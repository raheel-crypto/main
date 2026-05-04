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
        @AuraEnabled public Decimal        pipelineTarget;
        @AuraEnabled public Decimal        pipelineActual;
        @AuraEnabled public Integer        weeksRemaining;
        @AuraEnabled public String         quarter;
        @AuraEnabled public List<StageCard> stageCards;
    }

    public class StageCard {
        @AuraEnabled public String  stageName;
        @AuraEnabled public Integer oppCount;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Boolean isClosedWon;
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

    public class ManagerDashboardData {
        @AuraEnabled public List<RepSummary> reps;
        @AuraEnabled public TeamSummary      teamSummary;
    }

    public class TeamSummary {
        @AuraEnabled public Integer totalReps;
        @AuraEnabled public Integer totalCommits;
        @AuraEnabled public Integer completedCommits;
        @AuraEnabled public Integer atRiskCommitCount;
        @AuraEnabled public Integer repsWithNoCommits;
    }

    public class RepSummary {
        @AuraEnabled public String                 repId;
        @AuraEnabled public String                 repName;
        @AuraEnabled public List<Weekly_Commit__c> thisWeekCommits;
        @AuraEnabled public ScorecardData          lastWeekScorecard;
        @AuraEnabled public List<String>           riskReasons;
        @AuraEnabled public Boolean                hasRisk;
        @AuraEnabled public Integer                inFlightOppCount;
        @AuraEnabled public Integer                thisWeekTotal;
        @AuraEnabled public Integer                thisWeekCompleted;
        @AuraEnabled public Decimal                pipelineTarget;
        @AuraEnabled public Decimal                pipelineActual;
        @AuraEnabled public Integer                weeksRemaining;
        @AuraEnabled public String                 quarter;
        @AuraEnabled public Integer                lwOppsCreated;
        @AuraEnabled public Integer                qtdOppsCreated;
        @AuraEnabled public Integer                lwOppsToDiscovery;
        @AuraEnabled public Integer                qtdOppsToDiscovery;
    }

    // ─── Config Pass-throughs (used by service classes) ─────────────────────────

    // Exposed so PipeGenConfig can be reached through the controller in tests that
    // already reference PipeGenController.getWeekStart / STAGE_CLOSED_LOST etc.
    public static final String STAGE_CLOSED_LOST = PipeGenConfig.CLOSED_LOST;

    public static Boolean isPipelineStage(String s)  { return PipeGenConfig.isPipelineStage(s); }
    public static Boolean isClosedWonStage(String s)  { return PipeGenConfig.isClosedWon(s); }
    public static Boolean isAdvancedStage(String s)   { return PipeGenConfig.isAdvancedStage(s); }
    public static List<String> getStageOrderList()    { return PipeGenConfig.getStageOrderList(); }

    // ─── Rep Dashboard ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static DashboardData getRepDashboardData() {
        Id userId = UserInfo.getUserId();
        DashboardData d = new DashboardData();
        d.quarterlyTarget   = QuarterlyTargetService.build(userId);
        d.targetAccounts    = TargetAccountService.build(userId);
        d.inFlightOpps      = InFlightOppsService.build(userId);
        d.thisWeekCommits   = buildThisWeekCommits(userId);
        d.lastWeekScorecard = ScorecardService.buildLastWeek(userId);
        return d;
    }

    private static List<Weekly_Commit__c> buildThisWeekCommits(Id userId) {
        Date weekStart = getWeekStart(Date.today());
        Date weekEnd   = weekStart.addDays(6);
        List<Weekly_Commit__c> commits = CommitSelector.fetchForWeek(userId, weekStart);
        return CommitVerificationService.verify(commits, userId, weekStart, weekEnd);
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

    @AuraEnabled
    public static void markCommitComplete(Id commitId) {
        Weekly_Commit__c c = [
            SELECT Id, Committed_Count__c
            FROM Weekly_Commit__c
            WHERE Id = :commitId
            LIMIT 1
        ];
        c.Actual_Count__c      = c.Committed_Count__c != null ? c.Committed_Count__c.intValue() : 1;
        c.Completion_Status__c = 'Completed';
        update c;
    }

    // ─── Account Selection ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<AccountCard> getAccountsForSelection() {
        return SegmentationService.buildAccountCards(UserInfo.getUserId());
    }

    @AuraEnabled
    public static void updateTargetAccounts(List<Id> toTarget, List<Id> toUntarget) {
        List<Account> updates = new List<Account>();
        for (Id id : (toTarget   != null ? toTarget   : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = true));
        for (Id id : (toUntarget != null ? toUntarget : new List<Id>())) updates.add(new Account(Id = id, Target_Account__c = false));
        if (!updates.isEmpty()) update updates;
    }

    // ─── Manager Dashboard ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static ManagerDashboardData getManagerTeamData() {
        return ManagerDashboardService.build(UserInfo.getUserId());
    }

    // ─── Carry Forward ───────────────────────────────────────────────────────────

    @AuraEnabled
    public static List<Weekly_Commit__c> carryForwardIncompleteCommits() {
        Id   userId        = UserInfo.getUserId();
        Date weekStart     = getWeekStart(Date.today());
        Date lastWeekStart = weekStart.addDays(-7);

        List<Weekly_Commit__c> incomplete = CommitSelector.fetchIncomplete(userId, lastWeekStart);
        if (incomplete.isEmpty()) return new List<Weekly_Commit__c>();

        List<Weekly_Commit__c> toInsert = new List<Weekly_Commit__c>();
        for (Weekly_Commit__c c : incomplete) {
            toInsert.add(new Weekly_Commit__c(
                Rep__c                = userId,
                Week_Start_Date__c    = weekStart,
                Motion_Type__c        = c.Motion_Type__c,
                Commit_Type__c        = c.Commit_Type__c,
                Commit_Description__c = c.Commit_Description__c,
                Target_Account__c     = c.Target_Account__c,
                Target_Opportunity__c = c.Target_Opportunity__c,
                Committed_Count__c    = c.Committed_Count__c,
                Notes__c              = c.Notes__c
            ));
        }
        insert toInsert;

        return [
            SELECT Id, Motion_Type__c, Commit_Type__c, Commit_Description__c,
                   Target_Account__c, Target_Account__r.Name,
                   Target_Opportunity__c, Target_Opportunity__r.Name,
                   Committed_Count__c, Actual_Count__c,
                   Completion_Status__c, Gong_Verified__c, Notes__c
            FROM Weekly_Commit__c
            WHERE Id IN :toInsert
            ORDER BY Motion_Type__c ASC, CreatedDate ASC
        ];
    }

    // ─── Manager Actions ─────────────────────────────────────────────────────────

    @AuraEnabled
    public static void saveManagerNote(Id commitId, String note) {
        update new Weekly_Commit__c(Id = commitId, Manager_Note__c = note);
    }

    @AuraEnabled
    public static void setAtRiskFlag(Id commitId, Boolean atRisk) {
        update new Weekly_Commit__c(Id = commitId, At_Risk__c = atRisk);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    // Delegates to PipeGenConfig.getWeekStart; kept here for @TestVisible test compatibility
    @TestVisible
    public static Date getWeekStart(Date d) { return PipeGenConfig.getWeekStart(d); }
}
