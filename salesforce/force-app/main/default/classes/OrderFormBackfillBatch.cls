public with sharing class OrderFormBackfillBatch implements Database.Batchable<SObject>, Database.Stateful {

    @TestVisible private static final Integer SCOPE_SIZE = 50;

    private final Integer maxOpps;
    private Integer totalEnqueued = 0;
    private Integer totalSkippedNoFile = 0;
    private Integer totalSeen = 0;

    public OrderFormBackfillBatch() {
        this(null);
    }

    public OrderFormBackfillBatch(Integer maxOpps) {
        this.maxOpps = maxOpps;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String soql =
            'SELECT Id, Name ' +
            'FROM Opportunity ' +
            'WHERE StageName = \'Closed Won\' ' +
              'AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c) ' +
            'ORDER BY CloseDate DESC';
        if (maxOpps != null && maxOpps > 0) soql += ' LIMIT ' + maxOpps;
        return Database.getQueryLocator(soql);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> scope) {
        totalSeen += scope.size();

        Set<Id> oppIds = new Map<Id, Opportunity>(scope).keySet();

        Map<Id, List<Id>> docsByOpp = new Map<Id, List<Id>>();
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :oppIds
              AND ContentDocument.Title LIKE 'signed__%'
            ORDER BY ContentDocument.LastModifiedDate DESC
        ]) {
            List<Id> docs = docsByOpp.get(cdl.LinkedEntityId);
            if (docs == null) {
                docs = new List<Id>();
                docsByOpp.put(cdl.LinkedEntityId, docs);
            }
            docs.add(cdl.ContentDocumentId);
        }

        for (Opportunity opp : scope) {
            List<Id> docs = docsByOpp.get(opp.Id);
            if (docs == null || docs.isEmpty()) {
                totalSkippedNoFile++;
                continue;
            }
            System.enqueueJob(new OrderFormExtractionJob(opp.Id, docs));
            totalEnqueued++;
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'OrderFormBackfillBatch finished. ' +
            'Seen: ' + totalSeen + '; ' +
            'Enqueued: ' + totalEnqueued + '; ' +
            'Skipped (no signed__* file): ' + totalSkippedNoFile);
    }

    public static Id run() {
        return Database.executeBatch(new OrderFormBackfillBatch(), SCOPE_SIZE);
    }

    public static Id run(Integer maxOpps) {
        return Database.executeBatch(new OrderFormBackfillBatch(maxOpps), SCOPE_SIZE);
    }
}
