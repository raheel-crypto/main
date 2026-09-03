// =============================================================================
// Re-run flagged Order Form Extractions
// =============================================================================
// Re-extracts every OFE you checked Rerun__c = true (up to 50 per run), reading
// each Opportunity's CURRENT documents, then DELETES the flagged rows so they
// don't stack as duplicates (deleting also clears the flag). The fresh
// extraction inserts a new row per Opportunity.
//
// How to use:
//   1. In a Order Form Extraction list view, check Rerun on the rows that
//      didn't extract properly (mass-edit / inline edit).
//   2. Run this (repeat until it reports 0 remaining):
//        sf apex run --target-org rogo --file scripts/apex/rerunFlaggedExtractions.apex
//      (or paste into Dev Console -> Execute Anonymous)
//
// Anonymous Apex caps enqueued Queueables at 50/transaction, so this does 50
// opportunities per run and is resumable.
// =============================================================================

List<Order_Form_Extraction__c> flagged = [
    SELECT Id, Opportunity__c
    FROM Order_Form_Extraction__c
    WHERE Rerun__c = true AND Opportunity__c != null
    LIMIT 50
];

if (flagged.isEmpty()) {
    System.debug('--- Nothing flagged Rerun__c = true. Done.');
    return;
}

// Dedup opportunities (an opp could have more than one flagged row).
Set<Id> oppIds = new Set<Id>();
for (Order_Form_Extraction__c o : flagged) oppIds.add(o.Opportunity__c);

// Remove the flagged (bad) rows first. DML before System.enqueueJob is fine -
// the Anthropic callout happens later inside the Queueable, not now.
delete flagged;

List<OrderFormExtractor.Request> reqs = new List<OrderFormExtractor.Request>();
for (Id oid : oppIds) {
    OrderFormExtractor.Request r = new OrderFormExtractor.Request();
    r.opportunityId = oid;
    reqs.add(r);
}
List<OrderFormExtractor.Result> results = OrderFormExtractor.run(reqs);

Map<String, Integer> counts = new Map<String, Integer>();
for (OrderFormExtractor.Result res : results) {
    Integer prior = counts.containsKey(res.status) ? counts.get(res.status) : 0;
    counts.put(res.status, prior + 1);
}
System.debug('--- Re-extracting ' + reqs.size() + ' opportunity(ies) from ' + flagged.size() + ' flagged row(s). ' + counts);

Integer remaining = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Rerun__c = true];
System.debug('--- ' + remaining + ' flagged row(s) remaining for the next run.');
System.debug('--- Monitor: Setup -> Apex Jobs (OrderFormExtractionJob)');
