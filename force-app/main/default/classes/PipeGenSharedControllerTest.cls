@IsTest
private class PipeGenSharedControllerTest {

    // ─── Test Data Helpers ───────────────────────────────────────────────────────

    private static User makeAEUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName         = 'AE',
            LastName          = 'SharedTest',
            Email             = 'ae.shared.test@example.com',
            Username          = 'ae.shared.' + System.currentTimeMillis() + '@example.com',
            Alias             = 'aeshared',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static User makeGTMAUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName         = 'GTMA',
            LastName          = 'SharedTest',
            Email             = 'gtma.shared.test@example.com',
            Username          = 'gtma.shared.' + System.currentTimeMillis() + '@example.com',
            Alias             = 'gtmash',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Account makeAccount(Id ownerId, Id gtmaId, String name) {
        Account a = new Account(
            Name             = name,
            OwnerId          = ownerId,
            GTM_Associate__c = gtmaId
        );
        insert a;
        return a;
    }

    private static Weekly_Commit__c makeCommit(
        Id repId, Date weekStart, String type, String status,
        Boolean isShared, Id sharedPartner, Id targetAccount
    ) {
        Weekly_Commit__c c = new Weekly_Commit__c(
            Rep__c                = repId,
            Week_Start_Date__c    = weekStart,
            Commit_Type__c        = type,
            Commit_Description__c = 'Test commit',
            Committed_Count__c    = 2,
            Actual_Count__c       = status == 'Completed' ? 2 : 0,
            Completion_Status__c  = status,
            Is_Shared__c          = isShared,
            Shared_Partner__c     = sharedPartner,
            Target_Account__c     = targetAccount
        );
        insert c;
        return c;
    }

    // ─── getMyGTMAs Tests ────────────────────────────────────────────────────────

    @IsTest
    static void testGetMyGTMAs_emptyWhenNoMappedAccounts() {
        User ae = makeAEUser();

        Test.startTest();
        List<PipeGenSharedController.GTMAUser> gtmas;
        System.runAs(ae) {
            gtmas = PipeGenSharedController.getMyGTMAs();
        }
        Test.stopTest();

        System.assertEquals(0, gtmas.size(), 'No GTMAs expected when AE has no GTMA-mapped accounts');
    }

    @IsTest
    static void testGetMyGTMAs_deduplicatesMultipleAccountsPerGTMA() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        makeAccount(ae.Id, gtma.Id, 'Acme 1');
        makeAccount(ae.Id, gtma.Id, 'Acme 2');

        Test.startTest();
        List<PipeGenSharedController.GTMAUser> gtmas;
        System.runAs(ae) {
            gtmas = PipeGenSharedController.getMyGTMAs();
        }
        Test.stopTest();

        System.assertEquals(1, gtmas.size(), 'Two accounts mapped to the same GTMA should return 1 entry');
        System.assertEquals(String.valueOf(gtma.Id), gtmas[0].id, 'GTMA Id should match');
    }

    @IsTest
    static void testGetMyGTMAs_returnsDistinctGTMAs() {
        User ae    = makeAEUser();
        User gtma1 = makeGTMAUser();
        User gtma2 = makeGTMAUser();
        makeAccount(ae.Id, gtma1.Id, 'Acme');
        makeAccount(ae.Id, gtma2.Id, 'Globex');

        Test.startTest();
        List<PipeGenSharedController.GTMAUser> gtmas;
        System.runAs(ae) {
            gtmas = PipeGenSharedController.getMyGTMAs();
        }
        Test.stopTest();

        System.assertEquals(2, gtmas.size(), 'Two distinct GTMAs should both be returned');
    }

    @IsTest
    static void testGetMyGTMAs_excludesAccountsWithoutGTMAMapping() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        makeAccount(ae.Id, gtma.Id, 'Mapped');
        Account unmapped = new Account(Name = 'No GTMA', OwnerId = ae.Id);
        insert unmapped;

        Test.startTest();
        List<PipeGenSharedController.GTMAUser> gtmas;
        System.runAs(ae) {
            gtmas = PipeGenSharedController.getMyGTMAs();
        }
        Test.stopTest();

        System.assertEquals(1, gtmas.size(), 'Account with no GTM_Associate__c should not produce a GTMA entry');
    }

    // ─── getSharedDashboardData Tests ────────────────────────────────────────────

    @IsTest
    static void testGetSharedDashboardData_returnsOnlyMatchingGTMAAccounts() {
        User ae       = makeAEUser();
        User gtma     = makeGTMAUser();
        User otherGtma = makeGTMAUser();
        makeAccount(ae.Id, gtma.Id,      'Match');
        makeAccount(ae.Id, otherGtma.Id, 'No Match');

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(1, d.accounts.size(), 'Only accounts mapped to the selected GTMA should appear');
        System.assertEquals('Match', d.accounts[0].name);
    }

    @IsTest
    static void testGetSharedDashboardData_excludesAccountsOwnedByOtherAEs() {
        User ae      = makeAEUser();
        User otherAE = makeAEUser();
        User gtma    = makeGTMAUser();
        makeAccount(ae.Id,      gtma.Id, 'Mine');
        makeAccount(otherAE.Id, gtma.Id, 'Not Mine');

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(1, d.accounts.size(), 'Accounts owned by other AEs should be excluded');
        System.assertEquals('Mine', d.accounts[0].name);
    }

    @IsTest
    static void testGetSharedDashboardData_sharedCommitsForCurrentWeekReturned() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        makeAccount(ae.Id, gtma.Id, 'Acme');
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        makeCommit(ae.Id, weekStart, 'Meeting Booked', 'Not Started', true, gtma.Id, null);

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(1, d.sharedCommits.size(), 'Shared commit for current week should appear');
        System.assertEquals(true, d.sharedCommits[0].Is_Shared__c);
    }

    @IsTest
    static void testGetSharedDashboardData_sharedCommitFromPriorWeekExcluded() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        makeAccount(ae.Id, gtma.Id, 'Acme');
        Date lastWeekStart = PipeGenSharedController.getWeekStart(Date.today()).addDays(-7);
        makeCommit(ae.Id, lastWeekStart, 'Meeting Booked', 'Not Started', true, gtma.Id, null);

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(0, d.sharedCommits.size(), 'Prior-week shared commit should be excluded');
    }

    @IsTest
    static void testGetSharedDashboardData_aeOnlyCommitsOnPairingAccounts() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        Account acct = makeAccount(ae.Id, gtma.Id, 'Acme');
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        makeCommit(ae.Id, weekStart, 'Meeting Booked', 'Not Started', false, null, acct.Id);

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(1, d.aeCommits.size(), 'AE-only commit on a pairing account should appear');
        System.assertEquals(0, d.sharedCommits.size(), 'Should not appear in shared commits');
    }

    @IsTest
    static void testGetSharedDashboardData_gtmaOnlyCommitsOnPairingAccounts() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        Account acct = makeAccount(ae.Id, gtma.Id, 'Acme');
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        makeCommit(gtma.Id, weekStart, 'Cold Call Made', 'Not Started', false, null, acct.Id);

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(1, d.gtmaCommits.size(), 'GTMA-only commit on a pairing account should appear');
    }

    @IsTest
    static void testGetSharedDashboardData_noAccountsYieldsEmptyLists() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        System.assertEquals(0, d.accounts.size());
        System.assertEquals(0, d.sharedCommits.size());
        System.assertEquals(0, d.aeCommits.size());
        System.assertEquals(0, d.gtmaCommits.size());
    }

    @IsTest
    static void testGetSharedDashboardData_accountRowFieldsMapped() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        Account a = makeAccount(ae.Id, gtma.Id, 'FieldCheck Corp');
        a.Account_Status__c = 'Prospect';
        a.ARR__c            = 75000;
        a.Website           = 'https://fieldcheck.com';
        update a;

        Test.startTest();
        PipeGenSharedController.SharedDashboardData d;
        System.runAs(ae) {
            d = PipeGenSharedController.getSharedDashboardData(gtma.Id);
        }
        Test.stopTest();

        PipeGenSharedController.SharedAccountRow row = d.accounts[0];
        System.assertEquals('FieldCheck Corp',       row.name);
        System.assertEquals('Prospect',              row.accountStatus);
        System.assertEquals(75000,                   row.arr);
        System.assertEquals('https://fieldcheck.com', row.website);
        System.assertEquals(0,                       row.contactCount);
    }

    // ─── createSharedCommit Tests ─────────────────────────────────────────────────

    @IsTest
    static void testCreateSharedCommit_setsSharedFields() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            Weekly_Commit__c rec = new Weekly_Commit__c(
                Commit_Type__c        = 'Meeting Booked',
                Commit_Description__c = 'Joint outreach',
                Committed_Count__c    = 2
            );
            result = PipeGenSharedController.createSharedCommit(rec, gtma.Id);
        }
        Test.stopTest();

        System.assertNotEquals(null, result.Id,             'Record should be inserted');
        System.assertEquals(ae.Id,   result.Rep__c,            'Rep__c should be the AE');
        System.assertEquals(true,    result.Is_Shared__c,      'Is_Shared__c should be true');
        System.assertEquals(gtma.Id, result.Shared_Partner__c, 'Shared_Partner__c should be the GTMA');
        System.assertNotEquals(null, result.Week_Start_Date__c, 'Week_Start_Date__c should be set');
    }

    @IsTest
    static void testCreateSharedCommit_weekStartAlignedToCurrentMonday() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();
        Date expectedWeekStart = PipeGenSharedController.getWeekStart(Date.today());

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.createSharedCommit(
                new Weekly_Commit__c(Commit_Type__c = 'Meeting Booked', Commit_Description__c = 'x', Committed_Count__c = 1),
                gtma.Id
            );
        }
        Test.stopTest();

        System.assertEquals(expectedWeekStart, result.Week_Start_Date__c, 'Week start should be the current Monday');
    }

    // ─── createPartnerCommit Tests ────────────────────────────────────────────────

    @IsTest
    static void testCreatePartnerCommit_nullTargetRepDefaultsToCurrentUser() {
        User ae = makeAEUser();

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.createPartnerCommit(
                new Weekly_Commit__c(Commit_Type__c = 'Cold Call Made', Commit_Description__c = 'AE only', Committed_Count__c = 1),
                null
            );
        }
        Test.stopTest();

        System.assertEquals(ae.Id, result.Rep__c,       'Rep__c should default to current user when targetRepId is null');
        System.assertEquals(false, result.Is_Shared__c, 'Is_Shared__c should be false');
    }

    @IsTest
    static void testCreatePartnerCommit_targetRepIdAssignedToSpecifiedRep() {
        User ae   = makeAEUser();
        User gtma = makeGTMAUser();

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.createPartnerCommit(
                new Weekly_Commit__c(Commit_Type__c = 'Meeting Booked', Commit_Description__c = 'GTMA only', Committed_Count__c = 1),
                gtma.Id
            );
        }
        Test.stopTest();

        System.assertEquals(gtma.Id, result.Rep__c,       'Rep__c should be the provided targetRepId');
        System.assertEquals(false,   result.Is_Shared__c, 'Is_Shared__c should be false');
    }

    // ─── toggleCommitComplete Tests ───────────────────────────────────────────────

    @IsTest
    static void testToggle_notStartedBecomesCompleted() {
        User ae = makeAEUser();
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        Weekly_Commit__c c = makeCommit(ae.Id, weekStart, 'Meeting Booked', 'Not Started', false, null, null);

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.toggleCommitComplete(c.Id);
        }
        Test.stopTest();

        System.assertEquals('Completed', result.Completion_Status__c, 'Not Started → Completed');
        System.assertEquals(2, result.Actual_Count__c.intValue(), 'Actual_Count should match Committed_Count');
    }

    @IsTest
    static void testToggle_completedBecomesNotStarted() {
        User ae = makeAEUser();
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        Weekly_Commit__c c = makeCommit(ae.Id, weekStart, 'Meeting Booked', 'Completed', false, null, null);

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.toggleCommitComplete(c.Id);
        }
        Test.stopTest();

        System.assertEquals('Not Started', result.Completion_Status__c, 'Completed → Not Started');
        System.assertEquals(0, result.Actual_Count__c.intValue(), 'Actual_Count should be reset to 0');
    }

    @IsTest
    static void testToggle_nullCommittedCountDefaultsActualToOne() {
        User ae = makeAEUser();
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        Weekly_Commit__c c = new Weekly_Commit__c(
            Rep__c = ae.Id, Week_Start_Date__c = weekStart,
            Commit_Type__c = 'Meeting Booked', Commit_Description__c = 'Test',
            Committed_Count__c = null, Actual_Count__c = 0,
            Completion_Status__c = 'Not Started', Is_Shared__c = false
        );
        insert c;

        Test.startTest();
        Weekly_Commit__c result;
        System.runAs(ae) {
            result = PipeGenSharedController.toggleCommitComplete(c.Id);
        }
        Test.stopTest();

        System.assertEquals('Completed', result.Completion_Status__c);
        System.assertEquals(1, result.Actual_Count__c.intValue(), 'Null Committed_Count should default Actual to 1');
    }

    // ─── deleteCommit Tests ───────────────────────────────────────────────────────

    @IsTest
    static void testDeleteCommit_removesRecord() {
        User ae = makeAEUser();
        Date weekStart = PipeGenSharedController.getWeekStart(Date.today());
        Weekly_Commit__c c = makeCommit(ae.Id, weekStart, 'Meeting Booked', 'Not Started', false, null, null);

        Test.startTest();
        System.runAs(ae) {
            PipeGenSharedController.deleteCommit(c.Id);
        }
        Test.stopTest();

        List<Weekly_Commit__c> remaining = [SELECT Id FROM Weekly_Commit__c WHERE Id = :c.Id];
        System.assertEquals(0, remaining.size(), 'Commit should be deleted');
    }

    // ─── getWeekStart Tests ───────────────────────────────────────────────────────

    @IsTest
    static void testGetWeekStart_thursdayReturnsPrecedingMonday() {
        // 2026-05-21 is a Thursday
        Date thursday = Date.newInstance(2026, 5, 21);
        System.assertEquals(
            Date.newInstance(2026, 5, 18),
            PipeGenSharedController.getWeekStart(thursday),
            'Thursday should return the preceding Monday'
        );
    }

    @IsTest
    static void testGetWeekStart_mondayReturnsItself() {
        Date monday = Date.newInstance(2026, 5, 18);
        System.assertEquals(monday, PipeGenSharedController.getWeekStart(monday),
            'Monday should return itself as week start');
    }
}
