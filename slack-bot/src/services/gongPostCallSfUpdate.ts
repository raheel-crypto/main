import { Connection } from "jsforce";
import { WebClient } from "@slack/web-api";
import pLimit from "../util/pLimit.js";
import { DateTime } from "luxon";
import { RECOMMENDER_CONCURRENCY } from "../constants.js";
import {
  appendAudit,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { oppCard, postMeetingCard } from "../slack/blocks.js";
import { resolveAccount } from "./accountResolver.js";
import { recommendForPostMeeting } from "./postMeetingRecommender.js";
import { runBlueNextMovesForCall } from "./blueNextMoves.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import {
  fetchContactsByEmail,
  fetchOpportunitiesForAccount,
  fetchOpportunityStagePicklist,
} from "./sfReads.js";
import type {
  GongCallInsight,
  GongWebhookPayload,
  PostMeetingMatchedContact,
  PostMeetingOpportunity,
  PostMeetingPayload,
  PostMeetingUnmatchedAttendee,
  Recommendation,
} from "../types.js";

export interface GongPostCallSfUpdateResult {
  ok: boolean;
  reason: string;
}

export async function runGongPostCallSfUpdate(args: {
  slackUserId: string;
  payload: GongWebhookPayload;
  insights: GongCallInsight | null;
  slack: WebClient;
  digestChannelId: string;
  digestTs: string;
}): Promise<GongPostCallSfUpdateResult> {
  const { slackUserId, payload, insights, slack, digestChannelId, digestTs } =
    args;
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
  const allOpenOpps: PostMeetingOpportunity[] = opps.map((o) => ({
    id: o.id,
    name: o.name,
    stage: o.stage,
    amount: o.amount,
    closeDate: o.closeDate,
    nextStep: o.nextStep,
  }));

  const startedIso = callData?.metaData?.started ?? null;
  const durationSec = Number(callData?.metaData?.duration ?? 0);
  const endIso =
    startedIso && Number.isFinite(durationSec) && durationSec > 0
      ? new Date(new Date(startedIso).getTime() + durationSec * 1000).toISOString()
      : null;
  const eventTitle = callData?.metaData?.title ?? "(Gong call)";

  const recsByOppId = new Map<string, Recommendation>();
  if (insights && allOpenOpps.length > 0) {
    let picklistStages: string[] = [];
    try {
      picklistStages = await fetchOpportunityStagePicklist(conn);
    } catch (err: any) {
      console.error(
        `[gong-post-call] stage picklist fetch failed: ${err?.message ?? err}`
      );
    }
    const todayIso = DateTime.utc().toISODate()!;
    const limit = pLimit(RECOMMENDER_CONCURRENCY);
    const results = await Promise.all(
      allOpenOpps.map((o) =>
        limit(async () => {
          try {
            const rec = await recommendForPostMeeting({
              opp: {
                id: o.id,
                name: o.name,
                accountName: resolved.accountName ?? "(account)",
                stage: o.stage,
                nextStep: o.nextStep,
                amount: o.amount,
                closeDate: o.closeDate,
              },
              picklistStages,
              insights,
              callTitle: eventTitle,
              todayIso,
            });
            return { oppId: o.id, rec };
          } catch (err: any) {
            console.error(
              `[gong-post-call] recommend failed for ${o.id}:`,
              err?.message ?? err
            );
            return { oppId: o.id, rec: null };
          }
        })
      )
    );
    for (const r of results) {
      if (r.rec && r.rec.fields.length > 0) {
        recsByOppId.set(r.oppId, r.rec);
      }
    }
  }

  const oppsWithoutAi = allOpenOpps.filter((o) => !recsByOppId.has(o.id));

  if (
    matched.length === 0 &&
    unmatched.length === 0 &&
    oppsWithoutAi.length === 0 &&
    recsByOppId.size === 0
  ) {
    return await dropAudit(slackUserId, callId, "nothing_actionable");
  }

  const cardPayload: PostMeetingPayload = {
    gcalEventId: callId,
    eventTitle,
    startIso: startedIso,
    endIso,
    accountId: resolved.accountId,
    accountName: resolved.accountName ?? "(account)",
    matchedContacts: matched,
    unmatchedAttendees: unmatched,
    openOpportunities: oppsWithoutAi,
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

  for (const [oppId, rec] of recsByOppId) {
    const opp = allOpenOpps.find((o) => o.id === oppId);
    if (!opp) continue;
    const oppCardId = await insertPendingCard({
      slackUserId,
      slackChannel: digestChannelId,
      slackThreadTs: digestTs,
      opportunityId: oppId,
      recommendation: rec,
      kind: "standup",
    });
    const cardBlocks = oppCard(oppCardId, rec, {
      name: opp.name,
      accountName: resolved.accountName ?? "(account)",
      instanceUrl: conn.instanceUrl!,
    });
    const oppPosted = await slack.chat.postMessage({
      channel: digestChannelId,
      thread_ts: digestTs,
      unfurl_links: false,
      unfurl_media: false,
      ...cardBlocks,
    });
    if (oppPosted.ts) await setCardMessageTs(oppCardId, oppPosted.ts);
    for (const f of rec.fields) {
      await appendAudit({
        slackUserId,
        opportunityId: oppId,
        fieldName: f.field,
        action: "recommended",
        oldValue: String(f.currentValue ?? ""),
        newValue: String(f.recommendedValue ?? ""),
        metadata: {
          source: "gong_post_call",
          callId,
          rationale: f.rationale,
        },
      });
    }
  }

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
      openOppCount: allOpenOpps.length,
      aiSuggestedOppCount: recsByOppId.size,
      manualOppCount: oppsWithoutAi.length,
    },
  });

  // Best-effort Blue post-call next-moves. Never blocks the SF-update flow;
  // any failure audits a `next_moves_dropped` row and continues.
  if (allOpenOpps.length > 0) {
    try {
      await runBlueNextMovesForCall({
        slackUserId,
        conn,
        slack,
        digestChannelId,
        digestTs,
        callId,
        callTitle: callData?.metaData?.title ?? null,
        callStartedAt: callData?.metaData?.started ?? null,
        callDurationSec: callData?.metaData?.duration ?? null,
        callParties: (parties ?? []) as any[],
        callInsight: insights,
        opportunities: allOpenOpps.map((o) => ({
          id: o.id,
          name: o.name,
          stageName: o.stage,
          type: null,
          amount: o.amount,
          closeDate: o.closeDate,
          accountId: resolved.accountId!,
          accountName: resolved.accountName ?? "",
        })),
        matchedContacts: matched,
        unmatchedAttendees: unmatched,
      });
    } catch (err: any) {
      console.error(
        "[gong_post_call] next_moves orchestrator failed:",
        err?.message ?? err
      );
    }
  }

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
