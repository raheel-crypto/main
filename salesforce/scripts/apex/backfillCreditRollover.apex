// =============================================================================
// Backfill credit rollover on every extraction, then on the contracts
// =============================================================================
// Extractions made before credit rollover was added have no answer. This
// re-reads each such deal's files with a FOCUSED prompt - only the rollover
// question, using the CREDIT ROLLOVER rules from the extraction prompt - and
// writes only Credit_Rollover__c / _Percent__c / _Terms__c on the deal's
// current extraction. Nothing else on the row changes, so no economics move
// and no fuller read (large-document rows) is replaced.
//
// When it finishes it lays the answers onto the contracts (deal order; an
// upsell that disagrees with its contract flags legal review) - contracts that
// already have a rollover answer are left alone.
//
// - "Not specified" is saved only when every file could be read; otherwise the
//   row stays blank (the clause may be in a file that was left out).
// - Re-running it picks up only rows still blank, so a stopped run resumes.
// - One API call per deal, about a minute each.
//
// CREDIT_DEALS_ONLY = true reads only deals whose extraction shows credits (an
// allocation, a credit commitment or an overage rate). false reads every deal.
// DRY_RUN = true (default) shows how many deals each setting covers and where
// rollover stands now - run it again later to see the results.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillCreditRollover.apex
// =============================================================================

Boolean DRY_RUN = true;               // <-- false to start
Boolean CREDIT_DEALS_ONLY = true;     // <-- false to read every closed-won deal

System.debug('--- Deals to read: ' + CreditRolloverBackfillBatch.countTargets(true) + ' with credits; '
    + CreditRolloverBackfillBatch.countTargets(false) + ' in all (still without a rollover answer).');

System.debug('--- Extractions now (current rows):');
for (AggregateResult ar : [
    SELECT Credit_Rollover__c v, COUNT(Id) n FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Opportunity__r.StageName = 'Closed Won'
    GROUP BY Credit_Rollover__c
]) {
    System.debug('   ' + (ar.get('v') == null ? '(blank)' : String.valueOf(ar.get('v'))) + ': ' + ar.get('n'));
}
System.debug('--- Contracts now:');
for (AggregateResult ar : [
    SELECT Credit_Rollover__c v, COUNT(Id) n FROM Contract GROUP BY Credit_Rollover__c
]) {
    System.debug('   ' + (ar.get('v') == null ? '(blank)' : String.valueOf(ar.get('v'))) + ': ' + ar.get('n'));
}
Integer flagged = [SELECT COUNT() FROM Contract WHERE Needs_Legal_Review__c = true AND Credit_Rollover__c != null];
System.debug('--- Contracts with a rollover answer that are flagged for legal review: ' + flagged);

if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing started. Set DRY_RUN = false to read '
        + CreditRolloverBackfillBatch.countTargets(CREDIT_DEALS_ONLY) + ' deal(s).');
    return;
}
Id jobId = Database.executeBatch(new CreditRolloverBackfillBatch(CREDIT_DEALS_ONLY), 1);
System.debug('--- Started ' + jobId + '. Watch it in Setup > Apex Jobs; when it shows Completed, run this script again '
    + 'with DRY_RUN = true to see the results.');
