public with sharing class CommitSelector {

    // ─── This Week's Commits ─────────────────────────────────────────────────────

    public static List<Weekly_Commit__c> fetchForWeek(Id repId, Date weekStart) {
        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :repId
              AND Week_Start_Date__c = :weekStart
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
    }

    // ─── Incomplete Commits from Previous Week ───────────────────────────────────

    public static List<Weekly_Commit__c> fetchIncomplete(Id repId, Date weekStart) {
        return [
            SELECT Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Opportunity__c, Committed_Count__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :repId
              AND Week_Start_Date__c = :weekStart
              AND Completion_Status__c != 'Completed'
        ];
    }

    // ─── Scorecard Commits (verification-weight fields) ──────────────────────────

    public static List<Weekly_Commit__c> fetchForScorecard(Id repId, Date weekStart) {
        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Completion_Status__c,
                   Committed_Count__c, Actual_Count__c,
                   Target_Account__c, Target_Opportunity__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :repId
              AND Week_Start_Date__c = :weekStart
        ];
    }

    // ─── Team Commits for a Week ─────────────────────────────────────────────────

    public static List<Weekly_Commit__c> fetchTeamThisWeek(Set<Id> repIds, Date weekStart) {
        return [
            SELECT Id, Rep__c, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Manager_Note__c, At_Risk__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c IN :repIds
              AND Week_Start_Date__c = :weekStart
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
    }

    public static List<Weekly_Commit__c> fetchTeamLastWeek(Set<Id> repIds, Date weekStart) {
        return [
            SELECT Id, Rep__c, Motion_Type__c, Completion_Status__c,
                   Committed_Count__c, Target_Opportunity__c
            FROM Weekly_Commit__c
            WHERE Rep__c IN :repIds
              AND Week_Start_Date__c = :weekStart
        ];
    }
}
