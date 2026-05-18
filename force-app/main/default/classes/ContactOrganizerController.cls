public with sharing class ContactOrganizerController {

    private static final Set<String> VALID_ROLES = new Set<String>{
        'C-Suite/Executive',
        'Technology/Ops',
        'Senior User',
        'Junior User'
    };

    private static final Integer SEARCH_LIMIT = 50;

    public class OrganizerData {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Integer totalContacts;
        @AuraEnabled public List<AssignmentWrapper> assignments;
        @AuraEnabled public AccountSummary summary;
    }

    public class AccountSummary {
        @AuraEnabled public Integer totalActivities = 0;
        @AuraEnabled public Integer activitiesLast7d = 0;
        @AuraEnabled public Integer activitiesLast30d = 0;
        @AuraEnabled public Integer engagedContacts = 0;
        @AuraEnabled public Date lastActivityDate;
    }

    public class AssignmentWrapper {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean isChampion;
        @AuraEnabled public ActivityStats activity;
    }

    public class ContactWrapper {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;
        @AuraEnabled public ActivityStats activity;
    }

    public class ActivityStats {
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer last7d = 0;
        @AuraEnabled public Integer last30d = 0;
        @AuraEnabled public Integer emails = 0;
        @AuraEnabled public Integer meetings = 0;
        @AuraEnabled public Integer gongCalls = 0;
        @AuraEnabled public Date lastActivityDate;
    }

    public class RelationshipMapInput {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean isChampion;
    }

    @AuraEnabled(cacheable=true)
    public static OrganizerData loadOrganizer(Id opportunityId) {
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }

        List<Opportunity> opps = [
            SELECT Id, AccountId, Account.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found.');
        }
        Opportunity opp = opps[0];

        OrganizerData data = new OrganizerData();
        data.opportunityId = opp.Id;
        data.accountId = opp.AccountId;
        data.accountName = opp.Account != null ? opp.Account.Name : null;
        data.assignments = new List<AssignmentWrapper>();
        data.totalContacts = 0;
        data.summary = new AccountSummary();

        if (opp.AccountId == null) {
            return data;
        }

        data.totalContacts = [SELECT COUNT() FROM Contact WHERE AccountId = :opp.AccountId];

        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Contact__r.Name, Contact__r.Title, Contact__r.Email,
                   Role__c, Champion__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            AssignmentWrapper a = new AssignmentWrapper();
            a.contactId = rm.Contact__c;
            a.name = rm.Contact__r != null ? rm.Contact__r.Name : null;
            a.title = rm.Contact__r != null ? rm.Contact__r.Title : null;
            a.email = rm.Contact__r != null ? rm.Contact__r.Email : null;
            a.role = rm.Role__c;
            a.isChampion = rm.Champion__c;
            a.activity = new ActivityStats();
            data.assignments.add(a);
        }

        // Per-assignment activity stats
        if (!data.assignments.isEmpty()) {
            Set<Id> contactIds = new Set<Id>();
            for (AssignmentWrapper a : data.assignments) contactIds.add(a.contactId);
            Map<Id, ActivityStats> statsByContact = getActivityStats(contactIds, opp.AccountId, opportunityId);
            for (AssignmentWrapper a : data.assignments) {
                ActivityStats s = statsByContact.get(a.contactId);
                if (s != null) a.activity = s;
            }
        }

        data.summary = getAccountSummary(opp.AccountId, opportunityId);

        return data;
    }

    @AuraEnabled
    public static List<ContactWrapper> searchAccountContacts(Id accountId, Id opportunityId, String searchTerm, List<Id> excludeIds) {
        List<ContactWrapper> results = new List<ContactWrapper>();
        if (accountId == null) {
            return results;
        }
        Set<Id> excludeSet = new Set<Id>();
        if (excludeIds != null) {
            excludeSet.addAll(excludeIds);
        }
        Boolean hasExcludes = !excludeSet.isEmpty();
        Boolean hasTerm = String.isNotBlank(searchTerm);
        String term = hasTerm ? '%' + searchTerm.trim() + '%' : null;

        List<Contact> rows;
        if (hasTerm && hasExcludes) {
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                  AND Id NOT IN :excludeSet
                  AND (Name LIKE :term OR Title LIKE :term OR Email LIKE :term)
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        } else if (hasTerm) {
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                  AND (Name LIKE :term OR Title LIKE :term OR Email LIKE :term)
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        } else if (hasExcludes) {
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                  AND Id NOT IN :excludeSet
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        } else {
            rows = [
                SELECT Id, Name, Title, Email
                FROM Contact
                WHERE AccountId = :accountId
                ORDER BY Name ASC
                LIMIT :SEARCH_LIMIT
            ];
        }

        Set<Id> contactIds = new Set<Id>();
        for (Contact c : rows) contactIds.add(c.Id);
        Map<Id, ActivityStats> statsByContact = getActivityStats(contactIds, accountId, opportunityId);

        for (Contact c : rows) {
            ContactWrapper w = new ContactWrapper();
            w.id = c.Id;
            w.name = c.Name;
            w.title = c.Title;
            w.email = c.Email;
            w.activity = statsByContact.containsKey(c.Id) ? statsByContact.get(c.Id) : new ActivityStats();
            results.add(w);
        }
        return results;
    }

    @AuraEnabled
    public static void saveAssignments(Id opportunityId, List<RelationshipMapInput> assignments) {
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }
        if (assignments == null) {
            assignments = new List<RelationshipMapInput>();
        }

        List<Opportunity> opps = [
            SELECT Id, AccountId
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('Opportunity not found.');
        }
        Id accountId = opps[0].AccountId;
        if (accountId == null) {
            throw new AuraHandledException('Opportunity has no Account.');
        }

        Map<Id, RelationshipMapInput> desired = new Map<Id, RelationshipMapInput>();
        for (RelationshipMapInput input : assignments) {
            if (input.contactId == null || String.isBlank(input.role)) {
                continue;
            }
            if (!VALID_ROLES.contains(input.role)) {
                throw new AuraHandledException('Invalid role: ' + input.role);
            }
            if (input.isChampion == null) {
                input.isChampion = false;
            }
            desired.put(input.contactId, input);
        }

        Map<Id, Relationship_Map__c> existingByContact = new Map<Id, Relationship_Map__c>();
        for (Relationship_Map__c rm : [
            SELECT Id, Contact__c, Role__c, Champion__c
            FROM Relationship_Map__c
            WHERE Opportunity__c = :opportunityId
        ]) {
            existingByContact.put(rm.Contact__c, rm);
        }

        List<Relationship_Map__c> toInsert = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toUpdate = new List<Relationship_Map__c>();
        List<Relationship_Map__c> toDelete = new List<Relationship_Map__c>();

        for (Id contactId : desired.keySet()) {
            RelationshipMapInput input = desired.get(contactId);
            Relationship_Map__c existing = existingByContact.get(contactId);
            if (existing == null) {
                toInsert.add(new Relationship_Map__c(
                    Contact__c = contactId,
                    Account__c = accountId,
                    Opportunity__c = opportunityId,
                    Role__c = input.role,
                    Champion__c = input.isChampion
                ));
            } else {
                Boolean changed = false;
                if (existing.Role__c != input.role) {
                    existing.Role__c = input.role;
                    changed = true;
                }
                if (existing.Champion__c != input.isChampion) {
                    existing.Champion__c = input.isChampion;
                    changed = true;
                }
                if (changed) {
                    toUpdate.add(existing);
                }
            }
        }

        for (Id contactId : existingByContact.keySet()) {
            if (!desired.containsKey(contactId)) {
                toDelete.add(existingByContact.get(contactId));
            }
        }

        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate;
        if (!toDelete.isEmpty()) delete toDelete;
    }

    // ── Activity rollup helpers ──────────────────────────────────────────

    private static Map<Id, ActivityStats> getActivityStats(Set<Id> contactIds, Id accountId, Id opportunityId) {
        Map<Id, ActivityStats> result = new Map<Id, ActivityStats>();
        if (contactIds == null || contactIds.isEmpty() || accountId == null) {
            return result;
        }
        for (Id cid : contactIds) {
            result.put(cid, new ActivityStats());
        }

        Date today = Date.today();
        Date cutoff7 = today.addDays(-7);
        Date cutoff30 = today.addDays(-30);

        // Tasks (emails, calls, completed activities)
        List<Task> tasks;
        if (opportunityId != null) {
            tasks = [
                SELECT WhoId, ActivityDate, TaskSubtype, CreatedDate
                FROM Task
                WHERE WhoId IN :contactIds
                  AND Status = 'Completed'
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 5000
            ];
        } else {
            tasks = [
                SELECT WhoId, ActivityDate, TaskSubtype, CreatedDate
                FROM Task
                WHERE WhoId IN :contactIds
                  AND Status = 'Completed'
                  AND AccountId = :accountId
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 5000
            ];
        }
        for (Task t : tasks) {
            ActivityStats s = result.get(t.WhoId);
            if (s == null) continue;
            Date d = t.ActivityDate != null
                ? t.ActivityDate
                : (t.CreatedDate != null ? t.CreatedDate.date() : null);
            Boolean isEmail = (t.TaskSubtype == 'Email' || t.TaskSubtype == 'ListEmail');
            applyActivity(s, d, cutoff7, cutoff30, isEmail, false, false);
        }

        // Events (meetings)
        List<Event> events;
        if (opportunityId != null) {
            events = [
                SELECT WhoId, ActivityDate, StartDateTime
                FROM Event
                WHERE WhoId IN :contactIds
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 5000
            ];
        } else {
            events = [
                SELECT WhoId, ActivityDate, StartDateTime
                FROM Event
                WHERE WhoId IN :contactIds
                  AND AccountId = :accountId
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 5000
            ];
        }
        for (Event e : events) {
            ActivityStats s = result.get(e.WhoId);
            if (s == null) continue;
            Date d = e.ActivityDate != null
                ? e.ActivityDate
                : (e.StartDateTime != null ? e.StartDateTime.date() : null);
            applyActivity(s, d, cutoff7, cutoff30, false, true, false);
        }

        // Gong calls
        List<Gong__Call_Participant__c> gongs;
        if (opportunityId != null) {
            gongs = [
                SELECT Gong__Contact_Participant__c, Gong__Gong_Call__r.Gong__Call_Start__c
                FROM Gong__Call_Participant__c
                WHERE Gong__Contact_Participant__c IN :contactIds
                  AND Gong__Affiliation__c = 'External'
                  AND Gong__Gong_Call__r.Gong__Primary_Opportunity__c = :opportunityId
                LIMIT 3000
            ];
        } else {
            gongs = [
                SELECT Gong__Contact_Participant__c, Gong__Gong_Call__r.Gong__Call_Start__c
                FROM Gong__Call_Participant__c
                WHERE Gong__Contact_Participant__c IN :contactIds
                  AND Gong__Affiliation__c = 'External'
                  AND Gong__Gong_Call__r.Gong__Primary_Account__c = :accountId
                LIMIT 3000
            ];
        }
        for (Gong__Call_Participant__c gp : gongs) {
            ActivityStats s = result.get(gp.Gong__Contact_Participant__c);
            if (s == null) continue;
            DateTime callStart = gp.Gong__Gong_Call__r != null ? gp.Gong__Gong_Call__r.Gong__Call_Start__c : null;
            Date d = callStart != null ? callStart.date() : null;
            applyActivity(s, d, cutoff7, cutoff30, false, false, true);
        }

        return result;
    }

    private static void applyActivity(
        ActivityStats s,
        Date d,
        Date cutoff7,
        Date cutoff30,
        Boolean isEmail,
        Boolean isMeeting,
        Boolean isGong
    ) {
        s.total++;
        if (isEmail) s.emails++;
        if (isMeeting) s.meetings++;
        if (isGong) s.gongCalls++;
        if (d != null) {
            if (d >= cutoff7) s.last7d++;
            if (d >= cutoff30) s.last30d++;
            if (s.lastActivityDate == null || d > s.lastActivityDate) {
                s.lastActivityDate = d;
            }
        }
    }

    private static AccountSummary getAccountSummary(Id accountId, Id opportunityId) {
        AccountSummary out = new AccountSummary();
        if (accountId == null) return out;

        Date today = Date.today();
        Date cutoff7 = today.addDays(-7);
        Date cutoff30 = today.addDays(-30);

        // Totals + last activity date
        Integer taskTotal;
        Integer eventTotal;
        Integer gongTotal;
        Date taskMax;
        Date eventMax;
        DateTime gongMax;

        if (opportunityId != null) {
            AggregateResult ta = [
                SELECT COUNT(Id) total, MAX(ActivityDate) lastDate
                FROM Task
                WHERE Status = 'Completed'
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
            ];
            taskTotal = (Integer) ta.get('total');
            taskMax = (Date) ta.get('lastDate');

            AggregateResult ea = [
                SELECT COUNT(Id) total, MAX(ActivityDate) lastDate
                FROM Event
                WHERE (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
            ];
            eventTotal = (Integer) ea.get('total');
            eventMax = (Date) ea.get('lastDate');

            AggregateResult ga = [
                SELECT COUNT(Id) total, MAX(Gong__Gong_Call__r.Gong__Call_Start__c) lastDate
                FROM Gong__Call_Participant__c
                WHERE Gong__Affiliation__c = 'External'
                  AND Gong__Contact_Participant__c != null
                  AND Gong__Gong_Call__r.Gong__Primary_Opportunity__c = :opportunityId
            ];
            gongTotal = (Integer) ga.get('total');
            gongMax = (DateTime) ga.get('lastDate');

            out.activitiesLast7d =
                [SELECT COUNT() FROM Task
                  WHERE Status = 'Completed' AND ActivityDate >= :cutoff7
                  AND (WhatId = :opportunityId OR WhatId = :accountId) AND WhoId != null]
                + [SELECT COUNT() FROM Event
                  WHERE ActivityDate >= :cutoff7
                  AND (WhatId = :opportunityId OR WhatId = :accountId) AND WhoId != null];
            out.activitiesLast30d =
                [SELECT COUNT() FROM Task
                  WHERE Status = 'Completed' AND ActivityDate >= :cutoff30
                  AND (WhatId = :opportunityId OR WhatId = :accountId) AND WhoId != null]
                + [SELECT COUNT() FROM Event
                  WHERE ActivityDate >= :cutoff30
                  AND (WhatId = :opportunityId OR WhatId = :accountId) AND WhoId != null];
        } else {
            AggregateResult ta = [
                SELECT COUNT(Id) total, MAX(ActivityDate) lastDate
                FROM Task
                WHERE Status = 'Completed' AND AccountId = :accountId AND WhoId != null
            ];
            taskTotal = (Integer) ta.get('total');
            taskMax = (Date) ta.get('lastDate');

            AggregateResult ea = [
                SELECT COUNT(Id) total, MAX(ActivityDate) lastDate
                FROM Event
                WHERE AccountId = :accountId AND WhoId != null
            ];
            eventTotal = (Integer) ea.get('total');
            eventMax = (Date) ea.get('lastDate');

            AggregateResult ga = [
                SELECT COUNT(Id) total, MAX(Gong__Gong_Call__r.Gong__Call_Start__c) lastDate
                FROM Gong__Call_Participant__c
                WHERE Gong__Affiliation__c = 'External'
                  AND Gong__Contact_Participant__c != null
                  AND Gong__Gong_Call__r.Gong__Primary_Account__c = :accountId
            ];
            gongTotal = (Integer) ga.get('total');
            gongMax = (DateTime) ga.get('lastDate');

            out.activitiesLast7d =
                [SELECT COUNT() FROM Task
                  WHERE Status = 'Completed' AND ActivityDate >= :cutoff7
                  AND AccountId = :accountId AND WhoId != null]
                + [SELECT COUNT() FROM Event
                  WHERE ActivityDate >= :cutoff7
                  AND AccountId = :accountId AND WhoId != null];
            out.activitiesLast30d =
                [SELECT COUNT() FROM Task
                  WHERE Status = 'Completed' AND ActivityDate >= :cutoff30
                  AND AccountId = :accountId AND WhoId != null]
                + [SELECT COUNT() FROM Event
                  WHERE ActivityDate >= :cutoff30
                  AND AccountId = :accountId AND WhoId != null];
        }

        out.totalActivities =
            (taskTotal != null ? taskTotal : 0)
            + (eventTotal != null ? eventTotal : 0)
            + (gongTotal != null ? gongTotal : 0);

        Date gongMaxDate = gongMax != null ? gongMax.date() : null;
        for (Date candidate : new List<Date>{ taskMax, eventMax, gongMaxDate }) {
            if (candidate != null && (out.lastActivityDate == null || candidate > out.lastActivityDate)) {
                out.lastActivityDate = candidate;
            }
        }

        // Engaged contacts: distinct contacts with any activity (deduped across sources)
        Set<Id> engagedContactIds = new Set<Id>();
        if (opportunityId != null) {
            for (AggregateResult ar : [
                SELECT WhoId
                FROM Task
                WHERE Status = 'Completed' AND WhoId != null
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                GROUP BY WhoId
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('WhoId'));
            for (AggregateResult ar : [
                SELECT WhoId
                FROM Event
                WHERE WhoId != null
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                GROUP BY WhoId
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('WhoId'));
            for (AggregateResult ar : [
                SELECT Gong__Contact_Participant__c cid
                FROM Gong__Call_Participant__c
                WHERE Gong__Affiliation__c = 'External'
                  AND Gong__Contact_Participant__c != null
                  AND Gong__Gong_Call__r.Gong__Primary_Opportunity__c = :opportunityId
                GROUP BY Gong__Contact_Participant__c
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('cid'));
        } else {
            for (AggregateResult ar : [
                SELECT WhoId
                FROM Task
                WHERE Status = 'Completed' AND WhoId != null
                  AND AccountId = :accountId
                GROUP BY WhoId
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('WhoId'));
            for (AggregateResult ar : [
                SELECT WhoId
                FROM Event
                WHERE WhoId != null
                  AND AccountId = :accountId
                GROUP BY WhoId
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('WhoId'));
            for (AggregateResult ar : [
                SELECT Gong__Contact_Participant__c cid
                FROM Gong__Call_Participant__c
                WHERE Gong__Affiliation__c = 'External'
                  AND Gong__Contact_Participant__c != null
                  AND Gong__Gong_Call__r.Gong__Primary_Account__c = :accountId
                GROUP BY Gong__Contact_Participant__c
                LIMIT 10000
            ]) engagedContactIds.add((Id) ar.get('cid'));
        }
        out.engagedContacts = engagedContactIds.size();

        return out;
    }
}
