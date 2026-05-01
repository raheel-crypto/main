public with sharing class ActivitySelector {

    // ─── Events for Commit Verification ─────────────────────────────────────────
    // Returns Meeting_Type__c-tagged Events for the week, keyed by AccountId and WhatId.

    public static List<Event> fetchWeekEvents(
            Id ownerId, Date weekStart, Date weekEnd,
            Set<Id> targetAcctIds, Set<Id> targetOppIds) {
        return [
            SELECT Meeting_Type__c, AccountId, WhatId
            FROM Event
            WHERE OwnerId = :ownerId
              AND ActivityDate >= :weekStart
              AND ActivityDate <= :weekEnd
              AND Meeting_Type__c != null
              AND (AccountId IN :targetAcctIds OR WhatId IN :targetOppIds)
        ];
    }

    // ─── Tasks for Exec Outreach Verification ────────────────────────────────────

    public static List<Task> fetchWeekTasks(Id ownerId, Date weekStart, Date weekEnd, Set<Id> accountIds) {
        return [
            SELECT WhoId, AccountId
            FROM Task
            WHERE OwnerId = :ownerId
              AND ActivityDate >= :weekStart
              AND ActivityDate <= :weekEnd
              AND AccountId IN :accountIds
              AND WhoId != null
        ];
    }

    // ─── Contact Titles for DM Detection ────────────────────────────────────────

    public static Map<Id, String> fetchTitlesByContact(Set<Id> contactIds) {
        Map<Id, String> result = new Map<Id, String>();
        if (contactIds.isEmpty()) return result;
        for (Contact c : [
            SELECT Id, Title FROM Contact WHERE Id IN :contactIds AND Title != null
        ]) { result.put(c.Id, c.Title); }
        return result;
    }
}
