public with sharing class PipeGenController {

    // ─── Wrapper Classes ────────────────────────────────────────────────────────

    public class DashboardData {
        @AuraEnabled public QuarterlyTarget quarterlyTarget;
        @AuraEnabled public List<AccountRow>  targetAccounts;
        @AuraEnabled public List<OppRow>      stage1Opps;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public ScorecardData     lastWeekScorecard;
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
        @AuraEnabled public Decimal  amount;
        @AuraEnabled public String   accountName;
        @AuraEnabled public String   accountId;
        @AuraEnabled public Integer  daysInStage;
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

    // ─── Config ─────────────────────────────────────────────────────────────────

    // Adjust stage names to match your org's picklist values
    private static final String STAGE_1       = 'Stage 1';
    private static final String STAGE_3       = 'Stage 3';
    private static final Integer STALE_DAYS   = 21;

    // ─── Main Entry Point ────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static DashboardData getRepDashboardData() {
        Id userId = UserInfo.getUserId();
        DashboardData d = new DashboardData();
        d.quarterlyTarget  = buildQuarterlyTarget(userId);
        d.targetAccounts   = buildTargetAccounts(userId);
        d.stage1Opps       = buildStage1Opps(userId);
        d.thisWeekCommits  = buildThisWeekCommits(userId);
        d.lastWeekScorecard = buildLastWeekScorecard(userId);
        return d;
    }

    // ─── Quarterly Target ────────────────────────────────────────────────────────

    private static QuarterlyTarget buildQuarterlyTarget(Id userId) {
        QuarterlyTarget qt = new QuarterlyTarget();
        Date today = Date.today();

        // Quarter boundaries
        Integer qStartMonth = ((today.month() - 1) / 3) * 3 + 1;
        Date qStart = Date.newInstance(today.year(), qStartMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);
        qt.quarter  = 'Q' + ((qStartMonth / 3) + 1) + ' ' + today.year();
        qt.weeksRemaining = Math.max(0, today.daysBetween(qEnd) / 7);

        // Quota — stored on User as Pipe_Gen_Annual_Target__c (create this field or swap in your own)
        Decimal annual = 0;
        try {
            User u = [SELECT Pipe_Gen_Annual_Target__c FROM User WHERE Id = :userId LIMIT 1];
            annual = u.Pipe_Gen_Annual_Target__c != null ? u.Pipe_Gen_Annual_Target__c : 0;
        } catch (Exception e) { annual = 0; }

        qt.totalTarget       = annual / 4;
        qt.netNewTarget      = qt.totalTarget * 0.5;
        qt.progressionTarget = qt.totalTarget * 0.5;

        // Net New Actual: opps the rep created this quarter (any non-zero stage)
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

        // Progression Actual: opps owned by rep that entered Stage 3 this quarter
        Set<Id> stage3Ids = new Set<Id>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND NewValue = :STAGE_3
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
        ]) { stage3Ids.add(h.OpportunityId); }

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

        // ADJUST: Target_Account__c is a checkbox field on Account marking it as a target.
        // Swap in your own filter if you use a different field (e.g. Account_Tier__c = 'Tier 1').
        // ADJUST: Gong__gong_calls__r is the child relationship name from Account → Gong__gong_call__c.
        //         Confirm in Setup → Object Manager → Gong__gong_call__c → Fields → Account lookup → Child Relationship Name.
        // ADJUST: Gong__Start_Time__c is the call date field in the standard Gong package — verify in your org.
        List<Account> accounts = [
            SELECT Id, Name, Type,
                (SELECT ActivityDate, Subject
                 FROM ActivityHistories
                 WHERE ActivityDate != null
                 ORDER BY ActivityDate DESC LIMIT 1),
                (SELECT Name, Gong__Start_Time__c
                 FROM Gong__gong_calls__r
                 ORDER BY Gong__Start_Time__c DESC LIMIT 1),
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
            if (!a.ActivityHistories.isEmpty()) {
                row.lastActivityDate    = a.ActivityHistories[0].ActivityDate;
                row.lastActivitySubject = a.ActivityHistories[0].Subject;
            }
            if (!a.Gong__gong_calls__r.isEmpty()) {
                row.lastGongCallDate = a.Gong__gong_calls__r[0].Gong__Start_Time__c;
            }
            rows.add(row);
        }
        return rows;
    }

    // ─── Stage 1 Opps ───────────────────────────────────────────────────────────

    private static List<OppRow> buildStage1Opps(Id userId) {
        List<OppRow> rows = new List<OppRow>();

        // ADJUST: Gong__gong_calls__r on Opportunity — confirm relationship name for your Gong package.
        // ADJUST: Gong__Start_Time__c is the call date field — verify in your org.
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, CloseDate, AccountId, Account.Name,
                (SELECT ActivityDate, Subject
                 FROM ActivityHistories
                 ORDER BY ActivityDate DESC LIMIT 1),
                (SELECT Name, Gong__Start_Time__c
                 FROM Gong__gong_calls__r
                 ORDER BY Gong__Start_Time__c DESC LIMIT 1),
                (SELECT Id FROM OpportunityContactRoles WHERE IsDeleted = false)
            FROM Opportunity
            WHERE OwnerId = :userId
              AND StageName = :STAGE_1
              AND IsClosed = false
            ORDER BY CreatedDate ASC
        ];

        if (opps.isEmpty()) return rows;

        // Get when each opp last entered Stage 1 from field history
        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Map<Id, DateTime> stageEntry = new Map<Id, DateTime>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND NewValue = :STAGE_1
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, h.CreatedDate);
            }
        }

        Date today = Date.today();
        for (Opportunity o : opps) {
            OppRow row          = new OppRow();
            row.id              = o.Id;
            row.name            = o.Name;
            row.amount          = o.Amount;
            row.accountName     = o.Account.Name;
            row.accountId       = o.AccountId;
            row.closeDate       = o.CloseDate;
            row.contactRoleCount = o.OpportunityContactRoles.size();

            DateTime entry   = stageEntry.get(o.Id);
            row.daysInStage  = entry != null ? entry.date().daysBetween(today) : 0;
            row.isStale      = row.daysInStage > STALE_DAYS;

            if (!o.ActivityHistories.isEmpty())
                row.lastActivityDate = o.ActivityHistories[0].ActivityDate;
            if (!o.Gong__gong_calls__r.isEmpty())
                row.lastGongCallDate = o.Gong__gong_calls__r[0].Gong__Start_Time__c;

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

        sc.nnCommitsTotal      = 0;
        sc.nnCommitsCompleted  = 0;
        sc.progCommitsTotal    = 0;
        sc.progCommitsCompleted = 0;
        sc.progOppsAdvanced    = 0;
        sc.progOppsStalled     = 0;

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

        // Net new $ and opp count from opps created last week
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
    public static Weekly_Commit__c saveCommit(Weekly_Commit__c commit) {
        commit.Rep__c             = UserInfo.getUserId();
        commit.Week_Start_Date__c = getWeekStart(Date.today());
        upsert commit;
        // Re-query to return lookup name fields
        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c WHERE Id = :commit.Id
        ];
    }

    @AuraEnabled
    public static void deleteCommit(Id commitId) {
        delete new Weekly_Commit__c(Id = commitId);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    // Returns the Monday of the week containing d
    private static Date getWeekStart(Date d) {
        Integer dow = Math.mod(Date.newInstance(1900, 1, 7).daysBetween(d), 7);
        return d.addDays(-dow);
    }
}
