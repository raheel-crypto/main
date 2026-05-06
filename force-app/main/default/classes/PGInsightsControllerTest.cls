@IsTest
private class PGInsightsControllerTest {

    @TestSetup
    static void setupData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        List<User> users = new List<User>{
            buildUser('ae1', 'AE One',  'ENT 1', null, p.Id),
            buildUser('ae2', 'AE Two',  'ENT 2', null, p.Id),
            buildUser('ae3', 'AE Three','MM/HV', null, p.Id),
            buildUser('bdr', 'BDR One', 'ENT 1', 'BDR', p.Id)
        };
        insert users;

        Map<String, Id> uByAlias = new Map<String, Id>();
        for (User u : users) uByAlias.put(u.Alias, u.Id);

        // Opportunities — give each AE a mix of NB and Upsell with Stage_1__c true.
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 4; i++) {
            opps.add(buildOpp(uByAlias.get('ae1'), 'New Business', i));
        }
        for (Integer i = 0; i < 2; i++) {
            opps.add(buildOpp(uByAlias.get('ae1'), 'Upsell', i));
        }
        for (Integer i = 0; i < 3; i++) {
            opps.add(buildOpp(uByAlias.get('ae2'), 'New Business', i));
        }
        for (Integer i = 0; i < 1; i++) {
            opps.add(buildOpp(uByAlias.get('ae3'), 'New Business', i));
        }
        insert opps;

        // Tasks — outbound activity for the three AEs and a BDR (BDR should be excluded).
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < 5; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Email', null));
        for (Integer i = 0; i < 2; i++) tasks.add(buildTask(uByAlias.get('ae1'), 'Call', null));
        tasks.add(buildTask(uByAlias.get('ae1'), 'LinkedIn', null));
        tasks.add(buildTask(uByAlias.get('ae1'), 'Task', 'First Meeting'));

        for (Integer i = 0; i < 3; i++) tasks.add(buildTask(uByAlias.get('ae2'), 'Email', null));
        tasks.add(buildTask(uByAlias.get('ae2'), 'Task', 'Discovery'));

        tasks.add(buildTask(uByAlias.get('ae3'), 'Email', null));

        // BDR activity — must NOT show up in results
        for (Integer i = 0; i < 10; i++) tasks.add(buildTask(uByAlias.get('bdr'), 'Email', null));
        insert tasks;
    }

    @IsTest
    static void getPacingKpis_returnsCountsAndDeltas() {
        Test.startTest();
        PGInsightsController.PacingKpis wow = PGInsightsController.getPacingKpis('WoW');
        PGInsightsController.PacingKpis mom = PGInsightsController.getPacingKpis('MoM');
        Test.stopTest();

        System.assertNotEquals(null, wow, 'WoW result should not be null');
        System.assertNotEquals(null, mom, 'MoM result should not be null');
        // 4 NB + 2 Upsell from ae1, 3 NB from ae2, 1 NB from ae3 = 8 NB, 2 Exp
        System.assertEquals(8, wow.newBusiness, 'NB count');
        System.assertEquals(2, wow.expansion, 'Expansion count');
        System.assertEquals(80, wow.nbPctOfTotal, 'NB % of total');
    }

    @IsTest
    static void getStageProgressByQuarter_returnsRowsForCurrentQuarter() {
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
        System.assert(rows.size() == 3, 'Three AEs should be present, BDR excluded');
        // Top performer should be AE One (6 opps total)
        System.assertEquals(6, rows[0].nbCount + rows[0].expCount, 'AE One leads');
    }

    @IsTest
    static void getIndividualOutreach_excludesBDRs() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        Boolean foundBdr = false;
        Integer aeRowCount = 0;
        for (PGInsightsController.OutreachRow r : rows) {
            if (r.ownerName != null && r.ownerName.containsIgnoreCase('BDR')) foundBdr = true;
            if (r.total > 0) aeRowCount++;
        }
        System.assert(!foundBdr, 'BDR users should not appear');
        System.assert(aeRowCount >= 3, 'All three AEs with activity should appear');
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

    private static User buildUser(String alias, String fullName, String pod, String title, Id profileId) {
        return new User(
            Alias = alias.left(8),
            Email = alias + '@pginsightstest.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = fullName,
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
            StageName = '2 - Discovery',
            CloseDate = Date.today().addDays(60),
            Type = oppType,
            Stage_1__c = true,
            Stage_1_Start_Date__c = Date.today().addDays(-offsetDays)
        );
    }

    private static Task buildTask(Id ownerId, String subtype, String meetingType) {
        // CompletedDateTime is read-only; Salesforce auto-sets it when Status='Completed'.
        return new Task(
            OwnerId = ownerId,
            Subject = 'PG Test ' + subtype,
            Status = 'Completed',
            TaskSubtype = subtype,
            Meeting_Type__c = meetingType,
            ActivityDate = Date.today()
        );
    }
}
