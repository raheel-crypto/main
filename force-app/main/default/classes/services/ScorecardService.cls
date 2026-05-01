public with sharing class ScorecardService {

    public static PipeGenController.ScorecardData buildLastWeek(Id userId) {
        Date lastWeekStart = PipeGenConfig.getWeekStart(Date.today()).addDays(-7);
        Date lastWeekEnd   = lastWeekStart.addDays(6);

        List<Weekly_Commit__c> commits = CommitSelector.fetchForScorecard(userId, lastWeekStart);
        commits = CommitVerificationService.verify(commits, userId, lastWeekStart, lastWeekEnd);

        Set<Id> progOppIds = new Set<Id>();
        for (Weekly_Commit__c c : commits) {
            if (c.Motion_Type__c == 'Progression' && c.Target_Opportunity__c != null)
                progOppIds.add(c.Target_Opportunity__c);
        }
        Map<Id, String> oppStages = OpportunitySelector.fetchStagesByIds(progOppIds);

        PipeGenController.ScorecardData sc = buildFromCommits(commits, oppStages);

        AggregateResult[] nnRes = OpportunitySelector.fetchNetNewForPeriod(userId, lastWeekStart, lastWeekEnd);
        sc.nnDollarGenerated = nnRes[0].get('tot') != null ? (Decimal) nnRes[0].get('tot') : 0;
        sc.nnOppsCreated     = nnRes[0].get('cnt') != null ? (Integer) nnRes[0].get('cnt') : 0;

        return sc;
    }

    // Shared by both the rep scorecard and the manager dashboard per-rep scorecard
    public static PipeGenController.ScorecardData buildFromCommits(
            List<Weekly_Commit__c> commits, Map<Id, String> oppStages) {
        PipeGenController.ScorecardData sc = new PipeGenController.ScorecardData();
        sc.nnCommitsTotal       = 0; sc.nnCommitsCompleted   = 0;
        sc.progCommitsTotal     = 0; sc.progCommitsCompleted = 0;
        sc.progOppsAdvanced     = 0; sc.progOppsStalled      = 0;
        sc.nnDollarGenerated    = 0; sc.nnOppsCreated        = 0;

        for (Weekly_Commit__c c : commits) {
            if (c.Motion_Type__c == 'Net New') {
                sc.nnCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.nnCommitsCompleted++;
            } else if (c.Motion_Type__c == 'Progression') {
                sc.progCommitsTotal++;
                if (c.Completion_Status__c == 'Completed') sc.progCommitsCompleted++;
                String stage = oppStages != null ? oppStages.get(c.Target_Opportunity__c) : null;
                if (PipeGenConfig.isAdvancedStage(stage)) sc.progOppsAdvanced++;
                else if (stage != null)                   sc.progOppsStalled++;
            }
        }
        sc.progConversionRate = sc.progCommitsTotal > 0
            ? (sc.progOppsAdvanced * 100.0 / sc.progCommitsTotal) : 0;
        return sc;
    }
}
