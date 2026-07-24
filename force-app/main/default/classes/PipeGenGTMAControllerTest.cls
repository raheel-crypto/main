@IsTest
private class PipeGenGTMAControllerTest {

    // ─── Test Data Helpers ───────────────────────────────────────────────────────

    private static User makeGTMAUser() {
        UserRole r = [SELECT Id FROM UserRole WHERE Name = 'GTM Associate' LIMIT 1];
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName   = 'GTMA',
            LastName    = 'Test',
            Email       = 'gtma.test@example.com',
            Username    = 'gtma.test.' + System.currentTimeMillis() + '@example.com',
            Alias       = 'gtmatest',
            UserRoleId  = r.Id,
            ProfileId   = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // User is a setup object — must be inserted in its own DML context
        // to avoid MIXED_DML_OPERATION errors when non-setup objects follow.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Account makeAccount(Id gtmaUserId, Boolean isTarget, String status) {
        Account a = new Account(
            Name                  = 'Test Account ' + System.currentTimeMillis(),
            GTM_Associate__c      = gtmaUserId,
            GTMA_Target_Account__c = isTarget,
            Account_Status__c     = status
        );
        insert a;
        return a;
    }

    private static Weekly_Commit__c makeCommit(Id userId, Date weekStart, String type, String status) {
        Weekly_Commit__c c = new Weekly_Commit__c(
            Rep__c                = userId,
            Week_Start_Date__c    = weekStart,
            Commit_Type__c        = type,
            Motion_Type__c        = 'GTMA Activity',
            Commit_Description__c = 'Test commit',
            Committed_Count__c    = 1,
            Actual_Count__c       = status == 'Completed' ? 1 : 0,
            Completion_Status__c  = status
        );
        insert c;
        return c;
    }

    // ─── getGTMADashboardData Tests ──────────────────────────────────────────────

    @IsTest
    static void testGetDashboardData_noTargetAccounts() {
        User gtma = makeGTMAUser();
        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertNotEquals(null, d, 'Result should not be null');
        System.assertNotEquals(null, d.weeklyTarget, 'Weekly target should not be null');
        System.assertEquals(0, d.targetAccounts.size(), 'No targeted accounts expected');
        System.assertEquals(0, d.thisWeekCommits.size(), 'No commits expected');
    }

    @IsTest
    static void testGetDashboardData_withTargetAccounts() {
        User gtma = makeGTMAUser();
        System.runAs(gtma) {
            makeAccount(gtma.Id, true,  'Prospect');
            makeAccount(gtma.Id, true,  'Customer');
            makeAccount(gtma.Id, false, 'Prospect'); // not targeted — should be excluded
        }

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(2, d.targetAccounts.size(), 'Only targeted accounts should appear');
    }

    @IsTest
    static void testGetDashboardData_weeklyTargetCounts() {
        User gtma = makeGTMAUser();
        Date weekStart = PipeGenGTMAController.getWeekStart(Date.today());

        System.runAs(gtma) {
            makeCommit(gtma.Id, weekStart, 'Meeting Booked', 'Completed');
            makeCommit(gtma.Id, weekStart, 'Cold Call Made', 'Not Started');
            makeCommit(gtma.Id, weekStart, 'LinkedIn Outreach', 'Completed');
        }

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(3, d.weeklyTarget.total, 'Total commits should be 3');
        System.assertEquals(2, d.weeklyTarget.completed, 'Completed commits should be 2');
    }

    @IsTest
    static void testGetDashboardData_weekLabelFormatted() {
        User gtma = makeGTMAUser();
        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assert(d.weeklyTarget.weekLabel.startsWith('Week of '),
            'Week label should start with "Week of "');
    }

    @IsTest
    static void testGetDashboardData_thisWeekCommitsReturned() {
        User gtma = makeGTMAUser();
        Date weekStart = PipeGenGTMAController.getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        System.runAs(gtma) {
            makeCommit(gtma.Id, weekStart, 'Meeting Booked', 'Not Started');
            makeCommit(gtma.Id, lastWeekStart, 'Cold Call Made', 'Not Started'); // last week — excluded
        }

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(1, d.thisWeekCommits.size(), 'Only this week commits should be returned');
    }

    // ─── Scorecard Tests ─────────────────────────────────────────────────────────

    @IsTest
    static void testScorecard_accountsTouched() {
        User gtma = makeGTMAUser();
        Date lastWeekStart = PipeGenGTMAController.getWeekStart(Date.today()).addDays(-7);
        Account a1, a2;
        System.runAs(gtma) {
            a1 = makeAccount(gtma.Id, true, 'Prospect');
            a2 = makeAccount(gtma.Id, true, 'Prospect');
        }

        Weekly_Commit__c c1 = new Weekly_Commit__c(
            Rep__c = gtma.Id, Week_Start_Date__c = lastWeekStart,
            Commit_Type__c = 'Meeting Booked', Commit_Description__c = 'Test',
            Committed_Count__c = 1, Target_Account__c = a1.Id, Motion_Type__c = 'GTMA Activity',
            Completion_Status__c = 'Completed'
        );
        Weekly_Commit__c c2 = new Weekly_Commit__c(
            Rep__c = gtma.Id, Week_Start_Date__c = lastWeekStart,
            Commit_Type__c = 'Cold Call Made', Commit_Description__c = 'Test',
            Committed_Count__c = 1, Target_Account__c = a2.Id, Motion_Type__c = 'GTMA Activity',
            Completion_Status__c = 'Not Started'
        );
        insert new List<Weekly_Commit__c>{ c1, c2 };

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(2, d.lastWeekScorecard.accountsTouched, 'Should count 2 distinct accounts');
        System.assertEquals(1, d.lastWeekScorecard.commitsCompleted, 'Should count 1 completed commit');
        System.assertEquals(2, d.lastWeekScorecard.commitsTotal, 'Should count 2 total commits');
    }

    @IsTest
    static void testScorecard_pipelineInfluence() {
        User gtma = makeGTMAUser();
        Account a;
        System.runAs(gtma) {
            a = makeAccount(gtma.Id, false, 'Prospect');
        }

        Opportunity opp = new Opportunity(
            Name       = 'Test Opp',
            AccountId  = a.Id,
            StageName  = '2 - Discovery',
            CloseDate  = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(1, d.lastWeekScorecard.pipelineInfluence,
            'Pipeline influence should include the open opp');
    }

    @IsTest
    static void testScorecard_emptyWhenNoLastWeekCommits() {
        User gtma = makeGTMAUser();
        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(0, d.lastWeekScorecard.commitsTotal);
        System.assertEquals(0, d.lastWeekScorecard.commitsCompleted);
        System.assertEquals(0, d.lastWeekScorecard.accountsTouched);
    }

    // ─── getGTMAAccountsForSelection Tests ──────────────────────────────────────

    @IsTest
    static void testGetAccountsForSelection_onlyGTMAAccounts() {
        User gtma = makeGTMAUser();
        User other = makeGTMAUser();
        System.runAs(gtma) {
            makeAccount(gtma.Id,  true,  'Prospect');
            makeAccount(other.Id, false, 'Prospect'); // different GTM Associate
        }

        Test.startTest();
        List<PipeGenGTMAController.AccountCard> cards;
        System.runAs(gtma) {
            cards = PipeGenGTMAController.getGTMAAccountsForSelection();
        }
        Test.stopTest();

        System.assertEquals(1, cards.size(), 'Only GTM_Associate__c accounts should be returned');
    }

    @IsTest
    static void testGetAccountsForSelection_targetedFlagReflected() {
        User gtma = makeGTMAUser();
        System.runAs(gtma) {
            makeAccount(gtma.Id, true,  'Prospect');
            makeAccount(gtma.Id, false, 'Prospect');
        }

        Test.startTest();
        List<PipeGenGTMAController.AccountCard> cards;
        System.runAs(gtma) {
            cards = PipeGenGTMAController.getGTMAAccountsForSelection();
        }
        Test.stopTest();

        Integer targeted = 0;
        for (PipeGenGTMAController.AccountCard c : cards) if (c.isTargeted) targeted++;
        System.assertEquals(1, targeted, 'One account should be flagged as targeted');
    }

    @IsTest
    static void testGetAccountsForSelection_segmentComputed() {
        User gtma = makeGTMAUser();
        System.runAs(gtma) {
            Account a = makeAccount(gtma.Id, false, 'Customer');
            a.ARR__c = 50000;
            update a;
        }

        Test.startTest();
        List<PipeGenGTMAController.AccountCard> cards;
        System.runAs(gtma) {
            cards = PipeGenGTMAController.getGTMAAccountsForSelection();
        }
        Test.stopTest();

        System.assertEquals('Expansion', cards[0].segment, 'Customer with ARR should be Expansion');
    }

    // ─── updateGTMATargetAccounts Tests ─────────────────────────────────────────

    @IsTest
    static void testUpdateGTMATargetAccounts_setTarget() {
        User gtma = makeGTMAUser();
        Account a = makeAccount(gtma.Id, false, 'Prospect');

        Test.startTest();
        System.runAs(gtma) {
            PipeGenGTMAController.updateGTMATargetAccounts(
                new List<Id>{ a.Id }, new List<Id>()
            );
        }
        Test.stopTest();

        Account updated = [SELECT GTMA_Target_Account__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(true, updated.GTMA_Target_Account__c, 'Account should be targeted');
    }

    @IsTest
    static void testUpdateGTMATargetAccounts_unsetTarget() {
        User gtma = makeGTMAUser();
        Account a = makeAccount(gtma.Id, true, 'Prospect');

        Test.startTest();
        System.runAs(gtma) {
            PipeGenGTMAController.updateGTMATargetAccounts(
                new List<Id>(), new List<Id>{ a.Id }
            );
        }
        Test.stopTest();

        Account updated = [SELECT GTMA_Target_Account__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(false, updated.GTMA_Target_Account__c, 'Account should be untargeted');
    }

    @IsTest
    static void testUpdateGTMATargetAccounts_doesNotTouchAEFlag() {
        User gtma = makeGTMAUser();
        Account a = makeAccount(gtma.Id, false, 'Prospect');
        a.Target_Account__c = true; // AE flag set separately
        update a;

        Test.startTest();
        System.runAs(gtma) {
            PipeGenGTMAController.updateGTMATargetAccounts(
                new List<Id>{ a.Id }, new List<Id>()
            );
        }
        Test.stopTest();

        Account updated = [SELECT GTMA_Target_Account__c, Target_Account__c FROM Account WHERE Id = :a.Id];
        System.assertEquals(true,  updated.GTMA_Target_Account__c, 'GTMA flag should be set');
        System.assertEquals(true,  updated.Target_Account__c,      'AE flag should be unchanged');
    }

    // ─── saveCommit / deleteCommit Tests ────────────────────────────────────────

    @IsTest
    static void testSaveCommit_insertsNewRecord() {
        User gtma = makeGTMAUser();
        Test.startTest();
        Weekly_Commit__c saved;
        System.runAs(gtma) {
            Weekly_Commit__c rec = new Weekly_Commit__c(
                Commit_Type__c        = 'Meeting Booked',
                Commit_Description__c = 'First meeting at Acme',
                Motion_Type__c        = 'GTMA Activity',
                Committed_Count__c    = 1
            );
            saved = PipeGenGTMAController.saveCommit(rec, 0);
        }
        Test.stopTest();

        System.assertNotEquals(null, saved.Id, 'Saved record should have an Id');
        System.assertEquals(gtma.Id, saved.Rep__c, 'Rep__c should be set to current user');
        System.assertNotEquals(null, saved.Week_Start_Date__c, 'Week_Start_Date__c should be set');
        System.assertEquals('GTMA Activity', saved.Motion_Type__c, 'Motion_Type__c should be null for GTMAs');
    }

    @IsTest
    static void testSaveCommit_upsertUpdatesExisting() {
        User gtma = makeGTMAUser();
        Date weekStart = PipeGenGTMAController.getWeekStart(Date.today());
        Weekly_Commit__c existing;
        System.runAs(gtma) {
            existing = makeCommit(gtma.Id, weekStart, 'Cold Call Made', 'Not Started');
        }

        Test.startTest();
        System.runAs(gtma) {
            existing.Commit_Description__c = 'Updated description';
            PipeGenGTMAController.saveCommit(existing, 0);
        }
        Test.stopTest();

        Weekly_Commit__c updated = [SELECT Commit_Description__c FROM Weekly_Commit__c WHERE Id = :existing.Id];
        System.assertEquals('Updated description', updated.Commit_Description__c);
    }

    @IsTest
    static void testDeleteCommit() {
        User gtma = makeGTMAUser();
        Date weekStart = PipeGenGTMAController.getWeekStart(Date.today());
        Weekly_Commit__c c;
        System.runAs(gtma) {
            c = makeCommit(gtma.Id, weekStart, 'Meeting Booked', 'Not Started');
        }

        Test.startTest();
        System.runAs(gtma) {
            PipeGenGTMAController.deleteCommit(c.Id);
        }
        Test.stopTest();

        List<Weekly_Commit__c> remaining = [SELECT Id FROM Weekly_Commit__c WHERE Id = :c.Id];
        System.assertEquals(0, remaining.size(), 'Commit should be deleted');
    }

    // ─── carryForwardGTMACommits Tests ───────────────────────────────────────────

    @IsTest
    static void testCarryForward_copiesAllCommitsWhenNoSelection() {
        User gtma = makeGTMAUser();
        Date weekStart     = PipeGenGTMAController.getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        System.runAs(gtma) {
            makeCommit(gtma.Id, lastWeekStart, 'Meeting Booked',   'Not Started');
            makeCommit(gtma.Id, lastWeekStart, 'LinkedIn Outreach', 'Partial');
            makeCommit(gtma.Id, lastWeekStart, 'Cold Call Made',    'Completed');
        }

        Test.startTest();
        List<Weekly_Commit__c> carried;
        System.runAs(gtma) {
            carried = PipeGenGTMAController.carryForwardGTMACommits(0, null);
        }
        Test.stopTest();

        System.assertEquals(3, carried.size(), 'All 3 prior-week commits should be carried forward when selectedIds is null');
        for (Weekly_Commit__c c : carried) {
            System.assertEquals(weekStart, c.Week_Start_Date__c, 'Carried commits should be in current week');
        }
    }

    @IsTest
    static void testCarryForward_copiesOnlySelectedCommits() {
        User gtma = makeGTMAUser();
        Date weekStart     = PipeGenGTMAController.getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        Weekly_Commit__c c1, c2, c3;
        System.runAs(gtma) {
            c1 = makeCommit(gtma.Id, lastWeekStart, 'Meeting Booked',    'Not Started');
            c2 = makeCommit(gtma.Id, lastWeekStart, 'LinkedIn Outreach', 'Partial');
            c3 = makeCommit(gtma.Id, lastWeekStart, 'Cold Call Made',    'Completed');
        }

        Test.startTest();
        List<Weekly_Commit__c> carried;
        System.runAs(gtma) {
            carried = PipeGenGTMAController.carryForwardGTMACommits(0, new List<Id>{ c1.Id, c2.Id });
        }
        Test.stopTest();

        System.assertEquals(2, carried.size(), 'Only the 2 selected commits should be carried forward');
    }

    @IsTest
    static void testCarryForward_returnsEmptyWhenNothingToCarry() {
        User gtma = makeGTMAUser();
        Test.startTest();
        List<Weekly_Commit__c> carried;
        System.runAs(gtma) {
            carried = PipeGenGTMAController.carryForwardGTMACommits(0, null);
        }
        Test.stopTest();

        System.assertEquals(0, carried.size(), 'No commits to carry — should return empty list');
    }

    // ─── massCreateMeetingCommits Tests ──────────────────────────────────────────

    @IsTest
    static void testMassCreate_oneCommitPerTargetAccount() {
        User gtma = makeGTMAUser();
        Account a1, a2, a3;
        System.runAs(gtma) {
            a1 = makeAccount(gtma.Id, true,  'Prospect');
            a2 = makeAccount(gtma.Id, true,  'Customer');
            a3 = makeAccount(gtma.Id, false, 'Prospect'); // NOT a target — should be skipped
        }

        Test.startTest();
        List<Weekly_Commit__c> created;
        System.runAs(gtma) {
            created = PipeGenGTMAController.massCreateMeetingCommits(0);
        }
        Test.stopTest();

        System.assertEquals(2, created.size(), 'One commit per targeted account (non-target excluded)');
        for (Weekly_Commit__c c : created) {
            System.assertEquals('Meeting Booked', c.Commit_Type__c, 'Type should be Meeting Booked');
            System.assertEquals(1, c.Committed_Count__c, 'Count should be 1');
            System.assertNotEquals(null, c.Target_Account__c, 'Should be tied to an account');
        }
    }

    @IsTest
    static void testMassCreate_skipsAccountsAlreadyCommitted() {
        User gtma = makeGTMAUser();
        Date weekStart = PipeGenGTMAController.getWeekStart(Date.today());
        Account a1;
        System.runAs(gtma) {
            a1 = makeAccount(gtma.Id, true, 'Prospect');
            makeAccount(gtma.Id, true, 'Customer');
            // Pre-existing Meeting Booked commit on a1 this week
            Weekly_Commit__c pre = makeCommit(gtma.Id, weekStart, 'Meeting Booked', 'Not Started');
            pre.Target_Account__c = a1.Id;
            update pre;
        }

        Test.startTest();
        List<Weekly_Commit__c> created;
        System.runAs(gtma) {
            created = PipeGenGTMAController.massCreateMeetingCommits(0);
        }
        Test.stopTest();

        System.assertEquals(1, created.size(), 'Only the account without an existing commit should get one');
    }

    // ─── getWeekStart Tests ──────────────────────────────────────────────────────

    @IsTest
    static void testGetWeekStart_returnsMonday() {
        // 2026-05-21 is a Thursday
        Date thursday = Date.newInstance(2026, 5, 21);
        Date monday   = PipeGenGTMAController.getWeekStart(thursday);
        System.assertEquals(Date.newInstance(2026, 5, 18), monday, 'Week start should be the preceding Monday');
    }

    @IsTest
    static void testGetWeekStart_mondayIsOwnWeekStart() {
        Date monday = Date.newInstance(2026, 5, 18);
        System.assertEquals(monday, PipeGenGTMAController.getWeekStart(monday),
            'Monday should return itself as week start');
    }

    // ─── GTMA2 Tier — Helper ─────────────────────────────────────────────────────

    private static User makeGTMA2User() {
        UserRole r = [SELECT Id FROM UserRole WHERE Name = 'GTM Associate' LIMIT 1];
        Profile  p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName              = 'GTMA2',
            LastName               = 'Test',
            Email                  = 'gtma2.test@example.com',
            Username               = 'gtma2.test.' + System.currentTimeMillis() + '@example.com',
            Alias                  = 'g2test',
            UserRoleId             = r.Id,
            ProfileId              = p.Id,
            TimeZoneSidKey         = 'America/Los_Angeles',
            LocaleSidKey           = 'en_US',
            EmailEncodingKey       = 'UTF-8',
            LanguageLocaleKey      = 'en_US',
            GTM_Associate_Tier__c  = '2'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    // ─── GTMA2 isGTMA2 flag Tests ─────────────────────────────────────────────────

    @IsTest
    static void testGetDashboardData_isGTMA2FalseForTier1() {
        User gtma1 = makeGTMAUser();
        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma1) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();
        System.assertEquals(false, d.isGTMA2, 'Standard GTMA user should have isGTMA2=false');
    }

    @IsTest
    static void testGetDashboardData_isGTMA2TrueForTier2() {
        User gtma2 = makeGTMA2User();
        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma2) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();
        System.assertEquals(true, d.isGTMA2, 'Tier 2 user should have isGTMA2=true');
    }

    // ─── GTMA2 buildTargetAccounts Tests ─────────────────────────────────────────

    @IsTest
    static void testGetDashboardData_gtma2TargetAccountsFromJunctionRecords() {
        User gtma2 = makeGTMA2User();
        Account a = new Account(Name = 'Coverage Acct');
        insert a;
        GTM_Coverage__c cov = new GTM_Coverage__c(
            Account__c       = a.Id,
            Rep__c           = gtma2.Id,
            Coverage_Type__c = 'GTMA2 Target',
            Is_Active__c     = true,
            Date_Added__c    = Date.today()
        );
        insert cov;

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma2) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(1, d.targetAccounts.size(), 'GTMA2 target accounts should come from junction records');
        System.assertEquals(a.Id, d.targetAccounts[0].id);
    }

    @IsTest
    static void testGetDashboardData_gtma2IgnoresInactiveCoverageRecords() {
        User gtma2 = makeGTMA2User();
        Account a = new Account(Name = 'Inactive Coverage');
        insert a;
        GTM_Coverage__c cov = new GTM_Coverage__c(
            Account__c       = a.Id,
            Rep__c           = gtma2.Id,
            Coverage_Type__c = 'GTMA2 Target',
            Is_Active__c     = false,
            Date_Added__c    = Date.today().addDays(-7),
            Date_Removed__c  = Date.today().addDays(-1)
        );
        insert cov;

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma2) {
            d = PipeGenGTMAController.getGTMADashboardData(0);
        }
        Test.stopTest();

        System.assertEquals(0, d.targetAccounts.size(), 'Inactive coverage records should not appear as targets');
    }

    // ─── searchAllAccounts Tests ──────────────────────────────────────────────────

    @IsTest
    static void testSearchAllAccounts_returnsMatchingAccounts() {
        Account a1 = new Account(Name = 'Acme Corporation');
        Account a2 = new Account(Name = 'Acme Widgets');
        Account a3 = new Account(Name = 'Globex');
        insert new List<Account>{ a1, a2, a3 };

        User gtma2 = makeGTMA2User();
        Test.startTest();
        List<Account> results;
        System.runAs(gtma2) {
            results = PipeGenGTMAController.searchAllAccounts('Acme', new List<Id>());
        }
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should return 2 accounts matching "Acme"');
    }

    @IsTest
    static void testSearchAllAccounts_excludesSpecifiedIds() {
        Account a1 = new Account(Name = 'Acme Corp');
        Account a2 = new Account(Name = 'Acme Inc');
        insert new List<Account>{ a1, a2 };

        User gtma2 = makeGTMA2User();
        Test.startTest();
        List<Account> results;
        System.runAs(gtma2) {
            results = PipeGenGTMAController.searchAllAccounts('Acme', new List<Id>{ a1.Id });
        }
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should exclude already-targeted account');
        System.assertEquals(a2.Id, results[0].Id);
    }

    @IsTest
    static void testSearchAllAccounts_emptyForShortTerms() {
        User gtma2 = makeGTMA2User();
        Test.startTest();
        List<Account> results;
        System.runAs(gtma2) {
            results = PipeGenGTMAController.searchAllAccounts('Ac', new List<Id>());
        }
        Test.stopTest();
        System.assertEquals(0, results.size(), 'Search term shorter than 3 chars should return empty');
    }

    // ─── addGTMA2Target Tests ─────────────────────────────────────────────────────

    @IsTest
    static void testAddGTMA2Target_createsJunctionRecord() {
        User gtma2 = makeGTMA2User();
        Account a = new Account(Name = 'Target Co');
        insert a;

        Test.startTest();
        System.runAs(gtma2) {
            PipeGenGTMAController.addGTMA2Target(a.Id);
        }
        Test.stopTest();

        List<GTM_Coverage__c> records = [
            SELECT Id, Is_Active__c, Coverage_Type__c, Date_Added__c
            FROM GTM_Coverage__c
            WHERE Rep__c = :gtma2.Id AND Account__c = :a.Id
        ];
        System.assertEquals(1, records.size(), 'Should create one junction record');
        System.assertEquals(true,            records[0].Is_Active__c);
        System.assertEquals('GTMA2 Target',  records[0].Coverage_Type__c);
        System.assertNotEquals(null,          records[0].Date_Added__c);
    }

    @IsTest
    static void testAddGTMA2Target_idempotentWhenAlreadyActive() {
        User gtma2 = makeGTMA2User();
        Account a = new Account(Name = 'Target Co');
        insert a;
        GTM_Coverage__c existing = new GTM_Coverage__c(
            Account__c = a.Id, Rep__c = gtma2.Id,
            Coverage_Type__c = 'GTMA2 Target', Is_Active__c = true, Date_Added__c = Date.today()
        );
        insert existing;

        Test.startTest();
        System.runAs(gtma2) {
            PipeGenGTMAController.addGTMA2Target(a.Id);
        }
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :gtma2.Id AND Account__c = :a.Id];
        System.assertEquals(1, count, 'Should not create duplicate active record');
    }

    // ─── removeGTMA2Target Tests ──────────────────────────────────────────────────

    @IsTest
    static void testRemoveGTMA2Target_deactivatesJunctionRecord() {
        User gtma2 = makeGTMA2User();
        Account a = new Account(Name = 'To Remove');
        insert a;
        GTM_Coverage__c cov = new GTM_Coverage__c(
            Account__c = a.Id, Rep__c = gtma2.Id,
            Coverage_Type__c = 'GTMA2 Target', Is_Active__c = true, Date_Added__c = Date.today()
        );
        insert cov;

        Test.startTest();
        System.runAs(gtma2) {
            PipeGenGTMAController.removeGTMA2Target(a.Id);
        }
        Test.stopTest();

        GTM_Coverage__c updated = [SELECT Is_Active__c, Date_Removed__c FROM GTM_Coverage__c WHERE Id = :cov.Id];
        System.assertEquals(false, updated.Is_Active__c,    'Record should be deactivated');
        System.assertNotEquals(null, updated.Date_Removed__c, 'Date_Removed__c should be set');
    }

    // ─── getGTMAAccountsForSelection — GTMA2 branch Tests ─────────────────────────

    @IsTest
    static void testGetAccountsForSelection_gtma2ReturnsJunctionAccounts() {
        User gtma2 = makeGTMA2User();
        Account a1 = new Account(Name = 'Covered Acct');
        Account a2 = new Account(Name = 'Not Covered');
        insert new List<Account>{ a1, a2 };
        GTM_Coverage__c cov = new GTM_Coverage__c(
            Account__c = a1.Id, Rep__c = gtma2.Id,
            Coverage_Type__c = 'GTMA2 Target', Is_Active__c = true, Date_Added__c = Date.today()
        );
        insert cov;

        Test.startTest();
        List<PipeGenGTMAController.AccountCard> cards;
        System.runAs(gtma2) {
            cards = PipeGenGTMAController.getGTMAAccountsForSelection();
        }
        Test.stopTest();

        System.assertEquals(1, cards.size(), 'GTMA2 should only see their coverage accounts');
        System.assertEquals(a1.Id, cards[0].id);
        System.assertEquals(true, cards[0].isTargeted, 'Coverage accounts should be flagged as targeted');
    }

    @IsTest
    static void testGetAccountsForSelection_gtma2EmptyWhenNoCoverage() {
        User gtma2 = makeGTMA2User();
        insert new Account(Name = 'Any Acct');

        Test.startTest();
        List<PipeGenGTMAController.AccountCard> cards;
        System.runAs(gtma2) {
            cards = PipeGenGTMAController.getGTMAAccountsForSelection();
        }
        Test.stopTest();

        System.assertEquals(0, cards.size(), 'GTMA2 with no coverage records should get empty list');
    }
}
