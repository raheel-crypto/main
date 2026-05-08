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
        System.assert(s.goalQTD > 0, 'Goal QTD prorated from PG_Quota__c (ae1 has 14 quarterly)');
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
        System.assert(ib1.totalGoalQTD > 0, 'IB1 inherits ae1 prorated quota');

        PGInsightsController.PodPerformers ib2 = byPod.get('IB2');
        System.assertEquals(3, ib2.totalNb + ib2.totalExp, 'IB2 totals 3 stage-2+ opps');
        System.assertEquals(0, ib2.totalGoalQTD, 'IB2 has no quota set; falls back to 0');
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

    // ---- Phase B: $ amount tracking ------------------------------------------------

    @IsTest
    static void getPacingKpis_includesAmountFields() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        PGInsightsController.PacingKpis wow = PGInsightsController.getPacingKpis('WoW');
        Test.stopTest();

        // 8 NB opps × 50K + 2 Upsell × 50K = 400K NB / 100K Exp.
        System.assertEquals(400000, wow.newBusinessAmount, 'NB amount sums Opportunity.Amount');
        System.assertEquals(100000, wow.expansionAmount,   'Expansion amount sums Opportunity.Amount');
        System.assertEquals(80,     wow.nbAmtPctOfTotal,   'NB % of total in $ matches count split');
    }

    @IsTest
    static void getS1StatusQTD_includesAmountAndAttainment() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        PGInsightsController.S1Status s = PGInsightsController.getS1StatusQTD();
        Test.stopTest();

        System.assertEquals(400000, s.nbAmount,  'QTD NB amount');
        System.assertEquals(100000, s.expAmount, 'QTD Exp amount');
        // ae1 has NB $200K + Exp $80K quarterly amount goal; prorated.
        System.assert(s.amountGoalQTD > 0,
            'Amount goal QTD prorated from PG_Quota__c amount fields');
        System.assert(s.amountAttainmentPct > 0,
            'Amount attainment % computed from goal + actuals');
    }

    @IsTest
    static void getTopPerformersByPod_includesAmountFields() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        List<PGInsightsController.PodPerformers> pods =
            PGInsightsController.getTopPerformersByPod(5);
        Test.stopTest();

        Map<String, PGInsightsController.PodPerformers> byPod =
            new Map<String, PGInsightsController.PodPerformers>();
        for (PGInsightsController.PodPerformers p : pods) byPod.put(p.pod, p);

        // ae1 in IB1: 4 NB + 2 Upsell @ 50K each.
        PGInsightsController.PodPerformers ib1 = byPod.get('IB1');
        System.assertEquals(200000, ib1.totalNbAmount,  'IB1 NB amount');
        System.assertEquals(100000, ib1.totalExpAmount, 'IB1 Exp amount');
        System.assert(ib1.totalAmountGoalQTD > 0, 'IB1 inherits amount quota');

        PGInsightsController.PerformerRow leader = ib1.rows[0];
        System.assertEquals(200000, leader.nbAmount,  'Leader NB amount');
        System.assertEquals(100000, leader.expAmount, 'Leader Exp amount');
        System.assert(leader.amountGoal > 0, 'Leader has amount goal');
    }

    // ---- Phase C: weekly chart ----------------------------------------------------

    @IsTest
    static void getStageProgressByWeek_returnsCurrentQuarterBuckets() {
        PGInsightsController.mockFirstStage2PlusByOpp = buildStage2PlusMock();
        Test.startTest();
        List<PGInsightsController.QuarterRow> rows =
            PGInsightsController.getStageProgressByWeek();
        Test.stopTest();

        System.assert(rows.size() >= 1, 'At least one weekly bucket present');
        Integer totalNb = 0, totalExp = 0;
        Decimal totalNbAmt = 0, totalExpAmt = 0;
        for (PGInsightsController.QuarterRow r : rows) {
            totalNb     += r.nbCount;
            totalExp    += r.expCount;
            totalNbAmt  += (r.nbAmount  == null ? 0 : r.nbAmount);
            totalExpAmt += (r.expAmount == null ? 0 : r.expAmount);
        }
        System.assertEquals(8, totalNb,  'Sum of NB across weeks (only this quarter)');
        System.assertEquals(2, totalExp, 'Sum of Expansion across weeks');
        System.assertEquals(400000, totalNbAmt,  'Sum of NB amount');
        System.assertEquals(100000, totalExpAmt, 'Sum of Expansion amount');
    }

    // ---- Phase D: heatmap groupings + drill-down ----------------------------------

    @IsTest
    static void getAeUserIds_excludesCsmRoleNamePrefix() {
        // A user whose UserRole.Name starts with 'CSM' (and contains a pod
        // token like 'MM') should be filtered out — that's how Charlotte
        // Norris and Josh Karchmer were leaking in despite null Titles.
        String suffix = String.valueOf(System.currentTimeMillis());
        UserRole csmRole = new UserRole(
            Name = 'CSM - Test ' + suffix,
            DeveloperName = 'CsmTest_' + suffix
        );
        insert csmRole;

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User csmUser = buildUser('csmrole', 'CSM', 'Role', csmRole.Id, null, p.Id);
        insert csmUser;

        User loader = [SELECT Id FROM User WHERE Username LIKE 'pg-loader%' LIMIT 1];
        System.runAs(loader) {
            insert new List<Task>{ buildEmailCallTask(csmUser.Id, 'Email') };
        }

        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        for (PGInsightsController.OutreachRow r : rows) {
            System.assertNotEquals(csmUser.Id, r.ownerId,
                'CSM-prefixed role users must be excluded from the AE roster');
        }
    }

    @IsTest
    static void getAeUserIds_excludesCsmAndGtmTitles() {
        // Insert two extra users with matching pod role names but non-AE
        // titles. They should NOT appear in the AE outreach roster.
        UserRole role = [
            SELECT Id FROM UserRole WHERE Name LIKE 'Test IB1%' LIMIT 1
        ];
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> nonAes = new List<User>{
            buildUser('csm1', 'CSM', 'Person', role.Id, 'CSM - MM', p.Id),
            buildUser('gtm1', 'GTM', 'Person', role.Id, 'GTM Strategy', p.Id)
        };
        insert nonAes;

        // Outreach query reads getAeUserIds via getAeUserIdsByPod — give the
        // non-AEs an outbound task each and verify they don't appear.
        User loader = [SELECT Id FROM User WHERE Username LIKE 'pg-loader%' LIMIT 1];
        System.runAs(loader) {
            insert new List<Task>{
                buildEmailCallTask(nonAes[0].Id, 'Email'),
                buildEmailCallTask(nonAes[1].Id, 'Email')
            };
        }

        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        for (PGInsightsController.OutreachRow r : rows) {
            String name = r.ownerName == null ? '' : r.ownerName;
            System.assert(!name.contains('CSM'),
                'CSM-titled user should not appear in outreach roster');
            System.assert(!name.contains('GTM'),
                'GTM-titled user should not appear in outreach roster');
        }
    }

    @IsTest
    static void getConversionHeatmap_includesAmountWeightedFields() {
        PGInsightsController.mockStagesByOpp = buildSimpleStagesMock();
        Test.startTest();
        List<PGInsightsController.HeatmapRow> rows =
            PGInsightsController.getConversionHeatmap('AE', false);
        Test.stopTest();

        // Every row should carry the amount-weighted conversion fields.
        Boolean foundAmountField = false;
        for (PGInsightsController.HeatmapRow r : rows) {
            if (r.demoToDiscoAmount != null) {
                foundAmountField = true;
                // Count and amount conversion are equal here only because
                // every test opp has the same Amount; the math path differs.
                System.assertEquals(r.demoToDisco, r.demoToDiscoAmount,
                    'Equal-Amount opps yield equal count and amount conversions');
                break;
            }
        }
        System.assert(foundAmountField, 'At least one row populated demoToDiscoAmount');
    }

    @IsTest
    static void getConversionHeatmap_byPodGroupsAEs() {
        PGInsightsController.mockStagesByOpp = buildSimpleStagesMock();
        Test.startTest();
        List<PGInsightsController.HeatmapRow> rows =
            PGInsightsController.getConversionHeatmap('Pod', false);
        Test.stopTest();

        Set<String> seen = new Set<String>();
        for (PGInsightsController.HeatmapRow r : rows) seen.add(r.ownerName);
        // 3 pods have opps (IB1 via ae1, IB2 via ae2, MM via ae3). ae4 is in
        // Buyside but has no opps so its pod row is absent.
        System.assert(seen.contains('IB1'), 'IB1 row present');
        System.assert(seen.contains('IB2'), 'IB2 row present');
        System.assert(seen.contains('MM'),  'MM row present');
        System.assert(!seen.contains('IB'), 'IB combined row should NOT be present without combineIB');
    }

    @IsTest
    static void getConversionHeatmap_byPodCombinesIB() {
        PGInsightsController.mockStagesByOpp = buildSimpleStagesMock();
        Test.startTest();
        List<PGInsightsController.HeatmapRow> rows =
            PGInsightsController.getConversionHeatmap('Pod', true);
        Test.stopTest();

        Map<String, PGInsightsController.HeatmapRow> byName =
            new Map<String, PGInsightsController.HeatmapRow>();
        for (PGInsightsController.HeatmapRow r : rows) byName.put(r.ownerName, r);

        System.assert(byName.containsKey('IB'), 'IB combined row present');
        System.assert(!byName.containsKey('IB1'), 'IB1 collapsed under IB');
        System.assert(!byName.containsKey('IB2'), 'IB2 collapsed under IB');
        // ae1's 6 opps + ae2's 3 opps = 9 opps under combined IB.
        System.assertEquals(9, byName.get('IB').demoCount,
            'IB combined demo count is sum of IB1 + IB2 AEs');
    }

    @IsTest
    static void getConversionHeatmap_returnsNAForOpenAtSourceStage() {
        // Mock a single open-at-Contracting opp for ae1; all other opps
        // are excluded by leaving them out of mockStagesByOpp.
        Set<Id> aeIds = computeTestAeIds();
        Id ae1Id = null;
        for (User u : [SELECT Id, Alias FROM User WHERE Id IN :aeIds]) {
            if (u.Alias == 'ae1') { ae1Id = u.Id; break; }
        }
        System.assertNotEquals(null, ae1Id, 'ae1 in test set');

        // Find ae1's first stage 2+ opp (still has StageName = '2 - Discovery'
        // from setup, so IsClosed = false).
        Opportunity targetOpp = [
            SELECT Id, IsClosed FROM Opportunity
            WHERE OwnerId = :ae1Id AND StageName = '2 - Discovery'
            LIMIT 1
        ];
        // Verify it's open — controller relies on this for the eligible[] math.
        System.assertEquals(false, targetOpp.IsClosed, 'Test fixture is open');

        // Mock its stage history as having reached up through Contracting.
        Map<Id, Set<String>> mock = new Map<Id, Set<String>>();
        mock.put(targetOpp.Id, new Set<String>{
            '1 - Demo','2 - Discovery','3 - POV','4 - Proposal','5 - Contracting'
        });
        PGInsightsController.mockStagesByOpp = mock;

        Test.startTest();
        List<PGInsightsController.HeatmapRow> rows =
            PGInsightsController.getConversionHeatmap('AE', false);
        Test.stopTest();

        // ae1 is the only AE with a non-skipped opp in this test.
        System.assertEquals(1, rows.size(), 'One row for ae1');
        PGInsightsController.HeatmapRow r = rows[0];
        // Reached Contracting: yes. Reached Won: no. Open at Contracting:
        // eligible[5] = 0 → contractingToWon = null (N/A).
        System.assertEquals(null, r.contractingToWon,
            'Contracting -> Won is N/A when only deal is open at Contracting');
        // Earlier transitions: deal advanced past stages 1-4, so they all
        // have an eligible denominator and a 100% conversion.
        System.assertEquals(100, r.demoToDisco,           'Demo -> Discovery converted');
        System.assertEquals(100, r.discoToPov,            'Discovery -> POV converted');
        System.assertEquals(100, r.povToProposal,         'POV -> Proposal converted');
        System.assertEquals(100, r.proposalToContracting, 'Proposal -> Contracting converted');
    }

    @IsTest
    static void getHeatmapCellOpps_returnsDenominatorOpps() {
        PGInsightsController.mockStagesByOpp = buildSimpleStagesMock();

        // Pick ae1 — they have stage 2+ history per the simple mock.
        Set<Id> aeIds = computeTestAeIds();
        Id ae1Id = null;
        for (User u : [SELECT Id, Alias FROM User WHERE Id IN :aeIds]) {
            if (u.Alias == 'ae1') { ae1Id = u.Id; break; }
        }

        Test.startTest();
        // Demo -> Discovery transition (fromRank = 1).
        List<PGInsightsController.HeatmapCellOpp> aeRows =
            PGInsightsController.getHeatmapCellOpps(String.valueOf(ae1Id), 1, 'AE', false);
        Test.stopTest();

        System.assert(aeRows.size() > 0, 'Drill-down returns at least one opp');
        Boolean foundReached = false;
        for (PGInsightsController.HeatmapCellOpp o : aeRows) {
            if (o.reachedTarget) foundReached = true;
            System.assertNotEquals(null, o.name,      'opp name populated');
            System.assertNotEquals(null, o.stageName, 'opp stage populated');
        }
        System.assert(foundReached, 'At least one drilldown row reached Discovery');
    }

    @IsTest
    static void getHeatmapCellOpps_categorizesByOutcome() {
        Set<Id> aeIds = computeTestAeIds();
        Id ae1Id = null;
        for (User u : [SELECT Id, Alias FROM User WHERE Id IN :aeIds]) {
            if (u.Alias == 'ae1') { ae1Id = u.Id; break; }
        }

        User loader = [SELECT Id FROM User WHERE Username LIKE 'pg-loader%' LIMIT 1];
        List<Opportunity> testOpps;
        System.runAs(loader) {
            testOpps = new List<Opportunity>{
                new Opportunity(Name='Won',                 OwnerId=ae1Id, StageName='Closed Won',    CloseDate=Date.today(),            Type='New Business', Amount=10000, Booked_By_Role__c='AE - ENT'),
                new Opportunity(Name='Open later',          OwnerId=ae1Id, StageName='4 - Proposal',  CloseDate=Date.today().addDays(30), Type='New Business', Amount=10000, Booked_By_Role__c='AE - ENT'),
                new Opportunity(Name='Lost progressed',     OwnerId=ae1Id, StageName='Closed Lost',   CloseDate=Date.today(),            Type='New Business', Amount=10000, Booked_By_Role__c='AE - ENT'),
                new Opportunity(Name='Lost at source',      OwnerId=ae1Id, StageName='Closed Lost',   CloseDate=Date.today(),            Type='New Business', Amount=10000, Booked_By_Role__c='AE - ENT'),
                new Opportunity(Name='In flight at source', OwnerId=ae1Id, StageName='2 - Discovery', CloseDate=Date.today().addDays(30), Type='New Business', Amount=10000, Booked_By_Role__c='AE - ENT')
            };
            insert testOpps;
        }

        // Stage histories per intended outcome.
        Map<Id, Set<String>> mock = new Map<Id, Set<String>>();
        mock.put(testOpps[0].Id, new Set<String>{'1 - Demo','2 - Discovery','3 - POV','4 - Proposal','5 - Contracting','Closed Won'});
        mock.put(testOpps[1].Id, new Set<String>{'1 - Demo','2 - Discovery','3 - POV','4 - Proposal'});
        mock.put(testOpps[2].Id, new Set<String>{'1 - Demo','2 - Discovery','3 - POV'});
        mock.put(testOpps[3].Id, new Set<String>{'1 - Demo','2 - Discovery'});
        mock.put(testOpps[4].Id, new Set<String>{'1 - Demo','2 - Discovery'});
        PGInsightsController.mockStagesByOpp = mock;

        Test.startTest();
        // fromRank = 2 (Discovery -> POV) exercises every category.
        List<PGInsightsController.HeatmapCellOpp> rows =
            PGInsightsController.getHeatmapCellOpps(String.valueOf(ae1Id), 2, 'AE', false);
        Test.stopTest();

        Map<String, String> categoryByName = new Map<String, String>();
        for (PGInsightsController.HeatmapCellOpp r : rows) categoryByName.put(r.name, r.category);
        System.assertEquals('CLOSED_WON',             categoryByName.get('Won'),                 'Closed Won');
        System.assertEquals('OPEN_LATER_STAGE',       categoryByName.get('Open later'),          'Open · later stage');
        System.assertEquals('CLOSED_LOST_PROGRESSED', categoryByName.get('Lost progressed'),     'Closed Lost progressed');
        System.assertEquals('CLOSED_LOST_AT_SOURCE',  categoryByName.get('Lost at source'),      'Closed Lost at source');
        System.assertEquals('IN_FLIGHT_AT_SOURCE',    categoryByName.get('In flight at source'), 'In flight at source');

        // highestStageReached populated.
        for (PGInsightsController.HeatmapCellOpp r : rows) {
            System.assertNotEquals(null, r.highestStageReached,
                'highestStageReached set for ' + r.name);
        }
    }

    @IsTest
    static void getHeatmapCellOpps_byPodReturnsAllPodAEs() {
        PGInsightsController.mockStagesByOpp = buildSimpleStagesMock();
        Test.startTest();
        // Pod 'IB' should aggregate across IB1 + IB2 AEs (ae1 + ae2).
        List<PGInsightsController.HeatmapCellOpp> rows =
            PGInsightsController.getHeatmapCellOpps('IB', 1, 'Pod', true);
        Test.stopTest();

        // 6 ae1 opps + 3 ae2 opps in stage 2+; all eligible for fromRank=1 since
        // the simple mock has them all reaching at least Discovery (rank 2).
        System.assertEquals(9, rows.size(), 'IB combined drilldown returns ae1 + ae2 opps');
    }

    // ---- Phase E: outreach manager grouping ---------------------------------------

    @IsTest
    static void getIndividualOutreach_includesManagerInfo() {
        Test.startTest();
        List<PGInsightsController.OutreachRow> rows =
            PGInsightsController.getIndividualOutreach('CW');
        Test.stopTest();

        // Test users have no manager assigned, so managerName should be null
        // for every row. The query path runs regardless and the field is set.
        System.assert(rows.size() > 0, 'outreach rows returned');
        for (PGInsightsController.OutreachRow r : rows) {
            // managerId/managerName fields exist on every row (both null is
            // acceptable — proves the enrichment loop ran without error).
            System.assertEquals(null, r.managerName,
                'Test users have no manager — managerName should be null');
        }
    }

    // ---- helpers --------------------------------------------------------------------

    /**
     * Simple stages mock for heatmap tests. Maps every Stage 2+ test opp to a
     * stage set that reaches at least Discovery so the heatmap produces a row
     * for each AE.
     */
    private static Map<Id, Set<String>> buildSimpleStagesMock() {
        Set<Id> aeIds = computeTestAeIds();
        Map<Id, Set<String>> mock = new Map<Id, Set<String>>();
        Set<String> stages = new Set<String>{
            '1 - Demo', '2 - Discovery', '3 - POV', 'Closed Won'
        };
        for (Opportunity o : [
            SELECT Id, StageName FROM Opportunity
            WHERE OwnerId IN :aeIds AND StageName != '1 - Demo'
        ]) {
            mock.put(o.Id, stages);
        }
        return mock;
    }


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
            Amount = 50000,
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
