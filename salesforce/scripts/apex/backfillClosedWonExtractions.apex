// =============================================================================
// Backfill: extract order form data from existing Closed Won opportunities
// =============================================================================
// Picks up the next CHUNK_SIZE Opps that:
//   - Are StageName = 'Closed Won'
//   - Have at least one ContentDocument titled signed__*
//   - Do NOT already have an Order_Form_Extraction__c row
// Each Opp gets one Queueable enqueued -> one Anthropic call -> one new row.
//
// Anonymous Apex is capped at 50 enqueued Queueables per transaction, so
// CHUNK_SIZE must stay <= 50. Run this script as many times as needed -
// it's idempotent. When there's nothing left, it prints "All caught up."
//
// Run:
//   sf apex run --target-org rogo-dev --file salesforce/scripts/apex/backfillClosedWonExtractions.apex
//
// Heads up: each Opp = one Anthropic Messages call. At ~$0.10-$0.50 per call
// depending on token count, 500 Opps = ~$50-$250 in API costs. Monitor
// extraction status via Setup -> Apex Jobs and the Order_Form_Extraction__c
// list view.
// =============================================================================

Integer CHUNK_SIZE = 50;   // hard cap = 50 (System.enqueueJob limit)

// Step 1: collect every entity Id that has a signed__* file. ContentDocumentLink
// can't be used in a semi-join inner select, so we query it directly and filter
// down to Opportunity Ids (006...) in memory.
Set<Id> oppIdsWithSignedFiles = new Set<Id>();
for (ContentDocumentLink cdl : [
    SELECT LinkedEntityId
    FROM ContentDocumentLink
    WHERE ContentDocument.Title LIKE 'signed__%'
]) {
    Id eid = cdl.LinkedEntityId;
    if (eid != null && String.valueOf(eid).startsWith('006')) {
        oppIdsWithSignedFiles.add(eid);
    }
}
System.debug('--- Opps anywhere with a signed__* file: ' + oppIdsWithSignedFiles.size());

if (oppIdsWithSignedFiles.isEmpty()) {
    System.debug('--- No signed__* files anywhere in the org. Nothing to do.');
    return;
}

// Step 2: from those, pick Closed Won Opps that don't yet have an extraction.
List<Opportunity> opps = [
    SELECT Id, Name
    FROM Opportunity
    WHERE Id IN :oppIdsWithSignedFiles
      AND StageName = 'Closed Won'
      AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c)
    ORDER BY CloseDate DESC
    LIMIT :CHUNK_SIZE
];

System.debug('--- Found ' + opps.size() + ' Closed Won Opp(s) ready to extract');
if (opps.isEmpty()) {
    System.debug('--- All caught up. No remaining Closed Won Opps with signed__* files and no extraction yet.');
    return;
}

List<OrderFormExtractor.Request> reqs = new List<OrderFormExtractor.Request>();
for (Opportunity o : opps) {
    OrderFormExtractor.Request r = new OrderFormExtractor.Request();
    r.opportunityId = o.Id;
    reqs.add(r);
    System.debug('   queueing: ' + o.Name + ' (' + o.Id + ')');
}

List<OrderFormExtractor.Result> results = OrderFormExtractor.run(reqs);

Map<String, Integer> counts = new Map<String, Integer>();
for (OrderFormExtractor.Result res : results) {
    Integer prior = counts.containsKey(res.status) ? counts.get(res.status) : 0;
    counts.put(res.status, prior + 1);
}
System.debug('--- Summary: ' + counts);

// Quick remaining-count using the same Set
Integer remaining = [
    SELECT COUNT()
    FROM Opportunity
    WHERE Id IN :oppIdsWithSignedFiles
      AND StageName = 'Closed Won'
      AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c)
];
System.debug('--- ' + remaining + ' Opp(s) remaining for the next run.');
System.debug('--- Monitor progress: Setup -> Apex Jobs (look for OrderFormExtractionJob)');
