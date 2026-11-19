// Legal's decisions on Contract Term Changes: stamps who decided and rebuilds
// the contract so the decision lands (ContractTermChanges).
trigger ContractTermChangeTrigger on Contract_Term_Change__c (before update, after update) {
    if (Trigger.isBefore) ContractTermChanges.beforeUpdate(Trigger.new, Trigger.oldMap);
    else ContractTermChanges.afterUpdate(Trigger.new, Trigger.oldMap);
}
