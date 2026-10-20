// =============================================================================
// Step 2 of 2 - rebuild one account's contracts from its current extractions
// =============================================================================
// Run after rerunAccountExtractions.apex has finished (or on its own, to lay
// an account's contract terms down again from what is already extracted).
//
// For the account's current extractions this, in one step:
//   1. detaches them all from their contracts,
//   2. blanks the term fields the applier manages on every contract they were
//      on or now belong on (ContractLegalTermsApplier.clearedTerms: legal
//      terms, special terms, model changes, usage and credit fields, review
//      flag - contacts and billing details are kept),
//   3. re-applies them in deal order - new business / renewal / pilot first,
//      then amendments, each oldest first - so each lands where the applier
//      puts it today (an upsell on its base deal's contract) and genuine
//      conflicts are flagged again.
// ARR, seats and fees are not touched (the Quote Bot owns them).
//
// DRY_RUN = true (default) lists each contract and the deals that will land on
// it. Then set DRY_RUN = false.
//
// Run: sf apex run --target-org rogo --file scripts/apex/rebuildAccountContracts.apex
// =============================================================================

String ACCOUNT = 'Texas Capital';   // <-- account name (starts with), or an Account Id
Boolean DRY_RUN = true;            // <-- false to rebuild
Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

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

List<Order_Form_Extraction__c> fresh = new List<Order_Form_Extraction__c>();
List<Order_Form_Extraction__c> amends = new List<Order_Form_Extraction__c>();
Set<Id> rowIds = new Set<Id>();
Set<Id> contractIds = new Set<Id>();
for (Order_Form_Extraction__c r : [
    SELECT Id, Applied_Contract__c, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.CloseDate
    FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Opportunity__r.AccountId = :acct.Id
      AND Extraction_Status__c IN ('Success', 'Incomplete', 'No Order Form')
    ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
]) {
    rowIds.add(r.Id);
    if (r.Applied_Contract__c != null) contractIds.add(r.Applied_Contract__c);
    if (r.Opportunity__r.Type != null && AMEND.contains(r.Opportunity__r.Type)) amends.add(r);
    else fresh.add(r);
}
List<Order_Form_Extraction__c> ordered = new List<Order_Form_Extraction__c>(fresh);
ordered.addAll(amends);
Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(rowIds);
contractIds.addAll(targets.values());
Map<Id, Contract> contracts = new Map<Id, Contract>([
    SELECT Id, ContractNumber, Status FROM Contract WHERE Id IN :contractIds
]);

System.debug('--- ' + acct.Name + ': ' + ordered.size() + ' extraction(s), ' + contracts.size() + ' contract(s) to rebuild');
for (Order_Form_Extraction__c r : ordered) {
    Id t = targets.get(r.Id);
    String dest = t == null ? 'no contract of its own (left unapplied)' : contracts.get(t).ContractNumber + ' (' + contracts.get(t).Status + ')';
    System.debug(r.Opportunity__r.CloseDate + ' | ' + r.Opportunity__r.Name + ' [' + r.Opportunity__r.Type + '] -> ' + dest);
}
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to rebuild.');
    return;
}

Savepoint sp = Database.setSavepoint();
try {
    List<Order_Form_Extraction__c> detach = new List<Order_Form_Extraction__c>();
    for (Id rid : rowIds) detach.add(new Order_Form_Extraction__c(Id = rid, Applied_Contract__c = null));
    update detach;
    List<Contract> cleared = new List<Contract>();
    for (Id cid : contracts.keySet()) cleared.add(ContractLegalTermsApplier.clearedTerms(cid));
    update cleared;

    Map<Id, List<String>> logByContract = new Map<Id, List<String>>();
    for (Order_Form_Extraction__c r : ordered) {
        if (Limits.getQueries() > Limits.getLimitQueries() - 15 || Limits.getCpuTime() > Limits.getLimitCpuTime() - 1500) {
            System.debug('--- Stopped near a governor limit; the rest are unapplied - run applyContractTermsInOrder.apex to finish.');
            break;
        }
        ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
        req.extractionId = r.Id;
        ContractLegalTermsApplier.Result res = ContractLegalTermsApplier.apply(
            new List<ContractLegalTermsApplier.Request>{ req })[0];
        System.debug(r.Opportunity__r.Name + ' -> ' + res.status + (res.contractId == null || !contracts.containsKey(res.contractId)
            ? '' : ' on ' + contracts.get(res.contractId).ContractNumber));
        if (res.contractId == null) continue;
        if (!logByContract.containsKey(res.contractId)) logByContract.put(res.contractId, new List<String>());
        logByContract.get(res.contractId).add('[' + r.Opportunity__r.Name + '] ' + res.status
            + (String.isBlank(res.notes) ? '' : '\n' + res.notes));
    }
    List<Contract> notes = new List<Contract>();
    for (Id cid : logByContract.keySet()) {
        notes.add(new Contract(Id = cid, Reconciliation_Notes__c = ('Rebuilt ' + String.valueOf(Date.today())
            + ' from the account\'s current extractions, in deal order.\n\n'
            + String.join(logByContract.get(cid), '\n\n')).left(32768)));
    }
    update notes;
    System.debug('--- Rebuilt ' + contracts.size() + ' contract(s).');
} catch (Exception e) {
    Database.rollback(sp);
    System.debug('--- FAILED and rolled back: ' + e.getMessage());
}
