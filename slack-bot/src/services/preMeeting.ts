import { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import { config } from "../config.js";
import { runAgent } from "../agent/runner.js";
import { extractJsonObject } from "../agent/jsonParse.js";
import { BRIEF_SYSTEM } from "../agent/prompts.js";
import { buildSlackProgressUpdater } from "../agent/progress.js";
import {
  appendAudit,
  getUser,
  insertMeetingRun,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { briefCard, briefErrorBlocks } from "../slack/blocks.js";
import { BriefPayloadSchema, type BriefPayload } from "../types.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { resolveAccount } from "./accountResolver.js";
import { externalAttendees } from "./meetingScheduler.js";
import { getEvent, GcNotConnectedError } from "./googleClient.js";
import { meetingPickerCard } from "../slack/blocks.js";

export interface PreMeetingResult {
  ok: boolean;
  reason?: string;
}

export async function runPreMeeting(args: {
  slackUserId: string;
  eventId: string;
  overrideAccount?: { id: string; name: string };
}): Promise<PreMeetingResult> {
  const { slackUserId, eventId } = args;
  const user = await getUser(slackUserId);
  if (!user) return { ok: false, reason: "user_not_found" };

  if (!config.slack.botToken) {
    return { ok: false, reason: "no_slack_bot_token" };
  }
  const slack = new WebClient(config.slack.botToken);

  let event;
  try {
    event = await getEvent(slackUserId, eventId);
  } catch (err: any) {
    if (err instanceof GcNotConnectedError) {
      return { ok: false, reason: "gcal_not_connected" };
    }
    console.error(`[pre-meeting] getEvent failed:`, err?.message ?? err);
    return { ok: false, reason: "getEvent_failed" };
  }

  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      return { ok: false, reason: "sf_not_connected" };
    }
    throw err;
  }

  const externals = externalAttendees(event);
  if (externals.length === 0) {
    return { ok: true, reason: "no_external_attendees" };
  }

  const dm = await slack.conversations.open({ users: slackUserId });
  const channelId = dm.channel?.id;
  if (!channelId) return { ok: false, reason: "im_open_failed" };

  const externalEmails = externals.map((a) => a.email.toLowerCase());
  const resolved = args.overrideAccount
    ? {
        source: "contact_match" as const,
        accountId: args.overrideAccount.id,
        accountName: args.overrideAccount.name,
        candidates: [],
        matchedContacts: [],
      }
    : await resolveAccount(conn, externalEmails);

  const ins = await insertMeetingRun({
    slackUserId,
    gcalEventId: eventId,
    phase: "pre",
    accountIdResolved: resolved.accountId,
  });
  if (!ins.inserted) {
    return { ok: true, reason: "already_ran" };
  }

  const eventTitle = event.summary ?? "(untitled meeting)";
  const startIso = event.start?.dateTime ?? null;
  const startLabel = startIso
    ? DateTime.fromISO(startIso).setZone(user.timezone).toFormat("ccc h:mm a ZZZZ")
    : "soon";

  if (resolved.source === "picker_needed") {
    await appendAudit({
      slackUserId,
      action: "meeting_picker_surfaced",
      metadata: { eventId, externalEmails, candidates: resolved.candidates },
    });

    const cardId = await insertPendingCard({
      slackUserId,
      slackChannel: channelId,
      slackThreadTs: "",
      opportunityId: null,
      recommendation: {
        kind: "meeting_picker",
        gcalEventId: eventId,
        eventTitle,
        startIso,
        externalEmails,
        externalDomains: Array.from(
          new Set(externalEmails.map((e) => e.split("@")[1]).filter(Boolean))
        ),
        candidates: resolved.candidates,
      },
      kind: "meeting_picker",
    });

    const view = meetingPickerCard(cardId, {
      eventTitle,
      startLabel,
      externalEmails,
      candidates: resolved.candidates,
    });
    const posted = await slack.chat.postMessage({
      channel: channelId,
      unfurl_links: false,
      unfurl_media: false,
      ...view,
    });
    if (posted.ts) await setCardMessageTs(cardId, posted.ts);
    return { ok: true, reason: "picker_surfaced" };
  }

  if (!resolved.accountId) {
    return { ok: true, reason: "unresolved" };
  }

  const accountName = resolved.accountName ?? "this account";
  const placeholder = await slack.chat.postMessage({
    channel: channelId,
    text: `:mag: Pre-meeting brief for *${accountName}* — looking things up…`,
  });
  const placeholderTs = placeholder.ts!;

  const updateProgress = buildSlackProgressUpdater({
    slack,
    channel: channelId,
    ts: placeholderTs,
    logTag: "[pre-meeting]",
  });

  const today = DateTime.now().setZone(user.timezone).toISODate();
  const externalListLine = externals
    .map((a) => `${a.displayName ?? a.email} <${a.email}>`)
    .join(", ");
  const result = await runAgent({
    system: BRIEF_SYSTEM,
    userMessage:
      `Generate a pre-meeting brief for the Salesforce account named "${accountName}" (Id: ${resolved.accountId}). ` +
      `Today is ${today} (${user.timezone}). ` +
      `The meeting is "${eventTitle}" at ${startLabel}. External attendees: ${externalListLine}. ` +
      `Focus the talking points on what's changed since the last touch and what the rep should confirm or push for on this call.`,
    maxTokens: 8192,
    maxIterations: 20,
    onToolUse: ({ toolNames }) => updateProgress(toolNames),
    ctx: {
      conn,
      slackUserId,
      userEmail: user.email,
      userTimezone: user.timezone,
      instanceUrl: conn.instanceUrl!,
    },
  });

  await updateProgress(["__finalizing"]);

  const raw = extractJsonObject(result.finalText);
  if (!raw) {
    await appendAudit({
      slackUserId,
      action: "meeting_brief_failed",
      metadata: { eventId, reason: "no_json", finalText: result.finalText.slice(0, 1000) },
    });
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(`I couldn't generate a brief for *${accountName}*.`),
    });
    return { ok: false, reason: "no_json" };
  }

  const parsed = BriefPayloadSchema.safeParse(raw);
  if (!parsed.success) {
    await appendAudit({
      slackUserId,
      action: "meeting_brief_failed",
      metadata: { eventId, reason: "schema_invalid", issues: parsed.error.issues },
    });
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(`I couldn't structure the brief for *${accountName}*.`),
    });
    return { ok: false, reason: "schema_invalid" };
  }
  const payload: BriefPayload = parsed.data;

  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: placeholderTs,
    slackMessageTs: placeholderTs,
    opportunityId: null,
    recommendation: payload,
    kind: "brief",
  });

  const blocks = briefCard(cardId, payload, conn.instanceUrl!);
  await slack.chat.update({
    channel: channelId,
    ts: placeholderTs,
    ...blocks,
  });
  await setCardMessageTs(cardId, placeholderTs);

  await appendAudit({
    slackUserId,
    action: "meeting_briefed",
    metadata: {
      eventId,
      accountId: resolved.accountId,
      source: resolved.source,
      eventTitle,
      startIso,
    },
  });

  return { ok: true, reason: resolved.source };
}
