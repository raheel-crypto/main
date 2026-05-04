public with sharing class OpportunitySelector {

    // ─── In-Flight Opportunities ─────────────────────────────────────────────────

    public static List<Opportunity> fetchInFlight(Id ownerId, Set<String> inFlightStages) {
        return [
            SELECT Id, Name, StageName, Amount, CloseDate, CreatedDate, LastActivityDate,
                   AccountId, Account.Name,
                (SELECT Name, Gong__Call_Start__c
                 FROM Gong__Conversations__r
                 ORDER BY Gong__Call_Start__c DESC LIMIT 1),
                (SELECT Id FROM OpportunityContactRoles WHERE IsDeleted = false)
            FROM Opportunity
            WHERE OwnerId = :ownerId
              AND StageName IN :inFlightStages
              AND IsClosed = false
              AND Type IN ('New Business', 'Upsell', 'Pilot')
            ORDER BY StageName ASC, CreatedDate ASC
        ];
    }

    // ─── Stage History (latest entry per opp for the current stage) ──────────────

    public static List<OpportunityFieldHistory> fetchStageHistory(Set<Id> oppIds) {
        return [
            SELECT OpportunityId, NewValue, CreatedDate
            FROM OpportunityFieldHistory
            WHERE Field = 'StageName'
              AND OpportunityId IN :oppIds
            ORDER BY CreatedDate DESC
        ];
    }

    // ─── Gong Call Timestamps Per Opportunity ────────────────────────────────────

    public static Map<Id, DateTime> fetchLatestGongCallByOpp(Set<Id> oppIds) {
        Map<Id, DateTime> result = new Map<Id, DateTime>();
        if (oppIds.isEmpty()) return result;
        for (AggregateResult ar : [
            SELECT Gong__Primary_Opportunity__c oppId, MAX(Gong__Call_Start__c) maxGong
            FROM Gong__Gong_Call__c
            WHERE Gong__Primary_Opportunity__c IN :oppIds
            GROUP BY Gong__Primary_Opportunity__c
        ]) {
            result.put((Id) ar.get('oppId'), (DateTime) ar.get('maxGong'));
        }
        return result;
    }

    // ─── Quarterly Qualifying Opportunities ──────────────────────────────────────

    public static Set<Id> fetchCreatedThisQuarter(Id ownerId, Date qStart, Date qEnd, String closedLostStage) {
        Set<Id> ids = new Set<Id>();
        for (Opportunity o : [
            SELECT Id FROM Opportunity
            WHERE OwnerId = :ownerId
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
              AND StageName != :closedLostStage
        ]) { ids.add(o.Id); }
        return ids;
    }

    public static List<Opportunity> fetchByIds(Set<Id> ids, Id ownerId, String closedLostStage) {
        return [
            SELECT Id, StageName, Amount, ARR__c
            FROM Opportunity
            WHERE Id IN :ids
              AND OwnerId = :ownerId
              AND StageName != :closedLostStage
        ];
    }

    // ─── Stage History for Quarter (pipeline-progressed opps) ───────────────────

    public static List<OpportunityFieldHistory> fetchStageHistoryForPeriod(Date qStart, Date qEnd) {
        return [
            SELECT OpportunityId, NewValue
            FROM OpportunityFieldHistory
            WHERE Field      = 'StageName'
              AND CreatedDate >= :qStart
              AND CreatedDate <= :qEnd
        ];
    }

    // ─── Stage Lookup for Scorecard ──────────────────────────────────────────────

    public static Map<Id, String> fetchStagesByIds(Set<Id> ids) {
        Map<Id, String> result = new Map<Id, String>();
        if (ids.isEmpty()) return result;
        for (Opportunity o : [SELECT Id, StageName FROM Opportunity WHERE Id IN :ids]) {
            result.put(o.Id, o.StageName);
        }
        return result;
    }

    // ─── Net-New Dollar/Count for Period ────────────────────────────────────────

    public static AggregateResult[] fetchNetNewForPeriod(Id ownerId, Date start, Date end) {
        return [
            SELECT SUM(Amount) tot, COUNT(Id) cnt
            FROM Opportunity
            WHERE OwnerId = :ownerId
              AND CreatedDate >= :start
              AND CreatedDate <= :end
        ];
    }

    // ─── In-Flight Count per Rep (Manager Dashboard) ─────────────────────────────

    public static Map<Id, Integer> fetchInFlightCountByRep(Set<Id> repIds, Set<String> inFlightStages) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        for (Id rid : repIds) result.put(rid, 0);
        for (AggregateResult ar : [
            SELECT OwnerId rid, COUNT(Id) cnt
            FROM   Opportunity
            WHERE  OwnerId IN :repIds
              AND  StageName IN :inFlightStages
              AND  IsClosed   = false
            GROUP BY OwnerId
        ]) { result.put((Id) ar.get('rid'), (Integer) ar.get('cnt')); }
        return result;
    }

    // ─── Manager Dashboard: Opp creation count per rep for a date range ──────────

    public static Map<Id, Integer> fetchCreatedCountByRep(
            Set<Id> repIds, Date rangeStart, Date rangeEnd, String closedLostStage) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        for (Id rid : repIds) result.put(rid, 0);
        for (AggregateResult ar : [
            SELECT OwnerId rid, COUNT(Id) cnt
            FROM   Opportunity
            WHERE  OwnerId     IN :repIds
              AND  CreatedDate >= :rangeStart
              AND  CreatedDate <= :rangeEnd
              AND  StageName   != :closedLostStage
            GROUP BY OwnerId
        ]) { result.put((Id) ar.get('rid'), (Integer) ar.get('cnt')); }
        return result;
    }

    // ─── Manager Dashboard: Opps moved to a specific stage per rep ───────────────

    public static Map<Id, Integer> fetchMovedToStageCountByRep(
            Set<Id> repIds, Date rangeStart, Date rangeEnd, String targetStage) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        for (Id rid : repIds) result.put(rid, 0);
        Set<Id> movedOppIds = new Set<Id>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId
            FROM   OpportunityFieldHistory
            WHERE  Field       = 'StageName'
              AND  NewValue    = :targetStage
              AND  CreatedDate >= :rangeStart
              AND  CreatedDate <= :rangeEnd
        ]) { movedOppIds.add(h.OpportunityId); }
        if (movedOppIds.isEmpty()) return result;
        for (AggregateResult ar : [
            SELECT OwnerId rid, COUNT(Id) cnt
            FROM   Opportunity
            WHERE  Id      IN :movedOppIds
              AND  OwnerId IN :repIds
            GROUP BY OwnerId
        ]) { result.put((Id) ar.get('rid'), (Integer) ar.get('cnt')); }
        return result;
    }

    // ─── Manager Dashboard: QTD pipeline actual ($ generated) per rep ────────────

    public static Map<Id, Decimal> fetchPipelineActualByRep(
            Set<Id> repIds, Date qStart, Date qEnd) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        for (Id rid : repIds) result.put(rid, 0);
        String closedLost = PipeGenConfig.CLOSED_LOST;

        Set<Id> createdQtd = new Set<Id>();
        for (Opportunity o : [
            SELECT Id FROM Opportunity
            WHERE  OwnerId     IN :repIds
              AND  CreatedDate >= :qStart
              AND  CreatedDate <= :qEnd
              AND  StageName   != :closedLost
        ]) { createdQtd.add(o.Id); }

        Set<Id> progressedPipeline = new Set<Id>();
        for (OpportunityFieldHistory h : [
            SELECT OpportunityId, NewValue
            FROM   OpportunityFieldHistory
            WHERE  Field       = 'StageName'
              AND  CreatedDate >= :qStart
              AND  CreatedDate <= :qEnd
        ]) {
            if (PipeGenConfig.isPipelineStage((String) h.NewValue))
                progressedPipeline.add(h.OpportunityId);
        }

        Set<Id> qualifyingIds = new Set<Id>(createdQtd);
        qualifyingIds.addAll(progressedPipeline);
        if (qualifyingIds.isEmpty()) return result;

        for (Opportunity o : [
            SELECT Id, OwnerId, StageName, Amount, ARR__c
            FROM   Opportunity
            WHERE  Id       IN :qualifyingIds
              AND  OwnerId  IN :repIds
              AND  StageName != :closedLost
        ]) {
            if (!PipeGenConfig.isPipelineStage(o.StageName)) continue;
            Decimal val = PipeGenConfig.isClosedWon(o.StageName)
                ? (o.ARR__c != null ? o.ARR__c : 0)
                : (o.Amount != null ? o.Amount : 0);
            result.put(o.OwnerId, result.get(o.OwnerId) + val);
        }
        return result;
    }
}
