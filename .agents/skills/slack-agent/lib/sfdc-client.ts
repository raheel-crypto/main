import { getSFDCAccessToken } from "./sfdc-auth.js";
import type { DealContext } from "./types.js";

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
  Account?: {
    Id: string;
    Name: string;
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
      // Using Account.Type as Segment. Swap to a custom field (e.g. Segment__c)
      // if the org has one and update selectOpportunityFields() accordingly.
      segment: opp.Account?.Type ?? null,
    },
    opportunity: {
      id: opp.Id,
      name: opp.Name,
      stage: opp.StageName,
      amount: opp.Amount ?? null,
      close_date: opp.CloseDate,
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
    `SELECT Id, Name, StageName, Amount, CloseDate, AccountId, ` +
    `Account.Id, Account.Name, Account.Type, Account.Industry, ` +
    `Owner.Id, Owner.Name, Owner.Email, Owner.Slack_User_Id__c, ` +
    `Owner.Manager.Id, Owner.Manager.Name, Owner.Manager.Slack_User_Id__c`
  );
}

function escapeSoql(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}
