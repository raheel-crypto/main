// =============================================================================
// Order Form Extraction Dry-Run (multi-document)
// =============================================================================
// Runs the full extraction synchronously against EVERY signed__* file on the
// target Opportunity, prints the raw outputs, and does NOT update anything.
//
// Edit OPPORTUNITY_ID below then execute via:
//   sf apex run --target-org rogo-dev --file salesforce/scripts/apex/dryRunExtraction.apex
// Or paste into Developer Console > Debug > Execute Anonymous.
//
// View output: Setup -> Debug Logs -> open the newest log -> filter USER_DEBUG.
// =============================================================================

Id OPPORTUNITY_ID = '006XXXXXXXXXXXXXXX';   // <-- replace with target Opp Id

Integer CHUNK = 3000;

// --- 1. Find every signed__* file linked to the Opp ---
List<ContentDocumentLink> links = [
    SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
    FROM ContentDocumentLink
    WHERE LinkedEntityId = :OPPORTUNITY_ID
      AND ContentDocument.Title LIKE 'signed__%'
    ORDER BY ContentDocument.LastModifiedDate DESC
];
if (links.isEmpty()) {
    System.debug('--- NO FILES: no signed__* attachments on Opportunity ' + OPPORTUNITY_ID);
    return;
}
System.debug('--- FILES (' + links.size() + '):');
List<Id> docIds = new List<Id>();
for (ContentDocumentLink cdl : links) {
    System.debug('     ' + cdl.ContentDocument.Title + ' (' + cdl.ContentDocumentId + ')');
    docIds.add(cdl.ContentDocumentId);
}

// --- 2. Load PDF bytes for each ---
Map<Id, ContentVersion> versionByDoc = new Map<Id, ContentVersion>();
for (ContentVersion cv : [
    SELECT Id, ContentDocumentId, VersionData, ContentSize, Title
    FROM ContentVersion
    WHERE ContentDocumentId IN :docIds AND IsLatest = true
]) {
    versionByDoc.put(cv.ContentDocumentId, cv);
}

List<Blob> pdfBytesList = new List<Blob>();
Integer totalSize = 0;
for (Id docId : docIds) {
    ContentVersion cv = versionByDoc.get(docId);
    if (cv != null && cv.VersionData != null) {
        pdfBytesList.add(cv.VersionData);
        totalSize += cv.ContentSize == null ? 0 : Integer.valueOf(cv.ContentSize);
    }
}
System.debug('--- TOTAL PDF SIZE: ' + totalSize + ' bytes across ' + pdfBytesList.size() + ' file(s)');

// --- 3. Load system prompt from static resource ---
StaticResource prompt = [SELECT Body FROM StaticResource WHERE Name = 'OrderFormPrompt' LIMIT 1];
String systemPrompt = prompt.Body.toString();

// --- 4. Build the Anthropic request body with multiple document blocks ---
List<Object> content = new List<Object>();
for (Blob bytes : pdfBytesList) {
    content.add(new Map<String, Object>{
        'type' => 'document',
        'source' => new Map<String, Object>{
            'type' => 'base64',
            'media_type' => 'application/pdf',
            'data' => EncodingUtil.base64Encode(bytes)
        }
    });
}
content.add(new Map<String, Object>{
    'type' => 'text',
    'text' => 'Extract one unified order form per the schema from all attached PDFs. Return JSON only.'
});

Map<String, Object> payload = new Map<String, Object>{
    'model' => 'claude-sonnet-4-6',
    'max_tokens' => 4096,
    'system' => systemPrompt,
    'messages' => new List<Object>{
        new Map<String, Object>{ 'role' => 'user', 'content' => content }
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
List<Object> respContent = (List<Object>) envelope.get('content');
String assistantText = null;
for (Object block : respContent) {
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

System.debug('--- DONE (no DML performed). ---');
