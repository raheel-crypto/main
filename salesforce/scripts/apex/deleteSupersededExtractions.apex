// =============================================================================
// Delete superseded extraction versions - keep only each deal's current one
// =============================================================================
// Deletes Order_Form_Extraction__c rows that are no longer current, for deals
// that have a current row. Their product lines and their reviews (with findings)
// are deleted with them. Contract Term Changes stay (their link to the old row
// is cleared). Deleted rows sit in the Recycle Bin for 15 days.
//
// Run it AFTER the refresh and the contract rebuild: an old row still attached
// to a contract is skipped (its contract has not been rebuilt) and listed.
//
// DRY_RUN = true (default) counts what would go. Up to MAX_ROWS per run; run
// it again until nothing is left.
//
// Run: sf apex run --target-org rogo --file scripts/apex/deleteSupersededExtractions.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to delete
Integer MAX_ROWS = 400;

Set<Id> withCurrent = new Set<Id>();
for (AggregateResult ar : [
    SELECT Opportunity__c oid FROM Order_Form_Extraction__c WHERE Is_Current__c = true GROUP BY Opportunity__c
]) {
    withCurrent.add((Id) ar.get('oid'));
}
Integer total = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Is_Current__c = false AND Opportunity__c IN :withCurrent];
Integer attached = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Is_Current__c = false
                    AND Opportunity__c IN :withCurrent AND Applied_Contract__c != null];
Integer orphans = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Is_Current__c = false
                   AND Opportunity__c NOT IN :withCurrent];
Integer reviews = [SELECT COUNT() FROM Order_Form_Review__c WHERE Extraction__r.Is_Current__c = false
                   AND Extraction__r.Opportunity__c IN :withCurrent];
System.debug('--- Superseded rows: ' + total + ' (with ' + reviews + ' review(s) on them).');
if (attached > 0) {
    System.debug('   ' + attached + ' still attached to a contract: skipped - rebuild those contracts first '
        + '(refreshContractsFromExtractions.apex, MODE \'ALL\').');
}
if (orphans > 0) System.debug('   ' + orphans + ' on deals with no current row: kept (they are the only read of the deal).');

List<Order_Form_Extraction__c> rows = [
    SELECT Id FROM Order_Form_Extraction__c
    WHERE Is_Current__c = false AND Opportunity__c IN :withCurrent AND Applied_Contract__c = null
    LIMIT :MAX_ROWS
];
if (DRY_RUN) {
    System.debug('--- DRY RUN: ' + Math.min(total - attached, MAX_ROWS) + ' row(s) would be deleted this run. '
        + 'Set DRY_RUN = false to delete.');
    return;
}
Integer ok = 0;
List<String> failed = new List<String>();
for (Database.DeleteResult dr : Database.delete(rows, false)) {
    if (dr.isSuccess()) ok++;
    else failed.add(dr.getId() + ': ' + dr.getErrors()[0].getMessage());
}
System.debug('--- Deleted ' + ok + ' row(s); ' + failed.size() + ' failed. ' + (total - attached - ok)
    + ' left to delete (run again).');
for (Integer i = 0; i < Math.min(10, failed.size()); i++) System.debug('   ' + failed[i]);
