@isTest
private class PipeGenControllerTest {

    // ─── Test Helpers ─────────────────────────────────────────────────────────

    // Mirrors the private getWeekStart so test data dates align with controller queries
    private static Date thisWeekStart() {
        Date d = Date.today();
        // Jan 1, 1900 was a Monday - use it as reference
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }

    private static Date lastWeekStart() {
        return thisWeekStart().addDays(-7);
    }

    private static User makeRep(Decimal annualTarget) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName                 = 'Test',
            LastName                  = 'PipeRep',
            Email                     = 'piperep@test.example.com',
            Username                  = 'piperep' + System.currentTimeMillis() + '@test.example.com',
            Alias                     = 'prep',
            TimeZoneSidKey            = 'America/New_York',
            LocaleSidKey              = 'en_US',
            EmailEncodingKey          = 'UTF-8',
            LanguageLocaleKey         = 'en_US',
            ProfileId                 = p.Id,
            Pipe_Gen_Annual_Target__c = annualTarget
        );
        insert u;
        return u;
    }

    private static Account makeTargetAccount(Id ownerId, String name) {
        Account a = new Account(Name = name, OwnerId = ownerId, Target_Account__c = true);
        insert a;
        return a;
    }

    private static Opportunity makeOpp(Id ownerId, Id accountId, String name, String stage, Decimal amount) {
        Opportunity o = new Opportunity(
            Name      = name,
            OwnerId   = ownerId,
            AccountId = accountId,
            StageName = stage,
            CloseDate = Date.today().addDays(30),
            Amount    = amount
        );
        insert o;
        return o;
    }

    private static Weekly_Commit__c makeCommit(Id repId, Date weekStart, String motion, String status) {
        Weekly_Commit__c c = new Weekly_Commit__c(
            Rep__c                = repId,
            Week_Start_Date__c    = weekStart,
            Motion_Type__c        = motion,
            Commit_Type__c        = motion == 'Net New' ? 'First Meeting Booked' : 'Discovery Call - Economic Buyer',
            Commit_Description__c = 'Test commit — ' + motion,
            Committed_Count__c    = 1,
            Completion_Status__c  = status
        );
        insert c;
        return c;
    }

    // ─── Dashboard Structure ──────────────────────────────────────────────────

    @isTest
    static void testDashboard_returnsAllSections() {
        User rep = makeRep(2000000);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Acme Corp');
            makeOpp(rep.Id, a.Id, 'Acme Deal', 'Stage 1', 75000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertNotEquals(null, d.quarterlyTarget);
            System.assertNotEquals(null, d.targetAccounts);
            System.assertNotEquals(null, d.stage1Opps);
            System.assertNotEquals(null, d.thisWeekCommits);
            System.assertNotEquals(null, d.lastWeekScorecard);
        }
    }

    @isTest
    static void testDashboard_emptyStateReturnsEmptyLists() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.targetAccounts.size());
            System.assertEquals(0, d.stage1Opps.size());
            System.assertEquals(0, d.thisWeekCommits.size());
        }
    }

    // ─── Target Accounts ─────────────────────────────────────────────────────

    @isTest
    static void testTargetAccounts_onlyReturnsTargetFlaggedAccounts() {
        User rep = makeRep(0);
        System.runAs(rep) {
            makeTargetAccount(rep.Id, 'Flagged');
            insert new Account(Name = 'Not Flagged', OwnerId = rep.Id, Target_Account__c = false);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.targetAccounts.size());
            System.assertEquals('Flagged', d.targetAccounts[0].name);
        }
    }

    @isTest
    static void testTargetAccounts_onlyReturnsRepOwnedAccounts() {
        User rep1 = makeRep(0);
        User rep2 = makeRep(0);
        System.runAs(rep1) {
            makeTargetAccount(rep1.Id, 'Rep1 Account');
        }
        System.runAs(rep2) {
            makeTargetAccount(rep2.Id, 'Rep2 Account');
        }
        System.runAs(rep1) {
            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.targetAccounts.size());
            System.assertEquals('Rep1 Account', d.targetAccounts[0].name);
        }
    }

    @isTest
    static void testTargetAccounts_contactCountPopulated() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Multi-Thread Co');
            insert new Contact(LastName = 'Smith', AccountId = a.Id);
            insert new Contact(LastName = 'Jones', AccountId = a.Id);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(2, d.targetAccounts[0].contactCount);
        }
    }

    // ─── Stage 1 Opps ────────────────────────────────────────────────────────

    @isTest
    static void testStage1Opps_onlyReturnsOpenStage1() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Test Co');
            makeOpp(rep.Id, a.Id, 'Open S1',    'Stage 1',    50000);
            makeOpp(rep.Id, a.Id, 'Stage 3',    'Stage 3',    50000);
            makeOpp(rep.Id, a.Id, 'Closed Won', 'Closed Won', 50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.stage1Opps.size());
            System.assertEquals('Open S1', d.stage1Opps[0].name);
        }
    }

    @isTest
    static void testStage1Opps_rowFieldsPopulated() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Acme');
            Opportunity o = makeOpp(rep.Id, a.Id, 'Acme Deal', 'Stage 1', 125000);

            Contact c = new Contact(LastName = 'Smith', AccountId = a.Id);
            insert c;
            insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id, Role = 'Economic Buyer');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            PipeGenController.OppRow row = d.stage1Opps[0];
            System.assertEquals(o.Id, row.id);
            System.assertEquals('Acme Deal', row.name);
            System.assertEquals(125000, row.amount);
            System.assertEquals('Acme', row.accountName);
            System.assertEquals(a.Id, row.accountId);
            System.assertEquals(1, row.contactRoleCount);
            System.assertNotEquals(null, row.isStale);
            System.assertNotEquals(null, row.daysInStage);
        }
    }

    @isTest
    static void testStage1Opps_freshOppIsNotStale() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Fresh Co');
            makeOpp(rep.Id, a.Id, 'Fresh Deal', 'Stage 1', 50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            // Just-created opp has 0 days in stage — not stale
            System.assertEquals(false, d.stage1Opps[0].isStale);
        }
    }

    // ─── Quarterly Target ────────────────────────────────────────────────────

    @isTest
    static void testQuarterlyTarget_splitsAnnualQuotaCorrectly() {
        User rep = makeRep(2000000); // $2M annual
        System.runAs(rep) {
            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            PipeGenController.QuarterlyTarget qt = d.quarterlyTarget;
            System.assertEquals(500000, qt.totalTarget,       '$2M / 4 = $500K quarterly');
            System.assertEquals(250000, qt.netNewTarget,      '50% of $500K');
            System.assertEquals(250000, qt.progressionTarget, '50% of $500K');
            System.assertNotEquals(null, qt.quarter);
            System.assert(qt.weeksRemaining >= 0);
        }
    }

    @isTest
    static void testQuarterlyTarget_zeroWhenNoQuotaSet() {
        User rep = makeRep(null); // no quota
        System.runAs(rep) {
            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.quarterlyTarget.totalTarget);
        }
    }

    @isTest
    static void testQuarterlyTarget_netNewActualSumsThisQuarterOpps() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'NetNew Co');
            makeOpp(rep.Id, a.Id, 'Opp A', 'Stage 1', 80000);
            makeOpp(rep.Id, a.Id, 'Opp B', 'Stage 2', 40000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(120000, d.quarterlyTarget.netNewActual);
        }
    }

    @isTest
    static void testQuarterlyTarget_netNewActualExcludesStage0() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Stage0 Co');
            makeOpp(rep.Id, a.Id, 'Stage 0 Opp', 'Stage 0', 100000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.quarterlyTarget.netNewActual, 'Stage 0 opps excluded');
        }
    }

    // ─── This Week's Commits ─────────────────────────────────────────────────

    @isTest
    static void testThisWeekCommits_onlyCurrentWeek() {
        User rep = makeRep(0);
        System.runAs(rep) {
            makeCommit(rep.Id, thisWeekStart(), 'Net New', 'Pending');
            makeCommit(rep.Id, lastWeekStart(), 'Net New', 'Completed');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.thisWeekCommits.size());
            System.assertEquals('Pending', d.thisWeekCommits[0].Completion_Status__c);
        }
    }

    @isTest
    static void testThisWeekCommits_bothMotionTypesReturned() {
        User rep = makeRep(0);
        System.runAs(rep) {
            makeCommit(rep.Id, thisWeekStart(), 'Net New',    'Pending');
            makeCommit(rep.Id, thisWeekStart(), 'Progression','Pending');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(2, d.thisWeekCommits.size());
        }
    }

    // ─── Scorecard ───────────────────────────────────────────────────────────

    @isTest
    static void testScorecard_aggregatesLastWeekNetNewCommits() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Date lw = lastWeekStart();
            makeCommit(rep.Id, lw, 'Net New', 'Completed');
            makeCommit(rep.Id, lw, 'Net New', 'Completed');
            makeCommit(rep.Id, lw, 'Net New', 'Missed');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(3, d.lastWeekScorecard.nnCommitsTotal);
            System.assertEquals(2, d.lastWeekScorecard.nnCommitsCompleted);
        }
    }

    @isTest
    static void testScorecard_progressionAdvancedVsStalled() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Scorecard Co');
            Opportunity advanced = makeOpp(rep.Id, a.Id, 'Advanced Opp', 'Stage 3', 50000);
            Opportunity stalled  = makeOpp(rep.Id, a.Id, 'Stalled Opp',  'Stage 1', 30000);

            Date lw = lastWeekStart();
            Weekly_Commit__c c1 = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = lw,
                Motion_Type__c = 'Progression', Commit_Type__c = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Advance deal', Committed_Count__c = 1,
                Completion_Status__c = 'Completed', Target_Opportunity__c = advanced.Id
            );
            Weekly_Commit__c c2 = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = lw,
                Motion_Type__c = 'Progression', Commit_Type__c = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Progress stalled deal', Committed_Count__c = 1,
                Completion_Status__c = 'Missed', Target_Opportunity__c = stalled.Id
            );
            insert new List<Weekly_Commit__c>{ c1, c2 };

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            PipeGenController.ScorecardData sc = d.lastWeekScorecard;
            System.assertEquals(2,  sc.progCommitsTotal);
            System.assertEquals(1,  sc.progCommitsCompleted);
            System.assertEquals(1,  sc.progOppsAdvanced, 'Opp is now Stage 3');
            System.assertEquals(1,  sc.progOppsStalled,  'Opp is still Stage 1');
            System.assertEquals(50, sc.progConversionRate, '1/2 = 50%');
        }
    }

    @isTest
    static void testScorecard_conversionRateZeroWithNoProgressionCommits() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.lastWeekScorecard.progConversionRate);
        }
    }

    @isTest
    static void testScorecard_ignoresCurrentWeekCommits() {
        User rep = makeRep(0);
        System.runAs(rep) {
            // Current week commit — should NOT appear in scorecard
            makeCommit(rep.Id, thisWeekStart(), 'Net New', 'Completed');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.lastWeekScorecard.nnCommitsTotal);
        }
    }

    // ─── saveCommit ──────────────────────────────────────────────────────────

    @isTest
    static void testSaveCommit_createsRecordAndSetsSystemFields() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Save Test Co');

            Weekly_Commit__c toSave = new Weekly_Commit__c(
                Motion_Type__c        = 'Net New',
                Commit_Type__c        = 'First Meeting Booked',
                Commit_Description__c = 'Book 3 first meetings',
                Committed_Count__c    = 3,
                Target_Account__c     = a.Id
            );

            Test.startTest();
            Weekly_Commit__c saved = PipeGenController.saveCommit(toSave);
            Test.stopTest();

            System.assertNotEquals(null, saved.Id);
            System.assertEquals(rep.Id,          saved.Rep__c);
            System.assertEquals(thisWeekStart(), saved.Week_Start_Date__c);
            System.assertEquals('Net New',        saved.Motion_Type__c);
            System.assertEquals(3,                saved.Committed_Count__c);
            // Re-queried lookup name should be present
            System.assertEquals('Save Test Co',   saved.Target_Account__r.Name);
        }
    }

    @isTest
    static void testSaveCommit_upsertUpdatesExistingRecord() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Weekly_Commit__c first = new Weekly_Commit__c(
                Motion_Type__c        = 'Net New',
                Commit_Type__c        = 'First Meeting Booked',
                Commit_Description__c = 'Original description',
                Committed_Count__c    = 1
            );
            Weekly_Commit__c saved = PipeGenController.saveCommit(first);

            saved.Commit_Description__c = 'Updated description';

            Test.startTest();
            Weekly_Commit__c updated = PipeGenController.saveCommit(saved);
            Test.stopTest();

            System.assertEquals('Updated description', updated.Commit_Description__c);
            System.assertEquals(1, [SELECT COUNT() FROM Weekly_Commit__c WHERE Rep__c = :rep.Id]);
        }
    }

    @isTest
    static void testSaveCommit_progressionLinksSaveOppLookup() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Prog Co');
            Opportunity o = makeOpp(rep.Id, a.Id, 'Prog Deal', 'Stage 1', 60000);

            Weekly_Commit__c toSave = new Weekly_Commit__c(
                Motion_Type__c        = 'Progression',
                Commit_Type__c        = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Close discovery loop',
                Committed_Count__c    = 1,
                Target_Opportunity__c = o.Id
            );

            Test.startTest();
            Weekly_Commit__c saved = PipeGenController.saveCommit(toSave);
            Test.stopTest();

            System.assertEquals(o.Id,       saved.Target_Opportunity__c);
            System.assertEquals('Prog Deal', saved.Target_Opportunity__r.Name);
        }
    }

    // ─── deleteCommit ─────────────────────────────────────────────────────────

    @isTest
    static void testDeleteCommit_removesRecord() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Weekly_Commit__c c = makeCommit(rep.Id, thisWeekStart(), 'Net New', 'Pending');

            Test.startTest();
            PipeGenController.deleteCommit(c.Id);
            Test.stopTest();

            System.assertEquals(0, [SELECT COUNT() FROM Weekly_Commit__c WHERE Id = :c.Id]);
        }
    }

    @isTest
    static void testDeleteCommit_doesNotAffectOtherCommits() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Weekly_Commit__c keep   = makeCommit(rep.Id, thisWeekStart(), 'Net New', 'Pending');
            Weekly_Commit__c remove = makeCommit(rep.Id, thisWeekStart(), 'Net New', 'Pending');

            Test.startTest();
            PipeGenController.deleteCommit(remove.Id);
            Test.stopTest();

            System.assertEquals(1, [SELECT COUNT() FROM Weekly_Commit__c WHERE Rep__c = :rep.Id]);
            System.assertEquals(keep.Id, [SELECT Id FROM Weekly_Commit__c WHERE Rep__c = :rep.Id].Id);
        }
    }

    // ─── getWeekStart (via @TestVisible) ─────────────────────────────────────

    @isTest
    static void testGetWeekStart_returnsMonday() {
        // April 22 2026 is a Wednesday — Monday of that week is April 20
        Date wednesday = Date.newInstance(2026, 4, 22);
        Date expected  = Date.newInstance(2026, 4, 20);
        System.assertEquals(expected, PipeGenController.getWeekStart(wednesday));
    }

    @isTest
    static void testGetWeekStart_mondayReturnsSelf() {
        Date monday = Date.newInstance(2026, 4, 20);
        System.assertEquals(monday, PipeGenController.getWeekStart(monday));
    }

    @isTest
    static void testGetWeekStart_sundayReturnsPreviousMonday() {
        Date sunday   = Date.newInstance(2026, 4, 26);
        Date expected = Date.newInstance(2026, 4, 20);
        System.assertEquals(expected, PipeGenController.getWeekStart(sunday));
    }
}
