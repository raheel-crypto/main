@IsTest
private class AccountDedupeControllerTest {

    private static Account buildAccount(String name, String website, String linkedin, String normDomain, String domainRoot) {
        return new Account(
            Name = name,
            Website = website,
            LinkedIn_URL__c = linkedin,
            Normalized_Domain__c = normDomain,
            Domain_Root__c = domainRoot,
            Phone = '555-0100'
        );
    }

    @TestSetup
    static void setup() {
        List<Account> accs = new List<Account>{
            buildAccount('Acme, Inc.',         'https://www.acme.com',         'https://linkedin.com/company/acme',   'acme.com',     'acme'),
            buildAccount('Acme Corporation',   'http://acme.com/',             'linkedin.com/company/acme',           'acme.com',     'acme'),
            buildAccount('Acme Holdings LLC',  'https://acme.com',             null,                                   'acme.com',     'acme'),
            buildAccount('Acme Subsidiary',    'https://sub.acme.com',         null,                                   'sub.acme.com', 'acme'),
            buildAccount('Globex Corp',        'https://globex.com',           null,                                   'globex.com',   'globex')
        };
        insert accs;
    }

    @IsTest
    static void findDuplicates_returnsExpectedScenarios() {
        Account src = [SELECT Id FROM Account WHERE Name = 'Acme, Inc.' LIMIT 1];

        Test.startTest();
        AccountDedupeService.DedupeResult res = AccountDedupeController.findDuplicates(src.Id);
        Test.stopTest();

        System.assertEquals(src.Id, res.sourceId, 'sourceId should round-trip');
        System.assertEquals(5, res.scenarios.size(), 'five scenarios should be returned');

        Map<String, AccountDedupeService.ScenarioResult> byKey = new Map<String, AccountDedupeService.ScenarioResult>();
        for (AccountDedupeService.ScenarioResult s : res.scenarios) byKey.put(s.key, s);

        System.assert(byKey.get('exactWebsite').matchIds.size() >= 2,
            'Two other Acme accounts share the acme.com website after normalization');
        System.assert(byKey.get('exactLinkedIn').matchIds.size() >= 1,
            'One other Acme record has the same normalized LinkedIn URL');
        System.assert(byKey.get('nameNormalizedDomain').matchIds.size() >= 2,
            'Normalized "acme" name matches with normalized domain acme.com');
        System.assert(byKey.get('nameDomainRoot').matchIds.size() >= 2,
            'Normalized "acme" name matches with domain root acme');
        System.assertNotEquals(null, byKey.get('fuzzyNameDomainRoot'),
            'fuzzy scenario present');

        for (AccountDedupeService.ScenarioResult s : res.scenarios) {
            for (Id id : s.matchIds) {
                System.assertNotEquals(src.Id, id, 'source should never be in its own match list');
            }
        }
    }

    @IsTest
    static void mergeAccounts_cherryPicksFieldsAndMerges() {
        Map<String, Account> byName = new Map<String, Account>();
        for (Account a : [SELECT Id, Name, Industry, Website FROM Account WHERE Domain_Root__c = 'acme']) {
            byName.put(a.Name, a);
        }
        Account master = byName.get('Acme, Inc.');
        Account dupe1 = byName.get('Acme Corporation');
        Account dupe2 = byName.get('Acme Holdings LLC');
        System.assertNotEquals(null, master, 'setup created master');
        System.assertNotEquals(null, dupe1, 'setup created dupe1');
        System.assertNotEquals(null, dupe2, 'setup created dupe2');

        master.Industry = null;
        update master;
        dupe1.Industry = 'Technology';
        update dupe1;

        Map<String, Id> fieldSource = new Map<String, Id>{ 'Industry' => dupe1.Id };
        List<Id> dupeIds = new List<Id>{ dupe1.Id, dupe2.Id };

        // Call the service directly so any real exception surfaces in the test
        // output (AuraHandledException masks the message on the controller path).
        Test.startTest();
        AccountDedupeService.mergeAccounts(master.Id, dupeIds, fieldSource);
        Test.stopTest();

        Account afterMaster = [SELECT Id, Industry FROM Account WHERE Id = :master.Id];
        System.assertEquals('Technology', afterMaster.Industry, 'cherry-picked Industry should be on master');

        List<Account> remaining = [SELECT Id FROM Account WHERE Id IN :dupeIds];
        System.assertEquals(0, remaining.size(), 'duplicates should have been merged away');
    }

    @IsTest
    static void mergeAccounts_rejectsBadInput() {
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        try {
            AccountDedupeController.mergeAccounts(a.Id, new List<Id>(), null);
            System.assert(false, 'should have thrown on empty duplicates');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            AccountDedupeController.mergeAccounts(a.Id, new List<Id>{ a.Id }, null);
            System.assert(false, 'should have thrown when master is in duplicates list');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void findDuplicates_handlesAccountWithNoMatches() {
        Account src = [SELECT Id FROM Account WHERE Name = 'Globex Corp' LIMIT 1];
        Test.startTest();
        AccountDedupeService.DedupeResult res = AccountDedupeController.findDuplicates(src.Id);
        Test.stopTest();
        Integer total = 0;
        for (AccountDedupeService.ScenarioResult s : res.scenarios) total += s.matchIds.size();
        System.assertEquals(0, total, 'Globex should have no duplicates');
    }

    @IsTest
    static void fuzzyScenario_catchesSharedTokenAcrossRegionalNames() {
        // The Oaklins case: regional offices share a brand token but differ
        // entirely in suffix. Levenshtein alone misses these; token overlap
        // should catch them.
        List<Account> accs = new List<Account>{
            new Account(Name = 'Oaklins Denmark',     Website = 'https://oaklins.com',  Domain_Root__c = 'oaklins'),
            new Account(Name = 'Oaklins Italy',       Website = 'https://oaklins.com',  Domain_Root__c = 'oaklins'),
            new Account(Name = 'Oaklins Switzerland', Website = 'https://oaklins.com',  Domain_Root__c = 'oaklins')
        };
        insert accs;

        Test.startTest();
        AccountDedupeService.DedupeResult res = AccountDedupeController.findDuplicates(accs[0].Id);
        Test.stopTest();

        AccountDedupeService.ScenarioResult fuzzy;
        AccountDedupeService.ScenarioResult nameDomainRoot;
        for (AccountDedupeService.ScenarioResult s : res.scenarios) {
            if (s.key == 'fuzzyNameDomainRoot') fuzzy = s;
            if (s.key == 'nameDomainRoot') nameDomainRoot = s;
        }
        System.assertEquals(2, fuzzy.matchIds.size(),
            'Both other Oaklins regional offices should match via shared token "oaklins"');
        System.assertEquals(0, nameDomainRoot.matchIds.size(),
            '"Name + Domain Root" stays exact-after-normalization and should not fire here');
    }

    @IsTest
    static void getCompareData_returnsFieldsAndRecords() {
        List<Account> accs = [SELECT Id FROM Account LIMIT 3];
        List<Id> ids = new List<Id>();
        for (Account a : accs) ids.add(a.Id);

        AccountDedupeService.CompareData cd = AccountDedupeController.getCompareData(ids);
        System.assertNotEquals(null, cd);
        System.assert(cd.fields.size() > 0, 'Should include field metadata');
        System.assertEquals(3, cd.records.size(), 'Should include all requested accounts');
        for (Id id : ids) System.assert(cd.records.containsKey(id));

        // Null/empty input returns empty records but still includes field meta.
        AccountDedupeService.CompareData empty = AccountDedupeController.getCompareData(null);
        System.assertEquals(0, empty.records.size());
    }
}
