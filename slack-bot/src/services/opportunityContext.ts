import { Connection } from "jsforce";
import { DateTime } from "luxon";
import type {
  GongCall,
  OppContext,
  SfOpportunity,
  UsageRow,
} from "../types.js";
import { getUsageProvider } from "./usageDb.js";
import { getCallsForUserToday } from "./gong.js";
import {
  escapeSoql as escape,
  fetchActivities,
  fetchLastStageChangesForOpps,
} from "./sfReads.js";

export async function getStagePicklist(conn: Connection): Promise<string[]> {
  try {
    const desc = await conn.describe("Opportunity");
    const stageField = desc.fields.find((f) => f.name === "StageName");
    if (!stageField || !stageField.picklistValues) return [];
    return stageField.picklistValues
      .filter((p) => p.active)
      .map((p) => p.value);
  } catch {
    return [];
  }
}

async function fetchOpenOpps(
  conn: Connection,
  ownerId: string
): Promise<SfOpportunity[]> {
  const soql = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           NextStep, OwnerId
      FROM Opportunity
     WHERE OwnerId = '${escape(ownerId)}' AND IsClosed = false
     ORDER BY CloseDate ASC NULLS LAST
     LIMIT 50`;
  const result = await conn.query(soql);
  return result.records.map((r: any) => ({
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    stageName: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
    lastStageChangeDate: null,
  }));
}

export interface BuildContextInput {
  conn: Connection;
  sfUserId: string;
  email: string;
  timezone: string;
}

export interface BuildContextResult {
  opps: OppContext[];
  totalCalls: number;
  totalActivities: number;
}

export async function buildContext(
  input: BuildContextInput
): Promise<BuildContextResult> {
  const todayStart = DateTime.now()
    .setZone(input.timezone)
    .startOf("day")
    .toUTC()
    .toISO()!;
  const now = DateTime.now().toUTC().toISO()!;

  const [opps, stagePicklist, callsResult] = await Promise.all([
    fetchOpenOpps(input.conn, input.sfUserId),
    getStagePicklist(input.conn),
    getCallsForUserToday(input.email, todayStart, now).catch((err) => {
      console.error("[gong] fetch failed:", err.message);
      return [] as GongCall[];
    }),
  ]);

  const oppIds = opps.map((o) => o.id);
  const stageChanges = await fetchLastStageChangesForOpps(input.conn, oppIds);

  let earliestSince = todayStart;
  for (const dt of stageChanges.values()) {
    if (dt < earliestSince) earliestSince = dt;
  }

  const [activitiesByOpp, usageRows] = await Promise.all([
    fetchActivities(input.conn, oppIds, earliestSince),
    getUsageProvider()
      .getUsageForAccounts(
        Array.from(new Set(opps.map((o) => o.accountId))),
        DateTime.now().toISODate()!
      )
      .catch((err) => {
        console.error("[usage] fetch failed:", err.message);
        return [] as UsageRow[];
      }),
  ]);

  const usageByAccount = new Map<string, UsageRow[]>();
  for (const u of usageRows) {
    const arr = usageByAccount.get(u.accountId) ?? [];
    arr.push(u);
    usageByAccount.set(u.accountId, arr);
  }

  const oppsWithContext: OppContext[] = opps.map((opp) => ({
    opp: { ...opp, lastStageChangeDate: stageChanges.get(opp.id) ?? null },
    activities: activitiesByOpp.get(opp.id) ?? [],
    calls: matchCallsToOpp(callsResult, opp),
    usage: usageByAccount.get(opp.accountId) ?? [],
    picklistOptions: { stage: stagePicklist },
  }));

  const totalActivities = oppsWithContext.reduce(
    (n, o) => n + o.activities.length,
    0
  );

  return {
    opps: oppsWithContext,
    totalCalls: callsResult.length,
    totalActivities,
  };
}

/**
 * Build an OppContext for a single Opportunity by id. Skips Gong-call and
 * usage fetches — callers that want those should still go through
 * `buildContext`. Designed for on-demand flows (notion sync, channel sync,
 * @merlin brief) where the document/transcript is the recommender's input,
 * not Gong/Usage.
 */
export async function buildContextForSingleOpp(
  conn: Connection,
  opportunityId: string
): Promise<OppContext | null> {
  const soql = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           NextStep, OwnerId
      FROM Opportunity
     WHERE Id = '${escape(opportunityId)}'
     LIMIT 1`;
  const result = await conn.query(soql);
  const r = (result.records as any[])[0];
  if (!r) return null;
  const opp: SfOpportunity = {
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    stageName: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
    lastStageChangeDate: null,
  };
  const [stageChanges, stagePicklist, activitiesByOpp] = await Promise.all([
    fetchLastStageChangesForOpps(conn, [opp.id]),
    getStagePicklist(conn),
    fetchActivities(
      conn,
      [opp.id],
      DateTime.utc().minus({ days: 90 }).toISO()!
    ),
  ]);
  opp.lastStageChangeDate = stageChanges.get(opp.id) ?? null;
  return {
    opp,
    activities: activitiesByOpp.get(opp.id) ?? [],
    calls: [],
    usage: [],
    picklistOptions: { stage: stagePicklist },
  };
}

function matchCallsToOpp(calls: GongCall[], opp: SfOpportunity): GongCall[] {
  const acc = opp.accountName.toLowerCase();
  return calls.filter((c) => {
    const title = c.title.toLowerCase();
    if (acc && title.includes(acc)) return true;
    return false;
  });
}
