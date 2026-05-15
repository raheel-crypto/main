import type { Connection } from "jsforce";
import type { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import pLimit from "../util/pLimit.js";
import {
  BUY_SIGNAL_DEDUP_DAYS,
  BUY_SIGNAL_LOOKBACK_DAYS,
  BUY_SIGNAL_MAX_CARDS_PER_RUN,
  BUY_SIGNAL_SUBJECT_PATTERN,
  RECOMMENDER_CONCURRENCY,
} from "../constants.js";
import {
  appendAudit,
  getRecentBuySignalAccountIds,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import {
  fetchAccountIdsWithOpenOpp,
  fetchAccountsOwnedBy,
  fetchPositiveApolloCalls,
} from "./sfReads.js";
import { recommendBuySignal } from "./buySignalRecommender.js";
import { buySignalCard, buySignalThreadParent } from "../slack/blocks.js";
import type {
  BuySignalPayload,
  PositiveApolloCall,
} from "../types.js";

export interface BuySignalRunResult {
  accountsOwned: number;
  callsFound: number;
  candidateAccounts: number;
  cardsPosted: number;
  threadTs: string | null;
}

export interface RunBuySignalsArgs {
  slackUserId: string;
  conn: Connection;
  slack: WebClient;
  sfUserId: string;
  channelId: string | null;
  threadTs: string | null;
  instanceUrl: string;
}

export async function runBuySignalsForUser(
  args: RunBuySignalsArgs
): Promise<BuySignalRunResult> {
  const { slackUserId, conn, slack, sfUserId, instanceUrl } = args;

  const ownedAccounts = await fetchAccountsOwnedBy(conn, sfUserId);
  if (ownedAccounts.length === 0) {
    return {
      accountsOwned: 0,
      callsFound: 0,
      candidateAccounts: 0,
      cardsPosted: 0,
      threadTs: args.threadTs,
    };
  }

  const sinceIso = DateTime.utc()
    .minus({ days: BUY_SIGNAL_LOOKBACK_DAYS })
    .toISODate()!;

  const accountIds = ownedAccounts.map((a) => a.id);
  const [calls, accountsWithOpenOpp, dedupSet] = await Promise.all([
    fetchPositiveApolloCalls(
      conn,
      accountIds,
      sinceIso,
      BUY_SIGNAL_SUBJECT_PATTERN
    ),
    fetchAccountIdsWithOpenOpp(conn, accountIds),
    getRecentBuySignalAccountIds(slackUserId, BUY_SIGNAL_DEDUP_DAYS),
  ]);

  const nameById = new Map(ownedAccounts.map((a) => [a.id, a.name]));
  const byAccount = new Map<string, PositiveApolloCall[]>();
  for (const c of calls) {
    if (accountsWithOpenOpp.has(c.accountId)) continue;
    if (dedupSet.has(c.accountId)) continue;
    if (!nameById.has(c.accountId)) continue;
    const arr = byAccount.get(c.accountId) ?? [];
    arr.push(c);
    byAccount.set(c.accountId, arr);
  }

  const candidates = [...byAccount.entries()]
    .map(([accountId, accountCalls]) => ({ accountId, calls: accountCalls }))
    .sort((a, b) => {
      const da = a.calls[0]?.activityDate ?? "";
      const db = b.calls[0]?.activityDate ?? "";
      return db.localeCompare(da);
    })
    .slice(0, BUY_SIGNAL_MAX_CARDS_PER_RUN);

  if (candidates.length === 0) {
    return {
      accountsOwned: ownedAccounts.length,
      callsFound: calls.length,
      candidateAccounts: 0,
      cardsPosted: 0,
      threadTs: args.threadTs,
    };
  }

  const todayIso = DateTime.utc().toISODate()!;
  const limit = pLimit(RECOMMENDER_CONCURRENCY);
  const recs = await Promise.all(
    candidates.map((c) =>
      limit(async () => {
        try {
          const rec = await recommendBuySignal({
            accountId: c.accountId,
            accountName: nameById.get(c.accountId)!,
            industry: null,
            calls: c.calls,
            todayIso,
          });
          return { accountId: c.accountId, calls: c.calls, rec };
        } catch (err: any) {
          await appendAudit({
            slackUserId,
            action: "buy_signal_dropped",
            metadata: {
              accountId: c.accountId,
              reason: "recommender_error",
              error: err?.message ?? String(err),
            },
          });
          return null;
        }
      })
    )
  );

  const present = recs.filter(
    (r): r is NonNullable<typeof r> =>
      r !== null && r.rec !== null && r.rec.suggestedAction !== "no_action"
  );

  for (const dropped of recs) {
    if (!dropped) continue;
    if (dropped.rec === null) {
      await appendAudit({
        slackUserId,
        action: "buy_signal_dropped",
        metadata: { accountId: dropped.accountId, reason: "no_valid_json" },
      });
    } else if (dropped.rec.suggestedAction === "no_action") {
      await appendAudit({
        slackUserId,
        action: "buy_signal_dropped",
        metadata: {
          accountId: dropped.accountId,
          reason: "no_action",
          headline: dropped.rec.headline,
        },
      });
    }
  }

  if (present.length === 0) {
    return {
      accountsOwned: ownedAccounts.length,
      callsFound: calls.length,
      candidateAccounts: candidates.length,
      cardsPosted: 0,
      threadTs: args.threadTs,
    };
  }

  let channel = args.channelId;
  let threadTs = args.threadTs;
  if (!threadTs || !channel) {
    const parent = buySignalThreadParent({ cardCount: present.length });
    const parentRes = await slack.chat.postMessage({
      channel: slackUserId,
      unfurl_links: false,
      unfurl_media: false,
      ...parent,
    });
    threadTs = parentRes.ts!;
    channel = parentRes.channel!;
  }

  let cardsPosted = 0;
  for (const r of present) {
    const accountName = nameById.get(r.accountId)!;
    const mostRecent = r.calls[0];
    const payload: BuySignalPayload = {
      accountId: r.accountId,
      accountName,
      callCount: r.calls.length,
      mostRecentCallDate: mostRecent?.activityDate ?? null,
      calls: r.calls.slice(0, 5).map((c) => ({
        taskId: c.taskId,
        ownerName: c.ownerName,
        activityDate: c.activityDate,
        subject: c.subject,
        description: c.description,
      })),
      headline: r.rec!.headline,
      suggestedAction: r.rec!.suggestedAction,
      suggestedOpp: r.rec!.suggestedOpp ?? null,
      suggestedTask: r.rec!.suggestedTask ?? null,
      rationale: r.rec!.rationale,
    };

    const cardId = await insertPendingCard({
      slackUserId,
      slackChannel: channel,
      slackThreadTs: threadTs,
      opportunityId: null,
      recommendation: payload,
      kind: "buy_signal",
    });

    const cardBlocks = buySignalCard(cardId, payload, { instanceUrl });
    const cardRes = await slack.chat.postMessage({
      channel,
      thread_ts: threadTs,
      unfurl_links: false,
      unfurl_media: false,
      ...cardBlocks,
    });
    if (cardRes.ts) await setCardMessageTs(cardId, cardRes.ts);

    await appendAudit({
      slackUserId,
      action: "buy_signal_surfaced",
      metadata: {
        cardId,
        accountId: r.accountId,
        accountName,
        callCount: r.calls.length,
        suggestedAction: r.rec!.suggestedAction,
      },
    });
    cardsPosted++;
  }

  return {
    accountsOwned: ownedAccounts.length,
    callsFound: calls.length,
    candidateAccounts: candidates.length,
    cardsPosted,
    threadTs,
  };
}
