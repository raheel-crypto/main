// =============================================================================
// Write contract histories (Contract History field, written by Claude)
// =============================================================================
// Each contract's running history - new business or renewal, then every upsell
// in order, what each bought or changed, and the open items - is written by
// Claude from its deals' extractions, the Contract Term Changes and the billing
// split. After this first run it stays up to date by itself: whenever a
// contract's terms are re-applied (rebuild, nightly refresh, a legal decision)
// its history is checked and rewritten only if its facts changed.
//
// ONLY_CONTRACTS: contract numbers to do first (try two or three, read them,
//   then run it for all). Empty = every contract with a deal applied.
// FORCE = true rewrites even when the facts have not changed.
// DRY_RUN = true (default) counts and estimates the cost; changes nothing.
//
// Cost: about $0.02 per contract (model on the "Default" Order Form Review
// Setting, History Model). One background job per two contracts: Setup > Apex
// Jobs, "ContractHistoryJob".
//
// Run: sf apex run --target-org rogo --file scripts/apex/writeContractHistories.apex
// =============================================================================

List<String> ONLY_CONTRACTS = new List<String>{
    // '00001234'
};
Boolean FORCE = false;
Boolean DRY_RUN = true;   // <-- false to start

String modelName = ContractHistory.model();
if (String.isBlank(modelName)) {
    System.debug('--- No History Model is set on the "Default" Order Form Review Setting: nothing would be written.');
    return;
}
Set<Id> ids = new Set<Id>();
if (!ONLY_CONTRACTS.isEmpty()) {
    for (Contract c : [SELECT Id FROM Contract WHERE ContractNumber IN :ONLY_CONTRACTS]) ids.add(c.Id);
} else {
    for (AggregateResult ar : [
        SELECT Applied_Contract__c cid FROM Order_Form_Extraction__c
        WHERE Applied_Contract__c != null AND Is_Current__c = true
        GROUP BY Applied_Contract__c
    ]) {
        ids.add((Id) ar.get('cid'));
    }
}
Integer have = [SELECT COUNT() FROM Contract WHERE Id IN :ids AND Contract_History_Updated__c != null];
System.debug('--- Model ' + modelName + ': ' + ids.size() + ' contract(s); ' + have + ' already have a history'
    + (FORCE ? ' (FORCE: all are rewritten)' : ' (rewritten only if their facts changed)') + '.');
System.debug('--- Estimated cost: about $' + (ids.size() * 0.02).setScale(2) + ' at most.');
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing changed. Set DRY_RUN = false to start.');
    return;
}
List<Contract> marks = new List<Contract>();
for (Id cid : ids) {
    Contract c = new Contract(Id = cid, Contract_History_Stale__c = true);
    if (FORCE) c.Contract_History_Hash__c = null;
    marks.add(c);
}
update marks;
Id jobId = System.enqueueJob(new ContractHistoryJob(ONLY_CONTRACTS.isEmpty() ? null : ids));
System.debug('--- Started (job ' + jobId + ') for ' + ids.size() + ' contract(s). Progress: Setup > Apex Jobs, '
    + 'ContractHistoryJob. Each history appears in the Contract History field.');
