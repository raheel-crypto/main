import { getSalesforceConnection } from "./client";
import type { AccountRecord, OpportunityRecord } from "@/lib/arr/types";

export async function getAccountWithOpps(
  accountId: string,
): Promise<{ account: AccountRecord; opps: OpportunityRecord[] }> {
  const conn = await getSalesforceConnection();

  const accountQuery = await conn.query<AccountRecord>(
    `SELECT Id, Name, ARR__c, Account_Status__c, Churn_Date__c
     FROM Account WHERE Id = '${accountId}' LIMIT 1`,
  );
  const account = accountQuery.records[0];
  if (!account) throw new Error(`Account ${accountId} not found`);

  const oppsQuery = await conn.query<OpportunityRecord>(
    `SELECT Id, AccountId, Annual_Recurring_Revenue__c, Type, CloseDate, IsWon, Name, ARR_Locked__c
     FROM Opportunity
     WHERE AccountId = '${accountId}' AND IsWon = true
     ORDER BY CloseDate ASC`,
  );

  return { account, opps: oppsQuery.records };
}

export async function getAllCustomerAccountIds(): Promise<string[]> {
  const conn = await getSalesforceConnection();
  const result = await conn.query<{ Id: string }>(
    `SELECT Id FROM Account WHERE Account_Status__c IN ('Customer', 'Former Customer')`,
  );
  return result.records.map((r) => r.Id);
}

export async function rawSoql<T extends Record<string, any> = Record<string, any>>(
  query: string,
): Promise<T[]> {
  const conn = await getSalesforceConnection();
  const result = await conn.query<T>(query);
  return result.records;
}
