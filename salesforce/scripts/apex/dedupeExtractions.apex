// =============================================================================
// De-duplicate Order Form Extractions (keep one row per Opportunity)
// =============================================================================
// Reprocessing appends a new OFE row each run, so an Opp can accumulate several.
// This keeps ONE row per Opportunity - the most recent Success; if the Opp has
// no Success row, the most recent row of any status - and deletes the rest.
//
// SAFETY:
//   * DRY RUN by default (DO_DELETE = false): prints what it WOULD delete.
//     Review the counts, then set DO_DELETE = true to actually remove them.
//   * Run only AFTER all reprocessing (runRerunFlagged, manual reruns) is
//     finished, so the keeper is the final good row.
//   * If you apply OFEs to Contracts, a Contract's Latest_Order_Form_Extraction__c
//     may point at a row this deletes -> re-run the applier afterward (or ask me
//     to make the keeper prefer the already-applied row).
//
// Deletes up to 10,000 rows per run (Apex DML cap); re-run until it reports 0.
//
// Run: sf apex run --target-org rogo --file scripts/apex/dedupeExtractions.apex
// =============================================================================

Boolean DO_DELETE = false;   // <-- set true to actually delete

Map<Id, List<Order_Form_Extraction__c>> byOpp = new Map<Id, List<Order_Form_Extraction__c>>();
for (Order_Form_Extraction__c o : [
    SELECT Id, Opportunity__c, Extraction_Status__c, CreatedDate
    FROM Order_Form_Extraction__c
    WHERE Opportunity__c != null
    ORDER BY Opportunity__c, CreatedDate DESC   // newest first within each Opp
]) {
    if (!byOpp.containsKey(o.Opportunity__c)) byOpp.put(o.Opportunity__c, new List<Order_Form_Extraction__c>());
    byOpp.get(o.Opportunity__c).add(o);
}

List<Order_Form_Extraction__c> toDelete = new List<Order_Form_Extraction__c>();
Integer oppsWithDupes = 0;
for (Id oppId : byOpp.keySet()) {
    List<Order_Form_Extraction__c> rows = byOpp.get(oppId);   // newest first
    if (rows.size() < 2) continue;
    oppsWithDupes++;
    Order_Form_Extraction__c keeper = null;
    for (Order_Form_Extraction__c r : rows) {                 // first (newest) Success wins
        if (r.Extraction_Status__c == 'Success') { keeper = r; break; }
    }
    if (keeper == null) keeper = rows[0];                     // no Success -> newest of any
    for (Order_Form_Extraction__c r : rows) if (r.Id != keeper.Id) toDelete.add(r);
}

System.debug('--- Opps total: ' + byOpp.size());
System.debug('--- Opps with duplicates: ' + oppsWithDupes);
System.debug('--- Redundant rows to delete: ' + toDelete.size());

if (!DO_DELETE) {
    System.debug('--- DRY RUN. Set DO_DELETE = true to remove the ' + toDelete.size() + ' redundant row(s).');
    return;
}

Integer cap = 10000;
if (toDelete.size() > cap) {
    List<Order_Form_Extraction__c> slice = new List<Order_Form_Extraction__c>();
    for (Integer i = 0; i < cap; i++) slice.add(toDelete[i]);
    delete slice;
    System.debug('--- Deleted ' + slice.size() + '; ' + (toDelete.size() - cap) + ' remaining - run again.');
} else {
    delete toDelete;
    System.debug('--- Deleted ' + toDelete.size() + ' redundant row(s). Done.');
}
