// =============================================================================
// Backfill product lines on every extraction read before line items existed
// =============================================================================
// New reads list each order form's products as Order Form Line records (Rogo
// seats, Arvo / Rogo Notes seats, free seats, paid / included / free credits,
// hosting, data connections, services, pilot fees, true-ups) with totals on the
// extraction (Arvo Seats, Free Seats, Included Credits, Free Credits, Lines
// Recurring Annual) and an audit flag (Lines Mismatch: the lines' recurring
// fees disagree with the row's ARR by more than 1%).
//
// This re-reads each older deal's files with a FOCUSED prompt - only the line
// items question - and writes only those line fields; nothing else on the row
// changes. One API call per current extraction, about a minute each, newest
// deals first. Re-running picks up only rows still unread, so a stopped run
// resumes.
//
// DRY_RUN = true (default) shows how many extractions are still unread and
// where the lines stand now - run it again later to see the results.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillOrderFormLines.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to start

Integer unread = OrderFormLinesBackfillBatch.countTargets();
Integer read = [SELECT COUNT() FROM Order_Form_Extraction__c
                WHERE Is_Current__c = true AND Lines_Read_At__c != null AND Opportunity__r.StageName = 'Closed Won'];
Integer mismatched = [SELECT COUNT() FROM Order_Form_Extraction__c
                      WHERE Is_Current__c = true AND Lines_Mismatch__c = true AND Opportunity__r.StageName = 'Closed Won'];
System.debug('--- Current extractions with lines read: ' + read + '; still unread: ' + unread
    + '; lines disagree with the ARR: ' + mismatched);
System.debug('--- Lines by product:');
for (AggregateResult ar : [
    SELECT Product__c p, COUNT(Id) n, SUM(Quantity__c) q, SUM(Annual_Amount__c) amt FROM Order_Form_Line__c
    WHERE Extraction__r.Is_Current__c = true GROUP BY Product__c ORDER BY COUNT(Id) DESC
]) {
    System.debug('   ' + ar.get('p') + ': ' + ar.get('n') + ' line(s), quantity ' + ar.get('q')
        + ', recurring a year ' + ar.get('amt'));
}
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing started. Set DRY_RUN = false to read ' + unread + ' extraction(s).');
    return;
}
Id jobId = Database.executeBatch(new OrderFormLinesBackfillBatch(), 1);
System.debug('--- Started ' + jobId + '. Watch it in Setup > Apex Jobs; when it shows Completed, run this script again '
    + 'with DRY_RUN = true to see the results.');
