public with sharing class OrderFormExtractionJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String NAMED_CRED = 'callout:Anthropic_Claude';
    @TestVisible private static final String MODEL = 'claude-sonnet-4-6';
    @TestVisible private static final Integer MAX_TOKENS = 4096;
    @TestVisible private static final String PROMPT_RESOURCE = 'OrderFormPrompt';

    private final Id opportunityId;
    private final Id contentDocumentId;

    public OrderFormExtractionJob(Id opportunityId, Id contentDocumentId) {
        this.opportunityId = opportunityId;
        this.contentDocumentId = contentDocumentId;
    }

    public void execute(QueueableContext ctx) {
        Blob pdfBytes = loadLatestVersion(contentDocumentId);
        if (pdfBytes == null) {
            throw new OrderFormException('No ContentVersion data for ContentDocumentId ' + contentDocumentId);
        }

        String body = buildRequestBody(pdfBytes);
        String responseText = callAnthropic(body);
        Map<String, Object> extracted = parseAssistantJson(responseText);

        Opportunity current = loadOpportunity(opportunityId);
        Opportunity oppUpdate = buildFillBlanksUpdate(current, extracted);
        if (oppUpdate != null) {
            update oppUpdate;
        }
    }

    @TestVisible
    private static Blob loadLatestVersion(Id contentDocumentId) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
              AND IsLatest = true
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].VersionData;
    }

    @TestVisible
    private static String buildRequestBody(Blob pdfBytes) {
        String systemPrompt = loadPrompt();
        String base64Pdf = EncodingUtil.base64Encode(pdfBytes);

        Map<String, Object> documentSource = new Map<String, Object>{
            'type' => 'base64',
            'media_type' => 'application/pdf',
            'data' => base64Pdf
        };
        Map<String, Object> documentBlock = new Map<String, Object>{
            'type' => 'document',
            'source' => documentSource
        };
        Map<String, Object> textBlock = new Map<String, Object>{
            'type' => 'text',
            'text' => 'Extract the order form per the schema. Return JSON only.'
        };
        Map<String, Object> userMessage = new Map<String, Object>{
            'role' => 'user',
            'content' => new List<Object>{ documentBlock, textBlock }
        };
        Map<String, Object> payload = new Map<String, Object>{
            'model' => MODEL,
            'max_tokens' => MAX_TOKENS,
            'system' => systemPrompt,
            'messages' => new List<Object>{ userMessage }
        };
        return JSON.serialize(payload);
    }

    @TestVisible
    private static String loadPrompt() {
        List<StaticResource> resources = [
            SELECT Body FROM StaticResource WHERE Name = :PROMPT_RESOURCE LIMIT 1
        ];
        if (resources.isEmpty()) {
            throw new OrderFormException('Static resource "' + PROMPT_RESOURCE + '" not found.');
        }
        return resources[0].Body.toString();
    }

    @TestVisible
    private static String callAnthropic(String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CRED + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('anthropic-beta', 'pdfs-2024-09-25');
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse resp = new Http().send(req);
        Integer code = resp.getStatusCode();
        if (code < 200 || code >= 300) {
            System.debug(LoggingLevel.ERROR, 'Anthropic non-2xx ' + code + ': ' + resp.getBody());
            throw new OrderFormException('Anthropic API returned HTTP ' + code);
        }
        return resp.getBody();
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
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(jsonText);
        } catch (Exception e) {
            throw new OrderFormException('Failed to parse extracted JSON: ' + e.getMessage());
        }
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
    private static Opportunity loadOpportunity(Id oppId) {
        return [
            SELECT Id, Type,
                   Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
                   Seat_Licenses__c, Num_Users__c,
                   License_Fees__c, Platform_Connection_Fee__c, Professional_Service_Fees__c,
                   Total_Contract_Value__c, Amount, Annual_Recurring_Revenue__c,
                   Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
                   Billing_Contact__c, ELA__c,
                   Trial_Start_Date__c, Trial_End_Date__c, Trial_Length_Days__c,
                   Trial_Users__c, Trial_Price__c, Paid_Trial__c, Pilot_Success_Criteria__c,
                   Notes__c
            FROM Opportunity
            WHERE Id = :oppId
            LIMIT 1
        ];
    }

    @TestVisible
    private static Opportunity buildFillBlanksUpdate(Opportunity current, Map<String, Object> extracted) {
        Boolean isAmendment = toBoolean(extracted.get('_is_amendment'));
        String mappedType = OrderFormPicklistMapper.mapType((String) extracted.get('Type'));
        Boolean isPilot = 'Pilot'.equals(mappedType) || 'Pilot'.equals(current.Type);

        Opportunity changes = new Opportunity(Id = current.Id);
        Boolean anyChange = false;

        if (current.Type == null && mappedType != null) {
            changes.Type = mappedType;
            anyChange = true;
        }

        Date startDate = parseDate((String) extracted.get('Contract_Start_Date'));
        Date endDate = parseDate((String) extracted.get('Contract_End_Date'));
        Decimal lenMos = toDecimal(extracted.get('Contract_Length_Months'));
        Decimal lenDays = toDecimal(extracted.get('Contract_Length_Days'));

        if (isPilot) {
            if (current.Trial_Start_Date__c == null && startDate != null) { changes.Trial_Start_Date__c = startDate; anyChange = true; }
            if (current.Trial_End_Date__c == null && endDate != null)     { changes.Trial_End_Date__c   = endDate;   anyChange = true; }
            if (current.Trial_Length_Days__c == null && lenDays != null)  { changes.Trial_Length_Days__c = lenDays;  anyChange = true; }
            Decimal seats = toDecimal(extracted.get('Seat_Licenses'));
            if (current.Trial_Users__c == null && seats != null)          { changes.Trial_Users__c = seats; anyChange = true; }
            Decimal trialPrice = toDecimal(extracted.get('Trial_Price'));
            if (trialPrice == null) trialPrice = toDecimal(extracted.get('License_Fees'));
            if (current.Trial_Price__c == null && trialPrice != null)     { changes.Trial_Price__c = trialPrice; anyChange = true; }
            Boolean paidTrial = toBoolean(extracted.get('Paid_Trial'));
            if (paidTrial == null && trialPrice != null) paidTrial = (trialPrice > 0);
            if (current.Paid_Trial__c == false && paidTrial == true)      { changes.Paid_Trial__c = true; anyChange = true; }
            String criteria = (String) extracted.get('Pilot_Success_Criteria');
            if (String.isBlank(current.Pilot_Success_Criteria__c) && String.isNotBlank(criteria)) {
                changes.Pilot_Success_Criteria__c = criteria;
                anyChange = true;
            }
        } else {
            if (current.Contract_Start_Date__c == null && startDate != null) { changes.Contract_Start_Date__c = startDate; anyChange = true; }
            if (current.Contract_End_Date__c == null && endDate != null)     { changes.Contract_End_Date__c   = endDate;   anyChange = true; }
            if (current.Contract_Length_Mos__c == null && lenMos != null)    { changes.Contract_Length_Mos__c = lenMos;    anyChange = true; }

            Decimal seats = toDecimal(extracted.get('Seat_Licenses'));
            if (current.Seat_Licenses__c == null && seats != null)   { changes.Seat_Licenses__c = seats; anyChange = true; }
            if (current.Num_Users__c == null && seats != null)       { changes.Num_Users__c = seats; anyChange = true; }
        }

        Decimal licenseFees = toDecimal(extracted.get('License_Fees'));
        Decimal platformFee = toDecimal(extracted.get('Platform_Connection_Fee'));
        Decimal proServices = toDecimal(extracted.get('Professional_Service_Fees'));
        Decimal tcv = toDecimal(extracted.get('Total_Contract_Value'));
        Decimal arr = toDecimal(extracted.get('Annual_Recurring_Revenue'));

        if (!isPilot && current.License_Fees__c == null && licenseFees != null) { changes.License_Fees__c = licenseFees; anyChange = true; }
        if (current.Platform_Connection_Fee__c == null && platformFee != null)  { changes.Platform_Connection_Fee__c = platformFee; anyChange = true; }
        if (current.Professional_Service_Fees__c == null && proServices != null){ changes.Professional_Service_Fees__c = proServices; anyChange = true; }
        if (current.Total_Contract_Value__c == null && tcv != null)             { changes.Total_Contract_Value__c = tcv; anyChange = true; }
        if (current.Amount == null && tcv != null)                              { changes.Amount = tcv; anyChange = true; }
        if (current.Annual_Recurring_Revenue__c == null && arr != null)         { changes.Annual_Recurring_Revenue__c = arr; anyChange = true; }

        String renewal = OrderFormPicklistMapper.mapRenewalTerms((String) extracted.get('Renewal_Terms'));
        if (current.Renewal_Terms__c == null && renewal != null) { changes.Renewal_Terms__c = renewal; anyChange = true; }

        String subSched = OrderFormPicklistMapper.mapSubscriptionSchedule((String) extracted.get('Subscription_Schedule'));
        if (current.Subscription_Schedule__c == null && subSched != null) { changes.Subscription_Schedule__c = subSched; anyChange = true; }

        String payTerms = OrderFormPicklistMapper.mapPaymentTerms((String) extracted.get('Payment_Terms'));
        if (current.Payment_Terms__c == null && payTerms != null) { changes.Payment_Terms__c = payTerms; anyChange = true; }

        String credTerms = OrderFormPicklistMapper.mapCreditTerms((String) extracted.get('Credit_Terms'));
        if (current.Credit_Terms__c == null && credTerms != null) { changes.Credit_Terms__c = credTerms; anyChange = true; }

        String billingEmail = (String) extracted.get('Billing_Contact_Email');
        if (String.isBlank(current.Billing_Contact__c) && String.isNotBlank(billingEmail)) {
            changes.Billing_Contact__c = billingEmail;
            anyChange = true;
        }

        Boolean ela = toBoolean(extracted.get('ELA'));
        if (current.ELA__c == false && ela == true) { changes.ELA__c = true; anyChange = true; }

        String specialTerms = (String) extracted.get('Special_Terms');
        Decimal credits = toDecimal(extracted.get('Credits_Purchased'));
        String creditsPeriod = (String) extracted.get('Credits_Period');
        String appendix = composeNotesAppendix(specialTerms, credits, creditsPeriod, isAmendment);
        if (String.isNotBlank(appendix) && String.isBlank(current.Notes__c)) {
            changes.Notes__c = appendix;
            anyChange = true;
        }

        return anyChange ? changes : null;
    }

    private static String composeNotesAppendix(String specialTerms, Decimal credits, String period, Boolean isAmendment) {
        List<String> parts = new List<String>();
        if (credits != null) {
            String periodStr = String.isNotBlank(period) ? ' per ' + period : '';
            parts.add('Credits: ' + credits.toPlainString() + periodStr);
        }
        if (String.isNotBlank(specialTerms)) {
            parts.add('Special terms: ' + specialTerms);
        }
        if (isAmendment == true) {
            parts.add('[Source: amendment / rider]');
        }
        return parts.isEmpty() ? null : String.join(parts, '\n');
    }

    private static Date parseDate(String iso) {
        if (String.isBlank(iso)) return null;
        try {
            return Date.valueOf(iso);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return Decimal.valueOf((Integer) v);
        if (v instanceof Long) return Decimal.valueOf((Long) v);
        if (v instanceof Double) return Decimal.valueOf((Double) v);
        if (v instanceof String) {
            try { return Decimal.valueOf(((String) v).trim()); } catch (Exception e) { return null; }
        }
        return null;
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

    public class OrderFormException extends Exception {}
}
