public with sharing class PipeGenGTMAController {

    // ─── Wrapper Classes ────────────────────────────────────────────────────────

    public class GTMADashboardData {
        @AuraEnabled public GTMAWeeklyTarget      weeklyTarget;
        @AuraEnabled public List<AccountRow>      targetAccounts;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public GTMAScorecardData     lastWeekScorecard;
    }

    public class GTMAWeeklyTarget {
        @AuraEnabled public Integer target;     // User.GTMA_Weekly_Target__c
        @AuraEnabled public Integer completed;  // completed commits this week
        @AuraEnabled public Integer total;      // all commits this week
        @AuraEnabled public String  weekLabel;  // "Week of May 19"
    }

    public class GTMAScorecardData {
        @AuraEnabled public Integer commitsTotal;
        @AuraEnabled public Integer commitsCompleted;
        @AuraEnabled public Integer accountsTouched;    // distinct accounts on LW commits
        @AuraEnabled public Integer pipelineInfluence;  // open opps on GTMA-covered accounts
    }

    public class AccountRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   type;
        @AuraEnabled public String   accountStatus;
        @AuraEnabled public Decimal  arr;
        @AuraEnabled public Decimal  estimatedTam;
        @AuraEnabled public String   website;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactCount;
    }

    public class AccountCard {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  type;
        @AuraEnabled public String  industry;
        @AuraEnabled public Boolean isTargeted;
        @AuraEnabled public Integer contactCount;
        @AuraEnabled public Integer openOppCount;
        @AuraEnabled public String  accountStatus;
        @AuraEnabled public Decimal arr;
        @AuraEnabled public String  accountTier;
        @AuraEnabled public Decimal estimatedTam;
        @AuraEnabled public Integer bankerCount;
        @AuraEnabled public String  website;
        @AuraEnabled public String  segment;
        @AuraEnabled public Date    lastActivityDate;
        @AuraEnabled public Integer earlyStageOppCount;
    }

    // ─── Verification Config ─────────────────────────────────────────────────────

    // Commit types verified via Event.Meeting_Type__c on the target account
    private static final Map<String, Set<String>> GTMA_MEETING_TYPE_MAP =
        new Map<String, Set<String>>{
            'Meeting Booked'     => new Set<String>{ 'First Meeting', 'Discovery', 'Prospect Meeting' },
            'Referral Intro'     => new Set<String>{ 'First Meeting' },
            'Executive Briefing' => new Set<String>{ 'Deal Progression', 'Executive Alignment', 'POV Readout' }
        };

    private static final String STAGE_CLOSED_LOST = 'Closed Lost';
    private static final String STAGE_DEMO        = '1 - Demo';
    private static final String STAGE_DISCOVERY   = '2 - Discovery';

    // ─── Main Entry Point ────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static GTMADashboardData getGTMADashboardData() {
        Id userId = UserInfo.getUserId();
        GTMADashboardData d = new GTMADashboardData();
        d.weeklyTarget     = buildWeeklyTarget(userId);
        d.targetAccounts   = buildTargetAccounts(userId);
        d.thisWeekCommits  = buildThisWeekCommits(userId);
        d.lastWeekScorecard = buildLastWeekScorecard(userId);
        return d;
    }

    // ─── Weekly Target ───────────────────────────────────────────────────────────

    private static GTMAWeeklyTarget buildWeeklyTarget(Id userId) {
        GTMAWeeklyTarget wt = new GTMAWeeklyTarget();
        Date weekStart = getWeekStart(Date.today());

        Integer target = 0;
        try {
            User u = [SELECT GTMA_Weekly_Target__c FROM User WHERE Id = :userId LIMIT 1];
            target = u.GTMA_Weekly_Target__c != null ? u.GTMA_Weekly_Target__c.intValue() : 0;
        } catch (Exception e) { target = 0; }
        wt.target = target;

        List<Weekly_Commit__c> commits = [
            SELECT Id, Completion_Status__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId AND Week_Start_Date__c = :weekStart
        ];
        wt.total = commits.size();
        wt.completed = 0;
        for (Weekly_Commit__c c : commits) {
            if (c.Completion_Status__c == 'Completed') wt.completed++;
        }

        // Format "Week of May 19" — use Apex Date formatting
        String[] months = new String[]{
            '', 'January','February','March','April','May','June',
            'July','August','September','October','November','December'
        };
        wt.weekLabel = 'Week of ' + months[weekStart.month()] + ' ' + weekStart.day();
        return wt;
    }

    // ─── Target Accounts ────────────────────────────────────────────────────────

    private static List<AccountRow> buildTargetAccounts(Id userId) {
        List<AccountRow> rows = new List<AccountRow>();

        List<Account> accounts = [
            SELECT Id, Name, Type, Account_Status__c, ARR__c, Estimated_TAM__c, Website,
                   LastActivityDate,
                (SELECT Gong__Call_Start__c FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE GTM_Associate__c = :userId AND GTMA_Target_Account__c = true
            ORDER BY Name ASC
            LIMIT 150
        ];

        for (Account a : accounts) {
            AccountRow row       = new AccountRow();
            row.id               = a.Id;
            row.name             = a.Name;
            row.type             = a.Type;
            row.accountStatus    = a.Account_Status__c;
            row.arr              = a.ARR__c;
            row.estimatedTam     = a.Estimated_TAM__c;
            row.website          = a.Website;
            row.contactCount     = a.Contacts.size();
            row.lastActivityDate = a.LastActivityDate;
            if (!a.Gong__Conversations__r.isEmpty()) {
                row.lastGongCallDate = a.Gong__Conversations__r[0].Gong__Call_Start__c;
            }
            rows.add(row);
        }
        return rows;
    }

    // ─── This Week's Commits ─────────────────────────────────────────────────────

    private static List<Weekly_Commit__c> buildThisWeekCommits(Id userId) {
        Date weekStart = getWeekStart(Date.today());
        Date weekEnd   = weekStart.addDays(6);
        List<Weekly_Commit__c> commits = [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Manager_Note__c, At_Risk__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId AND Week_Start_Date__c = :weekStart
            ORDER BY CreatedDate ASC
        ];
        return verifyAndPersistGTMACommits(commits, userId, weekStart, weekEnd);
    }

    // ─── Last Week's Scorecard ───────────────────────────────────────────────────

    private static GTMAScorecardData buildLastWeekScorecard(Id userId) {
        GTMAScorecardData sc = new GTMAScorecardData();
        Date lastWeekStart = getWeekStart(Date.today()).addDays(-7);
        Date lastWeekEnd   = lastWeekStart.addDays(6);

        List<Weekly_Commit__c> commits = [
            SELECT Id, Commit_Type__c, Completion_Status__c,
                   Target_Account__c, Committed_Count__c, Actual_Count__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId AND Week_Start_Date__c = :lastWeekStart
        ];
        commits = verifyAndPersistGTMACommits(commits, userId, lastWeekStart, lastWeekEnd);

        sc.commitsTotal     = commits.size();
        sc.commitsCompleted = 0;
        Set<Id> touchedAccounts = new Set<Id>();
        for (Weekly_Commit__c c : commits) {
            if (c.Completion_Status__c == 'Completed') sc.commitsCompleted++;
            if (c.Target_Account__c != null) touchedAccounts.add(c.Target_Account__c);
        }
        sc.accountsTouched = touchedAccounts.size();

        // Pipeline influence: open opps on all accounts where GTM_Associate__c = userId
        Set<Id> coveredIds = new Set<Id>();
        for (Account a : [SELECT Id FROM Account WHERE GTM_Associate__c = :userId]) {
            coveredIds.add(a.Id);
        }
        if (!coveredIds.isEmpty()) {
            AggregateResult[] ar = [
                SELECT COUNT(Id) total FROM Opportunity
                WHERE AccountId IN :coveredIds
                  AND IsClosed = false
                  AND StageName != :STAGE_CLOSED_LOST
            ];
            sc.pipelineInfluence = ar[0].get('total') != null ? (Integer)ar[0].get('total') : 0;
        } else {
            sc.pipelineInfluence = 0;
        }
        return sc;
    }

    // ─── Account Selection ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<AccountCard> getGTMAAccountsForSelection() {
        Id   userId       = UserInfo.getUserId();
        Date today        = Date.today();
        Date thirtyAgo    = today.addDays(-30);
        Date sixMonthsAgo = today.addDays(-180);

        List<Account> accounts = [
            SELECT Id, Name, Type, Industry, GTMA_Target_Account__c, Website,
                   Account_Status__c, ARR__c, Account_Tier__c,
                   Estimated_TAM__c, Number_of_Bankers__c, LastActivityDate,
                (SELECT Id, StageName, IsClosed, CloseDate
                 FROM Opportunities WHERE IsDeleted = false
                 ORDER BY CloseDate DESC LIMIT 10),
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE GTM_Associate__c = :userId
            ORDER BY Name ASC
            LIMIT 300
        ];

        List<AccountCard> cards = new List<AccountCard>();
        for (Account a : accounts) {
            Integer openOppCount    = 0;
            Integer earlyStageCount = 0;
            Boolean hasRecentCL     = false;
            Boolean hasOldCL        = false;
            Boolean hasOnlyOldCL    = true;

            for (Opportunity o : a.Opportunities) {
                if (!o.IsClosed) {
                    openOppCount++;
                    hasOnlyOldCL = false;
                    if (o.StageName == STAGE_DEMO || o.StageName == STAGE_DISCOVERY)
                        earlyStageCount++;
                } else if (o.StageName == STAGE_CLOSED_LOST && o.CloseDate != null) {
                    if (o.CloseDate >= sixMonthsAgo) hasRecentCL = true;
                    else hasOldCL = true;
                }
            }

            AccountCard card        = new AccountCard();
            card.id                 = a.Id;
            card.name               = a.Name;
            card.type               = a.Type;
            card.industry           = a.Industry;
            card.isTargeted         = a.GTMA_Target_Account__c;
            card.contactCount       = a.Contacts.size();
            card.openOppCount       = openOppCount;
            card.earlyStageOppCount = earlyStageCount;
            card.accountStatus      = a.Account_Status__c;
            card.arr                = a.ARR__c;
            card.accountTier        = a.Account_Tier__c;
            card.estimatedTam       = a.Estimated_TAM__c;
            card.bankerCount        = a.Number_of_Bankers__c != null ? a.Number_of_Bankers__c.intValue() : 0;
            card.website            = a.Website;
            card.lastActivityDate   = a.LastActivityDate;
            card.segment            = computeSegment(
                a.Account_Status__c, a.ARR__c, openOppCount, earlyStageCount,
                hasRecentCL, hasOldCL, hasOnlyOldCL,
                a.LastActivityDate, thirtyAgo
            );
            cards.add(card);
        }
        return cards;
    }

    @AuraEnabled
    public static void updateGTMATargetAccounts(List<Id> toTarget, List<Id> toUntarget) {
        List<Account> updates = new List<Account>();
        for (Id id : (toTarget   != null ? toTarget   : new List<Id>()))
            updates.add(new Account(Id = id, GTMA_Target_Account__c = true));
        for (Id id : (toUntarget != null ? toUntarget : new List<Id>()))
            updates.add(new Account(Id = id, GTMA_Target_Account__c = false));
        if (!updates.isEmpty()) update updates;
    }

    // ─── Commit Mutations ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Weekly_Commit__c saveCommit(Weekly_Commit__c commitRecord) {
        commitRecord.Rep__c             = UserInfo.getUserId();
        commitRecord.Week_Start_Date__c = getWeekStart(Date.today());
        commitRecord.Motion_Type__c     = null; // GTMAs have no motion type
        upsert commitRecord;
        return [
            SELECT Id, Rep__c, Week_Start_Date__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Manager_Note__c, At_Risk__c
            FROM Weekly_Commit__c WHERE Id = :commitRecord.Id
        ];
    }

    @AuraEnabled
    public static void deleteCommit(Id commitId) {
        delete new Weekly_Commit__c(Id = commitId);
    }

    @AuraEnabled
    public static List<Weekly_Commit__c> carryForwardGTMACommits() {
        Id   userId        = UserInfo.getUserId();
        Date weekStart     = getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        List<Weekly_Commit__c> incomplete = [
            SELECT Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Committed_Count__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :lastWeekStart
              AND Completion_Status__c != 'Completed'
        ];
        if (incomplete.isEmpty()) return new List<Weekly_Commit__c>();

        List<Weekly_Commit__c> toInsert = new List<Weekly_Commit__c>();
        for (Weekly_Commit__c c : incomplete) {
            toInsert.add(new Weekly_Commit__c(
                Rep__c                = userId,
                Week_Start_Date__c    = weekStart,
                Commit_Type__c        = c.Commit_Type__c,
                Commit_Description__c = c.Commit_Description__c,
                Target_Account__c     = c.Target_Account__c,
                Committed_Count__c    = c.Committed_Count__c,
                Notes__c              = c.Notes__c
            ));
        }
        insert toInsert;

        return [
            SELECT Id, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Notes__c, Manager_Note__c, At_Risk__c
            FROM Weekly_Commit__c
            WHERE Id IN :toInsert
            ORDER BY CreatedDate ASC
        ];
    }

    // ─── Activity Verification ───────────────────────────────────────────────────

    private static List<Weekly_Commit__c> verifyAndPersistGTMACommits(
            List<Weekly_Commit__c> commits, Id userId, Date weekStart, Date weekEnd) {

        if (commits.isEmpty()) return commits;

        // Collect accounts needing event-based verification
        Set<Id> meetingAcctIds    = new Set<Id>();
        Set<Id> callEmailAcctIds  = new Set<Id>();
        for (Weekly_Commit__c c : commits) {
            if (c.Target_Account__c == null) continue;
            if (GTMA_MEETING_TYPE_MAP.containsKey(c.Commit_Type__c))
                meetingAcctIds.add(c.Target_Account__c);
            if (c.Commit_Type__c == 'Cold Call Made' || c.Commit_Type__c == 'Email Sequence Launched')
                callEmailAcctIds.add(c.Target_Account__c);
        }

        // Event-based verification
        Map<Id, List<String>> meetingsByAcct = new Map<Id, List<String>>();
        if (!meetingAcctIds.isEmpty()) {
            for (Event e : [
                SELECT Meeting_Type__c, AccountId
                FROM Event
                WHERE OwnerId = :userId
                  AND ActivityDate >= :weekStart
                  AND ActivityDate <= :weekEnd
                  AND Meeting_Type__c != null
                  AND AccountId IN :meetingAcctIds
            ]) {
                if (!meetingsByAcct.containsKey(e.AccountId))
                    meetingsByAcct.put(e.AccountId, new List<String>());
                meetingsByAcct.get(e.AccountId).add(e.Meeting_Type__c);
            }
        }

        // Task-based verification (calls and emails)
        Map<Id, Integer> callsByAcct  = new Map<Id, Integer>();
        Map<Id, Integer> emailsByAcct = new Map<Id, Integer>();
        if (!callEmailAcctIds.isEmpty()) {
            for (Task t : [
                SELECT Type, AccountId
                FROM Task
                WHERE OwnerId = :userId
                  AND ActivityDate >= :weekStart
                  AND ActivityDate <= :weekEnd
                  AND AccountId IN :callEmailAcctIds
                  AND Type IN ('Call', 'Email')
            ]) {
                if (t.Type == 'Call') {
                    Integer prev = callsByAcct.get(t.AccountId);
                    callsByAcct.put(t.AccountId, prev != null ? prev + 1 : 1);
                } else {
                    Integer prev = emailsByAcct.get(t.AccountId);
                    emailsByAcct.put(t.AccountId, prev != null ? prev + 1 : 1);
                }
            }
        }

        List<Weekly_Commit__c> toUpdate = new List<Weekly_Commit__c>();
        for (Weekly_Commit__c c : commits) {
            Integer newActual;

            if (GTMA_MEETING_TYPE_MAP.containsKey(c.Commit_Type__c) && c.Target_Account__c != null) {
                Set<String> mapped   = GTMA_MEETING_TYPE_MAP.get(c.Commit_Type__c);
                List<String> meetings = meetingsByAcct.get(c.Target_Account__c);
                newActual = 0;
                if (meetings != null)
                    for (String mt : meetings) if (mapped.contains(mt)) newActual++;

            } else if (c.Commit_Type__c == 'Cold Call Made' && c.Target_Account__c != null) {
                Integer h = callsByAcct.get(c.Target_Account__c);
                newActual = h != null ? h : 0;

            } else if (c.Commit_Type__c == 'Email Sequence Launched' && c.Target_Account__c != null) {
                Integer h = emailsByAcct.get(c.Target_Account__c);
                newActual = h != null ? h : 0;

            } else {
                // Manual types (LinkedIn Outreach, Event Attendance) — no auto-verify
                continue;
            }

            String  newStatus = deriveStatus(newActual, c.Committed_Count__c);
            Integer oldActual = c.Actual_Count__c != null ? c.Actual_Count__c.intValue() : -1;
            if (newActual == oldActual && newStatus == c.Completion_Status__c) continue;

            // Never auto-downgrade from Completed
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

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private static String deriveStatus(Integer actual, Decimal committed) {
        Integer target = committed != null ? committed.intValue() : 1;
        if (actual >= target) return 'Completed';
        if (actual > 0)       return 'Partial';
        return 'Not Started';
    }

    private static String computeSegment(
        String status, Decimal arr, Integer openCount, Integer earlyCount,
        Boolean hasRecentCL, Boolean hasOldCL, Boolean hasOnlyOldCL,
        Date lastActivity, Date thirtyAgo
    ) {
        Boolean isCustomer       = 'Customer'.equals(status);
        Boolean isFormerCustomer = 'Former Customer'.equals(status);
        Boolean isProspect       = 'Prospect'.equals(status);

        if (isCustomer && arr != null && arr > 0)                return 'Expansion';
        if (earlyCount > 0 && !isCustomer && !isFormerCustomer)  return 'Early Stage';
        if (isProspect && (openCount == 0 || hasOnlyOldCL))      return 'Uncracked';
        if (!isCustomer && !isFormerCustomer && openCount == 0 && hasRecentCL) return 'Recent Closed Lost';
        if (!isCustomer && !isFormerCustomer && openCount == 0
                && lastActivity != null && lastActivity >= thirtyAgo) return 'No Opportunities';
        return 'Other';
    }

    @TestVisible
    private static Date getWeekStart(Date d) {
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }
}
