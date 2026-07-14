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
            'model' => 'claude-sonnet-4-6',
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

    private static Opportunity insertOpp(String name, String stage) {
        Opportunity o = new Opportunity(Name = name, StageName = stage, CloseDate = Date.today());
        insert o;
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

        String evidence = '## Subprocessor_Notice_Period_Days\n' +
            '"Rogo shall provide Customer with no less than thirty (30) days\' prior written notice before adding, removing, or replacing any Subprocessor"\n' +
            '[source: MSA Section 9(f)]\n';

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
    static void extractionJob_subprocessorDefaultsTo30WhenAbsent() {
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
        System.assertEquals(30, row.Subprocessor_Notice_Period__c, 'Absent clause defaults to 30');
        System.assert(row.Extract_Evidence__c != null && row.Extract_Evidence__c.contains('Defaulted to 30'),
            'Default should be noted in evidence: ' + row.Extract_Evidence__c);
    }

    @isTest
    static void extractionJob_subprocessorConsentRestrictionWithDefault() {
        // Truist-style: written consent required, no day count -> default 30
        // for the notice period, restriction captured separately.
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
        System.assertEquals(30, row.Subprocessor_Notice_Period__c);
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
        insert opp;
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
        insert opps;
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
}
