import { Connection } from "jsforce";
import { appendAudit, getUser } from "../db/queries.js";
import {
  isUserEligible,
  runRedTeamEval,
  stageInAllowlist,
} from "./redTeamHandler.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import {
  escapeSoql,
  fetchOppIdsForGongCalls,
} from "./sfReads.js";
import type {
  GongContextObject,
  GongWebhookPayload,
} from "../types.js";

interface OppLookupResult {
  opportunityId: string | null;
  reason: string;
}

/**
 * Extract the SF Opportunity id from the Gong webhook's `context.salesforce`
 * objects (when Gong's SF sync attached them) or, failing that, by querying
 * Task records for the call id.
 */
async function resolveOppIdFromCall(
  conn: Connection,
  payload: GongWebhookPayload,
  callId: string
): Promise<OppLookupResult> {
  const sfContext = payload.callData?.context?.find(
    (c) => String(c?.system ?? "").toLowerCase() === "salesforce"
  );
  const oppObj: GongContextObject | undefined = sfContext?.objects?.find(
    (o) => o.objectType === "Opportunity"
  );
  if (oppObj?.objectId) {
    return { opportunityId: oppObj.objectId, reason: "context_block" };
  }
  const byTask = await fetchOppIdsForGongCalls(conn, [callId]);
  const fromTask = byTask.get(callId);
  if (fromTask) {
    return { opportunityId: fromTask, reason: "gong_task_match" };
  }
  return { opportunityId: null, reason: "no_opp_link" };
}

async function fetchOppStage(
  conn: Connection,
  opportunityId: string
): Promise<{ stageName: string; ownerId: string } | null> {
  const soql = `
    SELECT StageName, OwnerId
      FROM Opportunity
     WHERE Id = '${escapeSoql(opportunityId)}'
     LIMIT 1`;
  const result = await conn.query(soql);
  const r = (result.records as any[])[0];
  if (!r) return null;
  return { stageName: r.StageName, ownerId: r.OwnerId };
}

export interface TriggerRedTeamForGongCallArgs {
  slackUserId: string;
  payload: GongWebhookPayload;
}

/**
 * Fire-and-forget bridge from a Gong webhook to a Red Team eval. Resolves the
 * call → opp, checks the rep is enrolled + the stage is advanced enough, and
 * delegates to `runRedTeamEval`.
 */
export async function triggerRedTeamForGongCall(
  args: TriggerRedTeamForGongCallArgs
): Promise<{ ok: boolean; reason: string }> {
  const { slackUserId, payload } = args;
  const callId = payload.callData?.metaData?.id ?? null;
  if (!callId) return { ok: true, reason: "no_call_id" };

  const user = await getUser(slackUserId);
  if (!isUserEligible(user)) {
    return { ok: true, reason: "user_not_enrolled" };
  }

  let conn: Connection;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await appendAudit({
        slackUserId,
        action: "red_team_intel_dropped",
        metadata: { reason: "sf_not_connected", callId },
      });
      return { ok: true, reason: "sf_not_connected" };
    }
    throw err;
  }

  const lookup = await resolveOppIdFromCall(conn, payload, callId);
  if (!lookup.opportunityId) {
    await appendAudit({
      slackUserId,
      action: "red_team_intel_dropped",
      metadata: { reason: "no_opp_link", callId },
    });
    return { ok: true, reason: "no_opp_link" };
  }

  const oppInfo = await fetchOppStage(conn, lookup.opportunityId);
  if (!oppInfo) {
    await appendAudit({
      slackUserId,
      opportunityId: lookup.opportunityId,
      action: "red_team_intel_dropped",
      metadata: { reason: "opp_not_found", callId },
    });
    return { ok: true, reason: "opp_not_found" };
  }

  if (!stageInAllowlist(oppInfo.stageName)) {
    await appendAudit({
      slackUserId,
      opportunityId: lookup.opportunityId,
      action: "red_team_intel_dropped",
      metadata: {
        reason: "stage_not_eligible",
        stage: oppInfo.stageName,
        callId,
      },
    });
    return { ok: true, reason: "stage_not_eligible" };
  }

  const result = await runRedTeamEval({
    slackUserId,
    opportunityId: lookup.opportunityId,
    triggerEvent: "gong_call",
    triggerMetadata: { callId },
    conn,
    gongCallIds: [callId],
  });
  return { ok: result.ok, reason: result.reason };
}
