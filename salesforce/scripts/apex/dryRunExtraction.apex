// =============================================================================
// Order Form Extraction Dry-Run
// =============================================================================
// Runs the production extraction code path against every signed__* attachment
// on the target Opportunity (including parent-Opp files and images) and prints
// the raw response + parsed JSON. Returns the would-be Order_Form_Extraction__c
// row WITHOUT inserting it.
//
// Edit OPPORTUNITY_ID below then execute via:
//   sf apex run --target-org rogo --file scripts/apex/dryRunExtraction.apex
// (run from inside the salesforce/ directory, or prefix with salesforce/scripts/...
//  if running from the repo root)
//
// View output: Setup -> Debug Logs -> open the newest log -> filter USER_DEBUG.
// =============================================================================

Id OPPORTUNITY_ID = '006XXXXXXXXXXXXXXX';   // <-- replace

Integer CHUNK = 3000;

// 1. Find signed__* files (current Opp + Base_Opportunity__c parent)
Map<Id, List<Id>> docsByOpp = OrderFormExtractor.findAllSignedDocuments(new Set<Id>{ OPPORTUNITY_ID });
List<Id> docs = docsByOpp.get(OPPORTUNITY_ID);

if (docs == null || docs.isEmpty()) {
    System.debug('--- NO FILES: no signed__* attachments on Opportunity ' + OPPORTUNITY_ID + ' (or its base Opp)');
    return;
}
System.debug('--- ContentDocumentIds (' + docs.size() + '): ' + docs);

// 2. Run the same code the live flow uses. Returns the populated row WITHOUT
//    inserting it. This makes the callout for real - costs Anthropic API spend.
Order_Form_Extraction__c row = OrderFormExtractionJob.buildExtraction(OPPORTUNITY_ID, docs);

System.debug('--- Status: ' + row.Extraction_Status__c);
System.debug('--- HTTP Code: ' + row.HTTP_Status_Code__c);
System.debug('--- File Names: ' + row.File_Name__c);
System.debug('--- Type__c: ' + row.Type__c);
System.debug('--- Annual_Recurring_Revenue__c: ' + row.Annual_Recurring_Revenue__c);
System.debug('--- Incremental_ARR__c: ' + row.Incremental_ARR__c);
System.debug('--- Base_ARR__c: ' + row.Base_ARR__c);
System.debug('--- Seat_Licenses__c: ' + row.Seat_Licenses__c);
System.debug('--- License_Fees__c: ' + row.License_Fees__c);
System.debug('--- Contract_Start_Date__c: ' + row.Contract_Start_Date__c);
System.debug('--- Contract_End_Date__c: ' + row.Contract_End_Date__c);

if (String.isNotBlank(row.Error_Message__c)) {
    System.debug('--- Error_Message__c (chunked):');
    String em = row.Error_Message__c;
    for (Integer i = 0; i < em.length(); i += CHUNK) {
        Integer endIdx = Math.min(i + CHUNK, em.length());
        System.debug('[' + i + '..' + endIdx + '] ' + em.substring(i, endIdx));
    }
}

if (String.isNotBlank(row.Raw_Response__c)) {
    System.debug('--- Raw_Response__c (chunked):');
    String rb = row.Raw_Response__c;
    for (Integer i = 0; i < rb.length(); i += CHUNK) {
        Integer endIdx = Math.min(i + CHUNK, rb.length());
        System.debug('[' + i + '..' + endIdx + '] ' + rb.substring(i, endIdx));
    }
}

if (String.isNotBlank(row.Extracted_JSON__c)) {
    System.debug('--- Extracted_JSON__c:');
    String ej = row.Extracted_JSON__c;
    for (Integer i = 0; i < ej.length(); i += CHUNK) {
        Integer endIdx = Math.min(i + CHUNK, ej.length());
        System.debug('[' + i + '..' + endIdx + '] ' + ej.substring(i, endIdx));
    }
}

System.debug('--- DONE (no DML performed; row was built but not inserted). ---');
