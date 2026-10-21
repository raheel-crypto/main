/**
 * Self-service operations on order form extractions and contract terms, for
 * buttons (see the *Action invocables) and anonymous Apex:
 *
 *   OrderFormOps.rerunAccount('001...');      re-read every closed-won deal on the
 *                                             account, then rebuild its contracts
 *   OrderFormOps.rerunOpportunity('006...');  re-read one deal, then rebuild the
 *                                             contract it lands on
 *   OrderFormOps.rebuildContract('800...');   re-apply a contract's deals, oldest
 *                                             first (no re-reading)
 *   OrderFormOps.rebuildAccount('001...');    the same for every contract on an account
 *
 * Re-reads run in OrderFormRerunBatch (one deal at a time, oldest first); a
 * readable result replaces the deal's current extraction - except that a read
 * which had to leave files out never replaces one that did not (rows written
 * by the large-document script keep their fuller read; the re-read is kept as
 * history). Rebuilds run in
 * ContractRebuildJob: the deals' extractions are detached, the term fields the
 * applier manages are blanked (contacts and billing kept), and the deals are
 * re-applied new business / renewal / pilot first, then amendments, each
 * oldest first. ARR, seats and fees are never touched (the Quote Bot owns them).
 * Every method returns a message saying what was started.
 */
public with sharing class OrderFormOps {

    private static final Set<String> AMEND_TYPES = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };
    private static final Set<String> APPLICABLE = new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };
    // Left on a blanked contract until a deal lands on it.
    @TestVisible private static final String NONE_LANDED = 'No deal\'s terms belong on this contract now.';

    public static String rerunAccount(Id accountId) {
        Account acct = accountOf(accountId);
        if (acct == null) return 'Account not found.';
        Set<Id> oppIds = new Map<Id, Opportunity>([
            SELECT Id FROM Opportunity WHERE AccountId = :acct.Id AND StageName = 'Closed Won'
        ]).keySet();
        Set<Id> withFiles = withDocuments(oppIds);
        if (withFiles.isEmpty()) {
            return 'No closed-won deals with files on ' + acct.Name + ' - nothing to re-read. '
                + 'Use the contract rebuild to re-apply existing extractions.';
        }
        Database.executeBatch(new OrderFormRerunBatch(withFiles, new Set<Id>{ acct.Id }), 1);
        return 'Re-reading ' + withFiles.size() + ' deal(s) on ' + acct.Name + ', oldest first. When they finish '
            + '(roughly a minute each), the account\'s contracts are rebuilt from the new reads in deal order. '
            + 'Progress: Setup > Apex Jobs.';
    }

    public static String rerunOpportunity(Id opportunityId) {
        List<Opportunity> opps = [SELECT Id, Name FROM Opportunity WHERE Id = :opportunityId];
        if (opps.isEmpty()) return 'Opportunity not found.';
        if (withDocuments(new Set<Id>{ opps[0].Id }).isEmpty()) {
            return 'No files on ' + opps[0].Name + ' or its base deal - nothing to re-read.';
        }
        Database.executeBatch(new OrderFormRerunBatch(new Set<Id>{ opps[0].Id }, null), 1);
        return 'Re-reading ' + opps[0].Name + '. When it finishes (a minute or two), the contract it lands on '
            + 'is rebuilt from all of its deals in order. Progress: Setup > Apex Jobs.';
    }

    public static String rebuildContract(Id contractId) {
        List<Contract> cs = [SELECT Id, ContractNumber FROM Contract WHERE Id = :contractId];
        if (cs.isEmpty()) return 'Contract not found.';
        System.enqueueJob(new ContractRebuildJob(null, new Set<Id>{ cs[0].Id }));
        return 'Rebuilding contract ' + cs[0].ContractNumber + ' from its deals, oldest first. '
            + 'Refresh the page in a minute; the Reconciliation Notes show what each deal applied.';
    }

    public static String rebuildAccount(Id accountId) {
        Account acct = accountOf(accountId);
        if (acct == null) return 'Account not found.';
        System.enqueueJob(new ContractRebuildJob(new Set<Id>{ acct.Id }, null));
        return 'Rebuilding every contract on ' + acct.Name + ' from its deals, oldest first. Refresh in a minute.';
    }

    // ===== Rebuild (run by ContractRebuildJob) =====

    /**
     * Detach, blank and re-apply. With accountIds: every current extraction on
     * the accounts, and every contract they are on or belong on (plus any
     * contractIds given - e.g. where a re-read deal used to sit). With only
     * contractIds: the extractions applied to or belonging on those contracts,
     * and only those contracts are blanked - widened to any contract those
     * extractions now belong on, so each blanked contract gets all of its deals
     * back and no contract gets one deal laid on top. Returns the extractions not yet
     * re-applied (when a governor limit is near) for the caller to continue.
     */
    public static List<Id> rebuild(Set<Id> accountIds, Set<Id> contractIds) {
        Set<Id> extra = contractIds == null ? new Set<Id>() : new Set<Id>(contractIds);
        extra.remove(null);
        Boolean byContract = accountIds == null || accountIds.isEmpty();
        Set<Id> accounts = byContract ? new Set<Id>() : new Set<Id>(accountIds);
        if (!extra.isEmpty()) {
            for (Contract c : [SELECT AccountId FROM Contract WHERE Id IN :extra AND AccountId != null]) {
                accounts.add(c.AccountId);
            }
        }
        if (accounts.isEmpty()) return new List<Id>();

        List<Order_Form_Extraction__c> rows = [
            SELECT Id, Applied_Contract__c, Opportunity__r.Type
            FROM Order_Form_Extraction__c
            WHERE Is_Current__c = true AND Opportunity__r.AccountId IN :accounts
              AND Extraction_Status__c IN :APPLICABLE
            ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
        ];
        Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(new Map<Id, Order_Form_Extraction__c>(rows).keySet());
        Boolean grew = byContract;
        while (grew) {
            grew = false;
            for (Order_Form_Extraction__c r : rows) {
                Id t = targets.get(r.Id);
                if (!extra.contains(r.Applied_Contract__c) && !extra.contains(t)) continue;
                if (r.Applied_Contract__c != null && extra.add(r.Applied_Contract__c)) grew = true;
                if (t != null && extra.add(t)) grew = true;
            }
        }

        List<Id> fresh = new List<Id>();
        List<Id> amends = new List<Id>();
        Set<Id> toClear = new Set<Id>(extra);
        List<Order_Form_Extraction__c> detach = new List<Order_Form_Extraction__c>();
        for (Order_Form_Extraction__c r : rows) {
            Id t = targets.get(r.Id);
            if (byContract && !extra.contains(r.Applied_Contract__c) && !extra.contains(t)) continue;
            if (!byContract) {
                if (r.Applied_Contract__c != null) toClear.add(r.Applied_Contract__c);
                if (t != null) toClear.add(t);
            }
            if (r.Applied_Contract__c != null) detach.add(new Order_Form_Extraction__c(Id = r.Id, Applied_Contract__c = null));
            if (r.Opportunity__r != null && AMEND_TYPES.contains(r.Opportunity__r.Type)) amends.add(r.Id);
            else fresh.add(r.Id);
        }
        if (!detach.isEmpty()) update detach;
        List<Contract> cleared = new List<Contract>();
        for (Id cid : toClear) {
            Contract c = ContractLegalTermsApplier.clearedTerms(cid);
            c.Reconciliation_Notes__c = header() + '\n\n' + NONE_LANDED;
            cleared.add(c);
        }
        if (!cleared.isEmpty()) update cleared;

        List<Id> ordered = new List<Id>(fresh);
        ordered.addAll(amends);
        return applyInOrder(ordered, true);
    }

    /**
     * Apply these extractions one at a time in the given order, each through
     * ContractLegalTermsApplier, and record one combined note per contract
     * (startNotes: replace the notes; otherwise append - a continuation).
     * Stops near a governor limit and returns the ones not yet applied.
     */
    public static List<Id> applyInOrder(List<Id> rowIds, Boolean startNotes) {
        List<Id> left = new List<Id>();
        if (rowIds == null || rowIds.isEmpty()) return left;
        Map<Id, Order_Form_Extraction__c> byId = new Map<Id, Order_Form_Extraction__c>([
            SELECT Id, Opportunity__r.Name FROM Order_Form_Extraction__c WHERE Id IN :rowIds
        ]);
        // A continuation adds to the notes so far - read before each apply
        // overwrites them with its own.
        Map<Id, Contract> existing = new Map<Id, Contract>();
        if (!startNotes) {
            Set<Id> targets = new Set<Id>(ContractLegalTermsApplier.currentTargets(byId.keySet()).values());
            existing = new Map<Id, Contract>([SELECT Id, Reconciliation_Notes__c FROM Contract WHERE Id IN :targets]);
        }
        Map<Id, List<String>> logByContract = new Map<Id, List<String>>();
        for (Integer i = 0; i < rowIds.size(); i++) {
            if (Limits.getQueries() > Limits.getLimitQueries() - 25
                    || Limits.getDmlStatements() > Limits.getLimitDmlStatements() - 15
                    || Limits.getCpuTime() > Limits.getLimitCpuTime() - 5000) {
                for (Integer j = i; j < rowIds.size(); j++) left.add(rowIds[j]);
                break;
            }
            Order_Form_Extraction__c r = byId.get(rowIds[i]);
            if (r == null) continue;
            ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
            req.extractionId = r.Id;
            ContractLegalTermsApplier.Result res = ContractLegalTermsApplier.apply(
                new List<ContractLegalTermsApplier.Request>{ req })[0];
            if (res.contractId == null) continue;
            if (!logByContract.containsKey(res.contractId)) logByContract.put(res.contractId, new List<String>());
            logByContract.get(res.contractId).add('[' + (r.Opportunity__r == null ? String.valueOf(r.Id) : r.Opportunity__r.Name)
                + '] ' + res.status + (String.isBlank(res.notes) ? '' : '\n' + res.notes));
        }
        if (logByContract.isEmpty()) return left;
        List<Contract> notes = new List<Contract>();
        for (Id cid : logByContract.keySet()) {
            String body = String.join(logByContract.get(cid), '\n\n');
            String prior = existing.containsKey(cid) ? existing.get(cid).Reconciliation_Notes__c : null;
            if (prior != null) prior = prior.removeEnd(NONE_LANDED).trim();
            String text = String.isBlank(prior) ? header() + '\n\n' + body : prior + '\n\n' + body;
            notes.add(new Contract(Id = cid, Reconciliation_Notes__c = text.left(32768)));
        }
        update notes;
        return left;
    }

    // ===== Helpers =====

    private static String header() {
        return 'Rebuilt ' + String.valueOf(Date.today()) + ' from this contract\'s deals, oldest first.';
    }

    private static Account accountOf(Id accountId) {
        List<Account> accts = [SELECT Id, Name FROM Account WHERE Id = :accountId];
        return accts.isEmpty() ? null : accts[0];
    }

    private static Set<Id> withDocuments(Set<Id> oppIds) {
        Set<Id> out = new Set<Id>();
        if (oppIds == null || oppIds.isEmpty()) return out;
        Map<Id, List<Id>> docs = OrderFormExtractor.findAllDocuments(oppIds);
        for (Id o : oppIds) if (docs.containsKey(o) && !docs.get(o).isEmpty()) out.add(o);
        return out;
    }
}
