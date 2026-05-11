@IsTest
private class PGGtmInsightsControllerTest {

    private static final String LOADER_PERMSET = 'PG_Insights_Test_Loader';

    @TestSetup
    static void setupData() {
        // Create a UserRole named 'GTM Associate' so the controller's role
        // filter picks up the test GTM users.
        String suffix = String.valueOf(System.currentTimeMillis());
        UserRole gtmRole = new UserRole(
            Name = 'GTM Associate',
            DeveloperName = 'GtmAssoc_' + suffix
        );
        insert gtmRole;

        // Loader user with Bypass_Validations to seed opps freely.
        User loader = buildLoaderUser();
        insert loader;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :LOADER_PERMSET LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = loader.Id, PermissionSetId = ps.Id);

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>{
            buildUser('gtm1', 'GTM', 'One',   gtmRole.Id, 'GTM Associate', p.Id),
            buildUser('gtm2', 'GTM', 'Two',   gtmRole.Id, 'GTM Associate', p.Id),
            // Non-GTM user (no role, Title doesn't match) — should NOT appear.
            buildUser('nope', 'Not', 'GTM',   null,       'Account Executive', p.Id)
        };
        insert users;

        Map<String, Id> uByAlias = new Map<String, Id>();
        for (User u : users) uByAlias.put(u.Alias, u.Id);

        System.runAs(loader) {
            // gtm1 books 5 opps; 3 of them will be "qualified" via mock.
            // gtm2 books 2 opps; 1 qualified via mock.
            List<Opportunity> opps = new List<Opportunity>();
            for (Integer i = 0; i < 5; i++) {
                opps.add(buildOpp(uByAlias.get('gtm1'), 'New Business', '1 - Demo'));
            }
            for (Integer i = 0; i < 2; i++) {
                opps.add(buildOpp(uByAlias.get('gtm2'), 'Upsell', '1 - Demo'));
            }
            // One opp booked by the non-GTM user — must NOT count.
            opps.add(buildOpp(uByAlias.get('nope'), 'New Business', '1 - Demo'));
            insert opps;

            // Outreach activity
            insert new List<Task>{
                buildEmailTask(uByAlias.get('gtm1')),
                buildEmailTask(uByAlias.get('gtm1')),
                buildCallTask(uByAlias.get('gtm2')),
                buildLinkedInTask(uByAlias.get('gtm1'))
            };
            insert new List<Event>{
                buildEvent(uByAlias.get('gtm1')),
                buildEvent(uByAlias.get('gtm2'))
            };

            // Quotas: only gtm1 has goals (reusing NB_Goal / NB_Amount_Goal).
            Organization org = [SELECT FiscalYearStartMonth FROM Organization LIMIT 1];
            Integer startMonth = org.FiscalYearStartMonth;
            Date today = Date.today();
            Integer monthOffset = today.month() - startMonth;
            if (monthOffset < 0) monthOffset += 12;
            Integer fq = (monthOffset / 3) + 1;
            Integer fy = (startMonth == 1)
                ? today.year()
                : (today.month() >= startMonth ? today.year() + 1 : today.year());
            insert new List<PG_Quota__c>{
                new PG_Quota__c(
                    User__c = uByAlias.get('gtm1'),
                    Fiscal_Year__c = fy,
                    Fiscal_Quarter__c = fq,
                    NB_Goal__c = 20,
                    NB_Amount_Goal__c = 400000
                )
            };
        }
    }

    @IsTest
    static void getGtmStatus_qtdAggregatesBookedAndQualified() {
        PGGtmInsightsController.mockFirstStage2PlusByOpp = buildQualifiedMock(4);
        Test.startTest();
        PGGtmInsightsController.GtmStatus s = PGGtmInsightsController.getGtmStatus('QTD');
        Test.stopTest();

        // 5 (gtm1) + 2 (gtm2) = 7 booked. Non-GTM user's opp excluded.
        System.assertEquals(7, s.booked, 'Total opps booked by GTMs');
        System.assertEquals(4, s.qualified, 'Mock marks 4 as qualified');
        // 4 / 7 ≈ 57.14%
        System.assert(s.passThroughPct > 50 && s.passThroughPct < 60,
            'Pass-through % in expected range');
        // 7 opps × 50K = 350K booked $.
        System.assertEquals(350000, s.bookedAmount, 'Booked amount sum');
        System.assert(s.goal > 0, 'Goal prorated from gtm1 quota (NB_Goal=20)');
    }

    @IsTest
    static void getGtmStatus_cmHasShorterWindow() {
        PGGtmInsightsController.mockFirstStage2PlusByOpp = buildQualifiedMock(2);
        Test.startTest();
        PGGtmInsightsController.GtmStatus s = PGGtmInsightsController.getGtmStatus('CM');
        Test.stopTest();

        // Current calendar month includes today's seed inserts.
        System.assert(s.booked >= 1, 'CM window picks up today-inserted opps');
        System.assert(s.qualified <= s.booked, 'Qualified <= Booked');
    }

    @IsTest
    static void getGtmRanking_initializesEveryGtmEvenWithZeroBookings() {
        PGGtmInsightsController.mockFirstStage2PlusByOpp = buildQualifiedMock(0);
        Test.startTest();
        List<PGGtmInsightsController.GtmRow> rows =
            PGGtmInsightsController.getGtmRanking('QTD');
        Test.stopTest();

        Set<String> names = new Set<String>();
        for (PGGtmInsightsController.GtmRow r : rows) names.add(r.ownerName);
        System.assert(names.contains('GTM One'), 'gtm1 in ranking');
        System.assert(names.contains('GTM Two'), 'gtm2 in ranking');
        System.assert(!names.contains('Not GTM'),
            'Non-GTM user is not in ranking');
    }

    @IsTest
    static void getBookedTrendByWeek_returnsBucketsForCurrentQuarter() {
        PGGtmInsightsController.mockFirstStage2PlusByOpp = buildQualifiedMock(2);
        Test.startTest();
        List<PGGtmInsightsController.TrendBucket> rows =
            PGGtmInsightsController.getBookedTrendByWeek();
        Test.stopTest();

        System.assert(rows.size() >= 1, 'At least one weekly bucket');
        Integer totalBooked = 0, totalQualified = 0;
        for (PGGtmInsightsController.TrendBucket tb : rows) {
            totalBooked += tb.bookedCount;
            totalQualified += tb.qualifiedCount;
        }
        // All seeded GTM opps were inserted today, so they roll into one
        // current-week bucket. 7 booked / 2 qualified.
        System.assertEquals(7, totalBooked,  'All booked opps fall in weekly buckets');
        System.assertEquals(2, totalQualified, 'Qualified count matches mock size');
    }

    @IsTest
    static void getBookedTrendByQuarter_summarizesByFiscalQuarter() {
        PGGtmInsightsController.mockFirstStage2PlusByOpp = buildQualifiedMock(3);
        Test.startTest();
        List<PGGtmInsightsController.TrendBucket> rows =
            PGGtmInsightsController.getBookedTrendByQuarter(6);
        Test.stopTest();
        Integer totalBooked = 0;
        for (PGGtmInsightsController.TrendBucket tb : rows) totalBooked += tb.bookedCount;
        System.assertEquals(7, totalBooked, '7 booked opps land in some quarter bucket');
    }

    @IsTest
    static void getIndividualOutreach_supportsAllWindowLabels() {
        // Verify each window label parses cleanly and doesn't error. The
        // test fixture inserts today's activity, so CW / CM / QTD should
        // all return rows; PW / PM are valid syntax but may return empty.
        Test.startTest();
        for (String win : new List<String>{ 'CW', 'PW', 'CM', 'PM', 'QTD' }) {
            List<PGGtmInsightsController.OutreachRow> rows =
                PGGtmInsightsController.getIndividualOutreach(win);
            System.assertNotEquals(null, rows, 'window ' + win + ' returns a list');
        }
        Test.stopTest();
    }

    @IsTest
    static void getIndividualOutreach_excludesNonGtmUsers() {
        Test.startTest();
        List<PGGtmInsightsController.OutreachRow> rows =
            PGGtmInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        Boolean foundNonGtm = false;
        Integer totalEmails = 0, totalCalls = 0, totalLinkedIn = 0, totalMeetings = 0;
        for (PGGtmInsightsController.OutreachRow r : rows) {
            if (r.ownerName == 'Not GTM') foundNonGtm = true;
            totalEmails   += r.emails;
            totalCalls    += r.calls;
            totalLinkedIn += r.linkedin;
            totalMeetings += r.meetings;
        }
        System.assert(!foundNonGtm, 'Non-GTM users excluded');
        System.assertEquals(2, totalEmails,  '2 outbound emails from gtm1');
        System.assertEquals(1, totalCalls,   '1 call from gtm2');
        System.assertEquals(1, totalLinkedIn,'1 Sales Navigator Sent');
        System.assertEquals(2, totalMeetings,'2 Discovery events');
    }

    // ---- helpers --------------------------------------------------------------------

    /**
     * Build a mock map of OppId -> first-Stage-2+ DateTime for the first
     * `qualifiedCount` GTM-booked opps. Lets each test choose how many to
     * mark as qualified without depending on real OpportunityHistory rows
     * (which don't auto-create in this org's test context).
     */
    private static Map<Id, DateTime> buildQualifiedMock(Integer qualifiedCount) {
        Set<Id> gtms = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE IsActive = TRUE
              AND UserRole.Name = 'GTM Associate'
              AND Title = 'GTM Associate'
        ]) {
            gtms.add(u.Id);
        }
        List<Opportunity> opps = [
            SELECT Id FROM Opportunity WHERE Booked_By__c IN :gtms ORDER BY Id
        ];
        Map<Id, DateTime> mock = new Map<Id, DateTime>();
        DateTime now = DateTime.now();
        Integer added = 0;
        for (Opportunity o : opps) {
            if (added >= qualifiedCount) break;
            mock.put(o.Id, now);
            added++;
        }
        return mock;
    }

    private static User buildLoaderUser() {
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        return new User(
            Alias = 'gtmldr',
            FirstName = 'GTM',
            LastName = 'Loader',
            Email = 'gtm-loader@pginsightstest.example.com',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = sysAdmin.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'gtm-loader@pginsightstest.example.com.' + System.now().getTime(),
            IsActive = true
        );
    }

    private static User buildUser(String alias, String firstName, String lastName,
                                  Id userRoleId, String title, Id profileId) {
        return new User(
            Alias = alias.left(8),
            Email = alias + '@gtminsightstest.example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = firstName,
            LastName = lastName,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/New_York',
            UserName = alias + '@gtminsightstest.example.com.' + System.now().getTime(),
            Title = title,
            UserRoleId = userRoleId,
            IsActive = true
        );
    }

    private static Opportunity buildOpp(Id bookerId, String oppType, String stageName) {
        return new Opportunity(
            Name = 'GTM Test ' + oppType + ' ' + stageName,
            OwnerId = bookerId,
            Booked_By__c = bookerId,
            Booked_By_Role__c = 'GTM Associate',
            StageName = stageName,
            CloseDate = Date.today().addDays(60),
            Type = oppType,
            Amount = 50000
        );
    }

    private static Task buildEmailTask(Id ownerId) {
        return new Task(
            OwnerId = ownerId,
            Subject = 'GTM outbound email',
            Status = 'Completed',
            TaskSubtype = 'Email',
            NektarSender__c = 'Us',
            ActivityDate = Date.today()
        );
    }

    private static Task buildCallTask(Id ownerId) {
        return new Task(
            OwnerId = ownerId,
            Subject = 'GTM outbound call',
            Status = 'Completed',
            TaskSubtype = 'Call',
            ActivityDate = Date.today()
        );
    }

    private static Task buildLinkedInTask(Id ownerId) {
        return new Task(
            OwnerId = ownerId,
            Subject = 'Sales Navigator Message Sent',
            Status = 'Completed',
            TaskSubtype = 'Task',
            ActivityDate = Date.today()
        );
    }

    private static Event buildEvent(Id ownerId) {
        return new Event(
            OwnerId = ownerId,
            Subject = 'GTM Discovery Meeting',
            NektarSender__c = 'Us',
            NektarStatus__c = 'completed',
            Meeting_Type__c = 'Discovery',
            ActivityDate = Date.today(),
            ActivityDateTime = DateTime.now(),
            DurationInMinutes = 30
        );
    }
}
