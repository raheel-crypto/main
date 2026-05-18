import { Connection } from "jsforce";
import type { PositiveApolloCall, SfActivity } from "../types.js";

export function escapeSoql(value: string): string {
  return value.replace(/'/g, "\\'");
}

export interface ActivityWithWhat extends SfActivity {
  whatId: string;
}

export async function fetchActivities(
  conn: Connection,
  whatIds: string[],
  sinceIso: string
): Promise<Map<string, SfActivity[]>> {
  const out = new Map<string, SfActivity[]>();
  if (whatIds.length === 0) return out;
  const ids = whatIds.map((id) => `'${escapeSoql(id)}'`).join(",");
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

  const push = (whatId: string, a: SfActivity) => {
    const arr = out.get(whatId) ?? [];
    arr.push(a);
    out.set(whatId, arr);
  };

  for (const r of tasks.records as any[]) {
    push(r.WhatId, {
      id: r.Id,
      type: "Task",
      subject: r.Subject ?? "",
      activityDate: r.ActivityDate ?? null,
      description: r.Description ?? null,
    });
  }
  for (const r of events.records as any[]) {
    push(r.WhatId, {
      id: r.Id,
      type: "Event",
      subject: r.Subject ?? "",
      activityDate: r.ActivityDate ?? null,
      description: r.Description ?? null,
    });
  }
  return out;
}

export interface AccountSearchResult {
  id: string;
  name: string;
  industry: string | null;
  ownerName: string | null;
}

export async function findAccountsByName(
  conn: Connection,
  name: string,
  limit = 10
): Promise<AccountSearchResult[]> {
  const q = `
    SELECT Id, Name, Industry, Owner.Name
      FROM Account
     WHERE Name LIKE '%${escapeSoql(name)}%'
     ORDER BY Name
     LIMIT ${limit}`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({
    id: r.Id,
    name: r.Name,
    industry: r.Industry ?? null,
    ownerName: r.Owner?.Name ?? null,
  }));
}

export interface AccountOpportunity {
  id: string;
  name: string;
  stage: string;
  amount: number | null;
  closeDate: string | null;
  isClosed: boolean;
  isWon: boolean;
  nextStep: string | null;
  ownerId: string;
}

export async function fetchOpportunitiesForAccount(
  conn: Connection,
  accountId: string,
  openOnly = true,
  limit = 50
): Promise<AccountOpportunity[]> {
  const closedFilter = openOnly ? "AND IsClosed = false" : "";
  const q = `
    SELECT Id, Name, StageName, Amount, CloseDate, IsClosed, IsWon, NextStep, OwnerId
      FROM Opportunity
     WHERE AccountId = '${escapeSoql(accountId)}' ${closedFilter}
     ORDER BY CloseDate ASC NULLS LAST
     LIMIT ${limit}`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({
    id: r.Id,
    name: r.Name,
    stage: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate ?? null,
    isClosed: !!r.IsClosed,
    isWon: !!r.IsWon,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
  }));
}

export interface OwnedAccount {
  id: string;
  name: string;
}

export async function fetchAccountsOwnedBy(
  conn: Connection,
  ownerId: string,
  limit = 500
): Promise<OwnedAccount[]> {
  const q = `
    SELECT Id, Name
      FROM Account
     WHERE OwnerId = '${escapeSoql(ownerId)}'
     ORDER BY Name
     LIMIT ${limit}`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({ id: r.Id, name: r.Name }));
}

export async function fetchAccountIdsWithOpenOpp(
  conn: Connection,
  accountIds: string[]
): Promise<Set<string>> {
  const out = new Set<string>();
  if (accountIds.length === 0) return out;
  const ids = accountIds.map((id) => `'${escapeSoql(id)}'`).join(",");
  const q = `
    SELECT AccountId
      FROM Opportunity
     WHERE AccountId IN (${ids}) AND IsClosed = false`;
  const result = await conn.query(q);
  for (const r of result.records as any[]) {
    if (r.AccountId) out.add(r.AccountId);
  }
  return out;
}

export async function fetchPositiveApolloCalls(
  conn: Connection,
  accountIds: string[],
  sinceIso: string,
  subjectPattern: string
): Promise<PositiveApolloCall[]> {
  if (accountIds.length === 0) return [];
  const sinceDate = sinceIso.slice(0, 10);
  const ids = accountIds.map((id) => `'${escapeSoql(id)}'`).join(",");
  const pattern = escapeSoql(subjectPattern);
  const q = `
    SELECT Id, WhatId, OwnerId, Owner.Name, Subject, ActivityDate, CreatedDate, Description
      FROM Task
     WHERE WhatId IN (${ids})
       AND Subject LIKE '${pattern}'
       AND ActivityDate >= ${sinceDate}
     ORDER BY ActivityDate DESC, CreatedDate DESC
     LIMIT 500`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({
    taskId: r.Id,
    accountId: r.WhatId,
    ownerId: r.OwnerId,
    ownerName: r.Owner?.Name ?? null,
    subject: r.Subject ?? "",
    activityDate: r.ActivityDate ?? null,
    createdDate: r.CreatedDate ?? null,
    description: r.Description ?? null,
  }));
}

export interface ContactRow {
  id: string;
  email: string;
  name: string | null;
  title: string | null;
  accountId: string | null;
  accountName: string | null;
}

export async function fetchContactsByEmail(
  conn: Connection,
  emails: string[]
): Promise<ContactRow[]> {
  if (emails.length === 0) return [];
  const lowered = Array.from(new Set(emails.map((e) => e.toLowerCase()).filter(Boolean)));
  const chunks: string[][] = [];
  const CHUNK = 200;
  for (let i = 0; i < lowered.length; i += CHUNK) {
    chunks.push(lowered.slice(i, i + CHUNK));
  }
  const out: ContactRow[] = [];
  for (const batch of chunks) {
    const list = batch.map((e) => `'${escapeSoql(e)}'`).join(",");
    const q = `
      SELECT Id, Email, Name, Title, AccountId, Account.Name
        FROM Contact
       WHERE Email IN (${list})`;
    const result = await conn.query(q);
    for (const r of result.records as any[]) {
      if (!r.Email) continue;
      out.push({
        id: r.Id,
        email: String(r.Email).toLowerCase(),
        name: r.Name ?? null,
        title: r.Title ?? null,
        accountId: r.AccountId ?? null,
        accountName: r.Account?.Name ?? null,
      });
    }
  }
  return out;
}

export interface AccountByDomainRow {
  id: string;
  name: string;
  website: string | null;
}

export async function fetchAccountsByDomain(
  conn: Connection,
  domains: string[]
): Promise<AccountByDomainRow[]> {
  if (domains.length === 0) return [];
  const cleaned = Array.from(
    new Set(domains.map((d) => d.toLowerCase().trim()).filter(Boolean))
  );
  if (cleaned.length === 0) return [];
  const clauses = cleaned
    .map((d) => `Website LIKE '%${escapeSoql(d)}%'`)
    .join(" OR ");
  const q = `
    SELECT Id, Name, Website
      FROM Account
     WHERE ${clauses}
     LIMIT 50`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({
    id: r.Id,
    name: r.Name,
    website: r.Website ?? null,
  }));
}

export async function fetchOpportunityStagePicklist(
  conn: Connection
): Promise<string[]> {
  try {
    const meta = await conn.sobject("Opportunity").describe();
    const stage = (meta.fields as any[]).find((f) => f.name === "StageName");
    const values = stage?.picklistValues ?? [];
    return values
      .filter((v: any) => v.active !== false)
      .map((v: any) => v.value)
      .filter((v: any): v is string => typeof v === "string" && v.length > 0);
  } catch (err: any) {
    console.error(`[sf] describe Opportunity failed:`, err?.message ?? err);
    return [];
  }
}

export async function fetchLastStageChangesForOpps(
  conn: Connection,
  oppIds: string[]
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (oppIds.length === 0) return out;
  const ids = oppIds.map((id) => `'${escapeSoql(id)}'`).join(",");
  const soql = `
    SELECT OpportunityId, CreatedDate
      FROM OpportunityHistory
     WHERE OpportunityId IN (${ids})
     ORDER BY CreatedDate DESC`;
  const result = await conn.query(soql);
  for (const r of result.records as any[]) {
    if (!out.has(r.OpportunityId)) out.set(r.OpportunityId, r.CreatedDate);
  }
  return out;
}
