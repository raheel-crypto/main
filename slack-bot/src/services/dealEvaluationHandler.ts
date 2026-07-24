/**
 * Arbiter-side orchestrator (replaces runRedTeamEval for the live triggers).
 *
 * Same shape as redTeamHandler.ts: cooldown / sf-not-connected / build intel
 * pack / call evaluateArbiter / render card / DM / audit. The Red-only flow
 * (runRedTeamEval) is kept alive only for `probe red-team` debug.
 */
import { Connection } from "jsforce";
import { WebClient } from "@slack/web-api";
import { randomUUID } from "node:crypto";
import { config } from "../config.js";
import {
  appendAudit,
  getRedTeamMute,
  getUser,
  insertVerdictConversation,
} from "../db/queries.js";
import { arbiterCard } from "../slack/arbiterCard.js";
import { ArbiterClientError, evaluateArbiter } from "./arbiterClient.js";
import { buildIntelPack } from "./redTeamIntelPack.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import type {
  ArbiterVerdict,
  RedTeamTriggerEvent,
} from "../types.js";

export interface RunDealEvaluationArgs {
  slackUserId: string;
  opportunityId: string;
  triggerEvent: RedTeamTriggerEvent;
  triggerMetadata?: { callId?: string; previousStage?: string };
  conn?: Connection;
  gongCallIds?: string[];
}

export interface RunDealEvaluationResult {
  ok: boolean;
  reason: string;
  cardId?: string;
  slackUserId?: string;
  probability?: number;
  confidence?: string;
  firedTriggers?: string[];
}

async function dropAudit(
  slackUserId: string,
  opportunityId: string,
  reason: string,
  extra?: Record<string, unknown>
): Promise<RunDealEvaluationResult> {
  await appendAudit({
    slackUserId,
    opportunityId,
    action: "arbiter_intel_dropped",
    metadata: { reason, ...(extra ?? {}) },
  });
  return { ok: true, reason };
}

async function failAudit(
  slackUserId: string,
  opportunityId: string,
  reason: string,
  extra?: Record<string, unknown>
): Promise<RunDealEvaluationResult> {
  await appendAudit({
    slackUserId,
    opportunityId,
    action: "arbiter_intel_failed",
    metadata: { reason, ...(extra ?? {}) },
  });
  return { ok: false, reason };
}

/**
 * End-to-end deal eval: assemble intel pack → POST to /arbiter → DM the
 * rendered card (or audit-only in shadow mode).
 */
export async function runDealEvaluation(
  args: RunDealEvaluationArgs
): Promise<RunDealEvaluationResult> {
  const {
    slackUserId,
    opportunityId,
    triggerEvent,
    triggerMetadata,
    gongCallIds,
  } = args;

  if (!config.redTeam.url || !config.redTeam.secret) {
    return await dropAudit(slackUserId, opportunityId, "agent_not_configured");
  }

  const user = await getUser(slackUserId);
  if (!user) {
    return await dropAudit(slackUserId, opportunityId, "no_user_row");
  }

  const mute = await getRedTeamMute(opportunityId, slackUserId);
  if (mute) {
    return await dropAudit(slackUserId, opportunityId, "muted", {
      mutedUntil: mute.mutedUntilIso,
    });
  }

  let conn: Connection;
  try {
    conn = args.conn ?? (await getConnectionForUser(slackUserId));
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      return await dropAudit(slackUserId, opportunityId, "sf_not_connected");
    }
    throw err;
  }

  let buildResult;
  try {
    buildResult = await buildIntelPack({
      user,
      opportunityId,
      triggerEvent,
      triggerMetadata,
      conn,
      gongCallIds,
    });
  } catch (err: any) {
    return await failAudit(slackUserId, opportunityId, "intel_pack_failed", {
      error: String(err?.message ?? err).slice(0, 400),
    });
  }
  if (!buildResult) {
    return await dropAudit(slackUserId, opportunityId, "opp_not_found");
  }
  const { pack, opportunity } = buildResult;

  let verdict: ArbiterVerdict;
  try {
    verdict = await evaluateArbiter(pack);
  } catch (err: any) {
    return await failAudit(slackUserId, opportunityId, "agent_call_failed", {
      error:
        err instanceof ArbiterClientError
          ? `${err.message}${err.status ? ` (status=${err.status})` : ""}`.slice(0, 400)
          : String(err?.message ?? err).slice(0, 400),
    });
  }

  if (verdict.dropReason) {
    return await dropAudit(slackUserId, opportunityId, verdict.dropReason, {
      cooldownUntilIso: verdict.cooldownUntilIso ?? null,
      firedTriggers: verdict.firedTriggers,
    });
  }
  if (!verdict.redArgument || !verdict.blueArgument) {
    return await dropAudit(slackUserId, opportunityId, "missing_argument", {
      firedTriggers: verdict.firedTriggers,
    });
  }

  // Shadow mode: agent ran, verdict computed, no Slack post. Audit row
  // captures the full verdict for review.
  const isShadow = config.redTeam.shadowMode || verdict.shadowMode;
  const cardId = randomUUID();

  if (isShadow) {
    await appendAudit({
      slackUserId,
      opportunityId,
      action: "arbiter_eval_shadow",
      metadata: {
        cardId,
        triggerEvent,
        triggerMetadata,
        probability: verdict.probability,
        confidence: verdict.confidence,
        disagreement: verdict.disagreement,
        baseRate: verdict.baseRate,
        meddpiccLift: verdict.meddpiccLift,
        firedTriggers: verdict.firedTriggers,
        routeReason: verdict.routeReason,
        roundsCompleted: verdict.roundsCompleted,
        redArgument: verdict.redArgument,
        blueArgument: verdict.blueArgument,
        redScoring: verdict.redScoring,
        blueScoring: verdict.blueScoring,
        topActions: verdict.topActions,
        explanation: verdict.explanation,
      },
    });
    return {
      ok: true,
      reason: "shadow_mode",
      cardId,
      probability: verdict.probability,
      confidence: verdict.confidence,
      firedTriggers: verdict.firedTriggers,
    };
  }

  if (!config.slack.botToken) {
    return await dropAudit(slackUserId, opportunityId, "no_slack_bot_token");
  }

  const recipientSlackUserId =
    config.redTeam.redirectToSlackUserId || slackUserId;

  const slack = new WebClient(config.slack.botToken);
  const card = arbiterCard({
    cardId,
    opportunity: {
      id: opportunity.id,
      name: opportunity.name,
      stageName: opportunity.stageName,
      amount: opportunity.amount,
      accountName: opportunity.accountName,
    },
    ownerSlackUserId: slackUserId,
    triggerEvent,
    verdict,
    instanceUrl: conn.instanceUrl!,
  });

  try {
    const posted = await slack.chat.postMessage({
      channel: recipientSlackUserId,
      unfurl_links: false,
      unfurl_media: false,
      ...card,
    });

    // Seed the verdict_conversations row so subsequent thread replies in this
    // DM can be matched to the verdict + intel pack by the Arbiter Moderator.
    // Best-effort — a failure here shouldn't block the audit row below.
    if (posted.ts && posted.channel) {
      try {
        await insertVerdictConversation({
          slackUserId: recipientSlackUserId,
          slackChannelId: posted.channel,
          slackThreadTs: posted.ts,
          opportunityId,
          verdict,
          intelPack: pack as unknown as Record<string, unknown>,
        });
      } catch (err: any) {
        console.error(
          "[deal_evaluation] verdict_conversation seed failed:",
          err?.message ?? err
        );
      }
    }

    await appendAudit({
      slackUserId,
      opportunityId,
      action: "arbiter_evaluated",
      metadata: {
        cardId,
        triggerEvent,
        triggerMetadata,
        probability: verdict.probability,
        confidence: verdict.confidence,
        disagreement: verdict.disagreement,
        baseRate: verdict.baseRate,
        meddpiccLift: verdict.meddpiccLift,
        firedTriggers: verdict.firedTriggers,
        routeReason: verdict.routeReason,
        roundsCompleted: verdict.roundsCompleted,
        topActions: verdict.topActions,
        evaluatedAt: verdict.evaluatedAt,
        recipientSlackUserId,
        redirected: recipientSlackUserId !== slackUserId,
        slackChannel: posted.channel ?? null,
        slackTs: posted.ts ?? null,
      },
    });
    return {
      ok: true,
      reason: "surfaced",
      cardId,
      slackUserId: recipientSlackUserId,
      probability: verdict.probability,
      confidence: verdict.confidence,
      firedTriggers: verdict.firedTriggers,
    };
  } catch (err: any) {
    return await failAudit(slackUserId, opportunityId, "slack_post_failed", {
      error: String(err?.message ?? err).slice(0, 400),
    });
  }
}
