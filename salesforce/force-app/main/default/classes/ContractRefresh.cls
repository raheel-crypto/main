/**
 * Keeps contracts in step with their deals' latest extractions. A deal is
 * extracted when it closes, but its contract is usually created hours later,
 * and nothing applied the extraction once the contract existed, so those
 * contracts fell behind. Each run picks the accounts whose contracts are behind
 * and rebuilds them with ContractRebuildSweep: one account per job, the same as
 * the Contract "Rebuild Order Form Terms" button. ARR, seats and fees are never
 * touched.
 *
 * Behind means:
 *   - a current extraction is on no contract, and a contract for it now exists;
 *   - a contract still points at a superseded extraction;
 *   - a superseded extraction still counts on a contract its deal has moved off.
 * A deal whose contract does not exist yet waits until it does, so the same
 * accounts are not rebuilt night after night. An old version sitting beside its
 * deal's current one on the same contract is harmless (the applier counts each
 * deal once) and is not a reason.
 *
 * Runs nightly through ContractRefreshScheduler
 * (scripts/apex/scheduleContractRefresh.apex), and on demand from
 * scripts/apex/refreshContractsFromExtractions.apex.
 */
public with sharing class ContractRefresh implements Callable {

    public static final String UNAPPLIED = 'a current extraction is on no contract (its contract now exists)';
    public static final String POINTER = 'a contract points at a superseded extraction';
    public static final String MOVED_OFF = 'a superseded extraction still counts on a contract its deal moved off';
    private static final Set<String> APPLICABLE = new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };

    public class Selection {
        public Map<Id, Set<String>> reasons = new Map<Id, Set<String>>();   // account -> why it is behind
        public Integer waitingForContract = 0;   // current extractions whose contract does not exist yet
        public Integer harmless = 0;             // superseded extractions beside their deal's current one
    }

    /** The accounts whose contracts are behind their deals' extractions. */
    public static Selection stale() {
        Selection s = new Selection();

        Map<Id, Order_Form_Extraction__c> unapplied = new Map<Id, Order_Form_Extraction__c>([
            SELECT Id, Opportunity__r.AccountId FROM Order_Form_Extraction__c
            WHERE Is_Current__c = true AND Applied_Contract__c = null AND Extraction_Status__c IN :APPLICABLE
              AND Opportunity__r.AccountId != null
        ]);
        Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(unapplied.keySet());
        for (Order_Form_Extraction__c r : unapplied.values()) {
            if (targets.get(r.Id) == null) {
                s.waitingForContract++;
                continue;
            }
            add(s, r.Opportunity__r.AccountId, UNAPPLIED);
        }

        for (Contract c : [
            SELECT AccountId FROM Contract
            WHERE Latest_Order_Form_Extraction__c != null AND Latest_Order_Form_Extraction__r.Is_Current__c = false
              AND AccountId != null
        ]) {
            add(s, c.AccountId, POINTER);
        }

        List<Order_Form_Extraction__c> olds = [
            SELECT Opportunity__c, Applied_Contract__c, Applied_Contract__r.AccountId FROM Order_Form_Extraction__c
            WHERE Is_Current__c = false AND Applied_Contract__c != null AND Applied_Contract__r.AccountId != null
        ];
        Set<Id> oldOpps = new Set<Id>();
        for (Order_Form_Extraction__c r : olds) if (r.Opportunity__c != null) oldOpps.add(r.Opportunity__c);
        Map<Id, Id> currentContractByOpp = new Map<Id, Id>();
        if (!oldOpps.isEmpty()) {
            for (Order_Form_Extraction__c r : [
                SELECT Opportunity__c, Applied_Contract__c FROM Order_Form_Extraction__c
                WHERE Is_Current__c = true AND Opportunity__c IN :oldOpps
            ]) {
                currentContractByOpp.put(r.Opportunity__c, r.Applied_Contract__c);
            }
        }
        for (Order_Form_Extraction__c r : olds) {
            if (r.Opportunity__c != null && currentContractByOpp.containsKey(r.Opportunity__c)
                    && currentContractByOpp.get(r.Opportunity__c) == r.Applied_Contract__c) {
                s.harmless++;
                continue;
            }
            add(s, r.Applied_Contract__r.AccountId, MOVED_OFF);
        }
        return s;
    }

    private static void add(Selection s, Id accountId, String reason) {
        if (!s.reasons.containsKey(accountId)) s.reasons.put(accountId, new Set<String>());
        s.reasons.get(accountId).add(reason);
    }

    /** Rebuild the accounts whose contracts are behind. Returns what it started. */
    public static String run() {
        if (sweepRunning()) return 'A contract rebuild sweep is still running; nothing new was started.';
        Selection s = stale();
        if (s.reasons.isEmpty()) {
            return 'All contracts are in step with their extractions'
                + (s.waitingForContract > 0 ? ' (' + s.waitingForContract + ' extraction(s) wait for a contract).' : '.');
        }
        List<Id> accounts = new List<Id>(s.reasons.keySet());
        accounts.sort();
        System.enqueueJob(new ContractRebuildSweep(accounts));
        return 'Rebuilding ' + accounts.size() + ' account(s) whose contracts were behind their extractions.';
    }

    public static Boolean sweepRunning() {
        return [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'ContractRebuildSweep' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ] > 0;
    }

    /** For ContractRefreshScheduler, which calls this by name: call('run', null). */
    public Object call(String action, Map<String, Object> args) {
        if (action == 'run') return run();
        throw new IllegalArgumentException('Unknown action: ' + action);
    }
}
