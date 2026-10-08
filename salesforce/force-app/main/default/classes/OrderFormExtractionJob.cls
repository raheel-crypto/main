public with sharing class OrderFormExtractionJob implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String NAMED_CRED = 'callout:Anthropic_Claude';
    // Sonnet 5: newer generation and cheaper than Sonnet 4.6 ($2/$10 vs $3/$15
    // per MTok). Extraction is a scan-and-pull workload, so a newer-gen model at
    // lower cost is the right tier (Opus is overkill; Haiku under-judges the
    // strictest-gate roll-up). The callout sends no prefill/budget_tokens/thinking,
    // so this is a clean model swap. NOTE: Sonnet 5 runs adaptive thinking by
    // default; validated on the SG/Macquarie/WF/BofA set before fleet-wide use.
    @TestVisible private static final String MODEL = 'claude-sonnet-5';
    // v2 gate spec adds ~21 fields plus an Extract_Evidence JSON object, so the
    // response JSON roughly doubled. 4096 was truncating output on rich contracts.
    @TestVisible private static final Integer MAX_TOKENS = 8192;
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
            OrderFormVersioning.insertWithVersioning(new List<Order_Form_Extraction__c>{ row });
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

            // Flag the row whenever any file was excluded (unsupported type, over
            // the per-file cap, or dropped for the heap budget) so a possibly
            // incomplete extraction - e.g. a null Sub_Processor_List__c because
            // the DPA got dropped - is queryable, not buried in Error_Message__c.
            row.Docs_Dropped__c = !skipped.isEmpty();

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
                // The model occasionally emits a single malformed-JSON character
                // on a complex doc (e.g. a semicolon joining two strings inside an
                // evidence quote), which fails the whole row even though the
                // content is fine. Re-issue the same request once - a fresh
                // generation almost always returns valid JSON. Reuses the already
                // built body, so no VersionData reload.
                try {
                    HttpResponse retryResp = callAnthropic(body);
                    row.HTTP_Status_Code__c = retryResp.getStatusCode();
                    row.Raw_Response__c = truncate(retryResp.getBody(), RAW_RESPONSE_LIMIT);
                    if (retryResp.getStatusCode() < 200 || retryResp.getStatusCode() >= 300) {
                        row.Extraction_Status__c = 'API Failed';
                        row.Error_Message__c = truncate('Retry HTTP ' + retryResp.getStatusCode() + ': ' + retryResp.getBody(), ERROR_MESSAGE_LIMIT);
                        return row;
                    }
                    extracted = parseAssistantJson(retryResp.getBody());
                } catch (Exception e2) {
                    row.Extraction_Status__c = 'Parse Failed';
                    row.Error_Message__c = truncate('Parse failed on original and retry. ' + e2.getMessage() + '\n' + e2.getStackTraceString(), ERROR_MESSAGE_LIMIT);
                    return row;
                }
            }

            row.Extracted_JSON__c = truncate(JSON.serializePretty(extracted), EXTRACTED_JSON_LIMIT);
            finishRow(row, extracted, parentOpp, currentFiles.size(), skipped);
            return row;

        } catch (Exception e) {
            row.Extraction_Status__c = 'API Failed';
            row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
            return row;
        }
    }

    /**
     * Build a row from an Anthropic Messages response obtained OUTSIDE Apex - for
     * documents too large for the Apex heap, extracted by a local Files-API job.
     * No callout and NO VersionData load here (so the file size is irrelevant);
     * it reuses the exact same parsing + field mapping as buildExtraction, so the
     * resulting row is identical to an in-platform one. Caller inserts it.
     */
    public static Order_Form_Extraction__c buildFromResponseBody(
            Id opportunityId, List<Id> contentDocumentIds, String responseBody) {
        List<Id> docIds = contentDocumentIds == null ? new List<Id>() : contentDocumentIds;
        Opportunity parentOpp = loadParentOpp(opportunityId);

        // Titles only - never select VersionData (would blow heap on a big file).
        List<String> names = new List<String>();
        if (!docIds.isEmpty()) {
            Map<Id, String> titleByDoc = new Map<Id, String>();
            for (ContentVersion cv : [
                SELECT ContentDocumentId, Title FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND IsLatest = true
            ]) {
                titleByDoc.put(cv.ContentDocumentId, cv.Title);
            }
            for (Id d : docIds) if (titleByDoc.containsKey(d)) names.add(titleByDoc.get(d));
        }

        Order_Form_Extraction__c row = new Order_Form_Extraction__c(
            Opportunity__c = opportunityId,
            Content_Document_Id__c = truncate(joinIds(docIds), DOC_ID_LIMIT),
            File_Name__c = truncate(String.join(names, '; '), FILE_NAME_LIMIT),
            Extracted_At__c = System.now(),
            Model__c = MODEL
        );
        row.Raw_Response__c = truncate(responseBody, RAW_RESPONSE_LIMIT);

        try {
            Map<String, Object> extracted = parseAssistantJson(responseBody);
            row.Extracted_JSON__c = truncate(JSON.serializePretty(extracted), EXTRACTED_JSON_LIMIT);
            // The off-platform job may run a different model than MODEL; record
            // the one that actually produced this response.
            String served = responseModel(responseBody);
            if (String.isNotBlank(served)) row.Model__c = served;
            // File groups are not known here (the Files-API job sends one group).
            finishRow(row, extracted, parentOpp, null, new List<String>());
        } catch (Exception e) {
            row.Extraction_Status__c = 'Parse Failed';
            row.Error_Message__c = truncate(e.getMessage() + '\n' + e.getStackTraceString(), ERROR_MESSAGE_LIMIT);
        }
        return row;
    }

    @TestVisible
    private static Opportunity loadParentOpp(Id opportunityId) {
        if (opportunityId == null) return null;
        List<Opportunity> opps = [
            SELECT Id, Name, Type, CloseDate, CreatedDate, AccountId, Annual_Recurring_Revenue__c, ContractId,
                   Base_Opportunity__c,
                   Base_Opportunity__r.Name, Base_Opportunity__r.CloseDate,
                   Base_Opportunity__r.Annual_Recurring_Revenue__c, Base_Opportunity__r.ContractId
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
                skippedOut.add((cv.Title == null ? String.valueOf(cv.Id) : cv.Title) + ' (unsupported: ' + cv.FileExtension + ')');
                continue;
            }
            Integer sz = cv.VersionData.size();
            if (sz > MAX_PER_FILE_BYTES) {
                skippedOut.add((cv.Title == null ? String.valueOf(cv.Id) : cv.Title) +
                    ' (too large: ' + sz + ' bytes; cap ' + MAX_PER_FILE_BYTES + ')');
                continue;
            }
            Id linkedTo = sourceByDoc.get(docId);
            if (linkedTo == currentOppId) currentCandidates.add(cv);
            else if (linkedTo == baseOppId) baseCandidates.add(cv);
            else currentCandidates.add(cv); // unknown linkage defaults to "current deal"
        }

        // Second pass: fit EVERY file (current + base) within MAX_TOTAL_PDF_BYTES.
        // The whole request is base64-encoded into one JSON string at ~3x the raw
        // bytes in peak heap and the async heap ceiling is 12MB, so this budget
        // MUST cover current-deal files too - not just base files (an opp with an
        // Order Form + MSA + DPA + rider can otherwise blow heap with an
        // uncatchable limit exception). Order files so the most extraction-
        // relevant survive when over budget: current-deal files ahead of
        // base/context files, and within each group the order form + legal / DPA /
        // subprocessor / MSA docs ahead of incidental attachments (NDAs, W-9s).
        // Whatever does not fit is dropped and recorded (Docs_Dropped__c flags it).
        List<RankedDoc> ordered = new List<RankedDoc>();
        for (ContentVersion cv : currentCandidates) {
            ordered.add(new RankedDoc(docRelevanceRank(cv), cv.VersionData.size(), cv, true));
        }
        for (ContentVersion cv : baseCandidates) {
            // +100 keeps all base/context files behind all current-deal files.
            ordered.add(new RankedDoc(100 + docRelevanceRank(cv), cv.VersionData.size(), cv, false));
        }
        ordered.sort();

        Integer usedBytes = 0;
        for (RankedDoc rd : ordered) {
            if (usedBytes + rd.size > MAX_TOTAL_PDF_BYTES) {
                skippedOut.add((rd.cv.Title == null ? String.valueOf(rd.cv.Id) : rd.cv.Title) +
                    ' (dropped to fit heap budget: ' + rd.size + ' bytes would put the request over the ' +
                    MAX_TOTAL_PDF_BYTES + '-byte cap)');
                continue;
            }
            if (rd.isCurrent) currentFilesOut.add(rd.cv);
            else baseFilesOut.add(rd.cv);
            usedBytes += rd.size;
        }
    }

    // Priority score for fitting files into the heap budget. Lower = keep first.
    // Compliance-relevant docs (order form, DPA/subprocessor, MSA) rank ahead of
    // incidental attachments so, when we must drop something, an NDA/W-9 goes
    // before a contract. Keyword-based and deliberately forgiving - it only
    // orders the drop queue, it does not decide what gets extracted.
    @TestVisible
    private static Integer docRelevanceRank(ContentVersion cv) {
        String t = (cv != null && cv.Title != null) ? cv.Title.toLowerCase() : '';
        if (t.contains('order form') || t.contains('order_form') || t.contains('orderform')
            || t.contains('order-form') || t.contains('customer agreement form')) {
            return 0; // commercial terms - usually the primary doc
        }
        if (t.contains('dpa') || t.contains('data processing') || t.contains('data protection')
            || t.contains('subprocessor') || t.contains('sub-processor') || t.contains('sub processor')) {
            return 1; // data-protection / subprocessor text - compliance critical
        }
        if (t.contains('msa') || t.contains('mssa') || t.contains('master') || t.contains('agreement')
            || t.contains('schedule') || t.contains('addendum') || t.contains('rider')
            || t.contains('amendment') || t.contains('saas') || t.contains('subscription')) {
            return 2; // master / services / subscription agreements and riders
        }
        if (t.contains('nda') || t.contains('non-disclosure') || t.contains('nondisclosure')
            || t.contains('w-9') || t.contains('w9') || t.contains('coi') || t.contains('insurance')
            || t.contains('logo') || t.contains('certificate')) {
            return 9; // incidental - drop these first
        }
        return 5; // unknown - middle priority
    }

    // Sortable wrapper: primary key rank (base/context files carry a +100 offset
    // so they trail current-deal files), then size ascending so smaller files of
    // equal rank pack in first.
    private class RankedDoc implements Comparable {
        Integer rank;
        Integer size;
        ContentVersion cv;
        Boolean isCurrent;
        RankedDoc(Integer rank, Integer size, ContentVersion cv, Boolean isCurrent) {
            this.rank = rank;
            this.size = size;
            this.cv = cv;
            this.isCurrent = isCurrent;
        }
        public Integer compareTo(Object o) {
            RankedDoc other = (RankedDoc) o;
            if (this.rank != other.rank) return this.rank < other.rank ? -1 : 1;
            if (this.size != other.size) return this.size < other.size ? -1 : 1;
            return 0;
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

    @TestVisible
    private static String fileLabel(Integer n, Boolean isCurrent, String title) {
        return 'FILE ' + n + ' (' + (isCurrent ? 'CURRENT DEAL' : 'PARENT CONTEXT') + '): '
            + (String.isBlank(title) ? 'untitled' : title);
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

        // Current deal docs first, labeled. Every file gets a "FILE n" label so
        // the model can classify each one (Documents[]); files 1..currentFiles
        // are the current deal, the rest parent-contract context.
        Integer fileNo = 0;
        if (!currentFiles.isEmpty()) {
            content.add(new Map<String, Object>{
                'type' => 'text',
                'text' => '--- CURRENT DEAL DOCUMENTS (extract THIS deal) ---'
            });
            for (ContentVersion cv : currentFiles) {
                Object block = makeFileBlock(cv);
                if (block == null) continue;
                fileNo++;
                content.add(new Map<String, Object>{ 'type' => 'text', 'text' => fileLabel(fileNo, true, cv.Title) });
                content.add(block);
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
                if (block == null) continue;
                fileNo++;
                content.add(new Map<String, Object>{ 'type' => 'text', 'text' => fileLabel(fileNo, false, cv.Title) });
                content.add(block);
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
            // Sonnet 5 runs adaptive thinking by default; on a ~280K-token
            // contract it burned the ENTIRE max_tokens budget on thinking and
            // never emitted the JSON (stop_reason=max_tokens, 0 text tokens).
            // This is deterministic field extraction - the prompt encodes the
            // rules - so disable thinking: all output tokens go to the JSON, and
            // it matches Sonnet 4.6's default (no-thinking) behavior we validated.
            'thinking' => new Map<String, Object>{ 'type' => 'disabled' },
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
        row.Value_Basis__c = OrderFormPicklistMapper.mapValueBasis(asStr(extracted.get('Value_Basis')));
        row.Renewal_Terms__c = OrderFormPicklistMapper.mapRenewalTerms((String) extracted.get('Renewal_Terms'));
        row.Subscription_Schedule__c = OrderFormPicklistMapper.mapSubscriptionSchedule((String) extracted.get('Subscription_Schedule'));
        row.Payment_Terms__c = OrderFormPicklistMapper.mapPaymentTerms((String) extracted.get('Payment_Terms'));
        row.Credit_Terms__c = OrderFormPicklistMapper.mapCreditTerms((String) extracted.get('Credit_Terms'));
        row.Pricing_Structure__c = truncate(extracted.get('Pricing_Structure'), 100);
        row.Billing_Contact_Email__c = sanitizeEmail(extracted.get('Billing_Contact_Email'));
        row.Primary_Contact__c = truncate(extracted.get('Primary_Contact_Name'), 255);
        row.Primary_Contact_Phone__c = truncate(extracted.get('Primary_Contact_Phone'), 255);
        row.Primary_Contact_Email__c = sanitizeEmail(extracted.get('Primary_Contact_Email'));
        Boolean ela = toBoolean(extracted.get('ELA'));
        row.ELA__c = ela == true;
        Boolean paid = toBoolean(extracted.get('Paid_Trial'));
        row.Paid_Trial__c = paid == true;
        row.Trial_Price__c = toDecimal(extracted.get('Trial_Price'));
        row.Pilot_Success_Criteria__c = truncate(extracted.get('Pilot_Success_Criteria'), 32768);
        row.Credits_Purchased__c = toDecimal(extracted.get('Credits_Purchased'));
        row.Credits_Period__c = mapCreditsPeriod((String) extracted.get('Credits_Period'));
        row.Special_Terms__c = truncate(extracted.get('Special_Terms'), 32768);
        row.Logo_Publicity_Rights__c = OrderFormPicklistMapper.mapPublicityRights((String) extracted.get('Logo_Publicity_Rights'));
        row.Logo_Publicity_Language__c = truncate(extracted.get('Logo_Publicity_Language'), 32768);
        row.Renewal_Fee_Escalator__c = toDecimal(extracted.get('Renewal_Fee_Escalator_Percent'));
        row.Billing_Entity_Name__c = truncate(extracted.get('Billing_Entity_Name'), 255);
        row.Billing_Entity_Review__c = toBoolean(extracted.get('Billing_Entity_Is_Derived')) == true;
        row.Billing_Entity_Reg_Id__c = truncate(extracted.get('Billing_Entity_Reg_Id'), 100);
        row.Billing_Entity_Address__c = truncate(extracted.get('Billing_Entity_Address'), 255);
        row.Billing_Entity_Jurisdiction__c = truncate(extracted.get('Billing_Entity_Jurisdiction'), 100);
        row.Source_Document_Type__c = mapDocumentType((String) extracted.get('Source_Document_Type'));
        row.Seats_Added__c = toDecimal(extracted.get('Seats_Added'));
        row.Named_Users__c = truncate(extracted.get('Named_Users'), 4096);
        row.Requested_By_Name__c = truncate(extracted.get('Requested_By_Name'), 255);
        row.Requested_By_Email__c = sanitizeEmail(extracted.get('Requested_By_Email'));
        row.Credit_Rate__c = toDecimal(extracted.get('Credit_Rate_Stated'));
        row.Overage_Rate__c = toDecimal(extracted.get('Overage_Rate'));
        row.Free_Tier_Retained__c = OrderFormPicklistMapper.mapYesNoNotSpecified(asStr(extracted.get('Free_Tier_Retained')));

        populatePackageAndCreditFields(row, extracted);
        populateSignatureFields(row, extracted);
        populateSubprocessorFields(row, extracted);
        populateGateFields(row, extracted);
        row.Pricing_Structure__c = derivePricingStructure(row);
    }

    @TestVisible
    private static void populateSubprocessorFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        row.Subprocessor_Restrictions__c = truncate(extracted.get('Subprocessor_Restrictions'), 32768);
        row.Sub_Processor_List__c = truncate(mapSubprocessorListValue(extracted.get('Sub_Processor_List')), 32768);
        // Spec v2: a null day-count means NO notice obligation was found - do NOT
        // default it to 30 and do NOT treat it as zero. Store exactly what was
        // extracted (the LONGEST period when clauses conflict, per the prompt).
        row.Subprocessor_Notice_Period__c = toDecimal(extracted.get('Subprocessor_Notice_Period_Days'));
        row.Extract_Evidence__c = truncate(asEvidenceString(extracted.get('Extract_Evidence')), 32768);
    }

    // Serializes the extracted Sub_Processor_List. When named parties exist the
    // model returns an array of {name,scope,is_ai} objects -> store as JSON. When
    // none exist it returns a sentinel STRING ("By reference: ...", "No sub-
    // processors named...", "No DPA...") -> store as-is. null -> null.
    @TestVisible
    private static String mapSubprocessorListValue(Object raw) {
        if (raw == null) return null;
        if (raw instanceof List<Object>) {
            List<Object> items = (List<Object>) raw;
            return items.isEmpty() ? null : JSON.serialize(items);
        }
        String s = String.valueOf(raw).trim();
        return String.isBlank(s) ? null : s;
    }

    // Extract_Evidence may arrive as a JSON object {field:{clause,quote}} (v2) or
    // a plain string (older prompt). Store a string either way.
    @TestVisible
    private static String asEvidenceString(Object raw) {
        if (raw == null) return null;
        if (raw instanceof String) {
            String s = (String) raw;
            return String.isBlank(s) ? null : s;
        }
        return JSON.serialize(raw);
    }

    // Maps the LLM-enablement-gate fields (spec v2). Picklists route through the
    // mapper so a model variant can't write an invalid restricted value.
    @TestVisible
    private static void populateGateFields(Order_Form_Extraction__c row, Map<String, Object> extracted) {
        row.Resolved_Subprocessor_Term__c = truncate(extracted.get('Resolved_Subprocessor_Term'), 100);
        row.Subprocessor_Gate_Type__c = OrderFormPicklistMapper.mapGateType((String) extracted.get('Subprocessor_Gate_Type'));
        row.Consent_Revocable__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('Consent_Revocable'));
        row.Subprocessor_Objection_Consequence__c = truncate(extracted.get('Subprocessor_Objection_Consequence'), 255);
        row.Subprocessor_List_Location__c = OrderFormPicklistMapper.mapListLocation((String) extracted.get('Subprocessor_List_Location'));
        row.Subprocessor_List_Granularity__c = OrderFormPicklistMapper.mapListGranularity((String) extracted.get('Subprocessor_List_Granularity'));
        row.AI_Model_Change_Gate_Days__c = toDecimal(extracted.get('AI_Model_Change_Gate_Days'));
        row.AI_Model_Change_Documentation__c = truncate(extracted.get('AI_Model_Change_Documentation'), 32768);
        row.AI_Model_Change_Carveout__c = truncate(extracted.get('AI_Model_Change_Carveout'), 255);
        row.AI_Change_Reporting_Trigger__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('AI_Change_Reporting_Trigger'));
        row.Processing_Location_Gate__c = OrderFormPicklistMapper.mapLocationGate((String) extracted.get('Processing_Location_Gate'));
        row.Approved_Locations__c = truncate(extracted.get('Approved_Locations'), 255);
        row.Personal_Data_Disclosure_Gate__c = OrderFormPicklistMapper.mapDisclosureGate((String) extracted.get('Personal_Data_Disclosure_Gate'));
        row.Release_Notice_Days__c = toDecimal(extracted.get('Release_Notice_Days'));
        row.Release_Major_Notice_Days__c = toDecimal(extracted.get('Release_Major_Notice_Days'));
        row.Customer_Can_Defer_Release__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('Customer_Can_Defer_Release'));
        row.Material_Change_Notice__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('Material_Change_Notice'));
        row.AI_Training_Prohibition__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('AI_Training_Prohibition'));
        row.AI_Training_Flowdown_Required__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('AI_Training_Flowdown_Required'));
        row.Model_Capability_Floor__c = OrderFormPicklistMapper.mapYesNoNotSpecified((String) extracted.get('Model_Capability_Floor'));
        row.LLM_Gate_Confidence__c = OrderFormPicklistMapper.mapConfidence((String) extracted.get('LLM_Gate_Confidence'));
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

        row.Customer_Signer_Name__c = truncate(extracted.get('Customer_Signer_Name'), 255);
        row.Customer_Signer_Title__c = truncate(extracted.get('Customer_Signer_Title'), 100);
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
        row.Rate_Limit_Notes__c = truncate(extracted.get('Rate_Limit_Terms'), 32768);

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

    // ===================== Post-parse pipeline =====================
    // The model reports only what the paper STATES. Everything computed - term
    // length, the inclusive end date, annualised ARR and credits, amendment
    // increments, the credit rate - happens here, deterministically, and is
    // marked derived in Extract_Evidence__c and Derived_Fields__c. Shared by the
    // callout path and the off-platform Files-API path so both produce identical
    // rows.
    @TestVisible private static final Set<String> AMEND_TYPES =
        new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

    private static void finishRow(Order_Form_Extraction__c row, Map<String, Object> extracted,
                                  Opportunity parentOpp, Integer currentFileCount, List<String> skipped) {
        Derivations d = new Derivations(extracted.get('Extract_Evidence'));
        populateExtractedFields(row, extracted);
        overrideTypeFromOpp(row, parentOpp);
        Boolean hasOrderForm = classifyDocuments(row, extracted, currentFileCount);
        if (hasOrderForm == false) {
            clearEconomics(row);
            row.Pricing_Structure__c = derivePricingStructure(row);   // without the MSA's credits
        }
        normaliseTerm(row, d);
        // With no order form the economics step must not see the model's fee /
        // credit keys either - only the (cleared) row.
        computeEconomics(row, hasOrderForm == false ? new Map<String, Object>() : extracted, parentOpp, d);
        clampToFieldLimits(row, d);
        d.writeTo(row);
        applyStatus(row, hasOrderForm, skipped);
    }

    // Records the model's per-file classification and reports whether the CURRENT
    // deal includes an Order Form. Null = classification not returned (older
    // prompt), in which case the No Order Form rule is not applied.
    @TestVisible
    private static Boolean classifyDocuments(Order_Form_Extraction__c row, Map<String, Object> extracted,
                                             Integer currentFileCount) {
        row.Document_Classes__c = null;
        Object raw = extracted.get('Documents');
        if (!(raw instanceof List<Object>)) return null;
        List<String> lines = new List<String>();
        Boolean currentOrderForm = false;
        for (Object o : (List<Object>) raw) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> doc = (Map<String, Object>) o;
            String file = doc.get('file') == null ? 'unlabelled file' : String.valueOf(doc.get('file'));
            String cls = OrderFormPicklistMapper.mapDocumentClass(asStr(doc.get('class')));
            Boolean isCurrent = isCurrentFile(file, asStr(doc.get('group')), currentFileCount);
            lines.add(file + ' [' + (isCurrent ? 'Current' : 'Parent') + '] => ' + cls);
            if (isCurrent && cls == 'Order Form') currentOrderForm = true;
        }
        if (lines.isEmpty()) return null;
        row.Document_Classes__c = truncate(String.join(lines, '\n'), 8192);
        return currentOrderForm;
    }

    // Files 1..currentFileCount are the current deal (see buildRequestBody). When
    // the label can't be parsed or the count is unknown, trust the model's group.
    private static final Pattern FILE_NO = Pattern.compile('(?i)FILE\\s*(\\d+)');
    @TestVisible
    private static Boolean isCurrentFile(String file, String grp, Integer currentFileCount) {
        if (currentFileCount != null && file != null) {
            Matcher m = FILE_NO.matcher(file);
            if (m.find()) return Integer.valueOf(m.group(1)) <= currentFileCount;
        }
        if (file != null && file.toLowerCase().contains('parent')) return false;
        return grp == null || !grp.toLowerCase().contains('parent');
    }

    // No order form among the current deal's documents: MSA pricing exhibits,
    // MNDA dates etc. must not masquerade as this deal's economics.
    private static void clearEconomics(Order_Form_Extraction__c row) {
        row.Contract_Start_Date__c = null;
        row.Contract_End_Date__c = null;
        row.Contract_Length_Months__c = null;
        row.Contract_Length_Days__c = null;
        row.Seat_Licenses__c = null;
        row.Seats_Added__c = null;
        row.License_Fees__c = null;
        row.Platform_Connection_Fee__c = null;
        row.Professional_Service_Fees__c = null;
        row.Total_Contract_Value__c = null;
        row.Annual_Recurring_Revenue__c = null;
        row.Credits_Purchased__c = null;
        row.Credits_Period__c = null;
        row.Value_Basis__c = null;
        row.Credit_Rate__c = null;
        row.Overage_Rate__c = null;
        row.Trial_Price__c = null;
    }

    // Success requires an order form plus the minimums (see OrderFormVersioning).
    @TestVisible
    private static void applyStatus(Order_Form_Extraction__c row, Boolean hasOrderForm, List<String> skipped) {
        List<String> notes = new List<String>();
        if (hasOrderForm == false) {
            row.Extraction_Status__c = 'No Order Form';
            notes.add('No Order Form among the current-deal documents (only MSA / MNDA / DPA / other paper); '
                + 'economic fields were not extracted.');
        } else {
            List<String> missing = OrderFormVersioning.missingMinimums(row);
            if (missing.isEmpty()) {
                row.Extraction_Status__c = 'Success';
            } else {
                row.Extraction_Status__c = 'Incomplete';
                notes.add('Order form read but missing: ' + String.join(missing, ', ') + '.');
            }
        }
        if (skipped != null && !skipped.isEmpty()) {
            notes.add('Files skipped or dropped before extraction: ' + String.join(skipped, '; '));
        }
        row.Error_Message__c = notes.isEmpty() ? null : truncate(String.join(notes, '\n'), ERROR_MESSAGE_LIMIT);
    }

    // Rogo's convention: a term is INCLUSIVE of its start date, so the end date is
    // the anniversary minus one day (12 months from 9/30/2026 ends 9/29/2027).
    //  - A stated end that falls exactly on an anniversary is normalised back a
    //    day (End_Date_Source 'Normalized'); any other stated end is kept ('Stated').
    //  - No stated end: derive start + term - 1 day from a stated term ('Derived').
    //  - Term length not stated: compute it from the dates.
    private static void normaliseTerm(Order_Form_Extraction__c row, Derivations d) {
        Date startD = row.Contract_Start_Date__c;
        Date endD = row.Contract_End_Date__c;
        row.End_Date_Source__c = (endD != null) ? 'Stated' : null;
        if (startD == null) return;

        if (endD != null) {
            Integer k = startD.monthsBetween(endD);
            Integer statedDays = (row.Contract_Length_Days__c == null) ? null : row.Contract_Length_Days__c.intValue();
            if (statedDays != null && statedDays > 0 && endD == startD.addDays(statedDays)) {
                row.Contract_End_Date__c = endD.addDays(-1);
                row.End_Date_Source__c = 'Normalized';
                d.mark('Contract_End_Date', 'Paper states ' + String.valueOf(endD) + ' = start + ' + statedDays
                    + ' days; normalised to the inclusive end ' + String.valueOf(row.Contract_End_Date__c) + '.');
            } else if (k >= 1 && startD.addMonths(k) == endD) {
                row.Contract_End_Date__c = endD.addDays(-1);
                row.End_Date_Source__c = 'Normalized';
                d.mark('Contract_End_Date', 'Paper states ' + String.valueOf(endD) + ', the ' + k
                    + '-month anniversary of ' + String.valueOf(startD) + '; normalised to the inclusive end '
                    + String.valueOf(row.Contract_End_Date__c) + '.');
            }
        } else {
            Decimal m = row.Contract_Length_Months__c;
            if (m != null && m > 0 && m == m.setScale(0, RoundingMode.DOWN)) {
                row.Contract_End_Date__c = startD.addMonths(m.intValue()).addDays(-1);
                row.End_Date_Source__c = 'Derived';
                d.mark('Contract_End_Date', 'Derived: start ' + String.valueOf(startD) + ' + '
                    + m.intValue() + ' months - 1 day.');
            } else if (row.Contract_Length_Days__c != null && row.Contract_Length_Days__c > 0) {
                Integer days = row.Contract_Length_Days__c.intValue();
                row.Contract_End_Date__c = startD.addDays(days - 1);
                row.End_Date_Source__c = 'Derived';
                d.mark('Contract_End_Date', 'Derived: start ' + String.valueOf(startD) + ' + '
                    + days + ' days - 1 day.');
            }
        }

        if (row.Contract_Length_Months__c == null && row.Contract_End_Date__c != null
                && row.Contract_End_Date__c >= startD) {
            row.Contract_Length_Months__c = termMonths(startD, row.Contract_End_Date__c);
            d.mark('Contract_Length_Months', 'Derived from ' + String.valueOf(startD) + ' to '
                + String.valueOf(row.Contract_End_Date__c) + ' (inclusive).');
        }
    }

    // Whole months when the inclusive term is month-aligned (a 366-day leap-year
    // term still reads 12); otherwise days x 12 / 365.25, snapped to the whole
    // month when within 0.1 so a paper that is off by a day doesn't read 11.97.
    @TestVisible
    private static Decimal termMonths(Date startD, Date endD) {
        Date after = endD.addDays(1);
        Integer k = startD.monthsBetween(after);
        if (k > 0 && startD.addMonths(k) == after) return k;
        Decimal f = (Decimal.valueOf(startD.daysBetween(endD) + 1) * 12).divide(365.25, 6, RoundingMode.HALF_UP);
        Decimal whole = f.setScale(0, RoundingMode.HALF_UP);
        return (whole >= 1 && (f - whole).abs() <= 0.1) ? whole : f.setScale(2, RoundingMode.HALF_UP);
    }

    // Annualised ARR, amendment increments / resulting totals, credits per year
    // and the effective credit rate.
    private static void computeEconomics(Order_Form_Extraction__c row, Map<String, Object> extracted,
                                         Opportunity parentOpp, Derivations d) {
        // Reset everything computed below so an in-place refresh never keeps a
        // stale value from the previous extraction.
        row.Annual_Recurring_Revenue__c = null;
        row.Incremental_ARR__c = null;
        row.Base_ARR__c = null;
        row.Resulting_ARR__c = null;
        row.Resulting_Seats__c = null;
        row.Credits_Added__c = null;
        row.Credits_Per_Year__c = null;

        Boolean isAmend = AMEND_TYPES.contains(row.Type__c);
        Boolean isDownsell = row.Type__c == 'Downsell';
        Decimal months = row.Contract_Length_Months__c;
        String basis = row.Value_Basis__c;

        // Recurring fees as written: the whole contract after this paper and/or
        // (amendments) just the change it prices. Both in the paper's Value_Basis.
        Decimal totalStated = toDecimal(extracted.get('Recurring_Fees_Stated'));
        Decimal incStated = toDecimal(extracted.get('Incremental_Recurring_Fees'));
        String totalHow = null;
        if (totalStated == null && incStated == null) {
            if (row.License_Fees__c != null || row.Platform_Connection_Fee__c != null) {
                totalStated = nz(row.License_Fees__c) + nz(row.Platform_Connection_Fee__c);
                totalHow = 'License_Fees ' + nz(row.License_Fees__c) + ' + Hosting Fee ' + nz(row.Platform_Connection_Fee__c);
            } else if (extracted.get('Annual_Recurring_Revenue') != null) {
                // Older prompt: an already-annual figure for the whole contract.
                totalStated = toDecimal(extracted.get('Annual_Recurring_Revenue'));
                basis = 'Annual';
            }
        }
        Decimal feeFactor = annualFactor(basis, months);
        Decimal totalAnnual = annualiseFee(totalStated, basis, months);
        Decimal incAnnual = annualiseFee(incStated, basis, months);
        String termNote = (basis == 'Term' && months != null)
            ? ' stated for the ' + months + '-month term, x 12/' + months : '';

        Contract gov = isAmend ? loadGoverningContract(parentOpp) : null;

        if (!isAmend) {
            row.Annual_Recurring_Revenue__c = totalAnnual;
            if (totalAnnual != null && (totalHow != null || basis == 'Term')) {
                d.mark('Annual_Recurring_Revenue', (totalHow != null ? totalHow : String.valueOf(totalStated))
                    + termNote + ' = ' + totalAnnual + ' per year.');
            }
            computeIncrementalARR(row, parentOpp);
        } else {
            Baseline base = resolveAmendmentBaseline(row, parentOpp, gov, totalAnnual,
                row.Seat_Licenses__c, row.Credits_Purchased__c);
            Decimal baseArr = base.arr;
            String baseSrc = base.arrSource;
            Decimal inc = incAnnual;
            if (inc != null && isDownsell && inc > 0) inc = -inc;
            if (inc != null && basis == 'Term') {
                d.mark('Incremental_ARR', incStated + termNote + ' = ' + inc + ' per year.');
            }
            if (totalAnnual != null) {
                row.Resulting_ARR__c = totalAnnual;
                row.Annual_Recurring_Revenue__c = totalAnnual;
                if (totalHow != null || basis == 'Term') {
                    d.mark('Resulting_ARR', (totalHow != null ? totalHow : String.valueOf(totalStated))
                        + termNote + ' = ' + totalAnnual + ' per year.');
                }
                if (inc == null && baseArr != null) {
                    inc = totalAnnual - baseArr;
                    row.Base_ARR__c = baseArr;
                    d.mark('Incremental_ARR', 'Paper restates contract ARR ' + totalAnnual + '; minus '
                        + baseSrc + ' ' + baseArr + ' = ' + inc + '.');
                }
            } else if (inc != null && baseArr != null) {
                row.Base_ARR__c = baseArr;
                row.Resulting_ARR__c = baseArr + inc;
                row.Annual_Recurring_Revenue__c = row.Resulting_ARR__c;
                d.mark('Resulting_ARR', baseSrc + ' ' + baseArr + ' + incremental ' + inc + ' = '
                    + row.Resulting_ARR__c + '.');
            }
            row.Incremental_ARR__c = inc;

            // Seats: Seat_Licenses is the stated TOTAL after the change, Seats_Added the stated change.
            Decimal added = row.Seats_Added__c;
            if (added != null && isDownsell && added > 0) { added = -added; row.Seats_Added__c = added; }
            Decimal baseSeats = base.seats;
            if (row.Seat_Licenses__c != null) {
                row.Resulting_Seats__c = row.Seat_Licenses__c;
                if (added == null && baseSeats != null) {
                    row.Seats_Added__c = row.Seat_Licenses__c - baseSeats;
                    d.mark('Seats_Added', 'Paper states ' + row.Seat_Licenses__c + ' seats in total; minus '
                        + base.seatsSource + ' ' + baseSeats + ' = ' + row.Seats_Added__c + '.');
                }
            } else if (added != null && baseSeats != null) {
                row.Resulting_Seats__c = baseSeats + added;
                d.mark('Resulting_Seats', base.seatsSource + ' ' + baseSeats + ' + ' + added
                    + ' added = ' + row.Resulting_Seats__c + '.');
            }

            // Credits: Credits_Purchased is the stated TOTAL, Credits_Added the stated change.
            Decimal cAdded = toDecimal(extracted.get('Credits_Added'));
            if (cAdded != null && isDownsell && cAdded > 0) cAdded = -cAdded;
            Decimal baseCredits = base.credits;
            if (cAdded == null && row.Credits_Purchased__c != null && baseCredits != null) {
                cAdded = row.Credits_Purchased__c - baseCredits;
                d.mark('Credits_Added', 'Paper states ' + row.Credits_Purchased__c + ' credits in total; minus '
                    + base.creditsSource + ' ' + baseCredits + ' = ' + cAdded + '.');
            }
            row.Credits_Added__c = cAdded;
        }

        // Credits per year (the contract's allocation; null when only an increment is priced).
        Decimal creditFac = creditFactor(row.Credits_Period__c, months);
        row.Credits_Per_Year__c = creditsPerYear(row.Credits_Purchased__c, row.Credits_Period__c, months);
        if (row.Credits_Per_Year__c != null) {
            if (row.Credits_Period__c != 'year') {
                d.mark('Credits_Per_Year', row.Credits_Purchased__c + ' credits per ' + row.Credits_Period__c
                    + (row.Credits_Period__c == 'contract' ? ' (' + months + '-month term)' : '')
                    + ' = ' + row.Credits_Per_Year__c + ' per year.');
            }
        }

        // Effective committed price per credit, when the paper doesn't state one.
        if (row.Credit_Rate__c == null) {
            Decimal fee = (row.License_Fees__c != null) ? row.License_Fees__c : totalStated;
            Decimal credits = row.Credits_Purchased__c;
            String period = row.Credits_Period__c;
            if (credits == null && incStated != null && extracted.get('Credits_Added') != null) {
                fee = incStated;                                       // increment-only paper
                credits = toDecimal(extracted.get('Credits_Added'));
            }
            Boolean bothTerm = basis == 'Term' && period == 'contract';
            Decimal rate = creditRate(fee, feeFactor, credits, creditFac, bothTerm);
            if (rate != null) {
                row.Credit_Rate__c = rate;
                d.mark('Credit_Rate', 'Derived: committed fee ' + fee + ' (' + (basis == null ? 'Annual' : basis)
                    + ') / ' + credits + ' credits (' + period + ') = ' + rate + ' per credit.');
            }
        }
    }

    @TestVisible
    private static Decimal creditRate(Decimal fee, Decimal feeFactor, Decimal credits,
                                      Decimal creditFactor, Boolean bothTerm) {
        if (fee == null || credits == null || fee <= 0 || credits <= 0) return null;
        if (feeFactor != null && creditFactor != null) {
            return (fee * feeFactor).divide(credits * creditFactor, 6, RoundingMode.HALF_UP);
        }
        // Both figures cover the same whole term but its length is unknown - the
        // ratio is basis-invariant, so divide directly.
        if (bothTerm) return fee.divide(credits, 6, RoundingMode.HALF_UP);
        return null;
    }

    // Annual figures pass through; Term figures scale by 12 / term months (null
    // when the term length is unknown). A missing basis is treated as annual.
    @TestVisible
    private static Decimal annualFactor(String basis, Decimal months) {
        if (basis != 'Term') return 1;
        if (months == null || months <= 0) return null;
        return Decimal.valueOf(12).divide(months, 10, RoundingMode.HALF_UP);
    }

    @TestVisible
    private static Decimal creditFactor(String period, Decimal months) {
        if (period == 'year') return 1;
        if (period == 'month') return 12;
        if (period == 'quarter') return 4;
        if (period == 'contract') {
            return (months == null || months <= 0) ? null : Decimal.valueOf(12).divide(months, 10, RoundingMode.HALF_UP);
        }
        return null;
    }

    // Exact annualisation (value x 12 / months, rounded once) rather than
    // multiplying by a pre-rounded 12/months factor, which can land a cent off.
    @TestVisible
    private static Decimal annualiseFee(Decimal v, String basis, Decimal months) {
        if (v == null) return null;
        if (basis != 'Term') return v;
        if (months == null || months <= 0) return null;
        return (v * 12).divide(months, 2, RoundingMode.HALF_UP);
    }

    @TestVisible
    private static Decimal creditsPerYear(Decimal credits, String period, Decimal months) {
        if (credits == null) return null;
        if (period == 'year') return credits;
        if (period == 'month') return credits * 12;
        if (period == 'quarter') return credits * 4;
        if (period == 'contract' && months != null && months > 0) {
            return (credits * 12).divide(months, 2, RoundingMode.HALF_UP);
        }
        return null;
    }

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    private static String asStr(Object v) { return v == null ? null : String.valueOf(v); }

    // The contract an amendment changes: the base deal's contract, else this
    // opp's own. Deliberately no account fallback - a wrong contract would yield
    // wrong increments (see the applier's BlackRock case).
    @TestVisible
    private static Contract loadGoverningContract(Opportunity parentOpp) {
        if (parentOpp == null) return null;
        Id cid = (parentOpp.Base_Opportunity__r != null && parentOpp.Base_Opportunity__r.ContractId != null)
            ? parentOpp.Base_Opportunity__r.ContractId : parentOpp.ContractId;
        if (cid == null) return null;
        List<Contract> cs = [
            SELECT Id, ContractNumber, ARR__c, Seat_Licenses__c, Total_Credits_Purchased__c
            FROM Contract WHERE Id = :cid LIMIT 1
        ];
        return cs.isEmpty() ? null : cs[0];
    }

    // The governing contract's position BEFORE this amendment. Live Contract
    // fields are not a safe baseline on their own: flows roll a closed deal into
    // Contract.ARR__c and the applier adds an applied amendment's credits into
    // Total_Credits_Purchased__c, so a refresh would compute an increment of 0.
    //  1. Prior paper: the contract's current Success extractions for deals that
    //     closed before this one (the base deal and earlier amendments), never this
    //     deal's own rows. ARR / seats = the most recent prior figure; credits = the
    //     same signed running sum the applier keeps.
    //  2. Otherwise the live Contract ARR / seats - unless the value already equals
    //     the total this paper states (it already includes this deal).
    //  3. ARR only: the base opportunity's ARR.
    private class Baseline {
        Decimal arr;
        String arrSource;
        Decimal seats;
        String seatsSource;
        Decimal credits;
        String creditsSource;
    }

    private static Baseline resolveAmendmentBaseline(Order_Form_Extraction__c row, Opportunity parentOpp,
            Contract gov, Decimal statedArr, Decimal statedSeats, Decimal statedCredits) {
        Baseline b = new Baseline();
        Set<Id> govIds = new Set<Id>();
        if (gov != null) govIds.add(gov.Id);
        Set<Id> baseIds = new Set<Id>();
        if (parentOpp != null && parentOpp.Base_Opportunity__c != null) baseIds.add(parentOpp.Base_Opportunity__c);

        if (row.Opportunity__c != null && (!govIds.isEmpty() || !baseIds.isEmpty())) {
            Date myClose = (parentOpp == null) ? null : parentOpp.CloseDate;
            Datetime myCreated = (parentOpp == null) ? null : parentOpp.CreatedDate;
            Set<Id> seenOpps = new Set<Id>();
            Boolean anyCredits = false;
            Decimal creditSum = 0;
            for (Order_Form_Extraction__c p : [
                SELECT Opportunity__c, Opportunity__r.Type, Opportunity__r.CloseDate, Opportunity__r.CreatedDate,
                       Type__c, Annual_Recurring_Revenue__c, Resulting_Seats__c, Seat_Licenses__c,
                       Credits_Purchased__c, Credits_Added__c
                FROM Order_Form_Extraction__c
                WHERE Extraction_Status__c = 'Success'
                  AND Opportunity__c != :row.Opportunity__c
                  AND (Applied_Contract__c IN :govIds OR Opportunity__r.ContractId IN :govIds
                       OR Opportunity__c IN :baseIds OR Opportunity__r.Base_Opportunity__c IN :baseIds)
                ORDER BY Opportunity__r.CloseDate DESC NULLS LAST, Opportunity__r.CreatedDate DESC,
                         Is_Current__c DESC, Extracted_At__c DESC NULLS LAST
            ]) {
                if (p.Opportunity__r == null || seenOpps.contains(p.Opportunity__c)) continue;  // one row per deal: current, else latest
                seenOpps.add(p.Opportunity__c);
                if (!closedBefore(p.Opportunity__r, myClose, myCreated)) continue;
                String what = 'prior paper (' + (p.Opportunity__r.Type == null ? 'deal' : p.Opportunity__r.Type)
                    + ' closed ' + String.valueOf(p.Opportunity__r.CloseDate) + ')';
                if (b.arr == null && p.Annual_Recurring_Revenue__c != null) {
                    b.arr = p.Annual_Recurring_Revenue__c;
                    b.arrSource = what + ' ARR';
                }
                Decimal seats = (p.Resulting_Seats__c != null) ? p.Resulting_Seats__c : p.Seat_Licenses__c;
                if (b.seats == null && seats != null) {
                    b.seats = seats;
                    b.seatsSource = what + ' seats';
                }
                String t = (p.Opportunity__r.Type != null) ? p.Opportunity__r.Type : p.Type__c;
                Decimal contribution = (AMEND_TYPES.contains(t) && p.Credits_Added__c != null)
                    ? p.Credits_Added__c
                    : (p.Credits_Purchased__c == null ? null : (t == 'Downsell' ? -p.Credits_Purchased__c : p.Credits_Purchased__c));
                if (contribution != null) { creditSum += contribution; anyCredits = true; }
            }
            if (anyCredits) {
                b.credits = creditSum;
                b.creditsSource = 'credits on the contract\'s prior paper';
            }
        }

        String govName = (gov == null) ? null : 'governing Contract ' + gov.ContractNumber;
        if (b.arr == null && gov != null && gov.ARR__c != null && gov.ARR__c != statedArr) {
            b.arr = gov.ARR__c;
            b.arrSource = govName + ' ARR__c';
        }
        if (b.seats == null && gov != null && gov.Seat_Licenses__c != null && gov.Seat_Licenses__c != statedSeats) {
            b.seats = gov.Seat_Licenses__c;
            b.seatsSource = govName + ' Seat_Licenses__c';
        }
        if (b.arr == null && parentOpp != null && parentOpp.Base_Opportunity__r != null
                && parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c != null) {
            b.arr = parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c;
            b.arrSource = 'base opportunity ARR';
        }
        return b;
    }

    // Did that deal close before this one? Same-day deals order by creation.
    private static Boolean closedBefore(Opportunity other, Date myClose, Datetime myCreated) {
        if (other == null || myClose == null || other.CloseDate == null) return true;
        if (other.CloseDate != myClose) return other.CloseDate < myClose;
        return myCreated == null || other.CreatedDate == null || other.CreatedDate < myCreated;
    }

    private class BaseValue {
        Decimal value;
        String source;
        BaseValue(Decimal value, String source) { this.value = value; this.source = source; }
    }

    // Prior ARR when there is no governing contract value: the base opp's current
    // Success extraction, else the base opp's ARR, else (renewals) this opp's own
    // ARR - unless it already equals the new total (set by another process).
    private static BaseValue resolveBaseArr(Opportunity parentOpp, Decimal totalARR) {
        if (parentOpp == null) return new BaseValue(null, null);
        if (parentOpp.Base_Opportunity__c != null) {
            List<Order_Form_Extraction__c> baseRows = [
                SELECT Annual_Recurring_Revenue__c
                FROM Order_Form_Extraction__c
                WHERE Opportunity__c = :parentOpp.Base_Opportunity__c
                  AND Extraction_Status__c = 'Success'
                  AND Annual_Recurring_Revenue__c != null
                ORDER BY Is_Current__c DESC, CreatedDate DESC
                LIMIT 1
            ];
            if (!baseRows.isEmpty()) {
                return new BaseValue(baseRows[0].Annual_Recurring_Revenue__c, 'base opportunity extraction ARR');
            }
            if (parentOpp.Base_Opportunity__r != null && parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c != null) {
                return new BaseValue(parentOpp.Base_Opportunity__r.Annual_Recurring_Revenue__c, 'base opportunity ARR');
            }
        }
        if (parentOpp.Annual_Recurring_Revenue__c != null && parentOpp.Annual_Recurring_Revenue__c != totalARR) {
            return new BaseValue(parentOpp.Annual_Recurring_Revenue__c, 'opportunity ARR');
        }
        return new BaseValue(null, null);
    }

    // Non-amendment rows: New Business / Pilot -> incremental = total; Renewal ->
    // total minus the prior ARR.
    @TestVisible
    private static void computeIncrementalARR(Order_Form_Extraction__c row, Opportunity parentOpp) {
        Decimal totalARR = row.Annual_Recurring_Revenue__c;
        if (totalARR == null) return;
        if (row.Type__c != 'Renewal') {
            row.Incremental_ARR__c = totalARR;
            return;
        }
        BaseValue b = resolveBaseArr(parentOpp, totalARR);
        if (b.value == null) return;
        row.Base_ARR__c = b.value;
        row.Incremental_ARR__c = totalARR - b.value;
    }

    // An out-of-range number fails the whole DML (and, in a batch, the whole
    // chunk). Clamp every numeric field to its precision instead, keep the row,
    // and record the raw value in the evidence.
    private static Map<String, Schema.SObjectField> ofeFieldMap;
    private static void clampToFieldLimits(Order_Form_Extraction__c row, Derivations d) {
        if (ofeFieldMap == null) ofeFieldMap = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap();
        Map<String, Object> populated = row.getPopulatedFieldsAsMap();
        for (String f : populated.keySet()) {
            Object v = populated.get(f);
            if (!(v instanceof Decimal)) continue;
            Schema.SObjectField sf = ofeFieldMap.get(f.toLowerCase());
            if (sf == null) continue;
            Schema.DescribeFieldResult dr = sf.getDescribe();
            Schema.DisplayType t = dr.getType();
            if (t != Schema.DisplayType.DOUBLE && t != Schema.DisplayType.CURRENCY
                    && t != Schema.DisplayType.PERCENT && t != Schema.DisplayType.INTEGER) continue;
            Decimal max = maxForPrecision(dr.getPrecision(), dr.getScale());
            if (max == null) continue;
            Decimal dv = (Decimal) v;
            if (dv.abs() > max) {
                Decimal clamped = dv < 0 ? -max : max;
                row.put(f, clamped);
                d.clamped(f.removeEnd('__c'), dv, clamped);
            }
        }
    }

    @TestVisible
    private static Decimal maxForPrecision(Integer precision, Integer scale) {
        if (precision == null || precision <= 0) return null;
        Integer s = (scale == null) ? 0 : scale;
        String intPart = (precision - s > 0) ? '9'.repeat(precision - s) : '0';
        return Decimal.valueOf(intPart + (s > 0 ? '.' + '9'.repeat(s) : ''));
    }

    // Collects what Apex computed or clamped, merged into the model's evidence:
    // each entry may gain a "derived" or "clamped" key. Untouched rows keep the
    // model's evidence exactly as returned.
    private class Derivations {
        Map<String, Object> evidence = new Map<String, Object>();
        List<String> fields = new List<String>();
        Boolean touched = false;

        public Derivations(Object rawEvidence) {
            if (rawEvidence instanceof Map<String, Object>) {
                evidence = (Map<String, Object>) rawEvidence;
            } else if (rawEvidence != null && String.isNotBlank(String.valueOf(rawEvidence))) {
                evidence.put('_model_notes', String.valueOf(rawEvidence));
            }
        }

        public void mark(String field, String computation) {
            note(field, field, 'derived', computation);
        }

        public void clamped(String field, Decimal raw, Decimal stored) {
            note(field, field + '(clamped)', 'clamped',
                'Raw value ' + raw + ' exceeds the field limit; stored ' + stored + '.');
        }

        private void note(String field, String tag, String key, String text) {
            touched = true;
            if (!fields.contains(tag)) fields.add(tag);
            Object existing = evidence.get(field);
            if (existing instanceof Map<String, Object>) {
                ((Map<String, Object>) existing).put(key, text);
            } else {
                evidence.put(field, new Map<String, Object>{ 'clause' => 'Computed by extractor', key => text });
            }
        }

        public void writeTo(Order_Form_Extraction__c row) {
            row.Derived_Fields__c = null;
            if (!touched) return;
            row.Extract_Evidence__c = OrderFormExtractionJob.truncate(JSON.serialize(evidence), 32768);
            row.Derived_Fields__c = OrderFormExtractionJob.truncate(String.join(fields, ';'), 255);
        }
    }

    // The "model" field of a Messages API response envelope, if present.
    @TestVisible
    private static String responseModel(String responseBody) {
        try {
            Object env = JSON.deserializeUntyped(responseBody);
            if (env instanceof Map<String, Object>) return asStr(((Map<String, Object>) env).get('model'));
        } catch (Exception e) {
            return null;
        }
        return null;
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

    // Accepts Object, not just String: the model occasionally returns a free-text
    // field (e.g. Subprocessor_Restrictions) as a JSON object/array instead of a
    // string, and a raw (String) cast on that throws "Invalid conversion from
    // Map<String,ANY> to String", failing the whole row. Stringify non-strings so
    // the value is preserved (as JSON) rather than lost.
    private static String truncate(Object raw, Integer maxLen) {
        if (raw == null) return null;
        String s = (raw instanceof String) ? (String) raw : JSON.serialize(raw);
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }

    // Email-typed fields (Primary/Billing/Requested_By contact email) reject any
    // value that isn't a single valid address on upsert - and the model
    // sometimes returns two addresses in one value ("a@x.com / b@x.com"), which
    // failed the whole row with INVALID_EMAIL_ADDRESS. Return the FIRST
    // syntactically valid address, or null - never a malformed string. An
    // address longer than the 80-char Email limit is dropped (truncating an
    // email just produces another invalid one).
    private static final Pattern EMAIL_PATTERN =
        Pattern.compile('[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}');
    @TestVisible
    private static String sanitizeEmail(Object raw) {
        if (raw == null) return null;
        String s = String.valueOf(raw);
        if (String.isBlank(s)) return null;
        Matcher m = EMAIL_PATTERN.matcher(s);
        if (m.find()) {
            String email = m.group();
            return email.length() > 80 ? null : email;
        }
        return null;
    }

    public class OrderFormException extends Exception {}
}
