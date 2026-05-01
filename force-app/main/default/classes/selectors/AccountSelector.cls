public with sharing class AccountSelector {

    // ─── Target Account Query (Dashboard) ───────────────────────────────────────

    public static List<Account> fetchTargetAccounts(Id ownerId) {
        return [
            SELECT Id, Name, Type, Account_Status__c, ARR__c, Estimated_TAM__c, Website,
                   LastActivityDate,
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :ownerId
              AND Target_Account__c = true
            ORDER BY Name ASC
            LIMIT 150
        ];
    }

    // ─── Full Account List Query (Account Selection Tab) ────────────────────────

    public static List<Account> fetchAllForSelection(Id ownerId) {
        return [
            SELECT Id, Name, Type, Industry, Target_Account__c, Website,
                   Account_Status__c, ARR__c, Account_Tier__c,
                   Estimated_TAM__c, Number_of_Bankers__c, LastActivityDate,
                   (SELECT Id, StageName, Type, CloseDate, IsClosed
                    FROM Opportunities WHERE IsDeleted = false
                    ORDER BY CloseDate DESC LIMIT 50),
                   (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :ownerId
            ORDER BY Name ASC
            LIMIT 300
        ];
    }

    // ─── Most-recent Event subject per account (secondary enrichment) ───────────

    public static Map<Id, String> fetchLastActivitySubjectByAccount(Set<Id> accountIds) {
        Map<Id, String> result = new Map<Id, String>();
        if (accountIds.isEmpty()) return result;
        for (Event e : [
            SELECT AccountId, Subject, ActivityDate
            FROM Event
            WHERE AccountId IN :accountIds
              AND ActivityDate != null
            ORDER BY AccountId ASC, ActivityDate DESC
        ]) {
            if (!result.containsKey(e.AccountId)) {
                result.put(e.AccountId, e.Subject);
            }
        }
        return result;
    }
}
