// =============================================================================
// Refresh every deal's extraction with today's extraction logic
// =============================================================================
// Re-reads every Closed Won deal with Claude - the current prompt, Rogo's online
// terms and the current mapping - and updates its current extraction IN PLACE
// (OrderFormBackfillBatch refresh mode): no new versions. A read that fails, or
// reads less than the current row (fewer files), never overwrites it; the deal
// stays "to do" and is listed below with the reason.
//
// "Refreshed" = extracted since the current extraction logic was deployed (the
// later of the OrderFormExtractionJob class and the OrderFormPrompt static
// resource). So START again simply picks up whatever is still to do.
//
// ACTION
//   'STATUS' (default): refreshed / to do, the running jobs, and what is left
//     with its reason. Changes nothing.
//   'START': refresh every deal still to do, split into SHARDS jobs that run
//     side by side, one deal at a time each (a read takes about a minute). The
//     deals listed for the large-document script are left to it.
//
// When the jobs are done: STATUS; START again to retry what failed; the deals
// listed for the large-document script go through it; then rebuild every
// contract (refreshContractsFromExtractions.apex, MODE 'ALL').
//
// Run: sf apex run --target-org rogo --file scripts/apex/refreshAllExtractions.apex
// =============================================================================

String ACTION = 'STATUS';   // <-- 'STATUS' or 'START'
Integer SHARDS = 3;         // jobs side by side (Salesforce runs up to 5 batch jobs at once)

Datetime cutoff;
for (ApexClass c : [SELECT LastModifiedDate FROM ApexClass WHERE Name = 'OrderFormExtractionJob']) cutoff = c.LastModifiedDate;
for (StaticResource r : [SELECT LastModifiedDate FROM StaticResource WHERE Name = 'OrderFormPrompt']) {
    if (cutoff == null || r.LastModifiedDate > cutoff) cutoff = r.LastModifiedDate;
}
System.debug('--- Current extraction logic deployed ' + cutoff.format('yyyy-MM-dd HH:mm z')
    + '. A deal extracted since then is refreshed.');

List<AsyncApexJob> running = [
    SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors FROM AsyncApexJob
    WHERE ApexClass.Name = 'OrderFormBackfillBatch' AND JobType = 'BatchApex'
      AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
];
for (AsyncApexJob j : running) {
    System.debug('   running: ' + j.Id + ' ' + j.Status + ', ' + j.JobItemsProcessed + ' of ' + j.TotalJobItems
        + ' deal(s) done' + (j.NumberOfErrors > 0 ? ', ' + j.NumberOfErrors + ' error(s)' : ''));
}

Map<Id, Opportunity> won = new Map<Id, Opportunity>([SELECT Id, Name FROM Opportunity WHERE StageName = 'Closed Won']);
Set<Id> refreshed = new Set<Id>();
for (Order_Form_Extraction__c r : [
    SELECT Opportunity__c FROM Order_Form_Extraction__c
    WHERE Extracted_At__c >= :cutoff AND Opportunity__c IN :won.keySet()
]) {
    refreshed.add(r.Opportunity__c);
}
Map<Id, Order_Form_Extraction__c> currentByOpp = new Map<Id, Order_Form_Extraction__c>();
for (Order_Form_Extraction__c r : [
    SELECT Opportunity__c, Extraction_Status__c, Docs_Dropped__c, Model__c, Extracted_At__c
    FROM Order_Form_Extraction__c WHERE Is_Current__c = true AND Opportunity__c IN :won.keySet()
]) {
    currentByOpp.put(r.Opportunity__c, r);
}
Set<Id> notYet = new Set<Id>();
for (Id o : won.keySet()) if (!refreshed.contains(o)) notYet.add(o);
Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(notYet);

List<Id> todo = new List<Id>();
List<String> large = new List<String>();
Integer noFiles = 0;
Map<String, Integer> todoByStatus = new Map<String, Integer>();
for (Id o : notYet) {
    if (!docsByOpp.containsKey(o) || docsByOpp.get(o).isEmpty()) {
        noFiles++;
        continue;
    }
    todo.add(o);
    Order_Form_Extraction__c cur = currentByOpp.get(o);
    String why = cur == null ? 'no extraction yet' : 'current row: ' + cur.Extraction_Status__c
        + (cur.Docs_Dropped__c == true ? ', files left out (too large for Salesforce)' : '');
    todoByStatus.put(why, (todoByStatus.containsKey(why) ? todoByStatus.get(why) : 0) + 1);
    // Too large for Salesforce, or read off-platform before: the large-document script reads them whole.
    if (cur != null && (cur.Docs_Dropped__c == true || (cur.Model__c != null && cur.Model__c.contains('4-6')))) {
        large.add(String.valueOf(o));
    }
}

// Refreshed, but Salesforce had to leave files out (a ZIP envelope, or files over its
// size limits): complete only once the large-document script has read the deal whole.
Integer refreshedPartial = 0;
for (Id o : refreshed) {
    Order_Form_Extraction__c cur = currentByOpp.get(o);
    if (cur != null && cur.Docs_Dropped__c == true) {
        refreshedPartial++;
        large.add(String.valueOf(o));
    }
}

System.debug('--- Closed Won deals: ' + won.size() + '. Refreshed: ' + refreshed.size()
    + (refreshedPartial > 0 ? ' (' + refreshedPartial + ' with files left out - for the large-document script)' : '')
    + '. To do: ' + todo.size() + '. No files (nothing to read): ' + noFiles + '.');
for (String k : todoByStatus.keySet()) System.debug('   to do - ' + k + ': ' + todoByStatus.get(k));
if (!large.isEmpty()) {
    System.debug('--- ' + large.size() + ' deal(s) to read with the large-document script (Salesforce would leave files out). '
        + 'From salesforce/scripts/large-doc-extractor:');
    System.debug('   python3 extract_large_docs.py --write ' + String.join(large, ' '));
}

if (ACTION != 'START') {
    System.debug('--- STATUS only. Set ACTION = \'START\' to refresh the ' + todo.size() + ' deal(s) still to do.');
    return;
}
if (!running.isEmpty()) {
    System.debug('--- A refresh is still running; wait for it to finish (STATUS), then START again for what is left.');
    return;
}
Set<String> largeSet = new Set<String>(large);
List<Id> inSalesforce = new List<Id>();
for (Id o : todo) if (!largeSet.contains(String.valueOf(o))) inSalesforce.add(o);
if (inSalesforce.isEmpty()) {
    System.debug('--- Nothing to do in Salesforce' + (large.isEmpty() ? '.' : ' - the rest is for the large-document script.'));
    return;
}
Integer n = Math.max(1, Math.min(SHARDS, 5));
List<Set<Id>> passes = new List<Set<Id>>();
for (Integer i = 0; i < n; i++) passes.add(new Set<Id>());
for (Integer i = 0; i < inSalesforce.size(); i++) passes[Math.mod(i, n)].add(inSalesforce[i]);
for (Set<Id> pass : passes) {
    if (pass.isEmpty()) continue;
    Id jobId = OrderFormBackfillBatch.runRefresh(cutoff, pass, 1);
    System.debug('--- Started ' + jobId + ' for ' + pass.size() + ' deal(s).');
}
System.debug('--- ' + inSalesforce.size() + ' deal(s) in Salesforce, about ' + Math.max(1, inSalesforce.size() / n)
    + ' minute(s) at roughly a minute per deal per job' + (large.isEmpty() ? '' : '; ' + large.size()
    + ' left to the large-document script') + '. Progress: Setup > Apex Jobs, or run this again with ACTION = \'STATUS\'.');
