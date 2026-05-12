@IsTest
private class RogoUsageInsightsControllerTest {

    private class AskMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/api/ask')) {
                res.setStatusCode(202);
                res.setBody('{"job_id":"abc123","status":"accepted","next_poll_after_ms":750}');
            } else if (req.getEndpoint().contains('/api/jobs/')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"status":"completed","progress":1.0,' +
                    '"result":{"text":"{\\"account\\":\\"Acme\\",\\"dau\\":12,\\"wau\\":40,' +
                    '\\"enrolled\\":100,\\"queries\\":250,\\"dau_wau\\":0.3,' +
                    '\\"wau_enrolled\\":0.4,\\"qpu\\":6.25}",' +
                    '"analysis_mode":"sql_grounded"}}'
                );
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":{"code":"not_found","message":"unknown route"}}');
            }
            return res;
        }
    }

    private class FailedJobMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"status":"failed","error_info":{"code":"ask_failed","message":"upstream timeout"}}');
            return res;
        }
    }

    @IsTest
    static void submitJob_returnsAcceptedJob() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        Account a = new Account(Name = 'Acme');
        insert a;
        Test.setMock(HttpCalloutMock.class, new AskMock());

        Test.startTest();
        RogoUsageInsightsController.InsightsJob job =
            RogoUsageInsightsController.submitJob(a.Id);
        Test.stopTest();

        System.assertEquals('abc123', job.jobId);
        System.assertEquals('accepted', job.status);
        System.assertEquals(750, job.nextPollAfterMs);
    }

    @IsTest
    static void fetchJob_parsesMetricsFromAnswer() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        Test.setMock(HttpCalloutMock.class, new AskMock());

        Test.startTest();
        RogoUsageInsightsController.InsightsResult r =
            RogoUsageInsightsController.fetchJob('abc123');
        Test.stopTest();

        System.assertEquals('completed', r.status);
        System.assertNotEquals(null, r.metrics);
        System.assertEquals('Acme', r.metrics.accountName);
        System.assertEquals(12, r.metrics.dau);
        System.assertEquals(40, r.metrics.wau);
        System.assertEquals(100, r.metrics.enrolled);
        System.assertEquals(250, r.metrics.queries);
        System.assertEquals(Decimal.valueOf('0.3'), r.metrics.dauWau);
        System.assertEquals(Decimal.valueOf('0.4'), r.metrics.wauEnrolled);
        System.assertEquals(Decimal.valueOf('6.25'), r.metrics.qpu);
    }

    @IsTest
    static void fetchJob_handlesFailedJobs() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        Test.setMock(HttpCalloutMock.class, new FailedJobMock());

        Test.startTest();
        RogoUsageInsightsController.InsightsResult r =
            RogoUsageInsightsController.fetchJob('failedJob');
        Test.stopTest();

        System.assertEquals('failed', r.status);
        System.assertEquals('ask_failed', r.errorCode);
        System.assertEquals('upstream timeout', r.errorMessage);
        System.assertEquals(null, r.metrics);
    }

    @IsTest
    static void parseJobResponse_skipsMetricsWhenNoJsonBlock() {
        String body = '{"status":"running","progress":0.5}';
        RogoUsageInsightsController.InsightsResult r =
            RogoUsageInsightsController.parseJobResponse(body);
        System.assertEquals('running', r.status);
        System.assertEquals(Decimal.valueOf('0.5'), r.progress);
        System.assertEquals(null, r.metrics);
    }

    @IsTest
    static void extractMetrics_returnsNullOnMalformedJson() {
        RogoUsageInsightsController.Metrics m =
            RogoUsageInsightsController.extractMetrics('no json here at all');
        System.assertEquals(null, m);
    }

    @IsTest
    static void submitJob_requiresAccountId() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        try {
            RogoUsageInsightsController.submitJob(null);
            System.assert(false, 'expected exception');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    @IsTest
    static void fetchJob_requiresJobId() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        try {
            RogoUsageInsightsController.fetchJob('');
            System.assert(false, 'expected exception');
        } catch (AuraHandledException e) {
            // expected
        }
    }
}
