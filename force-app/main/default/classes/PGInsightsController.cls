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
        'ENT 1', 'ENT 2', 'MM/HV'
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
    private static Map<String, Set<Id>> aeUserIdsByPodCache;
    private static Map<Id, DateTime>  firstStage2PlusCache;
    private static Map<Id, Opportunity> oppDetailsCache;
    private static Integer            fiscalStartMonthCache;

    // Test seam: this org's test context does not auto-create OpportunityHistory
    // on opp insert (verified via diagnostic test — Hist=0 even after a clean
    // insert of stage-2 opps), and OpportunityHistory is a read-only object
    // so direct DML isn't allowed. Tests assign this map to bypass the
    // history query while leaving the production code path untouched.
    @TestVisible
    private static Map<Id, DateTime>  mockFirstStage2PlusByOpp;

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

    public class PodPerformers {
        @AuraEnabled public String pod;
        @AuraEnabled public List<PerformerRow> rows;
        @AuraEnabled public Integer totalNb;
        @AuraEnabled public Integer totalExp;
        @AuraEnabled public Decimal totalGoalMTD;
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

    public class HeatmapRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String managerName;
        // Conversion percentages for each transition (0-100).
        @AuraEnabled public Decimal demoToDisco;
        @AuraEnabled public Decimal discoToPov;
        @AuraEnabled public Decimal povToProposal;
        @AuraEnabled public Decimal proposalToContracting;
        @AuraEnabled public Decimal contractingToWon;
        // Underlying counts (opps that ever reached this stage or beyond).
        @AuraEnabled public Integer demoCount;
        @AuraEnabled public Integer discoveryCount;
        @AuraEnabled public Integer povCount;
        @AuraEnabled public Integer proposalCount;
        @AuraEnabled public Integer contractingCount;
        @AuraEnabled public Integer wonCount;
    }

    private static final Map<String, Integer> STAGE_RANK = new Map<String, Integer>{
        '1 - Demo'        => 1,
        '2 - Discovery'   => 2,
        '3 - POV'         => 3,
        '4 - Proposal'    => 4,
        '5 - Contracting' => 5,
        'Closed Won'      => 6
    };

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

        // Overlay quarterly goals from PG_Quota__c (sum across AEs per quarter).
        Map<Integer, Decimal> quarterGoals = getQuarterGoals();
        for (Integer key : byKey.keySet()) {
            if (quarterGoals.containsKey(key)) byKey.get(key).goal = quarterGoals.get(key);
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
        s.goalMTD = 0;
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

        // Sum current-quarter quotas across all AEs and prorate by days into quarter.
        Map<Id, Decimal[]> quotas = getQuotasForCurrentQuarter();
        Decimal totalQuarterly = 0;
        for (Decimal[] g : quotas.values()) totalQuarterly += g[0] + g[1];
        s.goalMTD = totalQuarterly * mtdProration();
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

        Map<Id, Decimal[]> quotas = getQuotasForCurrentQuarter();
        Decimal proration = mtdProration();

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
                Decimal[] g = quotas.get(o.OwnerId);
                Decimal quarterly = g == null ? 0 : g[0] + g[1];
                row.goal = quarterly * proration;
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
    public static List<PodPerformers> getTopPerformersByPod(Integer topN) {
        Integer n = (topN == null || topN <= 0) ? 5 : topN;
        Date qStart = startOfCurrentFiscalQuarter();
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();

        Set<Id> qIds = new Set<Id>();
        for (Id oid : firstDates.keySet()) {
            if (firstDates.get(oid).date() >= qStart) qIds.add(oid);
        }
        Map<Id, Opportunity> opps = getOppDetails(qIds);
        Map<Id, Decimal[]> quotas = getQuotasForCurrentQuarter();
        Decimal proration = mtdProration();

        Map<String, Set<Id>> aesByPod = getAeUserIdsByPod();
        Map<Id, String> podByAe = new Map<Id, String>();
        for (String pod : aesByPod.keySet()) {
            for (Id aeId : aesByPod.get(pod)) podByAe.put(aeId, pod);
        }

        Map<String, Map<Id, PerformerRow>> rowsByPod = new Map<String, Map<Id, PerformerRow>>();
        for (String pod : aesByPod.keySet()) rowsByPod.put(pod, new Map<Id, PerformerRow>());

        for (Id oid : qIds) {
            Opportunity o = opps.get(oid);
            if (o == null || (o.Type != NB_TYPE && o.Type != EXP_TYPE)) continue;
            String pod = podByAe.get(o.OwnerId);
            if (pod == null) continue;
            Map<Id, PerformerRow> bucket = rowsByPod.get(pod);
            PerformerRow row = bucket.get(o.OwnerId);
            if (row == null) {
                row = new PerformerRow();
                row.ownerId = o.OwnerId;
                row.ownerName = o.Owner != null ? o.Owner.Name : null;
                row.nbCount = 0;
                row.expCount = 0;
                Decimal[] g = quotas.get(o.OwnerId);
                Decimal quarterly = g == null ? 0 : g[0] + g[1];
                row.goal = quarterly * proration;
                bucket.put(o.OwnerId, row);
            }
            if (o.Type == NB_TYPE) row.nbCount  += 1;
            else                   row.expCount += 1;
        }

        List<PodPerformers> result = new List<PodPerformers>();
        List<String> sortedPods = new List<String>(aesByPod.keySet());
        sortedPods.sort();
        for (String pod : sortedPods) {
            PodPerformers pp = new PodPerformers();
            pp.pod = pod;

            // Pod totals: sum across the pod's quotas (not just top N rows)
            // and across all stage-2+ counts seen for the pod's AEs.
            Integer totalNb = 0, totalExp = 0;
            for (PerformerRow row : rowsByPod.get(pod).values()) {
                totalNb  += row.nbCount;
                totalExp += row.expCount;
            }
            Decimal totalGoalMTD = 0;
            for (Id aeId : aesByPod.get(pod)) {
                Decimal[] g = quotas.get(aeId);
                if (g != null) totalGoalMTD += (g[0] + g[1]) * proration;
            }
            pp.totalNb = totalNb;
            pp.totalExp = totalExp;
            pp.totalGoalMTD = totalGoalMTD;
            pp.attainmentPct = totalGoalMTD == 0 ? 0
                : ((totalNb + totalExp) / totalGoalMTD) * 100;

            // Per-rep attainment + sort + trim to top N.
            List<PerformerRow> sorted = new List<PerformerRow>();
            for (PerformerRow row : rowsByPod.get(pod).values()) {
                row.attainmentPct = row.goal == 0 ? 0
                    : ((row.nbCount + row.expCount) / row.goal) * 100;
                sorted.add(row);
            }
            sorted.sort(new PerformerComparator());
            if (sorted.size() > n) {
                List<PerformerRow> trimmed = new List<PerformerRow>();
                for (Integer i = 0; i < n; i++) trimmed.add(sorted[i]);
                sorted = trimmed;
            }
            pp.rows = sorted;
            result.add(pp);
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

    @AuraEnabled(cacheable=true)
    public static List<HeatmapRow> getConversionHeatmap() {
        Set<Id> aes = getAeUserIds();
        List<HeatmapRow> result = new List<HeatmapRow>();
        if (aes.isEmpty()) return result;

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, OwnerId, Owner.Name, Owner.Manager.Name
            FROM Opportunity
            WHERE OwnerId IN :aes
              AND Type IN (:NB_TYPE, :EXP_TYPE)
              AND Booked_By_Role__c LIKE 'AE%'
        ]);
        if (opps.isEmpty()) return result;

        Map<Id, Set<String>> stagesByOpp = getStagesByOpp(opps.keySet());

        // Group max-rank-reached per owner.
        Map<Id, List<Integer>> ranksByOwner = new Map<Id, List<Integer>>();
        Map<Id, Opportunity> sampleByOwner = new Map<Id, Opportunity>();
        for (Opportunity o : opps.values()) {
            Set<String> stages = stagesByOpp.get(o.Id);
            if (stages == null || stages.isEmpty()) continue;
            Integer maxRank = 0;
            for (String s : stages) {
                Integer r = STAGE_RANK.get(s);
                if (r != null && r > maxRank) maxRank = r;
            }
            if (maxRank == 0) continue;
            if (!ranksByOwner.containsKey(o.OwnerId)) {
                ranksByOwner.put(o.OwnerId, new List<Integer>());
                sampleByOwner.put(o.OwnerId, o);
            }
            ranksByOwner.get(o.OwnerId).add(maxRank);
        }

        for (Id ownerId : ranksByOwner.keySet()) {
            Opportunity sample = sampleByOwner.get(ownerId);
            HeatmapRow row = new HeatmapRow();
            row.ownerId = ownerId;
            row.ownerName = sample.Owner != null ? sample.Owner.Name : null;
            row.managerName = (sample.Owner != null && sample.Owner.Manager != null)
                ? sample.Owner.Manager.Name : null;

            Integer atOrAbove1 = 0, atOrAbove2 = 0, atOrAbove3 = 0,
                    atOrAbove4 = 0, atOrAbove5 = 0, atOrAbove6 = 0;
            for (Integer r : ranksByOwner.get(ownerId)) {
                if (r >= 1) atOrAbove1++;
                if (r >= 2) atOrAbove2++;
                if (r >= 3) atOrAbove3++;
                if (r >= 4) atOrAbove4++;
                if (r >= 5) atOrAbove5++;
                if (r >= 6) atOrAbove6++;
            }
            row.demoCount        = atOrAbove1;
            row.discoveryCount   = atOrAbove2;
            row.povCount         = atOrAbove3;
            row.proposalCount    = atOrAbove4;
            row.contractingCount = atOrAbove5;
            row.wonCount         = atOrAbove6;
            row.demoToDisco           = pct(atOrAbove2, atOrAbove1);
            row.discoToPov            = pct(atOrAbove3, atOrAbove2);
            row.povToProposal         = pct(atOrAbove4, atOrAbove3);
            row.proposalToContracting = pct(atOrAbove5, atOrAbove4);
            row.contractingToWon      = pct(atOrAbove6, atOrAbove5);
            result.add(row);
        }
        result.sort(new HeatmapComparator());
        return result;
    }

    // ---- Private helpers -------------------------------------------------------------

    private static Map<String, Set<Id>> getAeUserIdsByPod() {
        if (aeUserIdsByPodCache != null) return aeUserIdsByPodCache;
        Map<String, Set<Id>> out = new Map<String, Set<Id>>();
        for (User u : [
            SELECT Id, Title, Pod__c FROM User
            WHERE IsActive = TRUE AND Pod__c IN :AE_PODS
        ]) {
            if (u.Title != null && u.Title.containsIgnoreCase('BDR')) continue;
            if (!out.containsKey(u.Pod__c)) out.put(u.Pod__c, new Set<Id>());
            out.get(u.Pod__c).add(u.Id);
        }
        aeUserIdsByPodCache = out;
        return out;
    }

    private static Set<Id> getAeUserIds() {
        if (aeUserIdsCache != null) return aeUserIdsCache;
        Set<Id> ids = new Set<Id>();
        for (Set<Id> podIds : getAeUserIdsByPod().values()) {
            ids.addAll(podIds);
        }
        aeUserIdsCache = ids;
        return ids;
    }

    private static Map<Id, DateTime> getFirstStage2PlusByOpp() {
        if (mockFirstStage2PlusByOpp != null) return mockFirstStage2PlusByOpp;
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
              AND Booked_By_Role__c LIKE 'AE%'
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
                  AND NektarSender__c = 'Us'
                  AND ActivityDate = THIS_WEEK
                GROUP BY OwnerId, Owner.Name, TaskSubtype
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
            FROM Task
            WHERE OwnerId IN :aes
              AND Status = 'Completed'
              AND TaskSubtype IN ('Email', 'Call', 'LinkedIn')
              AND NektarSender__c = 'Us'
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name, TaskSubtype
        ];
    }

    private static List<AggregateResult> queryEventMeetings(Set<Id> aes, String windowLabel) {
        // Pipe-gen specific: only Discovery / First Meeting that actually
        // happened (NektarStatus = completed). Excludes internal calendar
        // items, deal-progression check-ins, and canceled/missed meetings.
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Event
                WHERE OwnerId IN :aes
                  AND NektarSender__c = 'Us'
                  AND NektarStatus__c = 'completed'
                  AND Meeting_Type__c IN ('Discovery', 'First Meeting')
                  AND ActivityDate = THIS_WEEK
                GROUP BY OwnerId, Owner.Name
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
            FROM Event
            WHERE OwnerId IN :aes
              AND NektarSender__c = 'Us'
              AND NektarStatus__c = 'completed'
              AND Meeting_Type__c IN ('Discovery', 'First Meeting')
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
        ];
    }

    private static Map<Id, Decimal[]> getQuotasForCurrentQuarter() {
        Set<Id> aes = getAeUserIds();
        Map<Id, Decimal[]> out = new Map<Id, Decimal[]>();
        if (aes.isEmpty()) return out;
        Map<String, Integer> fyfq = fiscalYearAndQuarter(Date.today());
        Integer fy = fyfq.get('fy');
        Integer fq = fyfq.get('fq');
        for (PG_Quota__c q : [
            SELECT User__c, NB_Goal__c, Exp_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :aes
              AND Fiscal_Year__c = :fy
              AND Fiscal_Quarter__c = :fq
        ]) {
            out.put(q.User__c, new Decimal[]{
                q.NB_Goal__c == null ? 0 : q.NB_Goal__c,
                q.Exp_Goal__c == null ? 0 : q.Exp_Goal__c
            });
        }
        return out;
    }

    private static Map<Integer, Decimal> getQuarterGoals() {
        Set<Id> aes = getAeUserIds();
        Map<Integer, Decimal> out = new Map<Integer, Decimal>();
        if (aes.isEmpty()) return out;
        for (PG_Quota__c q : [
            SELECT Fiscal_Year__c, Fiscal_Quarter__c, NB_Goal__c, Exp_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :aes
        ]) {
            if (q.Fiscal_Year__c == null || q.Fiscal_Quarter__c == null) continue;
            Integer key = q.Fiscal_Year__c.intValue() * 10 + q.Fiscal_Quarter__c.intValue();
            Decimal total = (q.NB_Goal__c == null ? 0 : q.NB_Goal__c)
                          + (q.Exp_Goal__c == null ? 0 : q.Exp_Goal__c);
            Decimal existing = out.get(key);
            out.put(key, (existing == null ? 0 : existing) + total);
        }
        return out;
    }

    private static Decimal mtdProration() {
        Date qStart = startOfCurrentFiscalQuarter();
        Date qEnd = qStart.addMonths(3).addDays(-1);
        Date today = Date.today();
        Integer daysElapsed = today.daysBetween(qStart) * -1 + 1;
        Integer totalDays = qEnd.daysBetween(qStart) * -1 + 1;
        if (totalDays <= 0) return 1;
        if (daysElapsed > totalDays) daysElapsed = totalDays;
        return Decimal.valueOf(daysElapsed) / Decimal.valueOf(totalDays);
    }

    private static Map<String, Integer> fiscalYearAndQuarter(Date d) {
        Integer startMonth = getFiscalStartMonth();
        Integer monthOffset = d.month() - startMonth;
        if (monthOffset < 0) monthOffset += 12;
        Integer fq = (monthOffset / 3) + 1;
        Integer fy;
        if (startMonth == 1) fy = d.year();
        else fy = (d.month() >= startMonth) ? d.year() + 1 : d.year();
        return new Map<String, Integer>{'fy' => fy, 'fq' => fq};
    }

    @TestVisible
    private static Map<Id, Set<String>> mockStagesByOpp;

    private static Map<Id, Set<String>> getStagesByOpp(Set<Id> oppIds) {
        if (mockStagesByOpp != null) return mockStagesByOpp;
        Map<Id, Set<String>> out = new Map<Id, Set<String>>();
        if (oppIds == null || oppIds.isEmpty()) return out;
        for (OpportunityHistory h : [
            SELECT OpportunityId, StageName
            FROM OpportunityHistory
            WHERE OpportunityId IN :oppIds
              AND StageName IN :STAGE_RANK.keySet()
        ]) {
            Set<String> s = out.get(h.OpportunityId);
            if (s == null) {
                s = new Set<String>();
                out.put(h.OpportunityId, s);
            }
            s.add(h.StageName);
        }
        return out;
    }

    private static Decimal pct(Integer numerator, Integer denominator) {
        if (denominator == null || denominator == 0) return 0;
        return (Decimal.valueOf(numerator) / Decimal.valueOf(denominator)) * 100;
    }

    private class HeatmapComparator implements Comparator<HeatmapRow> {
        public Integer compare(HeatmapRow a, HeatmapRow b) {
            String aMgr = a.managerName == null ? '' : a.managerName;
            String bMgr = b.managerName == null ? '' : b.managerName;
            Integer cmp = aMgr.compareTo(bMgr);
            if (cmp != 0) return cmp;
            String aName = a.ownerName == null ? '' : a.ownerName;
            String bName = b.ownerName == null ? '' : b.ownerName;
            return aName.compareTo(bName);
        }
    }

    private class PerformerComparator implements Comparator<PerformerRow> {
        public Integer compare(PerformerRow a, PerformerRow b) {
            // Primary: total Stage 2+ count desc; tiebreak by attainment desc
            // (mixing pct and count in one score gives nonsensical orderings
            // when some reps have a goal set and others don't).
            Integer aTotal = a.nbCount + a.expCount;
            Integer bTotal = b.nbCount + b.expCount;
            if (bTotal != aTotal) return bTotal > aTotal ? 1 : -1;
            if (b.attainmentPct > a.attainmentPct) return 1;
            if (b.attainmentPct < a.attainmentPct) return -1;
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
