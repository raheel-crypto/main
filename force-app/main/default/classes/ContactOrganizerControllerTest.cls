@isTest
private class ContactOrganizerControllerTest {

    private static Opportunity setupOppWithContacts(Integer contactCount) {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < contactCount; i++) {
            contacts.add(new Contact(
                FirstName = 'First' + i,
                LastName = 'Last' + i,
                AccountId = acc.Id,
                Title = 'Title ' + i,
                Email = 'user' + i + '@example.com'
            ));
        }
        insert contacts;

        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            AccountId = acc.Id
        );
        insert opp;
        return opp;
    }

    @isTest
    static void loadOrganizerReturnsAssignmentsAndTotal() {
        Opportunity opp = setupOppWithContacts(3);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        insert new Relationship_Map__c(
            Contact__c = contacts[0].Id,
            Account__c = opp.AccountId,
            Opportunity__c = opp.Id,
            Role__c = 'C-Suite/Executive',
            Champion__c = true
        );

        Test.startTest();
        ContactOrganizerController.OrganizerData data = ContactOrganizerController.loadOrganizer(opp.Id);
        Test.stopTest();

        System.assertEquals(opp.Id, data.opportunityId);
        System.assertEquals(opp.AccountId, data.accountId);
        System.assertEquals(3, data.totalContacts);
        System.assertEquals(1, data.assignments.size());
        System.assertEquals('C-Suite/Executive', data.assignments[0].role);
        System.assertEquals(true, data.assignments[0].isChampion);
    }

    @isTest
    static void searchAccountContactsFiltersByTermAndExcludes() {
        Opportunity opp = setupOppWithContacts(5);
        List<Contact> contacts = [SELECT Id, LastName FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];
        Id excludedId = contacts[0].Id;

        Test.startTest();
        List<ContactOrganizerController.ContactWrapper> noFilter =
            ContactOrganizerController.searchAccountContacts(opp.AccountId, opp.Id, '', new List<Id>{ excludedId });
        List<ContactOrganizerController.ContactWrapper> withTerm =
            ContactOrganizerController.searchAccountContacts(opp.AccountId, opp.Id, 'Last2', new List<Id>());
        Test.stopTest();

        System.assertEquals(4, noFilter.size(), 'Excluded id should be omitted');
        for (ContactOrganizerController.ContactWrapper w : noFilter) {
            System.assertNotEquals(excludedId, w.id);
            System.assertNotEquals(null, w.activity, 'Activity stats wrapper should always be present');
        }
        System.assertEquals(1, withTerm.size());
        System.assertEquals('First2 Last2', withTerm[0].name);
    }

    @isTest
    static void loadOrganizerIncludesActivityRollups() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        insert new Relationship_Map__c(
            Contact__c = contacts[0].Id,
            Account__c = opp.AccountId,
            Opportunity__c = opp.Id,
            Role__c = 'Senior User'
        );
        insert new Task(
            WhoId = contacts[0].Id,
            WhatId = opp.Id,
            Status = 'Completed',
            Subject = 'Test email',
            TaskSubtype = 'Email',
            ActivityDate = Date.today().addDays(-2)
        );

        Test.startTest();
        ContactOrganizerController.OrganizerData data = ContactOrganizerController.loadOrganizer(opp.Id);
        Test.stopTest();

        System.assertNotEquals(null, data.summary);
        System.assertEquals(1, data.assignments.size());
        ContactOrganizerController.ActivityStats stats = data.assignments[0].activity;
        System.assertNotEquals(null, stats);
        System.assertEquals(1, stats.total);
        System.assertEquals(1, stats.emails);
        System.assertEquals(1, stats.last7d);
        System.assertEquals(Date.today().addDays(-2), stats.lastActivityDate);
        System.assertEquals(1, data.summary.totalActivities);
        System.assertEquals(1, data.summary.engagedContacts);
    }

    @isTest
    static void saveAssignmentsInsertsWithChampion() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        ContactOrganizerController.RelationshipMapInput a = new ContactOrganizerController.RelationshipMapInput();
        a.contactId = contacts[0].Id;
        a.role = 'Senior User';
        a.isChampion = true;
        inputs.add(a);
        ContactOrganizerController.RelationshipMapInput b = new ContactOrganizerController.RelationshipMapInput();
        b.contactId = contacts[1].Id;
        b.role = 'Junior User';
        b.isChampion = false;
        inputs.add(b);

        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, inputs);
        Test.stopTest();

        Map<Id, Relationship_Map__c> byContact = new Map<Id, Relationship_Map__c>();
        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Role__c, Champion__c, Account__c, Opportunity__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opp.Id
        ]) {
            byContact.put(rm.Contact__c, rm);
        }
        System.assertEquals(2, byContact.size());
        System.assertEquals(true, byContact.get(contacts[0].Id).Champion__c);
        System.assertEquals(false, byContact.get(contacts[1].Id).Champion__c);
    }

    @isTest
    static void saveAssignmentsUpdatesChampionAndDeletesUnmapped() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        insert new List<Relationship_Map__c>{
            new Relationship_Map__c(
                Contact__c = contacts[0].Id,
                Account__c = opp.AccountId,
                Opportunity__c = opp.Id,
                Role__c = 'Junior User',
                Champion__c = false
            ),
            new Relationship_Map__c(
                Contact__c = contacts[1].Id,
                Account__c = opp.AccountId,
                Opportunity__c = opp.Id,
                Role__c = 'Senior User',
                Champion__c = false
            )
        };

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        ContactOrganizerController.RelationshipMapInput a = new ContactOrganizerController.RelationshipMapInput();
        a.contactId = contacts[0].Id;
        a.role = 'C-Suite/Executive';
        a.isChampion = true;
        inputs.add(a);

        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, inputs);
        Test.stopTest();

        List<Relationship_Map__c> remaining = [
            SELECT Contact__c, Role__c, Champion__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, remaining.size());
        System.assertEquals(contacts[0].Id, remaining[0].Contact__c);
        System.assertEquals('C-Suite/Executive', remaining[0].Role__c);
        System.assertEquals(true, remaining[0].Champion__c);
    }

    @isTest
    static void saveAssignmentsRejectsInvalidRole() {
        Opportunity opp = setupOppWithContacts(1);
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId LIMIT 1];

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        ContactOrganizerController.RelationshipMapInput bad = new ContactOrganizerController.RelationshipMapInput();
        bad.contactId = c.Id;
        bad.role = 'Not A Real Role';
        inputs.add(bad);

        Boolean threw = false;
        Test.startTest();
        try {
            ContactOrganizerController.saveAssignments(opp.Id, inputs);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Expected invalid-role exception');
    }
}
