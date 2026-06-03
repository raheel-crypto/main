import type {
  AccountRecord,
  ArrEvent,
  EventType,
  OpportunityRecord,
  OpportunityType,
  RecomputeResult,
} from "./types";

const TYPE_PRIORITY: Record<OpportunityType, number> = {
  Renewal: 0,
  "Contract Restructure": 1,
  "New Business": 2,
  Upsell: 3,
  Downsell: 3,
  Debooking: 3,
  Pilot: 4,
};

function compareOpps(a: OpportunityRecord, b: OpportunityRecord): number {
  const dateCmp = a.CloseDate.localeCompare(b.CloseDate);
  if (dateCmp !== 0) return dateCmp;
  const priorityCmp = TYPE_PRIORITY[a.Type] - TYPE_PRIORITY[b.Type];
  if (priorityCmp !== 0) return priorityCmp;
  return a.Id.localeCompare(b.Id);
}

export function recomputeAccount(
  account: AccountRecord,
  opps: OpportunityRecord[],
): RecomputeResult {
  const wonOpps = opps
    .filter((o) => o.IsWon && o.AccountId === account.Id)
    .slice()
    .sort(compareOpps);

  const events: ArrEvent[] = [];
  let running = 0;
  let lastRenewalDate: string | null = null;
  let sequence = 0;

  for (const opp of wonOpps) {
    const arr = opp.Annual_Recurring_Revenue__c ?? 0;
    let delta = 0;
    let eventType: EventType;
    // Match the existing backfill convention: the opp Name is the most useful
    // human-readable note. The §2 rule is implicit in eventType + delta.
    const note = opp.Name ?? "";

    switch (opp.Type) {
      case "New Business":
        delta = arr;
        eventType = "New Business";
        break;
      case "Upsell":
        delta = arr;
        eventType = "Upsell";
        break;
      case "Pilot":
        delta = arr;
        eventType = "Pilot";
        break;
      case "Downsell":
      case "Debooking":
        delta = arr;
        eventType = opp.Type;
        break;
      case "Renewal":
        delta = arr - running;
        eventType = "Renewal (rebase)";
        lastRenewalDate = opp.CloseDate;
        break;
      case "Contract Restructure":
        if (lastRenewalDate !== null && opp.CloseDate === lastRenewalDate) {
          delta = 0;
        } else {
          delta = arr;
        }
        eventType = "Restructure (delta/absorbed)";
        break;
    }

    running += delta;
    sequence += 1;

    events.push({
      opportunityId: opp.Id,
      eventDate: opp.CloseDate,
      eventType,
      delta,
      running,
      sequence,
      note,
      isSynthetic: false,
    });
  }

  if (account.Account_Status__c === "Former Customer" && running > 0) {
    sequence += 1;
    events.push({
      opportunityId: null,
      eventDate: account.Churn_Date__c ?? new Date().toISOString().slice(0, 10),
      eventType: "Churn",
      delta: -running,
      running: 0,
      sequence,
      note: "(Account churned)",
      isSynthetic: true,
    });
    running = 0;
  }

  const expectedArr =
    account.Account_Status__c === "Customer" ? running : 0;

  return {
    accountId: account.Id,
    expectedArr,
    events,
    status: account.Account_Status__c,
  };
}

export interface GapResult {
  account: AccountRecord;
  result: RecomputeResult;
  storedArr: number;
  gap: number;
  matches: boolean;
}

export function diffVsStored(
  account: AccountRecord,
  opps: OpportunityRecord[],
  threshold = 1,
): GapResult {
  const result = recomputeAccount(account, opps);
  const storedArr = account.ARR__c ?? 0;
  const gap = storedArr - result.expectedArr;
  return {
    account,
    result,
    storedArr,
    gap,
    matches: Math.abs(gap) < threshold,
  };
}
