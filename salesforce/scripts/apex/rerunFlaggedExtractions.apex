// =============================================================================
// Re-run flagged Order Form Extractions
// =============================================================================
// Re-extracts every Opportunity with an OFE checked Rerun__c = true, reading the
// opp's CURRENT documents. Each new row links to the flagged one (Supersedes__c)
// and takes over as current; the flag then clears itself. The flagged rows are
// KEPT as version history (they are no longer deleted). A rerun that fails
// (API / parse error) leaves the flag set so the next run retries it.
//
// How to use:
//   1. In an Order Form Extraction list view, check Rerun on the rows that
//      didn't extract properly (mass-edit / inline edit).
//   2. Run:
//        sf apex run --target-org rogo --file scripts/apex/rerunFlaggedExtractions.apex
//      (or paste into Dev Console -> Execute Anonymous)
//   3. Watch Setup -> Apex Jobs (OrderFormBackfillBatch). One unattended pass,
//      no 50-per-run cap.
// =============================================================================

Integer flagged = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Rerun__c = true AND Opportunity__c != null];
if (flagged == 0) {
    System.debug('--- Nothing flagged Rerun__c = true. Done.');
    return;
}
Id jobId = OrderFormBackfillBatch.runRerunFlagged();
System.debug('--- ' + flagged + ' flagged row(s); started OrderFormBackfillBatch ' + jobId
    + '. Monitor in Setup -> Apex Jobs. Flags clear as each rerun becomes current.');
