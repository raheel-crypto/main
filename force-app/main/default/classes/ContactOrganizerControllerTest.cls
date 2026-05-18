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
    static void loadOrganizerReturnsContactsAndAssignments() {
        Opportunity opp = setupOppWithContacts(3);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        Relationship_Map__c existing = new Relationship_Map__c(
            Contact__c = contacts[0].Id,
            Account__c = opp.AccountId,
            Opportunity__c = opp.Id,
            Role__c = 'C-Suite/Executive'
        );
        insert existing;

        Test.startTest();
        ContactOrganizerController.OrganizerData data = ContactOrganizerController.loadOrganizer(opp.Id);
        Test.stopTest();

        System.assertEquals(opp.Id, data.opportunityId);
        System.assertEquals(opp.AccountId, data.accountId);
        System.assertEquals(3, data.contacts.size());
        System.assertEquals(1, data.existingAssignments.size());
        System.assertEquals('C-Suite/Executive', data.existingAssignments[0].role);
    }

    @isTest
    static void saveAssignmentsInsertsRecords() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId];

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        ContactOrganizerController.RelationshipMapInput a = new ContactOrganizerController.RelationshipMapInput();
        a.contactId = contacts[0].Id;
        a.role = 'Senior User';
        inputs.add(a);
        ContactOrganizerController.RelationshipMapInput b = new ContactOrganizerController.RelationshipMapInput();
        b.contactId = contacts[1].Id;
        b.role = 'Junior User';
        inputs.add(b);

        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, inputs);
        Test.stopTest();

        List<Relationship_Map__c> created = [
            SELECT Contact__c, Role__c, Account__c, Opportunity__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(2, created.size());
        for (Relationship_Map__c rm : created) {
            System.assertEquals(opp.AccountId, rm.Account__c);
            System.assertEquals(opp.Id, rm.Opportunity__c);
        }
    }

    @isTest
    static void saveAssignmentsUpdatesAndDeletes() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];

        insert new List<Relationship_Map__c>{
            new Relationship_Map__c(
                Contact__c = contacts[0].Id,
                Account__c = opp.AccountId,
                Opportunity__c = opp.Id,
                Role__c = 'Junior User'
            ),
            new Relationship_Map__c(
                Contact__c = contacts[1].Id,
                Account__c = opp.AccountId,
                Opportunity__c = opp.Id,
                Role__c = 'Senior User'
            )
        };

        List<ContactOrganizerController.RelationshipMapInput> inputs =
            new List<ContactOrganizerController.RelationshipMapInput>();
        ContactOrganizerController.RelationshipMapInput a = new ContactOrganizerController.RelationshipMapInput();
        a.contactId = contacts[0].Id;
        a.role = 'C-Suite/Executive';
        inputs.add(a);

        Test.startTest();
        ContactOrganizerController.saveAssignments(opp.Id, inputs);
        Test.stopTest();

        List<Relationship_Map__c> remaining = [
            SELECT Contact__c, Role__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, remaining.size());
        System.assertEquals(contacts[0].Id, remaining[0].Contact__c);
        System.assertEquals('C-Suite/Executive', remaining[0].Role__c);
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
