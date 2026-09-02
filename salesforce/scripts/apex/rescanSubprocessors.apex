// =============================================================================
// Sub-Processor Re-Scan - all Closed Won opportunities (resumable)
// =============================================================================
// Re-extracts every Closed Won Opp that has a signed__* file so the new
// Sub_Processor_List__c gets populated across the whole book. Each Opp gets a
// fresh Order_Form_Extraction__c row (one Anthropic call each). This is
// NON-DESTRUCTIVE: existing extraction rows are left in place - the newest row
// per Opp is the current truth.
//
// RESUMABLE: set RESCAN_CUTOFF to the moment you START this re-scan (see below).
// Each run picks up the next 50 Opps that don't yet have a row created at/after
// the cutoff, so run it repeatedly until it prints "All caught up." Opps whose
// order form genuinely has no subprocessor list still get a (null-list) row,
// so they are not re-processed on the next run.
//
// Anonymous Apex caps enqueued Queueables at 50/transaction, so CHUNK_SIZE<=50.
//
// Run (repeat until caught up):
//   sf apex run --target-org rogo --file scripts/apex/rescanSubprocessors.apex
//
// COST: one Anthropic Messages call per Opp (~$0.10-$0.50 each depending on
// document size). Monitor via Setup -> Apex Jobs (OrderFormExtractionJob) and
// the Order_Form_Extraction__c list view.
// =============================================================================

// IMPORTANT: set this ONCE to just before your first run and keep it the SAME
// value for every subsequent run of this re-scan pass. Anything created at/after
// this instant counts as "already re-scanned."
Datetime RESCAN_CUTOFF = Datetime.newInstanceGmt(2026, 9, 2, 0, 0, 0);   // <-- set to your re-scan start (GMT)

Integer CHUNK_SIZE = 50;   // hard cap = 50 (System.enqueueJob limit)

// Step 1: every Opp that has a signed__* file. ContentDocumentLink CANNOT be
// filtered by ContentDocument.Title alone (implementation restriction: it must
// be filtered by ContentDocumentId or LinkedEntityId with = or IN). So first
// pull the signed__* ContentDocument Ids, then look up their links by those Ids.
Set<Id> signedDocIds = new Set<Id>();
for (ContentDocument cd : [SELECT Id FROM ContentDocument WHERE Title LIKE 'signed__%']) {
    signedDocIds.add(cd.Id);
}
System.debug('--- signed__* ContentDocuments in the org: ' + signedDocIds.size());

if (signedDocIds.isEmpty()) {
    System.debug('--- No signed__* files anywhere in the org. Nothing to do.');
    return;
}

Set<Id> oppIdsWithSignedFiles = new Set<Id>();
for (ContentDocumentLink cdl : [
    SELECT LinkedEntityId
    FROM ContentDocumentLink
    WHERE ContentDocumentId IN :signedDocIds
]) {
    Id eid = cdl.LinkedEntityId;
    if (eid != null && String.valueOf(eid).startsWith('006')) {
        oppIdsWithSignedFiles.add(eid);
    }
}
System.debug('--- Opps anywhere with a signed__* file: ' + oppIdsWithSignedFiles.size());

if (oppIdsWithSignedFiles.isEmpty()) {
    System.debug('--- No signed__* files linked to any Opportunity. Nothing to do.');
    return;
}

// Step 2: Closed Won Opps that have NOT yet been re-scanned in this pass
// (i.e. have no Order_Form_Extraction__c row created at/after the cutoff).
List<Opportunity> opps = [
    SELECT Id, Name
    FROM Opportunity
    WHERE Id IN :oppIdsWithSignedFiles
      AND StageName = 'Closed Won'
      AND Id NOT IN (
          SELECT Opportunity__c FROM Order_Form_Extraction__c
          WHERE CreatedDate >= :RESCAN_CUTOFF
      )
    ORDER BY CloseDate DESC
    LIMIT :CHUNK_SIZE
];

System.debug('--- Found ' + opps.size() + ' Closed Won Opp(s) still to re-scan this pass');
if (opps.isEmpty()) {
    System.debug('--- All caught up. Every Closed Won Opp with a signed__* file has a post-cutoff extraction.');
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

Integer remaining = [
    SELECT COUNT()
    FROM Opportunity
    WHERE Id IN :oppIdsWithSignedFiles
      AND StageName = 'Closed Won'
      AND Id NOT IN (
          SELECT Opportunity__c FROM Order_Form_Extraction__c
          WHERE CreatedDate >= :RESCAN_CUTOFF
      )
];
System.debug('--- ' + remaining + ' Opp(s) remaining for the next run.');
System.debug('--- Monitor progress: Setup -> Apex Jobs (OrderFormExtractionJob)');
