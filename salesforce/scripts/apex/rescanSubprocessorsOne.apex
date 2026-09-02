// =============================================================================
// Sub-Processor Re-Scan - single Opportunity (dry run, no DML)
// =============================================================================
// Validates the Sub_Processor_List__c extraction on ONE deal before you spend
// on the whole book. Runs the real production code path (makes the Anthropic
// callout) against every signed__* attachment on the Opportunity + its parent,
// then prints the extracted approved-subprocessor list and its evidence.
// It does NOT insert a row - nothing is written to Salesforce.
//
// Edit OPPORTUNITY_ID below, then run:
//   sf apex run --target-org rogo --file scripts/apex/rescanSubprocessorsOne.apex
// (run from inside the salesforce/ directory; use rogo-dev to validate in the sandbox)
//
// View output: Setup -> Debug Logs -> newest log -> filter USER_DEBUG.
// =============================================================================

Id OPPORTUNITY_ID = '006XXXXXXXXXXXXXXX';   // <-- replace

Integer CHUNK = 3000;

Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllSignedDocuments(new Set<Id>{ OPPORTUNITY_ID });
List<Id> docs = docsByOpp.get(OPPORTUNITY_ID);

if (docs == null || docs.isEmpty()) {
    System.debug('--- NO FILES: no signed__* attachments on Opportunity ' + OPPORTUNITY_ID + ' (or its base Opp)');
    return;
}
System.debug('--- ContentDocumentIds (' + docs.size() + '): ' + docs);

// Real callout, returns the populated row WITHOUT inserting it.
Order_Form_Extraction__c row = OrderFormExtractionJob.buildExtraction(OPPORTUNITY_ID, docs);

System.debug('--- Status: ' + row.Extraction_Status__c);
System.debug('--- HTTP Code: ' + row.HTTP_Status_Code__c);
System.debug('--- Source_Document_Type__c: ' + row.Source_Document_Type__c);
System.debug('--- File Names: ' + row.File_Name__c);
System.debug('=== Sub_Processor_List__c ===');
System.debug(String.isBlank(row.Sub_Processor_List__c)
    ? '(null - no approved-subprocessor list found in any attached document)'
    : '\n' + row.Sub_Processor_List__c);

if (String.isNotBlank(row.Error_Message__c)) {
    System.debug('--- Error_Message__c: ' + row.Error_Message__c);
}

if (String.isNotBlank(row.Extract_Evidence__c)) {
    System.debug('--- Extract_Evidence__c (chunked):');
    String ev = row.Extract_Evidence__c;
    for (Integer i = 0; i < ev.length(); i += CHUNK) {
        Integer endIdx = Math.min(i + CHUNK, ev.length());
        System.debug('[' + i + '..' + endIdx + '] ' + ev.substring(i, endIdx));
    }
}

System.debug('--- DONE (no DML performed; row was built but not inserted). ---');
