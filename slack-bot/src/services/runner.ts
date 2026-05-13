import pLimit from "../util/pLimit.js";
import { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import { config } from "../config.js";
import { RECOMMENDER_CONCURRENCY } from "../constants.js";
import {
  appendAudit,
  getUser,
  insertPendingCard,
  markRunComplete,
  setCardMessageTs,
} from "../db/queries.js";
import { connectPrompt, oppCard, threadParent } from "../slack/blocks.js";
import { startAuthorization } from "./salesforceAuth.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { buildContext } from "./opportunityContext.js";
import { recommendForOpp } from "./recommender.js";
import { postAudit } from "./auditChannel.js";

export interface RunResult {
  ran: boolean;
  reason?: string;
  oppsConsidered?: number;
  cardsPosted?: number;
}

export async function runStandupForUser(slackUserId: string): Promise<RunResult> {
  const user = await getUser(slackUserId);
  if (!user) return { ran: false, reason: "user_not_found" };

  const slack = new WebClient(config.slack.botToken);

  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      const url = await startAuthorization(slackUserId);
      await slack.chat.postMessage({
        channel: slackUserId,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      return { ran: false, reason: "sf_not_connected" };
    }
    throw err;
  }

  let sfUserId: string | null;
  try {
    const ident = await conn.identity();
    sfUserId = (ident as any).user_id ?? null;
  } catch (err: any) {
    if (err?.errorCode === "invalid_grant" || err?.name === "invalid_grant") {
      const url = await startAuthorization(slackUserId);
      await slack.chat.postMessage({
        channel: slackUserId,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      return { ran: false, reason: "sf_invalid_grant" };
    }
    throw err;
  }
  if (!sfUserId) return { ran: false, reason: "sf_identity_failed" };

  const { opps, totalCalls, totalActivities } = await buildContext({
    conn,
    sfUserId,
    email: user.email,
    timezone: user.timezone,
  });

  if (opps.length === 0) {
    await slack.chat.postMessage({
      channel: slackUserId,
      unfurl_links: false,
      unfurl_media: false,
      text: "No open opportunities found today. Nothing to review.",
    });
    await markToday(user.slackUserId, user.timezone);
    return { ran: true, oppsConsidered: 0, cardsPosted: 0 };
  }

  const limit = pLimit(RECOMMENDER_CONCURRENCY);
  const recs = await Promise.all(
    opps.map((ctx) => limit(() => safeRecommend(ctx, slackUserId)))
  );

  const present = recs.filter(
    (r): r is NonNullable<typeof r> => r !== null && r.recommendation.fields.length > 0
  );

  const parent = threadParent({
    oppCount: present.length,
    callCount: totalCalls,
    activityCount: totalActivities,
  });

  const parentRes = await slack.chat.postMessage({
    channel: slackUserId,
    unfurl_links: false,
    unfurl_media: false,
    ...parent,
  });
  const threadTs = parentRes.ts!;
  const channel = parentRes.channel!;

  for (const r of present) {
    const cardId = await insertPendingCard({
      slackUserId,
      slackChannel: channel,
      slackThreadTs: threadTs,
      opportunityId: r.recommendation.opportunityId,
      recommendation: r.recommendation,
    });
    const cardBlocks = oppCard(cardId, r.recommendation, {
      name: r.opp.name,
      accountName: r.opp.accountName,
      instanceUrl: conn.instanceUrl!,
    });
    const cardRes = await slack.chat.postMessage({
      channel,
      thread_ts: threadTs,
      unfurl_links: false,
      unfurl_media: false,
      ...cardBlocks,
    });
    if (cardRes.ts) await setCardMessageTs(cardId, cardRes.ts);
    for (const f of r.recommendation.fields) {
      await appendAudit({
        slackUserId,
        opportunityId: r.recommendation.opportunityId,
        fieldName: f.field,
        action: "recommended",
        oldValue: String(f.currentValue ?? ""),
        newValue: String(f.recommendedValue ?? ""),
        metadata: { rationale: f.rationale },
      });
    }
  }

  await markToday(user.slackUserId, user.timezone);
  await postAudit(
    `Standup ran for <@${slackUserId}>: ${present.length} cards across ${opps.length} opps.`
  );
  return {
    ran: true,
    oppsConsidered: opps.length,
    cardsPosted: present.length,
  };
}

async function safeRecommend(
  ctx: Parameters<typeof recommendForOpp>[0],
  slackUserId: string
) {
  try {
    const r = await recommendForOpp(ctx);
    if (!r) {
      await appendAudit({
        slackUserId,
        opportunityId: ctx.opp.id,
        action: "recommend_failed",
        metadata: { reason: "no_valid_json" },
      });
      return null;
    }
    return { opp: ctx.opp, recommendation: r };
  } catch (err: any) {
    await appendAudit({
      slackUserId,
      opportunityId: ctx.opp.id,
      action: "recommend_failed",
      metadata: { error: err.message },
    });
    return null;
  }
}

async function markToday(slackUserId: string, timezone: string): Promise<void> {
  const today = DateTime.now().setZone(timezone).toISODate()!;
  await markRunComplete(slackUserId, today);
}
