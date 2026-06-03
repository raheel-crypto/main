import type { AccountRecord, OpportunityRecord } from "@/lib/arr/types";
import type { GapResult } from "@/lib/arr/recompute";

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

function usd(n: number): string {
  return `$${n.toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

export function proposeActions(
  gap: GapResult,
  account: AccountRecord,
  opps: OpportunityRecord[],
): ProposedAction[] {
  const actions: ProposedAction[] = [];

  // 1. Sync Account ARR to §2's expected value.
  //    Covers stale-on-churn (Former Customer expected=0) AND missing-rollup
  //    (Customer with stale or wrong ARR__c). Skip if there's no gap.
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

  // 2. Lock the most recent won opp so Hook stops alerting on it.
  //    Only offer if at least one opp is unlocked.
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
