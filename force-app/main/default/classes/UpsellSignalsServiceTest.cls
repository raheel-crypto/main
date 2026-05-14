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
                'title' => 'Catch-up call',
                'gongCallId' => '111',
                'callStart' => Datetime.now().addDays(-1)
            },
            new Map<String, Object>{
                'title' => 'QBR',
                'gongCallId' => '222',
                'callStart' => Datetime.now().addDays(-3)
            },
            new Map<String, Object>{
                'title' => 'Executive sync',
                'gongCallId' => '333',
                'callStart' => Datetime.now().addDays(-5)
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
                System.assertEquals(5, s.contributionPoints, '3 calls, no upsell/concern terms -> +5 base');
                System.assert(s.detail.contains('3 calls'), 'detail mentions count: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_gongContentBumpsScoreWhenUpsellTalkPresent() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;
        UpsellSignalsService.gongCallsOverride = new List<Map<String, Object>>{
            new Map<String, Object>{
                'title' => 'Discovery',
                'callStart' => Datetime.now().addDays(-2),
                'brief' => 'Customer asked about adding more seats and tier ii pricing.',
                'keyPoints' => 'Interested in expansion to a second team.',
                'trackersJson' => '[{"name":"Expansion","count":3},{"name":"Pricing","count":1}]'
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
                // 1 call -> +3 base; +1 upsell hit; total +4 (clamped to +5 max)
                System.assertEquals(4, s.contributionPoints,
                    'upsell content in brief should add +1, got ' + s.contributionPoints);
                System.assert(s.detail.contains('upsell talk'), 'detail flags upsell talk: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_gongContentPenalizesWhenConcernTalkPresent() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;
        UpsellSignalsService.gongCallsOverride = new List<Map<String, Object>>{
            new Map<String, Object>{
                'title' => 'Renewal review',
                'callStart' => Datetime.now().addDays(-1),
                'brief' => 'Customer is frustrated about pricing and is evaluating a competitor.',
                'keyPoints' => 'Possible churn risk if renewal terms do not change.'
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
                // 1 call -> +3; -1 concern hit; +2 net
                System.assertEquals(2, s.contributionPoints,
                    'concern content should subtract, got ' + s.contributionPoints);
                System.assert(s.detail.contains('concern talk'), 'detail flags concern: ' + s.detail);
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
    static void compute_oppHistoryRewardsRenewalsPlusUpsells() {
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        insert a;
        insert new List<Opportunity>{
            new Opportunity(AccountId = a.Id, Name = 'NB',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-800),
                Type = 'New Business', Amount = 100000),
            new Opportunity(AccountId = a.Id, Name = 'R1',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-400),
                Type = 'Renewal', Amount = 110000),
            new Opportunity(AccountId = a.Id, Name = 'U1',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-300),
                Type = 'Upsell', Amount = 30000),
            new Opportunity(AccountId = a.Id, Name = 'U2',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-60),
                Type = 'Upsell', Amount = 45000),
            new Opportunity(AccountId = a.Id, Name = 'R2',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-35),
                Type = 'Renewal', Amount = 130000)
        };

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.62, 22.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'opp_cadence') {
                System.assertEquals('Opportunity History', s.label);
                System.assert(s.contributionPoints >= 12,
                    'sticky customer with active upsell pattern should score high, got ' + s.contributionPoints);
                System.assert(s.detail.contains('2 renewals'), 'detail mentions 2 renewals: ' + s.detail);
                System.assert(s.detail.contains('2 upsells'), 'detail mentions 2 upsells: ' + s.detail);
                System.assert(s.detail.contains('NB $100,000'), 'detail shows NB amount: ' + s.detail);
            }
        }
    }

    @IsTest
    static void compute_oppHistoryFlagsUnderMonetizationAndAmountDecline() {
        // Mirrors the real customer the user pushed back on:
        // 2-year customer, 2 renewals, 1 upsell, last renewal amount declined ($48K -> $42K)
        UpsellSignalsService.benchmarkCsvOverride = SAMPLE_CSV;
        UpsellSignalsService.bearerTokenOverride = 'test-token';
        UpsellSignalsService.skipNarrativeCall = true;

        Account a = buildAccount(true);
        insert a;
        insert new List<Opportunity>{
            new Opportunity(AccountId = a.Id, Name = 'NB',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-751),
                Type = 'New Business', Amount = 30000),
            new Opportunity(AccountId = a.Id, Name = 'U1',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-650),
                Type = 'Upsell', Amount = 6000),
            new Opportunity(AccountId = a.Id, Name = 'R1',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-400),
                Type = 'Renewal', Amount = 48000),
            new Opportunity(AccountId = a.Id, Name = 'R2',
                StageName = 'Closed Won', CloseDate = Date.today().addDays(-35),
                Type = 'Renewal', Amount = 42000)
        };

        Test.startTest();
        UpsellSignalsService.UpsellOutput out =
            UpsellSignalsService.compute(a.Id, 0.50, 0.85, 243.0);
        Test.stopTest();

        for (UpsellSignalsService.Signal s : out.signals) {
            if (s.key == 'opp_cadence') {
                System.assert(s.detail.contains('renewal amount declined'),
                    'should flag amount decline: ' + s.detail);
                System.assert(s.detail.contains('Renewal $48,000'),
                    'should show first renewal amount: ' + s.detail);
                System.assert(s.detail.contains('Renewal $42,000'),
                    'should show declining renewal amount: ' + s.detail);
                // 2 renewals(+6) + 1 upsell(+3) + 0 recency(>365d ago) + under-monetized(+4) - decline(-3) = 10
                System.assert(s.contributionPoints >= 8 && s.contributionPoints <= 12,
                    'under-monetized with amount decline should net mid-range, got ' + s.contributionPoints);
            }
        }
    }

    @IsTest
    static void compute_oppHistoryPenalizesDownsellType() {
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
                System.assert(s.detail.contains('1 downsell'),
                    'detail should call out the downsell: ' + s.detail);
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

    @IsTest
    static void getLastInsight_returnsNullWhenNothingSaved() {
        Account a = buildAccount(true);
        insert a;
        UpsellSignalsService.SavedInsight got =
            UpsellSignalsService.getLastInsight(a.Id);
        System.assertEquals(null, got);
    }

    @IsTest
    static void saveInsight_thenGetLast_roundTripsPayload() {
        Account a = buildAccount(true);
        insert a;
        String payload = '{"score":61,"metrics":{"dauWau":0.50}}';

        Test.startTest();
        UpsellSignalsService.SavedInsight savedReturn =
            UpsellSignalsService.saveInsight(a.Id, payload, 61);
        UpsellSignalsService.SavedInsight got =
            UpsellSignalsService.getLastInsight(a.Id);
        Test.stopTest();

        System.assertEquals(61, savedReturn.score);
        System.assertEquals(payload, savedReturn.payloadJson);
        System.assertNotEquals(null, savedReturn.lastRunAt);
        System.assertNotEquals(null, savedReturn.lastRunByName);

        System.assertEquals(61, got.score);
        System.assertEquals(payload, got.payloadJson);
    }

    @IsTest
    static void saveInsight_updatesExistingRecordInPlace() {
        Account a = buildAccount(true);
        insert a;

        UpsellSignalsService.saveInsight(a.Id, '{"score":40}', 40);
        UpsellSignalsService.saveInsight(a.Id, '{"score":61}', 61);

        UpsellSignalsService.SavedInsight got =
            UpsellSignalsService.getLastInsight(a.Id);
        System.assertEquals(61, got.score, 'should reflect second save');

        Integer count = [SELECT count() FROM Upsell_Insight__c WHERE Account__c = :a.Id];
        System.assertEquals(1, count, 'should only ever keep one row per account');
    }

    @IsTest
    static void saveInsight_requiresAccountIdAndPayload() {
        Account a = buildAccount(true);
        insert a;
        try {
            UpsellSignalsService.saveInsight(null, '{}', 50);
            System.assert(false, 'expected exception');
        } catch (AuraHandledException e) { /* expected */ }
        try {
            UpsellSignalsService.saveInsight(a.Id, null, 50);
            System.assert(false, 'expected exception');
        } catch (AuraHandledException e) { /* expected */ }
    }
}
