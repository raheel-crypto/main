/**
 * Source-based review of a saved Order_Form_Extraction__c (one pass).
 *
 * A separate model request through the same Anthropic named credential as
 * extraction. It receives the deal's original files with the extractor's
 * CURRENT DEAL / PARENT CONTEXT labels, the extraction prompt as the field
 * definitions, the permitted picklist values, the raw extraction, the product
 * lines, the calculated values and their provenance, the proposed Salesforce
 * payload, the deterministic checks (OrderFormValidator) and the required
 * coverage (OrderFormReviewCoverage). It answers with schema-constrained JSON
 * (output_config.format), which Apex validates again.
 *
 * Shadow mode: the result is an Order_Form_Review__c with its findings. Nothing
 * on the extraction, its product lines, the Opportunity or the Contract is
 * changed - a person accepts or dismisses each finding.
 *
 * The review runs after the extraction is saved (the extraction's own callout
 * can use most of a transaction's 120 seconds), on that saved version: the
 * review stores the hashes of the values, files and prompts it saw and is marked
 * stale when any of them changes (OrderFormReviewStaleness).
 *
 * Status (independent of Extraction_Status__c):
 *   Failed     - no usable review: no file sent, HTTP error, timeout, refusal,
 *                cut-off or malformed reply. Never clear.
 *   Incomplete - a required source was missing or unreadable, or required
 *                fields / product lines were not reviewed.
 *   Findings   - the reviewer reported findings, or a deterministic check failed.
 *   Clear      - none of the above. Model confidence plays no part.
 */
public with sharing class OrderFormReviewer {

    public static final String PROMPT_RESOURCE = 'OrderFormReviewPrompt';
    public static final String FALLBACK_BETA = 'server-side-fallback-2026-07-01';
    @TestVisible private static final Integer RAW_LIMIT = 131072;
    @TestVisible private static final Integer LONG_TEXT = 32768;
    // Tests set this instead of relying on the deployed Default record.
    @TestVisible private static Order_Form_Review_Setting__mdt settingsOverride;

    public static final List<String> STAGES = new List<String>{
        'source_selection', 'extraction', 'calculation', 'mapping', 'persistence'
    };
    public static final List<String> CATEGORIES = new List<String>{
        'wrong_value', 'missing_value', 'unsupported_value', 'unsupported_provenance', 'wrong_source', 'source_conflict',
        'enum_gap', 'calculation_error', 'scope_error', 'commitment_classification', 'double_counting',
        'invented_split', 'truncation', 'identifier_mismatch', 'evidence_error', 'missing_referenced_terms',
        'document_component_missed', 'legal_interpretation', 'other'
    };
    public static final List<String> ACTIONS = new List<String>{ 'none', 'set_value', 'clear_value', 'unresolved' };
    public static final List<String> SEVERITIES = new List<String>{ 'high', 'medium', 'low' };
    public static final List<String> ROLES = new List<String>{ 'governing', 'context', 'superseded', 'not_part_of_agreement' };
    public static final List<String> DOC_CLASSES = new List<String>{ 'Order Form', 'MSA', 'MNDA', 'DPA', 'Other' };
    private static final Pattern PRODUCT_REF = Pattern.compile('^L(\\d{1,4}):(.+)$');

    public class Outcome {
        public Id extractionId;
        public Order_Form_Review__c review;
        public List<Order_Form_Review_Finding__c> findings = new List<Order_Form_Review_Finding__c>();
        public String skipped;
        // The current review found stale (files / prompts changed); saved with it.
        public Order_Form_Review__c staleCurrent;
    }

    // ===================================================================
    // Settings

    public static Order_Form_Review_Setting__mdt settings() {
        if (settingsOverride != null) return settingsOverride;
        Order_Form_Review_Setting__mdt s = Order_Form_Review_Setting__mdt.getInstance('Default');
        return s != null ? s : new Order_Form_Review_Setting__mdt(Mode__c = 'Off');
    }

    public static Boolean isOn() {
        return settings().Mode__c == 'Shadow';
    }

    // ===================================================================
    // Entry points

    /** Review and save in one go (a queueable / batch execute: the callout runs before any DML). */
    public static Outcome reviewAndSave(Id extractionId, Boolean force) {
        Outcome o = review(extractionId, force);
        save(o);
        return o;
    }

    /**
     * Review one extraction: queries and the model callout, no DML. Skips (no
     * callout) when the reviewer is off, the current review is already up to date
     * with the same values, files and prompts, or this version has used its
     * attempts - unless force.
     */
    public static Outcome review(Id extractionId, Boolean force) {
        Outcome o = new Outcome();
        o.extractionId = extractionId;
        Order_Form_Review_Setting__mdt s = settings();
        if (s.Mode__c != 'Shadow') {
            o.skipped = 'The reviewer is off (Order Form Review Setting "Default", Mode = ' + s.Mode__c + ').';
            return o;
        }
        Order_Form_Extraction__c row = loadRow(extractionId);
        if (row == null) {
            o.skipped = 'Extraction not found.';
            return o;
        }

        List<OrderFormLines.Line> lines = OrderFormLines.fromJson(row.Line_Items__c);
        Map<String, Object> raw = rawOf(row);
        List<String> sourceNotes = new List<String>();
        List<Id> docIds = docIdsOf(row, sourceNotes);
        String inHash = inputHash(row);
        String srcHash = sourceHash(docIds);
        String reviewerPrompt = reviewPrompt();
        String definitions = OrderFormExtractionJob.extractionPrompt();
        List<String> schemaKeys = OrderFormExtractionJob.promptSchemaKeys();
        Map<String, Object> replySchema = responseSchema(OrderFormReviewCoverage.allowedFields(schemaKeys));
        String promptHash = promptVersion(reviewerPrompt, definitions, replySchema, s);

        List<Order_Form_Review__c> history = [
            SELECT Id, Is_Current__c, Is_Stale__c, Status__c, Input_Hash__c, Source_Hash__c, Prompt_Version__c
            FROM Order_Form_Review__c WHERE Extraction__c = :extractionId ORDER BY CreatedDate DESC
        ];
        Integer attempts = 0;
        Order_Form_Review__c current;
        for (Order_Form_Review__c h : history) {
            if (h.Is_Current__c == true && current == null) current = h;
            if (h.Input_Hash__c == inHash && h.Source_Hash__c == srcHash) attempts++;
        }
        if (force != true && current != null && current.Is_Stale__c != true && current.Status__c != 'Failed'
                && current.Input_Hash__c == inHash && current.Source_Hash__c == srcHash
                && current.Prompt_Version__c == promptHash) {
            o.skipped = 'Up to date: the current review saw these exact values, files and prompts.';
            return o;
        }
        // Files or prompts changed since the current review (the trigger catches value changes).
        if (current != null && current.Is_Stale__c != true) {
            if (current.Input_Hash__c != inHash) {
                current.Is_Stale__c = true;
                current.Stale_Reason__c = 'Extraction values changed after the review.';
                o.staleCurrent = current;
            } else if (OrderFormReviewStaleness.recheck(current, srcHash, promptHash) != null) {
                o.staleCurrent = current;
            }
        }
        Integer maxAttempts = s.Max_Attempts__c == null ? 2 : s.Max_Attempts__c.intValue();
        if (force != true && attempts >= maxAttempts) {
            o.skipped = 'This version has been reviewed ' + attempts + ' time(s) (Max Attempts ' + maxAttempts
                + '); run it with force to try again.';
            return o;
        }

        // Deterministic checks first: they go to the reviewer as input.
        Order_Form_Extraction__c proposed = rebuild(row, docIds);
        OrderFormValidator.Result checks = OrderFormValidator.validate(row, lines, raw, proposed);

        List<String> requiredFields = OrderFormReviewCoverage.requiredFields(row);
        List<String> requiredProducts = OrderFormReviewCoverage.requiredProducts(lines);

        Order_Form_Review__c rev = new Order_Form_Review__c(
            Extraction__c = extractionId,
            Mode__c = 'Shadow',
            Model__c = s.Model__c,
            Effort__c = s.Effort__c,
            Input_Hash__c = inHash,
            Source_Hash__c = srcHash,
            Prompt_Version__c = promptHash,
            Reviewed_At__c = System.now(),
            Attempt__c = attempts + 1,
            Check_Status__c = checks.status,
            Checks__c = truncate(JSON.serialize(checks.checks), RAW_LIMIT),
            Is_Stale__c = false
        );
        o.review = rev;

        Map<String, Object> shell = new Map<String, Object>{
            'model' => s.Model__c,
            'max_tokens' => s.Max_Tokens__c == null ? 16000 : s.Max_Tokens__c.intValue(),
            'system' => new List<Object>{
                new Map<String, Object>{ 'type' => 'text', 'text' => reviewerPrompt },
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => 'FIELD DEFINITIONS - the extractor\'s instructions, quoted for reference:\n\n' + definitions,
                    'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' }
                }
            },
            'output_config' => outputConfig(s, replySchema)
        };
        if (s.Use_Fallbacks__c == true) shell.put('fallbacks', 'default');
        // Rogo's online Terms & Conditions (fetched live), which most order forms incorporate by link.
        RogoStandardTerms.Terms terms = RogoStandardTerms.get();
        if (terms.promptBlock() != null) {
            ((List<Object>) shell.get('system')).add(new Map<String, Object>{
                'type' => 'text', 'text' => terms.promptBlock(),
                'cache_control' => new Map<String, Object>{ 'type' => 'ephemeral' } });
        }

        List<Object> blocks = inputBlocks(row, lines, raw, checks, requiredFields, requiredProducts);
        OrderFormExtractionJob.SourceRequest req;
        try {
            req = OrderFormExtractionJob.buildSourceRequest(row.Opportunity__c, docIds, shell, blocks,
                'Review the extraction above against the files. Return the findings, coverage, sources reviewed, gaps '
                + 'and summary.');
        } catch (Exception e) {
            return failed(o, checks, 'exception', 'The request could not be built: ' + e.getMessage());
        }
        List<String> sent = new List<String>(req.sentLabels);
        for (String sk : req.skipped) sent.add('NOT SENT: ' + sk);
        sent.addAll(sourceNotes);
        if (terms.sourceLine() != null) sent.add(terms.sourceLine());
        rev.Sources_Sent__c = truncate(String.join(sent, '\n'), LONG_TEXT);

        List<String> missing = OrderFormReviewCoverage.missingSources(row, req,
            row.Opportunity__r != null && row.Opportunity__r.Base_Opportunity__c != null);
        if (req.body == null) {
            rev.Missing_Required_Sources__c = truncate(String.join(missing, '\n'), LONG_TEXT);
            return failed(o, checks, 'no_files', 'No document could be sent to the reviewer.');
        }

        // ----- the model request -----
        HttpResponse resp;
        Long started = System.currentTimeMillis();
        try {
            resp = OrderFormExtractionJob.callAnthropic(req.body, s.Use_Fallbacks__c == true ? FALLBACK_BETA : null,
                (s.Timeout_Ms__c == null ? 120000 : s.Timeout_Ms__c.intValue()) - RogoStandardTerms.spentMs());
        } catch (Exception e) {
            rev.Latency_Ms__c = System.currentTimeMillis() - started;
            rev.Missing_Required_Sources__c = truncate(String.join(missing, '\n'), LONG_TEXT);
            String msg = e.getMessage() == null ? '' : e.getMessage();
            return failed(o, checks, msg.toLowerCase().contains('timed out') ? 'timeout' : 'exception',
                'The model request did not complete: ' + msg);
        }
        rev.Latency_Ms__c = System.currentTimeMillis() - started;
        rev.HTTP_Status__c = resp.getStatusCode();
        String body = resp.getBody();
        rev.Raw_Response__c = truncate(body, RAW_LIMIT);
        if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
            rev.Missing_Required_Sources__c = truncate(String.join(missing, '\n'), LONG_TEXT);
            return failed(o, checks, 'http_' + resp.getStatusCode(), 'HTTP ' + resp.getStatusCode() + ': '
                + truncate(body, 2000));
        }

        Map<String, Object> envelope;
        try {
            envelope = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            return failed(o, checks, 'malformed', 'The reply is not JSON: ' + e.getMessage());
        }
        recordUsage(rev, envelope, s);
        String stop = envelope.get('stop_reason') == null ? null : String.valueOf(envelope.get('stop_reason'));
        rev.Stop_Reason__c = stop;
        if (stop == 'refusal') return failed(o, checks, stop, 'The model declined the review (stop_reason refusal).');
        if (stop == 'max_tokens') {
            return failed(o, checks, stop, 'The reply was cut off at max_tokens (' + shell.get('max_tokens') + ').');
        }

        Map<String, Object> reply;
        try {
            reply = (Map<String, Object>) JSON.deserializeUntyped(replyText(envelope));
        } catch (Exception e) {
            return failed(o, checks, 'malformed', 'The reply text is not a JSON object: ' + e.getMessage());
        }
        List<String> problems = validateReply(reply, new Set<String>(OrderFormReviewCoverage.allowedFields(schemaKeys)));
        if (!problems.isEmpty()) {
            return failed(o, checks, 'malformed', 'The reply does not match the review schema: '
                + String.join(problems, '; '));
        }

        // ----- findings, coverage, status -----
        Map<String, Object> coverage = (Map<String, Object>) reply.get('coverage');
        Set<String> verified = strings(coverage.get('verified'));
        Set<String> notInSources = strings(coverage.get('not_in_sources'));
        Set<String> notReviewed = strings(coverage.get('not_reviewed'));
        Set<String> withFinding = new Set<String>();
        for (Object fo : (List<Object>) reply.get('findings')) {
            Map<String, Object> f = (Map<String, Object>) fo;
            String field = str(f.get('field'));
            String ref = str(f.get('product_ref'));
            if (String.isNotBlank(field)) withFinding.add(field);
            if (String.isNotBlank(ref)) withFinding.add(ref);
            o.findings.add(modelFinding(f, row, lines));
        }
        for (OrderFormValidator.Check c : checks.problems()) o.findings.add(checkFinding(c, row));

        for (Object so : (List<Object>) reply.get('sources_reviewed')) {
            Map<String, Object> src = (Map<String, Object>) so;
            if (src.get('readable') instanceof Boolean && !((Boolean) src.get('readable'))) {
                missing.add('The reviewer could not read ' + str(src.get('file')) + '.');
            }
        }
        List<String> unreviewed = new List<String>();
        List<String> required = new List<String>(requiredFields);
        required.addAll(requiredProducts);
        for (String item : required) {
            Boolean covered = !notReviewed.contains(item)
                && (verified.contains(item) || notInSources.contains(item) || withFinding.contains(item));
            if (!covered) unreviewed.add(item);
        }

        Integer modelFindings = ((List<Object>) reply.get('findings')).size();
        rev.Findings_Count__c = o.findings.size();
        rev.Missing_Required_Sources__c = missing.isEmpty() ? null : truncate(String.join(missing, '\n'), LONG_TEXT);
        rev.Unreviewed_Required_Fields__c = unreviewed.isEmpty() ? null : truncate(String.join(unreviewed, '\n'), LONG_TEXT);
        rev.Coverage__c = truncate(JSON.serialize(new Map<String, Object>{
            'required_fields' => requiredFields,
            'required_products' => requiredProducts,
            'verified' => sorted(verified),
            'not_in_sources' => sorted(notInSources),
            'not_reviewed' => sorted(notReviewed),
            'with_findings' => sorted(withFinding),
            'unreviewed_required' => unreviewed,
            'missing_required_sources' => missing,
            'sources_reviewed' => reply.get('sources_reviewed')
        }), RAW_LIMIT);
        List<String> summary = new List<String>{ str(reply.get('summary')) };
        List<Object> gaps = (List<Object>) reply.get('gaps');
        if (!gaps.isEmpty()) {
            summary.add('Gaps:');
            for (Object g : gaps) summary.add('- ' + String.valueOf(g));
        }
        rev.Summary__c = truncate(String.join(summary, '\n'), LONG_TEXT);
        rev.Status__c = statusFor(false, missing, unreviewed, modelFindings, checks);
        return o;
    }

    /**
     * The review's status from its checks, coverage and findings. Clear needs a
     * completed review, every required source and item covered, no findings and
     * no failed check. Warnings alone do not block Clear.
     */
    @TestVisible
    private static String statusFor(Boolean failedReview, List<String> missingSources, List<String> unreviewed,
                                    Integer modelFindings, OrderFormValidator.Result checks) {
        if (failedReview) return 'Failed';
        if (!missingSources.isEmpty() || !unreviewed.isEmpty()) return 'Incomplete';
        if (modelFindings > 0 || checks.failures > 0) return 'Findings';
        return 'Clear';
    }

    private static Outcome failed(Outcome o, OrderFormValidator.Result checks, String stopReason, String why) {
        o.review.Status__c = 'Failed';
        if (o.review.Stop_Reason__c == null) o.review.Stop_Reason__c = stopReason == null ? null : stopReason.left(50);
        o.review.Failure__c = truncate(why, LONG_TEXT);
        // The deterministic checks still ran; keep their problems visible.
        o.findings.clear();
        for (OrderFormValidator.Check c : checks.problems()) o.findings.add(checkFinding(c, null));
        o.review.Findings_Count__c = o.findings.size();
        return o;
    }

    /**
     * Save a review: the extraction's earlier reviews stop being current, the new
     * one and its findings are inserted, and a person's Accepted / Dismissed
     * decision on an earlier finding carries over to the same finding (by
     * fingerprint). Nothing else is written.
     */
    public static void save(Outcome o) {
        if (o == null) return;
        if (o.review == null) {
            // No new review (skipped), but the current one was found stale: record that.
            if (o.staleCurrent != null) {
                update new Order_Form_Review__c(Id = o.staleCurrent.Id, Is_Stale__c = true,
                    Stale_Reason__c = o.staleCurrent.Stale_Reason__c);
            }
            return;
        }
        List<Order_Form_Review__c> prior = [
            SELECT Id, Is_Stale__c, Stale_Reason__c FROM Order_Form_Review__c
            WHERE Extraction__c = :o.extractionId AND Is_Current__c = true
        ];
        for (Order_Form_Review__c p : prior) {
            p.Is_Current__c = false;
            if (o.staleCurrent != null && p.Id == o.staleCurrent.Id) {
                p.Is_Stale__c = true;
                p.Stale_Reason__c = o.staleCurrent.Stale_Reason__c;
            }
        }
        if (!prior.isEmpty()) update prior;
        o.review.Is_Current__c = true;
        insert o.review;
        if (o.findings.isEmpty()) return;

        Map<String, Order_Form_Review_Finding__c> decided = new Map<String, Order_Form_Review_Finding__c>();
        for (Order_Form_Review_Finding__c f : [
            SELECT Fingerprint__c, Status__c, Disposition_Note__c FROM Order_Form_Review_Finding__c
            WHERE Extraction__c = :o.extractionId AND Status__c != 'Open' AND Fingerprint__c != null
            ORDER BY CreatedDate DESC
        ]) {
            if (!decided.containsKey(f.Fingerprint__c)) decided.put(f.Fingerprint__c, f);
        }
        for (Order_Form_Review_Finding__c f : o.findings) {
            f.Review__c = o.review.Id;
            f.Extraction__c = o.extractionId;
            Order_Form_Review_Finding__c earlier = decided.get(f.Fingerprint__c);
            if (earlier != null) {
                f.Status__c = earlier.Status__c;
                f.Disposition_Note__c = earlier.Disposition_Note__c;
            }
        }
        insert o.findings;
    }

    // ===================================================================
    // Inputs

    @TestVisible
    private static Order_Form_Extraction__c loadRow(Id extractionId) {
        Set<String> fields = new Set<String>{
            'Id', 'Name', 'Opportunity__c', 'Opportunity__r.Base_Opportunity__c', 'Content_Document_Id__c',
            'Extraction_Status__c', 'Document_Classes__c', 'Extracted_JSON__c', 'Raw_Response__c', 'Is_Current__c',
            'Extracted_At__c', 'Model__c'
        };
        fields.addAll(OrderFormReviewCoverage.PAYLOAD_FIELDS);
        fields.addAll(OrderFormReviewCoverage.HASH_EXTRA_FIELDS);
        List<Order_Form_Extraction__c> rows = Database.query('SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM Order_Form_Extraction__c WHERE Id = :extractionId');
        return rows.isEmpty() ? null : rows[0];
    }

    @TestVisible
    private static Map<String, Object> rawOf(Order_Form_Extraction__c row) {
        if (String.isNotBlank(row.Extracted_JSON__c)) {
            try {
                Object parsed = JSON.deserializeUntyped(row.Extracted_JSON__c);
                if (parsed instanceof Map<String, Object>) return (Map<String, Object>) parsed;
            } catch (Exception e) {
                // Cut at its field size; the stored reply below holds it whole.
            }
        }
        if (String.isNotBlank(row.Raw_Response__c)) {
            try {
                return OrderFormExtractionJob.replyJson(row.Raw_Response__c);
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    // The files the extraction read (its Content_Document_Id__c). That list is cut
    // at 255 characters; when it was, the deal's files are found again the way the
    // extractor finds them.
    @TestVisible
    private static List<Id> docIdsOf(Order_Form_Extraction__c row, List<String> notes) {
        List<Id> ids = new List<Id>();
        Boolean cut = false;
        if (String.isNotBlank(row.Content_Document_Id__c)) {
            for (String part : row.Content_Document_Id__c.split(',')) {
                String p = part.trim();
                try {
                    if (p.length() == 15 || p.length() == 18) ids.add(Id.valueOf(p));
                    else cut = true;
                } catch (Exception e) {
                    cut = true;
                }
            }
            if (row.Content_Document_Id__c.length() >= 250) cut = true;
        }
        if ((ids.isEmpty() || cut) && row.Opportunity__c != null) {
            List<Id> all = OrderFormExtractor.findAllDocuments(new Set<Id>{ row.Opportunity__c }).get(row.Opportunity__c);
            if (all != null) {
                Set<Id> have = new Set<Id>(ids);
                for (Id d : all) if (have.add(d)) ids.add(d);
                notes.add(cut ? 'The extraction\'s file list was cut at 255 characters; the deal\'s files were found again '
                    + 'from the opportunity and its base opportunity.'
                    : 'The extraction recorded no files; the deal\'s files were found from the opportunity.');
            }
        }
        return ids;
    }

    @TestVisible
    private static Order_Form_Extraction__c rebuild(Order_Form_Extraction__c row, List<Id> docIds) {
        if (String.isBlank(row.Raw_Response__c) || row.Raw_Response__c.length() >= RAW_LIMIT) return null;
        try {
            return OrderFormExtractionJob.rebuildFromReply(row.Opportunity__c, docIds, row.Raw_Response__c);
        } catch (Exception e) {
            return null;
        }
    }

    private static String reviewPromptCache;

    private static String reviewPrompt() {
        if (reviewPromptCache != null) return reviewPromptCache;
        List<StaticResource> res = [SELECT Body FROM StaticResource WHERE Name = :PROMPT_RESOURCE LIMIT 1];
        if (res.isEmpty()) throw new OrderFormExtractionJob.OrderFormException('Static resource "' + PROMPT_RESOURCE + '" not found.');
        reviewPromptCache = res[0].Body.toString();
        return reviewPromptCache;
    }

    private static Map<String, Object> outputConfig(Order_Form_Review_Setting__mdt s, Map<String, Object> replySchema) {
        Map<String, Object> cfg = new Map<String, Object>{
            'format' => new Map<String, Object>{ 'type' => 'json_schema', 'schema' => replySchema }
        };
        if (String.isNotBlank(s.Effort__c)) cfg.put('effort', s.Effort__c.trim().toLowerCase());
        return cfg;
    }

    // The text blocks that follow the files: permitted values, the raw extraction,
    // the product lines, the calculated values, the payload, the checks, coverage.
    @TestVisible
    private static List<Object> inputBlocks(Order_Form_Extraction__c row, List<OrderFormLines.Line> lines,
                                            Map<String, Object> raw, OrderFormValidator.Result checks,
                                            List<String> requiredFields, List<String> requiredProducts) {
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap();
        Map<String, Object> permitted = new Map<String, Object>();
        Map<String, Object> payload = new Map<String, Object>();
        for (String f : OrderFormReviewCoverage.PAYLOAD_FIELDS) {
            String name = OrderFormReviewCoverage.nameOf(f);
            payload.put(name, row.get(f));
            Schema.SObjectField sf = fields.get(f.toLowerCase());
            if (sf == null || sf.getDescribe().getType() != Schema.DisplayType.PICKLIST) continue;
            List<String> vals = new List<String>();
            for (Schema.PicklistEntry pe : sf.getDescribe().getPicklistValues()) if (pe.isActive()) vals.add(pe.getValue());
            permitted.put(name, vals);
        }
        Map<String, Object> flows = new Map<String, Object>{
            'Opportunity (fill blanks only)' => new List<String>{ 'Contract_Start_Date', 'Contract_End_Date',
                'Contract_Length_Months', 'Seat_Licenses', 'License_Fees', 'Platform_Connection_Fee',
                'Professional_Service_Fees', 'Total_Contract_Value (also Amount)', 'Annual_Recurring_Revenue (Incremental_ARR on amendments)',
                'Renewal_Terms', 'Subscription_Schedule', 'Payment_Terms', 'Credit_Terms', 'Billing_Contact_Email', 'ELA' },
            'Contract (legal terms; amendments reconcile, conflicts flag legal review)' => new List<String>{
                'Renewal_Terms', 'Renewal_Fee_Escalator', 'Payment_Terms', 'Credit_Terms', 'Rate_Limitable',
                'Rate_Limit_Notes', 'Subprocessor_Notice_Period', 'Subprocessor_Restrictions', 'ELA', 'Credit_Commit',
                'Credit_Overcommit_Obligation', 'Seat_Adds_By_Email', 'Seat_Adds_By_Email_Terms', 'Credit_Rollover',
                'Credit_Rollover_Terms', 'Credit_Rollover_Percent', 'Model_Change_Requirement', 'Model_Change_Terms' }
        };
        List<Object> productLines = new List<Object>();
        for (OrderFormLines.Line l : lines) {
            productLines.add(new Map<String, Object>{
                'ref' => OrderFormReviewCoverage.productRef(l), 'product' => l.product, 'label' => l.label,
                'quantity' => l.quantity, 'unit_price' => l.unitPrice, 'amount' => l.amount, 'basis' => l.basis,
                'period' => l.period, 'change' => l.change, 'credits_per_seat' => l.creditsPerSeat,
                'annual_amount' => l.annualAmount, 'recurring' => l.recurring, 'quote' => l.quote, 'note' => l.note
            });
        }
        Map<String, Object> calculated = new Map<String, Object>{
            'Derived_Fields' => row.Derived_Fields__c,
            'End_Date_Source' => row.End_Date_Source__c,
            'derivations' => derivationNotes(row, raw),
            'Full_Text_Values (values cut or rounded to fit, kept in full)' => row.Full_Text_Values__c,
            'Extraction_Issues' => row.Extraction_Issues__c,
            'line_totals' => new Map<String, Object>{
                'Lines_Recurring_Annual' => row.Lines_Recurring_Annual__c, 'Lines_Mismatch' => row.Lines_Mismatch__c,
                'Arvo_Seats' => row.Arvo_Seats__c, 'Free_Seats' => row.Free_Seats__c,
                'Included_Credits' => row.Included_Credits__c }
        };
        List<Object> checkRows = new List<Object>();
        for (OrderFormValidator.Check c : checks.checks) {
            if (c.status == OrderFormValidator.PASS) continue;
            checkRows.add(new Map<String, Object>{ 'check' => c.name, 'status' => c.status, 'stage' => c.stage,
                'field' => c.field, 'product_ref' => c.productRef, 'message' => c.message });
        }
        List<String> passed = new List<String>();
        for (OrderFormValidator.Check c : checks.checks) if (c.status == OrderFormValidator.PASS) passed.add(c.name);

        String rawText = String.isNotBlank(row.Extracted_JSON__c) && raw != null ? row.Extracted_JSON__c
            : (raw == null ? '(the raw extraction could not be read)' : JSON.serializePretty(raw));
        return new List<Object>{
            textBlock('EXTRACTION UNDER REVIEW: ' + row.Name + ' (saved ' + String.valueOf(row.Extracted_At__c)
                + ', extraction status ' + row.Extraction_Status__c + ', extracted by ' + row.Model__c + ').\n'
                + 'File classification recorded by the extractor:\n'
                + (String.isBlank(row.Document_Classes__c) ? '(none)' : row.Document_Classes__c)),
            textBlock('PERMITTED VALUES (Salesforce picklists of the saved fields):\n' + JSON.serialize(permitted)),
            textBlock('RAW EXTRACTION (the extractor\'s reply - claims to verify):\n' + rawText),
            textBlock('PRODUCT LINES (saved; stable reference L<n>:<product>):\n' + JSON.serializePretty(productLines)),
            textBlock('CALCULATED VALUES AND PROVENANCE:\n' + JSON.serializePretty(calculated)),
            textBlock('PROPOSED SALESFORCE PAYLOAD (saved Order_Form_Extraction__c values; null = blank):\n'
                + JSON.serializePretty(payload) + '\nWhere they go:\n' + JSON.serializePretty(flows)),
            textBlock('DETERMINISTIC CHECKS (status ' + checks.status + '). Problems:\n' + JSON.serializePretty(checkRows)
                + '\nPassed: ' + String.join(passed, ', ')),
            textBlock('REQUIRED COVERAGE:\nFields: ' + String.join(requiredFields, ', ') + '\nProduct lines: '
                + (requiredProducts.isEmpty() ? '(none)' : String.join(requiredProducts, ', ')))
        };
    }

    private static Map<String, Object> textBlock(String text) {
        return new Map<String, Object>{ 'type' => 'text', 'text' => text };
    }

    // The application's own notes from the evidence: how each value was derived, clamped, cut or rounded.
    private static Map<String, Object> derivationNotes(Order_Form_Extraction__c row, Map<String, Object> raw) {
        Map<String, Object> out = new Map<String, Object>();
        Map<String, Object> ev = OrderFormValidator.evidenceOf(row, raw);
        for (String k : ev.keySet()) {
            if (!(ev.get(k) instanceof Map<String, Object>)) continue;
            Map<String, Object> e = (Map<String, Object>) ev.get(k);
            Map<String, Object> notes = new Map<String, Object>();
            for (String tag : new List<String>{ 'derived', 'clamped', 'truncated', 'rounded' }) {
                if (e.get(tag) != null) notes.put(tag, e.get(tag));
            }
            if (!notes.isEmpty()) out.put(k, notes);
        }
        return out;
    }

    // ===================================================================
    // The response schema (output_config.format) and its validation in Apex

    @TestVisible
    private static Map<String, Object> responseSchema(List<String> allowedFields) {
        List<String> fieldEnum = new List<String>{ '' };
        fieldEnum.addAll(allowedFields);
        Map<String, Object> strType = new Map<String, Object>{ 'type' => 'string' };
        Map<String, Object> strList = new Map<String, Object>{ 'type' => 'array', 'items' => strType };
        Map<String, Object> finding = obj(new Map<String, Object>{
            'field' => new Map<String, Object>{ 'type' => 'string', 'enum' => fieldEnum },
            'product_ref' => strType,
            'product_component' => strType,
            'stage' => new Map<String, Object>{ 'type' => 'string', 'enum' => STAGES },
            'category' => new Map<String, Object>{ 'type' => 'string', 'enum' => CATEGORIES },
            'severity' => new Map<String, Object>{ 'type' => 'string', 'enum' => SEVERITIES },
            'explanation' => strType,
            'source_refs' => new Map<String, Object>{ 'type' => 'array', 'items' => obj(new Map<String, Object>{
                'file' => strType, 'location' => strType }) },
            'evidence' => strList,
            'correction' => obj(new Map<String, Object>{
                'action' => new Map<String, Object>{ 'type' => 'string', 'enum' => ACTIONS },
                'value' => strType,
                'unresolved_reason' => strType })
        });
        Map<String, Object> source = obj(new Map<String, Object>{
            'file' => strType,
            'role' => new Map<String, Object>{ 'type' => 'string', 'enum' => ROLES },
            'readable' => new Map<String, Object>{ 'type' => 'boolean' },
            'components' => new Map<String, Object>{ 'type' => 'array', 'items' => new Map<String, Object>{
                'type' => 'string', 'enum' => DOC_CLASSES } },
            'note' => strType
        });
        return obj(new Map<String, Object>{
            'findings' => new Map<String, Object>{ 'type' => 'array', 'items' => finding },
            'coverage' => obj(new Map<String, Object>{
                'verified' => strList, 'not_in_sources' => strList, 'not_reviewed' => strList }),
            'sources_reviewed' => new Map<String, Object>{ 'type' => 'array', 'items' => source },
            'gaps' => strList,
            'summary' => strType
        });
    }

    // An object schema: every property required, nothing else allowed.
    private static Map<String, Object> obj(Map<String, Object> properties) {
        List<String> required = new List<String>(properties.keySet());
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => properties,
            'required' => required,
            'additionalProperties' => false
        };
    }

    /** Problems with a reply against the review schema (empty = valid). */
    @TestVisible
    private static List<String> validateReply(Map<String, Object> reply, Set<String> allowedFields) {
        List<String> p = new List<String>();
        if (reply == null) {
            p.add('no JSON object');
            return p;
        }
        for (String k : new List<String>{ 'findings', 'coverage', 'sources_reviewed', 'gaps', 'summary' }) {
            if (!reply.containsKey(k)) p.add('missing ' + k);
        }
        if (!p.isEmpty()) return p;
        if (!(reply.get('findings') instanceof List<Object>)) p.add('findings is not a list');
        if (!(reply.get('sources_reviewed') instanceof List<Object>)) p.add('sources_reviewed is not a list');
        if (!(reply.get('gaps') instanceof List<Object>)) p.add('gaps is not a list');
        if (!(reply.get('summary') instanceof String)) p.add('summary is not text');
        if (!(reply.get('coverage') instanceof Map<String, Object>)) {
            p.add('coverage is not an object');
        } else {
            Map<String, Object> c = (Map<String, Object>) reply.get('coverage');
            for (String k : new List<String>{ 'verified', 'not_in_sources', 'not_reviewed' }) {
                if (!(c.get(k) instanceof List<Object>)) p.add('coverage.' + k + ' is not a list');
            }
        }
        if (!p.isEmpty()) return p;
        Integer i = 0;
        for (Object fo : (List<Object>) reply.get('findings')) {
            i++;
            String at = 'finding ' + i + ': ';
            if (!(fo instanceof Map<String, Object>)) { p.add(at + 'not an object'); continue; }
            Map<String, Object> f = (Map<String, Object>) fo;
            String field = str(f.get('field'));
            String ref = str(f.get('product_ref'));
            if (String.isNotBlank(field) && !allowedFields.contains(field)) p.add(at + 'unknown field "' + field + '"');
            if (String.isNotBlank(ref) && !PRODUCT_REF.matcher(ref).matches()) p.add(at + 'product_ref "' + ref + '" is not L<n>:<product>');
            if (!STAGES.contains(str(f.get('stage')))) p.add(at + 'stage "' + str(f.get('stage')) + '"');
            if (!CATEGORIES.contains(str(f.get('category')))) p.add(at + 'category "' + str(f.get('category')) + '"');
            if (!SEVERITIES.contains(str(f.get('severity')))) p.add(at + 'severity "' + str(f.get('severity')) + '"');
            if (String.isBlank(str(f.get('explanation')))) p.add(at + 'no explanation');
            if (!(f.get('evidence') instanceof List<Object>)) p.add(at + 'evidence is not a list');
            if (!(f.get('source_refs') instanceof List<Object>)) p.add(at + 'source_refs is not a list');
            if (!(f.get('correction') instanceof Map<String, Object>)) {
                p.add(at + 'no correction');
            } else {
                Map<String, Object> c = (Map<String, Object>) f.get('correction');
                String action = str(c.get('action'));
                if (!ACTIONS.contains(action)) p.add(at + 'correction.action "' + action + '"');
                if (action == 'set_value' && String.isBlank(str(c.get('value')))) p.add(at + 'set_value without a value');
                if (action == 'unresolved' && String.isBlank(str(c.get('unresolved_reason')))) {
                    p.add(at + 'unresolved without a reason');
                }
            }
            if (String.isBlank(field) && String.isBlank(ref) && str(f.get('stage')) != 'source_selection') {
                p.add(at + 'names neither a field nor a product line');
            }
            if (p.size() > 20) break;
        }
        for (Object so : (List<Object>) reply.get('sources_reviewed')) {
            if (!(so instanceof Map<String, Object>) || !(((Map<String, Object>) so).get('readable') instanceof Boolean)) {
                p.add('a sources_reviewed entry has no readable flag');
                break;
            }
        }
        return p;
    }

    // ===================================================================
    // Findings

    @TestVisible
    private static Order_Form_Review_Finding__c modelFinding(Map<String, Object> f, Order_Form_Extraction__c row,
                                                             List<OrderFormLines.Line> lines) {
        Map<String, Object> c = (Map<String, Object>) f.get('correction');
        String field = str(f.get('field'));
        String ref = str(f.get('product_ref'));
        String component = str(f.get('product_component'));
        String action = str(c.get('action'));
        List<String> evidence = new List<String>();
        for (Object e : (List<Object>) f.get('evidence')) if (e != null) evidence.add(String.valueOf(e));
        List<String> refs = new List<String>();
        for (Object r : (List<Object>) f.get('source_refs')) {
            if (!(r instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) r;
            refs.add(str(m.get('file')) + (String.isBlank(str(m.get('location'))) ? '' : ' - ' + str(m.get('location'))));
        }
        Integer lineNo;
        if (String.isNotBlank(ref)) {
            Matcher m = PRODUCT_REF.matcher(ref);
            if (m.matches()) lineNo = Integer.valueOf(m.group(1));
        }
        String proposed = action == 'set_value' ? str(c.get('value')) : null;
        Order_Form_Review_Finding__c out = new Order_Form_Review_Finding__c(
            Origin__c = 'Model',
            Field__c = String.isBlank(field) ? null : field.left(80),
            Product_Ref__c = String.isBlank(ref) ? null : ref.left(80),
            Product_Line_Number__c = lineNo,
            Product_Component__c = String.isBlank(component) ? null : component.left(80),
            Stage__c = stageLabel(str(f.get('stage'))),
            Category__c = str(f.get('category')),
            Severity__c = str(f.get('severity')).capitalize(),
            Explanation__c = truncate(str(f.get('explanation')), LONG_TEXT),
            Evidence__c = evidence.isEmpty() ? null : truncate(String.join(evidence, '\n---\n'), LONG_TEXT),
            Source_Refs__c = refs.isEmpty() ? null : truncate(String.join(refs, '\n'), 8192),
            Correction_Action__c = actionLabel(action),
            Proposed_Value__c = truncate(proposed, LONG_TEXT),
            Unresolved_Reason__c = action == 'unresolved' ? truncate(str(c.get('unresolved_reason')), 2000) : null,
            Current_Value__c = truncate(currentValue(row, lines, field, lineNo, component), LONG_TEXT),
            Status__c = 'Open'
        );
        out.Fingerprint__c = fingerprint('Model', field, ref, component, str(f.get('category')), action, proposed);
        return out;
    }

    @TestVisible
    private static Order_Form_Review_Finding__c checkFinding(OrderFormValidator.Check c, Order_Form_Extraction__c row) {
        Integer lineNo;
        if (String.isNotBlank(c.productRef)) {
            Matcher m = PRODUCT_REF.matcher(c.productRef);
            if (m.matches()) lineNo = Integer.valueOf(m.group(1));
        }
        Order_Form_Review_Finding__c out = new Order_Form_Review_Finding__c(
            Origin__c = 'Check',
            Field__c = c.field == null ? null : c.field.left(80),
            Product_Ref__c = c.productRef == null ? null : c.productRef.left(80),
            Product_Line_Number__c = lineNo,
            Stage__c = c.stage,
            Category__c = c.name,
            Severity__c = c.status == OrderFormValidator.FAIL ? 'High' : 'Low',
            Explanation__c = truncate(c.message, LONG_TEXT),
            Correction_Action__c = 'None',
            Current_Value__c = row == null ? null : truncate(currentValue(row, null, c.field, null, null), LONG_TEXT),
            Status__c = 'Open'
        );
        out.Fingerprint__c = fingerprint('Check', c.field, c.productRef, null, c.name, 'none', c.message);
        return out;
    }

    private static String currentValue(Order_Form_Extraction__c row, List<OrderFormLines.Line> lines, String field,
                                       Integer lineNo, String component) {
        if (row == null) return null;
        if (lineNo != null && lines != null) {
            for (OrderFormLines.Line l : lines) {
                if (l.lineNo != lineNo) continue;
                Map<String, Object> asMap = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(l));
                String key = componentKey(component);
                return key == null ? JSON.serialize(asMap) : OrderFormValidator.fmt(asMap.get(key));
            }
            return '(no such line)';
        }
        if (String.isBlank(field)) return null;
        Schema.SObjectField sf = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap().get((field + '__c').toLowerCase());
        if (sf == null) return null;
        Object v;
        try {
            v = row.get(field + '__c');
        } catch (Exception e) {
            return null;   // a field the review did not load
        }
        if (v == null) return '(blank)';
        if (v instanceof Decimal) return ((Decimal) v).stripTrailingZeros().toPlainString();
        return String.valueOf(v);
    }

    private static String componentKey(String component) {
        if (String.isBlank(component)) return null;
        Map<String, String> keys = new Map<String, String>{
            'quantity' => 'quantity', 'unit_price' => 'unitPrice', 'amount' => 'amount', 'basis' => 'basis',
            'period' => 'period', 'change' => 'change', 'product' => 'product', 'credits_per_seat' => 'creditsPerSeat',
            'label' => 'label'
        };
        return keys.get(component.trim().toLowerCase());
    }

    private static String stageLabel(String stage) {
        Map<String, String> labels = new Map<String, String>{
            'source_selection' => 'Source Selection', 'extraction' => 'Extraction', 'calculation' => 'Calculation',
            'mapping' => 'Mapping', 'persistence' => 'Persistence'
        };
        return labels.get(stage);
    }

    private static String actionLabel(String action) {
        Map<String, String> labels = new Map<String, String>{
            'none' => 'None', 'set_value' => 'Set Value', 'clear_value' => 'Clear Value', 'unresolved' => 'Unresolved'
        };
        return labels.get(action);
    }

    @TestVisible
    private static String fingerprint(String origin, String field, String ref, String component, String category,
                                      String action, String value) {
        return sha256(String.join(new List<String>{ origin, nz(field), nz(ref), nz(component), nz(category), nz(action),
            nz(value) }, '|').toLowerCase());
    }

    // ===================================================================
    // Usage, cost, reply text

    private static void recordUsage(Order_Form_Review__c rev, Map<String, Object> envelope, Order_Form_Review_Setting__mdt s) {
        if (envelope.get('model') != null) rev.Served_Model__c = String.valueOf(envelope.get('model')).left(100);
        if (!(envelope.get('usage') instanceof Map<String, Object>)) return;
        Map<String, Object> u = (Map<String, Object>) envelope.get('usage');
        Decimal inTok = dec(u.get('input_tokens'));
        Decimal outTok = dec(u.get('output_tokens'));
        Decimal readTok = dec(u.get('cache_read_input_tokens'));
        Decimal writeTok = dec(u.get('cache_creation_input_tokens'));
        rev.Input_Tokens__c = inTok;
        rev.Output_Tokens__c = outTok;
        rev.Cache_Read_Tokens__c = readTok;
        rev.Cache_Write_Tokens__c = writeTok;
        Decimal cost = nzd(inTok) * nzd(s.Input_Price_Per_MTok__c) + nzd(outTok) * nzd(s.Output_Price_Per_MTok__c)
            + nzd(readTok) * nzd(s.Cache_Read_Price_Per_MTok__c) + nzd(writeTok) * nzd(s.Cache_Write_Price_Per_MTok__c);
        rev.Cost_USD__c = (cost / 1000000).setScale(6, RoundingMode.HALF_UP);
    }

    // The JSON text of the reply: the text after the last fallback block (a
    // server-side fallback re-answers from that point), joined.
    @TestVisible
    private static String replyText(Map<String, Object> envelope) {
        List<Object> content = envelope.get('content') instanceof List<Object>
            ? (List<Object>) envelope.get('content') : new List<Object>();
        List<String> parts = new List<String>();
        for (Object o : content) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> b = (Map<String, Object>) o;
            String type = str(b.get('type'));
            if (type == 'fallback') parts.clear();
            else if (type == 'text' && b.get('text') != null) parts.add(String.valueOf(b.get('text')));
        }
        if (parts.isEmpty()) throw new OrderFormExtractionJob.OrderFormException('The reply has no text block.');
        return String.join(parts, '').trim();
    }

    // ===================================================================
    // Hashes (shared with OrderFormReviewStaleness)

    private static String promptVersion(String reviewerPrompt, String definitions, Map<String, Object> replySchema,
                                        Order_Form_Review_Setting__mdt s) {
        return sha256(reviewerPrompt + '\n' + definitions + '\n' + JSON.serialize(replySchema) + '\n'
            + s.Model__c + '|' + s.Effort__c + '|' + s.Max_Tokens__c);
    }

    /**
     * The hashes a review of this extraction would record now - input (values),
     * source (file versions) and prompt (prompts, schema, model settings). No callout.
     */
    public static Map<String, String> versionsOf(Id extractionId) {
        Order_Form_Extraction__c row = loadRow(extractionId);
        if (row == null) return null;
        List<Id> docIds = docIdsOf(row, new List<String>());
        Map<String, Object> replySchema = responseSchema(
            OrderFormReviewCoverage.allowedFields(OrderFormExtractionJob.promptSchemaKeys()));
        return new Map<String, String>{
            'input' => inputHash(row),
            'source' => sourceHash(docIds),
            'prompt' => promptVersion(reviewPrompt(), OrderFormExtractionJob.extractionPrompt(), replySchema, settings())
        };
    }

    /** SHA-256 of the saved values, product lines, derivations, evidence, issues and full values. */
    public static String inputHash(Order_Form_Extraction__c row) {
        List<String> parts = new List<String>();
        for (String f : OrderFormReviewCoverage.PAYLOAD_FIELDS) parts.add(f + '=' + canon(row.get(f)));
        for (String f : OrderFormReviewCoverage.HASH_EXTRA_FIELDS) parts.add(f + '=' + canon(row.get(f)));
        return sha256(String.join(parts, '\n'));
    }

    /** SHA-256 of the latest version of each file the extraction read. */
    public static String sourceHash(List<Id> docIds) {
        if (docIds == null || docIds.isEmpty()) return sha256('');
        List<String> versions = new List<String>();
        for (ContentVersion cv : [
            SELECT Id FROM ContentVersion WHERE ContentDocumentId IN :docIds AND IsLatest = true
        ]) versions.add(String.valueOf(cv.Id));
        versions.sort();
        return sha256(String.join(versions, ','));
    }

    /** The canonical text of a saved value (as hashed): decimals without trailing zeros, blank text as empty. */
    public static String canonValue(Object v) {
        return canon(v);
    }

    @TestVisible
    private static String canon(Object v) {
        if (v == null) return '';
        if (v instanceof Decimal) return ((Decimal) v).stripTrailingZeros().toPlainString();
        if (v instanceof String && String.isBlank((String) v)) return '';
        return String.valueOf(v);
    }

    public static String sha256(String s) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(s == null ? '' : s)));
    }

    // ===================================================================
    // small helpers

    private static Set<String> strings(Object v) {
        Set<String> out = new Set<String>();
        if (v instanceof List<Object>) for (Object o : (List<Object>) v) if (o != null) out.add(String.valueOf(o).trim());
        return out;
    }

    private static List<String> sorted(Set<String> s) {
        List<String> out = new List<String>(s);
        out.sort();
        return out;
    }

    private static String str(Object v) {
        return v == null ? '' : String.valueOf(v);
    }

    private static String nz(String s) {
        return s == null ? '' : s.trim();
    }

    private static Decimal nzd(Decimal d) {
        return d == null ? 0 : d;
    }

    private static Decimal dec(Object v) {
        if (v == null) return null;
        try {
            return Decimal.valueOf(String.valueOf(v));
        } catch (Exception e) {
            return null;
        }
    }

    private static String truncate(String s, Integer n) {
        if (s == null) return null;
        return s.length() > n ? s.left(n) : s;
    }
}
