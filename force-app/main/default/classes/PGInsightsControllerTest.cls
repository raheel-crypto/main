@IsTest
private class PGInsightsControllerTest {

    private static final String LOADER_PERMSET = 'PG_Insights_Test_Loader';
    private static final Set<String> TEST_AE_PODS = new Set<String>{'ENT 1', 'ENT 2', 'MM/HV', 'NV'};

    @TestSetup
    static void setupData() {
        // Loader user with the Bypass_Validations custom permission so seed
        // DML can ignore org validation rules.
        User loader = buildLoaderUser();
        insert loader;

        PermissionSet ps = [
            SELECT Id FROM PermissionSet WHERE Name = :LOADER_PERMSET LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = loader.Id,
            PermissionSetId = ps.Id
        );

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>{
            buildUser('ae1', 'AE',  'One',   'ENT 1', null, p.Id),
            buildUser('ae2', 'AE',  'Two',   'ENT 2', null, p.Id),
            buildUser('ae3', 'AE',  'Three', 'MM/HV', null, p.Id),
            buildUser('bdr', 'BDR', 'One',   'ENT 1', 'BDR', p.Id)
        };
        insert users;

        Map<String, Id> uByAlias = new Map<String, Id>();
        for (User u : users) uByAlias.put(u.Alias, u.Id);

        System.runAs(loader) {
            List<Opportunity> opps = new List<Opportunity>();
            for (Integer i = 0; i < 4; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', '2 - Discovery'));
            for (Integer i = 0; i < 2; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'Upsell',       '2 - Discovery'));
            for (Integer i = 0; i < 3; i++) opps.add(buildOpp(uByAlias.get('ae2'), 'New Business', '2 - Discovery'));
            for (Integer i = 0; i < 1; i++) opps.add(buildOpp(uByAlias.get('ae3'), 'New Business', '2 - Discovery'));
            // Stays in Stage 1 — must NOT count toward Stage 2+ metrics.
            opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', '1 - Demo'));
            insert opps;

            List<Task> tasks = new List<Task>();
            for (Integer i = 0; i < 5; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Email'));
            for (Integer i = 0; i < 2; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Call'));
            tasks.add(buildTask(uByAlias.get('ae1'), 'LinkedIn'));
            for (Integer i = 0; i < 3; i++) tasks.add(buildTask(uByAlias.get('ae2'), 'Email'));
            tasks.add(buildTask(uByAlias.get('ae3'), 'Email'));
            for (Integer i = 0; i < 10; i++) tasks.add(buildTask(uByAlias.get('bdr'), 'Email'));
            insert tasks;

            List<Event> events = new List<Event>{
                buildEvent(uByAlias.get('ae1')),
                buildEvent(uByAlias.get('ae2'))
            };
            insert events;
        }
    }

    @IsTest
    static void diag_seedDataIsLoaded() {
        // Confirms @TestSetup completed. Skips assertions on AE count
        // (real org users with the same Pods are visible) and on auto-
        // OpportunityHistory (Salesforce is not auto-creating those in
        // this org's test context — Stage 2+ tests mock around it).
        Set<Id> aeIds = computeTestAeIds();
        List<Opportunity> aeOpps = [
            SELECT Id, Type, StageName FROM Opportunity WHERE OwnerId IN :aeIds
        ];
        Integer typeNB = 0, typeExp = 0;
        for (Opportunity o : aeOpps) {
            if (o.Type == 'New Business') typeNB++;
            else if (o.Type == 'Upsell') typeExp++;
        }
        System.assertEquals(11, aeOpps.size(),
            'Total seeded opps (10 stage 2 + 1 stage 1)');
        System.assertEquals(9, typeNB, 'NB count');
        System.assertEquals(2, typeExp, 'Upsell count');
    }

    @IsTest
    static void getPacingKpis_countsFirstStage2PlusEntries() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        PGInsightsController.PacingKpis wow = PGInsightsController.getPacingKpis('WoW');
        PGInsightsController.PacingKpis mom = PGInsightsController.getPacingKpis('MoM');
        Test.stopTest();

        // 4 NB + 2 Exp from ae1, 3 NB from ae2, 1 NB from ae3 = 8 NB / 2 Exp.
        // The remaining still-Stage-1 opp must NOT count.
        System.assertEquals(8, wow.newBusiness, 'NB count');
        System.assertEquals(2, wow.expansion,  'Expansion count');
        System.assertEquals(80, wow.nbPctOfTotal, 'NB % of total');
        System.assertEquals(8, mom.newBusiness, 'MoM NB count');
    }

    @IsTest
    static void getStageProgressByQuarter_bucketsByCurrentQuarter() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        List<PGInsightsController.QuarterRow> rows =
            PGInsightsController.getStageProgressByQuarter(8);
        Test.stopTest();
        System.assert(rows.size() >= 1, 'At least one quarter present');
        Integer totalNB = 0, totalExp = 0;
        for (PGInsightsController.QuarterRow r : rows) {
            totalNB  += r.nbCount;
            totalExp += r.expCount;
        }
        System.assertEquals(8, totalNB,  'Sum of NB across quarters');
        System.assertEquals(2, totalExp, 'Sum of Expansion across quarters');
    }

    @IsTest
    static void getS1StatusQTD_aggregatesAcrossAEs() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        PGInsightsController.S1Status s = PGInsightsController.getS1StatusQTD();
        Test.stopTest();
        System.assertEquals(8, s.nbCount,  'QTD NB count');
        System.assertEquals(2, s.expCount, 'QTD Exp count');
    }

    @IsTest
    static void getTopPerformers_returnsAEsOrderedByVolume() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        List<PGInsightsController.PerformerRow> rows =
            PGInsightsController.getTopPerformers(5);
        Test.stopTest();
        System.assertEquals(3, rows.size(), 'Three AEs with stage 2+ opps; BDR excluded');
        System.assertEquals(6, rows[0].nbCount + rows[0].expCount, 'AE One leads (6 opps)');
    }

    @IsTest
    static void getIndividualOutreach_countsTasksAndEventsExcludingBDRs() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        Boolean foundBdr = false;
        for (PGInsightsController.OutreachRow r : rows) {
            if (r.ownerName != null && r.ownerName.containsIgnoreCase('BDR')) foundBdr = true;
        }
        System.assert(!foundBdr, 'BDR users should not appear');
        System.assert(rows.size() >= 3, 'All three AEs with activity should appear');
        Integer totalMeetings = 0;
        for (PGInsightsController.OutreachRow r : rows) totalMeetings += r.meetings;
        System.assertEquals(2, totalMeetings, 'Two meetings inserted as Events');
    }

    @IsTest
    static void getIndividualOutreach_qtdWindowReturnsRows() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('QTD');
        Test.stopTest();
        System.assert(rows.size() >= 3, 'QTD window returns rows for AEs');
    }

    // ---- helpers --------------------------------------------------------------------

    /**
     * Builds the mock the controller's getFirstStage2PlusByOpp would return if
     * OpportunityHistory auto-creation worked in this org's test context.
     * Maps every test-seeded opp at Stage 2+ to "now" — so each test asserts
     * windows containing today (WoW, MoM, QTD) match.
     */
    private static Map<Id, DateTime> buildStage2PlusMock() {
        Set<Id> aeIds = computeTestAeIds();
        Map<Id, DateTime> mock = new Map<Id, DateTime>();
        DateTime now = DateTime.now();
        for (Opportunity o : [
            SELECT Id, StageName, Type FROM Opportunity WHERE OwnerId IN :aeIds
        ]) {
            if (o.StageName == '1 - Demo') continue;
            if (o.Type != 'New Business' && o.Type != 'Upsell') continue;
            mock.put(o.Id, now);
        }
        return mock;
    }

    private static Set<Id> computeTestAeIds() {
        List<User> aes = [
            SELECT Id, Title FROM User
            WHERE Pod__c IN :TEST_AE_PODS AND IsActive = TRUE
        ];
        Set<Id> ids = new Set<Id>();
        for (User u : aes) {
            if (u.Title == null || !u.Title.containsIgnoreCase('BDR')) ids.add(u.Id);
        }
        return ids;
    }

    private static User buildLoaderUser() {
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        return new User(
            Alias = 'pgldr',
            FirstName = 'PG',
            LastName = 'Loader',
            Email = 'pg-loader@pginsightstest.example.com',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = sysAdmin.Id,
            TimeZoneSidKey = 'America/New_York',
            UserName = 'pg-loader@pginsightstest.example.com.' + System.now().getTime(),
            IsActive = true
        );
    }

    private static User buildUser(String alias, String firstName, String lastName,
                                  String pod, String title, Id profileId) {
        return new User(
            Alias = alias.left(8),
            Email = alias + '@pginsightstest.example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = firstName,
            LastName = lastName,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/New_York',
            UserName = alias + '@pginsightstest.example.com.' + System.now().getTime(),
            Title = title,
            Pod__c = pod,
            IsActive = true
        );
    }

    private static Opportunity buildOpp(Id ownerId, String oppType, String stageName) {
        return new Opportunity(
            Name = 'PG Test ' + oppType + ' ' + stageName,
            OwnerId = ownerId,
            StageName = stageName,
            CloseDate = Date.today().addDays(60),
            Type = oppType
        );
    }

    private static Task buildTask(Id ownerId, String subtype) {
        return new Task(
            OwnerId = ownerId,
            Subject = 'PG Test ' + subtype,
            Status = 'Completed',
            TaskSubtype = subtype,
            ActivityDate = Date.today()
        );
    }

    private static Event buildEvent(Id ownerId) {
        return new Event(
            OwnerId = ownerId,
            Subject = 'PG Test Meeting',
            ActivityDate = Date.today(),
            ActivityDateTime = DateTime.now(),
            DurationInMinutes = 30
        );
    }
}
