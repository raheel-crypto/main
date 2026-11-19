/**
 * Writes the history of every contract marked Contract_History_Stale__c (set
 * when its terms are re-applied): the facts are hashed first, so only a contract
 * whose facts changed costs a Claude call (ContractHistory). Each job checks up
 * to CHECKS_PER_JOB contracts and makes up to CALLS_PER_JOB calls, saves, and
 * passes the rest to the next job. A failed call is noted on the contract
 * (Contract_History_Note__c) and not retried until its terms change again.
 * Started after contract rebuilds, by the nightly refresh, and by
 * scripts/apex/writeContractHistories.apex.
 */
public with sharing class ContractHistoryJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final Integer CHECKS_PER_JOB = 15;
    @TestVisible private static final Integer CALLS_PER_JOB = 2;
    private static final Integer CALLOUT_BUDGET_MS = 115000;

    private final Set<Id> only;   // null: every marked contract

    public ContractHistoryJob() {
        this(null);
    }

    public ContractHistoryJob(Set<Id> contractIds) {
        this.only = contractIds;
    }

    public void execute(QueueableContext ctx) {
        // One chain at a time: a second job started meanwhile leaves the work to the running one.
        Id self = ctx == null ? null : ctx.getJobId();
        if ([SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'ContractHistoryJob' AND Status = 'Processing'
             AND Id != :self] > 0) {
            return;
        }
        Integer waitingBefore = marked();
        runOnce();
        Integer waitingAfter = marked();
        // Go on only while each job makes progress (a contract that cannot be saved must not loop).
        if (waitingAfter > 0 && waitingAfter < waitingBefore && !Test.isRunningTest()) {
            System.enqueueJob(new ContractHistoryJob(only));
        }
    }

    private Integer marked() {
        return only == null
            ? [SELECT COUNT() FROM Contract WHERE Contract_History_Stale__c = true]
            : [SELECT COUNT() FROM Contract WHERE Contract_History_Stale__c = true AND Id IN :only];
    }

    /** One pass: check up to CHECKS_PER_JOB marked contracts; write those whose facts changed. */
    @TestVisible
    private void runOnce() {
        String modelName = ContractHistory.model();
        List<Contract> rows = only == null
            ? [SELECT Id, Contract_History_Hash__c FROM Contract WHERE Contract_History_Stale__c = true
               ORDER BY LastModifiedDate ASC LIMIT :CHECKS_PER_JOB]
            : [SELECT Id, Contract_History_Hash__c FROM Contract WHERE Contract_History_Stale__c = true AND Id IN :only
               ORDER BY LastModifiedDate ASC LIMIT :CHECKS_PER_JOB];
        List<Contract> updates = new List<Contract>();
        Integer calls = 0;
        Long spent = 0;
        for (Contract c : rows) {
            Contract u = new Contract(Id = c.Id, Contract_History_Stale__c = false);
            if (String.isBlank(modelName)) {
                updates.add(u);
                continue;
            }
            String factText = ContractHistory.facts(c.Id);
            String hash = ContractHistory.hashOf(factText, modelName);
            if (hash == c.Contract_History_Hash__c) {
                updates.add(u);
                continue;
            }
            if (calls >= CALLS_PER_JOB || spent > CALLOUT_BUDGET_MS - 30000) break;   // the next job takes it
            calls++;
            Long started = System.currentTimeMillis();
            try {
                Integer timeout = Math.min(60000L, CALLOUT_BUDGET_MS - spent).intValue();
                u.Contract_History__c = ContractHistory.write(factText, modelName, timeout).left(32768);
                u.Contract_History_Hash__c = hash;
                u.Contract_History_Updated__c = System.now();
                u.Contract_History_Note__c = null;
            } catch (Exception e) {
                u.Contract_History_Note__c = ('Not written ' + System.now().format('yyyy-MM-dd HH:mm') + ': '
                    + e.getMessage()).left(255);
            }
            spent += System.currentTimeMillis() - started;
            updates.add(u);
        }
        // Saved after every call: no DML may come before a callout in a transaction.
        if (!updates.isEmpty()) Database.update(updates, false);
    }
}
