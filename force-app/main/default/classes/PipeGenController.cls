public with sharing class PipeGenController {

    // ─── Wrapper Classes ────────────────────────────────────────────────────────

    public class DashboardData {
        @AuraEnabled public QuarterlyTarget        quarterlyTarget;
        @AuraEnabled public List<AccountRow>       targetAccounts;
        @AuraEnabled public List<OppRow>           inFlightOpps;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public ScorecardData          lastWeekScorecard;
    }

    public class QuarterlyTarget {
        @AuraEnabled public Decimal totalTarget;
        @AuraEnabled public Decimal netNewTarget;
        @AuraEnabled public Decimal progressionTarget;
        @AuraEnabled public Decimal netNewActual;
        @AuraEnabled public Decimal progressionActual;
        @AuraEnabled public Integer weeksRemaining;
        @AuraEnabled public String  quarter;
    }

    public class AccountRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   type;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public String   lastActivitySubject;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactCount;
    }

    public class OppRow {
        @AuraEnabled public String   id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   stageName;
        @AuraEnabled public Decimal  amount;
        @AuraEnabled public String   accountName;
        @AuraEnabled public String   accountId;
        @AuraEnabled public Integer  daysInStage;
        @AuraEnabled public Integer  staleThreshold;
        @AuraEnabled public Date     lastActivityDate;
        @AuraEnabled public DateTime lastGongCallDate;
        @AuraEnabled public Integer  contactRoleCount;
        @AuraEnabled public Boolean  isStale;
        @AuraEnabled public Date     closeDate;
    }

    public class ScorecardData {
        @AuraEnabled public Integer nnCommitsTotal;
        @AuraEnabled public Integer nnCommitsCompleted;
        @AuraEnabled public Decimal nnDollarGenerated;
        @AuraEnabled public Integer nnOppsCreated;
        @AuraEnabled public Integer progCommitsTotal;
        @AuraEnabled public Integer progCommitsCompleted;
        @AuraEnabled public Integer progOppsAdvanced;
        @AuraEnabled public Integer progOppsStalled;
        @AuraEnabled public Decimal progConversionRate;
    }

    public class AccountCard {
        @AuraEnabled public String  id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  type;
        @AuraEnabled public String  industry;
        @AuraEnabled public Boolean isTargeted;
        @AuraEnabled public Integer contactCount;
        @AuraEnabled public Integer openOppCount;
    }

    // ─── Config ─────────────────────────────────────────────────────────────────

    // Adjust stage names to match your org's picklist values
    private static final String STAGE_1 = 'Stage 1';
    private static final String STAGE_2 = 'Stage 2';
    private static final String STAGE_3 = 'Stage 3';

    private static final Set<String> IN_FLIGHT_STAGES = new Set<String>{ STAGE_1, STAGE_2 };

    // Staleness thresholds in days per stage — S2 tighter since it should be moving faster
    private static final Map<String, Integer> STALE_THRESHOLDS = new Map<String, Integer>{
        STAGE_1 => 21,
        STAGE_2 => 14
    };

    // ─── Main Entry Point ────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static DashboardData getRepDashboardData() {
        Id userId = UserInfo.getUserId();
        DashboardData d = new DashboardData();
        d.quarterlyTarget   = buildQuarterlyTarget(userId);
        d.targetAccounts    = buildTargetAccounts(userId);
        d.inFlightOpps      = buildInFlightOpps(userId);
        d.thisWeekCommits   = buildThisWeekCommits(userId);
        d.lastWeekScorecard = buildLastWeekScorecard(userId);
        return d;
    }

    // ─── Quarterly Target ────────────────────────────────────────────────────────

    private static QuarterlyTarget buildQuarterlyTarget(Id userId) {
        QuarterlyTarget qt = new QuarterlyTarget();
        Date today = Date.today();

        Integer qStartMonth = ((today.month() - 1) / 3) * 3 + 1;
        Date qStart = Date.newInstance(today.year(), qStartMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);
        qt.quarter  = 'Q' + ((qStartMonth / 3) + 1) + ' ' + today.year();
        qt.weeksRemaining = Math.max(0, today.daysBetween(qEnd) / 7);

        // Quota — stored on User as Pipe_Gen_Annual_Target__c
        Decimal annual = 0;
        try {
            User u = [SELECT Pipe_Gen_Annual_Target__c FROM User WHERE Id = :userId LIMIT 1];
            annual = u.Pipe_Gen_Annual_Target__c != null ? u.Pipe_Gen_Annual_Target__c : 0;
        } catch (Exception e) { annual = 0; }

        qt.totalTarget       = annual / 4;
        qt.netNewTarget      = qt.totalTarget * 0.5;
        qt.progressionTarget = qt.totalTarget * 0.5;

        AggregateResult[] nnRes = [
            SELECT SUM(Amount) tot
            FROM Opportunity
            WHERE OwnerId = :userId
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
              AND IsClosed = false
              AND StageName != 'Stage 0'
        ];
        qt.netNewActual = nnRes[0].get('tot') != null ? (Decimal)nnRes[0].get('tot') : 0;

        Set<Id> stage3Ids = new Set<Id>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
        ]) {
            if (h.NewValue == STAGE_3) stage3Ids.add(h.OpportunityId);
        }

        qt.progressionActual = 0;
        if (!stage3Ids.isEmpty()) {
            AggregateResult[] pRes = [
                SELECT SUM(Amount) tot
                FROM Opportunity
                WHERE Id IN :stage3Ids AND OwnerId = :userId
            ];
            qt.progressionActual = pRes[0].get('tot') != null ? (Decimal)pRes[0].get('tot') : 0;
        }
        return qt;
    }

    // ─── Target Accounts ────────────────────────────────────────────────────────

    private static List<AccountRow> buildTargetAccounts(Id userId) {
        List<AccountRow> rows = new List<AccountRow>();

        List<Account> accounts = [
            SELECT Id, Name, Type,
                (SELECT ActivityDate, Subject
                 FROM ActivityHistories
                 ORDER BY ActivityDate DESC, LastModifiedDate DESC LIMIT 1),
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM Contacts WHERE IsDeleted = false)
            FROM Account
            WHERE OwnerId = :userId
              AND Target_Account__c = true
            ORDER BY Name ASC
            LIMIT 150
        ];

        for (Account a : accounts) {
            AccountRow row   = new AccountRow();
            row.id           = a.Id;
            row.name         = a.Name;
            row.type         = a.Type;
            row.contactCount = a.Contacts.size();
            if (!a.ActivityHistories.isEmpty() && a.ActivityHistories[0].ActivityDate != null) {
                row.lastActivityDate    = a.ActivityHistories[0].ActivityDate;
                row.lastActivitySubject = a.ActivityHistories[0].Subject;
            }
            if (!a.Gong__Conversations__r.isEmpty()) {
                row.lastGongCallDate = a.Gong__Conversations__r[0].Gong__Call_Start__c;
            }
            rows.add(row);
        }
        return rows;
    }

    // ─── In-Flight Opps (Stage 1 + Stage 2) ─────────────────────────────────────

    private static List<OppRow> buildInFlightOpps(Id userId) {
        List<OppRow> rows = new List<OppRow>();

        List<Opportunity> opps = [
            SELECT Id, Name, StageName, Amount, CloseDate, AccountId, Account.Name,
                (SELECT ActivityDate, Subject
                 FROM ActivityHistories
                 ORDER BY ActivityDate DESC, LastModifiedDate DESC LIMIT 1),
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM OpportunityContactRoles WHERE IsDeleted = false)
            FROM Opportunity
            WHERE OwnerId = :userId
              AND StageName IN :IN_FLIGHT_STAGES
              AND IsClosed = false
            ORDER BY StageName ASC, CreatedDate ASC
        ];

        if (opps.isEmpty()) return rows;

        // Find when each opp last entered its CURRENT stage
        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Map<Id, DateTime> stageEntry = new Map<Id, DateTime>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ]) {
            // Match history entry to the opp's current stage — first hit (most recent) wins
            Opportunity o = opps[0]; // placeholder; we look up below
            if (!stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, null); // reserve slot
            }
        }

        // Build a lookup map for opp current stage, then re-scan history
        Map<Id, String> oppCurrentStage = new Map<Id, String>();
        for (Opportunity o : opps) oppCurrentStage.put(o.Id, o.StageName);

        stageEntry.clear();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ]) {
            String currentStage = oppCurrentStage.get(h.OpportunityId);
            if (h.NewValue == currentStage && !stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, h.CreatedDate);
            }
        }

        Date today = Date.today();
        for (Opportunity o : opps) {
            OppRow row           = new OppRow();
            row.id               = o.Id;
            row.name             = o.Name;
            row.stageName        = o.StageName;
            row.amount           = o.Amount;
            row.accountName      = o.Account.Name;
            row.accountId        = o.AccountId;
            row.closeDate        = o.CloseDate;
            row.contactRoleCount = o.OpportunityContactRoles.size();
            row.staleThreshold   = STALE_THRESHOLDS.containsKey(o.StageName)
                                    ? STALE_THRESHOLDS.get(o.StageName) : 21;

            DateTime entry  = stageEntry.get(o.Id);
            row.daysInStage = entry != null ? entry.date().daysBetween(today) : 0;
            row.isStale     = row.daysInStage > row.staleThreshold;

            if (!o.ActivityHistories.isEmpty())
                row.lastActivityDate = o.ActivityHistories[0].ActivityDate;
            if (!o.Gong__Conversations__r.isEmpty())
                row.lastGongCallDate = o.Gong__Conversations__r[0].Gong__Call_Start__c;

            rows.add(row);
        }
        return rows;
    }

    // ─── This Week's Commits ─────────────────────────────────────────────────────

    private static List<Weekly_Commit__c> buildThisWeekCommits(Id userId) {
        Date weekStart = getWeekStart(Date.today());
        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :weekStart
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
    }

    // ─── Last Week's Scorecard ───────────────────────────────────────────────────

    private static ScorecardData buildLastWeekScorecard(Id userId) {
        ScorecardData sc = new ScorecardData();
        Date lastWeekStart = getWeekStart(Date.today()).addDays(-7);
        Date lastWeekEnd   = lastWeekStart.addDays(6);

        sc.nnCommitsTotal       = 0;
        sc.nnCommitsCompleted   = 0;
        sc.progCommitsTotal     = 0;
        sc.progCommitsCompleted = 0;
        sc.progOppsAdvanced     = 0;
        sc.progOppsStalled      = 0;

        for (Weekly_Commit__c c : [
            SELECT Motion_Type__c, Completion_Status__c,
                   Committed_Count__c, Actual_Count__c,
                   Target_Opportunity__c, Target_Opportunity__r.StageName
            FROM Weekly_Commit__c
            WHERE Rep__c = :userId
              AND Week_Start_Date__c = :lastWeekStart
        ]) {
            if (c.Motion_Type__c == 'Net New') {
                sc.nnCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.nnCommitsCompleted++;
            } else if (c.Motion_Type__c == 'Progression') {
                sc.progCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.progCommitsCompleted++;
                if (c.Target_Opportunity__c != null) {
                    if (c.Target_Opportunity__r.StageName == STAGE_3) sc.progOppsAdvanced++;
                    else sc.progOppsStalled++;
                }
            }
        }

        AggregateResult[] nnRes = [
            SELECT SUM(Amount) tot, COUNT(Id) cnt
            FROM Opportunity
            WHERE OwnerId = :userId
              AND CreatedDate >= :lastWeekStart
              AND CreatedDate <= :lastWeekEnd
        ];
        sc.nnDollarGenerated = nnRes[0].get('tot') != null ? (Decimal)nnRes[0].get('tot') : 0;
        sc.nnOppsCreated     = nnRes[0].get('cnt') != null ? (Integer)nnRes[0].get('cnt') : 0;

        sc.progConversionRate = sc.progCommitsTotal > 0
            ? (sc.progOppsAdvanced * 100.0 / sc.progCommitsTotal)
            : 0;

        return sc;
    }

    // ─── Commit Mutations ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Weekly_Commit__c saveCommit(Weekly_Commit__c commitRecord) {
        commitRecord.Rep__c             = UserInfo.getUserId();
        commitRecord.Week_Start_Date__c = getWeekStart(Date.today());
        upsert commitRecord;
        return [
            SELECT Id, Rep__c, Week_Start_Date__c, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c WHERE Id = :commitRecord.Id
        ];
    }

    @AuraEnabled
    public static void deleteCommit(Id commitId) {
        delete new Weekly_Commit__c(Id = commitId);
    }

    // ─── Account Selection ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<AccountCard> getAccountsForSelection() {
        Id userId = UserInfo.getUserId();
        List<AccountCard> cards = new List<AccountCard>();
        for (Account a : [
            SELECT Id, Name, Type, Industry, Target_Account__c,
                (SELECT Id FROM Contacts WHERE IsDeleted = false),
                (SELECT Id FROM Opportunities WHERE IsClosed = false)
            FROM Account
            WHERE OwnerId = :userId
            ORDER BY Target_Account__c DESC, Name ASC
            LIMIT 300
        ]) {
            AccountCard card  = new AccountCard();
            card.id           = a.Id;
            card.name         = a.Name;
            card.type         = a.Type;
            card.industry     = a.Industry;
            card.isTargeted   = a.Target_Account__c;
            card.contactCount = a.Contacts.size();
            card.openOppCount = a.Opportunities.size();
            cards.add(card);
        }
        return cards;
    }

    @AuraEnabled
    public static void updateTargetAccounts(List<Id> toTarget, List<Id> toUntarget) {
        List<Account> updates = new List<Account>();
        for (Id id : (toTarget   != null ? toTarget   : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = true));
        for (Id id : (toUntarget != null ? toUntarget : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = false));
        if (!updates.isEmpty()) update updates;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    // Returns the Monday of the week containing d
    @TestVisible
    private static Date getWeekStart(Date d) {
        // Jan 1, 1900 was a Monday - use it as reference
        Date monday1900 = Date.newInstance(1900, 1, 1);
        Integer daysSince = monday1900.daysBetween(d);
        Integer dow = Math.mod(daysSince, 7);
        return d.addDays(-dow);
    }
}
