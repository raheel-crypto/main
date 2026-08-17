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
    // Base64 expands 1.33x and JSON.serialize makes another copy of the encoded
    // string, so peak heap during request build is roughly 2.7x the raw PDF
    // bytes. Async heap ceiling is 12MB, so cap raw payload at 3MB total (~8MB
    // peak) with a per-file cap so a single 6MB behemoth doesn't blow it alone.
    @TestVisible private static final Integer MAX_TOTAL_PDF_BYTES = 3 * 1024 * 1024;
    @TestVisible private static final Integer MAX_PER_FILE_BYTES = 4 * 1024 * 1024;

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
            // Split files by source so Claude can be told which are the CURRENT
            // deal and which are PARENT CONTRACT context.
            List<ContentVersion> currentFiles = new List<ContentVersion>();
            List<ContentVersion> baseFiles = new List<ContentVersion>();
            List<String> skipped = new List<String>();
            classifyFilesBySource(docIds, versionByDocId, opportunityId,
                parentOpp == null ? null : parentOpp.Base_Opportunity__c,
                currentFiles, baseFiles, skipped);

            if (currentFiles.isEmpty() && baseFiles.isEmpty()) {
                row.Extraction_Status__c = 'No Document';
                row.Error_Message__c = skipped.isEmpty()
                    ? 'No ContentVersion data found for the supplied ContentDocument Ids.'
                    : 'No usable files. Skipped unsupported types: ' + String.join(skipped, ', ');
                return row;
            }

            String body = buildRequestBody(currentFiles, baseFiles, opportunityId, parentOpp);
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
            if (!skipped.isEmpty()) {
                row.Error_Message__c = truncate(
                    'Note: files skipped or dropped during extraction (extraction still succeeded on the remaining files): '
                        + String.join(skipped, '; '),
                    ERROR_MESSAGE_LIMIT);
            }
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
            SELECT Id, Name, Type, CloseDate, AccountId, Annual_Recurring_Revenue__c,
                   Base_Opportunity__c,
                   Base_Opportunity__r.Name, Base_Opportunity__r.CloseDate,
                   Base_Opportunity__r.Annual_Recurring_Revenue__c
            FROM Opportunity WHERE Id = :opportunityId LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0];
    }

    @TestVisible
    private static void classifyFilesBySource(
        List<Id> docIds,
        Map<Id, ContentVersion> versionByDocId,
        Id currentOppId,
        Id baseOppId,
        List<ContentVersion> currentFilesOut,
        List<ContentVersion> baseFilesOut,
        List<String> skippedOut
    ) {
        if (docIds == null || docIds.isEmpty()) return;

        // Look up which Opp each ContentDocument is linked to. A single doc
        // can be linked to multiple parents; prefer the current Opp.
        Map<Id, Id> sourceByDoc = new Map<Id, Id>();
        Set<Id> scopeEntityIds = new Set<Id>{ currentOppId };
        if (baseOppId != null) scopeEntityIds.add(baseOppId);

        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :docIds
              AND LinkedEntityId IN :scopeEntityIds
        ]) {
            // Prefer current Opp if a doc is linked to both.
            Id existing = sourceByDoc.get(cdl.ContentDocumentId);
            if (existing == currentOppId) continue;
            sourceByDoc.put(cdl.ContentDocumentId, cdl.LinkedEntityId);
        }

        // First pass: split candidates into current vs base, filtering out
        // unsupported types and files bigger than the per-file cap.
        List<ContentVersion> currentCandidates = new List<ContentVersion>();
        List<ContentVersion> baseCandidates = new List<ContentVersion>();
        Set<Id> seen = new Set<Id>();
        for (Id docId : docIds) {
            if (seen.contains(docId)) continue;
            seen.add(docId);
            ContentVersion cv = versionByDocId.get(docId);
            if (cv == null || cv.VersionData == null) continue;
            if (getMediaType(cv) == null) {
                skippedOut.add((cv.Title == null ? cv.Id : cv.Title) + ' (unsupported: ' + cv.FileExtension + ')');
                continue;
            }
            Integer sz = cv.VersionData.size();
            if (sz > MAX_PER_FILE_BYTES) {
                skippedOut.add((cv.Title == null ? cv.Id : cv.Title) +
                    ' (too large: ' + sz + ' bytes; cap ' + MAX_PER_FILE_BYTES + ')');
                continue;
            }
            Id linkedTo = sourceByDoc.get(docId);
            if (linkedTo == currentOppId) currentCandidates.add(cv);
            else if (linkedTo == baseOppId) baseCandidates.add(cv);
            else currentCandidates.add(cv); // unknown linkage defaults to "current deal"
        }

        // Second pass: fit within MAX_TOTAL_PDF_BYTES. Current-deal files come
        // first (best-effort, all included). Base files fill remaining budget.
        Integer usedBytes = 0;
        for (ContentVersion cv : currentCandidates) {
            currentFilesOut.add(cv);
            usedBytes += cv.VersionData.size();
        }
        for (ContentVersion cv : baseCandidates) {
            Integer sz = cv.VersionData.size();
            if (usedBytes + sz > MAX_TOTAL_PDF_BYTES) {
                skippedOut.add((cv.Title == null ? cv.Id : cv.Title) +
                    ' (dropped to fit heap budget: ' + sz + ' bytes would put us over ' + MAX_TOTAL_PDF_BYTES + ')');
                continue;
            }
            baseFilesOut.add(cv);
            usedBytes += sz;
        }
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
            SELECT Id, ContentDocumentId, VersionData, Title, PathOnClient, FileType, FileExtension
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds AND IsLatest = true
        ]) {
            byDoc.put(cv.ContentDocumentId, cv);
        }
        return byDoc;
    }

    @TestVisible
    private static String buildDealContext(Id currentOppId, Opportunity parentOpp, Integer numCurrent, Integer numBase, String currentFileNames) {
        String name = (parentOpp != null && String.isNotBlank(parentOpp.Name)) ? parentOpp.Name : 'unknown';
        String type = (parentOpp != null && String.isNotBlank(parentOpp.Type)) ? parentOpp.Type : 'unspecified';
        String closeDate = (parentOpp != null && parentOpp.CloseDate != null) ? String.valueOf(parentOpp.CloseDate) : 'unknown';
        String baseName = (parentOpp != null && parentOpp.Base_Opportunity__r != null && String.isNotBlank(parentOpp.Base_Opportunity__r.Name))
            ? parentOpp.Base_Opportunity__r.Name : null;

        String s =
            'DEAL CONTEXT:\n' +
            'You are extracting the CURRENT deal below. Documents are split into two groups.\n' +
            '- Opportunity Name: ' + name + '\n' +
            '- Opportunity Type: ' + type + '\n' +
            '- Close Date: ' + closeDate + '\n' +
            '- Current-deal documents attached: ' + numCurrent + '\n' +
            '- Current-deal file name(s) (WEAK last-resort hint only - filenames are often wrong/stale and can name the wrong entity; never prefer over the document body): ' +
                (String.isBlank(currentFileNames) ? 'n/a' : currentFileNames) + '\n' +
            '- Parent-contract context documents attached: ' + numBase;
        if (baseName != null) s += ' (from base Opportunity "' + baseName + '")';
        s += '\n\nIMPORTANT: Extract THE CURRENT deal. If parent-contract documents are present, treat them as CONTEXT ONLY ' +
             '(for unchanged MSA terms, base ARR/seats for incremental computation, prior renewal cadence). ' +
             'Do NOT report figures from the parent contract as if they were the current deal. ' +
             'When the parent and current deal describe different legal entities, customers, seat counts, or terms, the CURRENT-deal documents win.';
        return s;
    }

    private static Map<String, Object> makeFileBlock(ContentVersion cv) {
        String mediaType = getMediaType(cv);
        if (mediaType == null) return null;
        String blockType = mediaType.startsWith('image/') ? 'image' : 'document';
        return new Map<String, Object>{
            'type' => blockType,
            'source' => new Map<String, Object>{
                'type' => 'base64',
                'media_type' => mediaType,
                'data' => EncodingUtil.base64Encode(cv.VersionData)
            }
        };
    }

    @TestVisible
    private static String getMediaType(ContentVersion cv) {
        String ext = cv.FileExtension;
        if (String.isBlank(ext) && cv.FileType != null) ext = cv.FileType;
        if (String.isBlank(ext) && String.isNotBlank(cv.PathOnClient) && cv.PathOnClient.contains('.')) {
            ext = cv.PathOnClient.substringAfterLast('.');
        }
        if (String.isBlank(ext)) return null;
        String e = ext.toLowerCase();
        if (e == 'pdf') return 'application/pdf';
        if (e == 'png') return 'image/png';
        if (e == 'jpg' || e == 'jpeg') return 'image/jpeg';
        if (e == 'gif') return 'image/gif';
        if (e == 'webp') return 'image/webp';
        return null;
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
    private static String buildRequestBody(
        List<ContentVersion> currentFiles,
        List<ContentVersion> baseFiles,
        Id currentOppId,
        Opportunity parentOpp
    ) {
        String systemPrompt = loadPrompt();
        List<Object> content = new List<Object>();

        // Deal context header so Claude knows WHICH deal it's extracting.
        List<String> currentTitles = new List<String>();
        for (ContentVersion cv : currentFiles) if (String.isNotBlank(cv.Title)) currentTitles.add(cv.Title);
        content.add(new Map<String, Object>{
            'type' => 'text',
            'text' => buildDealContext(currentOppId, parentOpp,
                                       currentFiles.size(), baseFiles.size(),
                                       String.join(currentTitles, ', '))
        });

        // Current deal docs first, labeled.
        if (!currentFiles.isEmpty()) {
            content.add(new Map<String, Object>{
                'type' => 'text',
                'text' => '--- CURRENT DEAL DOCUMENTS (extract THIS deal) ---'
            });
            for (ContentVersion cv : currentFiles) {
                Object block = makeFileBlock(cv);
                if (block != null) content.add(block);
            }
        }

        // Base/parent docs next, explicitly labeled as context.
        if (!baseFiles.isEmpty()) {
            content.add(new Map<String, Object>{
                'type' => 'text',
                'text' => '--- PARENT CONTRACT DOCUMENTS (CONTEXT ONLY - do NOT extract these as the deal) ---\n' +
                          'Use these only for: unchanged MSA boilerplate (renewal terms, payment terms, credit terms), ' +
                          'and as a reference for the base ARR / seats that the current deal expands or renews.'
            });
            for (ContentVersion cv : baseFiles) {
                Object block = makeFileBlock(cv);
                if (block != null) content.add(block);
            }
        }

        content.add(new Map<String, Object>{
            'type' => 'text',
            'text' => 'Extract the CURRENT deal per the schema, using parent docs only for context. Return JSON only.'
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
        row.Renewal_Fee_Escalator__c = toDecimal(extracted.get('Renewal_Fee_Escalator_Percent'));
        row.Billing_Entity_Name__c = truncate((String) extracted.get('Billing_Entity_Name'), 255);
        row.Billing_Entity_Review__c = toBoolean(extracted.get('Billing_Entity_Is_Derived')) == true;
        row.Billing_Entity_Reg_Id__c = truncate((String) extracted.get('Billing_Entity_Reg_Id'), 100);
        row.Billing_Entity_Address__c = truncate((String) extracted.get('Billing_Entity_Address'), 255);
        row.Billing_Entity_Jurisdiction__c = truncate((String) extracted.get('Billing_Entity_Jurisdiction'), 100);
        row.Source_Document_Type__c = mapDocumentType((String) extracted.get('Source_Document_Type'));
        row.Seats_Added__c = toDecimal(extracted.get('Seats_Added'));
        row.Named_Users__c = truncate((String) extracted.get('Named_Users'), 4096);
        row.Requested_By_Name__c = truncate((String) extracted.get('Requested_By_Name'), 255);
        row.Requested_By_Email__c = truncate((String) extracted.get('Requested_By_Email'), 255);

        populatePackageAndCreditFields(row, extracted);
        populateSignatureFields(row, extracted);
        populateSubprocessorFields(row, extracted);
        row.Pricing_Structure__c = derivePricingStructure(row);
        deriveEndDate(row);
    }

    @TestVisible private static final Integer DEFAULT_SUBPROCESSOR_NOTICE_DAYS = 30;

    @TestVisible
    private static void populateSubprocessorFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        row.Subprocessor_Restrictions__c = truncate((String) extracted.get('Subprocessor_Restrictions'), 255);

        Decimal notice = toDecimal(extracted.get('Subprocessor_Notice_Period_Days'));
        String evidence = (String) extracted.get('Extract_Evidence');
        if (notice != null) {
            row.Subprocessor_Notice_Period__c = notice;
        } else {
            // No explicit day count found: Rogo's standard is 30 days, so
            // default rather than leaving it blank. Note the assumption in
            // the evidence trail so Legal can tell defaulted from stated.
            row.Subprocessor_Notice_Period__c = DEFAULT_SUBPROCESSOR_NOTICE_DAYS;
            String note = '## Subprocessor_Notice_Period_Days\nDefaulted to ' +
                DEFAULT_SUBPROCESSOR_NOTICE_DAYS + ' (no explicit day-count notice period found in the attached documents).';
            evidence = String.isBlank(evidence) ? note : evidence + '\n\n' + note;
        }
        row.Extract_Evidence__c = truncate(evidence, 32768);
    }

    @TestVisible
    private static void populateSignatureFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        Date customerSig = parseDate((String) extracted.get('Customer_Signature_Date'));
        Date rogoSig = parseDate((String) extracted.get('Rogo_Signature_Date'));

        // Effective date = latest signature. Fallback to whichever is present.
        if (customerSig != null && rogoSig != null) {
            row.Signature_Date__c = (rogoSig > customerSig) ? rogoSig : customerSig;
        } else if (rogoSig != null) {
            row.Signature_Date__c = rogoSig;
        } else if (customerSig != null) {
            row.Signature_Date__c = customerSig;
        }

        row.Customer_Signer_Name__c = truncate((String) extracted.get('Customer_Signer_Name'), 255);
        row.Customer_Signer_Title__c = truncate((String) extracted.get('Customer_Signer_Title'), 100);
    }

    /**
     * Reps were choosing the wrong Pricing_Structure value in the screen flow,
     * so we compute it deterministically here from three axes:
     *   1. ELA__c: true -> "ELA: ...", false -> "Seats: ..."
     *   2. Credit_Commit__c or Credits_Purchased__c non-null -> "Credit-Based Usage"
     *   3. Otherwise unlimited path; Rate_Limitable__c='Yes' -> "with Throttling",
     *      anything else -> "No Throttling" (user's rule: non-credit unlimited
     *      is assumed non-throttled).
     */
    public static String derivePricingStructure(Order_Form_Extraction__c row) {
        String prefix = (row.ELA__c == true) ? 'ELA' : 'Seats';
        Boolean creditBased = row.Credit_Commit__c == true
            || (row.Credits_Purchased__c != null && row.Credits_Purchased__c > 0);
        if (creditBased) return prefix + ': Credit-Based Usage';
        Boolean throttled = 'Yes'.equals(row.Rate_Limitable__c);
        return throttled
            ? prefix + ': Unlimited Usage, with Throttling'
            : prefix + ': Unlimited Usage, No Throttling';
    }

    @TestVisible
    private static void populatePackageAndCreditFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        row.Package_Tier__c = OrderFormPicklistMapper.mapPackageTier((String) extracted.get('Package_Tier'));
        row.Credit_Commit__c = toBoolean(extracted.get('Credit_Commit')) == true;
        row.Credit_Overcommit_Obligation__c = toBoolean(extracted.get('Credit_Overcommit_Obligation')) == true;

        Boolean rateLimitable = toBoolean(extracted.get('Rate_Limitable_By_Rogo'));
        if (rateLimitable == true) row.Rate_Limitable__c = 'Yes';
        else if (rateLimitable == false) row.Rate_Limitable__c = 'No';
        else row.Rate_Limitable__c = 'Not specified';
        row.Rate_Limit_Notes__c = truncate((String) extracted.get('Rate_Limit_Terms'), 32768);

        Boolean isEnterprise = 'Enterprise'.equals(row.Package_Tier__c);
        row.Unlimited_Lite__c = resolveTristate(toBoolean(extracted.get('Unlimited_Lite_Stated')), isEnterprise);
        row.Free_Max_Mid_Credits__c = resolveTristate(toBoolean(extracted.get('Free_Max_Mid_Stated')), isEnterprise);
        row.Free_Max_Mid_Amount__c = toDecimal(extracted.get('Free_Max_Mid_Amount'));
    }

    private static String resolveTristate(Boolean stated, Boolean isEnterprise) {
        if (stated == true) return 'Yes';
        if (stated == false) return 'No';
        return isEnterprise ? 'Inferred (Enterprise)' : 'Not specified';
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

        if (parentOpp == null) return;
        Decimal baseARR = null;

        // 1) Explicit Base_Opportunity linkage (typical for Upsells that expand
        //    a specific Land/parent deal).
        if (parentOpp.Base_Opportunity__c != null) {
            List<Order_Form_Extraction__c> baseRows = [
                SELECT Annual_Recurring_Revenue__c
                FROM Order_Form_Extraction__c
                WHERE Opportunity__c = :parentOpp.Base_Opportunity__c
                  AND Extraction_Status__c = 'Success'
                  AND Annual_Recurring_Revenue__c != null
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!baseRows.isEmpty()) {
                baseARR = baseRows[0].Annual_Recurring_Revenue__c;
            } else if (parentOpp.Base_Opportunity__r != null) {
                baseARR = parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c;
            }
        }

        // 2) No base link (typical for Renewals - they renew the same
        //    subscription rather than expanding a parent deal). The prior /
        //    aggregate ARR is carried on THIS Opp's own Annual_Recurring_Revenue__c
        //    at close time (e.g. Land 20k + Upsell 35k = 55k on the renewal opp,
        //    renewing up to 81k). Use it as the base. The != totalARR guard
        //    avoids a bogus 0 when the Opp ARR has already been set to the new
        //    value by another process.
        if (baseARR == null && parentOpp.Annual_Recurring_Revenue__c != null
                && parentOpp.Annual_Recurring_Revenue__c != totalARR) {
            baseARR = parentOpp.Annual_Recurring_Revenue__c;
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

    private static String mapDocumentType(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('email')) return 'Email Confirmation';
        if (s.contains('order') || s.contains('service order')) return 'Order Form';
        if (s.contains('rider') || s.contains('amendment')) return 'Rider / Amendment';
        if (s.contains('msa') || s.contains('agreement') || s.contains('master')) return 'MSA / Agreement';
        return 'Other';
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
