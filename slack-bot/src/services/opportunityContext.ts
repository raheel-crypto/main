import { Connection } from "jsforce";
import { DateTime } from "luxon";
import type {
  GongCall,
  OppContext,
  SfActivity,
  SfOpportunity,
  UsageRow,
} from "../types.js";
import { getUsageProvider } from "./usageDb.js";
import { getCallsForUserToday } from "./gong.js";

function escape(value: string): string {
  return value.replace(/'/g, "\\'");
}

async function getStagePicklist(conn: Connection): Promise<string[]> {
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

async function fetchLastStageChanges(
  conn: Connection,
  oppIds: string[]
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (oppIds.length === 0) return out;
  const ids = oppIds.map((id) => `'${escape(id)}'`).join(",");
  const soql = `
    SELECT OpportunityId, CreatedDate, StageName
      FROM OpportunityHistory
     WHERE OpportunityId IN (${ids})
     ORDER BY CreatedDate DESC`;
  const result = await conn.query(soql);
  for (const r of result.records as any[]) {
    if (!out.has(r.OpportunityId)) out.set(r.OpportunityId, r.CreatedDate);
  }
  return out;
}

async function fetchActivities(
  conn: Connection,
  oppIds: string[],
  sinceIso: string
): Promise<Map<string, SfActivity[]>> {
  const out = new Map<string, SfActivity[]>();
  if (oppIds.length === 0) return out;
  const ids = oppIds.map((id) => `'${escape(id)}'`).join(",");
  const sinceDate = sinceIso.slice(0, 10);

  const taskSoql = `
    SELECT Id, WhatId, Subject, ActivityDate, Description
      FROM Task
     WHERE WhatId IN (${ids}) AND ActivityDate >= ${sinceDate}
     ORDER BY ActivityDate DESC
     LIMIT 200`;
  const eventSoql = `
    SELECT Id, WhatId, Subject, ActivityDate, Description
      FROM Event
     WHERE WhatId IN (${ids}) AND ActivityDate >= ${sinceDate}
     ORDER BY ActivityDate DESC
     LIMIT 200`;

  const [tasks, events] = await Promise.all([
    conn.query(taskSoql),
    conn.query(eventSoql),
  ]);

  for (const r of tasks.records as any[]) {
    const arr = out.get(r.WhatId) ?? [];
    arr.push({
      id: r.Id,
      type: "Task",
      subject: r.Subject ?? "",
      activityDate: r.ActivityDate ?? null,
      description: r.Description ?? null,
    });
    out.set(r.WhatId, arr);
  }
  for (const r of events.records as any[]) {
    const arr = out.get(r.WhatId) ?? [];
    arr.push({
      id: r.Id,
      type: "Event",
      subject: r.Subject ?? "",
      activityDate: r.ActivityDate ?? null,
      description: r.Description ?? null,
    });
    out.set(r.WhatId, arr);
  }
  return out;
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
  const stageChanges = await fetchLastStageChanges(input.conn, oppIds);

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

function matchCallsToOpp(calls: GongCall[], opp: SfOpportunity): GongCall[] {
  const acc = opp.accountName.toLowerCase();
  return calls.filter((c) => {
    const title = c.title.toLowerCase();
    if (acc && title.includes(acc)) return true;
    return false;
  });
}
