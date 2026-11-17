// =============================================================================
// Extract closed-won deals that never got an order form extraction
// =============================================================================
// The Close Opportunity screen flow queues the extraction (Run_OFE) only AFTER
// its last screen ("A Slack has been sent to RevOps..."): a rep who closes that
// window with the X instead of clicking Finish never reaches it (RKS-AM,
// 2026-11-17). RevOps marking the deal Closed Won does not queue one either.
//
// This lists every Closed Won opportunity with no extraction at all and whether
// it has files, then (DRY_RUN = false) reads the ones with files - the existing
// OrderFormBackfillBatch, two deals per transaction, one API call per deal.
// Deals with no files are skipped without a call. Safe to run again: a deal
// that now has an extraction is no longer listed.
//
// Run: sf apex run --target-org rogo --file scripts/apex/extractMissingOrderForms.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to start the reads

List<Opportunity> missing = [
    SELECT Id, Name, CloseDate, Owner.Name FROM Opportunity
    WHERE StageName = 'Closed Won' AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c)
    ORDER BY CloseDate DESC
];
Map<Id, List<Id>> docs = OrderFormExtractor.findAllDocuments(new Map<Id, Opportunity>(missing).keySet());
Integer withFiles = 0;
for (Opportunity o : missing) {
    Boolean has = docs.containsKey(o.Id);
    if (has) withFiles++;
    System.debug(o.CloseDate + ' | ' + o.Name + ' | ' + o.Owner.Name + ' | '
        + (has ? docs.get(o.Id).size() + ' file(s)' : 'no files - skipped'));
}
System.debug('--- Closed Won without an extraction: ' + missing.size() + '; with files to read: ' + withFiles
    + ' (one API call each).');
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing started. Set DRY_RUN = false to read them.');
    return;
}
Id jobId = Database.executeBatch(new OrderFormBackfillBatch(), 2);
System.debug('--- Started ' + jobId + ' (Setup > Apex Jobs). Run this again with DRY_RUN = true afterwards to check.');
