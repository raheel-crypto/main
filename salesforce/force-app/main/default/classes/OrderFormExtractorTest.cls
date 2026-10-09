@isTest
private class OrderFormExtractorTest {

    // Builds a Messages API response whose text block is the extraction JSON.
    // Unless a test sets them, it supplies what a real order form carries - an
    // Order Form in Documents, a start date + 12-month term, and a TCV - so a test
    // about one field still yields a Success row under the Success gate. Tests of
    // the gate itself use makeAnthropicResponseRaw.
    private static String makeAnthropicResponse(Map<String, Object> extractedFields) {
        Map<String, Object> f = new Map<String, Object>(extractedFields);
        if (!f.containsKey('Documents')) {
            f.put('Documents', new List<Object>{ new Map<String, Object>{
                'file' => 'FILE 1 (CURRENT DEAL): signed__OrderForm', 'group' => 'Current', 'class' => 'Order Form' } });
        }
        if (!f.containsKey('Contract_Start_Date') && !f.containsKey('Contract_End_Date')) {
            f.put('Contract_Start_Date', '2026-01-01');
            if (!f.containsKey('Contract_Length_Months') && !f.containsKey('Contract_Length_Days')) {
                f.put('Contract_Length_Months', 12);
            }
        }
        Boolean hasEconomics = false;
        for (String k : new List<String>{ 'Annual_Recurring_Revenue', 'Recurring_Fees_Stated', 'Incremental_Recurring_Fees',
                'Total_Contract_Value', 'License_Fees', 'Platform_Connection_Fee', 'Trial_Price', 'Unit_Price' }) {
            if (f.containsKey(k)) hasEconomics = true;
        }
        if (!hasEconomics) f.put('Total_Contract_Value', 10000);
        return makeAnthropicResponseRaw(f);
    }

    private static String makeAnthropicResponseRaw(Map<String, Object> extractedFields) {
        Map<String, Object> textBlock = new Map<String, Object>{
            'type' => 'text',
            'text' => JSON.serialize(extractedFields)
        };
        return JSON.serialize(new Map<String, Object>{
            'id' => 'msg_test',
            'type' => 'message',
            'role' => 'assistant',
            'model' => 'claude-sonnet-5',
            'content' => new List<Object>{ textBlock },
            'stop_reason' => 'end_turn',
            'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 200 }
        });
    }

    public class MockAnthropic implements HttpCalloutMock {
        public Integer statusCode = 200;
        public String responseBody;
        public Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse r = new HttpResponse();
            r.setStatusCode(statusCode);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(responseBody);
            return r;
        }
    }

    public class GarbageMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'content' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'text', 'text' => 'not valid json {{' }
                }
            }));
            return r;
        }
    }

    // The org has a validation rule that blocks creating an Opportunity at a
    // closed stage ("You cannot create a closed Won Opportunity. Start at
    // stage 1."). The rule is bypassed for holders of the Bypass_Validations
    // custom permission, so grant it to the running test user. This runs in its
    // own transaction (@testSetup), which (a) commits the assignment before each
    // test method so the permission cache reflects it, and (b) keeps the
    // setup-object DML from colliding (MIXED_DML) with the tests' record DML.
    // Defensive: if the custom permission isn't present in this org, do nothing
    // - a sandbox without the rule simply doesn't need the bypass.
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'OFE_Test_Bypass', Label = 'OFE Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(
            AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id
        );
    }

    // Proven-open stage in this org (other tests insert opps here without
    // tripping the closed-stage rule). Only used as the intermediate hop when
    // the bypass permission isn't active.
    private static final String SAFE_OPEN_STAGE = '4 - Proposal';

    // Inserts an Opportunity even when it targets a closed stage. If the running
    // user holds Bypass_Validations the direct insert is allowed; otherwise we
    // insert at an open stage and then update to the target - the "cannot create
    // a closed Won" rule fires on create only, and this is how a deal
    // legitimately reaches Closed Won.
    private static void insertOppSafely(Opportunity o) {
        if (FeatureManagement.checkPermission('Bypass_Validations')) {
            insert o;
            return;
        }
        String target = o.StageName;
        o.StageName = SAFE_OPEN_STAGE;
        insert o;
        if (target != SAFE_OPEN_STAGE) {
            o.StageName = target;
            update o;
        }
    }

    private static void insertOppsSafely(List<Opportunity> os) {
        if (FeatureManagement.checkPermission('Bypass_Validations')) {
            insert os;
            return;
        }
        List<String> targets = new List<String>();
        for (Opportunity o : os) { targets.add(o.StageName); o.StageName = SAFE_OPEN_STAGE; }
        insert os;
        List<Opportunity> toClose = new List<Opportunity>();
        for (Integer i = 0; i < os.size(); i++) {
            if (targets[i] != SAFE_OPEN_STAGE) { os[i].StageName = targets[i]; toClose.add(os[i]); }
        }
        if (!toClose.isEmpty()) update toClose;
    }

    private static Opportunity insertOpp(String name, String stage) {
        Opportunity o = new Opportunity(Name = name, StageName = stage, CloseDate = Date.today());
        insertOppSafely(o);
        return o;
    }

    private static void attachSignedFile(Id parentId, String title) {
        attachSignedFile(parentId, title, 'pdf', Blob.valueOf('%PDF-1.4 fake pdf bytes for unit test'));
    }

    private static void attachSignedFile(Id parentId, String title, String extension, Blob data) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.' + extension,
            VersionData = data,
            FirstPublishLocationId = parentId
        );
        insert cv;
    }

    private static Order_Form_Extraction__c latestExtractionFor(Id oppId) {
        List<Order_Form_Extraction__c> rows = [
            SELECT Id, Extraction_Status__c, HTTP_Status_Code__c, Raw_Response__c, Error_Message__c,
                   Extracted_JSON__c, File_Name__c, Content_Document_Id__c, Model__c, Extracted_At__c,
                   Is_Amendment__c, Type__c,
                   Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Months__c,
                   Seat_Licenses__c, License_Fees__c, Platform_Connection_Fee__c, Professional_Service_Fees__c,
                   Total_Contract_Value__c, Annual_Recurring_Revenue__c,
                   Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
                   Billing_Contact_Email__c, ELA__c, Paid_Trial__c, Trial_Price__c, Pilot_Success_Criteria__c,
                   Credits_Purchased__c, Credits_Period__c, Special_Terms__c,
                   Applied_To_Opportunity__c
            FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :oppId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    // ===== Invocable (file lookup) =====

    @isTest
    static void noDocumentFound_returnsStatus() {
        Opportunity opp = insertOpp('No Doc Opp', '4 - Proposal');
        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('NoDocumentFound', results[0].status);
        System.assertEquals(0, [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id]);
    }

    @isTest
    static void bulk_invocablePreservesOrder() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 4; i++) {
            opps.add(new Opportunity(Name = 'Bulk ' + i, StageName = '4 - Proposal', CloseDate = Date.today()));
        }
        insert opps;
        for (Integer i = 0; i < opps.size(); i++) {
            if (Math.mod(i, 2) == 0) attachSignedFile(opps[i].Id, 'signed__Bulk_' + i);
        }

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{ 'Type' => 'New Business', 'Seat_Licenses' => 7 });

        List<OrderFormExtractor.Request> reqs = new List<OrderFormExtractor.Request>();
        for (Opportunity o : opps) {
            OrderFormExtractor.Request r = new OrderFormExtractor.Request();
            r.opportunityId = o.Id;
            reqs.add(r);
        }

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(reqs);
        Test.stopTest();

        System.assertEquals(4, results.size());
        for (Integer i = 0; i < results.size(); i++) {
            String expected = Math.mod(i, 2) == 0 ? 'Enqueued' : 'NoDocumentFound';
            System.assertEquals(expected, results[i].status, 'Result ' + i);
        }
    }

    // ===== Extraction Queueable =====

    @isTest
    static void extractionJob_includesPngImagesAlongsidePdfs() {
        // A PNG screenshot of a confirmation email lives alongside the PDF
        // order form. Both should be sent to Anthropic in one callout.
        Opportunity opp = insertOpp('Arcano Mixed', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');
        // Fake PNG bytes - real signature isn't required for the mock path.
        attachSignedFile(opp.Id, 'signed__email_confirmation', 'png',
            Blob.valueOf('fake png bytes for unit test'));

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 35,
            'License_Fees' => 100000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        System.assertEquals('Enqueued', results[0].status);
        System.assertEquals(2, results[0].documentCount, 'PDF + PNG should both be picked up');

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(35, row.Seat_Licenses__c);
        System.assertEquals(1, mock.callCount, 'Single Anthropic call carries PDF + image blocks');
        System.assert(row.File_Name__c.contains('OrderForm') && row.File_Name__c.contains('confirmation'),
            'Both file titles should appear in File_Name__c: ' + row.File_Name__c);
    }

    @isTest
    static void extractionJob_populatesPackageAndCreditFields() {
        Opportunity opp = insertOpp('Saxenhammer', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        // Credit-commit deal, no overcommit obligation, no explicit throttling,
        // no Unlimited Lite / free Max/Mid. Team package.
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Package_Tier' => 'Team',
            'Credit_Commit' => true,
            'Credit_Overcommit_Obligation' => false,
            'Rate_Limitable_By_Rogo' => null,
            'Rate_Limit_Terms' => null,
            'Unlimited_Lite_Stated' => null,
            'Free_Max_Mid_Stated' => null,
            'Credits_Purchased' => 1400000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Package_Tier__c, Credit_Commit__c, Credit_Overcommit_Obligation__c,
                   Rate_Limitable__c, Rate_Limit_Notes__c,
                   Unlimited_Lite__c, Free_Max_Mid_Credits__c, Free_Max_Mid_Amount__c,
                   Credits_Purchased__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals('Team', row.Package_Tier__c);
        System.assertEquals(true, row.Credit_Commit__c);
        System.assertEquals(false, row.Credit_Overcommit_Obligation__c);
        System.assertEquals('Not specified', row.Rate_Limitable__c);
        System.assertEquals(null, row.Rate_Limit_Notes__c);
        System.assertEquals('Not specified', row.Unlimited_Lite__c, 'Non-enterprise + silent -> Not specified');
        System.assertEquals('Not specified', row.Free_Max_Mid_Credits__c);
        System.assertEquals(1400000, row.Credits_Purchased__c);
    }

    @isTest
    static void extractionJob_infersEnterpriseFreebies() {
        Opportunity opp = insertOpp('Big Bank Enterprise', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Package_Tier' => 'Enterprise',
            'Credit_Commit' => false,
            'Rate_Limitable_By_Rogo' => true,
            'Rate_Limit_Terms' => 'Unlimited requests per day but capped at 10 concurrent queries.',
            'Unlimited_Lite_Stated' => null,
            'Free_Max_Mid_Stated' => null
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Package_Tier__c, Rate_Limitable__c, Rate_Limit_Notes__c,
                   Unlimited_Lite__c, Free_Max_Mid_Credits__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals('Enterprise', row.Package_Tier__c);
        System.assertEquals('Yes', row.Rate_Limitable__c);
        System.assert(row.Rate_Limit_Notes__c != null && row.Rate_Limit_Notes__c.contains('concurrent'),
            'Rate_Limit_Notes__c should capture the language: ' + row.Rate_Limit_Notes__c);
        System.assertEquals('Inferred (Enterprise)', row.Unlimited_Lite__c);
        System.assertEquals('Inferred (Enterprise)', row.Free_Max_Mid_Credits__c);
    }

    @isTest
    static void derivePricingStructure_truthTable() {
        // Credit-based path (dominates throttling).
        System.assertEquals('Seats: Credit-Based Usage',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = false, Credit_Commit__c = true)));
        System.assertEquals('ELA: Credit-Based Usage',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = true, Credit_Commit__c = true)));
        // Credits_Purchased triggers credit-based even if Credit_Commit is false.
        System.assertEquals('Seats: Credit-Based Usage',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = false, Credit_Commit__c = false, Credits_Purchased__c = 100000)));

        // Unlimited paths.
        System.assertEquals('Seats: Unlimited Usage, No Throttling',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = false, Credit_Commit__c = false, Rate_Limitable__c = 'Not specified')));
        System.assertEquals('Seats: Unlimited Usage, with Throttling',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = false, Credit_Commit__c = false, Rate_Limitable__c = 'Yes')));
        System.assertEquals('ELA: Unlimited Usage, No Throttling',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = true, Credit_Commit__c = false, Rate_Limitable__c = 'No')));
        System.assertEquals('ELA: Unlimited Usage, with Throttling',
            OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = true, Credit_Commit__c = false, Rate_Limitable__c = 'Yes')));
    }

    @isTest
    static void extractionJob_emailConfirmationBasics() {
        // Type set explicitly: the opp's Type overrides the model's, and a blank
        // Type can be defaulted by the org to a non-amendment value.
        Opportunity opp = new Opportunity(Name = 'Seat Add Upsell', StageName = 'Closed Won',
            CloseDate = Date.today(), Type = 'Upsell');
        insertOppSafely(opp);
        // A PNG screenshot of the confirming email, prefixed signed__.
        attachSignedFile(opp.Id, 'signed__email_add_users', 'png', Blob.valueOf('fake png'));

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Source_Document_Type' => 'Email Confirmation',
            'Type' => 'Upsell',
            'Seats_Added' => 4,
            'Seat_Licenses' => 5,
            'Named_Users' => 'Sean Kensil\nTatum McKelvey\nMike De Mayo\nAnthony Megaro\nOne User TBD',
            'Requested_By_Name' => 'Mike De Mayo',
            'Requested_By_Email' => 'mike@customer.com',
            'Billing_Entity_Name' => 'Customer Co',
            // Commercial/legal fields intentionally null on an email.
            'License_Fees' => null,
            'Annual_Recurring_Revenue' => null,
            'Payment_Terms' => null
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Source_Document_Type__c, Seats_Added__c, Seat_Licenses__c, Named_Users__c,
                   Requested_By_Name__c, Requested_By_Email__c, Billing_Entity_Name__c,
                   License_Fees__c, Annual_Recurring_Revenue__c, Payment_Terms__c,
                   Extraction_Status__c, Resulting_Seats__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        // An email confirmation states seats but no ARR/TCV: it is captured, but
        // not as a Success (Success requires dates and ARR or TCV).
        System.assertEquals('Incomplete', row.Extraction_Status__c);
        System.assertEquals(5, row.Resulting_Seats__c, 'Stated total seats -> Resulting_Seats');
        System.assertEquals('Email Confirmation', row.Source_Document_Type__c);
        System.assertEquals(4, row.Seats_Added__c);
        System.assertEquals(5, row.Seat_Licenses__c);
        System.assert(row.Named_Users__c.contains('Sean Kensil') && row.Named_Users__c.contains('One User TBD'),
            'Named users should be captured incl. placeholder: ' + row.Named_Users__c);
        System.assertEquals('Mike De Mayo', row.Requested_By_Name__c);
        System.assertEquals('mike@customer.com', row.Requested_By_Email__c);
        System.assertEquals(null, row.License_Fees__c, 'Email has no fees');
        System.assertEquals(null, row.Payment_Terms__c, 'Email has no payment terms');
    }

    @isTest
    static void extractionJob_populatesBillingEntity() {
        Opportunity opp = insertOpp('Macquarie Expansion', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__MacCap_Order');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Upsell',
            'Billing_Entity_Name' => 'Macquarie Group Services Australia Pty Ltd',
            'Billing_Entity_Reg_Id' => 'ABN 53 116 467 031',
            'Billing_Entity_Address' => '50 Martin Place, Sydney NSW 2000',
            'Billing_Entity_Jurisdiction' => 'Australia'
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Billing_Entity_Name__c, Billing_Entity_Reg_Id__c,
                   Billing_Entity_Address__c, Billing_Entity_Jurisdiction__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals('Macquarie Group Services Australia Pty Ltd', row.Billing_Entity_Name__c);
        System.assertEquals('ABN 53 116 467 031', row.Billing_Entity_Reg_Id__c);
        System.assertEquals('50 Martin Place, Sydney NSW 2000', row.Billing_Entity_Address__c);
        System.assertEquals('Australia', row.Billing_Entity_Jurisdiction__c);
    }

    @isTest
    static void extractionJob_populatesRenewalFeeEscalator() {
        Opportunity opp = insertOpp('IB AI Platform', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Renewal_Fee_Escalator_Percent' => 5
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Renewal_Fee_Escalator__c FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(5, row.Renewal_Fee_Escalator__c);
    }

    @isTest
    static void extractionJob_renewalEscalatorNullWhenAbsent() {
        Opportunity opp = insertOpp('No Escalator', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Renewal_Fee_Escalator_Percent' => null
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Renewal_Fee_Escalator__c FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(null, row.Renewal_Fee_Escalator__c, 'No escalator -> null, not 0');
    }

    @isTest
    static void extractionJob_populatesSubprocessorAndEvidence() {
        Opportunity opp = insertOpp('Cantor Pilot', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        // v2: Extract_Evidence arrives as a JSON object {field:{clause,quote}}.
        Map<String, Object> evidence = new Map<String, Object>{
            'Subprocessor_Notice_Period_Days' => new Map<String, Object>{
                'clause' => 'MSA Section 9(f)',
                'quote'  => 'Rogo shall provide Customer with no less than thirty (30) days\' prior written notice before adding, removing, or replacing any Subprocessor'
            }
        };

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Subprocessor_Notice_Period_Days' => 30,
            'Extract_Evidence' => evidence
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Subprocessor_Notice_Period__c, Subprocessor_Restrictions__c, Extract_Evidence__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(30, row.Subprocessor_Notice_Period__c);
        System.assertEquals(null, row.Subprocessor_Restrictions__c, 'Plain 30-day notice is not a restriction');
        System.assert(row.Extract_Evidence__c != null && row.Extract_Evidence__c.contains('thirty (30)'),
            'Evidence field should carry the verbatim excerpt: ' + row.Extract_Evidence__c);
    }

    @isTest
    static void extractionJob_subprocessorNoticeStaysNullWhenAbsent() {
        // v2: a null day-count means NO notice obligation was found. We must NOT
        // fabricate a 30-day default and must NOT treat it as zero.
        Opportunity opp = insertOpp('No Subproc Clause', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Subprocessor_Notice_Period_Days' => null,
            'Subprocessor_Restrictions' => null
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Subprocessor_Notice_Period__c, Subprocessor_Restrictions__c, Extract_Evidence__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(null, row.Subprocessor_Notice_Period__c,
            'Absent clause -> null (no obligation found), never a 30-day default');
    }

    @isTest
    static void extractionJob_subprocessorConsentRestrictionNoNotice() {
        // Truist-style: written consent required, no day count. The notice period
        // stays null (v2: not defaulted) and the restriction is captured verbatim.
        Opportunity opp = insertOpp('Consent Required', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Subprocessor_Notice_Period_Days' => null,
            'Subprocessor_Restrictions' => 'Prior written consent required before changing subprocessors (MSA 10.5)'
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Subprocessor_Notice_Period__c, Subprocessor_Restrictions__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(null, row.Subprocessor_Notice_Period__c,
            'Consent-only clause has no day count -> null, not a 30-day default');
        System.assert(row.Subprocessor_Restrictions__c.contains('consent'),
            'Consent restriction should be captured: ' + row.Subprocessor_Restrictions__c);
    }

    @isTest
    static void extractionJob_signatureDateIsLaterOfCustomerAndRogo() {
        Opportunity opp = insertOpp('Sig Date Both', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OF');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Customer_Signature_Date' => '2026-04-14',
            'Rogo_Signature_Date' => '2026-04-15',
            'Customer_Signer_Name' => 'Borja Oria Riu',
            'Customer_Signer_Title' => 'Managing Partner'
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Signature_Date__c, Customer_Signer_Name__c, Customer_Signer_Title__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(Date.newInstance(2026, 4, 15), row.Signature_Date__c,
            'Signature_Date should be the later of the two (Rogo, 4/15)');
        System.assertEquals('Borja Oria Riu', row.Customer_Signer_Name__c);
        System.assertEquals('Managing Partner', row.Customer_Signer_Title__c);
    }

    @isTest
    static void extractionJob_signatureDateFallsBackWhenOnlyOnePresent() {
        Opportunity opp = insertOpp('Sig Date One', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OF');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Customer_Signature_Date' => '2026-04-14',
            'Rogo_Signature_Date' => null
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Signature_Date__c FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(Date.newInstance(2026, 4, 14), row.Signature_Date__c,
            'Signature_Date should fall back to the one present date');
    }

    @isTest
    static void extractionJob_overridesTypeWithOppType() {
        Opportunity opp = new Opportunity(
            Name = 'Renewal-with-seats',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'Renewal'
        );
        insertOppSafely(opp);
        attachSignedFile(opp.Id, 'signed__Renewal_Order_Form');

        // Claude misclassifies as Upsell (because the renewal adds seats).
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Upsell',
            'Annual_Recurring_Revenue' => 100000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Type__c, Extracted_JSON__c FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals('Renewal', row.Type__c, 'Opp.Type should override Claude classification');
        System.assert(row.Extracted_JSON__c.contains('Upsell'),
            'Claude original classification should still be preserved in Extracted_JSON__c');
    }

    @isTest
    static void extractionJob_computesIncrementalARRForUpsell() {
        // Base Opp has a prior Success extraction with ARR=$118k.
        Opportunity baseOpp = insertOpp('Arma Land', 'Closed Won');
        insert new Order_Form_Extraction__c(
            Opportunity__c = baseOpp.Id,
            Extraction_Status__c = 'Success',
            Annual_Recurring_Revenue__c = 118000,
            Extracted_At__c = System.now()
        );

        Opportunity upsellOpp = new Opportunity(
            Name = 'Arma Expansion',
            StageName = '5 - Contracting',
            CloseDate = Date.today(),
            Type = 'Upsell',
            Base_Opportunity__c = baseOpp.Id
        );
        insert upsellOpp;
        attachSignedFile(upsellOpp.Id, 'signed__Rider');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Upsell',
            'Annual_Recurring_Revenue' => 174000,
            'Seat_Licenses' => 100
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = upsellOpp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Annual_Recurring_Revenue__c, Incremental_ARR__c, Base_ARR__c, Type__c
            FROM Order_Form_Extraction__c
            WHERE Opportunity__c = :upsellOpp.Id
            LIMIT 1
        ];
        System.assertEquals('Upsell', row.Type__c);
        System.assertEquals(174000, row.Annual_Recurring_Revenue__c, 'Extracted total stays as $174k');
        System.assertEquals(118000, row.Base_ARR__c, 'Base ARR snapshot from parent OFE');
        System.assertEquals(56000, row.Incremental_ARR__c, '174k - 118k = 56k incremental');
    }

    @isTest
    static void extractionJob_renewalUsesOwnArrAsBaseWhenNoBaseOpp() {
        // Renewals have no Base_Opportunity__c. The prior/aggregate ARR is
        // carried on the renewal Opp's own Annual_Recurring_Revenue__c (55k),
        // renewing up to the extracted 81k -> incremental 26k.
        Opportunity opp = new Opportunity(
            Name = 'Renewal: Harbor View',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'Renewal',
            Annual_Recurring_Revenue__c = 55000
        );
        insertOppSafely(opp);
        attachSignedFile(opp.Id, 'signed__OF');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Renewal',
            'Annual_Recurring_Revenue' => 81000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Annual_Recurring_Revenue__c, Base_ARR__c, Incremental_ARR__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(81000, row.Annual_Recurring_Revenue__c);
        System.assertEquals(55000, row.Base_ARR__c, 'Base = renewal opp own ARR');
        System.assertEquals(26000, row.Incremental_ARR__c, '81k - 55k = 26k');
    }

    @isTest
    static void extractionJob_incrementalEqualsTotalForNewBusiness() {
        Opportunity opp = insertOpp('Net New', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OF');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Annual_Recurring_Revenue' => 490000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Annual_Recurring_Revenue__c, Incremental_ARR__c, Base_ARR__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
        System.assertEquals(490000, row.Incremental_ARR__c, 'New Business: incremental = total');
        System.assertEquals(null, row.Base_ARR__c);
    }

    @isTest
    static void applier_upsellWritesIncrementalARR() {
        Opportunity baseOpp = insertOpp('Base for Apply', 'Closed Won');
        Opportunity upsellOpp = new Opportunity(
            Name = 'Upsell for Apply',
            StageName = '5 - Contracting',
            CloseDate = Date.today(),
            Base_Opportunity__c = baseOpp.Id
        );
        insert upsellOpp;

        Order_Form_Extraction__c row = new Order_Form_Extraction__c(
            Opportunity__c = upsellOpp.Id,
            Extraction_Status__c = 'Success',
            Extracted_At__c = System.now(),
            Type__c = 'Upsell',
            Annual_Recurring_Revenue__c = 174000,
            Incremental_ARR__c = 56000,
            Base_ARR__c = 118000,
            Applied_To_Opportunity__c = false
        );
        insert row;

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;
        Test.startTest();
        OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        Opportunity after = [SELECT Annual_Recurring_Revenue__c FROM Opportunity WHERE Id = :upsellOpp.Id];
        System.assertEquals(56000, after.Annual_Recurring_Revenue__c,
            'Upsell should write Incremental_ARR__c (56k), not the gross $174k');
    }

    @isTest
    static void extractionJob_includesFilesFromBaseOpportunity() {
        Opportunity baseOpp = insertOpp('Arma Land', 'Closed Won');
        attachSignedFile(baseOpp.Id, 'signed__OrderForm_Land');
        attachSignedFile(baseOpp.Id, 'signed__MSA');

        Opportunity upsellOpp = new Opportunity(
            Name = 'Arma Expansion',
            StageName = '5 - Contracting',
            CloseDate = Date.today(),
            Base_Opportunity__c = baseOpp.Id
        );
        insert upsellOpp;
        attachSignedFile(upsellOpp.Id, 'signed__Rider');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Upsell',
            'Seat_Licenses' => 100,
            'License_Fees' => 144000,
            'Platform_Connection_Fee' => 30000,
            'Annual_Recurring_Revenue' => 174000
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = upsellOpp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        System.assertEquals('Enqueued', results[0].status);
        System.assertEquals(3, results[0].documentCount,
            'Should pull Rider from current Opp + OF + MSA from Base_Opportunity__c');

        Order_Form_Extraction__c row = latestExtractionFor(upsellOpp.Id);
        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(144000, row.License_Fees__c);
        System.assertEquals(30000, row.Platform_Connection_Fee__c);
        System.assertEquals(174000, row.Annual_Recurring_Revenue__c);
        System.assert(row.File_Name__c.contains('Rider') && row.File_Name__c.contains('OrderForm_Land'),
            'File_Name__c should include both Rider and parent OF: ' + row.File_Name__c);
    }

    @isTest
    static void extractionJob_multipleDocuments_singleRowOneCallout() {
        Opportunity opp = insertOpp('Multi-Doc Extract', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__Order_Form');
        attachSignedFile(opp.Id, 'signed__MSA');
        attachSignedFile(opp.Id, 'signed__DPA');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 100,
            'License_Fees' => 200000,
            'Renewal_Terms' => 'Auto-renews unless 90 days written notice'
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        System.assertEquals('Enqueued', results[0].status);
        System.assertEquals(3, results[0].documentCount, 'Should have found 3 signed files');
        System.assertEquals(1, mock.callCount, 'Single Anthropic call with multiple document blocks');

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(100, row.Seat_Licenses__c);
        System.assertEquals(200000, row.License_Fees__c);
        System.assertEquals('Auto-renew (90-day)', row.Renewal_Terms__c);
        System.assert(row.Content_Document_Id__c != null && row.Content_Document_Id__c.contains(','),
            'Content_Document_Id__c should contain comma-separated Ids: ' + row.Content_Document_Id__c);
        System.assert(row.File_Name__c != null && row.File_Name__c.contains('Order_Form') && row.File_Name__c.contains('MSA'),
            'File_Name__c should list both file titles: ' + row.File_Name__c);
    }

    @isTest
    static void extractionJob_derivesEndDateFromStartPlusMonths() {
        Opportunity opp = insertOpp('End Date Derive', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-05-29',
            'Contract_Length_Months' => 12,
            'Seat_Licenses' => 500,
            'License_Fees' => 490791
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(Date.newInstance(2026, 5, 29), row.Contract_Start_Date__c);
        System.assertEquals(Date.newInstance(2027, 5, 28), row.Contract_End_Date__c,
            'End date should be start + 12 months - 1 day (inclusive end)');
    }

    @isTest
    static void extractionJob_correctsAnniversaryEndDateOffByOne() {
        // Doc states only a 12-month term; the model computed the end as the
        // anniversary (9/30/2026 + 12mo = 9/30/2027). Rogo's convention is the
        // inclusive end 9/29/2027, so the extractor must correct the off-by-one.
        Opportunity opp = insertOpp('End Date Off By One', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-09-30',
            'Contract_End_Date' => '2027-09-30',   // model returned the anniversary
            'Contract_Length_Months' => 12
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertEquals(Date.newInstance(2026, 9, 30), row.Contract_Start_Date__c);
        System.assertEquals(Date.newInstance(2027, 9, 29), row.Contract_End_Date__c,
            'Anniversary end (start + 12mo) must be corrected to the inclusive end (start + 12mo - 1)');
    }

    @isTest
    static void extractionJob_keepsExplicitNonAnniversaryEndDate() {
        // A 3-month term with an explicit end date that is NEITHER the anniversary
        // (12/30/2026) nor the inclusive end (12/29/2026). It must be preserved -
        // we only correct the anniversary off-by-one, never override a real date.
        Opportunity opp = insertOpp('End Date Explicit', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-09-30',
            'Contract_End_Date' => '2026-12-31',   // explicit, not the anniversary
            'Contract_Length_Months' => 3
        });

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertEquals(Date.newInstance(2026, 12, 31), row.Contract_End_Date__c,
            'A non-anniversary explicit end date must be preserved');
    }

    @isTest
    static void extractionJob_writesSuccessRowWithAllFields() {
        Opportunity opp = insertOpp('Happy Extract', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__Customer_Agreement');

        Map<String, Object> extracted = new Map<String, Object>{
            '_is_amendment' => false,
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-06-01',
            'Contract_End_Date' => '2027-05-31',
            'Contract_Length_Months' => 12,
            'Seat_Licenses' => 25,
            'License_Fees' => 150000,
            'Total_Contract_Value' => 150000,
            'Annual_Recurring_Revenue' => 150000,
            'Renewal_Terms' => 'Auto-renews unless 90 days written notice',
            'Subscription_Schedule' => 'Annual',
            'Payment_Terms' => 'Annual',
            'Credit_Terms' => 'Net 30',
            'Billing_Contact_Email' => 'billing@customer.com',
            'Special_Terms' => 'MFN clause; standard MSA otherwise.'
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertNotEquals(null, row, 'Extraction row should exist');
        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(200, row.HTTP_Status_Code__c);
        System.assertNotEquals(null, row.Raw_Response__c);
        System.assertNotEquals(null, row.Extracted_JSON__c);
        System.assertEquals('New Business', row.Type__c);
        System.assertEquals(Date.newInstance(2026, 6, 1), row.Contract_Start_Date__c);
        System.assertEquals(Date.newInstance(2027, 5, 31), row.Contract_End_Date__c);
        System.assertEquals(12, row.Contract_Length_Months__c);
        System.assertEquals(25, row.Seat_Licenses__c);
        System.assertEquals(150000, row.License_Fees__c);
        System.assertEquals(150000, row.Total_Contract_Value__c);
        System.assertEquals(150000, row.Annual_Recurring_Revenue__c);
        System.assertEquals('Auto-renew (90-day)', row.Renewal_Terms__c);
        System.assertEquals('Annual', row.Subscription_Schedule__c);
        System.assertEquals('Annual', row.Payment_Terms__c);
        System.assertEquals('Net-30', row.Credit_Terms__c);
        System.assertEquals('billing@customer.com', row.Billing_Contact_Email__c);
        System.assertEquals(false, row.Applied_To_Opportunity__c);

        Opportunity oppAfter = [SELECT License_Fees__c, Seat_Licenses__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, oppAfter.License_Fees__c, 'Opp should NOT be modified by extraction alone');
        System.assertEquals(null, oppAfter.Seat_Licenses__c, 'Opp should NOT be modified by extraction alone');
    }

    @isTest
    static void extractionJob_apiFailure_writesFailureRow() {
        Opportunity opp = insertOpp('API Fail Extract', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__Whatever');

        MockAnthropic mock = new MockAnthropic();
        mock.statusCode = 500;
        mock.responseBody = '{"error":"internal"}';

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertNotEquals(null, row);
        System.assertEquals('API Failed', row.Extraction_Status__c);
        System.assertEquals(500, row.HTTP_Status_Code__c);
        System.assert(row.Error_Message__c != null && row.Error_Message__c.contains('500'),
            'Error_Message should mention 500: ' + row.Error_Message__c);
    }

    @isTest
    static void extractionJob_parseFailure_writesParseFailedRow() {
        Opportunity opp = insertOpp('Parse Fail Extract', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__Garbage');

        Test.setMock(HttpCalloutMock.class, new GarbageMock());
        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = latestExtractionFor(opp.Id);
        System.assertNotEquals(null, row);
        System.assertEquals('Parse Failed', row.Extraction_Status__c);
        System.assertNotEquals(null, row.Error_Message__c);
    }

    // ===== Applier =====

    private static Order_Form_Extraction__c insertExtraction(Id oppId, Map<String, Object> overrides) {
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(
            Opportunity__c = oppId,
            Extraction_Status__c = 'Success',
            Extracted_At__c = System.now(),
            Model__c = 'claude-sonnet-4-6',
            Type__c = 'New Business',
            Applied_To_Opportunity__c = false
        );
        for (String k : overrides.keySet()) row.put(k, overrides.get(k));
        insert row;
        return row;
    }

    @isTest
    static void applier_fillsBlanksOnly() {
        Opportunity opp = insertOpp('Apply Happy', '5 - Contracting');
        Order_Form_Extraction__c row = insertExtraction(opp.Id, new Map<String, Object>{
            'Contract_Start_Date__c' => Date.newInstance(2026, 6, 1),
            'Contract_End_Date__c' => Date.newInstance(2027, 5, 31),
            'Contract_Length_Months__c' => 12,
            'Seat_Licenses__c' => 25,
            'License_Fees__c' => 150000,
            'Total_Contract_Value__c' => 150000,
            'Annual_Recurring_Revenue__c' => 150000,
            'Renewal_Terms__c' => 'Auto-renew (90-day)',
            'Subscription_Schedule__c' => 'Annual',
            'Payment_Terms__c' => 'Annual',
            'Credit_Terms__c' => 'Net-30',
            'Billing_Contact_Email__c' => 'billing@customer.com',
            'Special_Terms__c' => 'MFN clause; auto-renews annually.'
        });

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;

        Test.startTest();
        List<OrderFormApplier.Result> results = OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].applied);
        System.assertEquals('Applied', results[0].status);

        Opportunity after = [
            SELECT Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
                   Seat_Licenses__c, Num_Users__c, License_Fees__c, Total_Contract_Value__c, Amount,
                   Annual_Recurring_Revenue__c, Renewal_Terms__c, Subscription_Schedule__c,
                   Payment_Terms__c, Credit_Terms__c, Billing_Contact__c, Notes__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals(Date.newInstance(2026, 6, 1), after.Contract_Start_Date__c);
        System.assertEquals(Date.newInstance(2027, 5, 31), after.Contract_End_Date__c);
        System.assertEquals(12, after.Contract_Length_Mos__c);
        System.assertEquals(25, after.Seat_Licenses__c);
        System.assertEquals(25, after.Num_Users__c);
        System.assertEquals(150000, after.License_Fees__c);
        System.assertEquals(150000, after.Total_Contract_Value__c);
        System.assertEquals(150000, after.Amount);
        System.assertEquals(150000, after.Annual_Recurring_Revenue__c);
        System.assertEquals('Auto-renew (90-day)', after.Renewal_Terms__c);
        System.assertEquals('Annual', after.Subscription_Schedule__c);
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assertEquals('Net-30', after.Credit_Terms__c);
        System.assertEquals('billing@customer.com', after.Billing_Contact__c);
        System.assert(after.Notes__c != null && after.Notes__c.contains('MFN'),
            'Notes__c should be appended with special terms: ' + after.Notes__c);

        Order_Form_Extraction__c rowAfter = [
            SELECT Applied_To_Opportunity__c, Applied_At__c, Applied_By__c, Apply_Notes__c
            FROM Order_Form_Extraction__c WHERE Id = :row.Id
        ];
        System.assertEquals(true, rowAfter.Applied_To_Opportunity__c);
        System.assertNotEquals(null, rowAfter.Applied_At__c);
        System.assertEquals(UserInfo.getUserId(), rowAfter.Applied_By__c);
        System.assert(rowAfter.Apply_Notes__c != null && rowAfter.Apply_Notes__c.contains('Wrote'),
            'Apply_Notes should list wrote actions: ' + rowAfter.Apply_Notes__c);
    }

    @isTest
    static void applier_noOverwrite_logsSkip() {
        Opportunity opp = new Opportunity(
            Name = 'Apply No Overwrite',
            StageName = '5 - Contracting',
            CloseDate = Date.today(),
            Seat_Licenses__c = 10,
            License_Fees__c = 50000
        );
        insert opp;
        Order_Form_Extraction__c row = insertExtraction(opp.Id, new Map<String, Object>{
            'Seat_Licenses__c' => 12,
            'License_Fees__c' => 60000
        });

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;

        Test.startTest();
        OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        Opportunity after = [SELECT Seat_Licenses__c, License_Fees__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(10, after.Seat_Licenses__c, 'Existing value should not be overwritten');
        System.assertEquals(50000, after.License_Fees__c, 'Existing value should not be overwritten');

        Order_Form_Extraction__c rowAfter = [SELECT Apply_Notes__c, Applied_To_Opportunity__c FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals(true, rowAfter.Applied_To_Opportunity__c);
        System.assert(rowAfter.Apply_Notes__c.contains('Skipped Seat_Licenses__c'), 'Apply notes should log skip: ' + rowAfter.Apply_Notes__c);
        System.assert(rowAfter.Apply_Notes__c.contains('Skipped License_Fees__c'), 'Apply notes should log skip: ' + rowAfter.Apply_Notes__c);
    }

    @isTest
    static void applier_idempotent_doesNotReapply() {
        Opportunity opp = insertOpp('Apply Idempotent', '5 - Contracting');
        Order_Form_Extraction__c row = insertExtraction(opp.Id, new Map<String, Object>{
            'Seat_Licenses__c' => 25,
            'Applied_To_Opportunity__c' => true
        });

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;

        Test.startTest();
        List<OrderFormApplier.Result> results = OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        System.assertEquals('AlreadyApplied', results[0].status);
        System.assertEquals(false, results[0].applied);

        Opportunity after = [SELECT Seat_Licenses__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, after.Seat_Licenses__c, 'Should not have been written on a re-apply');
    }

    @isTest
    static void applier_pilotRoutesToTrialFields() {
        Opportunity opp = insertOpp('Apply Pilot', '3 - POV');
        Order_Form_Extraction__c row = insertExtraction(opp.Id, new Map<String, Object>{
            'Type__c' => 'Pilot',
            'Contract_Start_Date__c' => Date.newInstance(2026, 6, 15),
            'Contract_End_Date__c' => Date.newInstance(2026, 8, 15),
            'Seat_Licenses__c' => 5,
            'License_Fees__c' => 25000,
            'Trial_Price__c' => 25000,
            'Paid_Trial__c' => true,
            'Pilot_Success_Criteria__c' => 'Adoption by 80% of users within 30 days.'
        });

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;

        Test.startTest();
        OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        Opportunity after = [
            SELECT Trial_Start_Date__c, Trial_End_Date__c, Trial_Users__c, Trial_Price__c,
                   Paid_Trial__c, Pilot_Success_Criteria__c,
                   Contract_Start_Date__c, License_Fees__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals(Date.newInstance(2026, 6, 15), after.Trial_Start_Date__c);
        System.assertEquals(Date.newInstance(2026, 8, 15), after.Trial_End_Date__c);
        System.assertEquals(5, after.Trial_Users__c);
        System.assertEquals(25000, after.Trial_Price__c);
        System.assertEquals(true, after.Paid_Trial__c);
        System.assertEquals('Adoption by 80% of users within 30 days.', after.Pilot_Success_Criteria__c);
        System.assertEquals(null, after.Contract_Start_Date__c, 'Pilot should not touch Contract_Start_Date__c');
        System.assertEquals(null, after.License_Fees__c, 'Pilot should not touch License_Fees__c');
    }

    @isTest
    static void applier_rejectsNonSuccessStatus() {
        Opportunity opp = insertOpp('Apply Failed Row', '5 - Contracting');
        Order_Form_Extraction__c row = insertExtraction(opp.Id, new Map<String, Object>{
            'Extraction_Status__c' => 'API Failed',
            'Seat_Licenses__c' => 99
        });

        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;

        Test.startTest();
        List<OrderFormApplier.Result> results = OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();

        System.assertEquals('NotSuccess', results[0].status);
        System.assertEquals(false, results[0].applied);
        Opportunity after = [SELECT Seat_Licenses__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, after.Seat_Licenses__c);
    }

    // ===== Backfill Batch =====

    @isTest
    static void backfillBatch_processesEligibleOpps() {
        Opportunity oppWithFile = insertOpp('Backfill With File', 'Closed Won');
        Opportunity oppNoFile = insertOpp('Backfill No File', 'Closed Won');
        Opportunity oppNotWon = insertOpp('Backfill Not Won', '4 - Proposal');
        attachSignedFile(oppWithFile.Id, 'signed__OrderForm');
        attachSignedFile(oppNotWon.Id, 'signed__OrderForm');

        // Pre-existing extraction on a third Closed Won Opp -> must be skipped.
        Opportunity oppAlready = insertOpp('Backfill Already Extracted', 'Closed Won');
        attachSignedFile(oppAlready.Id, 'signed__OrderForm');
        insert new Order_Form_Extraction__c(
            Opportunity__c = oppAlready.Id,
            Extraction_Status__c = 'Success',
            Extracted_At__c = System.now()
        );

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 12
        });

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        Id jobId = OrderFormBackfillBatch.run();
        Test.stopTest();

        System.assertNotEquals(null, jobId);

        // Only oppWithFile should have a NEW extraction. oppNoFile is skipped (no file),
        // oppNotWon is not Closed Won, oppAlready already has a row.
        Integer rowsForWithFile = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :oppWithFile.Id];
        Integer rowsForNoFile = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :oppNoFile.Id];
        Integer rowsForNotWon = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :oppNotWon.Id];
        Integer rowsForAlready = [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :oppAlready.Id];

        System.assertEquals(1, rowsForWithFile, 'Eligible Closed Won Opp should get an extraction');
        System.assertEquals(0, rowsForNoFile, 'No signed file => no extraction');
        System.assertEquals(0, rowsForNotWon, 'Not Closed Won => not picked up');
        System.assertEquals(1, rowsForAlready, 'Already-extracted Opp keeps its single row');
    }

    @isTest
    static void backfillBatch_multipleOppsAllSucceed() {
        // Verifies the callouts-first / DML-after-loop ordering. With the old
        // design (insert after each callout), the 2nd Opp's callout would
        // fail with "uncommitted work pending" and the row would be marked
        // API Failed. With the new design, both succeed.
        Opportunity oppA = insertOpp('Multi A', 'Closed Won');
        Opportunity oppB = insertOpp('Multi B', 'Closed Won');
        attachSignedFile(oppA.Id, 'signed__OF_A');
        attachSignedFile(oppB.Id, 'signed__OF_B');

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 10
        });

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormBackfillBatch.run();
        Test.stopTest();

        List<Order_Form_Extraction__c> rows = [
            SELECT Opportunity__c, Extraction_Status__c FROM Order_Form_Extraction__c
        ];
        System.assertEquals(2, rows.size(), 'Both Opps should have rows');
        for (Order_Form_Extraction__c r : rows) {
            System.assertEquals('Success', r.Extraction_Status__c,
                'Both extractions should succeed - no DML-before-callout error. Got ' +
                r.Extraction_Status__c + ' for ' + r.Opportunity__c);
        }
    }

    @isTest
    static void backfillBatch_respectsMaxOppsLimit() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(Name = 'Cap ' + i, StageName = 'Closed Won', CloseDate = Date.today()));
        }
        insertOppsSafely(opps);
        for (Opportunity o : opps) attachSignedFile(o.Id, 'signed__OrderForm_' + o.Name);

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{ 'Type' => 'New Business' });

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormBackfillBatch.run(2);
        Test.stopTest();

        Integer rows = [SELECT COUNT() FROM Order_Form_Extraction__c];
        System.assertEquals(2, rows, 'maxOpps=2 should produce exactly 2 extraction rows');
    }

    @isTest
    static void runRerunFlagged_reextractsAndClearsFlaggedRow() {
        Opportunity opp = insertOpp('Rerun Flagged', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');
        // Pre-existing extraction the user checked Rerun__c on.
        Order_Form_Extraction__c flaggedRow = new Order_Form_Extraction__c(
            Opportunity__c = opp.Id,
            Extraction_Status__c = 'Success',
            Extracted_At__c = System.now(),
            Rerun__c = true
        );
        insert flaggedRow;

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{ 'Type' => 'New Business' });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OrderFormBackfillBatch.runRerunFlagged();
        Test.stopTest();

        // The flagged row is KEPT as history; the fresh row supersedes it and is current.
        Order_Form_Extraction__c oldRow = [
            SELECT Rerun__c, Is_Current__c FROM Order_Form_Extraction__c WHERE Id = :flaggedRow.Id];
        System.assertEquals(false, oldRow.Rerun__c, 'Flag clears once the rerun is current');
        System.assertEquals(false, oldRow.Is_Current__c);
        Order_Form_Extraction__c fresh = [
            SELECT Extraction_Status__c, Rerun__c, Is_Current__c, Supersedes__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id AND Id != :flaggedRow.Id];
        System.assertEquals('Success', fresh.Extraction_Status__c);
        System.assertEquals(true, fresh.Is_Current__c);
        System.assertEquals(flaggedRow.Id, fresh.Supersedes__c, 'New row points at the row it supersedes');
        System.assertEquals(false, fresh.Rerun__c, 'New row must not be flagged');
    }

    @isTest
    static void runRefresh_updatesLatestRowInPlace() {
        Opportunity opp = insertOpp('Refresh In Place', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');
        Order_Form_Extraction__c existing = new Order_Form_Extraction__c(
            Opportunity__c = opp.Id, Extraction_Status__c = 'Success',
            Extracted_At__c = System.now(), Seat_Licenses__c = 1);
        insert existing;
        Id existingId = existing.Id;

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business', 'Seat_Licenses' => 9 });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OrderFormBackfillBatch.runRefresh(Datetime.now().addMinutes(1));
        Test.stopTest();

        List<Order_Form_Extraction__c> rows = [
            SELECT Id, Seat_Licenses__c FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id];
        System.assertEquals(1, rows.size(), 'Refresh must not create a new row');
        System.assertEquals(existingId, rows[0].Id, 'Same row updated in place');
        System.assertEquals(9, rows[0].Seat_Licenses__c, 'Row refreshed with the new values');
    }

    @isTest
    static void runRefresh_failedRerunLeavesRowUntouched() {
        Opportunity opp = insertOpp('Refresh Fail Safe', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');
        Order_Form_Extraction__c existing = new Order_Form_Extraction__c(
            Opportunity__c = opp.Id, Extraction_Status__c = 'Success',
            Extracted_At__c = System.now(), Seat_Licenses__c = 7);
        insert existing;
        Id existingId = existing.Id;

        MockAnthropic mock = new MockAnthropic();
        mock.statusCode = 500;                       // force the re-extraction to fail
        mock.responseBody = '{"error":"internal"}';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OrderFormBackfillBatch.runRefresh(Datetime.now().addMinutes(1));
        Test.stopTest();

        List<Order_Form_Extraction__c> rows = [
            SELECT Id, Seat_Licenses__c, Extraction_Status__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id];
        System.assertEquals(1, rows.size(), 'No new row on a failed rerun');
        System.assertEquals(existingId, rows[0].Id, 'Same row');
        System.assertEquals(7, rows[0].Seat_Licenses__c, 'A failed rerun must NOT overwrite the good row');
        System.assertEquals('Success', rows[0].Extraction_Status__c, 'Existing Success status preserved');
    }

    // ===== Off-platform large-doc path (buildFromResponseBody + REST) =====

    @isTest
    static void buildFromResponseBody_mapsFieldsWithoutCallout() {
        Opportunity opp = insertOpp('Large Doc Opp', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 5,
            'Sub_Processor_List' => new List<Object>{ 'Amazon Web Services', 'OpenAI' }
        });

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
            opp.Id, new List<Id>(), body);
        insert row;
        Test.stopTest();

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(5, row.Seat_Licenses__c);
        System.assertNotEquals(null, row.Sub_Processor_List__c);
        System.assert(row.Sub_Processor_List__c.contains('Amazon Web Services'),
            'Sub-processor list should be mapped from the passed-in response');
    }

    @isTest
    static void rest_doPost_createsExtraction() {
        Opportunity opp = insertOpp('Large Doc REST', 'Closed Won');
        OrderFormExtractionRest.Payload p = new OrderFormExtractionRest.Payload();
        p.opportunityId = opp.Id;
        p.contentDocumentIds = new List<Id>();
        p.responseBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business', 'Seat_Licenses' => 3
        });

        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(p));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        OrderFormExtractionRest.ApiResult res = OrderFormExtractionRest.doPost();
        Test.stopTest();

        System.assertEquals('Success', res.status);
        System.assertNotEquals(null, res.extractionId);
        System.assertEquals(1, [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id]);
    }

    @isTest
    static void rest_doPost_nullOpportunityReturnsError() {
        OrderFormExtractionRest.Payload p = new OrderFormExtractionRest.Payload();
        p.contentDocumentIds = new List<Id>();
        p.responseBody = 'x';

        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(p));   // opportunityId is null
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        OrderFormExtractionRest.ApiResult res = OrderFormExtractionRest.doPost();
        Test.stopTest();

        System.assertEquals('Error', res.status);
        System.assertEquals(null, res.extractionId);
    }

    @isTest
    static void rest_doPost_malformedBodyReturnsError() {
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('this is not json');   // forces the catch
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        OrderFormExtractionRest.ApiResult res = OrderFormExtractionRest.doPost();
        Test.stopTest();

        System.assertEquals('Error', res.status);
    }

    // ===== Doc relevance ranking (heap-budget drop order) =====

    @isTest
    static void docRelevanceRank_ordersComplianceDocsFirst() {
        // Order form = most important (0); DPA/subprocessor = 1; MSA/MSSA = 2;
        // NDA/W-9 = drop first (9); anything else = middle (5).
        System.assertEquals(0, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Rogo Order Form')));
        System.assertEquals(0, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Customer Agreement Form vFinal')));
        System.assertEquals(1, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Customer DPA')));
        // subprocessor beats the addendum keyword (rank 1, not 2)
        System.assertEquals(1, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Subprocessor Addendum')));
        System.assertEquals(2, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__MSSA Executed')));
        System.assertEquals(2, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Master Services Agreement')));
        System.assertEquals(9, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Mutual NDA')));
        System.assertEquals(5, OrderFormExtractionJob.docRelevanceRank(new ContentVersion(Title = 'signed__Kickoff Notes')));
        System.assertEquals(5, OrderFormExtractionJob.docRelevanceRank(new ContentVersion()));
    }

    // ===== Picklist mapper =====

    @isTest
    static void picklistMapper_directValues() {
        // Renewal terms - all branches
        System.assertEquals('Auto-renew (90-day)', OrderFormPicklistMapper.mapRenewalTerms('renews unless 90 days notice'));
        System.assertEquals('Auto-renew (60-day)', OrderFormPicklistMapper.mapRenewalTerms('auto with 60 day notice'));
        System.assertEquals('Auto-renew (30-day)', OrderFormPicklistMapper.mapRenewalTerms('30 day auto'));
        System.assertEquals('Auto-renew (30-day)', OrderFormPicklistMapper.mapRenewalTerms('evergreen'));
        System.assertEquals('Auto-renew (30-day)', OrderFormPicklistMapper.mapRenewalTerms('auto-renews each term'));
        System.assertEquals('Manual renewal', OrderFormPicklistMapper.mapRenewalTerms('mutual written agreement'));
        System.assertEquals('Manual renewal', OrderFormPicklistMapper.mapRenewalTerms('will not auto-renew'));
        System.assertEquals(null, OrderFormPicklistMapper.mapRenewalTerms(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapRenewalTerms('   '));
        System.assertEquals(null, OrderFormPicklistMapper.mapRenewalTerms('whatever'));

        // Credit terms - all 4 Net values plus negative
        System.assertEquals('Net-15', OrderFormPicklistMapper.mapCreditTerms('NET-15'));
        System.assertEquals('Net-30', OrderFormPicklistMapper.mapCreditTerms('Net 30 days'));
        System.assertEquals('Net-45', OrderFormPicklistMapper.mapCreditTerms('payable Net 45'));
        System.assertEquals('Net-60', OrderFormPicklistMapper.mapCreditTerms('NET60'));
        System.assertEquals(null, OrderFormPicklistMapper.mapCreditTerms('whenever'));
        System.assertEquals(null, OrderFormPicklistMapper.mapCreditTerms(null));

        // Subscription schedule - all 4 cadences
        System.assertEquals('Annual', OrderFormPicklistMapper.mapSubscriptionSchedule('Billed annually'));
        System.assertEquals('Annual', OrderFormPicklistMapper.mapSubscriptionSchedule('yearly'));
        System.assertEquals('Quarterly', OrderFormPicklistMapper.mapSubscriptionSchedule('every quarter'));
        System.assertEquals('Monthly', OrderFormPicklistMapper.mapSubscriptionSchedule('monthly invoicing'));
        System.assertEquals('Bi-Annual', OrderFormPicklistMapper.mapSubscriptionSchedule('bi-annual cadence'));
        System.assertEquals('Bi-Annual', OrderFormPicklistMapper.mapSubscriptionSchedule('semi-annual'));
        System.assertEquals(null, OrderFormPicklistMapper.mapSubscriptionSchedule(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapSubscriptionSchedule('unknown'));

        // Payment terms - all 4
        System.assertEquals('Annual', OrderFormPicklistMapper.mapPaymentTerms('billed annually'));
        System.assertEquals('Semi-Annual', OrderFormPicklistMapper.mapPaymentTerms('Semi-Annual installments'));
        System.assertEquals('Quarterly', OrderFormPicklistMapper.mapPaymentTerms('quarterly payment'));
        System.assertEquals('Monthly', OrderFormPicklistMapper.mapPaymentTerms('paid monthly'));
        System.assertEquals(null, OrderFormPicklistMapper.mapPaymentTerms(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapPaymentTerms('weekly'));

        // Type - hit all branches
        System.assertEquals('Pilot', OrderFormPicklistMapper.mapType('Proof of Concept'));
        System.assertEquals('Pilot', OrderFormPicklistMapper.mapType('30-day Trial'));
        System.assertEquals('Pilot', OrderFormPicklistMapper.mapType('POC agreement'));
        System.assertEquals('Renewal', OrderFormPicklistMapper.mapType('annual renewal'));
        System.assertEquals('Upsell', OrderFormPicklistMapper.mapType('expansion order'));
        System.assertEquals('Upsell', OrderFormPicklistMapper.mapType('Add-On Seats'));
        System.assertEquals('Downsell', OrderFormPicklistMapper.mapType('seat reduction'));
        System.assertEquals('Contract Restructure', OrderFormPicklistMapper.mapType('contract restructure'));
        System.assertEquals('Debooking', OrderFormPicklistMapper.mapType('debooking event'));
        System.assertEquals('New Business', OrderFormPicklistMapper.mapType('NEW BUSINESS'));
        System.assertEquals('New Business', OrderFormPicklistMapper.mapType('new logo'));
        System.assertEquals(null, OrderFormPicklistMapper.mapType(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapType('mystery'));

        // Package tier
        System.assertEquals('Enterprise', OrderFormPicklistMapper.mapPackageTier('Enterprise package'));
        System.assertEquals('Team', OrderFormPicklistMapper.mapPackageTier('team tier'));
        System.assertEquals('Basic', OrderFormPicklistMapper.mapPackageTier('Basic subscription'));
        System.assertEquals('Custom', OrderFormPicklistMapper.mapPackageTier('bespoke arrangement'));
        System.assertEquals(null, OrderFormPicklistMapper.mapPackageTier(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapPackageTier('mystery'));

        // Pricing structure - all branches
        System.assertEquals('Seats: Unlimited Usage, No Throttling', OrderFormPicklistMapper.mapPricingStructure('Seats: Unlimited Usage, No Throttling'));
        System.assertEquals('Seats: Unlimited Usage, with Throttling', OrderFormPicklistMapper.mapPricingStructure('unlimited usage subject to fair use'));
        System.assertEquals('Seats: Unlimited Usage, with Throttling', OrderFormPicklistMapper.mapPricingStructure('unlimited with rate limits'));
        System.assertEquals('Seats: Unlimited Usage, No Throttling', OrderFormPicklistMapper.mapPricingStructure('unlimited seats'));
        System.assertEquals('Seats: Credit-Based Usage', OrderFormPicklistMapper.mapPricingStructure('per-seat credits'));
        System.assertEquals('ELA: Credit-Based Usage', OrderFormPicklistMapper.mapPricingStructure('Enterprise license with credit pool'));
        System.assertEquals('ELA: Unlimited Usage, No Throttling', OrderFormPicklistMapper.mapPricingStructure('Enterprise License, unlimited'));
        System.assertEquals('ELA: Unlimited Usage, with Throttling', OrderFormPicklistMapper.mapPricingStructure('ELA unlimited subject to fair use throttling'));
        System.assertEquals('Custom', OrderFormPicklistMapper.mapPricingStructure('Custom pricing arrangement'));
        System.assertEquals(null, OrderFormPicklistMapper.mapPricingStructure(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapPricingStructure('something weird'));
    }

    @isTest
    static void picklistMapper_publicityRights() {
        System.assertEquals('Yes', OrderFormPicklistMapper.mapPublicityRights('Yes'));
        System.assertEquals('Yes', OrderFormPicklistMapper.mapPublicityRights('Rogo is granted the right to use the logo'));
        System.assertEquals('No', OrderFormPicklistMapper.mapPublicityRights('No'));
        System.assertEquals('No', OrderFormPicklistMapper.mapPublicityRights('Rogo shall not use Customer marks'));
        System.assertEquals('With Conditions', OrderFormPicklistMapper.mapPublicityRights('With Conditions'));
        System.assertEquals('With Conditions', OrderFormPicklistMapper.mapPublicityRights('permitted with prior written consent'));
        System.assertEquals('With Conditions', OrderFormPicklistMapper.mapPublicityRights('allowed but Customer may opt out'));
        System.assertEquals('Not Mentioned', OrderFormPicklistMapper.mapPublicityRights('Not Mentioned'));
        System.assertEquals('Not Mentioned', OrderFormPicklistMapper.mapPublicityRights(null));
        System.assertEquals('Not Mentioned', OrderFormPicklistMapper.mapPublicityRights('   '));
    }

    // ===== v2 LLM-enablement-gate mappers =====

    @isTest
    static void picklistMapper_gateMappers() {
        // Yes / No / Not specified. "not specified" must win over the "no" substring.
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapYesNoNotSpecified(null));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapYesNoNotSpecified('not specified'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapYesNoNotSpecified('silent'));
        System.assertEquals('Yes', OrderFormPicklistMapper.mapYesNoNotSpecified('Yes, prohibited'));
        System.assertEquals('Yes', OrderFormPicklistMapper.mapYesNoNotSpecified('true'));
        System.assertEquals('No', OrderFormPicklistMapper.mapYesNoNotSpecified('No'));
        System.assertEquals('No', OrderFormPicklistMapper.mapYesNoNotSpecified('false'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapYesNoNotSpecified('maybe'));

        // Gate type - strictest wins.
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapGateType(null));
        System.assertEquals('Consent required', OrderFormPicklistMapper.mapGateType('prior written consent'));
        System.assertEquals('Consent required', OrderFormPicklistMapper.mapGateType('customer approval required'));
        System.assertEquals('Notify with objection', OrderFormPicklistMapper.mapGateType('notice with right to object'));
        System.assertEquals('Notify', OrderFormPicklistMapper.mapGateType('30 days notice'));
        System.assertEquals('None', OrderFormPicklistMapper.mapGateType('none'));
        System.assertEquals('None', OrderFormPicklistMapper.mapGateType('may freely engage'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapGateType('ambiguous'));

        // Location gate.
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapLocationGate(null));
        System.assertEquals('Consent', OrderFormPicklistMapper.mapLocationGate('requires approval'));
        System.assertEquals('Notice', OrderFormPicklistMapper.mapLocationGate('notice required'));
        System.assertEquals('None', OrderFormPicklistMapper.mapLocationGate('processing anywhere'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapLocationGate('unclear'));

        // Disclosure gate.
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapDisclosureGate(null));
        System.assertEquals('Consent', OrderFormPicklistMapper.mapDisclosureGate('consent needed'));
        System.assertEquals('Notify', OrderFormPicklistMapper.mapDisclosureGate('notify customer'));
        System.assertEquals('None', OrderFormPicklistMapper.mapDisclosureGate('no gate'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapDisclosureGate('unclear'));

        // List location - default "Not listed".
        System.assertEquals('Not listed', OrderFormPicklistMapper.mapListLocation(null));
        System.assertEquals('Transaction document', OrderFormPicklistMapper.mapListLocation('in the transaction doc'));
        System.assertEquals('Trust page', OrderFormPicklistMapper.mapListLocation('on the trust page'));
        System.assertEquals('DPA appendix', OrderFormPicklistMapper.mapListLocation('DPA annex 3'));
        System.assertEquals('Order form', OrderFormPicklistMapper.mapListLocation('listed on the order form'));
        System.assertEquals('Schedule', OrderFormPicklistMapper.mapListLocation('Schedule B'));
        System.assertEquals('Not listed', OrderFormPicklistMapper.mapListLocation('nowhere'));

        // List granularity.
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapListGranularity(null));
        System.assertEquals('Service scoped', OrderFormPicklistMapper.mapListGranularity('service scoped'));
        System.assertEquals('Service scoped', OrderFormPicklistMapper.mapListGranularity('scoped by function'));
        System.assertEquals('Model', OrderFormPicklistMapper.mapListGranularity('per model'));
        System.assertEquals('Provider', OrderFormPicklistMapper.mapListGranularity('by vendor'));
        System.assertEquals('Not specified', OrderFormPicklistMapper.mapListGranularity('unclear'));

        // Confidence - default Low.
        System.assertEquals('Low', OrderFormPicklistMapper.mapConfidence(null));
        System.assertEquals('High', OrderFormPicklistMapper.mapConfidence('high confidence'));
        System.assertEquals('Medium', OrderFormPicklistMapper.mapConfidence('med'));
        System.assertEquals('Low', OrderFormPicklistMapper.mapConfidence('low'));
        System.assertEquals('Low', OrderFormPicklistMapper.mapConfidence('???'));
    }

    // ===== v2 subprocessor-list / evidence serialization =====

    @isTest
    static void mapSubprocessorListValue_allShapes() {
        // List of {name,scope,is_ai} objects -> JSON.
        List<Object> parties = new List<Object>{
            new Map<String, Object>{ 'name' => 'Anthropic', 'scope' => 'LLM inference', 'is_ai' => true },
            new Map<String, Object>{ 'name' => 'AWS', 'scope' => 'Hosting', 'is_ai' => false }
        };
        String asJson = OrderFormExtractionJob.mapSubprocessorListValue(parties);
        System.assert(asJson.startsWith('['), 'A party list should serialize to a JSON array');
        System.assert(asJson.contains('Anthropic') && asJson.contains('is_ai'), asJson);

        // Empty list -> null (nothing named).
        System.assertEquals(null, OrderFormExtractionJob.mapSubprocessorListValue(new List<Object>()));

        // Sentinel string -> stored as-is.
        System.assertEquals('By reference: https://rogo.ai/trust',
            OrderFormExtractionJob.mapSubprocessorListValue('By reference: https://rogo.ai/trust'));
        System.assertEquals('No sub-processors named in the executed documents.',
            OrderFormExtractionJob.mapSubprocessorListValue('No sub-processors named in the executed documents.'));

        // Blank / null -> null.
        System.assertEquals(null, OrderFormExtractionJob.mapSubprocessorListValue('   '));
        System.assertEquals(null, OrderFormExtractionJob.mapSubprocessorListValue(null));
    }

    @isTest
    static void asEvidenceString_objectAndString() {
        // JSON object {field:{clause,quote}} -> serialized JSON.
        Map<String, Object> ev = new Map<String, Object>{
            'Subprocessor_Gate_Type' => new Map<String, Object>{
                'clause' => 'MSA 10.5', 'quote' => 'prior written consent'
            }
        };
        String s = OrderFormExtractionJob.asEvidenceString(ev);
        System.assert(s.contains('prior written consent'), s);
        // Plain string -> as-is.
        System.assertEquals('legacy evidence', OrderFormExtractionJob.asEvidenceString('legacy evidence'));
        // Blank / null -> null.
        System.assertEquals(null, OrderFormExtractionJob.asEvidenceString('   '));
        System.assertEquals(null, OrderFormExtractionJob.asEvidenceString(null));
    }

    @isTest
    static void buildFromResponseBody_mapsGateFields() {
        Opportunity opp = insertOpp('Gate Fields Opp', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Resolved_Subprocessor_Term' => 'Subcontractor',
            'Subprocessor_Gate_Type' => 'prior written consent',
            'Consent_Revocable' => 'Yes',
            'Subprocessor_Objection_Consequence' => 'Customer may terminate for convenience',
            'Subprocessor_List_Location' => 'DPA appendix',
            'Subprocessor_List_Granularity' => 'by vendor',
            'AI_Model_Change_Gate_Days' => 45,
            'AI_Model_Change_Documentation' => 'Change log maintained on trust page',
            'AI_Model_Change_Carveout' => 'Emergency security patches exempt',
            'AI_Change_Reporting_Trigger' => 'Yes',
            'Processing_Location_Gate' => 'requires approval',
            'Approved_Locations' => 'US, EU',
            'Personal_Data_Disclosure_Gate' => 'notify customer',
            'Release_Notice_Days' => 30,
            'Release_Major_Notice_Days' => 90,
            'Customer_Can_Defer_Release' => 'No',
            'Material_Change_Notice' => 'Yes',
            'AI_Training_Prohibition' => 'Yes',
            'AI_Training_Flowdown_Required' => 'Yes',
            'Model_Capability_Floor' => 'not specified',
            'LLM_Gate_Confidence' => 'high'
        });

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
            opp.Id, new List<Id>(), body);
        insert row;
        Test.stopTest();

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals('Subcontractor', row.Resolved_Subprocessor_Term__c);
        System.assertEquals('Consent required', row.Subprocessor_Gate_Type__c);
        System.assertEquals('Yes', row.Consent_Revocable__c);
        System.assertEquals('DPA appendix', row.Subprocessor_List_Location__c);
        System.assertEquals('Provider', row.Subprocessor_List_Granularity__c);
        System.assertEquals(45, row.AI_Model_Change_Gate_Days__c);
        System.assertEquals('Yes', row.AI_Change_Reporting_Trigger__c);
        System.assertEquals('Consent', row.Processing_Location_Gate__c);
        System.assertEquals('US, EU', row.Approved_Locations__c);
        System.assertEquals('Notify', row.Personal_Data_Disclosure_Gate__c);
        System.assertEquals(30, row.Release_Notice_Days__c);
        System.assertEquals(90, row.Release_Major_Notice_Days__c);
        System.assertEquals('No', row.Customer_Can_Defer_Release__c);
        System.assertEquals('Yes', row.AI_Training_Prohibition__c);
        System.assertEquals('Not specified', row.Model_Capability_Floor__c);
        System.assertEquals('High', row.LLM_Gate_Confidence__c);
    }

    @isTest
    static void buildFromResponseBody_gateDefaultsWhenSilent() {
        // A response with no gate keys at all should still leave every restricted
        // gate picklist at its safe "silence" default (never null / invalid).
        Opportunity opp = insertOpp('Silent Gate Opp', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{ 'Type' => 'New Business' });

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
            opp.Id, new List<Id>(), body);
        insert row;
        Test.stopTest();

        System.assertEquals('Not specified', row.Subprocessor_Gate_Type__c);
        System.assertEquals('Not specified', row.Consent_Revocable__c);
        System.assertEquals('Not listed', row.Subprocessor_List_Location__c);
        System.assertEquals('Not specified', row.Subprocessor_List_Granularity__c);
        System.assertEquals('Not specified', row.Processing_Location_Gate__c);
        System.assertEquals('Not specified', row.Personal_Data_Disclosure_Gate__c);
        System.assertEquals('Low', row.LLM_Gate_Confidence__c, 'Silence routes to review at Low confidence');
        System.assertEquals(null, row.AI_Model_Change_Gate_Days__c, 'No day count -> null, not 0');
    }

    // ===== Email sanitization (INVALID_EMAIL_ADDRESS guard) =====

    @isTest
    static void sanitizeEmail_takesFirstValidAddress() {
        // Two addresses jammed in one value -> take the first, so the Email
        // field accepts it instead of failing the whole upsert.
        System.assertEquals('ffontana@arcanopartners.com',
            OrderFormExtractionJob.sanitizeEmail('ffontana@arcanopartners.com / rrodriguez@arcanopartners.com'));
        System.assertEquals('a@x.com', OrderFormExtractionJob.sanitizeEmail('a@x.com, b@y.com'));
        // Extracts a valid address out of surrounding prose.
        System.assertEquals('jane.doe@example.co.uk',
            OrderFormExtractionJob.sanitizeEmail('Contact: jane.doe@example.co.uk (billing)'));
        // A single clean address passes through.
        System.assertEquals('sole@firm.com', OrderFormExtractionJob.sanitizeEmail('sole@firm.com'));
        // Nothing that looks like an email -> null (never a malformed string).
        System.assertEquals(null, OrderFormExtractionJob.sanitizeEmail('see attached'));
        System.assertEquals(null, OrderFormExtractionJob.sanitizeEmail('   '));
        System.assertEquals(null, OrderFormExtractionJob.sanitizeEmail(null));
    }

    @isTest
    static void buildFromResponseBody_sanitizesDoubleEmail() {
        // End-to-end: a double-email value must not blow up the insert.
        Opportunity opp = insertOpp('Double Email Opp', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Primary_Contact_Email' => 'ffontana@arcanopartners.com / rrodriguez@arcanopartners.com',
            'Billing_Contact_Email' => 'ap@arcanopartners.com; backup@arcanopartners.com'
        });

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
            opp.Id, new List<Id>(), body);
        insert row; // would throw INVALID_EMAIL_ADDRESS without the sanitizer
        Test.stopTest();

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals('ffontana@arcanopartners.com', row.Primary_Contact_Email__c);
        System.assertEquals('ap@arcanopartners.com', row.Billing_Contact_Email__c);
    }

    // ===== Retry on malformed-JSON output =====

    // Returns a malformed-JSON body on the first callout, a valid one after.
    public class TwoShotMock implements HttpCalloutMock {
        public String firstBody;
        public String secondBody;
        public Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(callCount == 1 ? firstBody : secondBody);
            return r;
        }
    }

    @isTest
    static void extractionJob_retriesOnceOnMalformedJson() {
        Opportunity opp = insertOpp('Retry Opp', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        // First response: a text block whose JSON is invalid - a semicolon joins
        // two strings, exactly the SG failure. deserialize throws -> triggers retry.
        String badText = '{"Type": "New Business"; "note": "oops"}';
        String badBody = JSON.serialize(new Map<String, Object>{
            'model' => 'claude-sonnet-5', 'type' => 'message', 'role' => 'assistant',
            'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => badText } },
            'stop_reason' => 'end_turn'
        });
        String goodBody = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business', 'Seat_Licenses' => 9
        });

        TwoShotMock mock = new TwoShotMock();
        mock.firstBody = badBody;
        mock.secondBody = goodBody;

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Extraction_Status__c, Seat_Licenses__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id
            ORDER BY Extracted_At__c DESC LIMIT 1
        ];
        System.assertEquals(2, mock.callCount, 'A malformed first response must trigger exactly one retry');
        System.assertEquals('Success', row.Extraction_Status__c, 'The retry should recover to Success');
        System.assertEquals(9, row.Seat_Licenses__c, 'Fields come from the retry response');
    }

    @isTest
    static void extractionJob_parseFailsWhenBothAttemptsMalformed() {
        Opportunity opp = insertOpp('Retry Fail Opp', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__OrderForm');

        String badText = '{"Type": "New Business"; "x": 1}';
        String badBody = JSON.serialize(new Map<String, Object>{
            'model' => 'claude-sonnet-5', 'type' => 'message', 'role' => 'assistant',
            'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => badText } },
            'stop_reason' => 'end_turn'
        });

        TwoShotMock mock = new TwoShotMock();
        mock.firstBody = badBody;
        mock.secondBody = badBody; // retry also malformed

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Order_Form_Extraction__c row = [
            SELECT Extraction_Status__c, Error_Message__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id
            ORDER BY Extracted_At__c DESC LIMIT 1
        ];
        System.assertEquals(2, mock.callCount, 'Retried once');
        System.assertEquals('Parse Failed', row.Extraction_Status__c);
        System.assert(row.Error_Message__c.contains('original and retry'),
            'Error should note both attempts failed: ' + row.Error_Message__c);
    }

    // ===== Tolerate a free-text field returned as a JSON object/array =====

    @isTest
    static void populate_toleratesStructuredFreeTextField() {
        // The model occasionally returns a free-text field as an object/array
        // instead of a string. The row must still save (value stored as JSON),
        // not throw "Invalid conversion from Map<String,ANY> to String".
        Opportunity opp = insertOpp('Structured Free Text', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Subprocessor_Restrictions' => new Map<String, Object>{
                'consent' => 'prior written consent (MSA 10.5)',
                'notice'  => '30 days'
            },
            'Special_Terms' => new List<Object>{ 'term a', 'term b' }
        });

        Test.startTest();
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
            opp.Id, new List<Id>(), body);
        insert row;
        Test.stopTest();

        System.assertEquals('Success', row.Extraction_Status__c, 'A structured free-text value must not fail the row');
        System.assert(row.Subprocessor_Restrictions__c != null && row.Subprocessor_Restrictions__c.contains('consent'),
            'Structured restriction stored as JSON: ' + row.Subprocessor_Restrictions__c);
        System.assert(row.Special_Terms__c != null && row.Special_Terms__c.contains('term a'),
            'Structured special terms stored as JSON: ' + row.Special_Terms__c);
    }

    // =====================================================================
    // Extraction-quality fixes (classification, annualisation, increments,
    // credit rate, clamping, end dates, metered fields, versioning)
    // =====================================================================

    private static Map<String, Object> doc(Integer n, String grp, String cls) {
        return new Map<String, Object>{
            'file' => 'FILE ' + n + ' (' + (grp == 'Parent' ? 'PARENT CONTEXT' : 'CURRENT DEAL') + '): doc' + n,
            'group' => grp, 'class' => cls };
    }

    // ---- 1. Classification and the Success gate ----

    @isTest
    static void classification_noOrderFormClearsEconomicsAndSetsStatus() {
        // MidCap: the renewal's only paper was the MNDA plus the MSA.
        Opportunity opp = insertOpp('MidCap Renewal', 'Closed Won');
        String body = makeAnthropicResponseRaw(new Map<String, Object>{
            'Type' => 'Renewal',
            'Documents' => new List<Object>{ doc(1, 'Current', 'MNDA'), doc(2, 'Current', 'MSA') },
            'Contract_Start_Date' => '2024-01-01',      // the MSA's effective date
            'License_Fees' => 99000,                     // an MSA pricing exhibit
            'Recurring_Fees_Stated' => 99000,            // ...even if the model sums it
            'Annual_Recurring_Revenue' => 99000,         // ...or uses the legacy key
            'Credits_Added' => 5000,
            'Payment_Terms' => 'Annual'
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);

        System.assertEquals('No Order Form', row.Extraction_Status__c);
        System.assertEquals(null, row.License_Fees__c, 'MSA pricing is not this deal');
        System.assertEquals(null, row.Contract_Start_Date__c, 'MSA / MNDA dates are not the deal start');
        System.assertEquals(null, row.Annual_Recurring_Revenue__c, 'No order form -> no ARR from any key');
        System.assertEquals(null, row.Incremental_ARR__c);
        System.assertEquals(null, row.Credit_Rate__c);
        System.assertEquals('Annual', row.Payment_Terms__c, 'Legal terms from the MSA are still extracted');
        System.assert(row.Document_Classes__c.contains('=> MNDA') && row.Document_Classes__c.contains('=> MSA'),
            row.Document_Classes__c);
        System.assert(row.Error_Message__c.contains('No Order Form'), row.Error_Message__c);
    }

    @isTest
    static void classification_orderFormOnlyInParentContextIsNoOrderForm() {
        Opportunity opp = insertOpp('Parent Only OF', 'Closed Won');
        String body = makeAnthropicResponseRaw(new Map<String, Object>{
            'Documents' => new List<Object>{ doc(1, 'Current', 'MSA'), doc(2, 'Parent', 'Order Form') },
            'Contract_Start_Date' => '2026-01-01', 'Contract_Length_Months' => 12, 'Total_Contract_Value' => 50000
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);
        System.assertEquals('No Order Form', row.Extraction_Status__c, 'A parent-contract order form is context, not this deal');
    }

    @isTest
    static void classification_fileNumbersDecideCurrentVsParent() {
        System.assertEquals(true, OrderFormExtractionJob.isCurrentFile('FILE 1 (CURRENT DEAL): of', null, 1));
        System.assertEquals(false, OrderFormExtractionJob.isCurrentFile('FILE 2 (CURRENT DEAL): of', 'Current', 1),
            'File numbers beyond the current-deal count are parent context, whatever the model says');
        System.assertEquals(false, OrderFormExtractionJob.isCurrentFile('some file', 'Parent', null));
        System.assertEquals(true, OrderFormExtractionJob.isCurrentFile('some file', null, null));
        System.assertEquals('Order Form', OrderFormPicklistMapper.mapDocumentClass('Application Contract'));
        System.assertEquals('MNDA', OrderFormPicklistMapper.mapDocumentClass('Mutual Non-Disclosure Agreement'));
        System.assertEquals('DPA', OrderFormPicklistMapper.mapDocumentClass('Data Processing Agreement'));
        System.assertEquals('MSA', OrderFormPicklistMapper.mapDocumentClass('Master Subscription Agreement'));
        System.assertEquals('MSA', OrderFormPicklistMapper.mapDocumentClass('Standard Terms'), '"standard" is not an NDA');
        System.assertEquals('Other', OrderFormPicklistMapper.mapDocumentClass('W-9'));
    }

    @isTest
    static void statusGate_orderFormWithoutArrOrTcvIsIncomplete() {
        Opportunity opp = insertOpp('Thin OF', 'Closed Won');
        String body = makeAnthropicResponseRaw(new Map<String, Object>{
            'Type' => 'New Business',
            'Documents' => new List<Object>{ doc(1, 'Current', 'Order Form') },
            'Contract_Start_Date' => '2026-01-01', 'Contract_Length_Months' => 12, 'Seat_Licenses' => 5
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);
        System.assertEquals('Incomplete', row.Extraction_Status__c);
        System.assert(row.Error_Message__c.contains('ARR or TCV'), row.Error_Message__c);
    }

    @isTest
    static void statusGate_missingDatesIsIncomplete() {
        Opportunity opp = insertOpp('No Dates OF', 'Closed Won');
        String body = makeAnthropicResponseRaw(new Map<String, Object>{
            'Type' => 'New Business',
            'Documents' => new List<Object>{ doc(1, 'Current', 'Order Form') },
            'Total_Contract_Value' => 10000
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);
        System.assertEquals('Incomplete', row.Extraction_Status__c);
        System.assert(row.Error_Message__c.contains('start date') && row.Error_Message__c.contains('end date'),
            row.Error_Message__c);
    }

    // ---- 2. + 4. Annual normalisation and the credit rate (Nomura) ----

    @isTest
    static void annualise_termFiguresYieldArrCreditsPerYearAndRate() {
        // $1.7M and 110.5M credits stated for the whole 18-month subscription period.
        Opportunity opp = insertOpp('Nomura Term', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Contract_Start_Date' => '2026-01-01',
            'Contract_End_Date' => '2027-06-30',
            'Value_Basis' => 'Term',
            'License_Fees' => 1700000,
            'Recurring_Fees_Stated' => 1700000,
            'Total_Contract_Value' => 1700000,
            'Credits_Purchased' => 110500000,
            'Credits_Period' => 'contract'
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(18, row.Contract_Length_Months__c, 'Term length derived from the dates');
        System.assertEquals('Term', row.Value_Basis__c);
        System.assertEquals(1700000, row.License_Fees__c, 'Verbatim term figure is kept');
        System.assertEquals(1133333.33, row.Annual_Recurring_Revenue__c, '1.7M x 12/18');
        System.assertEquals(73666666.67, row.Credits_Per_Year__c, '110.5M x 12/18');
        System.assertEquals(0.015385, row.Credit_Rate__c, '1.7M / 110.5M');
        for (String f : new List<String>{ 'Annual_Recurring_Revenue', 'Credits_Per_Year', 'Credit_Rate', 'Contract_Length_Months' }) {
            System.assert(row.Derived_Fields__c.contains(f), f + ' should be marked derived: ' + row.Derived_Fields__c);
        }
        System.assert(row.Extract_Evidence__c.contains('"derived"'), row.Extract_Evidence__c);
    }

    @isTest
    static void annualise_annualFiguresPassThroughAndRateDerives() {
        // Harrison-style: $10,000 per year for 200,000 credits per year.
        Opportunity opp = insertOpp('Annual Credits', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Value_Basis' => 'Annual',
            'Recurring_Fees_Stated' => 10000,
            'Credits_Purchased' => 200000,
            'Credits_Period' => 'year',
            'Overage_Rate' => 0.04
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);
        System.assertEquals(10000, row.Annual_Recurring_Revenue__c);
        System.assertEquals(200000, row.Credits_Per_Year__c);
        System.assertEquals(0.05, row.Credit_Rate__c, 'Committed rate, not the 0.04 overage');
        System.assertEquals(0.04, row.Overage_Rate__c);
        System.assert(row.Derived_Fields__c == null || !row.Derived_Fields__c.contains('Annual_Recurring_Revenue'),
            'An annual stated figure is not derived: ' + row.Derived_Fields__c);
    }

    @isTest
    static void termMonths_handlesLeapAndOffByOneTerms() {
        System.assertEquals(12, OrderFormExtractionJob.termMonths(Date.newInstance(2027, 3, 1), Date.newInstance(2028, 2, 29)),
            'A 366-day leap-year term is still 12 months');
        System.assertEquals(12, OrderFormExtractionJob.termMonths(Date.newInstance(2026, 9, 30), Date.newInstance(2027, 9, 29)));
        System.assertEquals(12, OrderFormExtractionJob.termMonths(Date.newInstance(2026, 9, 30), Date.newInstance(2027, 9, 28)),
            'A paper a day short still reads 12');
        System.assertEquals(1.48, OrderFormExtractionJob.termMonths(Date.newInstance(2026, 1, 1), Date.newInstance(2026, 2, 14)));
        System.assertEquals(null, OrderFormExtractionJob.annualFactor('Term', null), 'Term basis needs a term length');
        System.assertEquals(4, OrderFormExtractionJob.creditFactor('quarter', null));
        System.assertEquals(0.5, OrderFormExtractionJob.creditRate(100, null, 200, null, true),
            'Both whole-term figures with no known length: direct ratio');
        System.assertEquals(null, OrderFormExtractionJob.creditRate(100, null, 200, 1, false));
    }

    // ---- 3. Amendment increments against the governing contract ----

    // A contract whose base deal already has a current extraction (ARR 100k,
    // 10 seats, 200k credits), plus an amendment opportunity on it.
    private static Opportunity governedAmendment(String type) {
        Account a = new Account(Name = 'Governed ' + type);
        insert a;
        Contract c = new Contract(AccountId = a.Id, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        insert c;
        Opportunity base = new Opportunity(Name = 'Governed Land', StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-30), AccountId = a.Id, Type = 'New Business', ContractId = c.Id);
        insertOppSafely(base);
        insert new Order_Form_Extraction__c(Opportunity__c = base.Id, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now().addDays(-30), Type__c = 'New Business',
            Contract_Start_Date__c = Date.today().addDays(-30), Contract_End_Date__c = Date.today().addDays(334),
            Annual_Recurring_Revenue__c = 100000, Seat_Licenses__c = 10,
            Credits_Purchased__c = 200000, Credits_Period__c = 'year', Applied_Contract__c = c.Id);
        Opportunity amend = new Opportunity(Name = 'Governed ' + type, StageName = '5 - Contracting',
            CloseDate = Date.today(), AccountId = a.Id, Type = type, Base_Opportunity__c = base.Id);
        insert amend;
        return amend;
    }

    @isTest
    static void amendment_restatedTotalsDeriveIncrementsAgainstGoverningContract() {
        Opportunity up = governedAmendment('Upsell');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Upsell', 'Value_Basis' => 'Annual',
            'Recurring_Fees_Stated' => 150000,   // the paper restates the whole contract
            'Seat_Licenses' => 15,
            'Credits_Purchased' => 300000, 'Credits_Period' => 'year'
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(), body);

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(150000, row.Resulting_ARR__c);
        System.assertEquals(150000, row.Annual_Recurring_Revenue__c, 'ARR on an amendment row = contract ARR after it');
        System.assertEquals(100000, row.Base_ARR__c);
        System.assertEquals(50000, row.Incremental_ARR__c);
        System.assertEquals(15, row.Resulting_Seats__c);
        System.assertEquals(5, row.Seats_Added__c);
        System.assertEquals(100000, row.Credits_Added__c);
        for (String f : new List<String>{ 'Incremental_ARR', 'Seats_Added', 'Credits_Added' }) {
            System.assert(row.Derived_Fields__c.contains(f), f + ': ' + row.Derived_Fields__c);
        }
        System.assert(row.Extract_Evidence__c.contains('prior paper'), row.Extract_Evidence__c);
    }

    @isTest
    static void amendment_incrementOnlyPaperDerivesResultingTotals_downsellSigned() {
        Opportunity dn = governedAmendment('Downsell');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'Downsell', 'Value_Basis' => 'Annual',
            'Incremental_Recurring_Fees' => 20000,   // stated as a positive reduction
            'Seats_Added' => 2,
            'Credits_Added' => 50000
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(dn.Id, new List<Id>(), body);

        System.assertEquals(-20000, row.Incremental_ARR__c, 'A downsell reduces ARR');
        System.assertEquals(80000, row.Resulting_ARR__c);
        System.assertEquals(80000, row.Annual_Recurring_Revenue__c);
        System.assertEquals(-2, row.Seats_Added__c);
        System.assertEquals(8, row.Resulting_Seats__c);
        System.assertEquals(-50000, row.Credits_Added__c);
        System.assertEquals(null, row.Credits_Per_Year__c, 'Only an increment was priced');
        System.assert(row.Derived_Fields__c.contains('Resulting_ARR') && row.Derived_Fields__c.contains('Resulting_Seats'),
            row.Derived_Fields__c);
    }

    @isTest
    static void creditRate_incrementOnlyFeeWithPaidAllocation() {
        // Lazard FA: "$316,350 per year for the Credit Allocation" of 15,817,500
        // credits per year, priced as an increment with no prior paper on file.
        Opportunity up = new Opportunity(Name = 'Lazard FA Credits', StageName = 'Closed Won',
            CloseDate = Date.today(), Type = 'Upsell');
        insertOppSafely(up);
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'Upsell', 'Value_Basis' => 'Annual',
                'Incremental_Recurring_Fees' => 316350,
                'Credits_Purchased' => 15817500, 'Credits_Period' => 'year',
                'Overage_Rate' => 0.02
            }));
        System.assertEquals(316350, row.Incremental_ARR__c);
        System.assertEquals(15817500, row.Credits_Per_Year__c);
        System.assertEquals(0.02, row.Credit_Rate__c, '316,350 / 15,817,500');
        System.assert(row.Derived_Fields__c.contains('Credit_Rate'), row.Derived_Fields__c);
    }

    // ---- Misreads found in the 2026-10-08 rerun ----

    @isTest
    static void parser_toleratesProseBeforeFencedJson() {
        // TTB Partners: a paragraph of reasoning, then the JSON in a code fence.
        String reply = 'Looking at the two documents, FILE 1 is the operative order form.\n\n```json\n'
            + '{"Type": "New Business", "Seat_Licenses": 7}\n```';
        System.assertEquals('{"Type": "New Business", "Seat_Licenses": 7}', OrderFormExtractionJob.extractJsonText(reply));
        System.assertEquals('{"a": 1}', OrderFormExtractionJob.extractJsonText('Here you go: {"a": 1} Done.'));
        System.assertEquals('{"a": "x"}', OrderFormExtractionJob.extractJsonText('```\n{"a": "x"}\n```'));
    }

    @isTest
    static void basis_monthlyFeeAnnualises() {
        // Centerview bridge: "$6,250 per month".
        Opportunity opp = insertOpp('Monthly Bridge', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Monthly', 'Recurring_Fees_Stated' => 6250,
                'Contract_Start_Date' => '2026-09-30', 'Contract_End_Date' => '2026-10-31' }));
        System.assertEquals('Monthly', row.Value_Basis__c);
        System.assertEquals(75000, row.Annual_Recurring_Revenue__c, '6,250 x 12');
        System.assert(row.Derived_Fields__c.contains('Annual_Recurring_Revenue'), row.Derived_Fields__c);
        System.assertEquals('Monthly', OrderFormPicklistMapper.mapValueBasis('per month'));
        System.assertEquals('Quarterly', OrderFormPicklistMapper.mapValueBasis('Quarterly'));
    }

    @isTest
    static void unitPrice_timesQuantityGivesRecurringFees() {
        // Wells Fargo: "$930 per license", 2,000 licenses, no annual total written.
        Opportunity opp = insertOpp('Unit Priced', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Annual',
                'Unit_Price' => 930, 'Unit_Quantity' => 2000, 'Seat_Licenses' => 2000,
                'Total_Contract_Value' => 1627500 }));
        System.assertEquals(1860000, row.Annual_Recurring_Revenue__c, '930 x 2,000');
        System.assertEquals(null, row.License_Fees__c, 'A unit price is not the license fee');
        System.assert(row.Extract_Evidence__c.contains('Unit price 930'), row.Extract_Evidence__c);

        // Arvo: "$70 per license per month", 9 licenses.
        Order_Form_Extraction__c monthly = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Monthly', 'Unit_Price' => 70, 'Unit_Quantity' => 9 }));
        System.assertEquals(7560, monthly.Annual_Recurring_Revenue__c, '70 x 9 x 12');
    }

    @isTest
    static void amendment_upsellTotalBelowContractIsTheIncrement() {
        // JPM PE: a new 50-seat schedule's "Total Annual Fee" under a much larger contract.
        Opportunity up = governedAmendment('Upsell');   // prior paper: 100k ARR, 10 seats, 200k credits
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'Upsell', 'Value_Basis' => 'Annual',
                'Recurring_Fees_Stated' => 46250, 'Seat_Licenses' => 5,
                'Credits_Purchased' => 50000, 'Credits_Period' => 'year' }));
        System.assertEquals(46250, row.Incremental_ARR__c, 'Read as the increment, not 46,250 - 100,000');
        System.assertEquals(146250, row.Resulting_ARR__c);
        System.assertEquals(146250, row.Annual_Recurring_Revenue__c);
        System.assertEquals(5, row.Seats_Added__c);
        System.assertEquals(15, row.Resulting_Seats__c);
        System.assertEquals(50000, row.Credits_Added__c);
        System.assertEquals(null, row.Credits_Per_Year__c, 'Only an increment was priced');
    }

    @isTest
    static void amendment_sameFigureAsTotalAndChangeIsTheChange() {
        // Mitsui: 5,500 reported as both; JPM true-up: 819 seats reported as both.
        Opportunity up = governedAmendment('Upsell');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'Upsell', 'Value_Basis' => 'Annual',
                'Recurring_Fees_Stated' => 5500, 'Incremental_Recurring_Fees' => 5500,
                'Seat_Licenses' => 12, 'Seats_Added' => 12 }));
        System.assertEquals(5500, row.Incremental_ARR__c);
        System.assertEquals(105500, row.Resulting_ARR__c, 'Prior 100k + 5,500, not 5,500');
        System.assertEquals(2, row.Seats_Added__c, '12 total - 10 prior');
        System.assertEquals(12, row.Resulting_Seats__c);
    }

    // ---- Found in the 2026-10-09 audit ----

    @isTest
    static void coTerm_amendmentWithNoEndOrTermRunsToBaseDealEnd() {
        // Macquarie / Tiger Global: the upsell paper says only "co-termed".
        Opportunity up = governedAmendment('Upsell');   // base paper ends today + 334
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'Upsell', 'Value_Basis' => 'Annual', 'Incremental_Recurring_Fees' => 10000,
                'Contract_Start_Date' => String.valueOf(Date.today()) }));
        System.assertEquals(Date.today().addDays(334), row.Contract_End_Date__c);
        System.assertEquals('Derived', row.End_Date_Source__c);
        System.assertNotEquals(null, row.Contract_Length_Months__c);
        System.assertEquals('Success', row.Extraction_Status__c, 'No longer Incomplete for a missing end date');
        System.assert(row.Extract_Evidence__c.contains('co-termed'), row.Extract_Evidence__c);
    }

    @isTest
    static void termTcvOnly_isTheSubscriptionFee() {
        // Partners Capital: "$7,500" for a 12-month term, reported only as TCV.
        Opportunity opp = insertOpp('TCV Only', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Term', 'Total_Contract_Value' => 7500,
                'Contract_Start_Date' => '2026-01-01', 'Contract_Length_Months' => 12 }));
        System.assertEquals(7500, row.Annual_Recurring_Revenue__c);
        System.assert(row.Derived_Fields__c.contains('Annual_Recurring_Revenue'), row.Derived_Fields__c);

        // A two-week paid trial's fee is not annualised into ARR.
        Order_Form_Extraction__c trial = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Term', 'Total_Contract_Value' => 5000,
                'Contract_Start_Date' => '2026-06-01', 'Contract_End_Date' => '2026-06-14' }));
        System.assertEquals(null, trial.Annual_Recurring_Revenue__c);
    }

    @isTest
    static void impossibleDateAndZeroRateAreDropped() {
        // Ribbit: "1026-01-31" sank a refresh chunk (Salesforce cannot store it).
        Opportunity opp = insertOpp('Bad Date', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Contract_Start_Date' => '1026-01-31', 'Contract_Length_Months' => 12,
                'Credit_Rate_Stated' => 0 }));
        System.assertEquals(null, row.Contract_Start_Date__c);
        System.assertEquals('Incomplete', row.Extraction_Status__c);
        insert row;
        System.assertEquals(null, row.Credit_Rate__c, 'A stated rate of 0 is not a rate');

        // William Blair: $500k licence / 250,000 credits = $2 a credit - not derived.
        Order_Form_Extraction__c ela = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'New Business', 'Value_Basis' => 'Annual', 'License_Fees' => 500000,
                'Credits_Purchased' => 250000, 'Credits_Period' => 'year' }));
        System.assertEquals(null, ela.Credit_Rate__c);
        System.assert(ela.Extract_Evidence__c.contains('implausible'), ela.Extract_Evidence__c);
    }

    // ---- 6. Clamp out-of-range numbers ----

    @isTest
    static void clamp_outOfRangeNumberKeepsRowAndRecordsRawValue() {
        Opportunity opp = insertOpp('Notice 2700', 'Closed Won');
        String body = makeAnthropicResponse(new Map<String, Object>{
            'Type' => 'New Business',
            'Subprocessor_Notice_Period_Days' => 2700,     // Number(3,0) holds 999
            'Renewal_Fee_Escalator_Percent' => 150          // Percent(2,0) holds 99
        });
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(), body);
        insert row;   // previously NUMBER_OUTSIDE_VALID_RANGE

        System.assertEquals('Success', row.Extraction_Status__c);
        System.assertEquals(999, row.Subprocessor_Notice_Period__c);
        System.assertEquals(99, row.Renewal_Fee_Escalator__c);
        System.assert(row.Derived_Fields__c.contains('Subprocessor_Notice_Period(clamped)'), row.Derived_Fields__c);
        System.assert(row.Extract_Evidence__c.contains('2700'), 'Raw value kept in evidence: ' + row.Extract_Evidence__c);
        System.assertEquals(999, OrderFormExtractionJob.maxForPrecision(3, 0));
        System.assertEquals(99999999999999.99, OrderFormExtractionJob.maxForPrecision(16, 2));
    }

    // ---- 7. Inclusive end date and its source ----

    @isTest
    static void endDate_sourceRecordsStatedNormalizedDerived() {
        Opportunity opp = insertOpp('End Date Sources', 'Closed Won');
        Order_Form_Extraction__c normalized = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Contract_Start_Date' => '2026-09-30', 'Contract_End_Date' => '2027-09-30' }));
        System.assertEquals(Date.newInstance(2027, 9, 29), normalized.Contract_End_Date__c);
        System.assertEquals('Normalized', normalized.End_Date_Source__c);
        System.assertEquals(12, normalized.Contract_Length_Months__c, 'Anniversary paper does not read as 12.03 months');

        Order_Form_Extraction__c derived = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Contract_Start_Date' => '2026-09-30', 'Contract_Length_Months' => 12 }));
        System.assertEquals(Date.newInstance(2027, 9, 29), derived.Contract_End_Date__c);
        System.assertEquals('Derived', derived.End_Date_Source__c);

        Order_Form_Extraction__c stated = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Contract_Start_Date' => '2026-09-30', 'Contract_End_Date' => '2027-09-29' }));
        System.assertEquals(Date.newInstance(2027, 9, 29), stated.Contract_End_Date__c);
        System.assertEquals('Stated', stated.End_Date_Source__c);
        System.assertEquals(12, stated.Contract_Length_Months__c);
    }

    // ---- 8. Metered-inference fields ----

    @isTest
    static void metered_statedCreditRateAndFreeTier() {
        Opportunity opp = insertOpp('Felix Light', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Recurring_Fees_Stated' => 10000, 'Value_Basis' => 'Annual',
                'Credits_Purchased' => 200000, 'Credits_Period' => 'year',
                'Credit_Rate_Stated' => 0.03, 'Free_Tier_Retained' => 'Yes'
            }));
        System.assertEquals(0.03, row.Credit_Rate__c, 'A stated rate wins over the derived one');
        System.assert(row.Derived_Fields__c == null || !row.Derived_Fields__c.contains('Credit_Rate'), row.Derived_Fields__c);
        System.assertEquals('Yes', row.Free_Tier_Retained__c);

        Order_Form_Extraction__c silent = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{ 'Type' => 'New Business' }));
        System.assertEquals('Not specified', silent.Free_Tier_Retained__c);
        System.assertEquals(null, silent.Overage_Rate__c);
    }

    // ---- 9. Version linking and the quality ladder ----

    private static Order_Form_Extraction__c completeRow(Id oppId, Boolean isCurrent) {
        return new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Extracted_At__c = System.now().addDays(-1), Is_Current__c = isCurrent,
            Contract_Start_Date__c = Date.newInstance(2026, 1, 1), Contract_End_Date__c = Date.newInstance(2026, 12, 31),
            Annual_Recurring_Revenue__c = 1000);
    }

    @isTest
    static void versioning_thinReextractionDoesNotDisplaceCompleteRow() {
        Opportunity opp = insertOpp('Keep Complete', 'Closed Won');
        Order_Form_Extraction__c complete = completeRow(opp.Id, true);
        insert complete;
        // A screenshot re-extraction: order form seen, but no dates / ARR / TCV.
        Order_Form_Extraction__c thin = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponseRaw(new Map<String, Object>{
                'Documents' => new List<Object>{ doc(1, 'Current', 'Order Form') }, 'Seat_Licenses' => 3 }));
        System.assertEquals('Incomplete', thin.Extraction_Status__c);

        Test.startTest();
        OrderFormVersioning.insertWithVersioning(new List<Order_Form_Extraction__c>{ thin });
        Test.stopTest();

        System.assertEquals(true, [SELECT Is_Current__c FROM Order_Form_Extraction__c WHERE Id = :complete.Id].Is_Current__c,
            'The complete row stays current');
        Order_Form_Extraction__c t = [SELECT Is_Current__c, Supersedes__c FROM Order_Form_Extraction__c WHERE Id = :thin.Id];
        System.assertEquals(false, t.Is_Current__c);
        System.assertEquals(complete.Id, t.Supersedes__c, 'Still linked into the version history');
    }

    @isTest
    static void versioning_noOrderFormReplacesHollowLegacySuccess() {
        Opportunity opp = insertOpp('Hollow Legacy', 'Closed Won');
        // Pre-fix MidCap row: "Success" with every economic field null.
        Order_Form_Extraction__c hollow = new Order_Form_Extraction__c(Opportunity__c = opp.Id,
            Extraction_Status__c = 'Success', Extracted_At__c = System.now().addDays(-1), Is_Current__c = true);
        insert hollow;
        Order_Form_Extraction__c fresh = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponseRaw(new Map<String, Object>{
                'Documents' => new List<Object>{ doc(1, 'Current', 'MNDA'), doc(2, 'Current', 'MSA') } }));

        Test.startTest();
        OrderFormVersioning.insertWithVersioning(new List<Order_Form_Extraction__c>{ fresh });
        Test.stopTest();

        System.assertEquals(false, [SELECT Is_Current__c FROM Order_Form_Extraction__c WHERE Id = :hollow.Id].Is_Current__c);
        Order_Form_Extraction__c f = [SELECT Is_Current__c, Supersedes__c, Extraction_Status__c FROM Order_Form_Extraction__c WHERE Id = :fresh.Id];
        System.assertEquals('No Order Form', f.Extraction_Status__c);
        System.assertEquals(true, f.Is_Current__c, 'The honest No Order Form row replaces the hollow Success');
        System.assertEquals(hollow.Id, f.Supersedes__c);
    }

    @isTest
    static void versioning_rankLadder() {
        Id oppId = insertOpp('Ladder', 'Closed Won').Id;
        System.assertEquals(3, OrderFormVersioning.rank(completeRow(oppId, false)));
        System.assertEquals(2, OrderFormVersioning.rank(new Order_Form_Extraction__c(Extraction_Status__c = 'Incomplete')));
        System.assertEquals(1, OrderFormVersioning.rank(new Order_Form_Extraction__c(Extraction_Status__c = 'No Order Form')));
        System.assertEquals(1, OrderFormVersioning.rank(new Order_Form_Extraction__c(Extraction_Status__c = 'Success')),
            'A legacy Success without the minimums ranks with No Order Form');
        System.assertEquals(0, OrderFormVersioning.rank(new Order_Form_Extraction__c(Extraction_Status__c = 'API Failed')));
        System.assertEquals(false, OrderFormVersioning.isAtLeastAsGood(
            new Order_Form_Extraction__c(Extraction_Status__c = 'Parse Failed'),
            new Order_Form_Extraction__c(Extraction_Status__c = 'API Failed')),
            'A failure never displaces anything');
        Order_Form_Extraction__c pilot = new Order_Form_Extraction__c(Extraction_Status__c = 'Success', Type__c = 'Pilot',
            Contract_Start_Date__c = Date.today(), Contract_End_Date__c = Date.today().addDays(30), Trial_Price__c = 0);
        System.assertEquals(3, OrderFormVersioning.rank(pilot), 'A pilot with dates and a stated fee (even 0) meets the minimums');
        pilot.Trial_Price__c = null;
        System.assertEquals(1, OrderFormVersioning.rank(pilot), 'A pilot whose fee was not read does not');
    }

    @isTest
    static void runRefresh_correctsHollowSuccessToNoOrderForm() {
        Opportunity opp = insertOpp('Refresh Hollow', 'Closed Won');
        attachSignedFile(opp.Id, 'signed__MNDA');
        Order_Form_Extraction__c hollow = new Order_Form_Extraction__c(Opportunity__c = opp.Id,
            Extraction_Status__c = 'Success', Extracted_At__c = System.now(), Is_Current__c = true);
        insert hollow;

        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponseRaw(new Map<String, Object>{
            'Documents' => new List<Object>{ doc(1, 'Current', 'MNDA') } });
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormBackfillBatch.runRefresh(Datetime.now().addMinutes(1));
        Test.stopTest();

        Order_Form_Extraction__c after = [SELECT Id, Extraction_Status__c, Is_Current__c
                                          FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id];
        System.assertEquals(hollow.Id, after.Id, 'Updated in place');
        System.assertEquals('No Order Form', after.Extraction_Status__c);
        System.assertEquals(true, after.Is_Current__c);
    }

    @isTest
    static void amendment_reextractionExcludesItsOwnAppliedRow() {
        // After the amendment is applied, its own row (and the contract totals it
        // fed) must not become its baseline - a refresh would otherwise derive 0.
        Opportunity up = governedAmendment('Upsell');
        Id contractId = [SELECT ContractId FROM Opportunity WHERE Id = :[SELECT Base_Opportunity__c FROM Opportunity WHERE Id = :up.Id].Base_Opportunity__c].ContractId;
        insert new Order_Form_Extraction__c(Opportunity__c = up.Id, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now().addDays(-1), Type__c = 'Upsell',
            Contract_Start_Date__c = Date.today(), Contract_End_Date__c = Date.today().addDays(364),
            Annual_Recurring_Revenue__c = 150000, Resulting_ARR__c = 150000, Resulting_Seats__c = 15,
            Credits_Purchased__c = 300000, Credits_Added__c = 100000, Applied_Contract__c = contractId);

        Order_Form_Extraction__c again = OrderFormExtractionJob.buildFromResponseBody(up.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Type' => 'Upsell', 'Value_Basis' => 'Annual', 'Recurring_Fees_Stated' => 150000,
                'Seat_Licenses' => 15, 'Credits_Purchased' => 300000, 'Credits_Period' => 'year' }));
        System.assertEquals(50000, again.Incremental_ARR__c, 'Same increment on re-extraction');
        System.assertEquals(5, again.Seats_Added__c);
        System.assertEquals(100000, again.Credits_Added__c);
    }

    @isTest
    static void endDate_dayTermAnniversaryIsNormalised() {
        Opportunity opp = insertOpp('90 Day Pilot', 'Closed Won');
        Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(opp.Id, new List<Id>(),
            makeAnthropicResponse(new Map<String, Object>{
                'Contract_Start_Date' => '2026-01-01', 'Contract_Length_Days' => 90, 'Contract_End_Date' => '2026-04-01' }));
        System.assertEquals(Date.newInstance(2026, 3, 31), row.Contract_End_Date__c, 'start + 90 days stated -> inclusive end');
        System.assertEquals('Normalized', row.End_Date_Source__c);
    }

    @isTest
    static void valueBasisAndShortTerms() {
        System.assertEquals('Annual', OrderFormPicklistMapper.mapValueBasis('Annual contract value'));
        System.assertEquals('Term', OrderFormPicklistMapper.mapValueBasis('for the Subscription Period'));
        System.assertEquals(null, OrderFormPicklistMapper.mapValueBasis('unclear'));
        System.assertEquals(0.10, OrderFormExtractionJob.termMonths(Date.newInstance(2026, 1, 1), Date.newInstance(2026, 1, 3)),
            'A 3-day term is not snapped to 0 months');
    }

    @isTest
    static void opportunityApplier_incompleteRowFillsBlankSeats() {
        // An email seat-add is Incomplete (no ARR/TCV) but its seats still reach the Opp.
        Opportunity opp = insertOpp('Email Seat Add', 'Closed Won');
        Order_Form_Extraction__c row = new Order_Form_Extraction__c(Opportunity__c = opp.Id,
            Extraction_Status__c = 'Incomplete', Extracted_At__c = System.now(), Type__c = 'Upsell',
            Seat_Licenses__c = 5, Applied_To_Opportunity__c = false);
        insert row;
        OrderFormApplier.Request req = new OrderFormApplier.Request();
        req.extractionId = row.Id;
        Test.startTest();
        OrderFormApplier.apply(new List<OrderFormApplier.Request>{ req });
        Test.stopTest();
        System.assertEquals(5, [SELECT Seat_Licenses__c FROM Opportunity WHERE Id = :opp.Id].Seat_Licenses__c);
    }
}
