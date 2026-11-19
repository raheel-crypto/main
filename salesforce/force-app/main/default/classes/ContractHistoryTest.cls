@isTest
private class ContractHistoryTest {

    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'CHist_Test_Bypass', Label = 'CHist Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    public class ClaudeMock implements HttpCalloutMock {
        public Integer calls = 0;
        public Integer status = 200;
        public String lastBody;
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            // Other automation in the org may call out when a contract is saved: answer, but count only Claude.
            if (req.getEndpoint() == null || !req.getEndpoint().contains('Anthropic_Claude')) {
                r.setStatusCode(200);
                r.setBody('{}');
                return r;
            }
            calls++;
            lastBody = req.getBody();
            r.setStatusCode(status);
            r.setBody(status != 200 ? '{"type":"error","error":{"message":"overloaded"}}' : JSON.serialize(
                new Map<String, Object>{ 'stop_reason' => 'end_turn', 'content' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'thinking', 'thinking' => '' },
                    new Map<String, Object>{ 'type' => 'text', 'text' => '2025-09-22 New business ... Open items: None.' } } }));
            return r;
        }
    }

    private static Contract contractWithDeal() {
        Account a = new Account(Name = 'History Co');
        insert a;
        Contract c = new Contract(AccountId = a.Id, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        insert c;
        Opportunity o = new Opportunity(Name = 'History NB', StageName = 'Closed Won', AccountId = a.Id,
            Type = 'New Business', CloseDate = Date.today().addDays(-30), ContractId = c.Id);
        insert o;
        insert new Order_Form_Extraction__c(Opportunity__c = o.Id, Extraction_Status__c = 'Success', Is_Current__c = true,
            Extracted_At__c = System.now(), Applied_Contract__c = c.Id, Seat_Licenses__c = 25, License_Fees__c = 150000,
            Credit_Transition_End_Date__c = Date.newInstance(2026, 10, 14));
        update new Contract(Id = c.Id, Contract_History_Stale__c = true, Payment_Terms__c = 'Annual');
        return c;
    }

    private static void model(String name) {
        OrderFormReviewer.settingsOverride = new Order_Form_Review_Setting__mdt(Mode__c = 'Shadow', History_Model__c = name);
    }

    @isTest
    static void writesTheHistoryOnceForTheSameFacts() {
        Contract c = contractWithDeal();
        model('claude-sonnet-5-5');
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);

        String facts = ContractHistory.facts(c.Id);
        System.assert(facts.contains('Deal 1: History NB (New Business, closed '), facts);
        System.assert(facts.contains('- Seats (total): 25'), facts);
        System.assert(facts.contains('- Credit transition period ends: 2026-10-14'), facts);
        System.assert(facts.contains('- Payment schedule: Annual'), facts);
        System.assert(facts.contains('CONTRACT TERM CHANGES\n(none)'), facts);

        Test.startTest();
        System.enqueueJob(new ContractHistoryJob());
        Test.stopTest();

        Contract after = [SELECT Contract_History__c, Contract_History_Hash__c, Contract_History_Stale__c,
                                 Contract_History_Updated__c, Contract_History_Note__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals('2025-09-22 New business ... Open items: None.', after.Contract_History__c);
        System.assertEquals(false, after.Contract_History_Stale__c);
        System.assertEquals(ContractHistory.hashOf(facts, 'claude-sonnet-5-5'), after.Contract_History_Hash__c);
        System.assertNotEquals(null, after.Contract_History_Updated__c);
        System.assertEquals(1, mock.calls);
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastBody);
        System.assertEquals('claude-sonnet-5-5', sent.get('model'));
        System.assert(String.valueOf(sent.get('system')).startsWith('You write the running history'));

        // Marked again with the same facts: no new call.
        update new Contract(Id = c.Id, Contract_History_Stale__c = true);
        new ContractHistoryJob().execute(null);
        System.assertEquals(1, mock.calls, 'unchanged facts are not sent again');
        System.assertEquals(false, [SELECT Contract_History_Stale__c FROM Contract WHERE Id = :c.Id].Contract_History_Stale__c);
    }

    @isTest
    static void aFailedCallIsNotedAndNotRetried() {
        Contract c = contractWithDeal();
        model('claude-sonnet-5-5');
        ClaudeMock mock = new ClaudeMock();
        mock.status = 529;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new ContractHistoryJob(new Set<Id>{ c.Id }));
        Test.stopTest();
        Contract after = [SELECT Contract_History__c, Contract_History_Stale__c, Contract_History_Note__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals(null, after.Contract_History__c);
        System.assertEquals(false, after.Contract_History_Stale__c);
        System.assert(after.Contract_History_Note__c.contains('HTTP 529'), after.Contract_History_Note__c);
    }

    @isTest
    static void noModel_noHistory() {
        Contract c = contractWithDeal();
        model(null);
        ClaudeMock mock = new ClaudeMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new ContractHistoryJob());
        Test.stopTest();
        System.assertEquals(0, mock.calls);
        System.assertEquals(false, [SELECT Contract_History_Stale__c FROM Contract WHERE Id = :c.Id].Contract_History_Stale__c);
    }

    @isTest
    static void theNightlyRunBringsHistoriesUpToDate() {
        contractWithDeal();
        model('claude-sonnet-5-5');
        Test.setMock(HttpCalloutMock.class, new ClaudeMock());
        Test.startTest();
        String message = ContractRefresh.run();
        Test.stopTest();
        System.assert(message.contains('1 contract history(ies) to bring up to date'), message);
        System.assertEquals(0, [SELECT COUNT() FROM Contract WHERE Contract_History_Stale__c = true]);
    }
}
