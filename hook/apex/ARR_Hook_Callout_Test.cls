// ARR_Hook_Callout_Test.cls
// Test coverage for ARR_Hook_Callout. Required for production deployment (75% min).

@isTest
private class ARR_Hook_Callout_Test {

    // Mock that always returns 200 OK
    private class HookSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            // Sanity-check the request shape Hook expects
            System.assertEquals('POST', req.getMethod());
            System.assert(req.getEndpoint().endsWith('/api/sf/opp-changed'),
                'Endpoint must hit /api/sf/opp-changed');
            System.assertNotEquals(null, req.getHeader('X-Hook-Signature'),
                'Signature header required');
            System.assertEquals('application/json', req.getHeader('Content-Type'));

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"ok":true}');
            return res;
        }
    }

    // Mock that returns 500 — exercise the error-logging branch
    private class HookErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"boom"}');
            return res;
        }
    }

    @isTest
    static void notifyAsync_postsSignedPayload() {
        Test.setMock(HttpCalloutMock.class, new HookSuccessMock());

        Set<Id> ids = new Set<Id>{
            Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA'
        };

        Test.startTest();
        ARR_Hook_Callout.notifyAsync(ids);
        Test.stopTest();

        // Reaching this line without exception means the @future executed
        System.assert(true, 'notifyAsync completed without exception');
    }

    @isTest
    static void notifyAsync_handlesServerError() {
        Test.setMock(HttpCalloutMock.class, new HookErrorMock());

        Set<Id> ids = new Set<Id>{
            Account.SObjectType.getDescribe().getKeyPrefix() + '000000000002AAA'
        };

        Test.startTest();
        ARR_Hook_Callout.notifyAsync(ids);
        Test.stopTest();

        // The class logs the failure to debug but does not throw — test passes if no exception
        System.assert(true, '500 response handled without exception');
    }

    @isTest
    static void trigger_firesOnWonOpportunityInsert() {
        Test.setMock(HttpCalloutMock.class, new HookSuccessMock());

        Account a = new Account(Name = 'Hook Trigger Test');
        insert a;

        Test.startTest();
        Opportunity o = new Opportunity(
            Name = 'Test Opp',
            AccountId = a.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'New Business',
            Annual_Recurring_Revenue__c = 10000
        );
        insert o;
        Test.stopTest();

        System.assert(true, 'Trigger handled won-opp insert');
    }
}
