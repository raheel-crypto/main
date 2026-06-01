@isTest
private class OrderFormExtractorTest {

    private static String makeAnthropicResponse(Map<String, Object> extractedFields) {
        Map<String, Object> textBlock = new Map<String, Object>{
            'type' => 'text',
            'text' => JSON.serialize(extractedFields)
        };
        Map<String, Object> envelope = new Map<String, Object>{
            'id' => 'msg_test',
            'type' => 'message',
            'role' => 'assistant',
            'model' => 'claude-sonnet-4-5',
            'content' => new List<Object>{ textBlock },
            'stop_reason' => 'end_turn',
            'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 200 }
        };
        return JSON.serialize(envelope);
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

    private static Opportunity insertOpp(String name, String stage) {
        Opportunity o = new Opportunity(
            Name = name,
            StageName = stage,
            CloseDate = Date.today()
        );
        insert o;
        return o;
    }

    private static void attachSignedFile(Id parentId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake pdf bytes for unit test'),
            FirstPublishLocationId = parentId
        );
        insert cv;
    }

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
        System.assertEquals(null, results[0].contentDocumentId);
    }

    @isTest
    static void happyPath_fillsBlanksOnNewBusiness() {
        Opportunity opp = insertOpp('Happy New Biz', '4 - Proposal');
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
            'Credit_Terms' => 'Net 30 days',
            'Billing_Contact_Email' => 'billing@customer.com',
            'Special_Terms' => 'MFN clause; standard MSA otherwise.'
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        System.assertEquals('Enqueued', results[0].status);
        System.assertEquals(1, mock.callCount);

        Opportunity after = [
            SELECT Type, Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
                   Seat_Licenses__c, Num_Users__c,
                   License_Fees__c, Total_Contract_Value__c, Amount, Annual_Recurring_Revenue__c,
                   Renewal_Terms__c, Subscription_Schedule__c, Payment_Terms__c, Credit_Terms__c,
                   Billing_Contact__c, Notes__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals('New Business', after.Type);
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
        System.assert(after.Notes__c != null && after.Notes__c.contains('MFN'), 'Notes should include special terms');
    }

    @isTest
    static void noOverwrite_existingValueWins() {
        Opportunity opp = new Opportunity(
            Name = 'Existing Seats Opp',
            StageName = '4 - Proposal',
            CloseDate = Date.today(),
            Seat_Licenses__c = 10
        );
        insert opp;
        attachSignedFile(opp.Id, 'signed__Customer_Agreement');

        Map<String, Object> extracted = new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 12
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Opportunity after = [SELECT Seat_Licenses__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(10, after.Seat_Licenses__c, 'Existing human-entered value must not be overwritten');
    }

    @isTest
    static void pilotPath_routesToTrialFields() {
        Opportunity opp = insertOpp('Pilot Opp', '3 - POV');
        attachSignedFile(opp.Id, 'signed__Pilot_Agreement');

        Map<String, Object> extracted = new Map<String, Object>{
            'Type' => 'Pilot',
            'Contract_Start_Date' => '2026-06-15',
            'Contract_End_Date' => '2026-08-15',
            'Contract_Length_Days' => 60,
            'Seat_Licenses' => 5,
            'License_Fees' => 25000,
            'Paid_Trial' => true,
            'Pilot_Success_Criteria' => 'Adoption by 80% of users within 30 days.'
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Opportunity after = [
            SELECT Type, Trial_Start_Date__c, Trial_End_Date__c, Trial_Length_Days__c,
                   Trial_Users__c, Trial_Price__c, Paid_Trial__c, Pilot_Success_Criteria__c,
                   Contract_Start_Date__c, Contract_End_Date__c, License_Fees__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals(Date.newInstance(2026, 6, 15), after.Trial_Start_Date__c);
        System.assertEquals(Date.newInstance(2026, 8, 15), after.Trial_End_Date__c);
        System.assertEquals(60, after.Trial_Length_Days__c);
        System.assertEquals(5, after.Trial_Users__c);
        System.assertEquals(25000, after.Trial_Price__c);
        System.assertEquals(true, after.Paid_Trial__c);
        System.assertEquals('Adoption by 80% of users within 30 days.', after.Pilot_Success_Criteria__c);
        System.assertEquals(null, after.Contract_Start_Date__c, 'Pilot should not write Contract_Start_Date__c');
        System.assertEquals(null, after.License_Fees__c, 'Pilot should not write License_Fees__c');
    }

    @isTest
    static void apiFailure_oppUnchanged() {
        Opportunity opp = insertOpp('API Fail Opp', '4 - Proposal');
        attachSignedFile(opp.Id, 'signed__Whatever');

        MockAnthropic mock = new MockAnthropic();
        mock.statusCode = 500;
        mock.responseBody = '{"error":"internal"}';

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        List<OrderFormExtractor.Result> results = OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        try {
            Test.stopTest();
        } catch (Exception e) {
            // Some Apex versions surface uncaught Queueable exceptions here; either way is fine.
        }

        System.assertEquals('Enqueued', results[0].status, 'Invocable still returns Enqueued (failure is async)');

        Opportunity after = [SELECT Type, License_Fees__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('New Business', after.Type, 'Type stays at the picklist default; no update fired');
        System.assertEquals(null, after.License_Fees__c, 'No callout-derived fields should be written when callout fails');
    }

    @isTest
    static void amendmentPath_onlyChangedFieldsWritten() {
        Opportunity opp = insertOpp('Rider Opp', '5 - Contracting');
        attachSignedFile(opp.Id, 'signed__Rider_April');

        Map<String, Object> extracted = new Map<String, Object>{
            '_is_amendment' => true,
            'Type' => 'Renewal',
            'Contract_End_Date' => '2027-04-30',
            'Seat_Licenses' => 50
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

        OrderFormExtractor.Request req = new OrderFormExtractor.Request();
        req.opportunityId = opp.Id;

        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        Test.stopTest();

        Opportunity after = [
            SELECT Type, Contract_Start_Date__c, Contract_End_Date__c, Seat_Licenses__c, License_Fees__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals(Date.newInstance(2027, 4, 30), after.Contract_End_Date__c);
        System.assertEquals(50, after.Seat_Licenses__c);
        System.assertEquals(null, after.Contract_Start_Date__c, 'Unchanged-by-rider fields stay null');
        System.assertEquals(null, after.License_Fees__c);
    }

    @isTest
    static void picklistMapper_directValues() {
        System.assertEquals('Auto-renew (90-day)', OrderFormPicklistMapper.mapRenewalTerms('renews unless 90 days notice'));
        System.assertEquals('Auto-renew (60-day)', OrderFormPicklistMapper.mapRenewalTerms('auto with 60 day notice'));
        System.assertEquals('Auto-renew (30-day)', OrderFormPicklistMapper.mapRenewalTerms('evergreen'));
        System.assertEquals('Manual renewal', OrderFormPicklistMapper.mapRenewalTerms('mutual written agreement'));
        System.assertEquals('Net-30', OrderFormPicklistMapper.mapCreditTerms('Net 30 days'));
        System.assertEquals('Net-15', OrderFormPicklistMapper.mapCreditTerms('NET-15'));
        System.assertEquals('Annual', OrderFormPicklistMapper.mapSubscriptionSchedule('Billed annually'));
        System.assertEquals('Quarterly', OrderFormPicklistMapper.mapSubscriptionSchedule('every quarter'));
        System.assertEquals('Pilot', OrderFormPicklistMapper.mapType('Proof of Concept'));
        System.assertEquals('Renewal', OrderFormPicklistMapper.mapType('annual renewal'));
        System.assertEquals('Upsell', OrderFormPicklistMapper.mapType('expansion order'));
        System.assertEquals('New Business', OrderFormPicklistMapper.mapType('NEW BUSINESS'));
        System.assertEquals('Seats: Unlimited Usage, with Throttling', OrderFormPicklistMapper.mapPricingStructure('unlimited usage subject to fair use'));
        System.assertEquals('ELA: Credit-Based Usage', OrderFormPicklistMapper.mapPricingStructure('Enterprise license with credit pool'));
        System.assertEquals(null, OrderFormPicklistMapper.mapRenewalTerms(null));
        System.assertEquals(null, OrderFormPicklistMapper.mapCreditTerms('whenever'));
    }

    @isTest
    static void bulk_invocablePreservesOrder() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Opp ' + i,
                StageName = '4 - Proposal',
                CloseDate = Date.today()
            ));
        }
        insert opps;
        // Attach file to only the even-indexed ones
        for (Integer i = 0; i < opps.size(); i++) {
            if (Math.mod(i, 2) == 0) attachSignedFile(opps[i].Id, 'signed__Bulk_' + i);
        }

        Map<String, Object> extracted = new Map<String, Object>{
            'Type' => 'New Business',
            'Seat_Licenses' => 7
        };
        MockAnthropic mock = new MockAnthropic();
        mock.responseBody = makeAnthropicResponse(extracted);

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

        System.assertEquals(5, results.size());
        for (Integer i = 0; i < results.size(); i++) {
            String expected = Math.mod(i, 2) == 0 ? 'Enqueued' : 'NoDocumentFound';
            System.assertEquals(expected, results[i].status, 'Result ' + i + ' wrong status');
        }
    }
}
