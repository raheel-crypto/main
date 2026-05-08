@IsTest
private class PGInsightsControllerTest {

    private static final String LOADER_PERMSET = 'PG_Insights_Test_Loader';

    @TestSetup
    static void setupData() {
        // UserRoles must be inserted before any non-setup-object DML to avoid
        // MIXED_DML_OPERATION. Names contain the tokens the controller filters
        // on (BUYSIDE, IB1, IB2, MM).
        String suffix = String.valueOf(System.currentTimeMillis());
        UserRole roleBuyside = new UserRole(
            Name = 'Test BUYSIDE Pod ' + suffix,
            DeveloperName = 'TstBuyside_' + suffix
        );
        UserRole roleIb1 = new UserRole(
            Name = 'Test IB1 Pod ' + suffix,
            DeveloperName = 'TstIb1_' + suffix
        );
        UserRole roleIb2 = new UserRole(
            Name = 'Test IB2 Pod ' + suffix,
            DeveloperName = 'TstIb2_' + suffix
        );
        UserRole roleMm = new UserRole(
            Name = 'Test MM Pod ' + suffix,
            DeveloperName = 'TstMm_' + suffix
        );
        insert new List<UserRole>{ roleBuyside, roleIb1, roleIb2, roleMm };

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
            buildUser('ae1', 'AE',  'One',   roleIb1.Id,  null,  p.Id),
            buildUser('ae2', 'AE',  'Two',   roleIb2.Id,  null,  p.Id),
            buildUser('ae3', 'AE',  'Three', roleMm.Id,   null,  p.Id),
            buildUser('ae4', 'AE',  'Four',  roleBuyside.Id, null, p.Id),
            buildUser('bdr', 'BDR', 'One',   roleIb1.Id,  'BDR', p.Id)
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
            // Emails / Calls — Nektar-tagged outbound.
            for (Integer i = 0; i < 5; i++) tasks.add(buildEmailCallTask(uByAlias.get('ae1'), 'Email'));
            for (Integer i = 0; i < 2; i++) tasks.add(buildEmailCallTask(uByAlias.get('ae1'), 'Call'));
            for (Integer i = 0; i < 3; i++) tasks.add(buildEmailCallTask(uByAlias.get('ae2'), 'Email'));
            tasks.add(buildEmailCallTask(uByAlias.get('ae3'), 'Email'));
            for (Integer i = 0; i < 10; i++) tasks.add(buildEmailCallTask(uByAlias.get('bdr'), 'Email'));
            // LinkedIn — Sales Navigator integration writes Tasks differently.
            tasks.add(buildLinkedInTask(uByAlias.get('ae1')));
            insert tasks;

            // Events: meetings live here, not Task.
            List<Event> events = new List<Event>{
                buildEvent(uByAlias.get('ae1')),
                buildEvent(uByAlias.get('ae2'))
            };
            insert events;

            // Quotas: ae1 has goals; ae2/ae3/ae4 do not (tests fallback to 0).
            Date today = Date.today();
            Organization org = [SELECT FiscalYearStartMonth FROM Organization LIMIT 1];
            Integer startMonth = org.FiscalYearStartMonth;
            Integer monthOffset = today.month() - startMonth;
            if (monthOffset < 0) monthOffset += 12;
            Integer fq = (monthOffset / 3) + 1;
            Integer fy = (startMonth == 1)
                ? today.year()
                : (today.month() >= startMonth ? today.year() + 1 : today.year());
            insert new List<PG_Quota__c>{
                new PG_Quota__c(
                    User__c = uByAlias.get('ae1'),
                    Fiscal_Year__c = fy,
                    Fiscal_Quarter__c = fq,
                    NB_Goal__c = 10,
                    Exp_Goal__c = 4,
                    NB_Amount_Goal__c = 200000,
                    Exp_Amount_Goal__c = 80000
                )
            };
        }
    }

    @IsTest
    static void diag_seedDataIsLoaded() {
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
        System.assert(s.goalMTD > 0, 'Goal MTD prorated from PG_Quota__c (ae1 has 14 quarterly)');
    }

    @IsTest
    static void getTopPerformersByPod_groupsAEsByRole() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        List<PGInsightsController.PodPerformers> pods =
            PGInsightsController.getTopPerformersByPod(5);
        Test.stopTest();

        Map<String, PGInsightsController.PodPerformers> byPod =
            new Map<String, PGInsightsController.PodPerformers>();
        for (PGInsightsController.PodPerformers p : pods) byPod.put(p.pod, p);

        // ae1 (IB1) has 6 opps, ae2 (IB2) has 3, ae3 (MM) has 1, ae4 (Buyside) has 0.
        System.assert(byPod.containsKey('IB1'),     'IB1 pod present');
        System.assert(byPod.containsKey('IB2'),     'IB2 pod present');
        System.assert(byPod.containsKey('MM'),      'MM pod present');
        System.assert(byPod.containsKey('Buyside'), 'Buyside pod present');

        PGInsightsController.PodPerformers ib1 = byPod.get('IB1');
        System.assertEquals(1, ib1.rows.size(), 'IB1 has one performer');
        System.assertEquals(6, ib1.totalNb + ib1.totalExp, 'IB1 totals 6 stage-2+ opps');
        System.assert(ib1.totalGoalMTD > 0, 'IB1 inherits ae1 prorated quota');

        PGInsightsController.PodPerformers ib2 = byPod.get('IB2');
        System.assertEquals(3, ib2.totalNb + ib2.totalExp, 'IB2 totals 3 stage-2+ opps');
        System.assertEquals(0, ib2.totalGoalMTD, 'IB2 has no quota set; falls back to 0');
    }

    @IsTest
    static void getIndividualOutreach_countsTasksAndEventsExcludingBDRs() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        Boolean foundBdr = false;
        Integer totalEmails = 0, totalCalls = 0, totalLinkedIn = 0, totalMeetings = 0;
        for (PGInsightsController.OutreachRow r : rows) {
            if (r.ownerName != null && r.ownerName.containsIgnoreCase('BDR')) foundBdr = true;
            totalEmails   += r.emails;
            totalCalls    += r.calls;
            totalLinkedIn += r.linkedin;
            totalMeetings += r.meetings;
        }
        System.assert(!foundBdr, 'BDR users should not appear');
        System.assert(rows.size() >= 3, 'AEs with activity should appear');
        System.assertEquals(9, totalEmails,  '5 (ae1) + 3 (ae2) + 1 (ae3) emails');
        System.assertEquals(2, totalCalls,   '2 (ae1) calls');
        System.assertEquals(1, totalLinkedIn,'1 Sales Navigator Sent (ae1)');
        System.assertEquals(2, totalMeetings,'2 Discovery/First Meeting events');
    }

    @IsTest
    static void getIndividualOutreach_qtdWindowReturnsRows() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('QTD');
        Test.stopTest();
        System.assert(rows.size() >= 3, 'QTD window returns rows for AEs');
    }

    @IsTest
    static void getConversionHeatmap_computesPerOwnerConversions() {
        Set<Id> aeIds = computeTestAeIds();
        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id FROM Opportunity WHERE OwnerId IN :aeIds
        ]);
        List<Id> oppIds = new List<Id>(opps.keySet());
        Map<Id, Set<String>> mock = new Map<Id, Set<String>>();
        Integer i = 0;
        for (Id oid : oppIds) {
            Integer mod = Math.mod(i, 4);
            if (mod == 0) {
                mock.put(oid, new Set<String>{'1 - Demo','2 - Discovery','3 - POV','4 - Proposal','5 - Contracting','Closed Won'});
            } else if (mod == 1) {
                mock.put(oid, new Set<String>{'1 - Demo','2 - Discovery','3 - POV'});
            } else if (mod == 2) {
                mock.put(oid, new Set<String>{'1 - Demo','2 - Discovery'});
            } else {
                mock.put(oid, new Set<String>{'1 - Demo'});
            }
            i++;
        }
        PGInsightsController.mockStagesByOpp = mock;

        Test.startTest();
        List<PGInsightsController.HeatmapRow> rows =
            PGInsightsController.getConversionHeatmap('AE', false);
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'One row per AE that has at least one opp at Stage 1+');
        Boolean foundFullFunnel = false;
        for (PGInsightsController.HeatmapRow r : rows) {
            System.assert(r.demoCount > 0, 'demoCount populated for ' + r.ownerName);
            if (r.contractingToWon != null && r.contractingToWon > 0) foundFullFunnel = true;
        }
        System.assert(foundFullFunnel, 'At least one AE has an opp that reached Closed Won');
    }

    // ---- helpers --------------------------------------------------------------------

    private static Map<Id, DateTime> buildStage2PlusMock() {
        Set<Id> aeIds = computeTestAeIds();
        Map<Id, DateTime> mock = new Map<Id, DateTime>();
        DateTime now = DateTime.now();
        Set<String> bucketableTypes = new Set<String>{'New Business', 'Upsell', 'Pilot'};
        for (Opportunity o : [
            SELECT Id, StageName, Type FROM Opportunity WHERE OwnerId IN :aeIds
        ]) {
            if (o.StageName == '1 - Demo') continue;
            if (!bucketableTypes.contains(o.Type)) continue;
            mock.put(o.Id, now);
        }
        return mock;
    }

    private static Set<Id> computeTestAeIds() {
        // Mirrors PGInsightsController.getAeUserIds() — UserRole.Name CONTAINS
        // any of the AE pod tokens, BDR titles excluded.
        List<User> aes = [
            SELECT Id, Title, UserRole.Name FROM User
            WHERE IsActive = TRUE
              AND (UserRole.Name LIKE '%BUYSIDE%'
                   OR UserRole.Name LIKE '%IB1%'
                   OR UserRole.Name LIKE '%IB2%'
                   OR UserRole.Name LIKE '%MM%')
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
                                  Id userRoleId, String title, Id profileId) {
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
            UserRoleId = userRoleId,
            IsActive = true
        );
    }

    private static Opportunity buildOpp(Id ownerId, String oppType, String stageName) {
        return new Opportunity(
            Name = 'PG Test ' + oppType + ' ' + stageName,
            OwnerId = ownerId,
            StageName = stageName,
            CloseDate = Date.today().addDays(60),
            Type = oppType,
            Booked_By_Role__c = 'AE - ENT'
        );
    }

    private static Task buildEmailCallTask(Id ownerId, String subtype) {
        return new Task(
            OwnerId = ownerId,
            Subject = 'PG Test ' + subtype,
            Status = 'Completed',
            TaskSubtype = subtype,
            NektarSender__c = 'Us',
            ActivityDate = Date.today()
        );
    }

    private static Task buildLinkedInTask(Id ownerId) {
        // Sales Navigator integration shape: TaskSubtype = 'Task', Subject
        // contains 'Sales Navigator' and 'Sent' for outbound. No Nektar tag.
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
            Subject = 'PG Test Meeting',
            NektarSender__c = 'Us',
            NektarStatus__c = 'completed',
            Meeting_Type__c = 'Discovery',
            ActivityDate = Date.today(),
            ActivityDateTime = DateTime.now(),
            DurationInMinutes = 30
        );
    }
}
