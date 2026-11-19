/**
 * Legal's decisions on Contract Term Changes (ContractTermChangeTrigger): who
 * decided and when, and a rebuild of the contract so the decision lands -
 * Accepted writes the new term, Rejected keeps the contract's value, and
 * Needs Legal Review is cleared once nothing is left open.
 */
public with sharing class ContractTermChanges {

    private static final Set<String> DECIDED = new Set<String>{ 'Accepted', 'Rejected' };

    public static void beforeUpdate(List<Contract_Term_Change__c> rows, Map<Id, Contract_Term_Change__c> oldMap) {
        for (Contract_Term_Change__c r : rows) {
            Contract_Term_Change__c o = oldMap.get(r.Id);
            if (o != null && r.Status__c != o.Status__c && DECIDED.contains(r.Status__c)) {
                r.Decided_By__c = UserInfo.getUserId();
                r.Decided_At__c = System.now();
            }
        }
    }

    public static void afterUpdate(List<Contract_Term_Change__c> rows, Map<Id, Contract_Term_Change__c> oldMap) {
        Set<Id> contracts = new Set<Id>();
        for (Contract_Term_Change__c r : rows) {
            Contract_Term_Change__c o = oldMap.get(r.Id);
            if (o != null && r.Status__c != o.Status__c && DECIDED.contains(r.Status__c)) contracts.add(r.Contract__c);
        }
        if (contracts.isEmpty() || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        System.enqueueJob(new ContractRebuildJob(null, contracts));
    }
}
