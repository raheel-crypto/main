/**
 * Backfills product lines on extractions read before line items existed.
 * scripts/apex/backfillOrderFormLines.apex runs it.
 *
 * Each deal's files are re-read with a focused prompt - the LINE ITEMS rules of
 * the extraction prompt and its Line_Items schema, asking nothing else - and
 * only the line fields are written to the deal's current extraction
 * (OrderFormExtractionJob.linesFrom: Line_Items__c, the per-product totals and
 * the audit against the row's ARR). The trigger turns Line_Items__c into
 * Order_Form_Line__c records. Every other field is left as it is.
 *
 * A reply with no lines is saved only when every file was read; when a file had
 * to be left out the lines may be in it, so the row stays unread and a later
 * run tries again. An unusable reply also leaves it unread.
 */
public with sharing class OrderFormLinesBackfillBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final String prompt;
    private Map<String, Integer> outcomes = new Map<String, Integer>();

    public OrderFormLinesBackfillBatch() {
        this.prompt = linesPrompt();
    }

    /** The current order form extractions whose lines have not been read. */
    public static final String TARGET_WHERE = 'WHERE Is_Current__c = true AND Lines_Read_At__c = null'
        + ' AND Extraction_Status__c IN (\'Success\', \'Incomplete\')'
        + ' AND Opportunity__r.StageName = \'Closed Won\'';

    public static Integer countTargets() {
        return Database.countQuery('SELECT COUNT() FROM Order_Form_Extraction__c ' + TARGET_WHERE);
    }

    @TestVisible
    private static String linesPrompt() {
        return 'You are a precise contract-data extractor. You receive the documents of ONE commercial deal and list '
            + 'what the CURRENT deal\'s paper sells, line by line. Return ONE JSON object and nothing else - no prose, '
            + 'no markdown - with exactly this key:\n{' + OrderFormExtractionJob.promptSchemaLine('Line_Items') + '}\n\n'
            + OrderFormExtractionJob.promptSection('LINE ITEMS');
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id, Opportunity__c FROM Order_Form_Extraction__c ' + TARGET_WHERE
            + ' ORDER BY Opportunity__r.CloseDate DESC NULLS LAST');
    }

    public void execute(Database.BatchableContext bc, List<Order_Form_Extraction__c> scope) {
        // Every read first: no DML may come before a callout in the transaction.
        Map<Id, Map<String, Object>> replies = new Map<Id, Map<String, Object>>();
        Map<Id, Boolean> partial = new Map<Id, Boolean>();
        for (Order_Form_Extraction__c row : scope) {
            Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(new Set<Id>{ row.Opportunity__c });
            List<Id> docs = docsByOpp.get(row.Opportunity__c);
            if (docs == null || docs.isEmpty()) { note('left unread: no files'); continue; }
            List<String> skipped = new List<String>();
            Map<String, Object> reply;
            try {
                reply = OrderFormExtractionJob.readWithPrompt(row.Opportunity__c, docs, prompt, skipped);
            } catch (Exception e) {
                reply = null;
            }
            if (reply == null) { note('left unread: read failed'); continue; }
            replies.put(row.Id, reply);
            partial.put(row.Id, !skipped.isEmpty());
        }
        List<Order_Form_Extraction__c> updates = new List<Order_Form_Extraction__c>();
        for (Id rowId : replies.keySet()) {
            Order_Form_Extraction__c u = OrderFormExtractionJob.linesFrom(rowId, replies.get(rowId));
            if (u.Line_Items__c == null && partial.get(rowId)) {
                note('left unread: no lines found, but files were left out');
                continue;
            }
            updates.add(u);
        }
        if (updates.isEmpty()) return;
        Database.SaveResult[] results = Database.update(updates, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) { note('failed to save'); continue; }
            Order_Form_Extraction__c u = updates[i];
            note(u.Line_Items__c == null ? 'read: no priced lines' : (u.Lines_Mismatch__c == true ? 'read: lines disagree with the ARR' : 'read'));
        }
    }

    public void finish(Database.BatchableContext bc) {
        List<String> lines = new List<String>();
        for (String k : outcomes.keySet()) lines.add(k + ': ' + outcomes.get(k));
        System.debug(LoggingLevel.INFO, 'OrderFormLinesBackfillBatch finished. ' + String.join(lines, '; '));
    }

    private void note(String outcome) {
        outcomes.put(outcome, (outcomes.containsKey(outcome) ? outcomes.get(outcome) : 0) + 1);
    }
}
