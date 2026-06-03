public with sharing class OrderFormExtractionJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String NAMED_CRED = 'callout:Anthropic_Claude';
    @TestVisible private static final String MODEL = 'claude-sonnet-4-6';
    @TestVisible private static final Integer MAX_TOKENS = 4096;
    @TestVisible private static final String PROMPT_RESOURCE = 'OrderFormPrompt';
    @TestVisible private static final Integer RAW_RESPONSE_LIMIT = 131072;
    @TestVisible private static final Integer EXTRACTED_JSON_LIMIT = 32768;
    @TestVisible private static final Integer ERROR_MESSAGE_LIMIT = 32768;
    @TestVisible private static final Integer FILE_NAME_LIMIT = 255;
    @TestVisible private static final Integer DOC_ID_LIMIT = 255;

    private final Id opportunityId;
    private final List<Id> contentDocumentIds;

    public OrderFormExtractionJob(Id opportunityId, List<Id> contentDocumentIds) {
        this.opportunityId = opportunityId;
        this.contentDocumentIds = contentDocumentIds == null ? new List<Id>() : contentDocumentIds;
    }

    public void execute(QueueableContext ctx) {
        runOnce(opportunityId, contentDocumentIds);
    }

    /**
     * Insert one extraction row for this Opp + docs. Use when caller only
     * needs to extract one Opp in the current transaction. For multi-Opp
     * paths (batch backfill), call buildExtraction(...) per Opp first, then
     * bulk-insert at the end to keep callouts and DML in separate phases.
     */
    public static void runOnce(Id opportunityId, List<Id> contentDocumentIds) {
        Order_Form_Extraction__c row = buildExtraction(opportunityId, contentDocumentIds);
        try {
            insert row;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to insert extraction row: ' + e.getMessage());
        }
    }

    /**
     * Build a populated Order_Form_Extraction__c row in memory by doing the
     * Anthropic callout and parsing the result. NO DML - caller is
     * responsible for inserting the returned row. Required for batch paths
     * that process multiple Opps per transaction (no DML between callouts).
     */
    public static Order_Form_Extraction__c buildExtraction(Id opportunityId, List<Id> contentDocumentIds) {
        List<Id> docIds = contentDocumentIds == null ? new List<Id>() : contentDocumentIds;
        Map<Id, ContentVersion> versionByDocId = loadLatestVersionsByDoc(docIds);
        Opportunity parentOpp = loadParentOpp(opportunityId);

        Order_Form_Extraction__c row = new Order_Form_Extraction__c(
            Opportunity__c = opportunityId,
            Content_Document_Id__c = truncate(joinIds(docIds), DOC_ID_LIMIT),
            File_Name__c = truncate(joinFileNames(versionByDocId, docIds), FILE_NAME_LIMIT),
            Extracted_At__c = System.now(),
            Model__c = MODEL
        );

        try {
            List<Blob> pdfBytes = new List<Blob>();
            for (Id docId : docIds) {
                ContentVersion cv = versionByDocId.get(docId);
                if (cv != null && cv.VersionData != null) pdfBytes.add(cv.VersionData);
            }
            if (pdfBytes.isEmpty()) {
                row.Extraction_Status__c = 'No Document';
                row.Error_Message__c = 'No ContentVersion data found for the supplied ContentDocument Ids.';
                return row;
            }

            String body = buildRequestBody(pdfBytes);
            HttpResponse resp = callAnthropic(body);
            row.HTTP_Status_Code__c = resp.getStatusCode();
            row.Raw_Response__c = truncate(resp.getBody(), RAW_RESPONSE_LIMIT);

            if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
                row.Extraction_Status__c = 'API Failed';
                row.Error_Message__c = truncate('HTTP ' + resp.getStatusCode() + ': ' + resp.getBody(), ERROR_MESSAGE_LIMIT);
                return row;
            }

            Map<String, Object> extracted;
            try {
                extracted = parseAssistantJson(resp.getBody());
            } catch (Exception e) {
                row.Extraction_Status__c = 'Parse Failed';
                row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
                return row;
            }

            row.Extracted_JSON__c = truncate(JSON.serializePretty(extracted), EXTRACTED_JSON_LIMIT);
            populateExtractedFields(row, extracted);
            overrideTypeFromOpp(row, parentOpp);
            computeIncrementalARR(row, parentOpp);
            row.Extraction_Status__c = 'Success';
            return row;

        } catch (Exception e) {
            row.Extraction_Status__c = 'API Failed';
            row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
            return row;
        }
    }

    @TestVisible
    private static Opportunity loadParentOpp(Id opportunityId) {
        if (opportunityId == null) return null;
        List<Opportunity> opps = [
            SELECT Id, Type, Base_Opportunity__c, Base_Opportunity__r.Annual_Recurring_Revenue__c
            FROM Opportunity WHERE Id = :opportunityId LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0];
    }

    @TestVisible
    private static void overrideTypeFromOpp(Order_Form_Extraction__c row, Opportunity parentOpp) {
        // The Opp's Type is the authoritative classification (Rogo Opp flows
        // populate it deliberately). Claude's PDF-derived guess can misfire on
        // renewals-with-seat-adds vs. true upsells, so prefer Opp.Type.
        // Claude's original value remains in Extracted_JSON__c for audit.
        if (parentOpp != null && String.isNotBlank(parentOpp.Type)) {
            row.Type__c = parentOpp.Type;
        }
    }

    @TestVisible
    private static Map<Id, ContentVersion> loadLatestVersionsByDoc(List<Id> contentDocumentIds) {
        Map<Id, ContentVersion> byDoc = new Map<Id, ContentVersion>();
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) return byDoc;
        for (ContentVersion cv : [
            SELECT Id, ContentDocumentId, VersionData, Title, PathOnClient
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = true
        ]) {
            byDoc.put(cv.ContentDocumentId, cv);
        }
        return byDoc;
    }

    private static String joinIds(List<Id> ids) {
        if (ids == null || ids.isEmpty()) return null;
        List<String> parts = new List<String>();
        for (Id id : ids) parts.add(String.valueOf(id));
        return String.join(parts, ',');
    }

    private static String joinFileNames(Map<Id, ContentVersion> versionByDocId, List<Id> contentDocumentIds) {
        List<String> names = new List<String>();
        for (Id docId : contentDocumentIds) {
            ContentVersion cv = versionByDocId.get(docId);
            if (cv != null && String.isNotBlank(cv.Title)) names.add(cv.Title);
        }
        return names.isEmpty() ? null : String.join(names, '; ');
    }

    @TestVisible
    private static String buildRequestBody(List<Blob> pdfBytes) {
        String systemPrompt = loadPrompt();
        List<Object> content = new List<Object>();
        for (Blob bytes : pdfBytes) {
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
        Map<String, Object> userMessage = new Map<String, Object>{
            'role' => 'user',
            'content' => content
        };
        return JSON.serialize(new Map<String, Object>{
            'model' => MODEL,
            'max_tokens' => MAX_TOKENS,
            'system' => systemPrompt,
            'messages' => new List<Object>{ userMessage }
        });
    }

    @TestVisible
    private static String loadPrompt() {
        List<StaticResource> resources = [SELECT Body FROM StaticResource WHERE Name = :PROMPT_RESOURCE LIMIT 1];
        if (resources.isEmpty()) {
            throw new OrderFormException('Static resource "' + PROMPT_RESOURCE + '" not found.');
        }
        return resources[0].Body.toString();
    }

    @TestVisible
    private static HttpResponse callAnthropic(String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CRED + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-beta', 'pdfs-2024-09-25');
        req.setTimeout(120000);
        req.setBody(body);
        return new Http().send(req);
    }

    @TestVisible
    private static Map<String, Object> parseAssistantJson(String responseBody) {
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        List<Object> content = (List<Object>) envelope.get('content');
        if (content == null || content.isEmpty()) {
            throw new OrderFormException('Anthropic response had no content array.');
        }
        String assistantText = null;
        for (Object block : content) {
            Map<String, Object> b = (Map<String, Object>) block;
            if ('text'.equals(b.get('type'))) {
                assistantText = (String) b.get('text');
                break;
            }
        }
        if (String.isBlank(assistantText)) {
            throw new OrderFormException('Anthropic response had no text block.');
        }
        String jsonText = stripCodeFence(assistantText);
        Object parsed = JSON.deserializeUntyped(jsonText);
        if (!(parsed instanceof Map<String, Object>)) {
            throw new OrderFormException('Extracted JSON was not an object.');
        }
        return (Map<String, Object>) parsed;
    }

    private static String stripCodeFence(String s) {
        String trimmed = s.trim();
        if (trimmed.startsWith('```')) {
            Integer first = trimmed.indexOf('\n');
            Integer last = trimmed.lastIndexOf('```');
            if (first > 0 && last > first) {
                return trimmed.substring(first + 1, last).trim();
            }
        }
        return trimmed;
    }

    @TestVisible
    private static void populateExtractedFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        Boolean amend = toBoolean(extracted.get('_is_amendment'));
        row.Is_Amendment__c = amend == true;
        row.Type__c = OrderFormPicklistMapper.mapType((String) extracted.get('Type'));
        row.Contract_Start_Date__c = parseDate((String) extracted.get('Contract_Start_Date'));
        row.Contract_End_Date__c = parseDate((String) extracted.get('Contract_End_Date'));
        row.Contract_Length_Months__c = toDecimal(extracted.get('Contract_Length_Months'));
        row.Contract_Length_Days__c = toDecimal(extracted.get('Contract_Length_Days'));
        row.Seat_Licenses__c = toDecimal(extracted.get('Seat_Licenses'));
        row.License_Fees__c = toDecimal(extracted.get('License_Fees'));
        row.Platform_Connection_Fee__c = toDecimal(extracted.get('Platform_Connection_Fee'));
        row.Professional_Service_Fees__c = toDecimal(extracted.get('Professional_Service_Fees'));
        row.Total_Contract_Value__c = toDecimal(extracted.get('Total_Contract_Value'));
        row.Annual_Recurring_Revenue__c = toDecimal(extracted.get('Annual_Recurring_Revenue'));
        row.Renewal_Terms__c = OrderFormPicklistMapper.mapRenewalTerms((String) extracted.get('Renewal_Terms'));
        row.Subscription_Schedule__c = OrderFormPicklistMapper.mapSubscriptionSchedule((String) extracted.get('Subscription_Schedule'));
        row.Payment_Terms__c = OrderFormPicklistMapper.mapPaymentTerms((String) extracted.get('Payment_Terms'));
        row.Credit_Terms__c = OrderFormPicklistMapper.mapCreditTerms((String) extracted.get('Credit_Terms'));
        row.Pricing_Structure__c = truncate((String) extracted.get('Pricing_Structure'), 100);
        row.Billing_Contact_Email__c = (String) extracted.get('Billing_Contact_Email');
        Boolean ela = toBoolean(extracted.get('ELA'));
        row.ELA__c = ela == true;
        Boolean paid = toBoolean(extracted.get('Paid_Trial'));
        row.Paid_Trial__c = paid == true;
        row.Trial_Price__c = toDecimal(extracted.get('Trial_Price'));
        row.Pilot_Success_Criteria__c = truncate((String) extracted.get('Pilot_Success_Criteria'), 32768);
        row.Credits_Purchased__c = toDecimal(extracted.get('Credits_Purchased'));
        row.Credits_Period__c = mapCreditsPeriod((String) extracted.get('Credits_Period'));
        row.Special_Terms__c = truncate((String) extracted.get('Special_Terms'), 32768);

        deriveEndDate(row);
    }

    @TestVisible
    private static void computeIncrementalARR(Order_Form_Extraction__c row, Opportunity parentOpp) {
        Decimal totalARR = row.Annual_Recurring_Revenue__c;
        if (totalARR == null) return;

        // For New Business / Pilot / null Type, Incremental = full extracted ARR.
        Set<String> expansionTypes = new Set<String>{'Upsell','Renewal','Downsell','Contract Restructure'};
        if (!expansionTypes.contains(row.Type__c)) {
            row.Incremental_ARR__c = totalARR;
            return;
        }

        if (parentOpp == null || parentOpp.Base_Opportunity__c == null) return;
        Id baseOppId = parentOpp.Base_Opportunity__c;

        // Preferred source: the base Opp's most recent successful OFE row.
        Decimal baseARR = null;
        List<Order_Form_Extraction__c> baseRows = [
            SELECT Annual_Recurring_Revenue__c
            FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :baseOppId
              AND Extraction_Status__c = 'Success'
              AND Annual_Recurring_Revenue__c != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!baseRows.isEmpty()) {
            baseARR = baseRows[0].Annual_Recurring_Revenue__c;
        } else if (parentOpp.Base_Opportunity__r != null) {
            // Fallback: the base Opp's own Annual_Recurring_Revenue__c field.
            // Useful for legacy bases that predate the signed__* convention.
            baseARR = parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c;
        }
        if (baseARR == null) return;

        row.Base_ARR__c = baseARR;
        row.Incremental_ARR__c = totalARR - baseARR;
    }

    @TestVisible
    private static void deriveEndDate(Order_Form_Extraction__c row) {
        if (row.Contract_End_Date__c != null || row.Contract_Start_Date__c == null) return;
        if (row.Contract_Length_Months__c != null) {
            Integer months = Integer.valueOf(row.Contract_Length_Months__c);
            row.Contract_End_Date__c = row.Contract_Start_Date__c.addMonths(months).addDays(-1);
        } else if (row.Contract_Length_Days__c != null) {
            Integer days = Integer.valueOf(row.Contract_Length_Days__c);
            row.Contract_End_Date__c = row.Contract_Start_Date__c.addDays(days - 1);
        }
    }

    private static String mapCreditsPeriod(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase().trim();
        if (s.startsWith('mo')) return 'month';
        if (s.startsWith('qu')) return 'quarter';
        if (s.startsWith('ye') || s.startsWith('an')) return 'year';
        if (s.startsWith('co')) return 'contract';
        return null;
    }

    private static Date parseDate(String iso) {
        if (String.isBlank(iso)) return null;
        try { return Date.valueOf(iso); } catch (Exception e) { return null; }
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        try {
            return Decimal.valueOf(String.valueOf(v).trim());
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean toBoolean(Object v) {
        if (v == null) return null;
        if (v instanceof Boolean) return (Boolean) v;
        if (v instanceof String) {
            String s = ((String) v).toLowerCase().trim();
            if (s == 'true' || s == 'yes') return true;
            if (s == 'false' || s == 'no') return false;
        }
        return null;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }

    public class OrderFormException extends Exception {}
}
