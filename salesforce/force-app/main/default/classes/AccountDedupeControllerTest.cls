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
        List<Account> all = [SELECT Id, Name, Phone, Industry FROM Account WHERE Domain_Root__c = 'acme' ORDER BY Name];
        Account master = null;
        List<Id> dupes = new List<Id>();
        for (Account a : all) {
            if (a.Name == 'Acme, Inc.') master = a;
            else if (dupes.size() < 2) dupes.add(a.Id);
        }
        System.assertNotEquals(null, master);
        System.assertEquals(2, dupes.size());

        update new Account(Id = master.Id, Industry = null);
        update new Account(Id = dupes[0], Industry = 'Technology');

        Map<String, Id> fieldSource = new Map<String, Id>{ 'Industry' => dupes[0] };

        Test.startTest();
        AccountDedupeController.mergeAccounts(master.Id, dupes, fieldSource);
        Test.stopTest();

        Account after = [SELECT Id, Industry FROM Account WHERE Id = :master.Id];
        System.assertEquals('Technology', after.Industry, 'cherry-picked Industry should be on master');

        List<Account> remaining = [SELECT Id FROM Account WHERE Id IN :dupes];
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
}
