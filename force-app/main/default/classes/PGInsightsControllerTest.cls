@IsTest
private class PGInsightsControllerTest {

    @TestSetup
    static void setupData() {
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

        // Insert opps in Stage 1, then move them to Stage 2+ so OpportunityHistory
        // captures the transition with today's CreatedDate.
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 4; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', i));
        for (Integer i = 0; i < 2; i++) opps.add(buildOpp(uByAlias.get('ae1'), 'Upsell',       i));
        for (Integer i = 0; i < 3; i++) opps.add(buildOpp(uByAlias.get('ae2'), 'New Business', i));
        for (Integer i = 0; i < 1; i++) opps.add(buildOpp(uByAlias.get('ae3'), 'New Business', i));
        // One opp stays in Stage 1 forever — should NOT count anywhere.
        Opportunity stillStage1 = buildOpp(uByAlias.get('ae1'), 'New Business', 99);
        opps.add(stillStage1);
        insert opps;

        List<Opportunity> toAdvance = new List<Opportunity>();
        for (Opportunity o : opps) {
            if (o == stillStage1) continue;
            o.StageName = '2 - Discovery';
            toAdvance.add(o);
        }
        update toAdvance;

        // Tasks: outbound activity for the AEs and one BDR (BDR should be excluded).
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < 5; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Email'));
        for (Integer i = 0; i < 2; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Call'));
        tasks.add(buildTask(uByAlias.get('ae1'), 'LinkedIn'));
        for (Integer i = 0; i < 3; i++) tasks.add(buildTask(uByAlias.get('ae2'), 'Email'));
        tasks.add(buildTask(uByAlias.get('ae3'), 'Email'));
        for (Integer i = 0; i < 10; i++) tasks.add(buildTask(uByAlias.get('bdr'), 'Email'));
        insert tasks;

        // Events: meetings live here (not Task), per the screenshot of the dashboard.
        List<Event> events = new List<Event>{
            buildEvent(uByAlias.get('ae1')),
            buildEvent(uByAlias.get('ae2'))
        };
        insert events;
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

        Map<Id, PGInsightsController.OutreachRow> byOwner = new Map<Id, PGInsightsController.OutreachRow>();
        for (PGInsightsController.OutreachRow r : rows) byOwner.put(r.ownerId, r);

        Boolean foundBdr = false;
        for (PGInsightsController.OutreachRow r : rows) {
            if (r.ownerName != null && r.ownerName.containsIgnoreCase('BDR')) foundBdr = true;
        }
        System.assert(!foundBdr, 'BDR users should not appear');
        System.assert(rows.size() >= 3, 'All three AEs with activity should appear');
        // Each AE should have meetings counted from Event, not Task.
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

    private static Opportunity buildOpp(Id ownerId, String oppType, Integer offsetDays) {
        return new Opportunity(
            Name = 'PG Test ' + oppType + ' ' + offsetDays,
            OwnerId = ownerId,
            StageName = '1 - Demo',
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
