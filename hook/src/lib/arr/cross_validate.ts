import type { OpportunityRecord, OrderFormExtraction } from "./types";

export type OfeGapCategory =
  | "Contract-ARR mismatch"
  | "Type mismatch vs contract"
  | "Mistyped amendment";

export interface OfeGap {
  oppId: string;
  oppName: string;
  category: OfeGapCategory;
  detail: string;
}

// Cross-validates each opp against the latest successful OFE row pointing at
// it. Surfaces:
//   - ARR disagreements between Opp.Annual_Recurring_Revenue__c and contract
//   - Type disagreements between Opp.Type and contract Type__c
//   - Amendments mistyped as New Business (per §6.6c)
//
// Opps without an OFE are not flagged — many historical opps pre-date the
// OFE pipeline. The duplicate-via-shared-document signal is intentionally
// not implemented here yet; come back to it in a follow-up.
export function crossValidate(
  opps: OpportunityRecord[],
  ofes: OrderFormExtraction[],
  threshold = 1,
): OfeGap[] {
  // Build a map of opp ID -> most recent successful OFE
  const latestOfeByOpp = new Map<string, OrderFormExtraction>();
  for (const ofe of ofes) {
    if (!ofe.Opportunity__c) continue;
    if (ofe.Extraction_Status__c !== "Success") continue;
    const existing = latestOfeByOpp.get(ofe.Opportunity__c);
    if (
      !existing ||
      (ofe.Extracted_At__c ?? "") > (existing.Extracted_At__c ?? "")
    ) {
      latestOfeByOpp.set(ofe.Opportunity__c, ofe);
    }
  }

  const gaps: OfeGap[] = [];

  for (const opp of opps) {
    const ofe = latestOfeByOpp.get(opp.Id);
    if (!ofe) continue;

    const oppName = opp.Name ?? opp.Id;

    // 1. ARR mismatch — only flag when both sides have values
    const oppArr = opp.Annual_Recurring_Revenue__c;
    const ofeArr = ofe.Annual_Recurring_Revenue__c;
    if (oppArr != null && ofeArr != null && Math.abs(oppArr - ofeArr) >= threshold) {
      gaps.push({
        oppId: opp.Id,
        oppName,
        category: "Contract-ARR mismatch",
        detail: `Opp ARR ${oppArr} vs contract ARR ${ofeArr} (Δ ${ofeArr - oppArr})`,
      });
    }

    // 2. Type mismatch
    if (ofe.Type__c && opp.Type && ofe.Type__c !== opp.Type) {
      gaps.push({
        oppId: opp.Id,
        oppName,
        category: "Type mismatch vs contract",
        detail: `Opp Type "${opp.Type}" vs contract Type "${ofe.Type__c}"`,
      });
    }

    // 3. Amendments mistyped as New Business
    if (ofe.Is_Amendment__c && opp.Type === "New Business") {
      gaps.push({
        oppId: opp.Id,
        oppName,
        category: "Mistyped amendment",
        detail:
          "Contract is an amendment (Is_Amendment=true) but opp Type is New Business. Amendments are typically Upsells or Contract Restructures.",
      });
    }
  }

  return gaps;
}

export function formatOfeGapsForPrompt(gaps: OfeGap[]): string {
  if (gaps.length === 0) return "";
  const lines = gaps.map(
    (g) => `  - [${g.category}] ${g.oppName} (${g.oppId}): ${g.detail}`,
  );
  return `\n\nContract-vs-opp validation (Order_Form_Extraction__c) surfaced ${gaps.length} OFE-based gap(s):\n${lines.join("\n")}\n\nWhen explaining the §2 reconciliation gap, cite any OFE gap(s) above if they are relevant to the same opportunity or account, since the signed contract is the source of truth for ARR and Type.`;
}
