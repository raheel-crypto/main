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
            makeOpp(rep.Id, a.Id, 'Acme Deal', '1 - Demo', 75000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertNotEquals(null, d.quarterlyTarget);
            System.assertNotEquals(null, d.targetAccounts);
            System.assertNotEquals(null, d.inFlightOpps);
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
            System.assertEquals(0, d.inFlightOpps.size());
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
            makeOpp(rep.Id, a.Id, 'Open S1',    '1 - Demo',   50000);
            makeOpp(rep.Id, a.Id, 'Stage 3',    '3 - POV',    50000);
            makeOpp(rep.Id, a.Id, 'Closed Won', 'Closed Won', 50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.inFlightOpps.size());
            System.assertEquals('Open S1', d.inFlightOpps[0].name);
        }
    }

    @isTest
    static void testStage1Opps_rowFieldsPopulated() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Acme');
            Opportunity o = makeOpp(rep.Id, a.Id, 'Acme Deal', '1 - Demo', 125000);

            Contact c = new Contact(LastName = 'Smith', AccountId = a.Id);
            insert c;
            insert new OpportunityContactRole(OpportunityId = o.Id, ContactId = c.Id, Role = 'Economic Buyer');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            PipeGenController.OppRow row = d.inFlightOpps[0];
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
            makeOpp(rep.Id, a.Id, 'Fresh Deal', '1 - Demo', 50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            // Just-created opp has 0 days in stage — not stale
            System.assertEquals(false, d.inFlightOpps[0].isStale);
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
            System.assertEquals(500000, qt.pipelineTarget, '$2M / 4 = $500K quarterly pipeline target');
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

            System.assertEquals(0, d.quarterlyTarget.pipelineTarget);
        }
    }

    @isTest
    static void testQuarterlyTarget_netNewActualSumsThisQuarterOpps() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'NetNew Co');
            makeOpp(rep.Id, a.Id, 'Opp A', '2 - Discovery', 80000);
            makeOpp(rep.Id, a.Id, 'Opp B', '2 - Discovery', 40000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(120000, d.quarterlyTarget.pipelineActual, '2-Discovery opps count toward pipeline');
        }
    }

    @isTest
    static void testQuarterlyTarget_netNewActualExcludesStage0() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Stage0 Co');
            makeOpp(rep.Id, a.Id, 'Demo Opp', '1 - Demo', 100000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(0, d.quarterlyTarget.pipelineActual, '1-Demo opps excluded from pipeline actual');
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
            // Create both opps initially in Stage 1 so we can simulate advancement after the week
            Opportunity advanced = makeOpp(rep.Id, a.Id, 'Advanced Opp', '1 - Demo', 50000);
            Opportunity stalled  = makeOpp(rep.Id, a.Id, 'Stalled Opp',  '1 - Demo', 30000);

            Date lw = lastWeekStart();
            Weekly_Commit__c c1 = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = lw,
                Motion_Type__c = 'Progression', Commit_Type__c = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Advance deal', Committed_Count__c = 1,
                Target_Opportunity__c = advanced.Id
            );
            Weekly_Commit__c c2 = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = lw,
                Motion_Type__c = 'Progression', Commit_Type__c = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Progress stalled deal', Committed_Count__c = 1,
                Target_Opportunity__c = stalled.Id
            );
            insert new List<Weekly_Commit__c>{ c1, c2 };

            // Provide a Nektar Discovery event on advanced — drives auto-verification to Completed for c1
            insert new Event(
                OwnerId         = rep.Id,
                WhatId          = advanced.Id,
                Subject         = 'Discovery Meeting',
                StartDateTime   = DateTime.newInstance(lw, Time.newInstance(9, 0, 0, 0)),
                EndDateTime     = DateTime.newInstance(lw, Time.newInstance(10, 0, 0, 0)),
                Meeting_Type__c = 'Discovery'
            );

            // Simulate the advanced opportunity moving to Stage 3 after the progression commit
            advanced.StageName = '3 - POV';
            update advanced;

            // Sanity checks to make debugging failing assertions easier
            Opportunity advancedRef = [SELECT Id, StageName FROM Opportunity WHERE Id = :advanced.Id];
            System.assertEquals('3 - POV', advancedRef.StageName, 'Advanced opp should be 3 - POV at scoring time');
            List<Weekly_Commit__c> lwCommits = [SELECT Id, Rep__c, Week_Start_Date__c, Motion_Type__c, Target_Opportunity__c, Completion_Status__c
                                                FROM Weekly_Commit__c WHERE Rep__c = :rep.Id AND Week_Start_Date__c = :lw];
            System.assertEquals(2, lwCommits.size(), 'Two last-week commits should exist');
            Set<Id> foundOppIds = new Set<Id>();
            for (Weekly_Commit__c cc : lwCommits) if (cc.Target_Opportunity__c != null) foundOppIds.add(cc.Target_Opportunity__c);
            System.assert(foundOppIds.contains(advanced.Id), 'Advanced opp should be referenced by a last-week commit');
            System.assert(foundOppIds.contains(stalled.Id), 'Stalled opp should be referenced by a last-week commit');

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            // Extra diagnostics: re-query to ensure controller saw the same opportunity stages
            PipeGenController.ScorecardData sc = d.lastWeekScorecard;
            Opportunity advCheck = [SELECT Id, StageName FROM Opportunity WHERE Id = :advanced.Id];
            Opportunity stlCheck = [SELECT Id, StageName FROM Opportunity WHERE Id = :stalled.Id];
            System.assertEquals('3 - POV',  advCheck.StageName, 'Advanced opp in DB should be 3 - POV');
            System.assertEquals('1 - Demo', stlCheck.StageName, 'Stalled opp in DB should be 1 - Demo');

            List<Weekly_Commit__c> postCommits = [SELECT Id, Motion_Type__c, Target_Opportunity__c, Completion_Status__c
                                                  FROM Weekly_Commit__c
                                                  WHERE Rep__c = :rep.Id AND Week_Start_Date__c = :lw];
            Integer progCount = 0;
            Set<Id> referencedOpps = new Set<Id>();
            for (Weekly_Commit__c wc : postCommits) {
                if (wc.Motion_Type__c == 'Progression') {
                    progCount++;
                    if (wc.Target_Opportunity__c != null) referencedOpps.add(wc.Target_Opportunity__c);
                }
            }
            System.assertEquals(2, progCount, 'There should be two progression commits in DB');
            System.assert(referencedOpps.contains(advanced.Id) && referencedOpps.contains(stalled.Id),
                'Both progression commits should reference the two opps');

            System.assertEquals(2,  sc.progCommitsTotal);
            System.assertEquals(1,  sc.progCommitsCompleted);
            // Ensure both progression commits referenced opportunities were counted (advanced or stalled)
            System.assertEquals(2, sc.progOppsAdvanced + sc.progOppsStalled, 'Both progression-targeted opps should be counted');
            System.assertEquals(50, sc.progConversionRate, 'Conversion rate should be advanced/total * 100');
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
            Opportunity o = makeOpp(rep.Id, a.Id, 'Prog Deal', '1 - Demo', 60000);

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

    // ─── In-Flight Opps — Stage 2 ────────────────────────────────────────────

    @isTest
    static void testInFlightOpps_includesStage2() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Two-Stage Co');
            makeOpp(rep.Id, a.Id, 'Stage 1 Deal', '1 - Demo',      40000);
            makeOpp(rep.Id, a.Id, 'Stage 2 Deal', '2 - Discovery', 60000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(2, d.inFlightOpps.size(), 'Both Stage 1 and Stage 2 opps should appear');
            Set<String> stages = new Set<String>();
            for (PipeGenController.OppRow row : d.inFlightOpps) stages.add(row.stageName);
            System.assert(stages.contains('1 - Demo'));
            System.assert(stages.contains('2 - Discovery'));
        }
    }

    @isTest
    static void testInFlightOpps_staleThresholdDiffersByStage() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Threshold Co');
            makeOpp(rep.Id, a.Id, 'S1 Opp', '1 - Demo',      50000);
            makeOpp(rep.Id, a.Id, 'S2 Opp', '2 - Discovery', 50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Map<String, Integer> thresholds = new Map<String, Integer>();
            for (PipeGenController.OppRow row : d.inFlightOpps) thresholds.put(row.stageName, row.staleThreshold);
            System.assertEquals(21, thresholds.get('1 - Demo'),      '1-Demo threshold = 21 days');
            System.assertEquals(14, thresholds.get('2 - Discovery'), '2-Discovery threshold = 14 days');
        }
    }

    @isTest
    static void testInFlightOpps_excludesStage3AndClosed() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Filter Co');
            makeOpp(rep.Id, a.Id, 'S1',         '1 - Demo',      50000);
            makeOpp(rep.Id, a.Id, 'S2',         '2 - Discovery', 50000);
            makeOpp(rep.Id, a.Id, 'S3',         '3 - POV',       50000);
            makeOpp(rep.Id, a.Id, 'Closed Won', 'Closed Won',    50000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(3, d.inFlightOpps.size(), 'S1, S2, S3 are all in-flight; Closed Won excluded');
        }
    }

    @isTest
    static void testInFlightOpps_stageNamePopulatedOnRow() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Stage Name Co');
            makeOpp(rep.Id, a.Id, 'My Deal', '2 - Discovery', 75000);

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals('2 - Discovery', d.inFlightOpps[0].stageName);
        }
    }

    // ─── Account Selection ───────────────────────────────────────────────────

    @isTest
    static void testGetAccountsForSelection_returnsAllOwnerAccounts() {
        User rep = makeRep(0);
        System.runAs(rep) {
            makeTargetAccount(rep.Id, 'Targeted');
            insert new Account(Name = 'Not Targeted', OwnerId = rep.Id, Target_Account__c = false);

            Test.startTest();
            List<PipeGenController.AccountCard> cards = PipeGenController.getAccountsForSelection();
            Test.stopTest();

            System.assertEquals(2, cards.size(), 'Should return all accounts regardless of target flag');
        }
    }

    @isTest
    static void testGetAccountsForSelection_targetedFirstInOrder() {
        User rep = makeRep(0);
        System.runAs(rep) {
            insert new Account(Name = 'Z Not Targeted', OwnerId = rep.Id, Target_Account__c = false);
            makeTargetAccount(rep.Id, 'A Targeted');

            Test.startTest();
            List<PipeGenController.AccountCard> cards = PipeGenController.getAccountsForSelection();
            Test.stopTest();

            System.assertEquals(true,  cards[0].isTargeted, 'Targeted accounts should sort first');
            System.assertEquals(false, cards[1].isTargeted);
        }
    }

    @isTest
    static void testGetAccountsForSelection_countsPopulated() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Counted Co');
            insert new Contact(LastName = 'Smith', AccountId = a.Id);
            insert new Contact(LastName = 'Jones', AccountId = a.Id);
            makeOpp(rep.Id, a.Id, 'Open Opp', '1 - Demo', 50000);

            Test.startTest();
            List<PipeGenController.AccountCard> cards = PipeGenController.getAccountsForSelection();
            Test.stopTest();

            System.assertEquals(2, cards[0].contactCount);
            System.assertEquals(1, cards[0].openOppCount);
        }
    }

    @isTest
    static void testGetAccountsForSelection_isTargetedFlagCorrect() {
        User rep = makeRep(0);
        System.runAs(rep) {
            makeTargetAccount(rep.Id, 'Is Targeted');
            insert new Account(Name = 'Not Targeted', OwnerId = rep.Id, Target_Account__c = false);

            Test.startTest();
            List<PipeGenController.AccountCard> cards = PipeGenController.getAccountsForSelection();
            Test.stopTest();

            Map<String, Boolean> flags = new Map<String, Boolean>();
            for (PipeGenController.AccountCard c : cards) flags.put(c.name, c.isTargeted);
            System.assertEquals(true,  flags.get('Is Targeted'));
            System.assertEquals(false, flags.get('Not Targeted'));
        }
    }

    // ─── updateTargetAccounts ────────────────────────────────────────────────

    @isTest
    static void testUpdateTargetAccounts_setsTargetTrue() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = new Account(Name = 'To Target', OwnerId = rep.Id, Target_Account__c = false);
            insert a;

            Test.startTest();
            PipeGenController.updateTargetAccounts(new List<Id>{ a.Id }, new List<Id>());
            Test.stopTest();

            System.assertEquals(true, [SELECT Target_Account__c FROM Account WHERE Id = :a.Id].Target_Account__c);
        }
    }

    @isTest
    static void testUpdateTargetAccounts_setsTargetFalse() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'To Untarget');

            Test.startTest();
            PipeGenController.updateTargetAccounts(new List<Id>(), new List<Id>{ a.Id });
            Test.stopTest();

            System.assertEquals(false, [SELECT Target_Account__c FROM Account WHERE Id = :a.Id].Target_Account__c);
        }
    }

    @isTest
    static void testUpdateTargetAccounts_handlesBothListsSimultaneously() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account toOn  = new Account(Name = 'Turn On',  OwnerId = rep.Id, Target_Account__c = false);
            Account toOff = new Account(Name = 'Turn Off', OwnerId = rep.Id, Target_Account__c = true);
            insert new List<Account>{ toOn, toOff };

            Test.startTest();
            PipeGenController.updateTargetAccounts(new List<Id>{ toOn.Id }, new List<Id>{ toOff.Id });
            Test.stopTest();

            System.assertEquals(true,  [SELECT Target_Account__c FROM Account WHERE Id = :toOn.Id].Target_Account__c);
            System.assertEquals(false, [SELECT Target_Account__c FROM Account WHERE Id = :toOff.Id].Target_Account__c);
        }
    }

    @isTest
    static void testUpdateTargetAccounts_nullListsDoNothing() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Test.startTest();
            PipeGenController.updateTargetAccounts(null, null);
            Test.stopTest();
        }
    }

    // ─── markCommitComplete ──────────────────────────────────────────────────

    @isTest
    static void testMarkCommitComplete_setsActualAndStatus() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Progression', Commit_Type__c = 'MEDDPICC Complete',
                Commit_Description__c = 'Complete MEDDPICC', Committed_Count__c = 2,
                Completion_Status__c = 'Not Started'
            );
            insert c;

            Test.startTest();
            PipeGenController.markCommitComplete(c.Id);
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Actual_Count__c, Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals(2,           updated.Actual_Count__c,     'Actual should equal Committed_Count__c');
            System.assertEquals('Completed', updated.Completion_Status__c, 'Status should be Completed');
        }
    }

    // ─── verifyAndPersistCommits — Net New event matching ────────────────────

    @isTest
    static void testVerifyCommits_netNewEventMatchCompletesCommit() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'First Meeting Co');
            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Book first meeting', Committed_Count__c = 1,
                Target_Account__c = a.Id, Completion_Status__c = 'Not Started'
            );
            insert c;

            insert new Event(
                OwnerId = rep.Id, WhatId = a.Id, Subject = 'First Meeting',
                StartDateTime = DateTime.now(), EndDateTime = DateTime.now().addHours(1),
                Meeting_Type__c = 'First Meeting'
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Actual_Count__c, Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals('Completed', updated.Completion_Status__c, 'Matching event should complete the commit');
            System.assertEquals(1,           updated.Actual_Count__c);
        }
    }

    @isTest
    static void testVerifyCommits_partialMatchWhenCountBelowCommitted() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Partial Co');
            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Book two meetings', Committed_Count__c = 2,
                Target_Account__c = a.Id, Completion_Status__c = 'Not Started'
            );
            insert c;

            // Only one event — should be Partial, not Completed
            insert new Event(
                OwnerId = rep.Id, WhatId = a.Id, Subject = 'First Meeting',
                StartDateTime = DateTime.now(), EndDateTime = DateTime.now().addHours(1),
                Meeting_Type__c = 'First Meeting'
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Actual_Count__c, Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals('Partial', updated.Completion_Status__c, 'One event against committed=2 should be Partial');
            System.assertEquals(1,         updated.Actual_Count__c);
        }
    }

    // ─── verifyAndPersistCommits — Progression event matching ────────────────

    @isTest
    static void testVerifyCommits_progressionEventMatchCompletesCommit() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Prog Event Co');
            Opportunity o = makeOpp(rep.Id, a.Id, 'Prog Deal', '1 - Demo', 50000);
            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Progression', Commit_Type__c = 'Discovery Call - Economic Buyer',
                Commit_Description__c = 'Run discovery', Committed_Count__c = 1,
                Target_Opportunity__c = o.Id, Completion_Status__c = 'Not Started'
            );
            insert c;

            insert new Event(
                OwnerId = rep.Id, WhatId = o.Id, Subject = 'Discovery Call',
                StartDateTime = DateTime.now(), EndDateTime = DateTime.now().addHours(1),
                Meeting_Type__c = 'Discovery'
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Actual_Count__c, Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals('Completed', updated.Completion_Status__c, 'Discovery event on opp should complete progression commit');
            System.assertEquals(1,           updated.Actual_Count__c);
        }
    }

    // ─── verifyAndPersistCommits — Exec Outreach task + DM title ─────────────

    @isTest
    static void testVerifyCommits_execOutreachDmTitleCompletes() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Exec Co');
            Contact dm = new Contact(LastName = 'Smith', AccountId = a.Id, Title = 'Managing Director');
            insert dm;

            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Net New', Commit_Type__c = 'Exec Outreach Sequence',
                Commit_Description__c = 'Reach MD', Committed_Count__c = 1,
                Target_Account__c = a.Id, Completion_Status__c = 'Not Started'
            );
            insert c;

            insert new Task(
                OwnerId = rep.Id, WhatId = a.Id, WhoId = dm.Id,
                Subject = 'Email to MD', ActivityDate = Date.today(), Status = 'Completed'
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Actual_Count__c, Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals('Completed', updated.Completion_Status__c, 'Task to DM-title contact should complete exec outreach');
            System.assertEquals(1,           updated.Actual_Count__c);
        }
    }

    @isTest
    static void testVerifyCommits_execOutreachNonDmTitleNoMatch() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Non-DM Co');
            Contact nonDm = new Contact(LastName = 'Jones', AccountId = a.Id, Title = 'Sales Development Rep');
            insert nonDm;

            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Net New', Commit_Type__c = 'Exec Outreach Sequence',
                Commit_Description__c = 'Reach exec', Committed_Count__c = 1,
                Target_Account__c = a.Id, Completion_Status__c = 'Not Started'
            );
            insert c;

            insert new Task(
                OwnerId = rep.Id, WhatId = a.Id, WhoId = nonDm.Id,
                Subject = 'Email to SDR', ActivityDate = Date.today(), Status = 'Completed'
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertNotEquals('Completed', updated.Completion_Status__c, 'Non-DM title should not verify exec outreach');
        }
    }

    // ─── verifyAndPersistCommits — MEDDPICC manual path ──────────────────────

    @isTest
    static void testVerifyCommits_meddpiccActualCountDrivesStatus() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Weekly_Commit__c c = new Weekly_Commit__c(
                Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
                Motion_Type__c = 'Progression', Commit_Type__c = 'MEDDPICC Complete',
                Commit_Description__c = 'MEDDPICC fields', Committed_Count__c = 1,
                Actual_Count__c = 1, Completion_Status__c = 'Not Started'
            );
            insert c;

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            Weekly_Commit__c updated = [SELECT Completion_Status__c FROM Weekly_Commit__c WHERE Id = :c.Id];
            System.assertEquals('Completed', updated.Completion_Status__c, 'Actual >= Committed should auto-complete MEDDPICC via verify');
        }
    }

    // ─── buildTargetAccounts — Event-based activity date ─────────────────────

    @isTest
    static void testTargetAccounts_lastActivityDatePopulatedFromEvent() {
        User rep = makeRep(0);
        System.runAs(rep) {
            Account a = makeTargetAccount(rep.Id, 'Activity Co');

            insert new Event(
                OwnerId = rep.Id, WhatId = a.Id, Subject = 'Account Review',
                StartDateTime = DateTime.now(), EndDateTime = DateTime.now().addHours(1)
            );

            Test.startTest();
            PipeGenController.DashboardData d = PipeGenController.getRepDashboardData();
            Test.stopTest();

            System.assertEquals(1, d.targetAccounts.size());
            System.assertNotEquals(null, d.targetAccounts[0].lastActivityDate,    'Event should populate lastActivityDate');
            System.assertNotEquals(null, d.targetAccounts[0].lastActivitySubject, 'Event subject should populate lastActivitySubject');
        }
    }

    private static Integer repCounter = 0;

    private static User makeRepUnder(Id managerId) {
        repCounter++;
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName             = 'Rep',
            LastName              = 'User' + repCounter,
            Email                 = 'mgrrep' + repCounter + '@test.example.com',
            Username              = 'mgrrep' + repCounter + System.currentTimeMillis() + '@test.example.com',
            Alias                 = 'mr' + repCounter,
            TimeZoneSidKey        = 'America/New_York',
            LocaleSidKey          = 'en_US',
            EmailEncodingKey      = 'UTF-8',
            LanguageLocaleKey     = 'en_US',
            ProfileId             = p.Id,
            ManagerId             = managerId,
            Pipe_Gen_Annual_Target__c = 0
        );
        insert u;
        return u;
    }

    // ─── getManagerTeamData ───────────────────────────────────────────────────

    @isTest
    static void testManagerDashboard_emptyWhenNoDirectReports() {
        User mgr = makeRep(0);
        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            System.assertEquals(0, d.reps.size(),            'No direct reports — reps list should be empty');
            System.assertEquals(0, d.teamSummary.totalReps,  'No direct reports — totalReps should be 0');
        }
    }

    @isTest
    static void testManagerDashboard_returnsOnlyDirectReports() {
        User mgr  = makeRep(0);
        User rep1 = makeRepUnder(mgr.Id);
        makeRep(0); // unrelated user — should not appear

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            System.assertEquals(1, d.reps.size(), 'Only direct reports should appear');
            System.assertEquals(rep1.Id, d.reps[0].repId, 'Direct report Id should match');
            System.assertEquals(1, d.teamSummary.totalReps);
        }
    }

    @isTest
    static void testManagerDashboard_teamSummaryAggregates() {
        User mgr  = makeRep(0);
        User rep1 = makeRepUnder(mgr.Id);
        User rep2 = makeRepUnder(mgr.Id);

        Date tw = thisWeekStart();
        insert new List<Weekly_Commit__c>{
            new Weekly_Commit__c(Rep__c = rep1.Id, Week_Start_Date__c = tw,
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Done commit', Committed_Count__c = 1,
                Completion_Status__c = 'Completed'),
            new Weekly_Commit__c(Rep__c = rep1.Id, Week_Start_Date__c = tw,
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Open commit', Committed_Count__c = 1,
                Completion_Status__c = 'Not Started')
        };
        // rep2 has no commits this week

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            System.assertEquals(2, d.teamSummary.totalReps);
            System.assertEquals(2, d.teamSummary.totalCommits,     'Two commits across team');
            System.assertEquals(1, d.teamSummary.completedCommits,  'One completed commit');
            System.assertEquals(1, d.teamSummary.repsWithNoCommits, 'rep2 has no commits');
        }
    }

    @isTest
    static void testManagerDashboard_riskReasonNoCommits() {
        User mgr = makeRep(0);
        makeRepUnder(mgr.Id); // no commits this week

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            PipeGenController.RepSummary rs = d.reps[0];
            System.assertEquals(true, rs.hasRisk, 'Rep with no commits should be at risk');
            System.assert(rs.riskReasons[0].containsIgnoreCase('no commits'),
                'Risk reason should mention no commits — got: ' + rs.riskReasons[0]);
        }
    }

    @isTest
    static void testManagerDashboard_riskReasonInFlightNoProgression() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        Account a = new Account(Name = 'Risk Co', OwnerId = rep.Id);
        insert a;
        insert new Opportunity(Name = 'In-Flight', OwnerId = rep.Id, AccountId = a.Id,
            StageName = '1 - Demo', CloseDate = Date.today().addDays(30), Amount = 50000);

        // Net New commit only — no Progression
        insert new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'NN commit', Committed_Count__c = 1,
            Completion_Status__c = 'Not Started');

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            PipeGenController.RepSummary rs = d.reps[0];
            System.assertEquals(1, rs.inFlightOppCount, 'In-flight opp count should be 1');
            System.assertEquals(true, rs.hasRisk);
            Boolean hasInFlightReason = false;
            for (String r : rs.riskReasons)
                if (r.containsIgnoreCase('in-flight')) hasInFlightReason = true;
            System.assert(hasInFlightReason, 'Risk reasons should mention in-flight — got: ' + rs.riskReasons);
        }
    }

    @isTest
    static void testManagerDashboard_noRiskWhenCommitsCompleted() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        insert new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Done', Committed_Count__c = 1,
            Completion_Status__c = 'Completed');

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            System.assertEquals(false, d.reps[0].hasRisk,
                'Rep with completed commit and no in-flight opps should not be at risk');
        }
    }

    @isTest
    static void testManagerDashboard_atRiskCommitCountedInSummary() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        insert new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Flagged', Committed_Count__c = 1,
            Completion_Status__c = 'Not Started', At_Risk__c = true);

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            System.assertEquals(1, d.teamSummary.atRiskCommitCount,
                'At-risk commit should be reflected in team summary');
        }
    }

    @isTest
    static void testManagerDashboard_pipelineAttainment() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);
        // Give rep a $400K annual target → $100K quarterly
        update new User(Id = rep.Id, Pipe_Gen_Annual_Target__c = 400000);

        Account a = new Account(Name = 'Attain Co', OwnerId = rep.Id);
        insert a;
        // Opp created now (this quarter) in a pipeline stage — should count toward pipelineActual
        insert new Opportunity(Name = 'Disco Opp', OwnerId = rep.Id, AccountId = a.Id,
            StageName = '2 - Discovery', CloseDate = Date.today().addDays(30), Amount = 60000);

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            PipeGenController.RepSummary rs = d.reps[0];
            System.assertEquals(100000, rs.pipelineTarget, '$400K annual / 4 = $100K quarterly target');
            System.assertEquals(60000,  rs.pipelineActual, 'Discovery opp amount counts toward pipeline actual');
            System.assert(rs.weeksRemaining >= 0, 'Weeks remaining should be non-negative');
            System.assertNotEquals(null, rs.quarter, 'Quarter label should be populated (e.g. Q2 2026)');
        }
    }

    @isTest
    static void testManagerDashboard_qtdOppsCreated() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        Account a = new Account(Name = 'Created Co', OwnerId = rep.Id);
        insert a;
        // Two opps inserted now — CreatedDate = today, which is within QTD range
        insert new List<Opportunity>{
            new Opportunity(Name = 'Opp A', OwnerId = rep.Id, AccountId = a.Id,
                StageName = '1 - Demo', CloseDate = Date.today().addDays(30), Amount = 10000),
            new Opportunity(Name = 'Opp B', OwnerId = rep.Id, AccountId = a.Id,
                StageName = '2 - Discovery', CloseDate = Date.today().addDays(30), Amount = 20000)
        };

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            PipeGenController.RepSummary rs = d.reps[0];
            System.assertEquals(2, rs.qtdOppsCreated,
                'Two opps created this quarter (today) should be counted for QTD');
            System.assertEquals(0, rs.lwOppsCreated,
                'No opps created last week — all inserted today');
        }
    }

    @isTest
    static void testManagerDashboard_oppMetricFieldsNonNull() {
        User mgr = makeRep(0);
        makeRepUnder(mgr.Id);

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.ManagerDashboardData d = PipeGenController.getManagerTeamData();
            Test.stopTest();

            PipeGenController.RepSummary rs = d.reps[0];
            System.assertNotEquals(null, rs.lwOppsCreated,      'lwOppsCreated should not be null');
            System.assertNotEquals(null, rs.qtdOppsCreated,     'qtdOppsCreated should not be null');
            System.assertNotEquals(null, rs.lwOppsToDiscovery,  'lwOppsToDiscovery should not be null');
            System.assertNotEquals(null, rs.qtdOppsToDiscovery, 'qtdOppsToDiscovery should not be null');
            System.assert(rs.lwOppsCreated      >= 0);
            System.assert(rs.qtdOppsCreated     >= 0);
            System.assert(rs.lwOppsToDiscovery  >= 0);
            System.assert(rs.qtdOppsToDiscovery >= 0);
        }
    }

    // ─── getVPDashboardData ───────────────────────────────────────────────────

    @isTest
    static void testVPDashboard_managerModeWhenNoManagersBelow() {
        // Caller's direct reports are reps (not managers) → isVP = false
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        insert new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Commit', Committed_Count__c = 1,
            Completion_Status__c = 'Not Started');

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.VPDashboardData d = PipeGenController.getVPDashboardData();
            Test.stopTest();

            System.assertEquals(false, d.isVP,         'No managers below — should be manager mode');
            System.assertEquals(1,     d.reps.size(),  'Manager mode should return direct rep list');
            System.assertEquals(0,     d.managers.size(), 'Manager mode — managers list should be empty');
            System.assertEquals(rep.Id, d.reps[0].repId, 'Direct report Id should match');
        }
    }

    @isTest
    static void testVPDashboard_vpModeWhenManagersBelow() {
        // Three-tier hierarchy: vp → mgr → rep
        User vp  = makeRep(0);
        User mgr = makeRepUnder(vp.Id);
        User rep = makeRepUnder(mgr.Id);

        insert new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'VP-visible commit', Committed_Count__c = 1,
            Completion_Status__c = 'Completed');

        System.runAs(vp) {
            Test.startTest();
            PipeGenController.VPDashboardData d = PipeGenController.getVPDashboardData();
            Test.stopTest();

            System.assertEquals(true,  d.isVP,            'Direct reports are managers — should be VP mode');
            System.assertEquals(1,     d.managers.size(), 'One manager under the VP');
            System.assertEquals(0,     d.reps.size(),     'VP mode — flat reps list should be empty');

            PipeGenController.ManagerSummary ms = d.managers[0];
            System.assertEquals(mgr.Id, ms.managerId, 'Manager Id should match');
            System.assertEquals(1,      ms.totalReps, 'Manager has one rep');
            System.assertEquals(1,      ms.reps.size(), 'Nested reps list should contain the rep');
            System.assertEquals(rep.Id, ms.reps[0].repId, 'Nested rep Id should match');
        }
    }

    @isTest
    static void testVPDashboard_vpModeTeamSummaryAggregates() {
        // Two managers, each with one rep
        User vp   = makeRep(0);
        User mgr1 = makeRepUnder(vp.Id);
        User mgr2 = makeRepUnder(vp.Id);
        User rep1 = makeRepUnder(mgr1.Id);
        User rep2 = makeRepUnder(mgr2.Id);

        Date tw = thisWeekStart();
        insert new List<Weekly_Commit__c>{
            new Weekly_Commit__c(Rep__c = rep1.Id, Week_Start_Date__c = tw,
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Rep1 done', Committed_Count__c = 1,
                Completion_Status__c = 'Completed'),
            new Weekly_Commit__c(Rep__c = rep2.Id, Week_Start_Date__c = tw,
                Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
                Commit_Description__c = 'Rep2 open', Committed_Count__c = 1,
                Completion_Status__c = 'Not Started')
        };

        System.runAs(vp) {
            Test.startTest();
            PipeGenController.VPDashboardData d = PipeGenController.getVPDashboardData();
            Test.stopTest();

            System.assertEquals(2,  d.managers.size(),            'Two managers under VP');
            System.assertEquals(2,  d.teamSummary.totalReps,      'Two reps total across both managers');
            System.assertEquals(2,  d.teamSummary.totalCommits,   'Two commits total');
            System.assertEquals(1,  d.teamSummary.completedCommits, 'One completed commit');
        }
    }

    @isTest
    static void testVPDashboard_vpModeManagerRiskRollup() {
        // Manager should show hasRisk = true if any nested rep is at risk
        User vp  = makeRep(0);
        User mgr = makeRepUnder(vp.Id);
        makeRepUnder(mgr.Id); // rep with no commits → at risk

        System.runAs(vp) {
            Test.startTest();
            PipeGenController.VPDashboardData d = PipeGenController.getVPDashboardData();
            Test.stopTest();

            System.assertEquals(true, d.managers[0].hasRisk,    'Manager should surface risk when rep is at risk');
            System.assertEquals(1,    d.managers[0].repsAtRisk, 'One rep at risk under this manager');
        }
    }

    @isTest
    static void testVPDashboard_emptyWhenNoDirectReports() {
        User vp = makeRep(0); // no one reports to this user

        System.runAs(vp) {
            Test.startTest();
            PipeGenController.VPDashboardData d = PipeGenController.getVPDashboardData();
            Test.stopTest();

            System.assertEquals(false, d.isVP,          'No direct reports — not a VP');
            System.assertEquals(0,     d.reps.size(),   'No reps');
            System.assertEquals(0,     d.managers.size(), 'No managers');
        }
    }

    // ─── saveManagerNote ──────────────────────────────────────────────────────

    @isTest
    static void testSaveManagerNote_persistsNote() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        Weekly_Commit__c c = new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Commit', Committed_Count__c = 1);
        insert c;

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.saveManagerNote(c.Id, 'Work on discovery questioning.');
            Test.stopTest();
        }

        System.assertEquals('Work on discovery questioning.',
            [SELECT Manager_Note__c FROM Weekly_Commit__c WHERE Id = :c.Id].Manager_Note__c);
    }

    // ─── setAtRiskFlag ────────────────────────────────────────────────────────

    @isTest
    static void testSetAtRiskFlag_setsTrue() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        Weekly_Commit__c c = new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Commit', Committed_Count__c = 1, At_Risk__c = false);
        insert c;

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.setAtRiskFlag(c.Id, true);
            Test.stopTest();
        }

        System.assertEquals(true, [SELECT At_Risk__c FROM Weekly_Commit__c WHERE Id = :c.Id].At_Risk__c,
            'At_Risk__c should be true after flag');
    }

    @isTest
    static void testSetAtRiskFlag_setsFalse() {
        User mgr = makeRep(0);
        User rep = makeRepUnder(mgr.Id);

        Weekly_Commit__c c = new Weekly_Commit__c(Rep__c = rep.Id, Week_Start_Date__c = thisWeekStart(),
            Motion_Type__c = 'Net New', Commit_Type__c = 'First Meeting Booked',
            Commit_Description__c = 'Commit', Committed_Count__c = 1, At_Risk__c = true);
        insert c;

        System.runAs(mgr) {
            Test.startTest();
            PipeGenController.setAtRiskFlag(c.Id, false);
            Test.stopTest();
        }

        System.assertEquals(false, [SELECT At_Risk__c FROM Weekly_Commit__c WHERE Id = :c.Id].At_Risk__c,
            'At_Risk__c should be false after unflag');
    }
}
