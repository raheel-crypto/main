/**
 * Rebuilds the contracts of a list of accounts from their deals' current
 * extractions: the Contract "Rebuild Order Form Terms" button, for many accounts
 * (OrderFormOps.rebuild). One account per job, then the next job takes the next
 * account, so each contract is blanked and filled again in the same transaction.
 * When a governor limit comes near, the next job finishes that account's deals
 * before moving on. An account that fails is rolled back (its contracts keep the
 * terms they had) and the sweep goes on. ARR, seats and fees are never touched
 * (the Quote Bot owns them).
 *
 * Started by scripts/apex/refreshContractsFromExtractions.apex.
 */
public with sharing class ContractRebuildSweep implements Queueable {

    private final List<Id> accounts;   // still to rebuild, in order
    private final List<Id> pending;    // the current account's deals not yet re-applied

    public ContractRebuildSweep(List<Id> accountIds) {
        this(accountIds, null);
    }

    @TestVisible
    private ContractRebuildSweep(List<Id> accountIds, List<Id> pending) {
        this.accounts = accountIds == null ? new List<Id>() : new List<Id>(accountIds);
        this.pending = pending == null ? new List<Id>() : new List<Id>(pending);
    }

    public void execute(QueueableContext ctx) {
        List<Id> rest = new List<Id>(accounts);
        List<Id> left = step(rest, pending);
        // A test cannot chain jobs: run the rest here.
        Integer guard = 0;
        while (Test.isRunningTest() && !(left.isEmpty() && rest.isEmpty()) && guard++ < 50) left = step(rest, left);
        if (Test.isRunningTest()) return;
        // When every account is done, the histories of the rebuilt contracts follow
        // (only those whose inputs changed are rewritten).
        if (left.isEmpty() && rest.isEmpty()) System.enqueueJob(new ContractHistoryJob());
        else System.enqueueJob(new ContractRebuildSweep(rest, left));
    }

    /** Finish the current account's deals, or rebuild the next account (removed from rest). */
    private static List<Id> step(List<Id> rest, List<Id> pendingRows) {
        Boolean continuing = pendingRows != null && !pendingRows.isEmpty();
        if (!continuing && rest.isEmpty()) return new List<Id>();
        Id acct = continuing ? null : rest.remove(0);
        Savepoint sp = Database.setSavepoint();
        try {
            return continuing
                ? OrderFormOps.applyInOrder(pendingRows, false)
                : OrderFormOps.rebuild(new Set<Id>{ acct }, null);
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'Contract rebuild ' + (continuing ? 'continuation' : 'of account ' + acct)
                + ' failed and was rolled back: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return new List<Id>();
        }
    }
}
