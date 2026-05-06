@IsTest
private class PGInsightsControllerTest {

    private static final String LOADER_PERMSET = 'PG_Insights_Test_Loader';

    @TestSetup
    static void setupData() {
        // Create a dedicated loader user that holds the Bypass_Validations
        // custom permission. All seed DML runs as this user so org validation
        // rules referencing $Permission.Bypass_Validations are skipped.
        User loader = buildLoaderUser();
        insert loader;

        PermissionSet ps = [
            SELECT Id FROM PermissionSet WHERE Name = :LOADER_PERMSET LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = loader.Id,
            PermissionSetId = ps.Id
        );

        // The test AE/BDR users still need a Standard User profile for the
        // tests to assert correct exclusion logic.
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
            // Insert opps directly at the target stage. OpportunityHistory is
            // auto-created on insert with that StageName, so we don't need a
            // separate stage-advance update (which was returning 0 rows in
            // sandbox tests, possibly due to a packaged trigger interfering).
            List<Opportunity> opps = new List<Opportunity>();
            for (Integer i = 0; i < 4; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', '2 - Discovery'));
            for (Integer i = 0; i < 2; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'Upsell',       '2 - Discovery'));
            for (Integer i = 0; i < 3; i++) opps.add(buildOpp(uByAlias.get('ae2'), 'New Business', '2 - Discovery'));
            for (Integer i = 0; i < 1; i++) opps.add(buildOpp(uByAlias.get('ae3'), 'New Business', '2 - Discovery'));
            // One opp stays in Stage 1 forever — should NOT count anywhere.
            opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', '1 - Demo'));
            insert opps;

            // Tasks: outbound activity for the AEs and one BDR (BDR excluded).
            List<Task> tasks = new List<Task>();
            for (Integer i = 0; i < 5; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Email'));
            for (Integer i = 0; i < 2; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Call'));
            tasks.add(buildTask(uByAlias.get('ae1'), 'LinkedIn'));
            for (Integer i = 0; i < 3; i++) tasks.add(buildTask(uByAlias.get('ae2'), 'Email'));
            tasks.add(buildTask(uByAlias.get('ae3'), 'Email'));
            for (Integer i = 0; i < 10; i++) tasks.add(buildTask(uByAlias.get('bdr'), 'Email'));
            insert tasks;

            // Events: meetings live here, not Task.
            List<Event> events = new List<Event>{
                buildEvent(uByAlias.get('ae1')),
                buildEvent(uByAlias.get('ae2'))
            };
            insert events;
        }
    }

    @IsTest
    static void diag_seedDataMatchesExpectations() {
        // Surfaces the actual seeded state with rich messages so any failure
        // identifies whether AEs, opps, or OpportunityHistory are the problem.
        Set<String> pods = new Set<String>{'ENT 1','ENT 2','MM/HV','NV'};
        List<User> rawAes = [SELECT Id, Title FROM User WHERE Pod__c IN :pods AND IsActive = TRUE];
        Set<Id> aeIds = new Set<Id>();
        for (User u : rawAes) {
            if (u.Title == null || !u.Title.containsIgnoreCase('BDR')) aeIds.add(u.Id);
        }

        List<Opportunity> aeOpps = [
            SELECT Id, Type, StageName, OwnerId FROM Opportunity WHERE OwnerId IN :aeIds
        ];
        Set<Id> aeOppIds = new Map<Id, Opportunity>(aeOpps).keySet();

        Integer typeNB = 0, typeExp = 0;
        for (Opportunity o : aeOpps) {
            if (o.Type == 'New Business') typeNB++;
            else if (o.Type == 'Upsell') typeExp++;
        }

        Integer histTotal = aeOppIds.isEmpty() ? 0 :
            [SELECT COUNT() FROM OpportunityHistory WHERE OpportunityId IN :aeOppIds];
        Integer histStage2Plus = aeOppIds.isEmpty() ? 0 :
            [SELECT COUNT() FROM OpportunityHistory
             WHERE OpportunityId IN :aeOppIds
               AND StageName IN ('2 - Discovery','3 - POV','4 - Proposal','5 - Contracting','Closed Won')];

        String diag = '[AEs=' + aeIds.size()
            + ' AEOpps=' + aeOpps.size()
            + ' NB=' + typeNB
            + ' Exp=' + typeExp
            + ' Hist=' + histTotal
            + ' HistStage2+=' + histStage2Plus + ']';

        System.assertEquals(3, aeIds.size(), 'Expected 3 AEs ' + diag);
        System.assertEquals(11, aeOpps.size(), 'Expected 11 AE-owned opps (10 stage 2+, 1 stage 1) ' + diag);
        System.assertEquals(8, typeNB, 'Expected 8 NB opps ' + diag);
        System.assertEquals(2, typeExp, 'Expected 2 Upsell opps ' + diag);
        System.assert(histStage2Plus >= 10,
            'Expected at least 10 stage-2+ history rows ' + diag);
    }

    @IsTest
    static void getPacingKpis_countsFirstStage2PlusEntries() {
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
        Test.startTest();
        List<PGInsightsController.QuarterRow> rows =
            PGInsightsController.getStageProgressByQuarter(8);
        Test.stopTest();
        System.assert(rows.size() >= 1, 'At least one quarter present');
        Integer totalNB = 0, totalExp = 0;
        for (PGInsightsController.QuarterRow r : rows) {
            totalNB += r.nbCount;
            totalExp += r.expCount;
        }
        System.assertEquals(8, totalNB, 'Sum of NB across quarters');
        System.assertEquals(2, totalExp, 'Sum of Expansion across quarters');
    }

    @IsTest
    static void getS1StatusQTD_aggregatesAcrossAEs() {
        Test.startTest();
        PGInsightsController.S1Status s = PGInsightsController.getS1StatusQTD();
        Test.stopTest();
        System.assertEquals(8, s.nbCount, 'QTD NB count');
        System.assertEquals(2, s.expCount, 'QTD Exp count');
    }

    @IsTest
    static void getTopPerformers_returnsAEsOrderedByVolume() {
        Test.startTest();
        List<PGInsightsController.PerformerRow> rows =
            PGInsightsController.getTopPerformers(5);
        Test.stopTest();
        System.assertEquals(3, rows.size(), 'Three AEs should be present, BDR excluded');
        System.assertEquals(6, rows[0].nbCount + rows[0].expCount, 'AE One leads');
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
        // CompletedDateTime is read-only; Salesforce sets it when Status='Completed'.
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
