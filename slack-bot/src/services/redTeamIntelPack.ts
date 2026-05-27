import { Connection } from "jsforce";
import { DateTime } from "luxon";
import { config } from "../config.js";
import {
  RED_TEAM_ACTIVITY_LIMIT,
  RED_TEAM_DEFAULT_OPP_FIELDS,
  RED_TEAM_FIELD_HISTORY_LOOKBACK_DAYS,
  RED_TEAM_GONG_CALL_LIMIT,
  RED_TEAM_TRANSCRIPT_SEGMENT_LIMIT,
} from "../constants.js";
import { getOppSnapshot, upsertOppSnapshot } from "../db/queries.js";
import { getCallsExtensive, getCallTranscript } from "./gong.js";
import { getConnectionForUser } from "./salesforceClient.js";
import {
  escapeSoql,
  fetchActivities,
  fetchOpportunityFieldHistory,
  fetchOpportunityWithCustomFields,
  type OpportunityFieldHistoryRow,
  type OpportunityWithCustomFields,
} from "./sfReads.js";
import type {
  RedTeamActivity,
  RedTeamFieldChange,
  RedTeamGongCall,
  RedTeamIntelPackRequest,
  RedTeamTriggerEvent,
  UserPrefs,
} from "../types.js";

export interface BuildIntelPackInput {
  user: UserPrefs;
  opportunityId: string;
  triggerEvent: RedTeamTriggerEvent;
  triggerMetadata?: { callId?: string; previousStage?: string };
  /** Optional pre-built connection to avoid a second token lookup. */
  conn?: Connection;
  /** Optional Gong call ids to attach (otherwise the function discovers
   *  recent calls heuristically by Account name match — same as buildContext). */
  gongCallIds?: string[];
}

export interface BuildIntelPackResult {
  pack: RedTeamIntelPackRequest;
  opportunity: OpportunityWithCustomFields;
}

function trackedCustomFieldNames(): string[] {
  return config.redTeam.oppFields.length > 0
    ? config.redTeam.oppFields
    : [...RED_TEAM_DEFAULT_OPP_FIELDS];
}

function detectRenewal(opp: OpportunityWithCustomFields): boolean {
  const stage = (opp.stageName ?? "").toLowerCase();
  const type = (opp.type ?? "").toLowerCase();
  return (
    type.includes("renewal") ||
    type.includes("expansion") ||
    stage.includes("renewal")
  );
}

function diffSnapshot(
  current: OpportunityWithCustomFields,
  previous: Record<string, unknown> | null,
  previousTakenAt: string | null
): RedTeamFieldChange[] {
  if (!previous) return [];
  const diffs: RedTeamFieldChange[] = [];
  const trackedKeys = [
    "stageName",
    "amount",
    "closeDate",
    "nextStep",
    "type",
    ...trackedCustomFieldNames().map((f) => `customFields.${f}`),
  ];
  const get = (
    obj: Record<string, unknown>,
    key: string
  ): unknown => {
    if (!key.includes(".")) return obj[key];
    const [head, ...rest] = key.split(".");
    const nested = obj[head] as Record<string, unknown> | undefined;
    return nested ? nested[rest.join(".")] : undefined;
  };
  const currentRecord = current as unknown as Record<string, unknown>;
  for (const key of trackedKeys) {
    const before = get(previous, key);
    const after = get(currentRecord, key);
    if (before === undefined && after === undefined) continue;
    const beforeStr = before == null ? null : String(before);
    const afterStr = after == null ? null : String(after);
    if (beforeStr === afterStr) continue;
    diffs.push({
      field: key.replace(/^customFields\./, ""),
      oldValue: beforeStr,
      newValue: afterStr,
      changedAt: previousTakenAt ?? new Date().toISOString(),
      source: "snapshot_diff",
    });
  }
  return diffs;
}

function fieldHistoryToChanges(
  rows: OpportunityFieldHistoryRow[]
): RedTeamFieldChange[] {
  return rows.map((r) => ({
    field: r.field,
    oldValue: r.oldValue,
    newValue: r.newValue,
    changedAt: r.changedAt,
    source: "field_history" as const,
  }));
}

async function discoverRecentGongCalls(
  conn: Connection,
  accountId: string,
  opportunityId: string,
  limit: number
): Promise<string[]> {
  // Gong's SF package logs calls as `Gong__Gong_Call__c` records linked to
  // the Opportunity via `Gong__Primary_Opportunity__c`. The Gong call ID lives
  // on either `Gong__Call_Id__c` (if the customer has the field) or the
  // record's `Name` (the package's default).
  //
  // Falls back to Task-based discovery for orgs that don't have the Gong
  // package installed but log call ids on Tasks via `Gong__Gong_Call_Id__c`.
  const gongCustomObject = await tryGongCustomObject(
    conn,
    opportunityId,
    accountId,
    limit
  );
  if (gongCustomObject !== null) return gongCustomObject;

  const whatIds = [accountId, opportunityId]
    .filter(Boolean)
    .map((id) => `'${escapeSoql(id)}'`)
    .join(", ");
  const fallbackSoql = `
    SELECT Gong__Gong_Call_Id__c, ActivityDate, CreatedDate
      FROM Task
     WHERE WhatId IN (${whatIds})
       AND Gong__Gong_Call_Id__c != null
     ORDER BY ActivityDate DESC NULLS LAST, CreatedDate DESC
     LIMIT ${limit * 2}`;
  try {
    const result = await conn.query(fallbackSoql);
    const ids: string[] = [];
    for (const r of result.records as any[]) {
      const id = r.Gong__Gong_Call_Id__c;
      if (typeof id === "string" && id && !ids.includes(id)) ids.push(id);
    }
    return ids.slice(0, limit);
  } catch (err: any) {
    const message = String(err?.message ?? err);
    if (/INVALID_FIELD|No such column|sObject type/i.test(message)) return [];
    throw err;
  }
}

async function tryGongCustomObject(
  conn: Connection,
  opportunityId: string,
  accountId: string,
  limit: number
): Promise<string[] | null> {
  // Gong only auto-links calls to the Account; the Opportunity link
  // (Gong__Primary_Opportunity__c) is often left blank because that field is
  // populated manually by the rep. So we widen the filter to either link.
  // Two id-field attempts: prefer `Gong__Call_Id__c`, fall back to `Name`.
  const whereClause =
    `(Gong__Primary_Opportunity__c = '${escapeSoql(opportunityId)}' ` +
    `OR Gong__Primary_Account__c = '${escapeSoql(accountId)}')`;
  for (const idField of ["Gong__Call_Id__c", "Name"]) {
    const soql = `
      SELECT ${idField}, Gong__Call_Start__c
        FROM Gong__Gong_Call__c
       WHERE ${whereClause}
       ORDER BY Gong__Call_Start__c DESC NULLS LAST
       LIMIT ${limit}`;
    try {
      const result = await conn.query(soql);
      const ids: string[] = [];
      for (const r of result.records as any[]) {
        const raw = r[idField];
        if (typeof raw === "string" && raw && !ids.includes(raw)) ids.push(raw);
      }
      return ids;
    } catch (err: any) {
      const message = String(err?.message ?? err);
      if (/sObject type 'Gong__Gong_Call__c'/i.test(message)) return null;
      if (/INVALID_FIELD|No such column/i.test(message)) continue;
      throw err;
    }
  }
  return null;
}

async function assembleGongCalls(
  callIds: string[]
): Promise<RedTeamGongCall[]> {
  if (callIds.length === 0) return [];
  let extensive: Awaited<ReturnType<typeof getCallsExtensive>> = [];
  try {
    extensive = await getCallsExtensive(callIds);
  } catch (err: any) {
    console.error(
      `[red-team] getCallsExtensive failed for ${callIds.length} calls:`,
      err?.message ?? err
    );
  }
  const byId = new Map(extensive.map((c) => [c.callId, c]));
  const out: RedTeamGongCall[] = [];
  for (const id of callIds) {
    const meta = byId.get(id) ?? null;
    let segments = null as Awaited<ReturnType<typeof getCallTranscript>>;
    try {
      segments = await getCallTranscript(id, {
        partySpeakers:
          meta?.parties.map((p) => ({
            speakerId: p.speakerId,
            name: p.name,
            affiliation: p.affiliation,
          })) ?? [],
      });
    } catch (err: any) {
      console.error(
        `[red-team] getCallTranscript failed for ${id}:`,
        err?.message ?? err
      );
    }
    const limited =
      segments && segments.length > RED_TEAM_TRANSCRIPT_SEGMENT_LIMIT
        ? segments.slice(0, RED_TEAM_TRANSCRIPT_SEGMENT_LIMIT)
        : segments;
    out.push({
      callId: id,
      title: meta?.title ?? null,
      startedAt: meta?.startedAt ?? null,
      durationSec: meta?.durationSec ?? null,
      url: meta?.url ?? null,
      brief: meta?.brief ?? null,
      parties:
        meta?.parties.map((p) => ({
          name: p.name,
          email: p.email,
          affiliation: p.affiliation,
          title: p.title,
        })) ?? [],
      transcript: limited ? { speakerSegments: limited } : null,
    });
  }
  return out;
}

export async function buildIntelPack(
  input: BuildIntelPackInput
): Promise<BuildIntelPackResult | null> {
  const customFieldNames = trackedCustomFieldNames();
  const conn =
    input.conn ?? (await getConnectionForUser(input.user.slackUserId));

  const opportunity = await fetchOpportunityWithCustomFields(
    conn,
    input.opportunityId,
    customFieldNames
  );
  if (!opportunity) return null;

  const sinceIso = DateTime.utc()
    .minus({ days: RED_TEAM_FIELD_HISTORY_LOOKBACK_DAYS })
    .toISO()!;

  const trackedHistoryFields = [
    "StageName",
    "Amount",
    "CloseDate",
    "NextStep",
    "Type",
    ...customFieldNames,
  ];

  let fieldHistory: OpportunityFieldHistoryRow[] = [];
  try {
    fieldHistory = await fetchOpportunityFieldHistory(
      conn,
      opportunity.id,
      sinceIso,
      trackedHistoryFields
    );
  } catch (err: any) {
    console.error(
      `[red-team] OpportunityFieldHistory unavailable for ${opportunity.id}:`,
      err?.message ?? err
    );
  }

  let recentFieldChanges = fieldHistoryToChanges(fieldHistory);
  const previousSnapshot = await getOppSnapshot(opportunity.id);
  if (recentFieldChanges.length === 0) {
    recentFieldChanges = diffSnapshot(
      opportunity,
      previousSnapshot?.snapshot ?? null,
      previousSnapshot?.takenAt ?? null
    );
  }

  // Always refresh the snapshot so the next sweep has a baseline to diff.
  await upsertOppSnapshot(opportunity.id, {
    stageName: opportunity.stageName,
    amount: opportunity.amount,
    closeDate: opportunity.closeDate,
    nextStep: opportunity.nextStep,
    type: opportunity.type,
    customFields: opportunity.customFields,
  });

  const activitiesByOpp = await fetchActivities(
    conn,
    [opportunity.id],
    DateTime.utc().minus({ days: 30 }).toISO()!
  );
  const activitiesRaw = activitiesByOpp.get(opportunity.id) ?? [];
  const activities: RedTeamActivity[] = activitiesRaw
    .slice(0, RED_TEAM_ACTIVITY_LIMIT)
    .map((a) => ({
      type: a.type,
      subject: a.subject,
      activityDate: a.activityDate,
      description: a.description,
    }));

  let gongCallIds = input.gongCallIds ?? [];
  if (gongCallIds.length === 0) {
    gongCallIds = await discoverRecentGongCalls(
      conn,
      opportunity.accountId,
      opportunity.id,
      RED_TEAM_GONG_CALL_LIMIT
    );
  } else {
    gongCallIds = gongCallIds.slice(0, RED_TEAM_GONG_CALL_LIMIT);
  }
  const gongCalls = await assembleGongCalls(gongCallIds);

  console.log(
    `[red-team] intel pack assembled for ${opportunity.id}: ` +
      `customFields=${Object.keys(opportunity.customFields).length} ` +
      `meddpiccScores=${
        Object.keys(opportunity.customFields).filter((k) =>
          k.endsWith("_Score__c")
        ).length
      } ` +
      `fieldChanges=${recentFieldChanges.length} ` +
      `gongCalls=${gongCalls.length} ` +
      `transcriptSegments=${gongCalls.reduce(
        (n, c) => n + (c.transcript?.speakerSegments?.length ?? 0),
        0
      )} ` +
      `activities=${activities.length}`
  );

  const pack: RedTeamIntelPackRequest = {
    schemaVersion: "1",
    opportunity: {
      id: opportunity.id,
      name: opportunity.name,
      stageName: opportunity.stageName,
      type: opportunity.type,
      amount: opportunity.amount,
      closeDate: opportunity.closeDate,
      nextStep: opportunity.nextStep,
      ownerId: opportunity.ownerId,
      accountId: opportunity.accountId,
      accountName: opportunity.accountName,
      isRenewal: detectRenewal(opportunity),
      customFields: opportunity.customFields,
    },
    owner: {
      sfUserId: opportunity.ownerId,
      name: opportunity.ownerName,
      email: opportunity.ownerEmail,
      slackUserId: input.user.slackUserId,
    },
    account: {
      id: opportunity.accountId,
      name: opportunity.accountName,
      industry: opportunity.accountIndustry,
      website: opportunity.accountWebsite,
    },
    recentFieldChanges,
    gongCalls,
    activities,
    triggerEvent: input.triggerEvent,
    triggerMetadata: input.triggerMetadata ?? {},
    shadowMode: config.redTeam.shadowMode,
  };

  return { pack, opportunity };
}
