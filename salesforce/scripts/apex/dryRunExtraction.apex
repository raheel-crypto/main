// =============================================================================
// Order Form Extraction Dry-Run
// =============================================================================
// Runs the full extraction synchronously and prints the raw outputs.
// Does NOT update the Opportunity. Safe to run repeatedly.
//
// Edit ONE line below (OPPORTUNITY_ID) then execute via:
//   sf apex run --target-org rogo-dev --file salesforce/scripts/apex/dryRunExtraction.apex
// Or paste into Developer Console > Debug > Execute Anonymous.
//
// View output: Setup -> Debug Logs -> open the newest log -> filter USER_DEBUG.
// =============================================================================

Id OPPORTUNITY_ID = '006XXXXXXXXXXXXXXX';   // <-- replace with target Opp Id

// --- helper: chunked debug print so long bodies don't get truncated ---
Integer CHUNK = 3000;

// --- 1. Find the latest signed__* file linked to the Opp ---
List<ContentDocumentLink> links = [
    SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :OPPORTUNITY_ID
      AND ContentDocument.Title LIKE 'signed__%'
    ORDER BY ContentDocument.LastModifiedDate DESC
    LIMIT 1
];
if (links.isEmpty()) {
    System.debug('--- NO FILE: no signed__* attachment on Opportunity ' + OPPORTUNITY_ID);
    return;
}
Id contentDocumentId = links[0].ContentDocumentId;
System.debug('--- FILE: ' + links[0].ContentDocument.Title + ' (' + contentDocumentId + ')');

// --- 2. Load PDF bytes ---
ContentVersion cv = [
    SELECT VersionData, ContentSize
    FROM ContentVersion
    WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
    LIMIT 1
];
System.debug('--- PDF SIZE: ' + cv.ContentSize + ' bytes');
String base64Pdf = EncodingUtil.base64Encode(cv.VersionData);

// --- 3. Load system prompt from static resource ---
StaticResource prompt = [SELECT Body FROM StaticResource WHERE Name = 'OrderFormPrompt' LIMIT 1];
String systemPrompt = prompt.Body.toString();

// --- 4. Build the Anthropic request body ---
Map<String, Object> payload = new Map<String, Object>{
    'model' => 'claude-sonnet-4-6',
    'max_tokens' => 4096,
    'system' => systemPrompt,
    'messages' => new List<Object>{
        new Map<String, Object>{
            'role' => 'user',
            'content' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'document',
                    'source' => new Map<String, Object>{
                        'type' => 'base64',
                        'media_type' => 'application/pdf',
                        'data' => base64Pdf
                    }
                },
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => 'Extract the order form per the schema. Return JSON only.'
                }
            }
        }
    }
};

// --- 5. Callout ---
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Anthropic_Claude/v1/messages');
req.setMethod('POST');
req.setHeader('Content-Type', 'application/json');
req.setHeader('anthropic-beta', 'pdfs-2024-09-25');
req.setTimeout(120000);
req.setBody(JSON.serialize(payload));

HttpResponse resp;
try {
    resp = new Http().send(req);
} catch (Exception e) {
    System.debug('--- CALLOUT EXCEPTION: ' + e.getMessage());
    return;
}

System.debug('--- HTTP STATUS: ' + resp.getStatusCode());
System.debug('--- RAW RESPONSE BODY (chunked):');
String rawBody = resp.getBody();
for (Integer i = 0; i < rawBody.length(); i += CHUNK) {
    Integer endIdx = Math.min(i + CHUNK, rawBody.length());
    System.debug('[' + i + '..' + endIdx + '] ' + rawBody.substring(i, endIdx));
}

if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
    System.debug('--- NON-2XX RESPONSE; stopping.');
    return;
}

// --- 6. Pull out the assistant text content ---
Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
List<Object> content = (List<Object>) envelope.get('content');
String assistantText = null;
for (Object block : content) {
    Map<String, Object> b = (Map<String, Object>) block;
    if ('text'.equals(b.get('type'))) {
        assistantText = (String) b.get('text');
        break;
    }
}

System.debug('--- ASSISTANT TEXT (chunked):');
for (Integer i = 0; i < assistantText.length(); i += CHUNK) {
    Integer endIdx = Math.min(i + CHUNK, assistantText.length());
    System.debug('[' + i + '..' + endIdx + '] ' + assistantText.substring(i, endIdx));
}

// Strip optional ``` code fences before parsing
String jsonText = assistantText.trim();
if (jsonText.startsWith('```')) {
    Integer firstNl = jsonText.indexOf('\n');
    Integer lastFence = jsonText.lastIndexOf('```');
    if (firstNl > 0 && lastFence > firstNl) {
        jsonText = jsonText.substring(firstNl + 1, lastFence).trim();
    }
}

// --- 7. Pretty-print parsed extraction ---
Map<String, Object> extracted;
try {
    extracted = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
} catch (Exception e) {
    System.debug('--- JSON PARSE ERROR: ' + e.getMessage());
    return;
}
System.debug('--- EXTRACTED JSON (pretty):');
String pretty = JSON.serializePretty(extracted);
for (Integer i = 0; i < pretty.length(); i += CHUNK) {
    Integer endIdx = Math.min(i + CHUNK, pretty.length());
    System.debug('[' + i + '..' + endIdx + '] ' + pretty.substring(i, endIdx));
}

// --- 8. Show what fields WOULD be written (no DML) ---
List<String> keys = new List<String>(extracted.keySet());
keys.sort();
System.debug('--- EXTRACTED FIELDS (key -> value):');
for (String k : keys) {
    System.debug('  ' + k + ' = ' + extracted.get(k));
}

// --- 9. Compare extracted vs current Opp values for the writable fields ---
Opportunity opp = [
    SELECT Type, Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
           Seat_Licenses__c, Num_Users__c,
           License_Fees__c, Platform_Connection_Fee__c, Professional_Service_Fees__c,
           Total_Contract_Value__c, Amount, Annual_Recurring_Revenue__c,
           Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
           Billing_Contact__c, ELA__c,
           Trial_Start_Date__c, Trial_End_Date__c, Trial_Length_Days__c,
           Trial_Users__c, Trial_Price__c, Paid_Trial__c, Pilot_Success_Criteria__c,
           Notes__c
    FROM Opportunity WHERE Id = :OPPORTUNITY_ID
];
System.debug('--- CURRENT OPP VALUES (for comparison; nulls = would be filled if PDF has a value):');
System.debug('  Type=' + opp.Type);
System.debug('  Contract_Start_Date__c=' + opp.Contract_Start_Date__c);
System.debug('  Contract_End_Date__c=' + opp.Contract_End_Date__c);
System.debug('  Contract_Length_Mos__c=' + opp.Contract_Length_Mos__c);
System.debug('  Seat_Licenses__c=' + opp.Seat_Licenses__c);
System.debug('  License_Fees__c=' + opp.License_Fees__c);
System.debug('  Total_Contract_Value__c=' + opp.Total_Contract_Value__c);
System.debug('  Annual_Recurring_Revenue__c=' + opp.Annual_Recurring_Revenue__c);
System.debug('  Renewal_Terms__c=' + opp.Renewal_Terms__c);
System.debug('  Subscription_Schedule__c=' + opp.Subscription_Schedule__c);
System.debug('  Payment_Terms__c=' + opp.Payment_Terms__c);
System.debug('  Credit_Terms__c=' + opp.Credit_Terms__c);
System.debug('  Billing_Contact__c=' + opp.Billing_Contact__c);
System.debug('  ELA__c=' + opp.ELA__c);
System.debug('  Trial_Start_Date__c=' + opp.Trial_Start_Date__c);
System.debug('  Trial_End_Date__c=' + opp.Trial_End_Date__c);
System.debug('  Trial_Users__c=' + opp.Trial_Users__c);
System.debug('  Trial_Price__c=' + opp.Trial_Price__c);
System.debug('  Paid_Trial__c=' + opp.Paid_Trial__c);
System.debug('  Pilot_Success_Criteria__c=' + opp.Pilot_Success_Criteria__c);
System.debug('  Notes__c=' + opp.Notes__c);

System.debug('--- DONE (no DML performed). ---');
