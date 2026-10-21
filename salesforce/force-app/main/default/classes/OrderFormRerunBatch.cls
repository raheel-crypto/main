/**
 * Re-reads chosen deals (OrderFormOps.rerunAccount / rerunOpportunity), one
 * per transaction, oldest first, then rebuilds the contracts they land on.
 *
 * Each deal is read from every file on it and its base deal. A readable result
 * replaces the current extraction even when it ranks lower on the quality
 * ladder (a person asked for the re-read) - unless the re-read had to leave
 * files out and the current row did not: rows from the large-document script
 * read everything, so there the ladder decides. The old row stays as history.
 *
 * finish: account mode rebuilds every contract on the accounts; deal mode
 * rebuilds the contract the deal now belongs on and the one it was on.
 */
public with sharing class OrderFormRerunBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final Set<Id> oppIds;
    private final Set<Id> rebuildAccountIds;
    // Contracts the re-read deals were on before the re-read (deal mode).
    private Set<Id> priorContracts = new Set<Id>();
    private Integer replaced = 0;
    private Integer kept = 0;

    /** rebuildAccountIds: rebuild these accounts' contracts afterwards; null = only the deals' contracts. */
    public OrderFormRerunBatch(Set<Id> oppIds, Set<Id> rebuildAccountIds) {
        this.oppIds = oppIds == null ? new Set<Id>() : oppIds;
        this.rebuildAccountIds = rebuildAccountIds;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Set<Id> ids = oppIds;
        return Database.getQueryLocator([
            SELECT Id FROM Opportunity WHERE Id IN :ids ORDER BY CloseDate ASC, CreatedDate ASC
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        Set<Id> ids = new Map<Id, Opportunity>(scope).keySet();
        Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(ids);
        Map<Id, Order_Form_Extraction__c> currentByOpp = new Map<Id, Order_Form_Extraction__c>();
        for (Order_Form_Extraction__c r : [
            SELECT Id, Opportunity__c, Docs_Dropped__c, Applied_Contract__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c IN :ids AND Is_Current__c = true
        ]) {
            currentByOpp.put(r.Opportunity__c, r);
        }

        // Callouts first - no DML until every read in the scope is back.
        List<Order_Form_Extraction__c> rows = new List<Order_Form_Extraction__c>();
        for (Opportunity o : scope) {
            List<Id> docs = docsByOpp.get(o.Id);
            if (docs == null || docs.isEmpty()) continue;
            rows.add(OrderFormExtractionJob.buildExtraction(o.Id, docs));
        }
        if (rows.isEmpty()) return;

        Set<Id> forced = new Set<Id>();
        for (Order_Form_Extraction__c r : rows) {
            Order_Form_Extraction__c cur = currentByOpp.get(r.Opportunity__c);
            if (cur == null || r.Docs_Dropped__c != true || cur.Docs_Dropped__c == true) forced.add(r.Opportunity__c);
        }
        OrderFormVersioning.insertWithVersioning(rows, forced);
        OrderFormExtractionJob.splitRenewalUpsellPairs(ids);

        Set<Id> nowCurrent = new Set<Id>();
        for (Order_Form_Extraction__c r : rows) {
            if (r.Is_Current__c == true) { nowCurrent.add(r.Opportunity__c); replaced++; }
            else kept++;
            Order_Form_Extraction__c cur = currentByOpp.get(r.Opportunity__c);
            if (cur != null && cur.Applied_Contract__c != null) priorContracts.add(cur.Applied_Contract__c);
        }
        // A rerun flag on a replaced row is done with.
        if (!nowCurrent.isEmpty()) {
            List<Order_Form_Extraction__c> flagged = [
                SELECT Id FROM Order_Form_Extraction__c WHERE Rerun__c = true AND Opportunity__c IN :nowCurrent
            ];
            for (Order_Form_Extraction__c f : flagged) f.Rerun__c = false;
            if (!flagged.isEmpty()) update flagged;
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'OrderFormRerunBatch finished. Replaced: ' + replaced
            + '; kept the existing row (the re-read was not usable): ' + kept);
        Set<Id> accounts = rebuildAccountIds;
        Set<Id> contracts = new Set<Id>(priorContracts);
        if (accounts == null || accounts.isEmpty()) {
            Set<Id> rowIds = new Map<Id, Order_Form_Extraction__c>([
                SELECT Id FROM Order_Form_Extraction__c
                WHERE Opportunity__c IN :oppIds AND Is_Current__c = true
            ]).keySet();
            contracts.addAll(ContractLegalTermsApplier.currentTargets(rowIds).values());
            contracts.remove(null);
            if (contracts.isEmpty()) return;
        }
        if (Test.isRunningTest()) {
            OrderFormOps.rebuild(accounts, contracts);   // a test cannot run a job chained from a batch
        } else {
            System.enqueueJob(new ContractRebuildJob(accounts, contracts));
        }
    }
}
