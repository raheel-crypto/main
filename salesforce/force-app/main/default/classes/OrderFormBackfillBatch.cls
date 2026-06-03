public with sharing class OrderFormBackfillBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {

    // Scope size must stay small because each Opp = one Anthropic callout (5-30 sec).
    // Per-transaction callout-time limit is 120 sec; size of 2 leaves headroom.
    @TestVisible private static final Integer SCOPE_SIZE = 2;

    private final Integer maxOpps;
    private Integer totalProcessed = 0;
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
        Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllSignedDocuments(oppIds);

        // Phase 1: callouts only. Build all rows in memory. NO DML yet -
        // otherwise the next callout fails with "uncommitted work pending".
        List<Order_Form_Extraction__c> rowsToInsert = new List<Order_Form_Extraction__c>();
        for (Opportunity opp : scope) {
            List<Id> docs = docsByOpp.get(opp.Id);
            if (docs == null || docs.isEmpty()) {
                totalSkippedNoFile++;
                continue;
            }
            rowsToInsert.add(OrderFormExtractionJob.buildExtraction(opp.Id, docs));
            totalProcessed++;
        }

        // Phase 2: bulk DML after all callouts.
        if (!rowsToInsert.isEmpty()) insert rowsToInsert;
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'OrderFormBackfillBatch finished. ' +
            'Seen: ' + totalSeen + '; ' +
            'Processed: ' + totalProcessed + '; ' +
            'Skipped (no signed__* file): ' + totalSkippedNoFile);
    }

    public static Id run() {
        return Database.executeBatch(new OrderFormBackfillBatch(), SCOPE_SIZE);
    }

    public static Id run(Integer maxOpps) {
        return Database.executeBatch(new OrderFormBackfillBatch(maxOpps), SCOPE_SIZE);
    }
}
