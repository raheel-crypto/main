public with sharing class InFlightOppsService {

    public static List<PipeGenController.OppRow> build(Id userId) {
        List<PipeGenController.OppRow> rows = new List<PipeGenController.OppRow>();

        Set<String> inFlightStages = PipeGenConfig.getInFlightStageNames();
        List<Opportunity> opps = OpportunitySelector.fetchInFlight(userId, inFlightStages);
        if (opps.isEmpty()) return rows;

        // Build a map of current stage per opp, then find when each opp last entered it
        Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
        Map<Id, String> oppCurrentStage = new Map<Id, String>();
        for (Opportunity o : opps) oppCurrentStage.put(o.Id, o.StageName);

        Map<Id, DateTime> stageEntry = new Map<Id, DateTime>();
        for (OpportunityFieldHistory h : OpportunitySelector.fetchStageHistory(oppIds)) {
            String currentStage = oppCurrentStage.get(h.OpportunityId);
            if (h.NewValue == currentStage && !stageEntry.containsKey(h.OpportunityId)) {
                stageEntry.put(h.OpportunityId, h.CreatedDate);
            }
        }

        Date today = Date.today();
        Map<Id, Opportunity> oppMap = new Map<Id, Opportunity>(opps);

        for (Opportunity o : opps) {
            PipeGenController.OppRow row = new PipeGenController.OppRow();
            row.id               = o.Id;
            row.name             = o.Name;
            row.stageName        = o.StageName;
            row.amount           = o.Amount;
            row.accountName      = o.Account.Name;
            row.accountId        = o.AccountId;
            row.closeDate        = o.CloseDate;
            row.contactRoleCount = o.OpportunityContactRoles.size();
            row.staleThreshold   = PipeGenConfig.getStaleThreshold(o.StageName);

            DateTime entry  = stageEntry.containsKey(o.Id) ? stageEntry.get(o.Id) : o.CreatedDate;
            row.daysInStage = entry != null ? entry.date().daysBetween(today) : 0;
            row.isStale     = row.daysInStage > row.staleThreshold;

            row.lastActivityDate = o.LastActivityDate;
            row.lastGongCallDate = null;
            rows.add(row);
        }

        // Populate lastGongCallDate via aggregate query — O(1) lookups instead of O(n²)
        Map<Id, DateTime> gongByOpp = OpportunitySelector.fetchLatestGongCallByOpp(oppIds);
        for (PipeGenController.OppRow r : rows) {
            r.lastGongCallDate = gongByOpp.get(r.id);
        }

        return rows;
    }
}
