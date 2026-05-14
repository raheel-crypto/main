@IsTest
private class UpsellSignalsServiceTest {

    private static final String SAMPLE_CSV =
        'DIMENSION,GROUP_VALUE,CUSTOMER_COUNT,DAU_WAU_PCT,WAU_ENROLLED_PCT,QPU\n' +
        'Business Type,Investment Bank,108,46.0,59.1,19.4\n' +
        'Segment,Enterprise,51,45.8,59.0,19.0\n' +
        'Region,AMERICAS,189,46.1,57.4,19.0\n' +
        'Overall,All Customers,285,45.8,57.9,19.2\n';

    private class AskMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(202);
            res.setBody('{"job_id":"narr_xyz","status":"accepted","next_poll_after_ms":750}');
            return res;
        }
    }

    private static Account buildAccount(Boolean populateAll) {
        Account a = new Account(Name = 'Acme Capital');
        if (populateAll) {
            a.ARR__c = 250000;
            a.Estimated_TAM__c = 1500000;
            a.Total_Licenses__c = 18;
            a.Number_of_Bankers__c = 30;
            a.Account_Health_Score__c = 78;
            a.Business_Type__c = 'Investment Bank';
            a.Region__c = 'AMERICAS';
            a.Segment__c = 'Enterprise';
            a.Account_Tier__c = 'Tier I';
        }
        return a;
    }

    @IsTest
    static void compute_producesAllSixSignalsWhenDataPresent() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.gongCallsOverride = new List<Map<String, Object>>();
        Test.setMock(HttpCalloutMock.class, new AskMock());

        Account a = buildAccount(true);
        insert a;
        insert new List<Opportunity>{
            new Opportunity(AccountId = a.Id, Name = 'New Biz',
                StageName = 'Closed Won', IsPrivate = false,
                CloseDate = Date.today().addDays(-365), Type = 'New Business', Amount = 250000),
            new Opportunity(AccountId = a.Id, Name = 'Seat Bump',
                StageName = 'Closed Won', IsPrivate = false,
                CloseDate = Date.today().addDays(-90), Type = 'Upsell', Amount = 50000)
        };

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.62, 22.0);
        Test.stopTest();

        System.assertEquals('Acme Capital', out.accountName);
        System.assertEquals('Tier I', out.accountTier);
        System.assertEquals(6, out.signals.size());
        System.assert(out.score > 0, 'score should be > 0 with mostly green signals');
        System.assert(out.score <= 100);
        System.assertEquals('narr_xyz', out.narrativeJobId);

        Map<String, UpsellSignalsService.Signal> byKey = new Map<String, UpsellSignalsService.Signal>();
        for (UpsellSignalsService.Signal s : out.signals) byKey.put(s.key, s);

        System.assertEquals('present', byKey.get('usage_vs_benchmark').status);
        System.assertEquals('present', byKey.get('whitespace').status);
        System.assertEquals('present', byKey.get('arr_tam_gap').status);
        System.assertEquals('present', byKey.get('opp_cadence').status);
        System.assertEquals('present', byKey.get('health').status);
        System.assertEquals('present', byKey.get('gong_signals').status);
        System.assertEquals(0, byKey.get('gong_signals').contributionPoints,
            'no override calls -> 0 bonus');
    }

    @IsTest
    static void compute_gongBonusGrowsWithCallVolume() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;
        UpsellSignalsService.gongCallsOverride = new List<Map<String, Object>>{
            new Map<String, Object>{
                'title' => 'Discovery: expansion seats',
                'gongCallId' => '111',
                'createdDate' => Datetime.now().addDays(-1)
            },
            new Map<String, Object>{
                'title' => 'QBR',
                'gongCallId' => '222',
                'createdDate' => Datetime.now().addDays(-3)
            },
            new Map<String, Object>{
                'title' => 'Executive sync',
                'gongCallId' => '333',
                'createdDate' => Datetime.now().addDays(-5)
            }
        };

        Account a = buildAccount(true);
        insert a;

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.62, 22.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'gong_signals') {
                System.assertEquals(5, s.contributionPoints, '3 calls -> +5 bonus');
                System.assert(s.detail.contains('3 calls'), 'detail mentions count: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_flagsMissingFieldsWithoutCrashing() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(false);
        insert a;

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, null, null, null);
        Test.stopTest();

        Map<String, UpsellSignalsService.Signal> byKey = new Map<String, UpsellSignalsService.Signal>();
        for (UpsellSignalsService.Signal s : out.signals) byKey.put(s.key, s);

        System.assertEquals('missing', byKey.get('usage_vs_benchmark').status);
        System.assertEquals('missing', byKey.get('whitespace').status);
        System.assertEquals('missing', byKey.get('arr_tam_gap').status);
        System.assertEquals('missing', byKey.get('opp_cadence').status);
        System.assertEquals('missing', byKey.get('health').status);
        System.assertEquals(0, out.score);
    }

    @IsTest
    static void compute_picksMostSpecificBenchmarkRow() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        a.Business_Type__c = 'Investment Bank';
        insert a;

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.51, 0.66, 22.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'usage_vs_benchmark') {
                System.assert(s.detail.contains('46.0'), 'should use Investment Bank DAU peer 46.0, got: ' + s.detail);
                System.assert(s.detail.contains('19.4'), 'should use Investment Bank QPU peer 19.4');
            }
        }
    }

    @IsTest
    static void compute_fallsBackToOverallWhenNoBusinessType() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        a.Business_Type__c = null;
        a.Segment__c = null;
        a.Region__c = null;
        insert a;

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.45, 0.58, 19.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'usage_vs_benchmark') {
                System.assert(s.detail.contains('45.8'),
                    'should use Overall DAU peer 45.8, got: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_opportunityCadenceRewardsExpansionPattern() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        insert a;
        insert new List<Opportunity>{
            new Opportunity(AccountId = a.Id, Name = 'NB',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-300),
                Type = 'New Business', Amount = 100000),
            new Opportunity(AccountId = a.Id, Name = 'U1',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-200),
                Type = 'Upsell', Amount = 30000),
            new Opportunity(AccountId = a.Id, Name = 'U2',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-60),
                Type = 'Upsell', Amount = 45000)
        };

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.62, 22.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'opp_cadence') {
                System.assert(s.contributionPoints > 10,
                    'multi-upsell + sweet-spot tenure should score high, got ' + s.contributionPoints);
                System.assert(s.detail.contains('2 upsells'), 'detail should reflect 2 upsells: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_opportunityCadencePenalizesDownsell() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        insert a;
        insert new List<Opportunity>{
            new Opportunity(AccountId = a.Id, Name = 'NB',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-400),
                Type = 'New Business', Amount = 100000),
            new Opportunity(AccountId = a.Id, Name = 'DS',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-30),
                Type = 'Downsell', Amount = -20000)
        };

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.40, 0.50, 15.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'opp_cadence') {
                System.assert(s.detail.contains('1 downsell'), 'detail should call out the downsell: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_requiresAccountId() {
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;
        try {
            UpsellSignalsService.compute(null, 0.5, 0.5, 20.0);
            System.assert(false, 'expected exception');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    @IsTest
    static void compute_narrativeFailureAddsWarningButReturnsScore() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        // No bearerTokenOverride and no CMT record present -> narrative submit will throw, score still computes
        Account a = buildAccount(true);
        insert a;

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.62, 22.0);
        Test.stopTest();

        System.assertEquals(null, out.narrativeJobId, 'narrative should be skipped');
        System.assert(!out.warnings.isEmpty(), 'a warning should be recorded');
        System.assert(out.score > 0, 'score still computed');
    }
}
