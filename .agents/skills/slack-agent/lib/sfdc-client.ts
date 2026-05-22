import { getSFDCAccessToken } from "./sfdc-auth.js";
import type { ApprovalTier, DealContext, SelectedTerm } from "./types.js";

const API_VERSION = "v60.0";

async function sfdcFetch(path: string, init?: RequestInit): Promise<unknown> {
  const { accessToken, instanceUrl } = await getSFDCAccessToken();
  const res = await fetch(`${instanceUrl}/services/data/${API_VERSION}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`SFDC ${init?.method ?? "GET"} ${path} failed: ${res.status} ${text}`);
  }

  if (res.status === 204) return null;
  return res.json();
}

export interface SFDCOpportunity {
  Id: string;
  Name: string;
  StageName: string;
  Amount?: number;
  CloseDate: string;
  AccountId: string;
  Type?: string;
  Segment__c?: string;
  Account?: {
    Id: string;
    Name: string;
    Segment__c?: string;
    Type?: string;
    Industry?: string;
  };
  Owner?: {
    Id: string;
    Name: string;
    Email?: string;
    Slack_User_Id__c?: string;
    Manager?: {
      Id?: string;
      Name?: string;
      Slack_User_Id__c?: string;
    };
  };
}

export async function findOpportunitiesByName(name: string, limit = 10): Promise<SFDCOpportunity[]> {
  const soql = encodeURIComponent(
    selectOpportunityFields() +
      ` FROM Opportunity WHERE Name LIKE '%${escapeSoql(name)}%' AND IsClosed = false ` +
      `ORDER BY CloseDate ASC LIMIT ${limit}`,
  );
  const result = (await sfdcFetch(`/query?q=${soql}`)) as { records: SFDCOpportunity[] };
  return result.records;
}

export async function getOpportunityById(id: string): Promise<SFDCOpportunity | null> {
  const soql = encodeURIComponent(
    selectOpportunityFields() + ` FROM Opportunity WHERE Id = '${escapeSoql(id)}' LIMIT 1`,
  );
  const result = (await sfdcFetch(`/query?q=${soql}`)) as { records: SFDCOpportunity[] };
  return result.records[0] ?? null;
}

export async function resolveOpportunity(nameOrId: string): Promise<{
  status: "found" | "ambiguous" | "not_found";
  opportunity?: SFDCOpportunity;
  matches?: SFDCOpportunity[];
}> {
  if (/^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(nameOrId)) {
    const opp = await getOpportunityById(nameOrId);
    return opp ? { status: "found", opportunity: opp } : { status: "not_found" };
  }

  const opps = await findOpportunitiesByName(nameOrId, 10);
  if (opps.length === 0) return { status: "not_found" };
  if (opps.length > 1) return { status: "ambiguous", matches: opps };
  return { status: "found", opportunity: opps[0] };
}

export function toDealContext(opp: SFDCOpportunity): DealContext {
  return {
    account: {
      id: opp.Account?.Id ?? opp.AccountId,
      name: opp.Account?.Name ?? "(unknown)",
      // Segment__c lives on the Opportunity in this org; fall back to the
      // Account field for older records where it may only be set there.
      segment: opp.Segment__c ?? opp.Account?.Segment__c ?? null,
    },
    opportunity: {
      id: opp.Id,
      name: opp.Name,
      stage: opp.StageName,
      amount: opp.Amount ?? null,
      close_date: opp.CloseDate,
      type: opp.Type ?? null,
      owner_id: opp.Owner?.Id ?? "",
      owner_name: opp.Owner?.Name ?? "(unknown)",
      owner_slack_user_id: opp.Owner?.Slack_User_Id__c ?? null,
      manager_name: opp.Owner?.Manager?.Name ?? null,
      manager_slack_user_id: opp.Owner?.Manager?.Slack_User_Id__c ?? null,
    },
  };
}

function selectOpportunityFields(): string {
  return (
    `SELECT Id, Name, StageName, Amount, CloseDate, AccountId, Type, Segment__c, ` +
    `Account.Id, Account.Name, Account.Segment__c, Account.Type, Account.Industry, ` +
    `Owner.Id, Owner.Name, Owner.Email, Owner.Slack_User_Id__c, ` +
    `Owner.Manager.Id, Owner.Manager.Name, Owner.Manager.Slack_User_Id__c`
  );
}

/**
 * Upsert any sobject by an External ID field. If a record with that External
 * ID exists, it's patched with the supplied fields; otherwise a new record
 * is created. Used by the audit-log path so submission and decision-update
 * writes converge on the same row.
 *
 * https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/dome_upsert.htm
 */
export async function upsertByExternalId(
  sobjectName: string,
  externalIdField: string,
  externalIdValue: string,
  fields: Record<string, unknown>,
): Promise<void> {
  await sfdcFetch(
    `/sobjects/${encodeURIComponent(sobjectName)}/${encodeURIComponent(externalIdField)}/${encodeURIComponent(externalIdValue)}`,
    {
      method: "PATCH",
      body: JSON.stringify(fields),
    },
  );
}

/**
 * Update any Opportunity field. Used by the "Mark Closed Won" path to set
 * StageName. Throws on SFDC errors so the caller can surface validation
 * rule failures, FLS issues, etc. in the Slack thread.
 */
export async function updateOpportunity(
  id: string,
  fields: Record<string, unknown>,
): Promise<void> {
  await sfdcFetch(`/sobjects/Opportunity/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: JSON.stringify(fields),
  });
}

/**
 * Fetch the most recent *approved* Quote_Approval__c for an Opportunity. Used
 * by the signed-order-form trigger so we can find the original Slack thread
 * to reply in.
 */
export async function getLatestApprovedQuoteApproval(
  opportunityId: string,
): Promise<{
  requestId: string;
  slackMessageUrl: string | null;
  raw: Record<string, unknown>;
} | null> {
  // Only consider approvals whose Slack post is still trackable -- the caller
  // wants to reply in that thread. Older / overridden rows with null URLs
  // would just give us a 422 anyway.
  const soql = encodeURIComponent(
    `SELECT Request_Id__c, Slack_Message_Url__c FROM Quote_Approval__c ` +
      `WHERE Opportunity__c = '${escapeSoql(opportunityId)}' ` +
      `AND State__c = 'Approved' ` +
      `AND Slack_Message_Url__c != null AND Slack_Message_Url__c != '' ` +
      `ORDER BY Decision_Made_At__c DESC LIMIT 1`,
  );
  const result = (await sfdcFetch(`/query?q=${soql}`)) as {
    records: Array<Record<string, unknown>>;
  };
  const r = result.records[0];
  if (!r) return null;
  return {
    requestId: getFieldCI(r, "Request_Id__c") ?? "",
    slackMessageUrl: getFieldCI(r, "Slack_Message_Url__c"),
    raw: r,
  };
}

/**
 * Fetch the SelectedTerm snapshot data for a list of Legal_Term__c codes.
 * Called at submit time so the rep's term selections are frozen verbatim into
 * the ApprovalRequest — legal edits to Legal_Term__c.Body__c after submit
 * never reach the generated order form.
 *
 * Drops any code that didn't resolve (inactive, deleted, typo'd by an older
 * LWC build) and logs a warning. Empty input returns [] without an SOQL call.
 */
export async function fetchTermsByCodes(codes: string[]): Promise<SelectedTerm[]> {
  if (codes.length === 0) return [];
  const inList = codes.map((c) => `'${escapeSoql(c)}'`).join(",");
  const soql = encodeURIComponent(
    `SELECT Id, Term_Code__c, Title__c, Body__c, Category__c, ` +
      `Required_Tier__c, Sort_Order__c FROM Legal_Term__c ` +
      `WHERE Term_Code__c IN (${inList}) AND Active__c = true`,
  );
  const result = (await sfdcFetch(`/query?q=${soql}`)) as {
    records: Array<Record<string, unknown>>;
  };
  const resolved: SelectedTerm[] = result.records.map((r) => ({
    sfdc_id: getFieldCI(r, "Id") ?? "",
    term_code: getFieldCI(r, "Term_Code__c") ?? "",
    title: getFieldCI(r, "Title__c") ?? "",
    body: getFieldCI(r, "Body__c") ?? "",
    category: getFieldCI(r, "Category__c") ?? "",
    required_tier: normalizeTier(getFieldCI(r, "Required_Tier__c")),
    sort_order: Number(getFieldCI(r, "Sort_Order__c") ?? 0),
  }));

  if (resolved.length !== codes.length) {
    const resolvedCodes = new Set(resolved.map((t) => t.term_code));
    const missing = codes.filter((c) => !resolvedCodes.has(c));
    console.warn(
      `[fetchTermsByCodes] dropped ${missing.length} unresolved term code(s): ${missing.join(", ")}`,
    );
  }

  return resolved.sort((a, b) => a.sort_order - b.sort_order);
}

function normalizeTier(raw: string | null): ApprovalTier {
  const t = raw?.trim().toLowerCase() ?? "";
  if (t === "deal_desk" || t === "deal desk") return "deal_desk";
  if (t === "pod_leader" || t === "pod leader") return "pod_leader";
  if (t === "james") return "james";
  return "auto";
}

/**
 * Case-insensitive field lookup. SFDC returns response keys in the canonical
 * casing the field was created with, which may differ from how we wrote the
 * SOQL (case is preserved on read even though SOQL itself is case-insensitive).
 * e.g. a field created as `Slack_Message_URL__c` reads at `r["Slack_Message_URL__c"]`,
 * not `r["Slack_Message_Url__c"]`.
 */
export function getFieldCI(record: Record<string, unknown>, name: string): string | null {
  const target = name.toLowerCase();
  for (const [k, v] of Object.entries(record)) {
    if (k.toLowerCase() === target) return typeof v === "string" ? v : v == null ? null : String(v);
  }
  return null;
}

/**
 * Slack archive URLs collapse the message ts dot: `1234567890.123456` becomes
 * `p1234567890123456` in the URL. Reconstruct the {channel, ts} we need to
 * post a threaded reply.
 */
export function parseSlackArchiveUrl(
  url: string | null | undefined,
): { channel: string; ts: string } | null {
  if (!url) return null;
  const m = /\/archives\/([^/]+)\/p(\d{7,})/.exec(url);
  if (!m) return null;
  const channel = m[1]!;
  const tsNoDot = m[2]!;
  return { channel, ts: `${tsNoDot.slice(0, -6)}.${tsNoDot.slice(-6)}` };
}

function escapeSoql(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}
