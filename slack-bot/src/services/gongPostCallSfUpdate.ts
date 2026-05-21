import { Connection } from "jsforce";
import { WebClient } from "@slack/web-api";
import {
  appendAudit,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { postMeetingCard } from "../slack/blocks.js";
import { resolveAccount } from "./accountResolver.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import {
  fetchContactsByEmail,
  fetchOpportunitiesForAccount,
} from "./sfReads.js";
import type {
  GongWebhookPayload,
  PostMeetingMatchedContact,
  PostMeetingOpportunity,
  PostMeetingPayload,
  PostMeetingUnmatchedAttendee,
} from "../types.js";

export interface GongPostCallSfUpdateResult {
  ok: boolean;
  reason: string;
}

export async function runGongPostCallSfUpdate(args: {
  slackUserId: string;
  payload: GongWebhookPayload;
  slack: WebClient;
  digestChannelId: string;
  digestTs: string;
}): Promise<GongPostCallSfUpdateResult> {
  const { slackUserId, payload, slack, digestChannelId, digestTs } = args;
  const callData = payload.callData;
  const callId = callData?.metaData?.id ?? null;

  if (!callId) {
    return await dropAudit(slackUserId, callId, "no_call_id");
  }

  const parties = callData?.parties ?? [];
  const externalAttendees: { email: string; displayName: string | null }[] = [];
  const seenEmails = new Set<string>();
  for (const p of parties) {
    if (!p) continue;
    const aff = String(p.affiliation ?? "").toLowerCase();
    if (aff !== "external") continue;
    const email = (p.emailAddress ?? "").trim().toLowerCase();
    if (!email || seenEmails.has(email)) continue;
    seenEmails.add(email);
    externalAttendees.push({ email, displayName: p.name ?? null });
  }
  if (externalAttendees.length === 0) {
    return await dropAudit(slackUserId, callId, "no_external_attendees");
  }

  let conn: Connection;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      return await dropAudit(slackUserId, callId, "sf_not_connected");
    }
    throw err;
  }

  const externalEmails = externalAttendees.map((a) => a.email);
  const resolved = await resolveAccount(conn, externalEmails);

  if (resolved.source === "picker_needed" || !resolved.accountId) {
    return await dropAudit(slackUserId, callId, "unresolved_account", {
      candidateCount: resolved.candidates.length,
    });
  }

  const matchedContacts =
    resolved.matchedContacts.length > 0
      ? resolved.matchedContacts
      : await fetchContactsByEmail(conn, externalEmails);

  const matchedEmails = new Set(
    matchedContacts.map((c) => c.email.toLowerCase())
  );
  const unmatched: PostMeetingUnmatchedAttendee[] = externalAttendees
    .filter((a) => !matchedEmails.has(a.email))
    .map((a) => ({
      email: a.email,
      displayName: a.displayName,
      domain: a.email.split("@")[1] ?? "",
    }));

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

  if (matched.length === 0 && unmatched.length === 0 && openOpportunities.length === 0) {
    return await dropAudit(slackUserId, callId, "nothing_actionable");
  }

  const startedIso = callData?.metaData?.started ?? null;
  const durationSec = Number(callData?.metaData?.duration ?? 0);
  const endIso =
    startedIso && Number.isFinite(durationSec) && durationSec > 0
      ? new Date(new Date(startedIso).getTime() + durationSec * 1000).toISOString()
      : null;
  const eventTitle = callData?.metaData?.title ?? "(Gong call)";

  const cardPayload: PostMeetingPayload = {
    gcalEventId: callId,
    eventTitle,
    startIso: startedIso,
    endIso,
    accountId: resolved.accountId,
    accountName: resolved.accountName ?? "(account)",
    matchedContacts: matched,
    unmatchedAttendees: unmatched,
    openOpportunities,
  };

  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: digestChannelId,
    slackThreadTs: digestTs,
    opportunityId: null,
    recommendation: cardPayload,
    kind: "post_meeting",
  });

  const view = postMeetingCard(cardId, cardPayload, conn.instanceUrl!);
  const posted = await slack.chat.postMessage({
    channel: digestChannelId,
    thread_ts: digestTs,
    unfurl_links: false,
    unfurl_media: false,
    ...view,
  });
  if (posted.ts) await setCardMessageTs(cardId, posted.ts);

  await appendAudit({
    slackUserId,
    action: "gong_post_call_surfaced",
    metadata: {
      callId,
      cardId,
      accountId: resolved.accountId,
      source: resolved.source,
      matchedCount: matched.length,
      unmatchedCount: unmatched.length,
      openOppCount: openOpportunities.length,
    },
  });

  return { ok: true, reason: "surfaced" };
}

async function dropAudit(
  slackUserId: string,
  callId: string | null,
  reason: string,
  extra?: Record<string, unknown>
): Promise<GongPostCallSfUpdateResult> {
  await appendAudit({
    slackUserId,
    action: "gong_post_call_dropped",
    metadata: { callId, reason, ...(extra ?? {}) },
  });
  return { ok: true, reason };
}
