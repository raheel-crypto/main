@IsTest
private class PipeGenGTMAControllerTest {

    // ─── Test Data Helpers ───────────────────────────────────────────────────────

    private static User makeGTMAUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName   = 'GTMA',
            LastName    = 'Test',
            Email       = 'gtma.test@example.com',
            Username    = 'gtma.test.' + System.currentTimeMillis() + '@example.com',
            Alias       = 'gtmatest',
            ProfileId   = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            Committed_Count__c = 1, Target_Account__c = a1.Id,
            Completion_Status__c = 'Completed'
        );
        Weekly_Commit__c c2 = new Weekly_Commit__c(
            Rep__c = gtma.Id, Week_Start_Date__c = lastWeekStart,
            Commit_Type__c = 'Cold Call Made', Commit_Description__c = 'Test',
            Committed_Count__c = 1, Target_Account__c = a2.Id,
            Completion_Status__c = 'Not Started'
        );
        insert new List<Weekly_Commit__c>{ c1, c2 };

        Test.startTest();
        PipeGenGTMAController.GTMADashboardData d;
        System.runAs(gtma) {
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
            d = PipeGenGTMAController.getGTMADashboardData();
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
                Committed_Count__c    = 1
            );
            saved = PipeGenGTMAController.saveCommit(rec);
        }
        Test.stopTest();

        System.assertNotEquals(null, saved.Id, 'Saved record should have an Id');
        System.assertEquals(gtma.Id, saved.Rep__c, 'Rep__c should be set to current user');
        System.assertNotEquals(null, saved.Week_Start_Date__c, 'Week_Start_Date__c should be set');
        System.assertEquals(null, saved.Motion_Type__c, 'Motion_Type__c should be null for GTMAs');
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
            PipeGenGTMAController.saveCommit(existing);
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
    static void testCarryForward_copiesIncompleteCommits() {
        User gtma = makeGTMAUser();
        Date weekStart     = PipeGenGTMAController.getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        System.runAs(gtma) {
            makeCommit(gtma.Id, lastWeekStart, 'Meeting Booked',   'Not Started');
            makeCommit(gtma.Id, lastWeekStart, 'LinkedIn Outreach', 'Partial');
            makeCommit(gtma.Id, lastWeekStart, 'Cold Call Made',    'Completed'); // should NOT carry
        }

        Test.startTest();
        List<Weekly_Commit__c> carried;
        System.runAs(gtma) {
            carried = PipeGenGTMAController.carryForwardGTMACommits();
        }
        Test.stopTest();

        System.assertEquals(2, carried.size(), 'Only 2 incomplete commits should be carried forward');
        for (Weekly_Commit__c c : carried) {
            System.assertEquals(weekStart, c.Week_Start_Date__c, 'Carried commits should be in current week');
        }
    }

    @IsTest
    static void testCarryForward_returnsEmptyWhenNothingToCarry() {
        User gtma = makeGTMAUser();
        Test.startTest();
        List<Weekly_Commit__c> carried;
        System.runAs(gtma) {
            carried = PipeGenGTMAController.carryForwardGTMACommits();
        }
        Test.stopTest();

        System.assertEquals(0, carried.size(), 'No commits to carry — should return empty list');
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
}
