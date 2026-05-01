// Matches each Weekly_Commit__c to Nektar-enriched activity data,
// updates Actual_Count__c and Completion_Status__c, persists only changed records.
public with sharing class CommitVerificationService {

    // Decision-maker title keywords — most specific phrases first so "Managing Director"
    // fires before the broader "Director" on a contains() match.
    private static final List<String> DM_TITLE_KEYWORDS = new List<String>{
        'Managing Director Investment Banking', 'Director Investment Banking',
        'Senior Managing Director', 'Executive Director', 'Investment Director',
        'Managing Director', 'General Partner', 'Portfolio Manager',
        'Head of M&A', 'Head of Investments', 'Director of Research',
        'Head of Equity Research', 'Head of Credit', 'Head of Private Equity',
        'Head of Macro', 'Head of Quantitative Research', 'Head of Fixed Income',
        'Head of Trading', 'Head of Capital Markets',
        'Partner', 'Principal', 'Director', 'MD'
    };

    public static List<Weekly_Commit__c> verify(
            List<Weekly_Commit__c> commits, Id userId, Date weekStart, Date weekEnd) {

        if (commits.isEmpty()) return commits;

        Set<Id> targetAcctIds = new Set<Id>();
        Set<Id> targetOppIds  = new Set<Id>();
        Set<Id> execAcctIds   = new Set<Id>();

        for (Weekly_Commit__c c : commits) {
            if (PipeGenConfig.isCommitTypeManual(c.Commit_Type__c)) continue;
            if (c.Target_Account__c    != null) targetAcctIds.add(c.Target_Account__c);
            if (c.Target_Opportunity__c != null) targetOppIds.add(c.Target_Opportunity__c);
            if (PipeGenConfig.isCommitTypeTaskBased(c.Commit_Type__c) && c.Target_Account__c != null)
                execAcctIds.add(c.Target_Account__c);
        }

        // Events: Net New matches on AccountId; Progression matches on WhatId (= Opp)
        Map<Id, List<String>> meetingsByAcct = new Map<Id, List<String>>();
        Map<Id, List<String>> meetingsByOpp  = new Map<Id, List<String>>();

        if (!targetAcctIds.isEmpty() || !targetOppIds.isEmpty()) {
            for (Event e : ActivitySelector.fetchWeekEvents(
                    userId, weekStart, weekEnd, targetAcctIds, targetOppIds)) {
                if (e.AccountId != null && targetAcctIds.contains(e.AccountId)) {
                    if (!meetingsByAcct.containsKey(e.AccountId))
                        meetingsByAcct.put(e.AccountId, new List<String>());
                    meetingsByAcct.get(e.AccountId).add(e.Meeting_Type__c);
                }
                if (e.WhatId != null && targetOppIds.contains(e.WhatId)) {
                    if (!meetingsByOpp.containsKey(e.WhatId))
                        meetingsByOpp.put(e.WhatId, new List<String>());
                    meetingsByOpp.get(e.WhatId).add(e.Meeting_Type__c);
                }
            }
        }

        // Tasks: Exec Outreach — contact Title must match DM persona list
        Map<Id, Integer> execHitsByAcct = new Map<Id, Integer>();
        if (!execAcctIds.isEmpty()) {
            List<Task> tasks = ActivitySelector.fetchWeekTasks(userId, weekStart, weekEnd, execAcctIds);
            Set<Id> contactIds = new Set<Id>();
            for (Task t : tasks) {
                if (String.valueOf(t.WhoId).startsWith('003')) contactIds.add(t.WhoId);
            }
            Map<Id, String> titleByContact = ActivitySelector.fetchTitlesByContact(contactIds);
            for (Task t : tasks) {
                if (!isDmTitle(titleByContact.get(t.WhoId))) continue;
                Integer prev = execHitsByAcct.get(t.AccountId);
                execHitsByAcct.put(t.AccountId, prev != null ? prev + 1 : 1);
            }
        }

        List<Weekly_Commit__c> toUpdate = new List<Weekly_Commit__c>();

        for (Weekly_Commit__c c : commits) {
            Integer newActual;
            String  newStatus;

            if (PipeGenConfig.isCommitTypeManual(c.Commit_Type__c)) {
                newActual = c.Actual_Count__c != null ? c.Actual_Count__c.intValue() : 0;
                newStatus = deriveStatus(newActual, c.Committed_Count__c);
                if (newStatus == c.Completion_Status__c) continue;
                c.Completion_Status__c = newStatus;
                toUpdate.add(new Weekly_Commit__c(Id = c.Id, Completion_Status__c = newStatus));
                continue;
            }

            if (PipeGenConfig.isCommitTypeTaskBased(c.Commit_Type__c) && c.Target_Account__c != null) {
                Integer h = execHitsByAcct.get(c.Target_Account__c);
                newActual = h != null ? h : 0;

            } else if (c.Motion_Type__c == 'Net New' && c.Target_Account__c != null) {
                Set<String> mapped   = PipeGenConfig.getMeetingTypesForCommit(c.Commit_Type__c);
                List<String> meetings = meetingsByAcct.get(c.Target_Account__c);
                newActual = 0;
                if (meetings != null && mapped != null)
                    for (String mt : meetings) if (mapped.contains(mt)) newActual++;

            } else if (c.Motion_Type__c == 'Progression' && c.Target_Opportunity__c != null) {
                Set<String> mapped    = PipeGenConfig.getMeetingTypesForCommit(c.Commit_Type__c);
                List<String> meetings = meetingsByOpp.get(c.Target_Opportunity__c);
                newActual = 0;
                if (meetings != null)
                    for (String mt : meetings)
                        if (mapped == null || mapped.contains(mt)) newActual++;

            } else {
                continue;
            }

            newStatus = deriveStatus(newActual, c.Committed_Count__c);
            Integer oldActual = c.Actual_Count__c != null ? c.Actual_Count__c.intValue() : -1;
            if (newActual == oldActual && newStatus == c.Completion_Status__c) continue;

            // Never auto-downgrade from Completed — preserves manually-set or prior completions
            if ('Completed'.equals(c.Completion_Status__c) && !'Completed'.equals(newStatus)) continue;

            c.Actual_Count__c      = newActual;
            c.Completion_Status__c = newStatus;
            toUpdate.add(new Weekly_Commit__c(
                Id = c.Id, Actual_Count__c = newActual, Completion_Status__c = newStatus
            ));
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        return commits;
    }

    public static String deriveStatus(Integer actual, Decimal committed) {
        Integer target = committed != null ? committed.intValue() : 1;
        if (actual >= target) return 'Completed';
        if (actual > 0)       return 'Partial';
        return 'Not Started';
    }

    private static Boolean isDmTitle(String title) {
        if (String.isBlank(title)) return false;
        String tl = title.toLowerCase();
        for (String kw : DM_TITLE_KEYWORDS) {
            if (tl.contains(kw.toLowerCase())) return true;
        }
        return false;
    }
}
