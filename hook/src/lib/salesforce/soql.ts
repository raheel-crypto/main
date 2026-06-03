import { getSalesforceConnection } from "./client";
import type {
  AccountRecord,
  OpportunityRecord,
  OrderFormExtraction,
} from "@/lib/arr/types";

export async function getAccountWithOpps(
  accountId: string,
): Promise<{
  account: AccountRecord;
  opps: OpportunityRecord[];
  ofes: OrderFormExtraction[];
}> {
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

  const opps = oppsQuery.records;
  const ofes = opps.length > 0 ? await getOfesForOpps(opps.map((o) => o.Id)) : [];

  return { account, opps, ofes };
}

export async function getOfesForOpps(
  oppIds: string[],
): Promise<OrderFormExtraction[]> {
  if (oppIds.length === 0) return [];
  const conn = await getSalesforceConnection();
  const inList = oppIds.map((id) => `'${id}'`).join(",");
  const query = await conn.query<OrderFormExtraction>(
    `SELECT Id, Opportunity__c, Annual_Recurring_Revenue__c, Type__c, Is_Amendment__c,
            Total_Contract_Value__c, Contract_Start_Date__c, Contract_End_Date__c,
            Seat_Licenses__c, Content_Document_Id__c, File_Name__c,
            Extraction_Status__c, Extracted_At__c
     FROM Order_Form_Extraction__c
     WHERE Opportunity__c IN (${inList})
     ORDER BY Extracted_At__c DESC`,
  );
  return query.records;
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
