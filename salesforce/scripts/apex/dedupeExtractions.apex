// =============================================================================
// Cleanup: delete extractions older than each Opportunity's most recent Success
// =============================================================================
// Reprocessing appends a new OFE row each run, so opps have accumulated stale
// history. This deletes, per Opportunity, every extraction row OLDER than that
// opp's most recent SUCCESS - keeping the most recent Success and anything
// newer. Opps that have NO Success row are left completely untouched (there's
// no good row to anchor on - those are the failed / large-file / blank ones you
// may still be working).
//
// SAFETY:
//   * DRY RUN by default (DO_DELETE = false): prints what it WOULD delete.
//     Review the counts, then set DO_DELETE = true to actually remove them.
//   * Loads only light fields (Id, Opportunity__c, CreatedDate, status) - no
//     VersionData or long-text, so it's heap-safe at any volume.
//   * If you apply OFEs to Contracts, a Contract's Latest_Order_Form_Extraction__c
//     may point at an older row this deletes -> re-run the applier afterward.
//
// Deletes up to 10,000 rows per run (Apex DML cap); re-run until it reports 0.
//
// Run: sf apex run --target-org rogo --file scripts/apex/dedupeExtractions.apex
// (or paste into Dev Console -> Execute Anonymous)
// =============================================================================

Boolean DO_DELETE = false;   // <-- set true to actually delete

// 1. Most recent Success CreatedDate per Opportunity (the "keep line").
Map<Id, Datetime> keepLineByOpp = new Map<Id, Datetime>();
for (Order_Form_Extraction__c o : [
    SELECT Opportunity__c, CreatedDate
    FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success' AND Opportunity__c != null
    ORDER BY CreatedDate ASC
]) {
    keepLineByOpp.put(o.Opportunity__c, o.CreatedDate);   // last (newest) wins
}

// 2. Any row older than its opp's keep line is stale - queue it for deletion.
List<Order_Form_Extraction__c> toDelete = new List<Order_Form_Extraction__c>();
if (!keepLineByOpp.isEmpty()) {
    for (Order_Form_Extraction__c o : [
        SELECT Id, Opportunity__c, CreatedDate
        FROM Order_Form_Extraction__c
        WHERE Opportunity__c IN :keepLineByOpp.keySet()
        ORDER BY CreatedDate ASC
    ]) {
        if (o.CreatedDate < keepLineByOpp.get(o.Opportunity__c)) {
            toDelete.add(o);
        }
    }
}

System.debug('--- Opps with a Success row: ' + keepLineByOpp.size());
System.debug('--- Stale rows (older than the most recent Success): ' + toDelete.size());

if (!DO_DELETE) {
    System.debug('--- DRY RUN. Set DO_DELETE = true to delete these ' + toDelete.size() + ' older row(s).');
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
    System.debug('--- Deleted ' + toDelete.size() + ' stale row(s). Done.');
}
