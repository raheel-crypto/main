// =============================================================================
// Step 1 of 2 - re-extract every closed-won deal on one account
// =============================================================================
// Flags the current extraction of each Closed Won opportunity on the account
// for rerun and starts the rerun batch (OrderFormBackfillBatch.runRerunFlagged:
// oldest deal first, every document on the deal and its base deal; any
// readable result replaces the flagged row, which is kept as history). Deals
// with no extraction yet are queued for a first one.
//
// When the batch shows Completed in Setup > Apex Jobs, run step 2,
// rebuildAccountContracts.apex, with the same ACCOUNT.
//
// DRY_RUN = true (default) lists the deals. Then set DRY_RUN = false.
//
// Run: sf apex run --target-org rogo --file scripts/apex/rerunAccountExtractions.apex
// =============================================================================

String ACCOUNT = 'Texas Capital';   // <-- account name (starts with), or an Account Id
Boolean DRY_RUN = true;            // <-- false to start the rerun

String namePattern = ACCOUNT + '%';
List<Account> accts = ACCOUNT.startsWith('001')
    ? [SELECT Id, Name FROM Account WHERE Id = :ACCOUNT]
    : [SELECT Id, Name FROM Account WHERE Name LIKE :namePattern];
if (accts.size() != 1) {
    System.debug('--- ' + accts.size() + ' accounts match "' + ACCOUNT + '" - make ACCOUNT more specific or paste the Account Id:');
    for (Account a : accts) System.debug('   ' + a.Id + ' | ' + a.Name);
    return;
}
Account acct = accts[0];

Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
    SELECT Id, Name, Type, CloseDate FROM Opportunity
    WHERE AccountId = :acct.Id AND StageName = 'Closed Won' ORDER BY CloseDate
]);
Map<Id, Order_Form_Extraction__c> currentByOpp = OrderFormVersioning.loadCurrentByOpp(opps.keySet());
Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(opps.keySet());

List<Order_Form_Extraction__c> flag = new List<Order_Form_Extraction__c>();
List<Id> firstTime = new List<Id>();
System.debug('--- ' + acct.Name + ': ' + opps.size() + ' closed-won deal(s)');
for (Opportunity o : opps.values()) {
    Order_Form_Extraction__c cur = currentByOpp.get(o.Id);
    List<Id> docs = docsByOpp.get(o.Id);
    Integer n = docs == null ? 0 : docs.size();
    if (cur != null && cur.Id != null) {
        flag.add(new Order_Form_Extraction__c(Id = cur.Id, Rerun__c = true));
        System.debug('rerun      | ' + o.CloseDate + ' | ' + o.Name + ' [' + o.Type + '] | now ' + cur.Extraction_Status__c + ' | ' + n + ' file(s)');
    } else if (n > 0) {
        firstTime.add(o.Id);
        System.debug('first read | ' + o.CloseDate + ' | ' + o.Name + ' [' + o.Type + '] | ' + n + ' file(s)');
    } else {
        System.debug('no files   | ' + o.CloseDate + ' | ' + o.Name + ' [' + o.Type + ']');
    }
}
Integer otherFlags = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Rerun__c = true AND Opportunity__r.AccountId != :acct.Id];
if (otherFlags > 0) {
    System.debug('--- Note: ' + otherFlags + ' row(s) on other accounts are also flagged for rerun; the batch will redo those too.');
}
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing started. Set DRY_RUN = false to rerun ' + flag.size() + ' and read ' + firstTime.size() + ' for the first time.');
    return;
}
update flag;
for (Id oppId : firstTime) System.enqueueJob(new OrderFormExtractionJob(oppId, docsByOpp.get(oppId)));
Id jobId = flag.isEmpty() ? null : OrderFormBackfillBatch.runRerunFlagged();
System.debug('--- Flagged ' + flag.size() + ' for rerun' + (jobId == null ? '' : ' (batch ' + jobId + ')')
    + '; queued ' + firstTime.size() + ' first read(s). When Apex Jobs shows it Completed, run rebuildAccountContracts.apex.');
