/**
 * The reviewer end to end on reviewed fixtures (extraction -> calculations ->
 * saved payload -> review), its failure and coverage rules, staleness and safe
 * reruns, and the Peel Hunt regressions (renewal default, TCV provenance, email
 * punctuation, truncation).
 *
 * The model is mocked: these tests prove the plumbing and the rules, not the
 * quality of a real model's review (scripts/review-eval measures that).
 */
@isTest
private class OrderFormReviewerTest {

    // ---------------------------------------------------------------- setup

    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'OFE_Review_Test_Bypass', Label = 'OFE Review Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private static final String SAFE_OPEN_STAGE = '4 - Proposal';

    private static Opportunity insertOpp(String name, Id baseOppId) {
        Opportunity o = new Opportunity(Name = name, StageName = 'Closed Won', CloseDate = Date.today(),
            Base_Opportunity__c = baseOppId);
        if (FeatureManagement.checkPermission('Bypass_Validations')) {
            insert o;
        } else {
            o.StageName = SAFE_OPEN_STAGE;
            insert o;
            o.StageName = 'Closed Won';
            update o;
        }
        return o;
    }

    private static Id attachFile(Id parentId, String title) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake pdf bytes for unit test'), FirstPublishLocationId = parentId);
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    private static void reviewerOn() {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(
            Mode__c = 'Shadow', Model__c = 'claude-opus-5-5', Effort__c = 'low', Max_Tokens__c = 16000,
            Max_Attempts__c = 2, Timeout_Ms__c = 120000, Use_Fallbacks__c = true, Input_Price_Per_MTok__c = 4,
            Output_Price_Per_MTok__c = 20, Cache_Read_Price_Per_MTok__c = 0.2, Cache_Write_Price_Per_MTok__c = 5,
            Sweep_Days__c = 30);
    }

    // A Messages API envelope around the extraction JSON.
    private static String extractionReply(Map<String, Object> extracted) {
        return JSON.serialize(new Map<String, Object>{
            'id' => 'msg_x', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-sonnet-5',
            'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(extracted) } },
            'stop_reason' => 'end_turn', 'usage' => new Map<String, Object>{ 'input_tokens' => 1, 'output_tokens' => 1 }
        });
    }

    private static Map<String, Object> quote(String clause, String text) {
        return new Map<String, Object>{ 'clause' => clause, 'quote' => text };
    }

    // A clean new-business order form: 25 seats at $69,000 + a $46,000 credit
    // commitment (2.3M credits) = $115,000 a year, everything stated and supported.
    private static Map<String, Object> cleanExtraction(String fileTitle) {
        return new Map<String, Object>{
            'Documents' => new List<Object>{ new Map<String, Object>{
                'file' => 'FILE 1 (CURRENT DEAL): ' + fileTitle, 'group' => 'Current', 'class' => 'Order Form',
                'components' => new List<Object>{ 'Order Form', 'MSA' } } },
            '_is_amendment' => false,
            'Source_Document_Type' => 'Order Form',
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-01-01',
            'Contract_Length_Months' => 12,
            'Seat_Licenses' => 25,
            'Value_Basis' => 'Annual',
            'License_Fees' => 69000,
            'Recurring_Fees_Stated' => 115000,
            'Total_Contract_Value' => 115000,
            'Currency' => 'USD',
            'Credit_Commit_Fee' => 46000,
            'Credits_Purchased' => 2300000,
            'Credits_Period' => 'year',
            'Credit_Commit' => true,
            'Renewal_Terms' => 'Auto-renew (90-day)',
            'Billing_Contact_Email' => 'accounts-payable@example.com',
            'Billing_Entity_Name' => 'Acme Capital Ltd',
            'Customer_Signature_Date' => '2025-12-15',
            'Free_Tier_Retained' => 'Not specified',
            'Credit_Rollover' => 'No Rollover',
            'Credit_Rollover_Terms' => 'Unused Credits do not roll over to a new term.',
            'Subprocessor_Gate_Type' => 'Notify',
            'Subprocessor_Notice_Period_Days' => 30,
            'Sub_Processor_List' => 'By reference: https://rogo.ai/subprocessors',
            'Subprocessor_List_Location' => 'Trust page',
            'Model_Change_Requirement' => 'None identified',
            'Model_Change_Terms' => 'None identified: No notice or approval requirement identified.',
            'AI_Training_Prohibition' => 'Yes',
            'Logo_Publicity_Rights' => 'Not Mentioned',
            'LLM_Gate_Confidence' => 'High',
            'Line_Items' => new List<Object>{
                new Map<String, Object>{ 'product' => 'Rogo Seats', 'label' => 'Platform Fee', 'quantity' => 25,
                    'amount' => 69000, 'basis' => 'Annual', 'quote' => 'Platform Fee: USD $69,000.00 per year (25 Authorized Users)' },
                new Map<String, Object>{ 'product' => 'Paid Credits', 'label' => 'Credit Commitment', 'quantity' => 2300000,
                    'amount' => 46000, 'basis' => 'Annual', 'period' => 'year',
                    'quote' => 'Credit Commitment: USD $46,000.00 per year for 2,300,000 Credits' }
            },
            'Extract_Evidence' => new Map<String, Object>{
                'Renewal_Terms' => quote('MSA 12', 'This Agreement renews automatically for successive one-year terms '
                    + 'unless either party gives notice of non-renewal at least ninety (90) days prior to the end of the term.'),
                'Billing_Contact_Email' => quote('Order Form', 'Accounts Payable: accounts-payable@example.com'),
                'Recurring_Fees_Stated' => quote('Order Form', 'Total Annual Fees: USD $115,000.00'),
                'Total_Contract_Value' => quote('Order Form', 'Total Fees for the Subscription Period: USD $115,000.00')
            }
        };
    }

    // Build the extraction exactly as the pipeline does (buildFromResponseBody) and save it.
    private static Order_Form_Extraction__c saveExtraction(Id oppId, List<Id> docIds, Map<String, Object> extracted) {
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(oppId, docIds, extractionReply(extracted));
        row.Is_Current__c = true;
        insert row;
        return row;
    }

    // ------------------------------------------------------------ the mock

    public class ReviewMock implements HttpCalloutMock {
        public Integer statusCode = 200;
        public String body;
        public Boolean timeout = false;
        public Integer calls = 0;
        public String lastRequest;
        public String lastBeta;
        public HttpResponse respond(HttpRequest req) {
            calls++;
            lastRequest = req.getBody();
            lastBeta = req.getHeader('anthropic-beta');
            if (timeout) throw new CalloutException('Read timed out');
            HttpResponse r = new HttpResponse();
            r.setStatusCode(statusCode);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(body);
            return r;
        }
    }

    private static String envelope(String text, String stopReason) {
        return JSON.serialize(new Map<String, Object>{
            'id' => 'msg_review', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-opus-5-5',
            'content' => new List<Object>{
                new Map<String, Object>{ 'type' => 'thinking', 'thinking' => '', 'signature' => 'x' },
                new Map<String, Object>{ 'type' => 'text', 'text' => text } },
            'stop_reason' => stopReason,
            'usage' => new Map<String, Object>{ 'input_tokens' => 50000, 'output_tokens' => 3000,
                'cache_read_input_tokens' => 0, 'cache_creation_input_tokens' => 20000 }
        });
    }

    // A review reply: the findings, and every required item not named in a finding
    // marked verified unless listed as not reviewed.
    private static String reviewReply(Order_Form_Extraction__c row, List<Object> findings, Set<String> notReviewed,
                                      List<String> gaps) {
        Order_Form_Extraction__c saved = [SELECT Id, Source_Document_Type__c, Extraction_Status__c, Type__c, Line_Items__c
                                          FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        Set<String> named = new Set<String>();
        for (Object o : findings) {
            Map<String, Object> f = (Map<String, Object>) o;
            named.add(String.valueOf(f.get('field')));
            named.add(String.valueOf(f.get('product_ref')));
        }
        List<String> verified = new List<String>();
        List<String> items = new List<String>(OrderFormReviewCoverage.requiredFields(saved));
        items.addAll(OrderFormReviewCoverage.requiredProducts(OrderFormLines.fromJson(saved.Line_Items__c)));
        for (String item : items) {
            if (!named.contains(item) && (notReviewed == null || !notReviewed.contains(item))) verified.add(item);
        }
        Map<String, Object> reply = new Map<String, Object>{
            'findings' => findings,
            'coverage' => new Map<String, Object>{ 'verified' => verified, 'not_in_sources' => new List<String>(),
                'not_reviewed' => notReviewed == null ? new List<String>() : new List<String>(notReviewed) },
            'sources_reviewed' => new List<Object>{ new Map<String, Object>{ 'file' => 'FILE 1 (CURRENT DEAL)',
                'role' => 'governing', 'readable' => true, 'components' => new List<Object>{ 'Order Form' }, 'note' => '' } },
            'gaps' => gaps == null ? new List<String>() : gaps,
            'summary' => 'Reviewed.'
        };
        return envelope(JSON.serialize(reply), 'end_turn');
    }

    private static Map<String, Object> finding(String field, String ref, String component, String category,
                                               String action, String value, String reason) {
        return new Map<String, Object>{
            'field' => field, 'product_ref' => ref, 'product_component' => component, 'stage' => 'extraction',
            'category' => category, 'severity' => 'high', 'explanation' => 'Test finding.',
            'source_refs' => new List<Object>{ new Map<String, Object>{ 'file' => 'FILE 1 (CURRENT DEAL)', 'location' => 'p.1' } },
            'evidence' => new List<Object>{ 'verbatim source text' },
            'correction' => new Map<String, Object>{ 'action' => action, 'value' => value, 'unresolved_reason' => reason }
        };
    }

    private static List<String> checkNames(String checksJson, String status) {
        List<String> out = new List<String>();
        for (Object o : (List<Object>) JSON.deserializeUntyped(checksJson)) {
            Map<String, Object> c = (Map<String, Object>) o;
            if (c.get('status') != status) continue;
            String entry = String.valueOf(c.get('name')) + ':' + String.valueOf(c.get('field'));
            // A failure's reason too, so a failing deploy shows why.
            if (status == 'Fail') entry += ' (' + String.valueOf(c.get('message')).left(160) + ')';
            out.add(entry);
        }
        return out;
    }

    // ============================================================ fixtures

    @isTest
    static void cleanExtraction_reviewIsClearAndChangesNothing() {
        reviewerOn();
        Opportunity opp = insertOpp('Acme Clean', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Acme');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Acme'));
        Order_Form_Extraction__c before = [SELECT Renewal_Terms__c, Annual_Recurring_Revenue__c, Line_Items__c, LastModifiedDate
                                           FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals('Success', [SELECT Extraction_Status__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Extraction_Status__c);
        System.assertEquals(115000, before.Annual_Recurring_Revenue__c);
        Set<Id> lineIds = new Map<Id, Order_Form_Line__c>([SELECT Id FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]).keySet();
        System.assertEquals(2, lineIds.size());

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.Outcome o = OrderFormReviewer.reviewAndSave(row.Id, false);
        Test.stopTest();

        Order_Form_Review__c rev = [SELECT Status__c, Check_Status__c, Checks__c, Is_Current__c, Findings_Count__c,
                                    Unreviewed_Required_Fields__c, Missing_Required_Sources__c, Cost_USD__c,
                                    Served_Model__c, Input_Hash__c, Sources_Sent__c, Mode__c
                                    FROM Order_Form_Review__c WHERE Extraction__c = :row.Id];
        String problems = 'fail: ' + String.join(checkNames(rev.Checks__c, 'Fail'), ', ')
            + ' | warn: ' + String.join(checkNames(rev.Checks__c, 'Warn'), ', ');
        System.debug(LoggingLevel.INFO, 'Clean fixture checks - ' + problems);
        System.assertEquals('Clear', rev.Status__c, problems + ' | unreviewed: ' + rev.Unreviewed_Required_Fields__c
            + ' | missing: ' + rev.Missing_Required_Sources__c);
        System.assertNotEquals('Fail', rev.Check_Status__c, problems);
        System.assertEquals(0, [SELECT COUNT() FROM Order_Form_Review_Finding__c
                                WHERE Extraction__c = :row.Id AND Origin__c = 'Model'], 'the model reported nothing');
        System.assertEquals(true, rev.Is_Current__c);
        System.assertEquals('Shadow', rev.Mode__c);
        System.assertEquals('claude-opus-5-5', rev.Served_Model__c);
        // 50,000 x $4 + 3,000 x $20 + 20,000 x $5 per million = $0.36
        System.assertEquals(0.36, rev.Cost_USD__c);
        System.assert(rev.Sources_Sent__c.contains('FILE 1 (CURRENT DEAL): Rogo Order Form - Acme'), rev.Sources_Sent__c);

        // The request: configured model, schema-constrained output, the original
        // PDF with its label, the core instruction, the field definitions, fallbacks.
        Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest);
        System.assertEquals('claude-opus-5-5', req.get('model'));
        System.assertEquals('default', req.get('fallbacks'));
        System.assertEquals('server-side-fallback-2026-07-01', mock.lastBeta);
        Map<String, Object> cfg = (Map<String, Object>) req.get('output_config');
        System.assertEquals('low', cfg.get('effort'));
        System.assertEquals('json_schema', ((Map<String, Object>) cfg.get('format')).get('type'));
        System.assert(!req.containsKey('thinking'), 'Opus 5.5 takes no thinking parameter');
        System.assert(mock.lastRequest.contains('Audit the proposed extraction and product records against the supplied '
            + 'agreements and field definitions.'), 'core instruction verbatim');
        System.assert(mock.lastRequest.contains('FIELD DEFINITIONS'), 'extraction prompt as definitions');
        System.assert(mock.lastRequest.contains('application/pdf'), 'original PDF sent');
        System.assert(mock.lastRequest.contains('FILE 1 (CURRENT DEAL): Rogo Order Form - Acme'));
        System.assert(mock.lastRequest.contains('PROPOSED SALESFORCE PAYLOAD'));
        System.assert(mock.lastRequest.contains('DETERMINISTIC CHECKS'));
        System.assert(mock.lastRequest.contains('L2:Paid Credits'));

        // Shadow mode: the extraction and its product lines are untouched.
        Order_Form_Extraction__c after = [SELECT Renewal_Terms__c, Annual_Recurring_Revenue__c, Line_Items__c, LastModifiedDate
                                          FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals(before.LastModifiedDate, after.LastModifiedDate);
        System.assertEquals(before.Line_Items__c, after.Line_Items__c);
        System.assertEquals(lineIds, new Map<Id, Order_Form_Line__c>([SELECT Id FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]).keySet());
        System.assertEquals(rev.Input_Hash__c, OrderFormReviewer.versionsOf(row.Id).get('input'));
    }

    @isTest
    static void amendment_findingsKeepNoCorrectionApartFromClear() {
        reviewerOn();
        Opportunity base = insertOpp('Acme Base', null);
        Id baseDoc = attachFile(base.Id, 'Master Agreement - Acme');
        Opportunity opp = insertOpp('Acme Upsell', base.Id);
        Id doc = attachFile(opp.Id, 'Rogo Supplemental Order Form - Acme');
        Map<String, Object> ex = new Map<String, Object>{
            'Documents' => new List<Object>{
                new Map<String, Object>{ 'file' => 'FILE 1 (CURRENT DEAL): Rogo Supplemental Order Form - Acme',
                    'group' => 'Current', 'class' => 'Order Form' },
                new Map<String, Object>{ 'file' => 'FILE 2 (PARENT CONTEXT): Master Agreement - Acme',
                    'group' => 'Parent', 'class' => 'MSA' } },
            '_is_amendment' => true, 'Type' => 'Upsell', 'Source_Document_Type' => 'Rider / Amendment',
            'Contract_Start_Date' => '2026-03-01', 'Contract_End_Date' => '2026-12-31',
            'Seats_Added' => 10, 'Value_Basis' => 'Annual', 'License_Fees' => 20000,
            'Incremental_Recurring_Fees' => 20000, 'Currency' => 'USD',
            'Line_Items' => new List<Object>{ new Map<String, Object>{ 'product' => 'Rogo Seats', 'label' => 'Additional Users',
                'quantity' => 10, 'amount' => 20000, 'basis' => 'Annual', 'change' => 'Added',
                'quote' => '10 additional Authorized Users: USD $20,000.00 per year' } }
        };
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc, baseDoc }, ex);

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>{
            finding('Seats_Added', '', '', 'wrong_value', 'set_value', '12', ''),
            finding('', 'L1:Rogo Seats', 'quantity', 'wrong_value', 'set_value', '12', ''),
            finding('Renewal_Terms', '', '', 'unsupported_provenance', 'none', '', ''),
            finding('Payment_Terms', '', '', 'unsupported_value', 'clear_value', '', ''),
            finding('Credit_Terms', '', '', 'missing_referenced_terms', 'unresolved', '', 'The referenced MSA schedule is not attached.')
        }, null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, false);
        Test.stopTest();

        Order_Form_Review__c rev = [SELECT Status__c, Sources_Sent__c, Missing_Required_Sources__c FROM Order_Form_Review__c
                                    WHERE Extraction__c = :row.Id];
        System.assertEquals('Findings', rev.Status__c, '' + rev.Missing_Required_Sources__c);
        System.assert(rev.Sources_Sent__c.contains('(PARENT CONTEXT): Master Agreement - Acme'), rev.Sources_Sent__c);
        Map<String, Order_Form_Review_Finding__c> byKey = new Map<String, Order_Form_Review_Finding__c>();
        for (Order_Form_Review_Finding__c f : [
            SELECT Field__c, Product_Ref__c, Product_Line_Number__c, Product_Component__c, Correction_Action__c,
                   Proposed_Value__c, Unresolved_Reason__c, Current_Value__c, Stage__c, Severity__c, Origin__c, Status__c
            FROM Order_Form_Review_Finding__c WHERE Extraction__c = :row.Id AND Origin__c = 'Model'
        ]) {
            byKey.put(f.Field__c != null ? f.Field__c : f.Product_Ref__c, f);
        }
        System.assertEquals('Set Value', byKey.get('Seats_Added').Correction_Action__c);
        System.assertEquals('12', byKey.get('Seats_Added').Proposed_Value__c);
        System.assertEquals('10', byKey.get('Seats_Added').Current_Value__c);
        System.assertEquals(1, byKey.get('L1:Rogo Seats').Product_Line_Number__c);
        System.assertEquals('quantity', byKey.get('L1:Rogo Seats').Product_Component__c);
        System.assertEquals('10', byKey.get('L1:Rogo Seats').Current_Value__c);
        // "No correction" and "clear the value" stay distinct.
        System.assertEquals('None', byKey.get('Renewal_Terms').Correction_Action__c);
        System.assertEquals(null, byKey.get('Renewal_Terms').Proposed_Value__c);
        System.assertEquals('Clear Value', byKey.get('Payment_Terms').Correction_Action__c);
        System.assertEquals('Unresolved', byKey.get('Credit_Terms').Correction_Action__c);
        System.assertEquals('The referenced MSA schedule is not attached.', byKey.get('Credit_Terms').Unresolved_Reason__c);
        System.assertEquals('Extraction', byKey.get('Seats_Added').Stage__c);
        System.assertEquals('High', byKey.get('Seats_Added').Severity__c);
        System.assertEquals('Open', byKey.get('Seats_Added').Status__c);
        // Nothing was applied.
        System.assertEquals(10, [SELECT Seats_Added__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Seats_Added__c);
    }

    @isTest
    static void emailOnlyOrder_requiresOnlyWhatTheEmailStates() {
        reviewerOn();
        Opportunity opp = insertOpp('Green Court Seats', null);
        Id doc = attachFile(opp.Id, 'Email - add users');
        Map<String, Object> ex = new Map<String, Object>{
            'Documents' => new List<Object>{ new Map<String, Object>{ 'file' => 'FILE 1 (CURRENT DEAL): Email - add users',
                'group' => 'Current', 'class' => 'Order Form' } },
            'Source_Document_Type' => 'Email Confirmation', 'Type' => 'Upsell', 'Seats_Added' => 4,
            'Named_Users' => 'Jane Doe jane.doe@example.com\nOne User TBD',
            'Requested_By_Name' => 'Pat Smith', 'Requested_By_Email' => 'pat.smith@example.com',
            'Billing_Entity_Name' => 'Green Court Partners', 'Billing_Entity_Is_Derived' => true,
            'Extract_Evidence' => new Map<String, Object>{
                'Requested_By_Email' => quote('FILE 1', 'From: Pat Smith <pat.smith@example.com>'),
                'Source_Document_Type' => new Map<String, Object>{ 'clause' => 'FILE 1',
                    'quote' => 'please add 4 additional users', 'note' => 'Extracted from an email confirmation.' } }
        };
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, ex);
        Order_Form_Extraction__c saved = [SELECT Id, Source_Document_Type__c, Extraction_Status__c, Type__c, License_Fees__c,
                                          Total_Contract_Value__c, Renewal_Terms__c FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals(null, saved.License_Fees__c, 'an email states no fees');
        System.assertEquals(null, saved.Total_Contract_Value__c);
        List<String> required = OrderFormReviewCoverage.requiredFields(saved);
        System.assert(required.contains('Requested_By_Email') && required.contains('Named_Users'), String.join(required, ','));
        System.assert(!required.contains('Renewal_Terms') && !required.contains('Contract_End_Date'),
            'no legal or term coverage required of an email: ' + String.join(required, ','));

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, false);
        Test.stopTest();
        Order_Form_Review__c rev = [SELECT Status__c, Checks__c, Unreviewed_Required_Fields__c FROM Order_Form_Review__c
                                    WHERE Extraction__c = :row.Id];
        System.assertEquals('Clear', rev.Status__c, 'fail: ' + String.join(checkNames(rev.Checks__c, 'Fail'), ', ')
            + ' | unreviewed: ' + rev.Unreviewed_Required_Fields__c);
    }

    @isTest
    static void phasedAndMixedPricing_appDerivesTheEscalatorAndKeepsTheExactValue() {
        Opportunity opp = insertOpp('Phased Deal', null);
        Map<String, Object> ex = cleanExtraction('Phased Order Form');
        ex.put('Ramp_Schedule', new List<Object>{
            new Map<String, Object>{ 'effective_date' => '2026-01-01', 'seats' => 25, 'platform_fee_annual' => 81000 },
            new Map<String, Object>{ 'effective_date' => '2027-01-01', 'seats' => 25, 'platform_fee_annual' => 89019 } });
        // A monthly Arvo line beside the annual seats: annualised by the app.
        List<Object> lines = (List<Object>) ex.get('Line_Items');
        lines.add(new Map<String, Object>{ 'product' => 'Arvo Seats', 'label' => 'Rogo Notes', 'quantity' => 5,
            'unit_price' => 100, 'basis' => 'Monthly', 'quote' => 'Rogo Notes: $100 per license per month; 5 licenses' });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        System.assertEquals(9.9, row.Renewal_Fee_Escalator__c, 'the app computes (89,019 - 81,000) / 81,000');
        System.assert(row.Derived_Fields__c.contains('Renewal_Fee_Escalator'), row.Derived_Fields__c);
        // The whole-number percent field keeps 10; the exact 9.9 is kept in full.
        System.assert(row.Derived_Fields__c.contains('Renewal_Fee_Escalator(rounded)'), row.Derived_Fields__c);
        System.assertEquals('9.9', ((Map<String, Object>) JSON.deserializeUntyped(row.Full_Text_Values__c)).get('Renewal_Fee_Escalator__c'));
        System.assertEquals(6000, OrderFormLines.annualFor(OrderFormLines.fromJson(row.Line_Items__c),
            new Set<String>{ 'Arvo Seats' }), 'monthly Arvo line annualised');

        // Phases that add seats are a ramp, not a price escalator.
        ex.put('Ramp_Schedule', new List<Object>{
            new Map<String, Object>{ 'effective_date' => '2026-01-01', 'seats' => 25, 'platform_fee_annual' => 81000 },
            new Map<String, Object>{ 'effective_date' => '2027-01-01', 'seats' => 40, 'platform_fee_annual' => 120000 } });
        Order_Form_Extraction__c ramp = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        System.assertEquals(null, ramp.Renewal_Fee_Escalator__c);
    }

    @isTest
    static void missingReferencedTerms_staysVisibleAndIncomplete() {
        reviewerOn();
        Opportunity opp = insertOpp('Missing Schedule', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Missing');
        Map<String, Object> ex = cleanExtraction('Rogo Order Form - Missing');
        ex.put('Model_Change_Requirement', 'Unresolved');
        ex.put('Model_Change_Terms', 'Unresolved: Referenced AI Schedule is missing.');
        ex.put('Issues', new List<Object>{ new Map<String, Object>{ 'kind' => 'missing_referenced_terms',
            'field' => 'Model_Change_Requirement', 'stated' => 'subject to the AI Schedule',
            'note' => 'The AI Schedule is referenced but not attached.', 'files' => 'FILE 1 (CURRENT DEAL)' } });
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, ex);
        System.assert([SELECT Extraction_Issues__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Extraction_Issues__c
            .contains('[missing_referenced_terms] Model_Change_Requirement'));

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), new Set<String>{ 'Model_Change_Requirement' },
            new List<String>{ 'The AI Schedule referenced in section 8 is not attached.' });
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, false);
        Test.stopTest();
        Order_Form_Review__c rev = [SELECT Status__c, Unreviewed_Required_Fields__c, Summary__c, Checks__c
                                    FROM Order_Form_Review__c WHERE Extraction__c = :row.Id];
        System.assertEquals('Incomplete', rev.Status__c);
        System.assertEquals('Model_Change_Requirement', rev.Unreviewed_Required_Fields__c);
        System.assert(rev.Summary__c.contains('AI Schedule'), rev.Summary__c);
        System.assert(checkNames(rev.Checks__c, 'Warn').contains('extraction_issues:null'), rev.Checks__c);
    }

    // ===================================================== failures / coverage

    // Each case is one review (one callout, no DML); a few per test keeps under the query limit.
    private static Map<String, OrderFormReviewer.Outcome> runFailures(Map<String, ReviewMock> cases) {
        reviewerOn();
        Opportunity opp = insertOpp('Failures', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Failures');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Failures'));
        Map<String, OrderFormReviewer.Outcome> results = new Map<String, OrderFormReviewer.Outcome>();
        Test.startTest();
        for (String k : cases.keySet()) {
            Test.setMock(HttpCalloutMock.class, cases.get(k));
            results.put(k, OrderFormReviewer.review(row.Id, true));
        }
        Test.stopTest();
        for (String k : results.keySet()) {
            Order_Form_Review__c rev = results.get(k).review;
            System.assertEquals('Failed', rev.Status__c, k + ': ' + rev.Failure__c);
            System.assertNotEquals(null, rev.Failure__c, k);
        }
        return results;
    }

    @isTest
    static void failedReviews_httpRefusalCutOff_areNeverClear() {
        Map<String, ReviewMock> cases = new Map<String, ReviewMock>();
        ReviewMock http = new ReviewMock(); http.statusCode = 529; http.body = '{"type":"error"}'; cases.put('http_529', http);
        ReviewMock refusal = new ReviewMock(); refusal.body = envelope('', 'refusal'); cases.put('refusal', refusal);
        ReviewMock cut = new ReviewMock(); cut.body = envelope('{"findings": [', 'max_tokens'); cases.put('max_tokens', cut);
        Map<String, OrderFormReviewer.Outcome> results = runFailures(cases);
        System.assertEquals('refusal', results.get('refusal').review.Stop_Reason__c);
        System.assertEquals('max_tokens', results.get('max_tokens').review.Stop_Reason__c);
        System.assertEquals(529, results.get('http_529').review.HTTP_Status__c);
    }

    @isTest
    static void failedReviews_malformedAndTimeout_areNeverClear() {
        Map<String, ReviewMock> cases = new Map<String, ReviewMock>();
        ReviewMock garbage = new ReviewMock(); garbage.body = envelope('not json', 'end_turn'); cases.put('malformed', garbage);
        ReviewMock noCoverage = new ReviewMock();
        noCoverage.body = envelope('{"findings": [], "sources_reviewed": [], "gaps": [], "summary": "x"}', 'end_turn');
        cases.put('malformed schema', noCoverage);
        ReviewMock slow = new ReviewMock(); slow.timeout = true; cases.put('timeout', slow);
        Map<String, OrderFormReviewer.Outcome> results = runFailures(cases);
        System.assertEquals('timeout', results.get('timeout').review.Stop_Reason__c);
        System.assert(results.get('malformed schema').review.Failure__c.contains('missing coverage'),
            results.get('malformed schema').review.Failure__c);
    }

    @isTest
    static void noFiles_failsWithoutACallout() {
        reviewerOn();
        Opportunity opp = insertOpp('No Files', null);
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>(), cleanExtraction('Rogo Order Form - Gone'));
        ReviewMock mock = new ReviewMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.Outcome o = OrderFormReviewer.review(row.Id, true);
        Test.stopTest();
        System.assertEquals('Failed', o.review.Status__c);
        System.assertEquals(0, mock.calls);
        System.assertNotEquals(null, o.review.Missing_Required_Sources__c);
    }

    @isTest
    static void missingRequiredSource_andUnreviewedFields_makeItIncomplete() {
        reviewerOn();
        Opportunity opp = insertOpp('Missing Source', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Present');
        Map<String, Object> ex = cleanExtraction('Rogo Order Form - Present');
        // The extraction also read an order form that is no longer attached.
        ((List<Object>) ex.get('Documents')).add(new Map<String, Object>{
            'file' => 'FILE 2 (CURRENT DEAL): Signed Order Form - Removed', 'group' => 'Current', 'class' => 'Order Form' });
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, ex);

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), new Set<String>{ 'Credit_Rate', 'L1:Rogo Seats' }, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.Outcome o = OrderFormReviewer.review(row.Id, true);
        Test.stopTest();
        System.assertEquals('Incomplete', o.review.Status__c);
        System.assert(o.review.Missing_Required_Sources__c.contains('signed order form - removed'), o.review.Missing_Required_Sources__c);
        System.assert(o.review.Unreviewed_Required_Fields__c.contains('Credit_Rate'));
        System.assert(o.review.Unreviewed_Required_Fields__c.contains('L1:Rogo Seats'));
    }

    // =================================================== staleness and reruns

    private static Order_Form_Review__c priorReview(Id extractionId, String status, Map<String, String> v) {
        Order_Form_Review__c r = new Order_Form_Review__c(Extraction__c = extractionId, Status__c = status,
            Mode__c = 'Shadow', Is_Current__c = true, Input_Hash__c = v.get('input'), Source_Hash__c = v.get('source'),
            Prompt_Version__c = v.get('prompt'), Reviewed_At__c = System.now());
        insert r;
        return r;
    }

    @isTest
    static void staleReview_whenTheReviewedValuesChange() {
        reviewerOn();
        Opportunity opp = insertOpp('Stale Values', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Stale');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Stale'));
        Order_Form_Review__c prior = priorReview(row.Id, 'Clear', OrderFormReviewer.versionsOf(row.Id));

        // A change outside the reviewed values (versioning) does not make it stale.
        update new Order_Form_Extraction__c(Id = row.Id, Is_Current__c = false);
        System.assertEquals(false, [SELECT Is_Stale__c FROM Order_Form_Review__c WHERE Id = :prior.Id].Is_Stale__c);

        // A person corrects a value: the review no longer describes the saved row.
        update new Order_Form_Extraction__c(Id = row.Id, Renewal_Terms__c = 'Manual renewal');
        Order_Form_Review__c after = [SELECT Is_Stale__c, Stale_Reason__c, Is_Current__c FROM Order_Form_Review__c WHERE Id = :prior.Id];
        System.assertEquals(true, after.Is_Stale__c);
        System.assert(after.Stale_Reason__c.contains('Renewal_Terms'), after.Stale_Reason__c);
        System.assertEquals(true, after.Is_Current__c, 'still the latest review, but stale');
    }

    @isTest
    static void staleReview_whenAFileGetsANewVersion_thenReviewedAgain() {
        reviewerOn();
        Opportunity opp = insertOpp('Stale Files', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Versions');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Versions'));
        Order_Form_Review__c prior = priorReview(row.Id, 'Clear', OrderFormReviewer.versionsOf(row.Id));
        insert new ContentVersion(ContentDocumentId = doc, Title = 'Rogo Order Form - Versions', PathOnClient = 'v2.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 second version'));

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, false);
        Test.stopTest();
        System.assertEquals(1, mock.calls);
        Order_Form_Review__c old = [SELECT Is_Stale__c, Is_Current__c, Stale_Reason__c FROM Order_Form_Review__c WHERE Id = :prior.Id];
        System.assertEquals(true, old.Is_Stale__c);
        System.assertEquals(false, old.Is_Current__c);
        System.assert(old.Stale_Reason__c.contains('new version'), old.Stale_Reason__c);
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Review__c WHERE Extraction__c = :row.Id AND Is_Current__c = true]);
    }

    @isTest
    static void rerun_skipsWhenUpToDate_andBoundsAttempts() {
        reviewerOn();
        Opportunity opp = insertOpp('Reruns', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Reruns');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Reruns'));
        Map<String, String> v = OrderFormReviewer.versionsOf(row.Id);
        priorReview(row.Id, 'Clear', v);
        ReviewMock mock = new ReviewMock();
        Test.setMock(HttpCalloutMock.class, mock);
        OrderFormReviewer.Outcome upToDate = OrderFormReviewer.review(row.Id, false);
        System.assert(upToDate.skipped.startsWith('Up to date'), upToDate.skipped);
        System.assertEquals(0, mock.calls);

        // Two failed attempts on this version: the sweep stops trying (no correction loop).
        update new Order_Form_Review__c(Id = [SELECT Id FROM Order_Form_Review__c WHERE Extraction__c = :row.Id].Id,
            Status__c = 'Failed');
        priorReview(row.Id, 'Failed', v);
        OrderFormReviewer.Outcome bounded = OrderFormReviewer.review(row.Id, false);
        System.assert(bounded.skipped.contains('Max Attempts'), bounded.skipped);
        System.assertEquals(0, mock.calls);
    }

    @isTest
    static void rerun_keepsHumanDecisionsAndNeverTouchesProducts() {
        reviewerOn();
        Opportunity opp = insertOpp('Human Decisions', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Decisions');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Decisions'));
        // A person's correction on the extraction itself.
        update new Order_Form_Extraction__c(Id = row.Id, Billing_Entity_Name__c = 'Acme Capital Limited');
        Map<String, String> v = OrderFormReviewer.versionsOf(row.Id);
        Order_Form_Review__c prior = priorReview(row.Id, 'Findings', v);
        String fp = OrderFormReviewer.fingerprint('Model', 'Billing_Entity_Name', '', '', 'wrong_value', 'set_value', 'Acme Capital Ltd');
        insert new Order_Form_Review_Finding__c(Review__c = prior.Id, Extraction__c = row.Id, Origin__c = 'Model',
            Field__c = 'Billing_Entity_Name', Category__c = 'wrong_value', Correction_Action__c = 'Set Value',
            Proposed_Value__c = 'Acme Capital Ltd', Status__c = 'Dismissed', Disposition_Note__c = 'Legal name confirmed by AP.',
            Fingerprint__c = fp);
        Set<Id> lineIds = new Map<Id, Order_Form_Line__c>([SELECT Id FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]).keySet();

        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>{
            finding('Billing_Entity_Name', '', '', 'wrong_value', 'set_value', 'Acme Capital Ltd', '') }, null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, true);
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Order_Form_Review__c WHERE Extraction__c = :row.Id]);
        System.assertEquals(false, [SELECT Is_Current__c FROM Order_Form_Review__c WHERE Id = :prior.Id].Is_Current__c);
        Order_Form_Review_Finding__c again = [SELECT Status__c, Disposition_Note__c, Review_Is_Current__c
            FROM Order_Form_Review_Finding__c WHERE Extraction__c = :row.Id AND Review__r.Is_Current__c = true AND Origin__c = 'Model'];
        System.assertEquals('Dismissed', again.Status__c, 'the person\'s decision carries over');
        System.assertEquals('Legal name confirmed by AP.', again.Disposition_Note__c);
        System.assertEquals(true, again.Review_Is_Current__c);
        System.assertEquals('Acme Capital Limited',
            [SELECT Billing_Entity_Name__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Billing_Entity_Name__c,
            'the human correction is not overwritten');
        System.assertEquals(lineIds, new Map<Id, Order_Form_Line__c>([SELECT Id FROM Order_Form_Line__c WHERE Extraction__c = :row.Id]).keySet(),
            'no product lines recreated or duplicated');
    }

    // ===================================================== deterministic checks

    @isTest
    static void derivedFinalValues_acceptedWhenRawFieldsAreNull_unsupportedOnesFail() {
        Opportunity opp = insertOpp('Derived', null);
        Map<String, Object> ex = cleanExtraction('Derived Order Form');
        ex.remove('Total_Contract_Value');   // no TCV on the paper
        ex.put('Value_Basis', 'Monthly');
        ex.put('Recurring_Fees_Stated', 9583.33);
        ex.put('License_Fees', 5750);
        ex.put('Credit_Commit_Fee', null);
        ex.put('Line_Items', null);
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        System.assertEquals(null, row.Total_Contract_Value__c, 'no TCV invented');
        System.assertNotEquals(null, row.Contract_End_Date__c, 'end date derived');
        System.assertEquals('Derived', row.End_Date_Source__c);
        Map<String, Object> raw = OrderFormExtractionJob.replyJson(row.Raw_Response__c);
        OrderFormValidator.Result ok = OrderFormValidator.validate(row, new List<OrderFormLines.Line>(), raw, null);
        for (OrderFormValidator.Check c : ok.checks) {
            System.assert(!(c.name == 'provenance' && c.status == 'Fail'), 'derived values are supported: ' + c.message);
        }
        // TCV provenance regression: a TCV with no stated value and no derivation is unsupported.
        row.Total_Contract_Value__c = 115000;
        OrderFormValidator.Result bad = OrderFormValidator.validate(row, new List<OrderFormLines.Line>(), raw, null);
        Boolean flagged = false;
        for (OrderFormValidator.Check c : bad.checks) {
            if (c.name == 'provenance' && c.status == 'Fail' && c.field == 'Total_Contract_Value') flagged = true;
        }
        System.assert(flagged, JSON.serialize(bad.checks));
    }

    @isTest
    static void optionalAndContingentLines_doubleMultiplication_currency() {
        List<OrderFormLines.Line> lines = new List<OrderFormLines.Line>();
        OrderFormLines.Line overage = new OrderFormLines.Line();
        overage.lineNo = 1; overage.product = 'Paid Credits'; overage.label = 'Overage credits'; overage.amount = 4000;
        overage.recurring = true; overage.annualAmount = 4000; overage.quote = 'Overage fees of $0.04 per Credit';
        OrderFormLines.Line doubled = new OrderFormLines.Line();
        doubled.lineNo = 2; doubled.product = 'Rogo Seats'; doubled.label = 'Seats'; doubled.quantity = 10;
        doubled.unitPrice = 1000; doubled.amount = 100000; doubled.basis = 'Annual';
        lines.add(overage);
        lines.add(doubled);
        System.assertEquals('Fail', OrderFormValidator.checkCommitted(lines)[0].status);
        System.assertEquals('L1:Paid Credits', OrderFormValidator.checkCommitted(lines)[0].productRef);
        List<OrderFormValidator.Check> arithmetic = OrderFormValidator.checkLineArithmetic(lines);
        System.assertEquals(1, arithmetic.size());
        System.assertEquals('Fail', arithmetic[0].status);
        System.assert(arithmetic[0].message.contains('twice'), arithmetic[0].message);
        System.assertEquals('Fail', OrderFormValidator.checkCurrency(new Order_Form_Extraction__c(),
            new Map<String, Object>{ 'Currency' => 'GBP' }, lines)[0].status);
    }

    // ======================================================== Peel Hunt regressions

    @isTest
    static void peelHunt_renewalHasNoInventedDefault() {
        Opportunity opp = insertOpp('Peel Hunt Renewal', null);
        Map<String, Object> ex = cleanExtraction('PH Order Form');
        ex.put('Renewal_Terms', 'Manual renewal');
        ((Map<String, Object>) ex.get('Extract_Evidence')).put('Renewal_Terms', quote('MSA 15(a)',
            'The Agreement will automatically renew in accordance with the Agreement at Rogo\'s then-current list pricing '
            + 'unless otherwise mutually agreed.'));
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        System.assertEquals(null, row.Renewal_Terms__c, 'no 30-day default');
        System.assert(row.Extraction_Issues__c.contains('[enum_gap] Renewal_Terms: Auto-renews; it states no non-renewal notice period'),
            row.Extraction_Issues__c);

        // The row saved before this change: the validator flags the default.
        Order_Form_Extraction__c old = row.clone(false, true);
        old.Renewal_Terms__c = 'Auto-renew (30-day)';
        old.Extract_Evidence__c = JSON.serialize(new Map<String, Object>{ 'Renewal_Terms' => new Map<String, Object>{
            'quote' => 'The Agreement will automatically renew ...', 'derived' => 'Model answered Manual renewal, but its '
            + 'quote renews automatically; no notice period stated, so 30-day.' } });
        List<OrderFormValidator.Check> checks = OrderFormValidator.checkRenewal(old, OrderFormValidator.evidenceOf(old, null));
        System.assertEquals('Fail', checks[0].status, checks[0].message);

        // A price-increase notice is not the non-renewal notice.
        System.assertEquals(30, OrderFormExtractionJob.statedNonRenewalDays('Rogo will give sixty (60) days notice of any '
            + 'price increase. The Agreement renews automatically unless either party gives notice of non-renewal at '
            + 'least thirty (30) days prior to the end of the term.'));
        System.assertEquals(null, OrderFormExtractionJob.statedNonRenewalDays('Fees may increase on sixty (60) days notice.'));
    }

    @isTest
    static void peelHunt_emailPunctuationIsCaught() {
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Billing_Contact_Email__c = 'accountspayable@example.co.uk');
        Map<String, Object> evidence = new Map<String, Object>{
            'Billing_Contact_Email' => quote('Order Form', 'Accounts Payable: accounts-payable@example.co.uk') };
        List<OrderFormValidator.Check> checks = OrderFormValidator.checkEmails(row, null, evidence);
        System.assertEquals('Fail', checks[0].status);
        System.assert(checks[0].message.contains('accounts-payable@example.co.uk'), checks[0].message);
        // The address as written passes.
        row.Billing_Contact_Email__c = 'accounts-payable@example.co.uk';
        System.assert(OrderFormValidator.checkEmails(row, null, evidence).isEmpty());
    }

    @isTest
    static void peelHunt_truncatedTextIsKeptInFull() {
        Opportunity opp = insertOpp('Peel Hunt Truncation', null);
        String consequence = 'If Customer reasonably objects to a new Subprocessor on data protection grounds, the parties '
            + 'will discuss the objection in good faith; if they cannot resolve it within thirty (30) days, Customer may '
            + 'terminate the affected Services on written notice and receive a pro-rata refund of prepaid fees for the '
            + 'remainder of the Subscription Period, which is its sole and exclusive remedy for the objection.';
        System.assert(consequence.length() > 255, 'fixture is longer than the field: ' + consequence.length());
        Map<String, Object> ex = cleanExtraction('PH Order Form');
        ex.put('Subprocessor_Objection_Consequence', consequence);
        ex.put('Renewal_Fee_Escalator_Percent', 5);
        ex.put('Renewal_Fee_Escalator_Terms', 'fees increase by the greater of 5% or CPI');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        insert row;
        Order_Form_Extraction__c saved = [SELECT Subprocessor_Objection_Consequence__c, Full_Text_Values__c, Derived_Fields__c,
                                          Renewal_Fee_Escalator_Terms__c FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals(255, saved.Subprocessor_Objection_Consequence__c.length());
        System.assertEquals(consequence, ((Map<String, Object>) JSON.deserializeUntyped(saved.Full_Text_Values__c))
            .get('Subprocessor_Objection_Consequence__c'));
        System.assert(saved.Derived_Fields__c.contains('Subprocessor_Objection_Consequence(truncated)'), saved.Derived_Fields__c);
        System.assertEquals('fees increase by the greater of 5% or CPI', saved.Renewal_Fee_Escalator_Terms__c);

        // The row saved before this change kept no full value: the validator says so.
        Order_Form_Extraction__c old = new Order_Form_Extraction__c(
            Subprocessor_Objection_Consequence__c = consequence.left(255));
        List<OrderFormValidator.Check> checks = OrderFormValidator.checkCapacity(old,
            new Map<String, Object>{ 'Subprocessor_Objection_Consequence' => consequence });
        System.assertEquals('Fail', checks[0].status, checks[0].message);
        Order_Form_Extraction__c kept = new Order_Form_Extraction__c(
            Subprocessor_Objection_Consequence__c = saved.Subprocessor_Objection_Consequence__c,
            Full_Text_Values__c = saved.Full_Text_Values__c);
        System.assert(OrderFormValidator.checkCapacity(kept,
            new Map<String, Object>{ 'Subprocessor_Objection_Consequence' => consequence }).isEmpty());
    }

    // ===================================================== pilot fee, online terms

    @isTest
    static void pilotFee_isTheTrialPriceNotArr() {
        // No opportunity: the extractor takes the deal type from the opportunity, and a test
        // opportunity gets the org's default Type - here the paper's "Pilot" must stand.
        Map<String, Object> ex = cleanExtraction('Pilot Agreement');
        ex.put('Type', 'Pilot');
        ex.remove('Contract_Length_Months');
        ex.put('Contract_Length_Days', 32);
        ex.put('Value_Basis', 'Term');
        ex.put('License_Fees', 7700);
        ex.put('Recurring_Fees_Stated', 7700);
        ex.put('Total_Contract_Value', 7700);
        ex.put('Credit_Commit_Fee', null);
        ex.put('Credits_Purchased', null);
        ex.put('Line_Items', new List<Object>{ new Map<String, Object>{ 'product' => 'Rogo Seats', 'label' => 'Pilot Fee',
            'quantity' => 5, 'amount' => 7700, 'basis' => 'Term', 'quote' => 'Pilot Fee: USD $7,700 for the Pilot Period' } });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(null, new List<Id>(), extractionReply(ex));
        System.assertEquals('Pilot', row.Type__c);
        System.assertEquals(null, row.Annual_Recurring_Revenue__c, 'a 32-day pilot fee is not annualised into ARR');
        System.assertEquals(7700, row.Trial_Price__c);
        System.assertEquals(true, row.Paid_Trial__c);
        System.assert(row.Derived_Fields__c.contains('Annual_Recurring_Revenue'), row.Derived_Fields__c);
        List<OrderFormLines.Line> lines = OrderFormLines.fromJson(row.Line_Items__c);
        for (OrderFormLines.Line l : lines) {
            System.assertNotEquals('Rogo Seats', l.product, 'no recurring seats on a pilot: ' + row.Line_Items__c);
        }
        System.assertEquals(null, row.Lines_Recurring_Annual__c);
        System.assertEquals('Success', row.Extraction_Status__c, 'dates and the stated fee meet the minimums');
    }

    // Serves Rogo's terms page for GETs and the review reply for the model request.
    public class SiteAndReviewMock implements HttpCalloutMock {
        public String reviewBody;
        public String lastPost;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            if (req.getMethod() == 'GET') {
                r.setBody('<html><body><h1>Terms &amp; Conditions</h1><p>Last updated: March 3, 2026</p>'
                    + ('<p>14. Renewal. Either party may give notice of non-renewal at least thirty (30) days before the '
                    + 'end of the then-current term.</p>').repeat(30) + '</body></html>');
                return r;
            }
            lastPost = req.getBody();
            r.setBody(reviewBody);
            return r;
        }
    }

    @isTest
    static void review_readsTheOnlineTermsAndRecordsTheVersion() {
        reviewerOn();
        OrderFormReviewer.settingsOverride.Standard_Terms_URL__c = 'https://rogo.com/legal/terms-and-conditions';
        RogoStandardTerms.fetchInTests = true;
        RogoStandardTerms.subprocessorCsv = '"Company Name","Purpose","Location","Additional Details","Created At"\n'
            + '"OpenAI","OpenAI Enterprise LLM Inference API","United States","","May 15, 2025"\n';
        Opportunity opp = insertOpp('Terms Review', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Terms');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Terms'));
        SiteAndReviewMock mock = new SiteAndReviewMock();
        mock.reviewBody = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormReviewer.reviewAndSave(row.Id, true);
        Test.stopTest();
        List<Object> sys = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(mock.lastPost)).get('system');
        System.assertEquals(3, sys.size(), 'review prompt, field definitions, Rogo terms');
        System.assert(String.valueOf(((Map<String, Object>) sys[2]).get('text')).contains('last updated March 3, 2026'));
        Order_Form_Review__c rev = [SELECT Sources_Sent__c FROM Order_Form_Review__c WHERE Extraction__c = :row.Id];
        System.assert(rev.Sources_Sent__c.contains('Rogo Terms & Conditions (online'), rev.Sources_Sent__c);
        System.assert(rev.Sources_Sent__c.contains('Rogo Subprocessor List (trust center export'), rev.Sources_Sent__c);
        System.assert(String.valueOf(((Map<String, Object>) sys[2]).get('text')).contains('- OpenAI | Purpose: OpenAI '
            + 'Enterprise LLM Inference API'));
    }

    @isTest
    static void emailCase_isNotAFinding() {
        Order_Form_Extraction__c saved = new Order_Form_Extraction__c(Billing_Contact_Email__c = 'finance@example.com',
            Raw_Response__c = '{}');
        Order_Form_Extraction__c fresh = new Order_Form_Extraction__c(Billing_Contact_Email__c = 'Finance@example.com');
        System.assert(OrderFormValidator.checkSavedVsProposed(saved, fresh).isEmpty(), 'case-only email difference');
        // No quote to compare (older extraction): no warning either.
        System.assert(OrderFormValidator.checkEmails(saved, null, new Map<String, Object>()).isEmpty());
    }

    // ===================================================== extraction changes

    @isTest
    static void documentComponents_doNotHideAnOrderForm() {
        Opportunity opp = insertOpp('Components', null);
        Map<String, Object> ex = cleanExtraction('Combined Agreement');
        ex.put('Documents', new List<Object>{ new Map<String, Object>{
            'file' => 'FILE 1 (CURRENT DEAL): Combined Agreement', 'group' => 'Current', 'class' => 'MSA',
            'components' => new List<Object>{ 'MSA', 'Order Form', 'DPA' } } });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), extractionReply(ex));
        System.assertEquals('Success', row.Extraction_Status__c, 'the order form component carries the economics');
        System.assert(row.Document_Classes__c.contains('=> MSA (contains: MSA, Order Form, DPA)'), row.Document_Classes__c);
        System.assertEquals(115000, row.Annual_Recurring_Revenue__c);
    }

    @isTest
    static void schema_promptAndReplyValidation() {
        List<String> keys = OrderFormExtractionJob.promptSchemaKeys();
        for (String k : new List<String>{ 'Issues', 'Currency', 'Ramp_Schedule', 'Free_Credits', 'Credit_Commit_Fee',
                'Renewal_Fee_Escalator_Terms', 'Line_Items', 'Extract_Evidence' }) {
            System.assert(keys.contains(k), k + ' missing from the prompt schema');
        }
        System.assert(!keys.contains('Pricing_Structure'), 'Apex computes Pricing_Structure');
        String prompt = OrderFormExtractionJob.extractionPrompt();
        System.assert(!prompt.contains('without a notice period -> Renewal_Terms = "Auto-renew (30-day)"'));
        System.assert(!prompt.contains('The standard Rogo-paper clause is 30 days'));
        System.assert(!prompt.contains('use the email\'s figures over the original Order Form\'s figures'));

        // Every object in the response schema is closed and fully required.
        Map<String, Object> s = OrderFormReviewer.responseSchema(OrderFormReviewCoverage.allowedFields(keys));
        assertClosed(s);

        Set<String> allowed = new Set<String>(OrderFormReviewCoverage.allowedFields(keys));
        Map<String, Object> reply = new Map<String, Object>{
            'findings' => new List<Object>{
                finding('Not_A_Field', '', '', 'wrong_value', 'none', '', ''),
                finding('', 'Rogo Seats', 'quantity', 'wrong_value', 'none', '', ''),
                finding('Seat_Licenses', '', '', 'wrong_value', 'set_value', '', ''),
                finding('Seat_Licenses', '', '', 'wrong_value', 'unresolved', '', '') },
            'coverage' => new Map<String, Object>{ 'verified' => new List<Object>(), 'not_in_sources' => new List<Object>(),
                'not_reviewed' => new List<Object>() },
            'sources_reviewed' => new List<Object>(), 'gaps' => new List<Object>(), 'summary' => 'x' };
        String problems = String.join(OrderFormReviewer.validateReply(reply, allowed), ' | ');
        System.assert(problems.contains('unknown field "Not_A_Field"'), problems);
        System.assert(problems.contains('is not L<n>:<product>'), problems);
        // A thin correction is normalised, not a failed review (SC Capital).
        System.assert(!problems.contains('finding 3') && !problems.contains('finding 4'), problems);
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Seat_Licenses__c = 5);
        Order_Form_Review_Finding__c noValue = OrderFormReviewer.modelFinding(
            finding('Seat_Licenses', '', '', 'wrong_value', 'set_value', '', ''), row, new List<OrderFormLines.Line>());
        System.assertEquals('Unresolved', noValue.Correction_Action__c);
        System.assert(noValue.Unresolved_Reason__c.contains('no value'), noValue.Unresolved_Reason__c);
        Order_Form_Review_Finding__c noReason = OrderFormReviewer.modelFinding(
            finding('Seat_Licenses', '', '', 'wrong_value', 'unresolved', '', ''), row, new List<OrderFormLines.Line>());
        System.assertEquals('Unresolved', noReason.Correction_Action__c);
        System.assertNotEquals(null, noReason.Unresolved_Reason__c);
        System.assertEquals('Clear', OrderFormReviewer.statusFor(false, new List<String>(), new List<String>(), 0,
            new OrderFormValidator.Result()));
        System.assertEquals('Failed', OrderFormReviewer.statusFor(true, new List<String>(), new List<String>(), 0,
            new OrderFormValidator.Result()));
    }

    private static void assertClosed(Object node) {
        if (node instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) node;
            if (m.get('type') == 'object') {
                System.assertEquals(false, m.get('additionalProperties'));
                System.assertEquals(((Map<String, Object>) m.get('properties')).keySet(),
                    new Set<String>((List<String>) m.get('required')));
            }
            for (Object v : m.values()) assertClosed(v);
        } else if (node instanceof List<Object>) {
            for (Object v : (List<Object>) node) assertClosed(v);
        }
    }

    // ===================================================== entry points

    @isTest
    static void buttonAndSweep_reviewInTheBackground() {
        reviewerOn();
        Opportunity opp = insertOpp('Button', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Button');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Button'));
        row = [SELECT Id, Extracted_At__c FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        OrderFormReviewAction.Request req = new OrderFormReviewAction.Request();
        req.recordId = row.Id;
        Test.startTest();
        String msg = OrderFormReviewAction.run(new List<OrderFormReviewAction.Request>{ req })[0].message;
        Test.stopTest();
        System.assert(msg.startsWith('Review started'), msg);
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Review__c WHERE Extraction__c = :row.Id AND Is_Current__c = true]);
        System.assert(OrderFormReviewBatch.targetWhere(30).contains('LAST_N_DAYS:30'));
    }

    @isTest
    static void sweep_reviewsCurrentExtractionsWithoutAReview() {
        reviewerOn();
        Opportunity opp = insertOpp('Sweep', null);
        Id doc = attachFile(opp.Id, 'Rogo Order Form - Sweep');
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>{ doc }, cleanExtraction('Rogo Order Form - Sweep'));
        ReviewMock mock = new ReviewMock();
        mock.body = reviewReply(row, new List<Object>(), null, null);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Database.executeBatch(new OrderFormReviewBatch(30), 1);
        Test.stopTest();
        Order_Form_Review__c rev = [SELECT Status__c, Checks__c FROM Order_Form_Review__c WHERE Extraction__c = :row.Id];
        System.assertEquals('Clear', rev.Status__c, 'fail: ' + String.join(checkNames(rev.Checks__c, 'Fail'), ', '));
    }

    @isTest
    static void reviewerOff_runsNothing() {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Off');
        Opportunity opp = insertOpp('Off', null);
        Order_Form_Extraction__c row = saveExtraction(opp.Id, new List<Id>(), cleanExtraction('Rogo Order Form - Off'));
        System.assert(OrderFormReviewer.review(row.Id, true).skipped.contains('off'));
        System.assert(OrderFormReviewJob.enqueue(new List<Id>{ row.Id }, false).contains('off'));
        OrderFormReviewer.save(OrderFormReviewer.review(row.Id, true));
        Test.startTest();
        Database.executeBatch(new OrderFormReviewBatch(30), 1);   // the sweep finds nothing to do
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Order_Form_Review__c]);
    }

    @isTest
    static void sweep_canBeScheduled() {
        reviewerOn();
        Test.startTest();
        String jobId = System.schedule('Order form review sweep (test)', '0 0 0 1 1 ? 2099', new OrderFormReviewBatch());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }
}
