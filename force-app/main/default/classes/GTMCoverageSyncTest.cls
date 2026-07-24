@IsTest
private class GTMCoverageSyncTest {

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private static User makeUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName            = 'Test',
            LastName             = 'SyncUser',
            Email                = 'gtmsynctestuser@example.com',
            Username             = 'gtmsynctestuser' + DateTime.now().getTime() + '@example.com',
            Alias                = 'sync',
            TimeZoneSidKey       = 'America/Los_Angeles',
            LocaleSidKey         = 'en_US',
            EmailEncodingKey     = 'UTF-8',
            LanguageLocaleKey    = 'en_US',
            ProfileId            = p.Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) { insert u; }
        return u;
    }

    private static Account makeAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    // ─── Tests ───────────────────────────────────────────────────────────────────

    @IsTest
    static void syncActivate_createsNewRecords() {
        User rep = makeUser();
        Account a1 = makeAccount('SyncAcct1');
        Account a2 = makeAccount('SyncAcct2');

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(
                new List<Id>{ a1.Id, a2.Id },
                new List<Id>(),
                rep.Id,
                'GTMA1 Target'
            );
            Test.stopTest();
        }

        List<GTM_Coverage__c> recs = [
            SELECT Account__c, Is_Active__c, Date_Added__c, Coverage_Type__c
            FROM GTM_Coverage__c
            WHERE Rep__c = :rep.Id
        ];
        System.assertEquals(2, recs.size(), 'Should create 2 coverage records');
        for (GTM_Coverage__c r : recs) {
            System.assertEquals(true, r.Is_Active__c);
            System.assertEquals('GTMA1 Target', r.Coverage_Type__c);
            System.assertEquals(Date.today(), r.Date_Added__c);
        }
    }

    @IsTest
    static void syncDeactivate_marksInactive() {
        User rep = makeUser();
        Account a = makeAccount('SyncAcctDeact');
        GTM_Coverage__c existing = new GTM_Coverage__c(
            Account__c       = a.Id,
            Rep__c           = rep.Id,
            Coverage_Type__c = 'AE Target',
            Is_Active__c     = true,
            Date_Added__c    = Date.today().addDays(-5)
        );
        insert existing;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(
                new List<Id>(),
                new List<Id>{ a.Id },
                rep.Id,
                'AE Target'
            );
            Test.stopTest();
        }

        GTM_Coverage__c updated = [
            SELECT Is_Active__c, Date_Removed__c FROM GTM_Coverage__c WHERE Id = :existing.Id
        ];
        System.assertEquals(false, updated.Is_Active__c);
        System.assertEquals(Date.today(), updated.Date_Removed__c);
    }

    @IsTest
    static void syncActivate_reactivatesInactiveRecord() {
        User rep = makeUser();
        Account a = makeAccount('SyncAcctReact');
        GTM_Coverage__c existing = new GTM_Coverage__c(
            Account__c        = a.Id,
            Rep__c            = rep.Id,
            Coverage_Type__c  = 'GTMA1 Target',
            Is_Active__c      = false,
            Date_Added__c     = Date.today().addDays(-10),
            Date_Removed__c   = Date.today().addDays(-3)
        );
        insert existing;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(
                new List<Id>{ a.Id },
                new List<Id>(),
                rep.Id,
                'GTMA1 Target'
            );
            Test.stopTest();
        }

        GTM_Coverage__c updated = [
            SELECT Is_Active__c, Date_Added__c, Date_Removed__c
            FROM GTM_Coverage__c WHERE Id = :existing.Id
        ];
        System.assertEquals(true, updated.Is_Active__c);
        System.assertEquals(Date.today(), updated.Date_Added__c);
        System.assertEquals(null, updated.Date_Removed__c);

        // Must not have created a duplicate
        System.assertEquals(1, [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :rep.Id AND Account__c = :a.Id]);
    }

    @IsTest
    static void syncActivate_alreadyActive_noOp() {
        User rep = makeUser();
        Account a = makeAccount('SyncAcctAlready');
        GTM_Coverage__c existing = new GTM_Coverage__c(
            Account__c        = a.Id,
            Rep__c            = rep.Id,
            Coverage_Type__c  = 'AE Target',
            Is_Active__c      = true,
            Date_Added__c     = Date.today().addDays(-1)
        );
        insert existing;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>{ a.Id }, new List<Id>(), rep.Id, 'AE Target');
            Test.stopTest();
        }

        System.assertEquals(1, [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :rep.Id AND Account__c = :a.Id]);
    }

    @IsTest
    static void syncDeactivate_alreadyInactive_noUpdate() {
        User rep = makeUser();
        Account a = makeAccount('SyncAcctAlreadyInactive');
        GTM_Coverage__c existing = new GTM_Coverage__c(
            Account__c        = a.Id,
            Rep__c            = rep.Id,
            Coverage_Type__c  = 'GTMA1 Target',
            Is_Active__c      = false,
            Date_Added__c     = Date.today().addDays(-10),
            Date_Removed__c   = Date.today().addDays(-5)
        );
        insert existing;
        Date origRemoved = existing.Date_Removed__c;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>(), new List<Id>{ a.Id }, rep.Id, 'GTMA1 Target');
            Test.stopTest();
        }

        GTM_Coverage__c unchanged = [SELECT Date_Removed__c FROM GTM_Coverage__c WHERE Id = :existing.Id];
        System.assertEquals(origRemoved, unchanged.Date_Removed__c, 'Date_Removed__c should not change for already-inactive record');
    }

    @IsTest
    static void syncDeactivate_missingRecord_noError() {
        User rep = makeUser();
        Account a = makeAccount('SyncAcctMissing');

        // No existing coverage record — deactivate should be silent
        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>(), new List<Id>{ a.Id }, rep.Id, 'GTMA1 Target');
            Test.stopTest();
        }

        System.assertEquals(0, [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :rep.Id AND Account__c = :a.Id]);
    }

    @IsTest
    static void sync_bothListsNull_earlyReturn() {
        User rep = makeUser();

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(null, null, rep.Id, 'AE Target');
            Test.stopTest();
        }

        System.assertEquals(0, [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :rep.Id]);
    }

    @IsTest
    static void sync_bothListsEmpty_earlyReturn() {
        User rep = makeUser();

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>(), new List<Id>(), rep.Id, 'AE Target');
            Test.stopTest();
        }

        System.assertEquals(0, [SELECT COUNT() FROM GTM_Coverage__c WHERE Rep__c = :rep.Id]);
    }

    @IsTest
    static void sync_mixedActivateAndDeactivate() {
        User rep = makeUser();
        Account a1 = makeAccount('SyncMixedA');
        Account a2 = makeAccount('SyncMixedB');

        GTM_Coverage__c toDeact = new GTM_Coverage__c(
            Account__c       = a2.Id,
            Rep__c           = rep.Id,
            Coverage_Type__c = 'GTMA1 Target',
            Is_Active__c     = true,
            Date_Added__c    = Date.today().addDays(-2)
        );
        insert toDeact;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>{ a1.Id }, new List<Id>{ a2.Id }, rep.Id, 'GTMA1 Target');
            Test.stopTest();
        }

        GTM_Coverage__c newRec = [
            SELECT Is_Active__c FROM GTM_Coverage__c WHERE Rep__c = :rep.Id AND Account__c = :a1.Id
        ];
        System.assertEquals(true, newRec.Is_Active__c);

        GTM_Coverage__c deactRec = [
            SELECT Is_Active__c FROM GTM_Coverage__c WHERE Rep__c = :rep.Id AND Account__c = :a2.Id
        ];
        System.assertEquals(false, deactRec.Is_Active__c);
    }

    @IsTest
    static void sync_coverageTypeScopedCorrectly() {
        // A record with 'AE Target' should not be touched when syncing 'GTMA1 Target'
        User rep = makeUser();
        Account a = makeAccount('SyncTypeScope');
        GTM_Coverage__c aeRec = new GTM_Coverage__c(
            Account__c       = a.Id,
            Rep__c           = rep.Id,
            Coverage_Type__c = 'AE Target',
            Is_Active__c     = false,
            Date_Added__c    = Date.today().addDays(-5)
        );
        insert aeRec;

        System.runAs(rep) {
            Test.startTest();
            GTMCoverageSync.sync(new List<Id>{ a.Id }, new List<Id>(), rep.Id, 'GTMA1 Target');
            Test.stopTest();
        }

        // AE Target record should remain inactive (untouched)
        GTM_Coverage__c unchanged = [SELECT Is_Active__c FROM GTM_Coverage__c WHERE Id = :aeRec.Id];
        System.assertEquals(false, unchanged.Is_Active__c);

        // A new GTMA1 Target record should have been created
        System.assertEquals(1, [
            SELECT COUNT() FROM GTM_Coverage__c
            WHERE Rep__c = :rep.Id AND Account__c = :a.Id AND Coverage_Type__c = 'GTMA1 Target'
        ]);
    }
}
