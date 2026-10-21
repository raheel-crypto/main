/**
 * Rebuilds contracts from their deals' extractions, oldest first
 * (OrderFormOps.rebuild). When a governor limit comes near, the deals not yet
 * re-applied carry on in a follow-up job, which adds to the same notes.
 */
public with sharing class ContractRebuildJob implements Queueable {

    private Set<Id> accountIds;
    private Set<Id> contractIds;
    private List<Id> pending;   // a follow-up: the deals still to re-apply

    /** accountIds: every contract on these accounts; contractIds: these contracts (with accountIds: also these). */
    public ContractRebuildJob(Set<Id> accountIds, Set<Id> contractIds) {
        this.accountIds = accountIds;
        this.contractIds = contractIds;
    }

    private ContractRebuildJob(List<Id> pending) {
        this.pending = pending;
    }

    public void execute(QueueableContext ctx) {
        List<Id> left = pending != null
            ? OrderFormOps.applyInOrder(pending, false)
            : OrderFormOps.rebuild(accountIds, contractIds);
        if (!left.isEmpty() && !Test.isRunningTest()) System.enqueueJob(new ContractRebuildJob(left));
    }
}
