/**
 * PGInsightsController
 *
 * Backs the pgInsightsApp LWC with aggregated Pipeline Generation metrics.
 *
 * Pipeline = opportunities (NB or Upsell) that FIRST entered Stage 2 or beyond
 * during the window. Source of truth is OpportunityHistory: a deal that
 * jumped from Stage 1 directly to Stage 4 still counts on the date of that
 * jump. Deals still in Stage 1 do not count.
 *
 * Outbound activity sources:
 *   - Emails / Calls / LinkedIn = Task.TaskSubtype with Status='Completed'
 *   - Meetings                  = Event records (OwnerId is the AE)
 */
public with sharing class PGInsightsController {

    // ---- Org-specific configuration --------------------------------------------------

    private static final Set<String> AE_PODS = new Set<String>{
        'ENT 1', 'ENT 2', 'MM/HV', 'NV'
    };

    private static final String NB_TYPE  = 'New Business';
    private static final String EXP_TYPE = 'Upsell';

    // Any of these StageName values count as "Stage 2 or beyond".
    private static final Set<String> STAGE_2_PLUS = new Set<String>{
        '2 - Discovery',
        '3 - POV',
        '4 - Proposal',
        '5 - Contracting',
        'Closed Won'
    };

    // Default goal until per-rep / per-quarter quotas are wired in.
    private static final Decimal DEFAULT_QUARTERLY_GOAL = 0;

    // ---- Per-transaction caches ------------------------------------------------------

    private static Set<Id>            aeUserIdsCache;
    private static Map<Id, DateTime>  firstStage2PlusCache;
    private static Map<Id, Opportunity> oppDetailsCache;
    private static Integer            fiscalStartMonthCache;

    // ---- Result wrappers -------------------------------------------------------------

    public class PacingKpis {
        @AuraEnabled public String windowLabel;
        @AuraEnabled public Integer newBusiness;
        @AuraEnabled public Integer expansion;
        @AuraEnabled public Decimal nbPctOfTotal;
        @AuraEnabled public Integer deltaNB;
        @AuraEnabled public Integer deltaExp;
        @AuraEnabled public Decimal deltaPct;
    }

    public class QuarterRow {
        @AuraEnabled public String fiscalLabel;
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goal;
    }

    public class S1Status {
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goalMTD;
        @AuraEnabled public Decimal attainmentPct;
    }

    public class PerformerRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goal;
        @AuraEnabled public Decimal attainmentPct;
    }

    public class OutreachRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Integer emails;
        @AuraEnabled public Integer calls;
        @AuraEnabled public Integer linkedin;
        @AuraEnabled public Integer meetings;
        @AuraEnabled public Integer total;
    }

    // ---- @AuraEnabled API ------------------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static PacingKpis getPacingKpis(String windowLabel) {
        Date today = Date.today();
        Date currStart, currEnd, priorStart, priorEnd;
        if (windowLabel == 'WoW') {
            // 7-day rolling window, anchored at today.
            currStart  = today.addDays(-6);  currEnd  = today;
            priorStart = today.addDays(-13); priorEnd = today.addDays(-7);
        } else {
            // Calendar month boundaries.
            currStart  = today.toStartOfMonth();
            currEnd    = today;
            priorEnd   = currStart.addDays(-1);
            priorStart = priorEnd.toStartOfMonth();
        }

        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Set<Id> currIds  = new Set<Id>();
        Set<Id> priorIds = new Set<Id>();
        for (Id oid : firstDates.keySet()) {
            Date d = firstDates.get(oid).date();
            if (d >= currStart  && d <= currEnd)  currIds.add(oid);
            if (d >= priorStart && d <= priorEnd) priorIds.add(oid);
        }

        Map<Id, Opportunity> opps = getOppDetails(unionIds(currIds, priorIds));
        Map<String, Integer> curr  = countByType(currIds, opps);
        Map<String, Integer> prior = countByType(priorIds, opps);

        PacingKpis k = new PacingKpis();
        k.windowLabel  = windowLabel;
        k.newBusiness  = curr.get(NB_TYPE);
        k.expansion    = curr.get(EXP_TYPE);
        Integer total  = k.newBusiness + k.expansion;
        k.nbPctOfTotal = total == 0 ? 0 : (Decimal.valueOf(k.newBusiness) / total) * 100;
        k.deltaNB      = k.newBusiness - prior.get(NB_TYPE);
        k.deltaExp     = k.expansion   - prior.get(EXP_TYPE);
        Integer priorTotal = prior.get(NB_TYPE) + prior.get(EXP_TYPE);
        Decimal priorPct   = priorTotal == 0 ? 0 : (Decimal.valueOf(prior.get(NB_TYPE)) / priorTotal) * 100;
        k.deltaPct = k.nbPctOfTotal - priorPct;
        return k;
    }

    @AuraEnabled(cacheable=true)
    public static List<QuarterRow> getStageProgressByQuarter(Integer numQuarters) {
        Integer n = (numQuarters == null || numQuarters <= 0) ? 8 : numQuarters;
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Map<Id, Opportunity> opps = getOppDetails(firstDates.keySet());

        Map<Integer, QuarterRow> byKey = new Map<Integer, QuarterRow>();
        for (Id oid : firstDates.keySet()) {
            Opportunity o = opps.get(oid);
            if (o == null || (o.Type != NB_TYPE && o.Type != EXP_TYPE)) continue;
            Date d = firstDates.get(oid).date();
            Integer sortKey = fiscalSortKey(d);
            QuarterRow row = byKey.get(sortKey);
            if (row == null) {
                row = new QuarterRow();
                row.fiscalLabel = fiscalLabelFor(d);
                row.nbCount  = 0;
                row.expCount = 0;
                row.goal     = DEFAULT_QUARTERLY_GOAL;
                byKey.put(sortKey, row);
            }
            if (o.Type == NB_TYPE) row.nbCount  += 1;
            else                   row.expCount += 1;
        }

        List<Integer> sortedKeys = new List<Integer>(byKey.keySet());
        sortedKeys.sort();
        List<QuarterRow> rows = new List<QuarterRow>();
        for (Integer k : sortedKeys) rows.add(byKey.get(k));
        if (rows.size() > n) {
            List<QuarterRow> trimmed = new List<QuarterRow>();
            for (Integer i = rows.size() - n; i < rows.size(); i++) trimmed.add(rows[i]);
            rows = trimmed;
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static S1Status getS1StatusQTD() {
        S1Status s = new S1Status();
        s.nbCount = 0;
        s.expCount = 0;
        s.goalMTD = DEFAULT_QUARTERLY_GOAL;
        s.attainmentPct = 0;

        Date qStart = startOfCurrentFiscalQuarter();
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Set<Id> qIds = new Set<Id>();
        for (Id oid : firstDates.keySet()) {
            if (firstDates.get(oid).date() >= qStart) qIds.add(oid);
        }
        Map<Id, Opportunity> opps = getOppDetails(qIds);
        Map<String, Integer> counts = countByType(qIds, opps);
        s.nbCount = counts.get(NB_TYPE);
        s.expCount = counts.get(EXP_TYPE);
        s.attainmentPct = s.goalMTD == 0 ? 0 : ((s.nbCount + s.expCount) / s.goalMTD) * 100;
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static List<PerformerRow> getTopPerformers(Integer topN) {
        Integer n = (topN == null || topN <= 0) ? 5 : topN;
        Date qStart = startOfCurrentFiscalQuarter();
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();

        Set<Id> qIds = new Set<Id>();
        for (Id oid : firstDates.keySet()) {
            if (firstDates.get(oid).date() >= qStart) qIds.add(oid);
        }
        Map<Id, Opportunity> opps = getOppDetails(qIds);

        Map<Id, PerformerRow> byOwner = new Map<Id, PerformerRow>();
        for (Id oid : qIds) {
            Opportunity o = opps.get(oid);
            if (o == null || (o.Type != NB_TYPE && o.Type != EXP_TYPE)) continue;
            PerformerRow row = byOwner.get(o.OwnerId);
            if (row == null) {
                row = new PerformerRow();
                row.ownerId = o.OwnerId;
                row.ownerName = o.Owner != null ? o.Owner.Name : null;
                row.nbCount = 0;
                row.expCount = 0;
                row.goal = DEFAULT_QUARTERLY_GOAL;
                byOwner.put(o.OwnerId, row);
            }
            if (o.Type == NB_TYPE) row.nbCount  += 1;
            else                   row.expCount += 1;
        }

        List<PerformerRow> result = new List<PerformerRow>();
        for (PerformerRow row : byOwner.values()) {
            row.attainmentPct = row.goal == 0 ? 0
                : ((row.nbCount + row.expCount) / row.goal) * 100;
            result.add(row);
        }
        result.sort(new PerformerComparator());
        if (result.size() > n) {
            List<PerformerRow> trimmed = new List<PerformerRow>();
            for (Integer i = 0; i < n; i++) trimmed.add(result[i]);
            result = trimmed;
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<OutreachRow> getIndividualOutreach(String windowLabel) {
        Set<Id> aes = getAeUserIds();
        List<OutreachRow> result = new List<OutreachRow>();
        if (aes.isEmpty()) return result;

        Map<Id, OutreachRow> byOwner = new Map<Id, OutreachRow>();

        // Tasks: emails, calls, LinkedIn touches
        for (AggregateResult ar : queryTaskAggregates(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            String subtype = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            if (subtype == 'Email')         row.emails   = cnt;
            else if (subtype == 'Call')     row.calls    = cnt;
            else if (subtype == 'LinkedIn') row.linkedin = cnt;
        }

        // Meetings live on the standard Event object.
        for (AggregateResult ar : queryEventMeetings(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            row.meetings = cnt;
        }

        for (OutreachRow row : byOwner.values()) {
            row.total = row.emails + row.calls + row.linkedin + row.meetings;
            if (row.ownerName != null) result.add(row);
        }
        result.sort(new OutreachComparator());
        return result;
    }

    // ---- Private helpers -------------------------------------------------------------

    private static Set<Id> getAeUserIds() {
        if (aeUserIdsCache != null) return aeUserIdsCache;
        Set<Id> ids = new Set<Id>();
        for (User u : [
            SELECT Id, Title FROM User
            WHERE IsActive = TRUE AND Pod__c IN :AE_PODS
        ]) {
            if (u.Title == null || !u.Title.containsIgnoreCase('BDR')) ids.add(u.Id);
        }
        aeUserIdsCache = ids;
        return ids;
    }

    private static Map<Id, DateTime> getFirstStage2PlusByOpp() {
        if (firstStage2PlusCache != null) return firstStage2PlusCache;
        Set<Id> aes = getAeUserIds();
        Map<Id, DateTime> out = new Map<Id, DateTime>();
        if (aes.isEmpty()) {
            firstStage2PlusCache = out;
            return out;
        }

        // Two-step query: relationship filters on OpportunityHistory
        // (Opportunity.OwnerId / Opportunity.Type) behave inconsistently in
        // some test contexts and in orgs with packaged trigger interference.
        // Pull the AE-owned NB/Upsell opp IDs first, then aggregate history
        // by direct OpportunityId IN clause.
        Set<Id> aeOppIds = new Set<Id>();
        for (Opportunity o : [
            SELECT Id FROM Opportunity
            WHERE OwnerId IN :aes
              AND Type IN (:NB_TYPE, :EXP_TYPE)
        ]) {
            aeOppIds.add(o.Id);
        }
        if (aeOppIds.isEmpty()) {
            firstStage2PlusCache = out;
            return out;
        }

        for (AggregateResult ar : [
            SELECT OpportunityId oid, MIN(CreatedDate) firstDt
            FROM OpportunityHistory
            WHERE StageName IN :STAGE_2_PLUS
              AND OpportunityId IN :aeOppIds
            GROUP BY OpportunityId
        ]) {
            out.put((Id) ar.get('oid'), (DateTime) ar.get('firstDt'));
        }
        firstStage2PlusCache = out;
        return out;
    }

    private static Map<Id, Opportunity> getOppDetails(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return new Map<Id, Opportunity>();
        return new Map<Id, Opportunity>([
            SELECT Id, Type, OwnerId, Owner.Name FROM Opportunity WHERE Id IN :ids
        ]);
    }

    private static Set<Id> unionIds(Set<Id> a, Set<Id> b) {
        Set<Id> out = new Set<Id>();
        out.addAll(a);
        out.addAll(b);
        return out;
    }

    private static Map<String, Integer> countByType(Set<Id> oppIds, Map<Id, Opportunity> opps) {
        Map<String, Integer> out = new Map<String, Integer>{NB_TYPE => 0, EXP_TYPE => 0};
        for (Id oid : oppIds) {
            Opportunity o = opps.get(oid);
            if (o == null) continue;
            if (out.containsKey(o.Type)) out.put(o.Type, out.get(o.Type) + 1);
        }
        return out;
    }

    private static OutreachRow ensureRow(Map<Id, OutreachRow> byOwner, Id ownerId, String ownerName) {
        OutreachRow row = byOwner.get(ownerId);
        if (row == null) {
            row = new OutreachRow();
            row.ownerId = ownerId;
            row.ownerName = ownerName;
            row.emails = 0;
            row.calls = 0;
            row.linkedin = 0;
            row.meetings = 0;
            row.total = 0;
            byOwner.put(ownerId, row);
        } else if (row.ownerName == null) {
            row.ownerName = ownerName;
        }
        return row;
    }

    private static Integer getFiscalStartMonth() {
        if (fiscalStartMonthCache != null) return fiscalStartMonthCache;
        Organization org = [SELECT FiscalYearStartMonth FROM Organization LIMIT 1];
        fiscalStartMonthCache = org.FiscalYearStartMonth;
        return fiscalStartMonthCache;
    }

    private static Date startOfCurrentFiscalQuarter() {
        Integer startMonth = getFiscalStartMonth();
        Date today = Date.today();
        Integer monthOffset = today.month() - startMonth;
        if (monthOffset < 0) monthOffset += 12;
        Integer monthsIntoQuarter = Math.mod(monthOffset, 3);
        return today.toStartOfMonth().addMonths(-monthsIntoQuarter);
    }

    private static Integer fiscalSortKey(Date d) {
        Integer startMonth = getFiscalStartMonth();
        Integer monthOffset = d.month() - startMonth;
        if (monthOffset < 0) monthOffset += 12;
        Integer fq = (monthOffset / 3) + 1;
        Integer fy;
        if (startMonth == 1) fy = d.year();
        else fy = (d.month() >= startMonth) ? d.year() + 1 : d.year();
        return fy * 10 + fq;
    }

    private static String fiscalLabelFor(Date d) {
        Integer startMonth = getFiscalStartMonth();
        Integer monthOffset = d.month() - startMonth;
        if (monthOffset < 0) monthOffset += 12;
        Integer fq = (monthOffset / 3) + 1;
        Integer fy;
        if (startMonth == 1) fy = d.year();
        else fy = (d.month() >= startMonth) ? d.year() + 1 : d.year();
        return 'FY' + fy + '-Q' + fq;
    }

    private static List<AggregateResult> queryTaskAggregates(Set<Id> aes, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :aes
                  AND Status = 'Completed'
                  AND TaskSubtype IN ('Email', 'Call', 'LinkedIn')
                  AND CompletedDateTime = THIS_WEEK
                GROUP BY OwnerId, Owner.Name, TaskSubtype
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
            FROM Task
            WHERE OwnerId IN :aes
              AND Status = 'Completed'
              AND TaskSubtype IN ('Email', 'Call', 'LinkedIn')
              AND CompletedDateTime = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name, TaskSubtype
        ];
    }

    private static List<AggregateResult> queryEventMeetings(Set<Id> aes, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Event
                WHERE OwnerId IN :aes
                  AND ActivityDate = THIS_WEEK
                GROUP BY OwnerId, Owner.Name
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
            FROM Event
            WHERE OwnerId IN :aes
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
        ];
    }

    private class PerformerComparator implements Comparator<PerformerRow> {
        public Integer compare(PerformerRow a, PerformerRow b) {
            Decimal aScore = a.goal > 0 ? a.attainmentPct : a.nbCount + a.expCount;
            Decimal bScore = b.goal > 0 ? b.attainmentPct : b.nbCount + b.expCount;
            if (bScore > aScore) return 1;
            if (bScore < aScore) return -1;
            return 0;
        }
    }

    private class OutreachComparator implements Comparator<OutreachRow> {
        public Integer compare(OutreachRow a, OutreachRow b) {
            if (b.total > a.total) return 1;
            if (b.total < a.total) return -1;
            return 0;
        }
    }
}
