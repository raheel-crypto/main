// =============================================================================
// Fill blank billing details and the seat-adds term on existing Contracts
// =============================================================================
// The applier now carries the AP / billing email (Billing_Contact__c), the
// billing entity (Billing_Entity_Name__c) and its address
// (Billing_Entity_Address__c, plus the standard Billing Address when the line
// can be split) onto the Contract - filling blanks only, never overwriting.
// Contracts applied before that change get them here, from the current
// extractions already applied to them, in deal order (the earliest deal that
// states a value wins, as it would have on the first apply).
//
// It also adds Seat_Adds_By_Email__c (add-only: true once any applied deal
// lets the customer add seats by email / through the Account Executive) and
// fills Seat_Adds_By_Email_Terms__c when blank.
//
// Run AFTER the full refresh and applyContractTermsInOrder.apex.
// DRY_RUN = true (default) counts what would be filled and shows a sample of
// address splits. Then set DRY_RUN = false. One run covers every contract.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillContractBilling.apex
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

List<Contract> changes = ContractLegalTermsApplier.backfillBillingAndSeatAdds(contractIds);

Map<String, Integer> filled = new Map<String, Integer>{
    'Billing_Contact__c' => 0, 'Billing_Entity_Name__c' => 0, 'Billing_Entity_Address__c' => 0, 'BillingStreet' => 0,
    'Seat_Adds_By_Email__c' => 0
};
Integer shown = 0;
for (Contract c : changes) {
    Map<String, Object> f = c.getPopulatedFieldsAsMap();
    for (String k : filled.keySet()) if (f.containsKey(k)) filled.put(k, filled.get(k) + 1);
    if (f.containsKey('BillingStreet') && shown < 15) {
        System.debug('split: ' + c.Billing_Entity_Address__c + '  ->  ' + c.BillingStreet + ' | ' + c.BillingCity
            + ' | ' + c.BillingState + ' | ' + c.BillingPostalCode + ' | ' + c.BillingCountry);
        shown++;
    }
}
System.debug('--- Contracts with applied extractions: ' + contractIds.size() + '; contracts to fill: ' + changes.size());
System.debug('--- AP email: ' + filled.get('Billing_Contact__c') + '; billing entity: ' + filled.get('Billing_Entity_Name__c')
    + '; address text: ' + filled.get('Billing_Entity_Address__c') + '; standard address split: ' + filled.get('BillingStreet')
    + '; seat adds by email: ' + filled.get('Seat_Adds_By_Email__c'));
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
