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
        ContactOrganizerController.SaveResult result =
            ContactOrganizerController.saveAssignments(opp.Id, JSON.serialize(inputs));
        Test.stopTest();

        System.assertEquals(2, result.received);
        System.assertEquals(2, result.inserted);
        System.assertEquals(0, result.updated);
        System.assertEquals(0, result.deleted);
        System.assertEquals(0, result.skipped);

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
        ContactOrganizerController.saveAssignments(opp.Id, JSON.serialize(inputs));
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
            ContactOrganizerController.saveAssignments(opp.Id, JSON.serialize(inputs));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Expected invalid-role exception');
    }

    // ── Error paths ────────────────────────────────────────────────────

    @isTest
    static void loadOrganizerThrowsWhenIdNull() {
        Boolean threw = false;
        try {
            ContactOrganizerController.loadOrganizer(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception for null Opp Id');
    }

    @isTest
    static void loadOrganizerThrowsWhenOppMissing() {
        Account a = new Account(Name = 'Throwaway');
        insert a;
        // a's Id is valid format but not an Opportunity Id — use a real-looking but missing Opp Id
        Opportunity o = new Opportunity(
            Name = 'Temp', StageName = 'Prospecting', CloseDate = Date.today()
        );
        insert o;
        Id missingId = o.Id;
        delete o;

        Boolean threw = false;
        try {
            ContactOrganizerController.loadOrganizer(missingId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception when Opp not found');
    }

    @isTest
    static void loadOrganizerReturnsEmptyWhenOppHasNoAccount() {
        Opportunity o = new Opportunity(
            Name = 'Orphan', StageName = 'Prospecting', CloseDate = Date.today()
        );
        insert o;

        ContactOrganizerController.OrganizerData data = ContactOrganizerController.loadOrganizer(o.Id);
        System.assertEquals(null, data.accountId);
        System.assertEquals(0, data.totalContacts);
        System.assertEquals(0, data.assignments.size());
        System.assertNotEquals(null, data.summary);
        System.assertEquals(0, data.summary.totalActivities);
    }

    @isTest
    static void searchReturnsEmptyWhenAccountNull() {
        List<ContactOrganizerController.ContactWrapper> wrappers =
            ContactOrganizerController.searchAccountContacts(null, null, '', new List<Id>());
        System.assertEquals(0, wrappers.size());
    }

    @isTest
    static void searchWithoutOpportunityIdReturnsContactsAndStats() {
        Opportunity opp = setupOppWithContacts(3);
        Contact c0 = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName LIMIT 1];

        // Activity attributed to Account (not the Opportunity) — exercises the
        // accountId-only branch in getActivityStats and getAccountSummary.
        insert new Event(
            WhoId = c0.Id,
            WhatId = opp.AccountId,
            Subject = 'Account meeting',
            ActivityDateTime = DateTime.now().addDays(-1),
            DurationInMinutes = 30
        );

        Test.startTest();
        List<ContactOrganizerController.ContactWrapper> wrappers =
            ContactOrganizerController.searchAccountContacts(opp.AccountId, null, '', new List<Id>());
        Test.stopTest();

        System.assertEquals(3, wrappers.size());
        Boolean foundActivity = false;
        for (ContactOrganizerController.ContactWrapper w : wrappers) {
            if (w.id == c0.Id) {
                System.assertEquals(1, w.activity.total);
                System.assertEquals(1, w.activity.meetings);
                System.assertEquals(1, w.activity.last7d);
                foundActivity = true;
            }
        }
        System.assert(foundActivity, 'Activity should be returned for c0');
    }

    @isTest
    static void searchWithTermAndExcludesPath() {
        Opportunity opp = setupOppWithContacts(4);
        List<Contact> contacts = [SELECT Id, LastName FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        Test.startTest();
        List<ContactOrganizerController.ContactWrapper> results =
            ContactOrganizerController.searchAccountContacts(
                opp.AccountId, opp.Id, 'Last', new List<Id>{ contacts[0].Id, contacts[1].Id }
            );
        Test.stopTest();

        // Term matches all 4, but two are excluded
        System.assertEquals(2, results.size());
        for (ContactOrganizerController.ContactWrapper w : results) {
            System.assertNotEquals(contacts[0].Id, w.id);
            System.assertNotEquals(contacts[1].Id, w.id);
        }
    }

    // ── Activity rollups: edge cases ──────────────────────────────────

    @isTest
    static void loadOrganizerAggregatesMixedActivityTypes() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        insert new Relationship_Map__c(
            Contact__c = contacts[0].Id,
            Account__c = opp.AccountId,
            Opportunity__c = opp.Id,
            Role__c = 'C-Suite/Executive'
        );

        // Email task, completed call task, and an event — exercises multiple branches.
        insert new List<Task>{
            new Task(
                WhoId = contacts[0].Id, WhatId = opp.Id, Status = 'Completed',
                Subject = 'Sent intro', TaskSubtype = 'Email',
                ActivityDate = Date.today().addDays(-3)
            ),
            new Task(
                WhoId = contacts[0].Id, WhatId = opp.Id, Status = 'Completed',
                Subject = 'Logged call', TaskSubtype = 'Call',
                ActivityDate = Date.today().addDays(-10)
            )
        };
        insert new Event(
            WhoId = contacts[0].Id, WhatId = opp.Id,
            Subject = 'Discovery call',
            ActivityDateTime = DateTime.now().addDays(-5), DurationInMinutes = 45
        );

        Test.startTest();
        ContactOrganizerController.OrganizerData data = ContactOrganizerController.loadOrganizer(opp.Id);
        Test.stopTest();

        ContactOrganizerController.ActivityStats stats = data.assignments[0].activity;
        System.assertEquals(3, stats.total);
        System.assertEquals(1, stats.emails);
        System.assertEquals(1, stats.meetings);
        // Last 7d should include the email (-3) and meeting (-5), but not the call (-10)
        System.assertEquals(2, stats.last7d);
        System.assertEquals(3, stats.last30d);
        System.assertEquals(Date.today().addDays(-3), stats.lastActivityDate);

        System.assertEquals(3, data.summary.totalActivities);
        System.assertEquals(1, data.summary.engagedContacts);
        System.assertEquals(2, data.summary.activitiesLast7d);
        System.assertEquals(3, data.summary.activitiesLast30d);
    }

    @isTest
    static void saveAssignmentsRejectsNullOppId() {
        Boolean threw = false;
        try {
            ContactOrganizerController.saveAssignments(
                null, '[]'
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception for null Opp Id');
    }

    @isTest
    static void saveAssignmentsThrowsWhenOppNotFound() {
        Opportunity o = new Opportunity(
            Name = 'Temp', StageName = 'Prospecting', CloseDate = Date.today()
        );
        insert o;
        Id missingId = o.Id;
        delete o;

        Boolean threw = false;
        try {
            ContactOrganizerController.saveAssignments(
                missingId, '[]'
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception when Opp not found');
    }

    @isTest
    static void saveAssignmentsThrowsWhenOppHasNoAccount() {
        Opportunity o = new Opportunity(
            Name = 'Orphan', StageName = 'Prospecting', CloseDate = Date.today()
        );
        insert o;

        Boolean threw = false;
        try {
            ContactOrganizerController.saveAssignments(
                o.Id, '[]'
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception when Opp has no Account');
    }

    @isTest
    static void saveAssignmentsThrowsOnMalformedJson() {
        Opportunity opp = setupOppWithContacts(1);
        Boolean threw = false;
        try {
            ContactOrganizerController.saveAssignments(opp.Id, '{not valid json');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception for malformed JSON');
    }

    @isTest
    static void saveAssignmentsAcceptsNullList() {
        Opportunity opp = setupOppWithContacts(1);

        // Should not throw — null list is normalized to empty.
        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, null);
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Relationship_Map__c WHERE Opportunity__c = :opp.Id]
        );
    }

    @isTest
    static void saveAssignmentsSkipsBlankInputs() {
        Opportunity opp = setupOppWithContacts(2);
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId LIMIT 1];

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        // Blank role — should be skipped
        ContactOrganizerController.RelationshipMapInput a = new ContactOrganizerController.RelationshipMapInput();
        a.contactId = c.Id;
        a.role = '';
        inputs.add(a);
        // Null contactId — should be skipped
        ContactOrganizerController.RelationshipMapInput b = new ContactOrganizerController.RelationshipMapInput();
        b.contactId = null;
        b.role = 'Senior User';
        inputs.add(b);

        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, JSON.serialize(inputs));
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Relationship_Map__c WHERE Opportunity__c = :opp.Id]
        );
    }
}
