// =============================================================================
// Re-align product lines that were read before the seat fee / credit split
// =============================================================================
// The product lines now follow the extraction's split: the seat fee on the
// seats line, a credit commitment as a Paid Credits line, credits with no
// commitment as an Included Credits line, and lines the read left out (seats,
// credits, free credits) added from the extraction's fields. Lines read before
// that keep their old shape - re-running the lines backfill does not touch them
// (it only reads rows never read).
//
// This re-applies the alignment and the audit (Lines Recurring Annual, Lines
// Mismatch) from the lines already stored on each current extraction: no
// re-reading, no API calls. The trigger replaces each changed extraction's
// Order Form Line records - nothing is duplicated. Safe to run again: rows with
// nothing left to change are skipped.
//
// DRY_RUN = true (default) lists what would change. Then set DRY_RUN = false.
//
// Run: sf apex run --target-org rogo --file scripts/apex/realignOrderFormLines.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write

Map<Id, Order_Form_Extraction__c> rows = new Map<Id, Order_Form_Extraction__c>([
    SELECT Id, Opportunity__r.Name, Lines_Recurring_Annual__c, Lines_Mismatch__c
    FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Lines_Read_At__c != null AND Opportunity__r.StageName = 'Closed Won'
]);
List<Order_Form_Extraction__c> changes = OrderFormExtractionJob.realignLines(rows.keySet());

Integer nowMatching = 0;
Integer nowMismatched = 0;
Integer shown = 0;
for (Order_Form_Extraction__c c : changes) {
    Order_Form_Extraction__c before = rows.get(c.Id);
    if (before.Lines_Mismatch__c == true && c.Lines_Mismatch__c != true) nowMatching++;
    if (before.Lines_Mismatch__c != true && c.Lines_Mismatch__c == true) nowMismatched++;
    if (shown < 25) {
        System.debug(before.Opportunity__r.Name + ' | lines a year ' + before.Lines_Recurring_Annual__c + ' -> '
            + c.Lines_Recurring_Annual__c + (c.Lines_Mismatch__c == true ? ' | MISMATCH' : ''));
        shown++;
    }
}
System.debug('--- Current extractions with lines: ' + rows.size() + '; to re-align: ' + changes.size()
    + '; mismatches cleared: ' + nowMatching + '; new mismatches: ' + nowMismatched);
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to write.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(changes, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
System.debug('--- Re-aligned ' + ok + ' of ' + changes.size() + ' extraction(s).');
