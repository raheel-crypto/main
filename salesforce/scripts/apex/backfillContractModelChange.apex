// =============================================================================
// Lay legal's "Model changes: notice or approval" column onto Contracts
// =============================================================================
// Most Contracts were applied before the column existed, and a refresh updates
// extraction rows in place without re-applying them, so the Contract column is
// blank on most of the book while the extractions have it. This fills it, for
// Contracts where it is blank only, from the current extractions applied to
// each Contract in deal order - the same rules as an apply: a fresh deal
// writes; an amendment saying "None identified" / "Unresolved" keeps the
// answer; a different real answer on an amendment is a conflict, which flags
// legal review and is noted on the Contract.
//
// DRY_RUN = true (default) shows the counts by answer and every conflict.
// Then set DRY_RUN = false. One run covers every contract.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillContractModelChange.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write

Set<Id> contractIds = new Set<Id>();
for (AggregateResult ar : [
    SELECT Applied_Contract__c c FROM Order_Form_Extraction__c
    WHERE Applied_Contract__c != null AND Is_Current__c = true AND Model_Change_Requirement__c != null
    GROUP BY Applied_Contract__c
]) {
    contractIds.add((Id) ar.get('c'));
}

List<Contract> changes = ContractLegalTermsApplier.backfillModelChange(contractIds);

Map<String, Integer> byAnswer = new Map<String, Integer>();
Integer conflicts = 0;
for (Contract c : changes) {
    String v = c.Model_Change_Requirement__c == null ? '(blank)' : c.Model_Change_Requirement__c;
    byAnswer.put(v, (byAnswer.containsKey(v) ? byAnswer.get(v) : 0) + 1);
    if (c.Needs_Legal_Review__c == true) {
        conflicts++;
        System.debug('CONFLICT ' + c.Id + ': ' + c.Reconciliation_Notes__c.substringAfterLast('Model changes column laid down').left(600));
    }
}
System.debug('--- Contracts to fill: ' + changes.size() + ' ' + byAnswer + '; conflicts flagged for review: ' + conflicts);
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to fill.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(changes, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
System.debug('--- Filled ' + ok + ' of ' + changes.size() + ' contracts.');
