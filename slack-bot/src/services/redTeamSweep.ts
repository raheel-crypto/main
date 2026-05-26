import { Connection } from "jsforce";
import { config } from "../config.js";
import { RED_TEAM_SWEEP_CONCURRENCY } from "../constants.js";
import {
  appendAudit,
  getRedTeamEnabledUsers,
  getUser,
} from "../db/queries.js";
import pLimit from "../util/pLimit.js";
import {
  isUserEligible,
  runRedTeamEval,
  stageInAllowlist,
} from "./redTeamHandler.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { fetchOppsForOwnerByStage } from "./sfReads.js";

export interface RedTeamSweepUserResult {
  slackUserId: string;
  ok: boolean;
  reason?: string;
  oppsEvaluated: number;
  surfaced: number;
  dropped: number;
  failed: number;
}

export interface RedTeamSweepResult {
  usersConsidered: number;
  usersEvaluated: number;
  oppsEvaluated: number;
  cardsSurfaced: number;
  perUser: RedTeamSweepUserResult[];
}

/**
 * Trigger the daily sweep: enumerate enrolled users and dispatch each via the
 * internal `/api/red-team/run-for-user` endpoint. Mirrors how the standup
 * dispatcher uses `/api/standup/run` so each per-user run gets its own Vercel
 * function invocation (with the 300s budget).
 */
export async function dispatchRedTeamSweep(): Promise<{
  total: number;
  triggered: string[];
}> {
  if (!config.redTeam.url || !config.redTeam.secret) {
    console.log("[red-team-sweep] skipping — agent URL/secret not configured");
    return { total: 0, triggered: [] };
  }
  if (config.redTeam.stageAllowlist.length === 0) {
    console.log("[red-team-sweep] skipping — RED_TEAM_STAGE_ALLOWLIST empty");
    return { total: 0, triggered: [] };
  }

  const users = await getRedTeamEnabledUsers();
  const triggered: string[] = [];

  for (const u of users) {
    try {
      const res = await fetch(
        `${config.publicUrl}/api/red-team/run-for-user`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-internal-secret": config.internalSecret,
          },
          body: JSON.stringify({ slackUserId: u.slackUserId }),
        }
      );
      if (res.ok) triggered.push(u.slackUserId);
      else
        console.error(
          `[red-team-sweep] run-for-user failed for ${u.slackUserId}: ${res.status}`
        );
    } catch (err: any) {
      console.error(
        `[red-team-sweep] dispatch error for ${u.slackUserId}:`,
        err?.message ?? err
      );
    }
  }

  return { total: users.length, triggered };
}

/**
 * The per-user sweep step — runs inside the dedicated function invocation
 * triggered by `dispatchRedTeamSweep`. Enumerates the rep's open opps in the
 * stage allowlist and fires evals concurrently.
 */
export async function runRedTeamSweepForUser(
  slackUserId: string
): Promise<RedTeamSweepUserResult> {
  const user = await getUser(slackUserId);
  if (!isUserEligible(user)) {
    return {
      slackUserId,
      ok: true,
      reason: "not_enrolled",
      oppsEvaluated: 0,
      surfaced: 0,
      dropped: 0,
      failed: 0,
    };
  }

  let conn: Connection;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await appendAudit({
        slackUserId,
        action: "red_team_intel_dropped",
        metadata: { reason: "sf_not_connected", source: "daily_sweep" },
      });
      return {
        slackUserId,
        ok: true,
        reason: "sf_not_connected",
        oppsEvaluated: 0,
        surfaced: 0,
        dropped: 0,
        failed: 0,
      };
    }
    throw err;
  }

  const ident = await conn.identity();
  const sfUserId = (ident as any).user_id as string;
  const opps = await fetchOppsForOwnerByStage(
    conn,
    sfUserId,
    config.redTeam.stageAllowlist,
    50
  );
  if (opps.length === 0) {
    return {
      slackUserId,
      ok: true,
      reason: "no_eligible_opps",
      oppsEvaluated: 0,
      surfaced: 0,
      dropped: 0,
      failed: 0,
    };
  }

  const limit = pLimit(RED_TEAM_SWEEP_CONCURRENCY);
  let surfaced = 0;
  let dropped = 0;
  let failed = 0;
  await Promise.all(
    opps.map((o) =>
      limit(async () => {
        if (!stageInAllowlist(o.stageName)) return;
        const r = await runRedTeamEval({
          slackUserId,
          opportunityId: o.id,
          triggerEvent: "daily_sweep",
          conn,
        });
        if (!r.ok) {
          failed += 1;
        } else if (r.reason === "surfaced") {
          surfaced += 1;
        } else {
          dropped += 1;
        }
      })
    )
  );

  return {
    slackUserId,
    ok: true,
    oppsEvaluated: opps.length,
    surfaced,
    dropped,
    failed,
  };
}
