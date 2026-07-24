/**
 * Blue Team post-call "next moves" — fires after every Gong post-call
 * SF-update flow and surfaces 2-4 concrete forward-looking actions per opp.
 *
 * Same managed-agent pattern as the arbiter, but with a lighter prompt: no
 * debate framing, no win/lose argumentation, just "here's the call insight
 * + deal state + people — what should the rep do next." The result is
 * Slack-rendered as its own card with feedback buttons so we can calibrate
 * whether reps find the actions actually useful.
 *
 * Triggered from `runGongPostCallSfUpdate` once we have an account-resolved
 * opp + call insight in scope. Best-effort — a failure here never blocks
 * the existing SF-update flow.
 */
import type { Connection } from "jsforce";
import type { WebClient } from "@slack/web-api";
import pLimit from "../util/pLimit.js";
import { RECOMMENDER_CONCURRENCY, NEXT_MOVES_MAX_PER_CALL } from "../constants.js";
import {
  appendAudit,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { nextMovesCard } from "../slack/blocks.js";
import { fetchActivities } from "./sfReads.js";
import { callBlueNextMoves, NextMovesClientError } from "./blueNextMovesClient.js";
import type {
  GongCallInsight,
  NextMovesPayload,
  PostMeetingMatchedContact,
  PostMeetingUnmatchedAttendee,
  SfActivity,
} from "../types.js";

export interface NextMovesOppInput {
  id: string;
  name: string;
  stageName: string;
  type: string | null;
  amount: number | null;
  closeDate: string | null;
  accountId: string;
  accountName: string;
}

export interface RunBlueNextMovesArgs {
  slackUserId: string;
  conn: Connection;
  slack: WebClient;
  digestChannelId: string;
  digestTs: string;
  callId: string | null;
  callTitle: string | null;
  callStartedAt: string | null;
  callDurationSec: number | null;
  callParties: Array<Record<string, unknown>>;
  callInsight: GongCallInsight | null;
  opportunities: NextMovesOppInput[];
  matchedContacts: PostMeetingMatchedContact[];
  unmatchedAttendees: PostMeetingUnmatchedAttendee[];
}

export interface RunBlueNextMovesResult {
  cardsPosted: number;
  oppsConsidered: number;
}

export async function runBlueNextMovesForCall(
  args: RunBlueNextMovesArgs
): Promise<RunBlueNextMovesResult> {
  const {
    slackUserId,
    conn,
    slack,
    digestChannelId,
    digestTs,
    callId,
    callTitle,
    callStartedAt,
    callDurationSec,
    callParties,
    callInsight,
    opportunities,
    matchedContacts,
    unmatchedAttendees,
  } = args;

  if (opportunities.length === 0) {
    return { cardsPosted: 0, oppsConsidered: 0 };
  }

  // Cap how many opps we run for next-moves on a single call — most calls
  // touch 1 opp; 3 is generous.
  const toProcess = opportunities.slice(0, NEXT_MOVES_MAX_PER_CALL);

  // Fetch the last 30d of activities once, batched across all opp ids.
  let activitiesByOppId: Map<string, SfActivity[]> = new Map();
  try {
    const since = new Date();
    since.setDate(since.getDate() - 30);
    const sinceIso = since.toISOString().slice(0, 10);
    activitiesByOppId = await fetchActivities(
      conn,
      toProcess.map((o) => o.id),
      sinceIso
    );
  } catch (err: any) {
    console.error("[next_moves] activity fetch failed:", err?.message ?? err);
  }

  const limit = pLimit(RECOMMENDER_CONCURRENCY);
  let cardsPosted = 0;

  await Promise.all(
    toProcess.map((opp) =>
      limit(async () => {
        try {
          const activities = (activitiesByOppId.get(opp.id) ?? []).map((a) => ({
            type: a.type,
            subject: a.subject ?? "",
            activityDate: a.activityDate,
            description: a.description,
          }));

          const resp = await callBlueNextMoves({
            opportunity: {
              id: opp.id,
              name: opp.name,
              stageName: opp.stageName,
              type: opp.type,
              amount: opp.amount,
              closeDate: opp.closeDate,
              accountName: opp.accountName,
              accountId: opp.accountId,
              ownerSlackUserId: slackUserId,
            },
            callInsight: callInsight
              ? {
                  summary: callInsight.summary ?? null,
                  positives: callInsight.positives ?? [],
                  negatives: callInsight.negatives ?? [],
                  nextSteps: callInsight.nextSteps ?? [],
                }
              : null,
            callMetadata: {
              callId,
              title: callTitle,
              durationSec: callDurationSec,
              startedAt: callStartedAt,
              parties: callParties,
            },
            matchedContacts: matchedContacts.map((c) => ({
              id: c.id,
              name: c.name,
              email: c.email,
              title: c.title,
            })),
            unmatchedAttendees: unmatchedAttendees.map((a) => ({
              email: a.email,
              displayName: a.displayName,
            })),
            recentActivities: activities,
            shadowMode: false,
          });

          if (resp.dropReason || resp.recommendedActions.length === 0) {
            await appendAudit({
              slackUserId,
              opportunityId: opp.id,
              action: "next_moves_dropped",
              metadata: {
                callId,
                reason: resp.dropReason ?? "no_actions",
                accountId: opp.accountId,
              },
            });
            return;
          }

          const payload: NextMovesPayload = {
            opportunityId: opp.id,
            opportunityName: opp.name,
            accountName: opp.accountName,
            callId,
            callTitle,
            headline: resp.headline,
            rationale: resp.rationale,
            actions: resp.recommendedActions,
            actionStates: Object.fromEntries(
              resp.recommendedActions.map((_, i) => [i, "open" as const])
            ),
          };

          const cardId = await insertPendingCard({
            slackUserId,
            slackChannel: digestChannelId,
            slackThreadTs: digestTs,
            opportunityId: opp.id,
            recommendation: payload,
            kind: "next_moves",
          });

          const view = nextMovesCard(cardId, payload, conn.instanceUrl!);
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
            opportunityId: opp.id,
            action: "next_moves_surfaced",
            metadata: {
              callId,
              cardId,
              accountId: opp.accountId,
              actionCount: resp.recommendedActions.length,
              headline: resp.headline,
              actions: resp.recommendedActions.map((a) => ({
                action: a.action,
                why: a.why,
                ownerRole: a.ownerRole,
                byDate: a.byDate,
              })),
            },
          });
          cardsPosted += 1;
        } catch (err: any) {
          const reason =
            err instanceof NextMovesClientError
              ? err.message
              : String(err?.message ?? err);
          console.error("[next_moves] opp failed:", opp.id, reason);
          await appendAudit({
            slackUserId,
            opportunityId: opp.id,
            action: "next_moves_dropped",
            metadata: {
              callId,
              reason: reason.slice(0, 400),
            },
          });
        }
      })
    )
  );

  return { cardsPosted, oppsConsidered: toProcess.length };
}
