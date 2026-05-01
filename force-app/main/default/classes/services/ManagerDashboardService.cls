public with sharing class ManagerDashboardService {

    public static PipeGenController.ManagerDashboardData build(Id managerId) {
        Date weekStart = PipeGenConfig.getWeekStart(Date.today());
        Date lwStart   = weekStart.addDays(-7);

        List<User> reps = UserSelector.fetchDirectReports(managerId);

        PipeGenController.ManagerDashboardData result = new PipeGenController.ManagerDashboardData();
        result.reps        = new List<PipeGenController.RepSummary>();
        result.teamSummary = new PipeGenController.TeamSummary();
        result.teamSummary.totalReps         = reps.size();
        result.teamSummary.totalCommits      = 0;
        result.teamSummary.completedCommits  = 0;
        result.teamSummary.atRiskCommitCount = 0;
        result.teamSummary.repsWithNoCommits = 0;
        if (reps.isEmpty()) return result;

        Set<Id> repIds = new Map<Id, User>(reps).keySet();

        // ── Commits ──────────────────────────────────────────────────────────────
        Map<Id, List<Weekly_Commit__c>> twByRep = groupCommitsByRep(
            CommitSelector.fetchTeamThisWeek(repIds, weekStart), repIds);
        Map<Id, List<Weekly_Commit__c>> lwByRep = groupCommitsByRep(
            CommitSelector.fetchTeamLastWeek(repIds, lwStart), repIds);

        // ── In-flight counts ─────────────────────────────────────────────────────
        Map<Id, Integer> inFlightByRep = OpportunitySelector.fetchInFlightCountByRep(
            repIds, PipeGenConfig.getInFlightStageNames());

        // ── Opp stages for last-week scorecard ───────────────────────────────────
        Set<Id> allOppIds = new Set<Id>();
        for (List<Weekly_Commit__c> lst : lwByRep.values())
            for (Weekly_Commit__c c : lst)
                if (c.Target_Opportunity__c != null) allOppIds.add(c.Target_Opportunity__c);
        Map<Id, String> oppStages = OpportunitySelector.fetchStagesByIds(allOppIds);

        // ── Per-rep summaries ────────────────────────────────────────────────────
        Integer teamTotal = 0, teamCompleted = 0, teamAtRisk = 0, teamNoCommits = 0;

        for (User rep : reps) {
            List<Weekly_Commit__c> twCommits = twByRep.get(rep.Id);
            List<Weekly_Commit__c> lwCommits = lwByRep.get(rep.Id);
            Integer inFlight = inFlightByRep.get(rep.Id);

            PipeGenController.RepSummary rs = new PipeGenController.RepSummary();
            rs.repId             = rep.Id;
            rs.repName           = rep.Name;
            rs.thisWeekCommits   = twCommits;
            rs.inFlightOppCount  = inFlight;
            rs.lastWeekScorecard = ScorecardService.buildFromCommits(lwCommits, oppStages);
            rs.riskReasons       = computeRiskReasons(twCommits, inFlight);
            rs.hasRisk           = !rs.riskReasons.isEmpty();
            rs.thisWeekTotal     = twCommits.size();
            rs.thisWeekCompleted = 0;
            for (Weekly_Commit__c c : twCommits) {
                if (c.Completion_Status__c == 'Completed') rs.thisWeekCompleted++;
                if (c.At_Risk__c) teamAtRisk++;
            }
            teamTotal     += twCommits.size();
            teamCompleted += rs.thisWeekCompleted;
            if (twCommits.isEmpty()) teamNoCommits++;

            result.reps.add(rs);
        }

        result.teamSummary.totalReps         = reps.size();
        result.teamSummary.totalCommits      = teamTotal;
        result.teamSummary.completedCommits  = teamCompleted;
        result.teamSummary.atRiskCommitCount = teamAtRisk;
        result.teamSummary.repsWithNoCommits = teamNoCommits;
        return result;
    }

    private static Map<Id, List<Weekly_Commit__c>> groupCommitsByRep(
            List<Weekly_Commit__c> commits, Set<Id> repIds) {
        Map<Id, List<Weekly_Commit__c>> byRep = new Map<Id, List<Weekly_Commit__c>>();
        for (Id rid : repIds) byRep.put(rid, new List<Weekly_Commit__c>());
        for (Weekly_Commit__c c : commits) byRep.get(c.Rep__c).add(c);
        return byRep;
    }

    private static List<String> computeRiskReasons(List<Weekly_Commit__c> commits, Integer inFlightCount) {
        List<String> reasons = new List<String>();
        if (commits.isEmpty()) {
            reasons.add('No commits this week');
            return reasons;
        }
        Integer progCount = 0, completedCount = 0;
        for (Weekly_Commit__c c : commits) {
            if (c.Motion_Type__c == 'Progression') progCount++;
            if (c.Completion_Status__c == 'Completed') completedCount++;
        }
        if (progCount == 0 && inFlightCount > 0)
            reasons.add(inFlightCount + ' in-flight opp' + (inFlightCount > 1 ? 's' : '') + ', no progression commit');
        if (completedCount == 0)
            reasons.add(commits.size() + ' commit' + (commits.size() > 1 ? 's' : '') + ' logged, none completed');
        return reasons;
    }
}
