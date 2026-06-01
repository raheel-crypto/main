public with sharing class OrderFormExtractionJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String NAMED_CRED = 'callout:Anthropic_Claude';
    @TestVisible private static final String MODEL = 'claude-sonnet-4-6';
    @TestVisible private static final Integer MAX_TOKENS = 4096;
    @TestVisible private static final String PROMPT_RESOURCE = 'OrderFormPrompt';
    @TestVisible private static final Integer RAW_RESPONSE_LIMIT = 131072;
    @TestVisible private static final Integer EXTRACTED_JSON_LIMIT = 32768;
    @TestVisible private static final Integer ERROR_MESSAGE_LIMIT = 32768;

    private final Id opportunityId;
    private final Id contentDocumentId;

    public OrderFormExtractionJob(Id opportunityId, Id contentDocumentId) {
        this.opportunityId = opportunityId;
        this.contentDocumentId = contentDocumentId;
    }

    public void execute(QueueableContext ctx) {
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(
            Opportunity__c = opportunityId,
            Content_Document_Id__c = contentDocumentId,
            File_Name__c = lookupFileName(contentDocumentId),
            Extracted_At__c = System.now(),
            Model__c = MODEL
        );

        try {
            Blob pdfBytes = loadLatestVersion(contentDocumentId);
            if (pdfBytes == null) {
                row.Extraction_Status__c = 'No Document';
                row.Error_Message__c = 'No ContentVersion data for ContentDocumentId ' + contentDocumentId;
                insert row;
                return;
            }

            String body = buildRequestBody(pdfBytes);
            HttpResponse resp = callAnthropic(body);
            row.HTTP_Status_Code__c = resp.getStatusCode();
            row.Raw_Response__c = truncate(resp.getBody(), RAW_RESPONSE_LIMIT);

            if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
                row.Extraction_Status__c = 'API Failed';
                row.Error_Message__c = truncate('HTTP ' + resp.getStatusCode() + ': ' + resp.getBody(), ERROR_MESSAGE_LIMIT);
                insert row;
                return;
            }

            Map<String, Object> extracted;
            try {
                extracted = parseAssistantJson(resp.getBody());
            } catch (Exception e) {
                row.Extraction_Status__c = 'Parse Failed';
                row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
                insert row;
                return;
            }

            row.Extracted_JSON__c = truncate(JSON.serializePretty(extracted), EXTRACTED_JSON_LIMIT);
            populateExtractedFields(row, extracted);
            row.Extraction_Status__c = 'Success';
            insert row;

        } catch (Exception e) {
            row.Extraction_Status__c = 'API Failed';
            row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
            try {
                insert row;
            } catch (Exception e2) {
                System.debug(LoggingLevel.ERROR, 'Failed to record extraction error row: ' + e2.getMessage());
            }
        }
    }

    private static String lookupFileName(Id contentDocumentId) {
        List<ContentDocument> docs = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId LIMIT 1];
        return docs.isEmpty() ? null : docs[0].Title;
    }

    @TestVisible
    private static Blob loadLatestVersion(Id contentDocumentId) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].VersionData;
    }

    @TestVisible
    private static String buildRequestBody(Blob pdfBytes) {
        String systemPrompt = loadPrompt();
        String base64Pdf = EncodingUtil.base64Encode(pdfBytes);

        Map<String, Object> documentBlock = new Map<String, Object>{
            'type' => 'document',
            'source' => new Map<String, Object>{
                'type' => 'base64',
                'media_type' => 'application/pdf',
                'data' => base64Pdf
            }
        };
        Map<String, Object> textBlock = new Map<String, Object>{
            'type' => 'text',
            'text' => 'Extract the order form per the schema. Return JSON only.'
        };
        Map<String, Object> userMessage = new Map<String, Object>{
            'role' => 'user',
            'content' => new List<Object>{ documentBlock, textBlock }
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
