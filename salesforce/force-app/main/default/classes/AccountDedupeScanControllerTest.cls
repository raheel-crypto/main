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
}
