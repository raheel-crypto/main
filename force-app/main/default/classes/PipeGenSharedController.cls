public with sharing class PipeGenSharedController {

    // ─── Wrapper Classes ──────────────────────────────────────────────

    public class GTMAUser {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
    }

    public class SharedDashboardData {
        @AuraEnabled public List<SharedAccountRow>  accounts;
        @AuraEnabled public List<Weekly_Commit__c>  sharedCommits;  // Is_Shared__c=true, AE created
        @AuraEnabled public List<Weekly_Commit__c>  aeCommits;      // Is_Shared__c=false, Rep__c=aeId
        @AuraEnabled public List<Weekly_Commit__c>  gtmaCommits;    // Is_Shared__c=false, Rep__c=gtmaId
    }

    public class SharedAccountRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   type;
        @AuraEnabled public String   accountStatus;
        @AuraEnabled public Decimal  arr;
        @AuraEnabled public Decimal  estimatedTam;
        @AuraEnabled public String   website;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public Integer  contactCount;
    }

    // ─── GTMA Roster ─────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<GTMAUser> getMyGTMAs() {
        Id aeId = UserInfo.getUserId();
        List<Account> accounts = [
            SELECT GTM_Associate__c, GTM_Associate__r.Name
            FROM Account
            WHERE OwnerId = :aeId
              AND GTM_Associate__c != null
            LIMIT 500
        ];
        Map<Id, GTMAUser> seen = new Map<Id, GTMAUser>();
        for (Account a : accounts) {
            if (!seen.containsKey(a.GTM_Associate__c)) {
                GTMAUser u = new GTMAUser();
                u.id   = a.GTM_Associate__c;
                u.name = a.GTM_Associate__r.Name;
                seen.put(a.GTM_Associate__c, u);
            }
        }
        return seen.values();
    }

    // ─── Shared Dashboard Data ───────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static SharedDashboardData getSharedDashboardData(Id gtmaId) {
        Id aeId = UserInfo.getUserId();
        Date weekStart = getWeekStart(Date.today());
        SharedDashboardData result = new SharedDashboardData();

        // Accounts owned by AE that are mapped to this GTMA
        List<Account> rawAccounts = [
            SELECT Id, Name, Type, Account_Status__c, ARR__c, Estimated_TAM__c,
                   Website, LastActivityDate,
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :aeId
              AND GTM_Associate__c = :gtmaId
            ORDER BY Name ASC
            LIMIT 200
        ];

        Set<Id> acctIds = new Set<Id>();
        List<SharedAccountRow> acctRows = new List<SharedAccountRow>();
        for (Account a : rawAccounts) {
            acctIds.add(a.Id);
            SharedAccountRow row  = new SharedAccountRow();
            row.id               = a.Id;
            row.name             = a.Name;
            row.type             = a.Type;
            row.accountStatus    = a.Account_Status__c;
            row.arr              = a.ARR__c;
            row.estimatedTam     = a.Estimated_TAM__c;
            row.website          = a.Website;
            row.lastActivityDate = a.LastActivityDate;
            row.contactCount     = a.Contacts.size();
            acctRows.add(row);
        }
        result.accounts = acctRows;

        // Shared commits (AE created, GTMA is partner)
        result.sharedCommits = [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Rep__c,
                   Is_Shared__c, Shared_Partner__c
            FROM Weekly_Commit__c
            WHERE Is_Shared__c = true
              AND Rep__c = :aeId
              AND Shared_Partner__c = :gtmaId
              AND Week_Start_Date__c = :weekStart
            ORDER BY CreatedDate ASC
        ];

        // AE-only commits on pairing accounts
        result.aeCommits = acctIds.isEmpty() ? new List<Weekly_Commit__c>() : [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Motion_Type__c,
                   Is_Shared__c, Shared_Partner__c
            FROM Weekly_Commit__c
            WHERE Is_Shared__c = false
              AND Rep__c = :aeId
              AND Target_Account__c IN :acctIds
              AND Week_Start_Date__c = :weekStart
            ORDER BY CreatedDate ASC
        ];

        // GTMA-only commits on pairing accounts
        result.gtmaCommits = acctIds.isEmpty() ? new List<Weekly_Commit__c>() : [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c,
                   Is_Shared__c, Shared_Partner__c
            FROM Weekly_Commit__c
            WHERE Is_Shared__c = false
              AND Rep__c = :gtmaId
              AND Target_Account__c IN :acctIds
              AND Week_Start_Date__c = :weekStart
            ORDER BY CreatedDate ASC
        ];

        return result;
    }

    // ─── Commit Mutations ──────────────────────────────────────────────────

    @AuraEnabled
    public static Weekly_Commit__c createSharedCommit(Weekly_Commit__c commitRecord, Id gtmaId) {
        Id aeId = UserInfo.getUserId();
        commitRecord.Rep__c             = aeId;
        commitRecord.Is_Shared__c       = true;
        commitRecord.Shared_Partner__c  = gtmaId;
        commitRecord.Week_Start_Date__c = getWeekStart(Date.today());
        insert commitRecord;
        return [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Motion_Type__c,
                   Week_Start_Date__c, Is_Shared__c, Shared_Partner__c, Rep__c
            FROM Weekly_Commit__c WHERE Id = :commitRecord.Id
        ];
    }

    @AuraEnabled
    public static Weekly_Commit__c createPartnerCommit(Weekly_Commit__c commitRecord, Id targetRepId) {
        Id repId = targetRepId != null ? targetRepId : UserInfo.getUserId();
        commitRecord.Rep__c             = repId;
        commitRecord.Is_Shared__c       = false;
        commitRecord.Week_Start_Date__c = getWeekStart(Date.today());
        insert commitRecord;
        return [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Motion_Type__c,
                   Week_Start_Date__c, Is_Shared__c, Shared_Partner__c, Rep__c
            FROM Weekly_Commit__c WHERE Id = :commitRecord.Id
        ];
    }

    @AuraEnabled
    public static Weekly_Commit__c toggleCommitComplete(Id commitId) {
        Weekly_Commit__c c = [
            SELECT Id, Completion_Status__c, Committed_Count__c
            FROM Weekly_Commit__c WHERE Id = :commitId LIMIT 1
        ];
        if (c.Completion_Status__c == 'Completed') {
            c.Completion_Status__c = 'Not Started';
            c.Actual_Count__c      = 0;
        } else {
            c.Completion_Status__c = 'Completed';
            c.Actual_Count__c      = c.Committed_Count__c != null ? c.Committed_Count__c.intValue() : 1;
        }
        update c;
        return [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Motion_Type__c,
                   Is_Shared__c, Shared_Partner__c, Rep__c
            FROM Weekly_Commit__c WHERE Id = :commitId
        ];
    }

    @AuraEnabled
    public static void deleteCommit(Id commitId) {
        delete new Weekly_Commit__c(Id = commitId);
    }

    // ─── Helper ────────────────────────────────────────────────────────────

    @TestVisible
    private static Date getWeekStart(Date d) {
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }
}
