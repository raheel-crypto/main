/**
 * Backfills credit rollover on extractions made before it was read, then lays
 * it onto their contracts. scripts/apex/backfillCreditRollover.apex runs it.
 *
 * Each deal's files are re-read with a focused prompt - the CREDIT ROLLOVER
 * section of the extraction prompt, asking nothing else - and only the three
 * rollover fields are written to the deal's current extraction, checked as in
 * a full read. Every other field is left as it is, so the pass changes no
 * economics and never replaces a fuller read (large-document rows).
 *
 * "Not specified" is written only when every file was read: when a file had to
 * be left out the answer may be in it, so the row stays blank. An unusable reply
 * also leaves it blank. finish() applies the answers to the contracts with
 * ContractLegalTermsApplier.backfillCreditRollover (deal order; an amendment
 * that disagrees flags legal review) and logs a summary.
 */
public with sharing class CreditRolloverBackfillBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final Boolean creditDealsOnly;
    private final String prompt;
    private Map<String, Integer> outcomes = new Map<String, Integer>();
    private Set<Id> contractIds = new Set<Id>();

    /** creditDealsOnly: only deals whose extraction shows credits (an allocation, a commitment or an overage rate). */
    public CreditRolloverBackfillBatch(Boolean creditDealsOnly) {
        this.creditDealsOnly = creditDealsOnly == true;
        this.prompt = rolloverPrompt();
    }

    /** The current extractions still without a rollover answer. */
    public static String targetWhere(Boolean creditDealsOnly) {
        String w = 'WHERE Is_Current__c = true AND Credit_Rollover__c = null'
            + ' AND Extraction_Status__c IN (\'Success\', \'Incomplete\', \'No Order Form\')'
            + ' AND Opportunity__r.StageName = \'Closed Won\'';
        if (creditDealsOnly == true) {
            w += ' AND (Credits_Purchased__c != null OR Credits_Added__c != null OR Credit_Commit__c = true'
                + ' OR Credit_Commit_Fee__c != null OR Overage_Rate__c != null)';
        }
        return w;
    }

    public static Integer countTargets(Boolean creditDealsOnly) {
        return Database.countQuery('SELECT COUNT() FROM Order_Form_Extraction__c ' + targetWhere(creditDealsOnly));
    }

    @TestVisible
    private static String rolloverPrompt() {
        return 'You are a precise contract-data extractor. You receive the documents of ONE commercial deal and answer '
            + 'ONE question: what happens to unused credits when the period they were allocated for ends. Return ONE JSON '
            + 'object and nothing else - no prose, no markdown - with exactly these keys:\n'
            + '{"Credit_Rollover": "No Rollover" | "Negotiable" | "Partial" | "Full" | "Not specified", '
            + '"Credit_Rollover_Percent": number | null, '
            + '"Credit_Rollover_Terms": "the clause verbatim" | null, '
            + '"Extract_Evidence": {"Credit_Rollover": {"quote": "the operative words", "clause": "where they are"}} | null}\n\n'
            + OrderFormExtractionJob.promptSection('CREDIT ROLLOVER');
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id, Opportunity__c, Applied_Contract__c FROM Order_Form_Extraction__c '
            + targetWhere(creditDealsOnly) + ' ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST');
    }

    public void execute(Database.BatchableContext bc, List<Order_Form_Extraction__c> scope) {
        // Every read first: no DML may come before a callout in the transaction.
        List<Order_Form_Extraction__c> answers = new List<Order_Form_Extraction__c>();
        Map<Id, Id> contractByRow = new Map<Id, Id>();
        for (Order_Form_Extraction__c row : scope) {
            Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllDocuments(new Set<Id>{ row.Opportunity__c });
            List<Id> docs = docsByOpp.get(row.Opportunity__c);
            if (docs == null || docs.isEmpty()) { note('left blank: no files'); continue; }

            List<String> skipped = new List<String>();
            Map<String, Object> reply;
            try {
                reply = OrderFormExtractionJob.readWithPrompt(row.Opportunity__c, docs, prompt, skipped);
            } catch (Exception e) {
                reply = null;
            }
            if (reply == null) { note('left blank: read failed'); continue; }

            Order_Form_Extraction__c answer = OrderFormExtractionJob.creditRolloverFrom(row.Id, reply);
            if (answer.Credit_Rollover__c == null) { note('left blank: no usable answer'); continue; }
            if (answer.Credit_Rollover__c == 'Not specified' && !skipped.isEmpty()) {
                note('left blank: not found, but files were left out');
                continue;
            }
            answers.add(answer);
            contractByRow.put(row.Id, row.Applied_Contract__c);
        }
        if (answers.isEmpty()) return;
        Database.SaveResult[] results = Database.update(answers, false);
        for (Integer i = 0; i < results.size(); i++) {
            Order_Form_Extraction__c answer = answers[i];
            if (!results[i].isSuccess()) { note('failed to save'); continue; }
            note(answer.Credit_Rollover__c);
            Id contractId = contractByRow.get(answer.Id);
            if (contractId != null && answer.Credit_Rollover__c != 'Not specified') contractIds.add(contractId);
        }
    }

    public void finish(Database.BatchableContext bc) {
        Integer applied = 0;
        Integer flagged = 0;
        List<Contract> changes = ContractLegalTermsApplier.backfillCreditRollover(contractIds);
        if (!changes.isEmpty()) {
            Database.SaveResult[] results = Database.update(changes, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) continue;
                applied++;
                if (changes[i].Needs_Legal_Review__c == true) flagged++;
            }
        }
        List<String> lines = new List<String>();
        for (String k : outcomes.keySet()) lines.add(k + ': ' + outcomes.get(k));
        System.debug(LoggingLevel.INFO, 'CreditRolloverBackfillBatch finished. Extractions - ' + String.join(lines, '; ')
            + '. Contracts given rollover: ' + applied + ' (flagged for legal review: ' + flagged + ').');
    }

    private void note(String outcome) {
        outcomes.put(outcome, (outcomes.containsKey(outcome) ? outcomes.get(outcome) : 0) + 1);
    }
}
