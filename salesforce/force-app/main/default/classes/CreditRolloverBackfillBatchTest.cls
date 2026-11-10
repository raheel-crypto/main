@isTest
private class CreditRolloverBackfillBatchTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'Rollover_Test_Bypass', Label = 'Rollover Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    // Replies with the given rollover answer and keeps the request it was sent.
    private class RolloverMock implements HttpCalloutMock {
        Map<String, Object> answer;
        String requestBody;
        RolloverMock(Map<String, Object> answer) { this.answer = answer; }
        public HttpResponse respond(HttpRequest req) {
            requestBody = req.getBody();
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-sonnet-5',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } },
                'stop_reason' => 'end_turn',
                'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 50 }
            }));
            return r;
        }
    }

    private static Contract contractFor(Id accountId) {
        Contract c = new Contract(AccountId = accountId, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        insert c;
        return c;
    }

    private static Opportunity closedDeal(Id accountId, String name, Id contractId) {
        Opportunity o = new Opportunity(Name = name, StageName = 'Closed Won', CloseDate = Date.today().addDays(-30),
            AccountId = accountId, Type = 'New Business', ContractId = contractId);
        insert o;
        return o;
    }

    private static Order_Form_Extraction__c currentRow(Id oppId, Id contractId, Map<String, Object> values) {
        Order_Form_Extraction__c r = new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now().addDays(-20), Applied_Contract__c = contractId);
        for (String k : values.keySet()) r.put(k, values.get(k));
        insert r;
        return r;
    }

    private static void attach(Id parentId, String fileName) {
        insert new ContentVersion(Title = fileName.substringBeforeLast('.'), PathOnClient = fileName,
            VersionData = Blob.valueOf('%PDF-1.4 fake bytes for unit test'), FirstPublishLocationId = parentId);
    }

    @isTest
    static void readsOnlyRolloverAndAppliesItToTheContract() {
        Account a = new Account(Name = 'LionTree Test');
        insert a;
        Contract c = contractFor(a.Id);
        Opportunity creditDeal = closedDeal(a.Id, 'Credit Deal', c.Id);
        Order_Form_Extraction__c row = currentRow(creditDeal.Id, c.Id, new Map<String, Object>{
            'Credits_Purchased__c' => 1000000, 'Credits_Period__c' => 'year', 'License_Fees__c' => 50000 });
        attach(creditDeal.Id, 'Order Form.pdf');
        // A seats-only deal: outside a credit-deals pass.
        Opportunity seatsDeal = closedDeal(a.Id, 'Seats Deal', null);
        currentRow(seatsDeal.Id, null, new Map<String, Object>{ 'License_Fees__c' => 10000 });

        System.assertEquals(1, CreditRolloverBackfillBatch.countTargets(true));
        System.assertEquals(2, CreditRolloverBackfillBatch.countTargets(false));

        RolloverMock mock = new RolloverMock(new Map<String, Object>{
            'Credit_Rollover' => 'Partial', 'Credit_Rollover_Percent' => null,
            'Credit_Rollover_Terms' => 'Up to 20% of unused Credits will roll over from a Subscription Period.' });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Database.executeBatch(new CreditRolloverBackfillBatch(true), 1);
        Test.stopTest();

        Order_Form_Extraction__c after = [SELECT Credit_Rollover__c, Credit_Rollover_Percent__c, Credit_Rollover_Terms__c,
                                                 License_Fees__c, Credits_Purchased__c
                                          FROM Order_Form_Extraction__c WHERE Id = :row.Id];
        System.assertEquals('Partial', after.Credit_Rollover__c);
        System.assertEquals(20, after.Credit_Rollover_Percent__c, 'Read from the clause, as in a full read');
        System.assert(after.Credit_Rollover_Terms__c.startsWith('Up to 20%'), after.Credit_Rollover_Terms__c);
        System.assertEquals(50000, after.License_Fees__c, 'Nothing else on the row changes');
        System.assertEquals(1000000, after.Credits_Purchased__c);

        Contract contractAfter = [SELECT Credit_Rollover__c, Credit_Rollover_Percent__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Partial', contractAfter.Credit_Rollover__c);
        System.assertEquals(20, contractAfter.Credit_Rollover_Percent__c);

        // The model was asked the rollover question only.
        String systemPrompt = (String) ((Map<String, Object>) JSON.deserializeUntyped(mock.requestBody)).get('system');
        System.assert(systemPrompt.contains('CREDIT ROLLOVER:'), systemPrompt);
        System.assert(!systemPrompt.contains('SEAT ADDS BY EMAIL'), 'A focused prompt, not the full extraction');
    }

    @isTest
    static void notFoundStaysBlankWhenFilesWereLeftOut() {
        Account a = new Account(Name = 'Partial Read Co');
        insert a;
        Contract c = contractFor(a.Id);
        Opportunity deal = closedDeal(a.Id, 'Partial Read', c.Id);
        Order_Form_Extraction__c row = currentRow(deal.Id, c.Id, new Map<String, Object>{ 'Credit_Commit__c' => true });
        attach(deal.Id, 'Order Form.pdf');
        attach(deal.Id, 'Credit Addendum.xlsx');   // not readable here - the clause could be in it
        Test.setMock(HttpCalloutMock.class, new RolloverMock(new Map<String, Object>{ 'Credit_Rollover' => 'Not specified' }));

        Test.startTest();
        Database.executeBatch(new CreditRolloverBackfillBatch(true), 1);
        Test.stopTest();

        System.assertEquals(null, [SELECT Credit_Rollover__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Credit_Rollover__c,
            'Unknown, not "Not specified"');
    }

    @isTest
    static void notSpecifiedIsRecordedWhenEveryFileWasRead() {
        Account a = new Account(Name = 'Silent Co');
        insert a;
        Contract c = contractFor(a.Id);
        Opportunity deal = closedDeal(a.Id, 'Silent', c.Id);
        Order_Form_Extraction__c row = currentRow(deal.Id, c.Id, new Map<String, Object>{ 'Overage_Rate__c' => 0.02 });
        attach(deal.Id, 'Order Form.pdf');
        // Within-term use is not rollover: checked down to Not specified.
        Test.setMock(HttpCalloutMock.class, new RolloverMock(new Map<String, Object>{ 'Credit_Rollover' => 'Full',
            'Credit_Rollover_Terms' => 'Credits may be used at any point during the Initial Subscription Period.' }));

        Test.startTest();
        Database.executeBatch(new CreditRolloverBackfillBatch(true), 1);
        Test.stopTest();

        System.assertEquals('Not specified', [SELECT Credit_Rollover__c FROM Order_Form_Extraction__c WHERE Id = :row.Id].Credit_Rollover__c);
        System.assertEquals(null, [SELECT Credit_Rollover__c FROM Contract WHERE Id = :c.Id].Credit_Rollover__c,
            'Nothing to lay on the contract');
    }
}
