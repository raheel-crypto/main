public with sharing class OrderFormBackfillBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {

    // Scope size must stay small because each Opp = one Anthropic callout (5-30 sec).
    // Per-transaction callout-time limit is 120 sec; size of 2 leaves headroom.
    @TestVisible private static final Integer SCOPE_SIZE = 2;

    private final Integer maxOpps;
    private final Boolean rescanMode;
    private final Datetime rescanCutoff;
    private Integer totalProcessed = 0;
    private Integer totalSkippedNoFile = 0;
    private Integer totalSeen = 0;

    public OrderFormBackfillBatch() {
        this(null);
    }

    // Incremental backfill: only Opps that have never been extracted.
    public OrderFormBackfillBatch(Integer maxOpps) {
        this.maxOpps = maxOpps;
        this.rescanMode = false;
        this.rescanCutoff = null;
    }

    // Re-scan: re-process Closed Won Opps that ALREADY have extractions (not
    // just brand-new ones) so newly-added fields populate across the whole book.
    // rescanCutoff makes a re-run resumable - Opps that already got a fresh row
    // at/after the cutoff are skipped; pass the same cutoff to resume a pass.
    public OrderFormBackfillBatch(Boolean rescanMode, Datetime rescanCutoff, Integer maxOpps) {
        this.maxOpps = maxOpps;
        this.rescanMode = (rescanMode == true);
        this.rescanCutoff = rescanCutoff;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Declared at method scope so the dynamic-SOQL bind :cutoff resolves.
        Datetime cutoff = (rescanCutoff != null) ? rescanCutoff : Datetime.now();
        String soql =
            'SELECT Id, Name ' +
            'FROM Opportunity ' +
            'WHERE StageName = \'Closed Won\' ';
        if (rescanMode) {
            // Include already-extracted Opps; skip only those re-scanned in THIS
            // pass (a row created at/after the cutoff) so a re-run resumes.
            soql += 'AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c WHERE CreatedDate >= :cutoff) ';
        } else {
            soql += 'AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c) ';
        }
        soql += 'ORDER BY CloseDate DESC';
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

    // Re-scan the whole book: re-extract EVERY Closed Won Opp with a signed__*
    // file, including ones already extracted, so newly-added fields (e.g.
    // Sub_Processor_List__c) get populated. One call processes everything
    // unattended - no 50-Queueable-per-run cap. Each Opp gets a fresh row
    // appended; the newest row per Opp is the current truth.
    public static Id runRescan() {
        return Database.executeBatch(new OrderFormBackfillBatch(true, Datetime.now(), null), SCOPE_SIZE);
    }

    // Resume a partially-completed re-scan: pass the timestamp of when the pass
    // first started so Opps already re-done in this pass are skipped.
    public static Id runRescan(Datetime cutoff) {
        return Database.executeBatch(new OrderFormBackfillBatch(true, cutoff, null), SCOPE_SIZE);
    }
}
