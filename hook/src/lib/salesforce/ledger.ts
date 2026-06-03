import { getSalesforceConnection } from "./client";
import type { ArrEvent, EventType, RecomputeResult } from "@/lib/arr/types";

// The Churn picklist value in this org has trailing tabs from an admin entry
// quirk. Picklists require exact string match on write, so encode it here.
const SF_CHURN_PICKLIST_VALUE = "Churn\t\t\t";

function toSfPicklist(eventType: EventType): string {
  if (eventType === "Churn") return SF_CHURN_PICKLIST_VALUE;
  return eventType;
}

interface SyncSummary {
  accountId: string;
  deleted: number;
  inserted: number;
}

// Replaces all ARR_Event__c rows for one account with the freshly recomputed
// set. Idempotent because §2 is deterministic — re-running produces the same
// events. Delete-then-insert keeps the writeback simple and avoids needing
// an external ID for upserts.
//
// Failure modes:
//   - delete succeeds, insert fails -> account has no events until next run.
//     Logged and surfaced; next weekly run reconciles automatically.
//   - delete fails -> nothing is written, prior state preserved.
export async function syncAccountEvents(
  accountId: string,
  recompute: RecomputeResult,
): Promise<SyncSummary> {
  const conn = await getSalesforceConnection();

  const existing = await conn.query<{ Id: string }>(
    `SELECT Id FROM ARR_Event__c WHERE Account__c = '${accountId}'`,
  );
  const existingIds = existing.records.map((r) => r.Id);

  if (existingIds.length > 0) {
    await conn.sobject("ARR_Event__c").del(existingIds);
  }

  const inserts = recompute.events.map((ev: ArrEvent) => ({
    Account__c: accountId,
    Opportunity__c: ev.opportunityId,
    Event_Date__c: ev.eventDate,
    Event_Type__c: toSfPicklist(ev.eventType),
    Delta_ARR__c: ev.delta,
    Running_ARR__c: ev.running,
    Sequence__c: ev.sequence,
    Note__c: ev.note.slice(0, 255),
  }));

  if (inserts.length > 0) {
    await conn.sobject("ARR_Event__c").create(inserts);
  }

  return {
    accountId,
    deleted: existingIds.length,
    inserted: inserts.length,
  };
}
