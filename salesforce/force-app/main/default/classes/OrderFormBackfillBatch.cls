public with sharing class OrderFormBackfillBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {

    // Scope size must stay small because each Opp = one Anthropic callout (5-30 sec).
    // Per-transaction callout-time limit is 120 sec; size of 2 leaves headroom.
    @TestVisible private static final Integer SCOPE_SIZE = 2;

    private final Integer maxOpps;
    private final Boolean rescanMode;
    private final Datetime rescanCutoff;
    // Set only by runRerunFlagged(): re-extract Opps whose OFE is flagged
    // Rerun__c = true. The new row supersedes the flagged one (kept as version
    // history) and the flag clears once the rerun is current. Stateful, so it
    // survives across execute() calls once set before executeBatch.
    private Boolean rerunFlagged = false;
    // Set only by runRefresh(): re-extract the current row per opp and UPDATE it
    // in place when the fresh read ranks at least as high (OrderFormVersioning) -
    // so no new duplicate rows and a failed or thinner rerun never clobbers good
    // data. refreshCutoff makes a re-run resumable (skip opps already refreshed).
    private Boolean refreshMode = false;
    private Datetime refreshCutoff;
    private Integer totalProcessed = 0;
    private Integer totalSkippedNoFile = 0;
    private Integer totalRefreshSkipped = 0;
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
        if (rerunFlagged) {
            // Only Opps whose extraction was flagged for re-run.
            return Database.getQueryLocator(
                'SELECT Id, Name FROM Opportunity ' +
                'WHERE Id IN (SELECT Opportunity__c FROM Order_Form_Extraction__c WHERE Rerun__c = true) ' +
                'ORDER BY CloseDate DESC'
            );
        }
        // Declared at method scope so the dynamic-SOQL bind :cutoff resolves.
        Datetime cutoff = (refreshMode ? refreshCutoff : rescanCutoff);
        if (cutoff == null) cutoff = Datetime.now();
        if (refreshMode) {
            // Every Closed Won opp EXCEPT those already refreshed in this pass
            // (an extraction row modified at/after the cutoff). execute() updates
            // the latest row in place.
            return Database.getQueryLocator(
                'SELECT Id, Name FROM Opportunity ' +
                'WHERE StageName = \'Closed Won\' ' +
                'AND Id NOT IN (SELECT Opportunity__c FROM Order_Form_Extraction__c WHERE LastModifiedDate >= :cutoff) ' +
                'ORDER BY CloseDate DESC'
            );
        }
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
        Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(oppIds);

        if (refreshMode) {
            executeRefresh(scope, oppIds, docsByOpp);
            return;
        }

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

        // Phase 2: bulk DML after all callouts. Each new row links to the row it
        // supersedes and only becomes current if it ranks at least as high -
        // except for opps a person flagged for rerun, where any readable result
        // replaces the flagged row.
        if (rowsToInsert.isEmpty()) return;
        Set<Id> reExtracted = new Set<Id>();
        for (Order_Form_Extraction__c r : rowsToInsert) reExtracted.add(r.Opportunity__c);
        OrderFormVersioning.insertWithVersioning(rowsToInsert, rerunFlagged ? reExtracted : null);

        // Rerun-flagged mode: keep the flagged rows (they are the version history
        // the new rows point back to) and clear the flag wherever the rerun took
        // over as current. A failed rerun leaves the flag set so it is retried.
        if (rerunFlagged) {
            Set<Id> replaced = new Set<Id>();
            for (Order_Form_Extraction__c r : rowsToInsert) if (r.Is_Current__c == true) replaced.add(r.Opportunity__c);
            if (!replaced.isEmpty()) {
                List<Order_Form_Extraction__c> cleared = [
                    SELECT Id FROM Order_Form_Extraction__c
                    WHERE Rerun__c = true AND Opportunity__c IN :replaced
                ];
                for (Order_Form_Extraction__c c : cleared) c.Rerun__c = false;
                update cleared;
            }
        }
    }

    // Refresh mode: re-extract each opp's CURRENT row and update it IN PLACE when
    // the fresh read ranks at least as high on the quality ladder (see
    // OrderFormVersioning). That corrects a hollow legacy "Success" to No Order
    // Form / Incomplete, while a failed or thinner rerun never clobbers a
    // complete row. Opps with no extraction get a new row. No duplicate rows.
    private void executeRefresh(List<Opportunity> scope, Set<Id> oppIds, Map<Id, List<Id>> docsByOpp) {
        Map<Id, Order_Form_Extraction__c> currentByOpp = OrderFormVersioning.loadCurrentByOpp(oppIds);

        Datetime cutoff = (refreshCutoff != null) ? refreshCutoff : Datetime.now();
        List<Order_Form_Extraction__c> toUpdate = new List<Order_Form_Extraction__c>();
        List<Order_Form_Extraction__c> toInsert = new List<Order_Form_Extraction__c>();
        for (Opportunity opp : scope) {
            Order_Form_Extraction__c existing = currentByOpp.get(opp.Id);
            if (existing != null && existing.LastModifiedDate >= cutoff) continue; // already refreshed this pass

            List<Id> docs = docsByOpp.get(opp.Id);
            if (docs == null || docs.isEmpty()) { totalSkippedNoFile++; continue; }

            Order_Form_Extraction__c fresh = OrderFormExtractionJob.buildExtraction(opp.Id, docs);
            if (existing == null) {
                toInsert.add(fresh);                          // no prior row - record the attempt
                totalProcessed++;
            } else if (OrderFormVersioning.isAtLeastAsGood(fresh, existing)) {
                fresh.Id = existing.Id;                       // update in place (keeps Applied_* / Supersedes__c)
                fresh.Is_Current__c = true;
                toUpdate.add(fresh);
                totalProcessed++;
            } else {
                totalRefreshSkipped++;                        // failed or thinner rerun - keep the good row
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!toInsert.isEmpty()) OrderFormVersioning.insertWithVersioning(toInsert);
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'OrderFormBackfillBatch finished. ' +
            'Seen: ' + totalSeen + '; ' +
            'Processed: ' + totalProcessed + '; ' +
            'Skipped (no documents): ' + totalSkippedNoFile + '; ' +
            'Refresh skipped (failed or thinner rerun, row kept): ' + totalRefreshSkipped);
    }

    public static Id run() {
        return Database.executeBatch(new OrderFormBackfillBatch(), SCOPE_SIZE);
    }

    public static Id run(Integer maxOpps) {
        return Database.executeBatch(new OrderFormBackfillBatch(maxOpps), SCOPE_SIZE);
    }

    // Re-scan the whole book: re-extract EVERY Closed Won Opp that has documents,
    // including ones already extracted, so newly-added fields (e.g.
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

    // Re-extract every Opp whose OFE is flagged Rerun__c = true (all documents).
    // The new row links to the flagged one via Supersedes__c and the flag clears
    // when the rerun becomes current (a failed rerun stays flagged). One unattended pass - no
    // 50-Queueable-per-run cap. Use this to re-do a targeted set (e.g. the opps
    // extracted before all-document support landed) after checking Rerun__c on
    // their extraction rows in a list view.
    public static Id runRerunFlagged() {
        OrderFormBackfillBatch b = new OrderFormBackfillBatch();
        b.rerunFlagged = true;
        return Database.executeBatch(b, SCOPE_SIZE);
    }

    // Re-extract the LATEST row per Closed Won opp and update it in place - one
    // current row per opp, refreshed with the latest prompt/mapping. Overwrites
    // only on a fresh Success (failed reruns leave the existing row untouched);
    // inserts only for opps that had no extraction. No duplicate rows, so no
    // dedupe afterward. This is the cleanest way to re-apply prompt changes.
    public static Id runRefresh() {
        OrderFormBackfillBatch b = new OrderFormBackfillBatch();
        b.refreshMode = true;
        b.refreshCutoff = Datetime.now();
        return Database.executeBatch(b, SCOPE_SIZE);
    }

    // Resume a partially-completed refresh: pass the timestamp of when the pass
    // first started so opps already refreshed in this pass are skipped.
    public static Id runRefresh(Datetime cutoff) {
        OrderFormBackfillBatch b = new OrderFormBackfillBatch();
        b.refreshMode = true;
        b.refreshCutoff = cutoff;
        return Database.executeBatch(b, SCOPE_SIZE);
    }
}
