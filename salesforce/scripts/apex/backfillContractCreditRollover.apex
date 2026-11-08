// =============================================================================
// Lay credit rollover down on existing Contracts
// =============================================================================
// The extractor now reads what happens to unused credits when their period ends
// (Credit_Rollover__c: No Rollover / Negotiable / Partial / Full / Not
// specified, with Credit_Rollover_Percent__c for a capped share and the clause
// in Credit_Rollover_Terms__c), and the applier carries them onto the Contract.
// Contracts applied before that get them here, from the current extractions
// already applied to them, in deal order: a fresh deal writes, an amendment's
// silence keeps, a different answer on an amendment flags legal review.
// Only contracts whose Credit_Rollover__c is blank are touched.
//
// Run AFTER the deals have been re-read (a refresh, or the rerun buttons) -
// extractions made before this change have no rollover answer to lay down.
// DRY_RUN = true (default) counts what would be written and lists the
// conflicts. Then set DRY_RUN = false. One run covers every contract.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillContractCreditRollover.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write

Set<Id> contractIds = new Set<Id>();
for (AggregateResult ar : [
    SELECT Applied_Contract__c c FROM Order_Form_Extraction__c
    WHERE Applied_Contract__c != null AND Is_Current__c = true
    GROUP BY Applied_Contract__c
]) {
    contractIds.add((Id) ar.get('c'));
}

List<Contract> changes = ContractLegalTermsApplier.backfillCreditRollover(contractIds);

Map<String, Integer> byValue = new Map<String, Integer>();
Integer conflicts = 0;
for (Contract c : changes) {
    String v = c.Credit_Rollover__c + (c.Credit_Rollover_Percent__c == null ? '' : ' ' + c.Credit_Rollover_Percent__c + '%');
    byValue.put(v, (byValue.containsKey(v) ? byValue.get(v) : 0) + 1);
    if (c.Needs_Legal_Review__c == true) {
        conflicts++;
        System.debug('conflict: ' + c.Id + ' | ' + c.Reconciliation_Notes__c.substringAfterLast('Credit rollover laid down'));
    }
}
System.debug('--- Contracts with applied extractions: ' + contractIds.size() + '; contracts to fill: ' + changes.size()
    + '; flagged for legal review: ' + conflicts);
for (String v : byValue.keySet()) System.debug('   ' + v + ': ' + byValue.get(v));
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
