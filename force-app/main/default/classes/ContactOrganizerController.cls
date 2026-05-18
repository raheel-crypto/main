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

    public class ContactDetail {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String email;
        @AuraEnabled public ActivityStats stats;
        @AuraEnabled public List<TimelineItem> timeline;
        @AuraEnabled public List<String> gongTopics;
        @AuraEnabled public List<TrackerInsight> gongTrackers;
        @AuraEnabled public List<String> gongKeyPoints;
        @AuraEnabled public String gongLatestBrief;
        @AuraEnabled public String gongLatestNextSteps;
        @AuraEnabled public Date gongLatestCallDate;
        @AuraEnabled public List<String> granolaTopics;
        @AuraEnabled public List<String> granolaActionItems;
        @AuraEnabled public String granolaLatestSummary;
        @AuraEnabled public Date granolaLatestDate;
    }

    public class TimelineItem {
        @AuraEnabled public String type;
        @AuraEnabled public Date activityDate;
        @AuraEnabled public String subject;
    }

    public class TrackerInsight {
        @AuraEnabled public String name;
        @AuraEnabled public String phrase;
        @AuraEnabled public Integer occurrences;
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

    public class SaveResult {
        @AuraEnabled public Integer inserted = 0;
        @AuraEnabled public Integer updated = 0;
        @AuraEnabled public Integer deleted = 0;
        @AuraEnabled public Integer received = 0;
        @AuraEnabled public Integer skipped = 0;
    }

    @AuraEnabled
    public static SaveResult saveAssignments(Id opportunityId, String assignmentsJson) {
        SaveResult outcome = new SaveResult();
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }

        List<RelationshipMapInput> assignments;
        try {
            if (String.isBlank(assignmentsJson)) {
                assignments = new List<RelationshipMapInput>();
            } else {
                assignments = (List<RelationshipMapInput>) JSON.deserialize(
                    assignmentsJson, List<RelationshipMapInput>.class
                );
            }
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse assignments: ' + e.getMessage());
        }
        if (assignments == null) {
            assignments = new List<RelationshipMapInput>();
        }
        outcome.received = assignments.size();

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
                outcome.skipped++;
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

        outcome.inserted = toInsert.size();
        outcome.updated = toUpdate.size();
        outcome.deleted = toDelete.size();
        return outcome;
    }

    // ── Per-contact detail (popup) ───────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static ContactDetail getContactDetail(Id opportunityId, Id contactId) {
        if (contactId == null) {
            throw new AuraHandledException('Contact Id is required.');
        }

        List<Contact> contacts = [
            SELECT Id, Name, Title, Email, AccountId
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new AuraHandledException('Contact not found.');
        }
        Contact c = contacts[0];

        ContactDetail detail = new ContactDetail();
        detail.contactId = c.Id;
        detail.name = c.Name;
        detail.title = c.Title;
        detail.email = c.Email;
        detail.timeline = new List<TimelineItem>();
        detail.gongTopics = new List<String>();
        detail.gongTrackers = new List<TrackerInsight>();
        detail.gongKeyPoints = new List<String>();
        detail.granolaTopics = new List<String>();
        detail.granolaActionItems = new List<String>();
        detail.stats = new ActivityStats();

        Id accountId = c.AccountId;
        if (accountId == null) return detail;

        Set<Id> oneId = new Set<Id>{ contactId };
        Map<Id, ActivityStats> statsMap = getActivityStats(oneId, accountId, opportunityId);
        if (statsMap.containsKey(contactId)) detail.stats = statsMap.get(contactId);

        detail.timeline = buildContactTimeline(contactId, accountId, opportunityId);
        enrichContactWithGong(detail, contactId, accountId, opportunityId);
        enrichContactWithGranola(detail, contactId, accountId, opportunityId);

        return detail;
    }

    private static List<TimelineItem> buildContactTimeline(Id contactId, Id accountId, Id opportunityId) {
        List<TimelineItem> items = new List<TimelineItem>();

        List<Task> tasks;
        if (opportunityId != null) {
            tasks = [
                SELECT ActivityDate, Subject, TaskSubtype, CreatedDate
                FROM Task
                WHERE WhoId = :contactId
                  AND Status = 'Completed'
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 20
            ];
        } else {
            tasks = [
                SELECT ActivityDate, Subject, TaskSubtype, CreatedDate
                FROM Task
                WHERE WhoId = :contactId
                  AND Status = 'Completed'
                  AND AccountId = :accountId
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 20
            ];
        }
        for (Task t : tasks) {
            TimelineItem it = new TimelineItem();
            it.activityDate = t.ActivityDate != null
                ? t.ActivityDate
                : (t.CreatedDate != null ? t.CreatedDate.date() : null);
            it.subject = t.Subject;
            it.type = (t.TaskSubtype == 'Email' || t.TaskSubtype == 'ListEmail')
                ? 'Email'
                : (t.TaskSubtype != null ? t.TaskSubtype : 'Task');
            items.add(it);
        }

        List<Event> events;
        if (opportunityId != null) {
            events = [
                SELECT ActivityDate, Subject, StartDateTime
                FROM Event
                WHERE WhoId = :contactId
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 20
            ];
        } else {
            events = [
                SELECT ActivityDate, Subject, StartDateTime
                FROM Event
                WHERE WhoId = :contactId
                  AND AccountId = :accountId
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 20
            ];
        }
        for (Event e : events) {
            TimelineItem it = new TimelineItem();
            it.activityDate = e.ActivityDate != null
                ? e.ActivityDate
                : (e.StartDateTime != null ? e.StartDateTime.date() : null);
            it.subject = e.Subject;
            it.type = 'Meeting';
            items.add(it);
        }

        // Sort merged list by date desc, return top 15
        for (Integer i = 0; i < items.size(); i++) {
            for (Integer j = i + 1; j < items.size(); j++) {
                Date di = items[i].activityDate;
                Date dj = items[j].activityDate;
                Boolean jWins = (di == null && dj != null) || (di != null && dj != null && dj > di);
                if (jWins) {
                    TimelineItem tmp = items[i];
                    items[i] = items[j];
                    items[j] = tmp;
                }
            }
        }
        if (items.size() > 15) {
            List<TimelineItem> trimmed = new List<TimelineItem>();
            for (Integer i = 0; i < 15; i++) trimmed.add(items[i]);
            items = trimmed;
        }
        return items;
    }

    private static void enrichContactWithGong(ContactDetail detail, Id contactId, Id accountId, Id opportunityId) {
        List<Gong__Call_Participant__c> participants;
        if (opportunityId != null) {
            participants = [
                SELECT Gong__Gong_Call__r.Gong__Call_Start__c,
                       Gong__Gong_Call__r.Gong__Call_Brief__c,
                       Gong__Gong_Call__r.Gong__Call_Key_Points__c,
                       Gong__Gong_Call__r.Gong__Call_Highlights_Next_Steps__c,
                       Gong__Gong_Call__r.Gong__Related_Topics_json__c,
                       Gong__Gong_Call__r.Gong__Related_Trackers_json__c
                FROM Gong__Call_Participant__c
                WHERE Gong__Contact_Participant__c = :contactId
                  AND Gong__Affiliation__c = 'External'
                  AND (Gong__Gong_Call__r.Gong__Primary_Account__c = :accountId
                       OR Gong__Gong_Call__r.Gong__Primary_Opportunity__c = :opportunityId)
                ORDER BY Gong__Gong_Call__r.Gong__Call_Start__c DESC NULLS LAST
                LIMIT 100
            ];
        } else {
            participants = [
                SELECT Gong__Gong_Call__r.Gong__Call_Start__c,
                       Gong__Gong_Call__r.Gong__Call_Brief__c,
                       Gong__Gong_Call__r.Gong__Call_Key_Points__c,
                       Gong__Gong_Call__r.Gong__Call_Highlights_Next_Steps__c,
                       Gong__Gong_Call__r.Gong__Related_Topics_json__c,
                       Gong__Gong_Call__r.Gong__Related_Trackers_json__c
                FROM Gong__Call_Participant__c
                WHERE Gong__Contact_Participant__c = :contactId
                  AND Gong__Affiliation__c = 'External'
                  AND Gong__Gong_Call__r.Gong__Primary_Account__c = :accountId
                ORDER BY Gong__Gong_Call__r.Gong__Call_Start__c DESC NULLS LAST
                LIMIT 100
            ];
        }

        Set<String> topicSeen = new Set<String>();
        Map<String, TrackerInsight> trackerByName = new Map<String, TrackerInsight>();
        for (Gong__Call_Participant__c gp : participants) {
            if (gp.Gong__Gong_Call__r == null) continue;
            DateTime callStart = gp.Gong__Gong_Call__r.Gong__Call_Start__c;
            Date callDate = callStart != null ? callStart.date() : null;

            // Latest call fields go first in result order
            if (detail.gongLatestCallDate == null && callDate != null) {
                detail.gongLatestCallDate = callDate;
                detail.gongLatestBrief = decodeHtml(gp.Gong__Gong_Call__r.Gong__Call_Brief__c);
                detail.gongLatestNextSteps = decodeHtml(gp.Gong__Gong_Call__r.Gong__Call_Highlights_Next_Steps__c);
                detail.gongKeyPoints = parseKeyPoints(gp.Gong__Gong_Call__r.Gong__Call_Key_Points__c, 6);
            }

            for (String t : parseTopics(gp.Gong__Gong_Call__r.Gong__Related_Topics_json__c)) {
                if (!topicSeen.contains(t)) {
                    topicSeen.add(t);
                    detail.gongTopics.add(t);
                }
            }
            mergeTrackers(trackerByName, gp.Gong__Gong_Call__r.Gong__Related_Trackers_json__c);
        }
        detail.gongTrackers = sortedTrackers(trackerByName);
        if (detail.gongTopics.size() > 12) {
            List<String> trimmed = new List<String>();
            for (Integer i = 0; i < 12; i++) trimmed.add(detail.gongTopics[i]);
            detail.gongTopics = trimmed;
        }
        if (detail.gongTrackers.size() > 8) {
            List<TrackerInsight> trimmed = new List<TrackerInsight>();
            for (Integer i = 0; i < 8; i++) trimmed.add(detail.gongTrackers[i]);
            detail.gongTrackers = trimmed;
        }
    }

    private static void enrichContactWithGranola(ContactDetail detail, Id contactId, Id accountId, Id opportunityId) {
        Date lookback = Date.today().addDays(-180);
        List<Event> granolaEvents;
        if (opportunityId != null) {
            granolaEvents = [
                SELECT Id, ActivityDate, Description, Subject
                FROM Event
                WHERE WhoId = :contactId
                  AND Subject LIKE '%Granola%'
                  AND ActivityDate >= :lookback
                  AND (WhatId = :opportunityId OR WhatId = :accountId OR AccountId = :accountId)
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 30
            ];
        } else {
            granolaEvents = [
                SELECT Id, ActivityDate, Description, Subject
                FROM Event
                WHERE WhoId = :contactId
                  AND Subject LIKE '%Granola%'
                  AND ActivityDate >= :lookback
                  AND AccountId = :accountId
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 30
            ];
        }
        // Also pull in Granola events via EventRelation
        Set<Id> seenEventIds = new Set<Id>();
        for (Event e : granolaEvents) seenEventIds.add(e.Id);
        List<Id> erEventIds = new List<Id>();
        for (EventRelation er : [
            SELECT EventId
            FROM EventRelation
            WHERE RelationId = :contactId AND IsWhat = false
            LIMIT 200
        ]) {
            if (!seenEventIds.contains(er.EventId)) erEventIds.add(er.EventId);
        }
        if (!erEventIds.isEmpty()) {
            List<Event> moreEvents;
            if (opportunityId != null) {
                moreEvents = [
                    SELECT Id, ActivityDate, Description, Subject
                    FROM Event
                    WHERE Id IN :erEventIds
                      AND Subject LIKE '%Granola%'
                      AND ActivityDate >= :lookback
                      AND (WhatId = :opportunityId OR WhatId = :accountId OR AccountId = :accountId)
                    ORDER BY ActivityDate DESC NULLS LAST
                    LIMIT 30
                ];
            } else {
                moreEvents = [
                    SELECT Id, ActivityDate, Description, Subject
                    FROM Event
                    WHERE Id IN :erEventIds
                      AND Subject LIKE '%Granola%'
                      AND ActivityDate >= :lookback
                      AND AccountId = :accountId
                    ORDER BY ActivityDate DESC NULLS LAST
                    LIMIT 30
                ];
            }
            granolaEvents.addAll(moreEvents);
        }

        Set<String> topicSeen = new Set<String>();
        Set<String> actionSeen = new Set<String>();
        for (Event e : granolaEvents) {
            if (String.isBlank(e.Description)) continue;
            GranolaNote g = parseGranolaNote(e.Description);
            if (detail.granolaLatestDate == null && e.ActivityDate != null) {
                detail.granolaLatestDate = e.ActivityDate;
                detail.granolaLatestSummary = g.summary;
            }
            for (String t : g.topics) {
                if (!topicSeen.contains(t)) {
                    topicSeen.add(t);
                    detail.granolaTopics.add(t);
                }
            }
            for (String item : g.actionItems) {
                if (!actionSeen.contains(item) && detail.granolaActionItems.size() < 10) {
                    actionSeen.add(item);
                    detail.granolaActionItems.add(item);
                }
            }
        }
        if (detail.granolaTopics.size() > 10) {
            List<String> trimmed = new List<String>();
            for (Integer i = 0; i < 10; i++) trimmed.add(detail.granolaTopics[i]);
            detail.granolaTopics = trimmed;
        }
    }

    // ── Insight parsing helpers (mirrored from MultithreadHeatmapController) ──

    private static String decodeHtml(String input) {
        if (String.isBlank(input)) return input;
        return input
            .replace('&#39;', '\'')
            .replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"')
            .replace('&nbsp;', ' ');
    }

    private static List<String> parseTopics(String jsonStr) {
        List<String> topics = new List<String>();
        if (String.isBlank(jsonStr)) return topics;
        try {
            List<Object> parsed = (List<Object>) JSON.deserializeUntyped(jsonStr);
            Set<String> seen = new Set<String>();
            for (Object item : parsed) {
                Map<String, Object> m = (Map<String, Object>) item;
                String name = (String) m.get('Name');
                if (name != null && !seen.contains(name) && !name.startsWith('[')
                    && name != 'Call Setup' && name != 'Wrap-Up' && name != 'Small Talk') {
                    seen.add(name);
                    topics.add(name);
                }
            }
        } catch (Exception e) { /* skip */ }
        return topics;
    }

    private static void mergeTrackers(Map<String, TrackerInsight> merged, String jsonStr) {
        if (String.isBlank(jsonStr)) return;
        try {
            List<Object> parsed = (List<Object>) JSON.deserializeUntyped(jsonStr);
            for (Object item : parsed) {
                Map<String, Object> m = (Map<String, Object>) item;
                String name = (String) m.get('Name');
                if (name == null) continue;
                if (name.startsWith('[SMART] ')) name = name.substring(8);
                if (name == 'Call Setup' || name == 'Wrap-Up' || name == 'Small Talk') continue;

                Integer occ = m.get('Gong__Tracker_Occurrences__c') != null
                    ? ((Decimal) m.get('Gong__Tracker_Occurrences__c')).intValue() : 1;
                String phrase = (String) m.get('Gong__Tracker_Phrase__c');

                if (merged.containsKey(name)) {
                    merged.get(name).occurrences += occ;
                } else {
                    TrackerInsight ti = new TrackerInsight();
                    ti.name = name;
                    ti.phrase = (phrase != null && phrase != '-') ? phrase : null;
                    ti.occurrences = occ;
                    merged.put(name, ti);
                }
            }
        } catch (Exception e) { /* skip */ }
    }

    private static List<TrackerInsight> sortedTrackers(Map<String, TrackerInsight> merged) {
        List<TrackerInsight> trackers = new List<TrackerInsight>(merged.values());
        for (Integer i = 0; i < trackers.size(); i++) {
            for (Integer j = i + 1; j < trackers.size(); j++) {
                if (trackers[j].occurrences > trackers[i].occurrences) {
                    TrackerInsight tmp = trackers[i];
                    trackers[i] = trackers[j];
                    trackers[j] = tmp;
                }
            }
        }
        return trackers;
    }

    private static List<String> parseKeyPoints(String html, Integer maxPoints) {
        List<String> points = new List<String>();
        if (String.isBlank(html)) return points;
        List<String> parts = html.split('<br>');
        for (String part : parts) {
            String clean = part.replaceAll('<[^>]+>', '').trim();
            clean = clean.replaceAll('^\\d+\\.\\s*', '');
            clean = clean.replaceAll('^\\*\\s*', '');
            clean = decodeHtml(clean.trim());
            if (String.isNotBlank(clean) && clean.length() > 5) {
                if (clean.length() > 200) clean = clean.substring(0, 197) + '...';
                points.add(clean);
                if (points.size() >= maxPoints) break;
            }
        }
        return points;
    }

    private class GranolaNote {
        public List<String> topics = new List<String>();
        public List<String> actionItems = new List<String>();
        public String summary;
    }

    private static GranolaNote parseGranolaNote(String description) {
        GranolaNote g = new GranolaNote();
        List<String> lines = description.split('\n');
        Boolean inActionItems = false;
        Boolean capturingFirstSection = false;
        String firstSectionContent = '';
        Integer firstSectionLines = 0;

        for (String line : lines) {
            String trimmed = line.trim();
            if (trimmed.startsWith('Granola Link:') || trimmed.startsWith('Granola Note ID:')
                || trimmed.contains('Granola Generated Notes') || trimmed.startsWith('---')
                || trimmed.startsWith('Chat with meeting transcript:')) {
                continue;
            }
            if (trimmed.startsWith('### ')) {
                String topic = trimmed.substring(4).trim();
                String topicLower = topic.toLowerCase();
                if (topicLower.contains('action item') || topicLower.contains('next step')) {
                    inActionItems = true;
                    capturingFirstSection = false;
                } else {
                    inActionItems = false;
                    g.topics.add(topic);
                    if (g.topics.size() == 1) {
                        capturingFirstSection = true;
                        firstSectionLines = 0;
                    } else {
                        capturingFirstSection = false;
                    }
                }
                continue;
            }
            if (inActionItems && trimmed.startsWith('- ')) {
                String item = trimmed.substring(2).trim();
                if (item.length() > 150) item = item.substring(0, 147) + '...';
                if (g.actionItems.size() < 8) g.actionItems.add(item);
            }
            if (capturingFirstSection && firstSectionLines < 6 && String.isNotBlank(trimmed)
                && !trimmed.startsWith('###')) {
                if (String.isNotBlank(firstSectionContent)) firstSectionContent += ' ';
                String clean = trimmed.replaceAll('^[-*]\\s*', '');
                firstSectionContent += clean;
                firstSectionLines++;
            }
        }
        if (String.isNotBlank(firstSectionContent)) {
            if (firstSectionContent.length() > 400) {
                firstSectionContent = firstSectionContent.substring(0, 397) + '...';
            }
            g.summary = firstSectionContent;
        }
        return g;
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
            taskTotal = [
                SELECT COUNT() FROM Task
                WHERE Status = 'Completed'
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
            ];
            List<Task> latestTask = [
                SELECT ActivityDate FROM Task
                WHERE Status = 'Completed'
                  AND (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
                  AND ActivityDate != null
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 1
            ];
            if (!latestTask.isEmpty()) taskMax = latestTask[0].ActivityDate;

            eventTotal = [
                SELECT COUNT() FROM Event
                WHERE (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
            ];
            List<Event> latestEvent = [
                SELECT ActivityDate FROM Event
                WHERE (WhatId = :opportunityId OR WhatId = :accountId)
                  AND WhoId != null
                  AND ActivityDate != null
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 1
            ];
            if (!latestEvent.isEmpty()) eventMax = latestEvent[0].ActivityDate;

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
            taskTotal = [
                SELECT COUNT() FROM Task
                WHERE Status = 'Completed' AND AccountId = :accountId AND WhoId != null
            ];
            List<Task> latestTask = [
                SELECT ActivityDate FROM Task
                WHERE Status = 'Completed' AND AccountId = :accountId AND WhoId != null
                  AND ActivityDate != null
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 1
            ];
            if (!latestTask.isEmpty()) taskMax = latestTask[0].ActivityDate;

            eventTotal = [
                SELECT COUNT() FROM Event
                WHERE AccountId = :accountId AND WhoId != null
            ];
            List<Event> latestEvent = [
                SELECT ActivityDate FROM Event
                WHERE AccountId = :accountId AND WhoId != null AND ActivityDate != null
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 1
            ];
            if (!latestEvent.isEmpty()) eventMax = latestEvent[0].ActivityDate;

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
