import { Connection } from "jsforce";
import { DateTime } from "luxon";
import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getRedTeamMute,
  getUser,
} from "../db/queries.js";
import { redTeamCard } from "../slack/redTeamCard.js";
import { evaluateRedTeam, RedTeamClientError } from "./redTeamClient.js";
import { buildIntelPack } from "./redTeamIntelPack.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import type {
  RedTeamRunResult,
  RedTeamTriggerEvent,
  UserPrefs,
} from "../types.js";
import { randomUUID } from "node:crypto";

export interface RunRedTeamEvalArgs {
  slackUserId: string;
  opportunityId: string;
  triggerEvent: RedTeamTriggerEvent;
  triggerMetadata?: { callId?: string; previousStage?: string };
  conn?: Connection;
  gongCallIds?: string[];
}

export interface RunRedTeamEvalResult {
  ok: boolean;
  reason: string;
  cardId?: string;
  slackUserId?: string;
  personasInvoked?: number;
  firedTriggers?: string[];
}

async function dropAudit(
  slackUserId: string,
  opportunityId: string,
  reason: string,
  extra?: Record<string, unknown>
): Promise<RunRedTeamEvalResult> {
  await appendAudit({
    slackUserId,
    opportunityId,
    action: "red_team_intel_dropped",
    metadata: { reason, ...(extra ?? {}) },
  });
  return { ok: true, reason };
}

async function failAudit(
  slackUserId: string,
  opportunityId: string,
  reason: string,
  extra?: Record<string, unknown>
): Promise<RunRedTeamEvalResult> {
  await appendAudit({
    slackUserId,
    opportunityId,
    action: "red_team_intel_failed",
    metadata: { reason, ...(extra ?? {}) },
  });
  return { ok: false, reason };
}

/**
 * End-to-end Red Team eval for a single (rep, opp) pair: assemble the intel
 * pack, POST it to the Python service, then either DM the rendered card or —
 * in shadow mode — log the result without posting.
 */
export async function runRedTeamEval(
  args: RunRedTeamEvalArgs
): Promise<RunRedTeamEvalResult> {
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

  let result: RedTeamRunResult;
  try {
    result = await evaluateRedTeam(pack);
  } catch (err: any) {
    return await failAudit(slackUserId, opportunityId, "agent_call_failed", {
      error:
        err instanceof RedTeamClientError
          ? `${err.message}${err.status ? ` (status=${err.status})` : ""}`.slice(0, 400)
          : String(err?.message ?? err).slice(0, 400),
    });
  }

  if (result.dropReason) {
    return await dropAudit(slackUserId, opportunityId, result.dropReason, {
      cooldownUntilIso: result.cooldownUntilIso ?? null,
      firedTriggers: result.firedTriggers,
    });
  }
  if (result.personasInvoked.length === 0) {
    return await dropAudit(slackUserId, opportunityId, "no_personas_fired", {
      firedTriggers: result.firedTriggers,
    });
  }

  // Shadow mode: agent ran, would-be card prepared, but no Slack post. The
  // full result lives in audit_log.metadata for review.
  const isShadow = config.redTeam.shadowMode || result.shadowMode;
  const cardId = randomUUID();

  if (isShadow) {
    await appendAudit({
      slackUserId,
      opportunityId,
      action: "red_team_eval_shadow",
      metadata: {
        cardId,
        triggerEvent,
        triggerMetadata,
        firedTriggers: result.firedTriggers,
        personasInvoked: result.personasInvoked,
        cooldownUntilIso: result.cooldownUntilIso ?? null,
      },
    });
    return {
      ok: true,
      reason: "shadow_mode",
      cardId,
      personasInvoked: result.personasInvoked.length,
      firedTriggers: result.firedTriggers,
    };
  }

  if (!config.slack.botToken) {
    return await dropAudit(slackUserId, opportunityId, "no_slack_bot_token");
  }

  const recipientSlackUserId =
    config.redTeam.redirectToSlackUserId || slackUserId;

  const slack = new WebClient(config.slack.botToken);
  const card = redTeamCard({
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
    result,
    instanceUrl: conn.instanceUrl!,
  });

  try {
    const posted = await slack.chat.postMessage({
      channel: recipientSlackUserId,
      unfurl_links: false,
      unfurl_media: false,
      ...card,
    });

    await appendAudit({
      slackUserId,
      opportunityId,
      action: "red_team_intel_surfaced",
      metadata: {
        cardId,
        triggerEvent,
        triggerMetadata,
        firedTriggers: result.firedTriggers,
        personasInvoked: result.personasInvoked,
        cooldownUntilIso: result.cooldownUntilIso ?? null,
        recipientSlackUserId,
        redirected: recipientSlackUserId !== slackUserId,
        evaluatedAt: result.evaluatedAt,
        slackChannel: posted.channel ?? null,
        slackTs: posted.ts ?? null,
      },
    });
    return {
      ok: true,
      reason: "surfaced",
      cardId,
      slackUserId: recipientSlackUserId,
      personasInvoked: result.personasInvoked.length,
      firedTriggers: result.firedTriggers,
    };
  } catch (err: any) {
    return await failAudit(slackUserId, opportunityId, "slack_post_failed", {
      error: String(err?.message ?? err).slice(0, 400),
    });
  }
}

/**
 * Returns true if the rep should be evaluated for the given stage. Empty
 * allowlist = feature off.
 */
export function stageInAllowlist(stageName: string): boolean {
  if (config.redTeam.stageAllowlist.length === 0) return false;
  return config.redTeam.stageAllowlist.some(
    (s) => s.toLowerCase() === stageName.toLowerCase()
  );
}

/**
 * `isEligibleForRedTeam` is a single source of truth for "should we fire an
 * eval for this rep on this opp right now". Used by both the Gong webhook
 * branch and the daily sweep.
 */
export function isUserEligible(user: UserPrefs | null): boolean {
  if (!user) return false;
  // Shadow mode lets us evaluate enrolled users (and the configured
  // redirect target) without DMing them. We still gate on the user being
  // enrolled OR a redirect being configured, so we don't spam audit rows
  // for users who never opted in.
  if (user.redTeamEnabled) return true;
  if (config.redTeam.shadowMode && config.redTeam.redirectToSlackUserId) {
    return user.slackUserId === config.redTeam.redirectToSlackUserId;
  }
  return false;
}

/** Convenience: ISO timestamp for a 7-day mute. */
export function muteUntilIso(days = 7): string {
  return DateTime.utc().plus({ days }).toISO()!;
}
