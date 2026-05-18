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
    static void getContactDetailThrowsWhenContactNull() {
        Boolean threw = false;
        try {
            ContactOrganizerController.getContactDetail(null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected exception for null Contact Id');
    }

    @isTest
    static void getContactDetailBuildsTimelineAndStats() {
        Opportunity opp = setupOppWithContacts(1);
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId LIMIT 1];

        insert new Task(
            WhoId = c.Id, WhatId = opp.Id, Status = 'Completed',
            Subject = 'Intro email', TaskSubtype = 'Email',
            ActivityDate = Date.today().addDays(-3)
        );
        insert new Event(
            WhoId = c.Id, WhatId = opp.Id,
            Subject = 'Discovery',
            ActivityDateTime = DateTime.now().addDays(-2), DurationInMinutes = 30
        );

        Test.startTest();
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(opp.Id, c.Id);
        Test.stopTest();

        System.assertEquals(c.Id, detail.contactId);
        System.assertNotEquals(null, detail.stats);
        System.assertEquals(2, detail.stats.total);
        System.assertEquals(1, detail.stats.emails);
        System.assertEquals(1, detail.stats.meetings);
        System.assertEquals(2, detail.timeline.size());
        // Sorted desc — event (-2) should come before task (-3)
        System.assertEquals('Meeting', detail.timeline[0].type);
        System.assertEquals('Email', detail.timeline[1].type);
    }

    @isTest
    static void getContactDetailReturnsEmptyWhenNoAccount() {
        Contact c = new Contact(LastName = 'Orphan');
        insert c;
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(null, c.Id);
        System.assertEquals(c.Id, detail.contactId);
        System.assertEquals(0, detail.stats.total);
        System.assertEquals(0, detail.timeline.size());
    }

    @isTest
    static void getContactDetailParsesGongInsights() {
        Opportunity opp = setupOppWithContacts(1);
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId LIMIT 1];

        // Topics: includes filter-worthy entries that should be skipped
        String topicsJson =
            '[' +
            '{"Name":"Pricing"},' +
            '{"Name":"Call Setup"},' +
            '{"Name":"Competitors"},' +
            '{"Name":"[SMART] Internal"},' +
            '{"Name":"Wrap-Up"}' +
            ']';
        // Trackers: [SMART] prefix should be stripped + merged with the plain name
        String trackersJson =
            '[' +
            '{"Name":"Pricing","Gong__Tracker_Occurrences__c":3,"Gong__Tracker_Phrase__c":"discounts"},' +
            '{"Name":"[SMART] Pricing","Gong__Tracker_Occurrences__c":2,"Gong__Tracker_Phrase__c":"-"},' +
            '{"Name":"Competitor","Gong__Tracker_Occurrences__c":5,"Gong__Tracker_Phrase__c":"alternative"}' +
            ']';
        String keyPointsHtml =
            '<p>1. Customer is interested in upsell to enterprise tier.<br>' +
            '2. Budget approval expected within Q2.<br>' +
            '3. Two competitors evaluated, ours is preferred.</p>';

        Gong__Gong_Call__c call = new Gong__Gong_Call__c(
            Gong__Call_ID__c = 'test-call-001',
            Gong__Call_Start__c = DateTime.now().addDays(-4),
            Gong__Call_Brief__c = 'Productive call covering pricing and competitive positioning.',
            Gong__Call_Key_Points__c = keyPointsHtml,
            Gong__Call_Highlights_Next_Steps__c = 'Send proposal, schedule technical deep-dive.',
            Gong__Related_Topics_json__c = topicsJson,
            Gong__Related_Trackers_json__c = trackersJson,
            Gong__Primary_Opportunity__c = opp.Id,
            Gong__Primary_Account__c = opp.AccountId
        );
        insert call;

        insert new Gong__Call_Participant__c(
            Gong__Gong_Call__c = call.Id,
            Gong__Contact_Participant__c = c.Id,
            Gong__Affiliation__c = 'External'
        );

        Test.startTest();
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(opp.Id, c.Id);
        Test.stopTest();

        // Topic filtering: Call Setup, Wrap-Up, and the [SMART]-prefixed
        // entry should be excluded
        System.assertEquals(2, detail.gongTopics.size(), 'Filtered topics: ' + detail.gongTopics);
        System.assert(detail.gongTopics.contains('Pricing'));
        System.assert(detail.gongTopics.contains('Competitors'));

        // Tracker merging: [SMART] Pricing → Pricing (occurrences 3 + 2 = 5)
        Map<String, ContactOrganizerController.TrackerInsight> byName =
            new Map<String, ContactOrganizerController.TrackerInsight>();
        for (ContactOrganizerController.TrackerInsight ti : detail.gongTrackers) {
            byName.put(ti.name, ti);
        }
        System.assertEquals(2, byName.size());
        System.assertEquals(5, byName.get('Pricing').occurrences);
        System.assertEquals('discounts', byName.get('Pricing').phrase);
        System.assertEquals(5, byName.get('Competitor').occurrences);

        // Key points: HTML tags stripped, list-prefix removed, 3 points
        System.assertEquals(3, detail.gongKeyPoints.size());
        System.assert(detail.gongKeyPoints[0].startsWith('Customer is interested'));

        // Brief + next steps set on the latest call
        System.assertNotEquals(null, detail.gongLatestBrief);
        System.assertNotEquals(null, detail.gongLatestNextSteps);
        System.assertEquals(Date.today().addDays(-4), detail.gongLatestCallDate);
    }

    @isTest
    static void getContactDetailParsesGranolaNote() {
        Opportunity opp = setupOppWithContacts(1);
        Contact c = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId LIMIT 1];

        String description =
            'Granola Link: https://example.com/note/abc\n' +
            '── Granola Generated Notes ──\n' +
            '### Discussion Highlights\n' +
            '- Customer happy with implementation pace.\n' +
            '- Concerns about scaling beyond 50 users.\n' +
            '### Risks\n' +
            '- Procurement timeline tightening.\n' +
            '### Action Items\n' +
            '- AE: Share enterprise pricing sheet by Wednesday.\n' +
            '- CSM: Set up quarterly business review.\n' +
            '- Customer: Identify executive sponsor.\n';

        insert new Event(
            WhoId = c.Id,
            WhatId = opp.Id,
            Subject = 'Granola - Weekly Sync',
            Description = description,
            ActivityDateTime = DateTime.now().addDays(-1),
            DurationInMinutes = 30
        );

        Test.startTest();
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(opp.Id, c.Id);
        Test.stopTest();

        // Topics: Discussion Highlights and Risks (Action Items excluded)
        System.assertEquals(2, detail.granolaTopics.size());
        System.assert(detail.granolaTopics.contains('Discussion Highlights'));
        System.assert(detail.granolaTopics.contains('Risks'));

        // Action items: 3 captured
        System.assertEquals(3, detail.granolaActionItems.size());
        System.assert(detail.granolaActionItems[0].startsWith('AE:'));

        // Summary: captured from first section bullets
        System.assertNotEquals(null, detail.granolaLatestSummary);
        System.assert(detail.granolaLatestSummary.contains('Customer happy'));
        System.assertEquals(Date.today().addDays(-1), detail.granolaLatestDate);
    }

    @isTest
    static void getContactDetailGranolaViaEventRelation() {
        Opportunity opp = setupOppWithContacts(2);
        List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :opp.AccountId ORDER BY LastName];
        Contact primary = contacts[0];
        Contact extra = contacts[1];

        // Granola event whose WhoId is the primary contact; extra contact
        // attends via EventRelation only.
        Event granolaEvent = new Event(
            WhoId = primary.Id,
            WhatId = opp.Id,
            Subject = 'Granola - Group Call',
            Description = 'Granola Link: x\n### Topic A\n- Discussed roadmap.\n### Action Items\n- Follow up next week.\n',
            ActivityDateTime = DateTime.now().addDays(-2),
            DurationInMinutes = 60
        );
        insert granolaEvent;
        insert new EventRelation(
            EventId = granolaEvent.Id,
            RelationId = extra.Id,
            IsWhat = false
        );

        Test.startTest();
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(opp.Id, extra.Id);
        Test.stopTest();

        System.assert(
            detail.granolaTopics.contains('Topic A'),
            'Extra contact should see Granola insights via EventRelation: ' + detail.granolaTopics
        );
        System.assert(detail.granolaActionItems.size() > 0);
    }

    @isTest
    static void getContactDetailAccountOnlyBranches() {
        // Exercise the else (accountId-only) branches in
        // enrichContactWithGong / enrichContactWithGranola by calling
        // getContactDetail with opportunityId = null.
        Account acc = new Account(Name = 'Account-Only Test');
        insert acc;
        Contact c = new Contact(LastName = 'Solo', AccountId = acc.Id);
        insert c;

        Gong__Gong_Call__c call = new Gong__Gong_Call__c(
            Gong__Call_ID__c = 'account-only-call',
            Gong__Call_Start__c = DateTime.now().addDays(-1),
            Gong__Related_Topics_json__c = '[{"Name":"Renewal"}]',
            Gong__Primary_Account__c = acc.Id
        );
        insert call;
        insert new Gong__Call_Participant__c(
            Gong__Gong_Call__c = call.Id,
            Gong__Contact_Participant__c = c.Id,
            Gong__Affiliation__c = 'External'
        );

        insert new Event(
            WhoId = c.Id,
            WhatId = acc.Id,
            Subject = 'Granola - Solo Sync',
            Description = '### Renewal Plan\n- Confirm budget.\n### Action Items\n- Send pricing.\n',
            ActivityDateTime = DateTime.now().addDays(-1),
            DurationInMinutes = 15
        );

        Test.startTest();
        ContactOrganizerController.ContactDetail detail =
            ContactOrganizerController.getContactDetail(null, c.Id);
        Test.stopTest();

        System.assert(detail.gongTopics.contains('Renewal'));
        System.assert(detail.granolaTopics.contains('Renewal Plan'));
        System.assertEquals(1, detail.granolaActionItems.size());
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
