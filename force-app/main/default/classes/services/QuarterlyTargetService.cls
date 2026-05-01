public with sharing class QuarterlyTargetService {

    public static PipeGenController.QuarterlyTarget build(Id userId) {
        PipeGenController.QuarterlyTarget qt = new PipeGenController.QuarterlyTarget();
        Date today = Date.today();

        Integer qStartMonth = ((today.month() - 1) / 3) * 3 + 1;
        Date qStart = Date.newInstance(today.year(), qStartMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);
        qt.quarter        = 'Q' + ((qStartMonth / 3) + 1) + ' ' + today.year();
        qt.weeksRemaining = Math.max(0, today.daysBetween(qEnd) / 7);

        User u = UserSelector.fetchCurrentUser(userId);
        Decimal annual = (u != null && u.Pipe_Gen_Annual_Target__c != null)
            ? u.Pipe_Gen_Annual_Target__c : 0;
        qt.pipelineTarget = annual / 4;

        // Opps created this quarter (excluding Closed Lost)
        Set<Id> createdThisQtr = OpportunitySelector.fetchCreatedThisQuarter(
            userId, qStart, qEnd, PipeGenConfig.CLOSED_LOST);

        // Opps that progressed into a pipeline stage this quarter
        Set<Id> progressedThisQtr = new Set<Id>();
        for (OpportunityFieldHistory h : OpportunitySelector.fetchStageHistoryForPeriod(qStart, qEnd)) {
            if (PipeGenConfig.isPipelineStage((String)h.NewValue))
                progressedThisQtr.add(h.OpportunityId);
        }

        Set<Id> qualifyingIds = new Set<Id>(createdThisQtr);
        qualifyingIds.addAll(progressedThisQtr);

        List<String> stageOrder = PipeGenConfig.getStageOrderList();
        Map<String, PipeGenController.StageCard> cardMap = new Map<String, PipeGenController.StageCard>();
        for (String s : stageOrder) {
            PipeGenController.StageCard sc = new PipeGenController.StageCard();
            sc.stageName   = s;
            sc.oppCount    = 0;
            sc.amount      = 0;
            sc.isClosedWon = PipeGenConfig.isClosedWon(s);
            cardMap.put(s, sc);
        }

        Decimal pipelineActual = 0;
        if (!qualifyingIds.isEmpty()) {
            for (Opportunity o : OpportunitySelector.fetchByIds(
                    qualifyingIds, userId, PipeGenConfig.CLOSED_LOST)) {
                PipeGenController.StageCard sc = cardMap.get(o.StageName);
                if (sc == null) continue;
                sc.oppCount++;
                Decimal val = PipeGenConfig.isClosedWon(o.StageName)
                    ? (o.ARR__c  != null ? o.ARR__c  : 0)
                    : (o.Amount  != null ? o.Amount  : 0);
                sc.amount += val;
                if (PipeGenConfig.isPipelineStage(o.StageName)) pipelineActual += val;
            }
        }

        qt.pipelineActual = pipelineActual;
        qt.stageCards     = new List<PipeGenController.StageCard>();
        for (String s : stageOrder) qt.stageCards.add(cardMap.get(s));
        return qt;
    }
}
