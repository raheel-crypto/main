@IsTest
private class AccountDedupeScanControllerTest {

    @TestSetup
    static void setup() {
        List<Account> accs = new List<Account>{
            new Account(Name = 'Acme, Inc.',         Website = 'https://www.acme.com',  LinkedIn_URL__c = 'https://linkedin.com/company/acme'),
            new Account(Name = 'Acme Corporation',   Website = 'http://acme.com/',      LinkedIn_URL__c = 'https://linkedin.com/company/acme'),
            new Account(Name = 'Acme Holdings LLC',  Website = 'https://acme.com',      LinkedIn_URL__c = null),
            new Account(Name = 'Oaklins Denmark',    Website = 'https://oaklins.com',   LinkedIn_URL__c = 'https://linkedin.com/company/oaklins-dk'),
            new Account(Name = 'Oaklins Italy',      Website = 'https://oaklins.com',   LinkedIn_URL__c = 'https://linkedin.com/company/oaklins-it'),
            new Account(Name = 'Globex Corp',        Website = 'https://globex.com',    LinkedIn_URL__c = null)
        };
        insert accs;
    }

    @IsTest
    static void listScenarios_returnsFiveOptions() {
        List<AccountDedupeScanController.ScenarioOption> opts = AccountDedupeScanController.listScenarios();
        System.assertEquals(5, opts.size());
    }

    @IsTest
    static void startScan_runsAllScenariosAndPersistsGroups() {
        Test.startTest();
        Id scanId = AccountDedupeScanController.startScan(new List<String>{
            'exactWebsite', 'exactLinkedIn', 'nameNormalizedDomain', 'nameDomainRoot', 'fuzzyNameDomainRoot'
        });
        Test.stopTest();

        Dedupe_Scan__c scan = [
            SELECT Id, Status__c, Group_Count__c, Account_Count__c, Scenarios_Run__c
            FROM Dedupe_Scan__c WHERE Id = :scanId
        ];
        System.assertEquals('Completed', scan.Status__c, 'Scan should complete: ' + scan);
        System.assert(scan.Group_Count__c > 0, 'Expected at least one group');

        Set<String> scenariosSeen = new Set<String>();
        for (Dedupe_Group__c g : [
            SELECT Id, Scenario_Key__c, Member_Count__c, Status__c,
                   (SELECT Id FROM Members__r)
            FROM Dedupe_Group__c WHERE Scan__c = :scanId
        ]) {
            scenariosSeen.add(g.Scenario_Key__c);
            System.assertEquals('Open', g.Status__c);
            System.assert(g.Members__r.size() >= 2, 'Each group needs >= 2 members');
            System.assertEquals(g.Members__r.size(), g.Member_Count__c.intValue());
        }
        // All five scenarios should have found at least one group given the seed data.
        for (String key : new List<String>{ 'exactWebsite', 'exactLinkedIn', 'nameNormalizedDomain', 'nameDomainRoot', 'fuzzyNameDomainRoot' }) {
            System.assert(scenariosSeen.contains(key), 'Expected at least one group for scenario: ' + key);
        }
    }

    @IsTest
    static void unknownScenarioKey_isRejected() {
        try {
            AccountDedupeScanController.startScan(new List<String>{ 'notARealScenario' });
            System.assert(false, 'should throw');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void resolveGroups_noOpOnEmptyInput() {
        AccountDedupeScanService.resolveGroups(null);
        AccountDedupeScanService.resolveGroups(new Set<Id>());
        Set<Id> empty = AccountDedupeScanService.findOpenGroupsForAccounts(null);
        System.assertEquals(0, empty.size());
        empty = AccountDedupeScanService.findOpenGroupsForAccounts(new Set<Id>());
        System.assertEquals(0, empty.size());
    }

    @IsTest
    static void listScansAndGroups_roundTrip() {
        Test.startTest();
        Id scanId = AccountDedupeScanController.startScan(new List<String>{ 'exactWebsite' });
        Test.stopTest();

        List<AccountDedupeScanController.ScanSummary> scans = AccountDedupeScanController.listScans(10);
        System.assertEquals(1, scans.size());
        System.assertEquals(scanId, scans[0].id);
        System.assertEquals('Completed', scans[0].status);

        List<AccountDedupeScanController.GroupSummary> open = AccountDedupeScanController.listGroups(scanId, 'Open', null);
        System.assert(!open.isEmpty(), 'Should have at least one open group');
        for (AccountDedupeScanController.GroupSummary g : open) {
            System.assert(g.members.size() >= 2);
        }

        List<AccountDedupeScanController.GroupSummary> filtered =
            AccountDedupeScanController.listGroups(scanId, 'Open', 'exactWebsite');
        for (AccountDedupeScanController.GroupSummary g : filtered) {
            System.assertEquals('exactWebsite', g.scenarioKey);
        }
    }

    @IsTest
    static void mergeAccounts_resolvesContainingGroup() {
        // Run a scan first to create open groups.
        Test.startTest();
        Id scanId = AccountDedupeScanController.startScan(new List<String>{ 'exactWebsite' });
        Test.stopTest();

        // Pick an Acme group and merge two of its members.
        Dedupe_Group__c acmeGroup;
        for (Dedupe_Group__c g : [
            SELECT Id, Status__c, Match_Key__c, (SELECT Account__c FROM Members__r)
            FROM Dedupe_Group__c WHERE Scan__c = :scanId
        ]) {
            if (g.Match_Key__c != null && g.Match_Key__c.contains('acme')) {
                acmeGroup = g;
                break;
            }
        }
        System.assertNotEquals(null, acmeGroup, 'Acme group should exist');
        System.assert(acmeGroup.Members__r.size() >= 2);

        Id master = acmeGroup.Members__r[0].Account__c;
        List<Id> dupes = new List<Id>{ acmeGroup.Members__r[1].Account__c };

        AccountDedupeService.mergeAccounts(master, dupes, null);

        Dedupe_Group__c after = [SELECT Status__c, Resolved_At__c, Resolved_By__c FROM Dedupe_Group__c WHERE Id = :acmeGroup.Id];
        System.assertEquals('Resolved', after.Status__c);
        System.assertNotEquals(null, after.Resolved_At__c);
        System.assertEquals(UserInfo.getUserId(), after.Resolved_By__c);
    }

    @IsTest
    static void startScan_rejectsEmptyScenarioList() {
        try {
            AccountDedupeScanController.startScan(new List<String>());
            System.assert(false, 'should throw');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void acrConflicts_detectAndCleanup() {
        // Two Acme accounts share Website — they'll be in the same Exact Website group.
        List<Account> acmes = [
            SELECT Id FROM Account WHERE Website LIKE '%acme%' ORDER BY Name LIMIT 3
        ];
        System.assert(acmes.size() >= 2, 'Need >= 2 Acme accounts');
        Id master = acmes[0].Id;
        Id dupe   = acmes[1].Id;

        // Contact's direct account = master; add an indirect ACR on the dupe.
        Contact c = new Contact(FirstName = 'Test', LastName = 'Person', AccountId = master);
        insert c;
        insert new AccountContactRelation(ContactId = c.Id, AccountId = dupe);

        Test.startTest();
        Id scanId = AccountDedupeScanController.startScan(new List<String>{ 'exactWebsite' });
        Test.stopTest();

        Dedupe_Group__c acmeGroup;
        for (Dedupe_Group__c g : [
            SELECT Id, (SELECT Account__c FROM Members__r)
            FROM Dedupe_Group__c WHERE Scan__c = :scanId
        ]) {
            for (Dedupe_Group_Member__c m : g.Members__r) {
                if (m.Account__c == master) { acmeGroup = g; break; }
            }
            if (acmeGroup != null) break;
        }
        System.assertNotEquals(null, acmeGroup, 'Acme group should exist');

        List<AccountDedupeScanController.AcrConflict> conflicts =
            AccountDedupeScanController.listAcrConflicts(acmeGroup.Id);
        System.assert(!conflicts.isEmpty(), 'Should detect the conflict contact');
        Boolean found = false;
        for (AccountDedupeScanController.AcrConflict cf : conflicts) {
            if (cf.contactId == c.Id) {
                found = true;
                System.assert(cf.relations.size() >= 2);
            }
        }
        System.assert(found, 'Inserted contact should appear in conflicts');

        Integer cleaned = AccountDedupeScanController.cleanupAcrConflicts(acmeGroup.Id, master);
        System.assert(cleaned >= 1);
        Integer remaining = [
            SELECT COUNT() FROM AccountContactRelation
            WHERE ContactId = :c.Id AND AccountId = :dupe AND IsDirect = false
        ];
        System.assertEquals(0, remaining, 'Indirect ACR on dupe should be gone');
    }

    @IsTest
    static void acrConflicts_emptyInputs() {
        System.assertEquals(0, AccountDedupeScanController.listAcrConflicts(null).size());
        try {
            AccountDedupeScanController.cleanupAcrConflicts(null, null);
            System.assert(false, 'should throw');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void dismissGroups_marksResolved() {
        Test.startTest();
        Id scanId = AccountDedupeScanController.startScan(new List<String>{ 'exactWebsite' });
        Test.stopTest();

        List<Dedupe_Group__c> open = [
            SELECT Id FROM Dedupe_Group__c WHERE Scan__c = :scanId AND Status__c = 'Open' LIMIT 5
        ];
        System.assert(!open.isEmpty());

        List<Id> ids = new List<Id>();
        for (Dedupe_Group__c g : open) ids.add(g.Id);

        Integer count = AccountDedupeScanController.dismissGroups(ids);
        System.assertEquals(ids.size(), count);

        Integer stillOpen = [SELECT COUNT() FROM Dedupe_Group__c WHERE Id IN :ids AND Status__c = 'Open'];
        System.assertEquals(0, stillOpen);

        // Empty / null inputs return 0
        System.assertEquals(0, AccountDedupeScanController.dismissGroups(null));
        System.assertEquals(0, AccountDedupeScanController.dismissGroups(new List<Id>()));
    }

    @IsTest
    static void createManualGroup_happyPath() {
        List<Account> picks = [SELECT Id FROM Account LIMIT 3];
        List<Id> ids = new List<Id>();
        for (Account a : picks) ids.add(a.Id);

        Id groupId = AccountDedupeScanController.createManualGroup(null, ids, 'pantheon');
        System.assertNotEquals(null, groupId);

        Dedupe_Group__c g = [
            SELECT Scenario_Key__c, Match_Key__c, Member_Count__c, Status__c,
                   (SELECT Account__c FROM Members__r)
            FROM Dedupe_Group__c WHERE Id = :groupId
        ];
        System.assertEquals('manual', g.Scenario_Key__c);
        System.assertEquals('pantheon', g.Match_Key__c);
        System.assertEquals(3, g.Member_Count__c.intValue());
        System.assertEquals(3, g.Members__r.size());
        System.assertEquals('Open', g.Status__c);
    }

    @IsTest
    static void createManualGroup_validation() {
        List<Account> picks = [SELECT Id FROM Account LIMIT 6];
        List<Id> tooMany = new List<Id>();
        for (Account a : picks) tooMany.add(a.Id);

        try {
            AccountDedupeScanController.createManualGroup(null, new List<Id>{ picks[0].Id }, null);
            System.assert(false, 'should reject < 2');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            AccountDedupeScanController.createManualGroup(null, tooMany, null);
            System.assert(false, 'should reject > 5');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            AccountDedupeScanController.createManualGroup(null,
                new List<Id>{ picks[0].Id, picks[0].Id }, null);
            System.assert(false, 'should reject duplicates');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void getAccountSummaries_returnsRequested() {
        List<Account> picks = [SELECT Id FROM Account LIMIT 2];
        List<Id> ids = new List<Id>();
        for (Account a : picks) ids.add(a.Id);
        List<AccountDedupeScanController.ManualAccount> out =
            AccountDedupeScanController.getAccountSummaries(ids);
        System.assertEquals(2, out.size());
        System.assertEquals(0, AccountDedupeScanController.getAccountSummaries(null).size());
    }
}
