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
                    '"result":{"text":"{\\"account\\":\\"Acme\\",\\"enrolled\\":7,' +
                    '\\"dau_wau\\":{\\"mean\\":0.50,\\"min\\":0.347,\\"max\\":0.690,\\"commentary\\":\\"strong start, mid-period dip, partial recovery\\"},' +
                    '\\"wau_enrolled\\":{\\"mean\\":0.857,\\"min\\":0.714,\\"max\\":1.0,\\"commentary\\":\\"100% on several days, recovering to 85.7%\\"},' +
                    '\\"qpu\\":{\\"mean\\":74.0,\\"min\\":59.0,\\"max\\":99.0,\\"commentary\\":\\"exceptionally high engagement, peaked at 99 on May 14\\"}}",' +
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
        System.assertEquals(7, r.metrics.enrolled);

        System.assertNotEquals(null, r.metrics.dauWau);
        System.assertEquals(Decimal.valueOf('0.50'),  r.metrics.dauWau.mean);
        System.assertEquals(Decimal.valueOf('0.347'), r.metrics.dauWau.min);
        System.assertEquals(Decimal.valueOf('0.690'), r.metrics.dauWau.max);
        System.assert(r.metrics.dauWau.commentary.contains('dip'),
            'dauWau commentary should describe the trajectory');

        System.assertEquals(Decimal.valueOf('0.857'), r.metrics.wauEnrolled.mean);
        System.assertEquals(Decimal.valueOf('1.0'),   r.metrics.wauEnrolled.max);

        System.assertEquals(Decimal.valueOf('74.0'), r.metrics.qpu.mean);
        System.assertEquals(Decimal.valueOf('59.0'), r.metrics.qpu.min);
        System.assertEquals(Decimal.valueOf('99.0'), r.metrics.qpu.max);
    }

    @IsTest
    static void parseStat_acceptsLegacyFlatNumberAsMean() {
        // Old saved insights persist the metrics as plain numbers. The parser
        // wraps them as mean-only stats so cached records keep rendering.
        Object legacy = 0.42;
        RogoUsageInsightsController.MetricStat s =
            RogoUsageInsightsController.parseStat(legacy);
        System.assertEquals(Decimal.valueOf('0.42'), s.mean);
        System.assertEquals(null, s.min);
        System.assertEquals(null, s.max);
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

    private class NotFoundMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(404);
            res.setBody('{"error":{"status":"error","code":"job_not_found","message":"Job not found (may have expired)","retryable":false}}');
            return res;
        }
    }

    @IsTest
    static void fetchJob_returnsNotFoundStatusOn404InsteadOfThrowing() {
        RogoUsageInsightsController.bearerTokenOverride = 'test-token';
        Test.setMock(HttpCalloutMock.class, new NotFoundMock());

        Test.startTest();
        RogoUsageInsightsController.InsightsResult r =
            RogoUsageInsightsController.fetchJob('expired-or-misrouted-id');
        Test.stopTest();

        System.assertEquals('not_found', r.status);
        System.assertEquals('job_not_found', r.errorCode);
        System.assertNotEquals(null, r.errorMessage);
    }
}
