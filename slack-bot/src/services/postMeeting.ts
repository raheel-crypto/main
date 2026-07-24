import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getUser,
  insertMeetingRun,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { postMeetingCard, meetingPickerCard } from "../slack/blocks.js";
import { externalAttendees } from "./meetingScheduler.js";
import { resolveAccount } from "./accountResolver.js";
import { getEvent, GcNotConnectedError } from "./googleClient.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import {
  fetchContactsByEmail,
  fetchOpportunitiesForAccount,
  type ContactRow,
} from "./sfReads.js";
import type {
  PostMeetingMatchedContact,
  PostMeetingOpportunity,
  PostMeetingPayload,
  PostMeetingUnmatchedAttendee,
} from "../types.js";
import { DateTime } from "luxon";

export interface PostMeetingResult {
  ok: boolean;
  reason?: string;
}

export async function runPostMeeting(args: {
  slackUserId: string;
  eventId: string;
}): Promise<PostMeetingResult> {
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
    console.error(`[post-meeting] getEvent failed:`, err?.message ?? err);
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
  const resolved = await resolveAccount(conn, externalEmails);

  const ins = await insertMeetingRun({
    slackUserId,
    gcalEventId: eventId,
    phase: "post",
    accountIdResolved: resolved.accountId,
  });
  if (!ins.inserted) {
    return { ok: true, reason: "already_ran" };
  }

  const eventTitle = event.summary ?? "(untitled meeting)";
  const startIso = event.start?.dateTime ?? null;
  const endIso = event.end?.dateTime ?? null;
  const startLabel = startIso
    ? DateTime.fromISO(startIso).setZone(user.timezone).toFormat("ccc h:mm a ZZZZ")
    : "earlier";

  if (resolved.source === "picker_needed") {
    await appendAudit({
      slackUserId,
      action: "meeting_picker_surfaced",
      metadata: { eventId, phase: "post", externalEmails, candidates: resolved.candidates },
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
      eventTitle: `Post-meeting · ${eventTitle}`,
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

  const matchedContacts: ContactRow[] = resolved.matchedContacts.length > 0
    ? resolved.matchedContacts
    : await fetchContactsByEmail(conn, externalEmails);

  const matchedEmails = new Set(matchedContacts.map((c) => c.email.toLowerCase()));
  const unmatched: PostMeetingUnmatchedAttendee[] = externals
    .filter((a) => !matchedEmails.has(a.email.toLowerCase()))
    .map((a) => {
      const email = a.email.toLowerCase();
      return {
        email,
        displayName: a.displayName ?? null,
        domain: email.split("@")[1] ?? "",
      };
    });

  const matched: PostMeetingMatchedContact[] = matchedContacts
    .filter((c) => c.accountId === resolved.accountId)
    .map((c) => ({
      id: c.id,
      name: c.name,
      email: c.email,
      title: c.title,
    }));

  const opps = await fetchOpportunitiesForAccount(conn, resolved.accountId, true);
  const openOpportunities: PostMeetingOpportunity[] = opps.map((o) => ({
    id: o.id,
    name: o.name,
    stage: o.stage,
    amount: o.amount,
    closeDate: o.closeDate,
    nextStep: o.nextStep,
  }));

  const payload: PostMeetingPayload = {
    gcalEventId: eventId,
    eventTitle,
    startIso,
    endIso,
    accountId: resolved.accountId,
    accountName: resolved.accountName ?? "(account)",
    matchedContacts: matched,
    unmatchedAttendees: unmatched,
    openOpportunities,
  };

  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: "",
    opportunityId: null,
    recommendation: payload,
    kind: "post_meeting",
  });

  const view = postMeetingCard(cardId, payload, conn.instanceUrl!);
  const posted = await slack.chat.postMessage({
    channel: channelId,
    unfurl_links: false,
    unfurl_media: false,
    ...view,
  });
  if (posted.ts) await setCardMessageTs(cardId, posted.ts);

  await appendAudit({
    slackUserId,
    action: "meeting_post_surfaced",
    metadata: {
      eventId,
      accountId: resolved.accountId,
      source: resolved.source,
      matchedCount: matched.length,
      unmatchedCount: unmatched.length,
      openOppCount: openOpportunities.length,
    },
  });

  return { ok: true, reason: resolved.source };
}
