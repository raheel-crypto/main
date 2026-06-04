import type { AccountRecord, OpportunityRecord, OpportunityType } from "@/lib/arr/types";
import type { GapResult } from "@/lib/arr/recompute";
import type { OfeGap } from "@/lib/arr/cross_validate";

export type ActionKind = "sync_account_arr" | "lock_opp";

export interface ProposedAction {
  kind: ActionKind;
  accountId: string | null;
  opportunityId: string | null;
  targetObject: "Account" | "Opportunity";
  targetField: string;
  currentValue: string;
  proposedValue: string;
  buttonText: string;
  buttonStyle?: "primary" | "danger";
  confirmText: string;
  reason: string;
}

export interface Recommendation {
  field: string;
  recordName: string;
  currentValue: string;
  proposedValue: string;
}

export interface AutoApplyDecision {
  eligible: boolean;
  reason: string;
}

const AUTO_SAFE_TYPES: ReadonlySet<OpportunityType> = new Set([
  "New Business",
  "Pilot",
  "Renewal",
]);

function usd(n: number): string {
  return `$${n.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

// Determines whether Hook can safely write the §2-expected ARR without human
// approval. Conservative on purpose: auto only when every signal lines up.
export function isAutoApplyEligible(
  gap: GapResult,
  account: AccountRecord,
  opps: OpportunityRecord[],
  ofeGaps: OfeGap[],
): AutoApplyDecision {
  if (gap.matches) {
    return { eligible: false, reason: "no gap to correct" };
  }

  if (opps.some((o) => o.ARR_Locked__c)) {
    return { eligible: false, reason: "one or more opps have ARR_Locked__c = true" };
  }

  if (ofeGaps.length > 0) {
    return {
      eligible: false,
      reason: `${ofeGaps.length} contract-vs-opp disagreement(s) need review first`,
    };
  }

  // Former Customer with stale ARR — deterministic fix (zero it). Safe to auto.
  if (
    account.Account_Status__c === "Former Customer" &&
    (gap.storedArr ?? 0) > 0 &&
    gap.result.expectedArr === 0
  ) {
    return { eligible: true, reason: "stale-on-churn: zero the ARR" };
  }

  // Prospect should never carry ARR; status gate handles that already so this
  // branch is defensive.
  if (account.Account_Status__c !== "Customer") {
    return {
      eligible: false,
      reason: `account status is ${account.Account_Status__c}, not Customer`,
    };
  }

  // Customer: auto only if every won opp is in the deterministic set
  // (New Business, Pilot, Renewal). Upsells, Downsells, Contract Restructures,
  // and Debookings all carry semantic nuance that warrants a human eye.
  const unsafe = opps.filter((o) => !AUTO_SAFE_TYPES.has(o.Type));
  if (unsafe.length > 0) {
    const kinds = [...new Set(unsafe.map((o) => o.Type))].sort().join(", ");
    return {
      eligible: false,
      reason: `account contains ${kinds} opp(s) — needs human approval`,
    };
  }

  return {
    eligible: true,
    reason: `all ${opps.length} won opp(s) are deterministic (New Business / Pilot / Renewal)`,
  };
}

// Structured field-by-field "current → proposed" recommendations for the
// Slack post. Today only Account.ARR__c is recommended; once OFE populates
// Incremental_ARR__c, opp-level recommendations will join the list.
export function buildRecommendations(
  gap: GapResult,
  account: AccountRecord,
): Recommendation[] {
  const recs: Recommendation[] = [];

  if (!gap.matches) {
    recs.push({
      field: "Account.ARR__c",
      recordName: account.Name,
      currentValue: usd(gap.storedArr),
      proposedValue: usd(gap.result.expectedArr),
    });
  }

  return recs;
}

export function proposeActions(
  gap: GapResult,
  account: AccountRecord,
  opps: OpportunityRecord[],
): ProposedAction[] {
  const actions: ProposedAction[] = [];

  if (!gap.matches) {
    const isChurnFix =
      account.Account_Status__c === "Former Customer" &&
      (gap.storedArr ?? 0) > 0 &&
      gap.result.expectedArr === 0;

    actions.push({
      kind: "sync_account_arr",
      accountId: account.Id,
      opportunityId: null,
      targetObject: "Account",
      targetField: "ARR__c",
      currentValue: String(gap.storedArr),
      proposedValue: String(gap.result.expectedArr),
      buttonText: isChurnFix
        ? `Zero ARR (churned)`
        : `Sync ARR to ${usd(gap.result.expectedArr)}`,
      buttonStyle: isChurnFix ? "danger" : "primary",
      confirmText: isChurnFix
        ? `${account.Name} is a Former Customer with stale ARR of ${usd(gap.storedArr)}.\n\nSet Account.ARR__c to $0?\n\nThe write will be attributed to your Slack user and logged.`
        : `Set ${account.Name} Account.ARR__c from ${usd(gap.storedArr)} to ${usd(gap.result.expectedArr)}?\n\nThe write will be attributed to your Slack user and logged.`,
      reason: isChurnFix ? "Stale-on-churn (§6.6 stale-on-churn)" : "Sync to §2 expected",
    });
  }

  const unlocked = opps.filter((o) => !o.ARR_Locked__c);
  if (unlocked.length > 0) {
    const latest = unlocked.reduce((a, b) =>
      a.CloseDate > b.CloseDate ? a : b,
    );
    actions.push({
      kind: "lock_opp",
      accountId: account.Id,
      opportunityId: latest.Id,
      targetObject: "Opportunity",
      targetField: "ARR_Locked__c",
      currentValue: "false",
      proposedValue: "true",
      buttonText: `Lock "${latest.Name ?? latest.Id}"`,
      confirmText: `Set ARR_Locked__c = true on "${latest.Name ?? latest.Id}"?\n\nHook will keep reporting on this account but will not propose write actions on this specific opp.\n\nThe write will be attributed to your Slack user and logged.`,
      reason: "Silence future Hook proposals on this opp",
    });
  }

  return actions;
}
