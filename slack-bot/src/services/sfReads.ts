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

export interface OppNameMatch {
  id: string;
  name: string;
  accountId: string;
  accountName: string;
  stage: string;
  amount: number | null;
  closeDate: string | null;
  isClosed: boolean;
  ownerId: string;
  ownerName: string | null;
}

/**
 * Fuzzy-name lookup for an Opportunity. Prefers opps owned by `ownerSfUserId`
 * when provided, then opens up to org-wide. Caller decides how to handle
 * multiple results (disambiguation card vs friendly error).
 */
export async function findOpportunitiesByName(
  conn: Connection,
  query: string,
  ownerSfUserId?: string,
  limit = 6
): Promise<OppNameMatch[]> {
  const owned = ownerSfUserId
    ? await runOppNameQuery(conn, query, ownerSfUserId, limit)
    : [];
  if (owned.length > 0) return owned;
  return runOppNameQuery(conn, query, undefined, limit);
}

async function runOppNameQuery(
  conn: Connection,
  query: string,
  ownerSfUserId: string | undefined,
  limit: number
): Promise<OppNameMatch[]> {
  const ownerClause = ownerSfUserId
    ? `AND OwnerId = '${escapeSoql(ownerSfUserId)}'`
    : "";
  const q = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           IsClosed, OwnerId, Owner.Name
      FROM Opportunity
     WHERE Name LIKE '%${escapeSoql(query)}%' ${ownerClause}
     ORDER BY IsClosed ASC, CloseDate ASC NULLS LAST
     LIMIT ${limit}`;
  const result = await conn.query(q);
  return (result.records as any[]).map((r) => ({
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    stage: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate ?? null,
    isClosed: !!r.IsClosed,
    ownerId: r.OwnerId,
    ownerName: r.Owner?.Name ?? null,
  }));
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

export async function fetchEarliestStageEntry(
  conn: Connection,
  opportunityId: string,
  stagePrefix: string
): Promise<string | null> {
  // OpportunityHistory logs a row each time the opp is modified, with the
  // StageName at that moment. The earliest row where StageName starts with
  // `stagePrefix` is when the opp first entered that stage.
  // Soql LIKE matching escapes %; we pass the prefix literally so callers
  // control the wildcard placement.
  const soql = `
    SELECT CreatedDate, StageName
      FROM OpportunityHistory
     WHERE OpportunityId = '${escapeSoql(opportunityId)}'
       AND StageName LIKE '${escapeSoql(stagePrefix)}%'
     ORDER BY CreatedDate ASC
     LIMIT 1`;
  try {
    const result = await conn.query(soql);
    const row = (result.records as any[])[0];
    return row?.CreatedDate ?? null;
  } catch (err: any) {
    console.warn(
      `[red-team] fetchEarliestStageEntry(${opportunityId}, ${stagePrefix}) failed:`,
      err?.message ?? err
    );
    return null;
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

let _queryableOpportunityFieldsCache: Set<string> | null = null;

async function getQueryableOpportunityFields(
  conn: Connection
): Promise<Set<string>> {
  if (_queryableOpportunityFieldsCache) return _queryableOpportunityFieldsCache;
  const meta: any = await conn.describe("Opportunity");
  const set = new Set<string>();
  for (const f of (meta?.fields ?? []) as Array<{ name: string }>) {
    if (f?.name) set.add(f.name);
  }
  _queryableOpportunityFieldsCache = set;
  return set;
}

const OPPORTUNITY_CORE_FIELDS = [
  "Id",
  "Name",
  "AccountId",
  "Account.Name",
  "Account.Industry",
  "Account.Website",
  "StageName",
  "Amount",
  "CloseDate",
  "NextStep",
  "OwnerId",
  "Owner.Name",
  "Owner.Email",
  "Type",
  "IsClosed",
  "CreatedDate",
] as const;

export interface OpportunityWithCustomFields {
  id: string;
  name: string;
  accountId: string;
  accountName: string;
  accountIndustry: string | null;
  accountWebsite: string | null;
  stageName: string;
  type: string | null;
  amount: number | null;
  closeDate: string | null;
  nextStep: string | null;
  ownerId: string;
  ownerName: string | null;
  ownerEmail: string | null;
  isClosed: boolean;
  createdDate: string | null;
  customFields: Record<string, unknown>;
}

export async function fetchOpportunityWithCustomFields(
  conn: Connection,
  opportunityId: string,
  customFieldApiNames: string[]
): Promise<OpportunityWithCustomFields | null> {
  // Describe Opportunity once per cold start and filter the requested fields
  // down to those that actually exist in this org. One bad field name in the
  // SELECT would cause SF to reject the whole query with INVALID_FIELD —
  // pre-filtering avoids dropping the whole custom-field set on one typo.
  const queryable = await getQueryableOpportunityFields(conn);
  const requested = customFieldApiNames.filter((f) =>
    /^[A-Za-z0-9_]+$/.test(f) && !OPPORTUNITY_CORE_FIELDS.includes(f as any)
  );
  const known = requested.filter((f) => queryable.has(f));
  const dropped = requested.filter((f) => !queryable.has(f));
  if (dropped.length > 0) {
    console.warn(
      `[red-team] Opportunity is missing fields, skipping: ${dropped.join(", ")}`
    );
  }
  const fields = [...OPPORTUNITY_CORE_FIELDS, ...known];
  const soql = `
    SELECT ${fields.join(", ")}
      FROM Opportunity
     WHERE Id = '${escapeSoql(opportunityId)}'
     LIMIT 1`;
  let result;
  try {
    result = await conn.query(soql);
  } catch (err: any) {
    // Defensive fallback — should be unreachable after the describe filter,
    // but keeps the intel pack assembling if describe metadata is stale.
    const message = String(err?.message ?? err);
    if (/INVALID_FIELD|No such column/i.test(message)) {
      console.error(
        `[red-team] custom field query failed after describe filter (${message}); falling back to core fields`
      );
      const coreOnly = `
        SELECT ${OPPORTUNITY_CORE_FIELDS.join(", ")}
          FROM Opportunity
         WHERE Id = '${escapeSoql(opportunityId)}'
         LIMIT 1`;
      result = await conn.query(coreOnly);
    } else {
      throw err;
    }
  }
  const r = (result.records as any[])[0];
  if (!r) return null;
  const customFields: Record<string, unknown> = {};
  for (const name of known) {
    if (Object.prototype.hasOwnProperty.call(r, name)) {
      customFields[name] = r[name];
    }
  }
  return {
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    accountIndustry: r.Account?.Industry ?? null,
    accountWebsite: r.Account?.Website ?? null,
    stageName: r.StageName,
    type: r.Type ?? null,
    amount: typeof r.Amount === "number" ? r.Amount : r.Amount ?? null,
    closeDate: r.CloseDate ?? null,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
    ownerName: r.Owner?.Name ?? null,
    ownerEmail: r.Owner?.Email ?? null,
    isClosed: !!r.IsClosed,
    createdDate: r.CreatedDate ?? null,
    customFields,
  };
}

export interface OpportunityFieldHistoryRow {
  field: string;
  oldValue: string | null;
  newValue: string | null;
  changedAt: string;
}

/**
 * Pull recent field-level changes from `OpportunityFieldHistory`. Some orgs
 * gate this object; callers should fall back to snapshot-diffing if this
 * throws or returns empty.
 */
export async function fetchOpportunityFieldHistory(
  conn: Connection,
  opportunityId: string,
  sinceIso: string,
  fields?: string[]
): Promise<OpportunityFieldHistoryRow[]> {
  const fieldClause =
    fields && fields.length > 0
      ? `AND Field IN (${fields
          .filter((f) => /^[A-Za-z0-9_]+$/.test(f))
          .map((f) => `'${f}'`)
          .join(",")})`
      : "";
  const soql = `
    SELECT Field, OldValue, NewValue, CreatedDate
      FROM OpportunityFieldHistory
     WHERE OpportunityId = '${escapeSoql(opportunityId)}'
       AND CreatedDate >= ${sinceIso}
       ${fieldClause}
     ORDER BY CreatedDate DESC
     LIMIT 200`;
  const result = await conn.query(soql);
  const rows: OpportunityFieldHistoryRow[] = [];
  for (const r of result.records as any[]) {
    rows.push({
      field: r.Field,
      oldValue:
        r.OldValue == null
          ? null
          : typeof r.OldValue === "object"
            ? JSON.stringify(r.OldValue)
            : String(r.OldValue),
      newValue:
        r.NewValue == null
          ? null
          : typeof r.NewValue === "object"
            ? JSON.stringify(r.NewValue)
            : String(r.NewValue),
      changedAt: r.CreatedDate,
    });
  }
  return rows;
}

interface GongCallTopOpportunity {
  opportunityId: string;
  callIds: string[];
}

/**
 * For a list of Gong call ids, find the Salesforce Opportunity each one is
 * attached to (via the Gong-Salesforce sync's standard custom field
 * `Gong__Gong_Call_Id__c` on Task records or directly on Opportunity).
 *
 * Returns a map of callId → opportunityId. Empty when no association exists.
 *
 * Falls back to an empty map if the org doesn't have the Gong SF package
 * installed (the SOQL returns INVALID_FIELD).
 */
export async function fetchOppIdsForGongCalls(
  conn: Connection,
  callIds: string[]
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (callIds.length === 0) return out;
  const ids = callIds.map((id) => `'${escapeSoql(id)}'`).join(",");
  const soql = `
    SELECT WhatId, Gong__Gong_Call_Id__c
      FROM Task
     WHERE Gong__Gong_Call_Id__c IN (${ids})
       AND WhatId != null
     ORDER BY CreatedDate DESC`;
  try {
    const result = await conn.query(soql);
    for (const r of result.records as any[]) {
      const cid = r.Gong__Gong_Call_Id__c;
      const what = r.WhatId;
      if (cid && what && typeof what === "string" && what.startsWith("006")) {
        if (!out.has(cid)) out.set(cid, what);
      }
    }
  } catch (err: any) {
    const message = String(err?.message ?? err);
    if (!/INVALID_FIELD|No such column/i.test(message)) throw err;
  }
  return out;
}

export async function fetchOppsForOwnerByStage(
  conn: Connection,
  ownerId: string,
  stageAllowlist: string[],
  limit = 100
): Promise<{ id: string; stageName: string }[]> {
  if (stageAllowlist.length === 0) return [];
  const stageClause = stageAllowlist
    .map((s) => `'${escapeSoql(s)}'`)
    .join(",");
  const soql = `
    SELECT Id, StageName
      FROM Opportunity
     WHERE OwnerId = '${escapeSoql(ownerId)}'
       AND IsClosed = false
       AND StageName IN (${stageClause})
     ORDER BY CloseDate ASC NULLS LAST
     LIMIT ${limit}`;
  const result = await conn.query(soql);
  return (result.records as any[]).map((r) => ({
    id: r.Id,
    stageName: r.StageName,
  }));
}

export interface AtRiskOpportunity {
  id: string;
  name: string;
  accountId: string;
  accountName: string;
  stage: string;
  amount: number | null;
  closeDate: string | null;
  type: string | null;
  nextStep: string | null;
  lastActivityDate: string | null;
  daysToClose: number | null;
  daysSinceActivity: number | null;
  reason: "renewal_approaching" | "stalled" | "both";
}

/**
 * Pull renewals approaching close AND stalled opps for a single rep, classified
 * by reason. One SOQL call. Drops any opp that's already closed.
 *
 * `lookaheadDays` controls the renewal window; `stallDays` controls the stall
 * threshold. Both default from constants. `excludeOppIds` is the set of opps
 * we already surfaced today (e.g., the standup's main opp list) so we don't
 * double-DM.
 */
export async function fetchAtRiskOpportunities(
  conn: Connection,
  ownerSfUserId: string,
  opts: {
    lookaheadDays: number;
    stallDays: number;
    excludeOppIds?: Set<string>;
  }
): Promise<AtRiskOpportunity[]> {
  // SOQL `NEXT_N_DAYS:n` only matches the [today, today+n] window, which is
  // exactly what we want for renewals. `LAST_N_DAYS:n` matches [today-n, today]
  // — we want LastActivityDate OLDER than that for "stalled", so we use
  // `< LAST_N_DAYS:n` semantics (i.e., LastActivityDate < today - n).
  const soql = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           Type, NextStep, LastActivityDate
      FROM Opportunity
     WHERE OwnerId = '${escapeSoql(ownerSfUserId)}'
       AND IsClosed = false
       AND (
         (CloseDate <= NEXT_N_DAYS:${opts.lookaheadDays}
           AND (Type LIKE '%Renewal%' OR StageName LIKE '%Renewal%')
         )
         OR (LastActivityDate = null
           OR LastActivityDate < LAST_N_DAYS:${opts.stallDays}
         )
       )
     ORDER BY CloseDate ASC NULLS LAST
     LIMIT 100`;
  const result = await conn.query(soql);
  const exclude = opts.excludeOppIds ?? new Set<string>();
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);

  const out: AtRiskOpportunity[] = [];
  for (const r of result.records as any[]) {
    if (exclude.has(r.Id)) continue;
    const close = r.CloseDate ? new Date(r.CloseDate) : null;
    const lastAct = r.LastActivityDate ? new Date(r.LastActivityDate) : null;
    const daysToClose = close
      ? Math.round((close.getTime() - today.getTime()) / 86_400_000)
      : null;
    const daysSinceActivity = lastAct
      ? Math.round((today.getTime() - lastAct.getTime()) / 86_400_000)
      : null;
    const typeOrStage = `${r.Type ?? ""} ${r.StageName ?? ""}`.toLowerCase();
    const isRenewal =
      /renewal/.test(typeOrStage) &&
      daysToClose != null &&
      daysToClose >= 0 &&
      daysToClose <= opts.lookaheadDays;
    const isStalled =
      lastAct == null || (daysSinceActivity ?? 0) >= opts.stallDays;
    const reason: AtRiskOpportunity["reason"] = isRenewal && isStalled
      ? "both"
      : isRenewal
        ? "renewal_approaching"
        : "stalled";
    out.push({
      id: r.Id,
      name: r.Name,
      accountId: r.AccountId,
      accountName: r.Account?.Name ?? "",
      stage: r.StageName,
      amount: r.Amount ?? null,
      closeDate: r.CloseDate ?? null,
      type: r.Type ?? null,
      nextStep: r.NextStep ?? null,
      lastActivityDate: r.LastActivityDate ?? null,
      daysToClose,
      daysSinceActivity,
      reason,
    });
  }
  return out;
}
