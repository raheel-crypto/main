@isTest
private class OrderFormExtractorTest {

    private static String makeAnthropicResponse(Map<String, Object> extractedFields) {
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
        Opportunity opp = insertOpp('Seat Add Upsell', 'Closed Won');
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
                   License_Fees__c, Annual_Recurring_Revenue__c, Payment_Terms__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id LIMIT 1
        ];
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

        // The flagged (superseded) row is deleted; exactly one fresh, unflagged row remains.
        System.assertEquals(0, [SELECT COUNT() FROM Order_Form_Extraction__c WHERE Id = :flaggedRow.Id],
            'Flagged row should be deleted after re-extraction');
        List<Order_Form_Extraction__c> rows = [
            SELECT Id, Extraction_Status__c, Rerun__c
            FROM Order_Form_Extraction__c WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, rows.size(), 'Exactly one fresh extraction row should remain');
        System.assertEquals('Success', rows[0].Extraction_Status__c);
        System.assertEquals(false, rows[0].Rerun__c, 'New row must not be flagged');
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
}
