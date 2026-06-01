/**
 * At-risk opp watch: surfaces renewals approaching close + stalled opps that
 * the standup didn't already pick up.
 *
 * Piggybacks `runStandupForUser` — fires after `runBuySignalsForUser`. Same
 * thread (if there's a parent), same DM (if there isn't). Reuses the existing
 * recommender per opp so the action buttons on the card behave identically to
 * standup cards; the only difference is a "⚠️ Renewal closes in 14d · stalled
 * 23d" badge prepended via `oppWatchCard`.
 */
import type { Connection } from "jsforce";
import type { WebClient } from "@slack/web-api";
import pLimit from "../util/pLimit.js";
import {
  OPP_WATCH_DEDUP_DAYS,
  OPP_WATCH_MAX_CARDS_PER_RUN,
  RECOMMENDER_CONCURRENCY,
  RENEWAL_LOOKAHEAD_DAYS,
  STALL_THRESHOLD_DAYS,
} from "../constants.js";
import {
  appendAudit,
  getRecentOppWatchOppIds,
  insertOppWatchRun,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { oppWatchCard } from "../slack/blocks.js";
import { buildContextForSingleOpp } from "./opportunityContext.js";
import { recommendForOpp } from "./recommender.js";
import { fetchAtRiskOpportunities } from "./sfReads.js";

export interface OppWatchRunArgs {
  slackUserId: string;
  conn: Connection;
  slack: WebClient;
  sfUserId: string;
  channelId: string | null;
  threadTs: string | null;
  instanceUrl: string;
  /** Opp ids already surfaced in today's standup — skip these. */
  alreadySurfacedOppIds: Set<string>;
}

export interface OppWatchRunResult {
  candidateOpps: number;
  cardsPosted: number;
}

export async function runOppWatchForUser(
  args: OppWatchRunArgs
): Promise<OppWatchRunResult> {
  const {
    slackUserId,
    conn,
    slack,
    sfUserId,
    channelId,
    threadTs,
    instanceUrl,
    alreadySurfacedOppIds,
  } = args;

  const recentlySurfaced = await getRecentOppWatchOppIds(
    slackUserId,
    OPP_WATCH_DEDUP_DAYS
  );
  const exclude = new Set<string>([
    ...alreadySurfacedOppIds,
    ...recentlySurfaced,
  ]);

  let candidates;
  try {
    candidates = await fetchAtRiskOpportunities(conn, sfUserId, {
      lookaheadDays: RENEWAL_LOOKAHEAD_DAYS,
      stallDays: STALL_THRESHOLD_DAYS,
      excludeOppIds: exclude,
    });
  } catch (err: any) {
    await appendAudit({
      slackUserId,
      action: "opp_watch_dropped",
      metadata: {
        reason: "soql_failed",
        error: String(err?.message ?? err).slice(0, 400),
      },
    });
    return { candidateOpps: 0, cardsPosted: 0 };
  }

  if (candidates.length === 0) {
    return { candidateOpps: 0, cardsPosted: 0 };
  }

  // Sort: highest-urgency first. Renewals with the soonest close go first;
  // pure stalled deals follow, ordered by how long they've been dark.
  candidates.sort((a, b) => {
    const aIsRenewal = a.reason !== "stalled";
    const bIsRenewal = b.reason !== "stalled";
    if (aIsRenewal && !bIsRenewal) return -1;
    if (!aIsRenewal && bIsRenewal) return 1;
    if (aIsRenewal) {
      return (a.daysToClose ?? 9999) - (b.daysToClose ?? 9999);
    }
    return (b.daysSinceActivity ?? 0) - (a.daysSinceActivity ?? 0);
  });
  const surface = candidates.slice(0, OPP_WATCH_MAX_CARDS_PER_RUN);

  // Per-opp recommender, capped concurrency to keep within Vercel function
  // budget alongside the standup's existing N opps.
  const limit = pLimit(RECOMMENDER_CONCURRENCY);
  let cardsPosted = 0;

  await Promise.all(
    surface.map((c) =>
      limit(async () => {
        const ctx = await buildContextForSingleOpp(conn, c.id);
        if (!ctx) {
          await appendAudit({
            slackUserId,
            opportunityId: c.id,
            action: "opp_watch_dropped",
            metadata: { reason: "context_failed", oppId: c.id },
          });
          return;
        }
        let rec;
        try {
          rec = await recommendForOpp(ctx);
        } catch (err: any) {
          await appendAudit({
            slackUserId,
            opportunityId: c.id,
            action: "opp_watch_dropped",
            metadata: {
              reason: "recommender_failed",
              error: String(err?.message ?? err).slice(0, 400),
            },
          });
          return;
        }
        if (!rec || rec.fields.length === 0) {
          await appendAudit({
            slackUserId,
            opportunityId: c.id,
            action: "opp_watch_dropped",
            metadata: { reason: "no_field_changes", oppId: c.id, why: c.reason },
          });
          return;
        }

        (rec as any)._meta = {
          source: "opp_watch",
          reason: c.reason,
          daysToClose: c.daysToClose,
          daysSinceActivity: c.daysSinceActivity,
        };

        const cardId = await insertPendingCard({
          slackUserId,
          slackChannel: channelId ?? slackUserId,
          slackThreadTs: threadTs ?? "",
          opportunityId: c.id,
          recommendation: rec,
          kind: "opp_watch",
        });

        const { blocks, text } = oppWatchCard(
          cardId,
          rec,
          { name: c.name, accountName: c.accountName, instanceUrl },
          {
            reason: c.reason,
            daysToClose: c.daysToClose,
            daysSinceActivity: c.daysSinceActivity,
          }
        );

        try {
          const posted = await slack.chat.postMessage({
            channel: channelId ?? slackUserId,
            thread_ts: threadTs ?? undefined,
            unfurl_links: false,
            unfurl_media: false,
            text,
            blocks,
          });
          if (posted.ts) await setCardMessageTs(cardId, posted.ts);
        } catch (err: any) {
          await appendAudit({
            slackUserId,
            opportunityId: c.id,
            action: "opp_watch_dropped",
            metadata: {
              reason: "slack_post_failed",
              error: String(err?.message ?? err).slice(0, 400),
            },
          });
          return;
        }

        await insertOppWatchRun({
          slackUserId,
          opportunityId: c.id,
          reason: c.reason,
          cardId,
        });
        await appendAudit({
          slackUserId,
          opportunityId: c.id,
          action: "opp_watch_surfaced",
          metadata: {
            cardId,
            reason: c.reason,
            daysToClose: c.daysToClose,
            daysSinceActivity: c.daysSinceActivity,
            stage: c.stage,
            amount: c.amount,
            type: c.type,
          },
        });
        cardsPosted += 1;
      })
    )
  );

  return { candidateOpps: candidates.length, cardsPosted };
}
