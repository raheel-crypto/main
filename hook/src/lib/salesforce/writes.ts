import { getSalesforceConnection } from "./client";

export async function updateAccountArr(
  accountId: string,
  newArr: number,
): Promise<void> {
  const conn = await getSalesforceConnection();
  await conn.sobject("Account").update({ Id: accountId, ARR__c: newArr });
}

export async function setOppLocked(
  opportunityId: string,
  locked: boolean,
): Promise<void> {
  const conn = await getSalesforceConnection();
  await conn
    .sobject("Opportunity")
    .update({ Id: opportunityId, ARR_Locked__c: locked });
}
