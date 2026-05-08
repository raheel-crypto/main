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

    // AEs are grouped by UserRole.Name CONTAINS one of these tokens
    // (case-insensitive). Order matters for derivePodFromRole — first match
    // wins, so put the more-specific tokens first if any overlap is possible.
    private static final List<String> POD_TOKENS = new List<String>{
        'BUYSIDE', 'IB1', 'IB2', 'MM'
    };

    // Display label per token. Keep keys aligned with POD_TOKENS.
    private static final Map<String, String> POD_LABEL_BY_TOKEN = new Map<String, String>{
        'BUYSIDE' => 'Buyside',
        'IB1' => 'IB1',
        'IB2' => 'IB2',
        'MM'  => 'MM'
    };

    private static final String NB_TYPE  = 'New Business';
    private static final String EXP_TYPE = 'Upsell';
    private static final String PILOT_TYPE = 'Pilot';

    // Pilots are pre-NB pipeline; rolled up with New Business in count/$
    // metrics (NB column on the dashboard includes them).
    private static final Set<String> NB_TYPES_FOR_BUCKETING = new Set<String>{
        NB_TYPE, PILOT_TYPE
    };

    private static final Set<String> ALL_DASHBOARD_TYPES = new Set<String>{
        NB_TYPE, PILOT_TYPE, EXP_TYPE
    };

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
        // Counts
        @AuraEnabled public Integer newBusiness;
        @AuraEnabled public Integer expansion;
        @AuraEnabled public Decimal nbPctOfTotal;
        @AuraEnabled public Integer deltaNB;
        @AuraEnabled public Integer deltaExp;
        @AuraEnabled public Decimal deltaPct;
        // Amounts ($)
        @AuraEnabled public Decimal newBusinessAmount;
        @AuraEnabled public Decimal expansionAmount;
        @AuraEnabled public Decimal nbAmtPctOfTotal;
        @AuraEnabled public Decimal deltaNBAmount;
        @AuraEnabled public Decimal deltaExpAmount;
        @AuraEnabled public Decimal deltaAmtPct;
    }

    public class QuarterRow {
        @AuraEnabled public String fiscalLabel;
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goal;
        @AuraEnabled public Decimal nbAmount;
        @AuraEnabled public Decimal expAmount;
        @AuraEnabled public Decimal amountGoal;
    }

    public class S1Status {
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goalMTD;
        @AuraEnabled public Decimal attainmentPct;
        @AuraEnabled public Decimal nbAmount;
        @AuraEnabled public Decimal expAmount;
        @AuraEnabled public Decimal amountGoalMTD;
        @AuraEnabled public Decimal amountAttainmentPct;
    }

    public class PerformerRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Integer nbCount;
        @AuraEnabled public Integer expCount;
        @AuraEnabled public Decimal goal;
        @AuraEnabled public Decimal attainmentPct;
        @AuraEnabled public Decimal nbAmount;
        @AuraEnabled public Decimal expAmount;
        @AuraEnabled public Decimal amountGoal;
        @AuraEnabled public Decimal amountAttainmentPct;
    }

    public class PodPerformers {
        @AuraEnabled public String pod;
        @AuraEnabled public List<PerformerRow> rows;
        @AuraEnabled public Integer totalNb;
        @AuraEnabled public Integer totalExp;
        @AuraEnabled public Decimal totalGoalMTD;
        @AuraEnabled public Decimal attainmentPct;
        @AuraEnabled public Decimal totalNbAmount;
        @AuraEnabled public Decimal totalExpAmount;
        @AuraEnabled public Decimal totalAmountGoalMTD;
        @AuraEnabled public Decimal amountAttainmentPct;
    }

    public class OutreachRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Id managerId;
        @AuraEnabled public String managerName;
        @AuraEnabled public Integer emails;
        @AuraEnabled public Integer calls;
        @AuraEnabled public Integer linkedin;
        @AuraEnabled public Integer meetings;
        @AuraEnabled public Integer total;
    }

    public class HeatmapCellOpp {
        @AuraEnabled public Id oppId;
        @AuraEnabled public String name;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public Boolean isClosed;
        @AuraEnabled public Boolean reachedTarget;
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
        Map<String, Integer> curr      = countByType(currIds,  opps);
        Map<String, Integer> prior     = countByType(priorIds, opps);
        Map<String, Decimal> currAmt   = amountByType(currIds,  opps);
        Map<String, Decimal> priorAmt  = amountByType(priorIds, opps);

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

        k.newBusinessAmount = currAmt.get(NB_TYPE);
        k.expansionAmount   = currAmt.get(EXP_TYPE);
        Decimal totalAmt    = k.newBusinessAmount + k.expansionAmount;
        k.nbAmtPctOfTotal   = totalAmt == 0 ? 0 : (k.newBusinessAmount / totalAmt) * 100;
        k.deltaNBAmount     = k.newBusinessAmount - priorAmt.get(NB_TYPE);
        k.deltaExpAmount    = k.expansionAmount   - priorAmt.get(EXP_TYPE);
        Decimal priorAmtTotal = priorAmt.get(NB_TYPE) + priorAmt.get(EXP_TYPE);
        Decimal priorAmtPct   = priorAmtTotal == 0 ? 0 : (priorAmt.get(NB_TYPE) / priorAmtTotal) * 100;
        k.deltaAmtPct = k.nbAmtPctOfTotal - priorAmtPct;
        return k;
    }

    @AuraEnabled(cacheable=true)
    public static List<QuarterRow> getStageProgressByWeek() {
        // Weekly buckets for the current fiscal quarter only. Used by the
        // chart's "Per Week (this Q)" view. Goals aren't applied per week —
        // the chart skips the goal line in this view.
        Date qStart = startOfCurrentFiscalQuarter();
        Date today = Date.today();

        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Map<Id, Opportunity> opps = getOppDetails(firstDates.keySet());

        // Build week buckets up to today, aligned to qStart.
        Map<Integer, QuarterRow> byKey = new Map<Integer, QuarterRow>();
        Integer currentWeekIndex = today.daysBetween(qStart) * -1 / 7;
        for (Integer i = 0; i <= currentWeekIndex; i++) {
            Date wkStart = qStart.addDays(i * 7);
            Date wkEnd   = wkStart.addDays(6);
            QuarterRow r = new QuarterRow();
            r.fiscalLabel = formatWeekLabel(wkStart);
            r.nbCount    = 0;
            r.expCount   = 0;
            r.goal       = 0;
            r.nbAmount   = 0;
            r.expAmount  = 0;
            r.amountGoal = 0;
            byKey.put(i, r);
        }

        for (Id oid : firstDates.keySet()) {
            Opportunity o = opps.get(oid);
            if (o == null) continue;
            String bucket = bucketForType(o.Type);
            if (bucket == null) continue;
            Date d = firstDates.get(oid).date();
            if (d < qStart || d > today) continue;
            Integer wkIdx = d.daysBetween(qStart) * -1 / 7;
            QuarterRow row = byKey.get(wkIdx);
            if (row == null) continue;
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            if (bucket == NB_TYPE) {
                row.nbCount  += 1;
                row.nbAmount += amt;
            } else {
                row.expCount  += 1;
                row.expAmount += amt;
            }
        }

        List<Integer> sortedKeys = new List<Integer>(byKey.keySet());
        sortedKeys.sort();
        List<QuarterRow> rows = new List<QuarterRow>();
        for (Integer k : sortedKeys) rows.add(byKey.get(k));
        return rows;
    }

    private static String formatWeekLabel(Date wkStart) {
        // Compact "M/d" label, e.g. "5/4".
        return wkStart.month() + '/' + wkStart.day();
    }

    @AuraEnabled(cacheable=true)
    public static List<QuarterRow> getStageProgressByQuarter(Integer numQuarters) {
        Integer n = (numQuarters == null || numQuarters <= 0) ? 8 : numQuarters;
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Map<Id, Opportunity> opps = getOppDetails(firstDates.keySet());

        Map<Integer, QuarterRow> byKey = new Map<Integer, QuarterRow>();
        for (Id oid : firstDates.keySet()) {
            Opportunity o = opps.get(oid);
            if (o == null) continue;
            String bucket = bucketForType(o.Type);
            if (bucket == null) continue;
            Date d = firstDates.get(oid).date();
            Integer sortKey = fiscalSortKey(d);
            QuarterRow row = byKey.get(sortKey);
            if (row == null) {
                row = new QuarterRow();
                row.fiscalLabel = fiscalLabelFor(d);
                row.nbCount    = 0;
                row.expCount   = 0;
                row.goal       = DEFAULT_QUARTERLY_GOAL;
                row.nbAmount   = 0;
                row.expAmount  = 0;
                row.amountGoal = 0;
                byKey.put(sortKey, row);
            }
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            if (bucket == NB_TYPE) {
                row.nbCount  += 1;
                row.nbAmount += amt;
            } else {
                row.expCount  += 1;
                row.expAmount += amt;
            }
        }

        // Overlay quarterly goals from PG_Quota__c (sum across AEs per quarter).
        Map<Integer, Decimal[]> quarterGoals = getQuarterGoals();
        for (Integer key : byKey.keySet()) {
            Decimal[] g = quarterGoals.get(key);
            if (g != null) {
                byKey.get(key).goal       = g[0];
                byKey.get(key).amountGoal = g[1];
            }
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
        s.nbAmount = 0;
        s.expAmount = 0;
        s.amountGoalMTD = 0;
        s.amountAttainmentPct = 0;

        Date qStart = startOfCurrentFiscalQuarter();
        Map<Id, DateTime> firstDates = getFirstStage2PlusByOpp();
        Set<Id> qIds = new Set<Id>();
        for (Id oid : firstDates.keySet()) {
            if (firstDates.get(oid).date() >= qStart) qIds.add(oid);
        }
        Map<Id, Opportunity> opps = getOppDetails(qIds);
        Map<String, Integer> counts = countByType(qIds, opps);
        Map<String, Decimal> amounts = amountByType(qIds, opps);
        s.nbCount   = counts.get(NB_TYPE);
        s.expCount  = counts.get(EXP_TYPE);
        s.nbAmount  = amounts.get(NB_TYPE);
        s.expAmount = amounts.get(EXP_TYPE);

        // Sum current-quarter quotas across all AEs and prorate by days into quarter.
        Map<Id, Decimal[]> quotas = getQuotasForCurrentQuarter();
        Decimal totalCountGoal = 0, totalAmtGoal = 0;
        for (Decimal[] g : quotas.values()) {
            totalCountGoal += g[0] + g[1];
            totalAmtGoal   += g[2] + g[3];
        }
        Decimal proration = mtdProration();
        s.goalMTD             = totalCountGoal * proration;
        s.amountGoalMTD       = totalAmtGoal   * proration;
        s.attainmentPct       = s.goalMTD       == 0 ? 0 : ((s.nbCount  + s.expCount)  / s.goalMTD)       * 100;
        s.amountAttainmentPct = s.amountGoalMTD == 0 ? 0 : ((s.nbAmount + s.expAmount) / s.amountGoalMTD) * 100;
        return s;
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
            if (o == null) continue;
            String typeBucket = bucketForType(o.Type);
            if (typeBucket == null) continue;
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
                row.nbAmount = 0;
                row.expAmount = 0;
                Decimal[] g = quotas.get(o.OwnerId);
                Decimal countQuarterly = g == null ? 0 : g[0] + g[1];
                Decimal amtQuarterly   = g == null ? 0 : g[2] + g[3];
                row.goal       = countQuarterly * proration;
                row.amountGoal = amtQuarterly   * proration;
                bucket.put(o.OwnerId, row);
            }
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            if (typeBucket == NB_TYPE) {
                row.nbCount  += 1;
                row.nbAmount += amt;
            } else {
                row.expCount  += 1;
                row.expAmount += amt;
            }
        }

        List<PodPerformers> result = new List<PodPerformers>();
        List<String> sortedPods = new List<String>(aesByPod.keySet());
        sortedPods.sort();
        for (String pod : sortedPods) {
            PodPerformers pp = new PodPerformers();
            pp.pod = pod;

            Integer totalNb = 0, totalExp = 0;
            Decimal totalNbAmt = 0, totalExpAmt = 0;
            for (PerformerRow row : rowsByPod.get(pod).values()) {
                totalNb     += row.nbCount;
                totalExp    += row.expCount;
                totalNbAmt  += row.nbAmount;
                totalExpAmt += row.expAmount;
            }
            Decimal totalCountGoal = 0, totalAmtGoal = 0;
            for (Id aeId : aesByPod.get(pod)) {
                Decimal[] g = quotas.get(aeId);
                if (g != null) {
                    totalCountGoal += (g[0] + g[1]) * proration;
                    totalAmtGoal   += (g[2] + g[3]) * proration;
                }
            }
            pp.totalNb              = totalNb;
            pp.totalExp             = totalExp;
            pp.totalNbAmount        = totalNbAmt;
            pp.totalExpAmount       = totalExpAmt;
            pp.totalGoalMTD         = totalCountGoal;
            pp.totalAmountGoalMTD   = totalAmtGoal;
            pp.attainmentPct        = totalCountGoal == 0 ? 0
                : ((totalNb + totalExp) / totalCountGoal) * 100;
            pp.amountAttainmentPct  = totalAmtGoal == 0 ? 0
                : ((totalNbAmt + totalExpAmt) / totalAmtGoal) * 100;

            // Per-rep attainment + sort + trim to top N.
            List<PerformerRow> sorted = new List<PerformerRow>();
            for (PerformerRow row : rowsByPod.get(pod).values()) {
                row.attainmentPct = row.goal == 0 ? 0
                    : ((row.nbCount + row.expCount) / row.goal) * 100;
                row.amountAttainmentPct = row.amountGoal == 0 ? 0
                    : ((row.nbAmount + row.expAmount) / row.amountGoal) * 100;
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

        // Emails + Calls (Nektar-tagged outbound)
        for (AggregateResult ar : queryEmailCallAggregates(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            String subtype = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            if (subtype == 'Email')         row.emails   = cnt;
            else if (subtype == 'Call')     row.calls    = cnt;
        }

        // LinkedIn — Sales Navigator integration writes Tasks differently
        // (TaskSubtype = 'Task', Subject contains 'Sales Navigator' and 'Sent'
        // for outbound). No Nektar tagging on these.
        for (AggregateResult ar : queryLinkedInAggregates(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            row.linkedin = cnt;
        }

        // Meetings live on the standard Event object.
        for (AggregateResult ar : queryEventMeetings(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            row.meetings = cnt;
        }

        // Enrich rows with manager info so the LWC can group by manager.
        if (!byOwner.isEmpty()) {
            for (User u : [
                SELECT Id, ManagerId, Manager.Name FROM User WHERE Id IN :byOwner.keySet()
            ]) {
                OutreachRow row = byOwner.get(u.Id);
                if (row == null) continue;
                row.managerId = u.ManagerId;
                row.managerName = u.Manager != null ? u.Manager.Name : null;
            }
        }

        for (OutreachRow row : byOwner.values()) {
            row.total = row.emails + row.calls + row.linkedin + row.meetings;
            if (row.ownerName != null) result.add(row);
        }
        result.sort(new OutreachComparator());
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<HeatmapCellOpp> getHeatmapCellOpps(String groupKey, Integer fromRank, String groupBy, Boolean combineIB) {
        // Returns the underlying opps that contributed to the denominator of
        // a conversion cell (fromRank -> fromRank+1) for the given group.
        // groupBy mirrors getConversionHeatmap; groupKey is either an AE
        // OwnerId (in AE mode) or a pod label (in Pod mode).
        List<HeatmapCellOpp> out = new List<HeatmapCellOpp>();
        if (String.isBlank(groupKey) || fromRank == null || fromRank < 1) return out;
        String mode = String.isBlank(groupBy) ? 'AE' : groupBy;
        Boolean ibCombined = combineIB == true;

        Set<Id> aes = getAeUserIds();
        if (aes.isEmpty()) return out;

        // Resolve which AE owner ids belong to the requested group.
        Set<Id> ownerScope = new Set<Id>();
        if (mode == 'Pod') {
            Map<String, Set<Id>> aesByPod = getAeUserIdsByPod();
            for (String pod : aesByPod.keySet()) {
                String displayPod = (ibCombined && (pod == 'IB1' || pod == 'IB2'))
                    ? 'IB' : pod;
                if (displayPod == groupKey) ownerScope.addAll(aesByPod.get(pod));
            }
        } else {
            ownerScope.add((Id) groupKey);
        }
        if (ownerScope.isEmpty()) return out;

        List<Opportunity> opps = [
            SELECT Id, Name, OwnerId, Type, StageName, Amount, CloseDate, IsClosed
            FROM Opportunity
            WHERE OwnerId IN :ownerScope
              AND Type IN :ALL_DASHBOARD_TYPES
        ];
        if (opps.isEmpty()) return out;

        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : opps) oppIds.add(o.Id);
        Map<Id, Set<String>> stagesByOpp = getStagesByOpp(oppIds);

        for (Opportunity o : opps) {
            Set<String> stages = stagesByOpp.get(o.Id);
            Integer maxRank = 0;
            if (stages != null) {
                for (String s : stages) {
                    Integer r = STAGE_RANK.get(s);
                    if (r != null && r > maxRank) maxRank = r;
                }
            }
            if (maxRank == 0) continue;

            // Eligible for fromRank denominator?
            Boolean eligible = (maxRank > fromRank) || (maxRank == fromRank && o.IsClosed);
            if (!eligible) continue;

            HeatmapCellOpp row = new HeatmapCellOpp();
            row.oppId = o.Id;
            row.name = o.Name;
            row.stageName = o.StageName;
            row.amount = o.Amount;
            row.closeDate = o.CloseDate;
            row.isClosed = o.IsClosed;
            row.reachedTarget = (maxRank >= fromRank + 1);
            out.add(row);
        }

        // Sort: reached-target first (descending stage), then non-reached.
        out.sort(new HeatmapCellComparator());
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<HeatmapRow> getConversionHeatmap(String groupBy, Boolean combineIB) {
        // groupBy: 'AE' (default) returns one row per AE owner.
        //         'Pod' returns one row per pod, aggregating across all AEs
        //         in that pod. When combineIB is true, IB1 + IB2 collapse to
        //         a single 'IB' row.
        String mode = String.isBlank(groupBy) ? 'AE' : groupBy;
        Boolean ibCombined = combineIB == true;

        Set<Id> aes = getAeUserIds();
        List<HeatmapRow> result = new List<HeatmapRow>();
        if (aes.isEmpty()) return result;

        // Heatmap shows progression on every NB/Upsell opp the AE owns,
        // regardless of who originally booked it. Pipeline GENERATION metrics
        // elsewhere on the dashboard apply Booked_By_Role__c LIKE 'AE%' to
        // scope to AE-sourced deals — but conversion is about what the AE
        // does with the deals they're handed, so that filter is omitted here.
        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, OwnerId, Owner.Name, Owner.Manager.Name, IsClosed, StageName
            FROM Opportunity
            WHERE OwnerId IN :aes
              AND Type IN :ALL_DASHBOARD_TYPES
        ]);
        if (opps.isEmpty()) return result;

        Map<Id, Set<String>> stagesByOpp = getStagesByOpp(opps.keySet());

        // Group key per opp: AE mode uses OwnerId; Pod mode uses the pod
        // label (with IB1/IB2 optionally collapsed to 'IB').
        Map<Id, String> podByAe = new Map<Id, String>();
        if (mode == 'Pod') {
            Map<String, Set<Id>> aesByPod = getAeUserIdsByPod();
            for (String pod : aesByPod.keySet()) {
                String displayPod = (ibCombined && (pod == 'IB1' || pod == 'IB2'))
                    ? 'IB' : pod;
                for (Id aeId : aesByPod.get(pod)) podByAe.put(aeId, displayPod);
            }
        }

        // Per-group: reached[N] / eligible[N] arrays indexed by stage rank.
        Map<String, Integer[]>      reachedByGroup  = new Map<String, Integer[]>();
        Map<String, Integer[]>      eligibleByGroup = new Map<String, Integer[]>();
        Map<String, Opportunity>    sampleByGroup   = new Map<String, Opportunity>();

        for (Opportunity o : opps.values()) {
            Set<String> stages = stagesByOpp.get(o.Id);
            Integer maxRank = 0;
            if (stages != null) {
                for (String s : stages) {
                    Integer r = STAGE_RANK.get(s);
                    if (r != null && r > maxRank) maxRank = r;
                }
            }
            if (maxRank == 0) continue;

            String groupKey;
            if (mode == 'Pod') {
                groupKey = podByAe.get(o.OwnerId);
                if (groupKey == null) continue;
            } else {
                groupKey = String.valueOf(o.OwnerId);
            }

            Integer[] reached  = reachedByGroup.get(groupKey);
            Integer[] eligible = eligibleByGroup.get(groupKey);
            if (reached == null) {
                reached  = new Integer[]{ 0, 0, 0, 0, 0, 0, 0 };
                eligible = new Integer[]{ 0, 0, 0, 0, 0, 0, 0 };
                reachedByGroup.put(groupKey, reached);
                eligibleByGroup.put(groupKey, eligible);
                sampleByGroup.put(groupKey, o);
            }
            for (Integer N = 1; N <= 6; N++) {
                if (maxRank >= N) reached[N]++;
                if (maxRank > N || (maxRank == N && o.IsClosed)) eligible[N]++;
            }
        }

        for (String groupKey : reachedByGroup.keySet()) {
            Integer[] reached  = reachedByGroup.get(groupKey);
            Integer[] eligible = eligibleByGroup.get(groupKey);
            Opportunity sample = sampleByGroup.get(groupKey);

            HeatmapRow row = new HeatmapRow();
            if (mode == 'Pod') {
                row.ownerId     = null;
                row.ownerName   = groupKey;          // pod label as the row name
                row.managerName = null;
            } else {
                row.ownerId     = sample.OwnerId;
                row.ownerName   = sample.Owner != null ? sample.Owner.Name : null;
                row.managerName = (sample.Owner != null && sample.Owner.Manager != null)
                    ? sample.Owner.Manager.Name : null;
            }

            row.demoCount        = reached[1];
            row.discoveryCount   = reached[2];
            row.povCount         = reached[3];
            row.proposalCount    = reached[4];
            row.contractingCount = reached[5];
            row.wonCount         = reached[6];
            row.demoToDisco           = pct(reached[2], eligible[1]);
            row.discoToPov            = pct(reached[3], eligible[2]);
            row.povToProposal         = pct(reached[4], eligible[3]);
            row.proposalToContracting = pct(reached[5], eligible[4]);
            row.contractingToWon      = pct(reached[6], eligible[5]);
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
            SELECT Id, Title, UserRole.Name FROM User
            WHERE IsActive = TRUE
              AND (UserRole.Name LIKE '%BUYSIDE%'
                   OR UserRole.Name LIKE '%IB1%'
                   OR UserRole.Name LIKE '%IB2%'
                   OR UserRole.Name LIKE '%MM%')
        ]) {
            if (u.Title != null && u.Title.containsIgnoreCase('BDR')) continue;
            String pod = derivePodFromRole(u.UserRole != null ? u.UserRole.Name : null);
            if (pod == null) continue;
            if (!out.containsKey(pod)) out.put(pod, new Set<Id>());
            out.get(pod).add(u.Id);
        }
        aeUserIdsByPodCache = out;
        return out;
    }

    private static String derivePodFromRole(String roleName) {
        if (String.isBlank(roleName)) return null;
        String upper = roleName.toUpperCase();
        for (String token : POD_TOKENS) {
            if (upper.contains(token)) return POD_LABEL_BY_TOKEN.get(token);
        }
        return null;
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
              AND Type IN :ALL_DASHBOARD_TYPES
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
            SELECT Id, Type, Amount, OwnerId, Owner.Name FROM Opportunity WHERE Id IN :ids
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
            String bucket = bucketForType(o.Type);
            if (bucket != null) out.put(bucket, out.get(bucket) + 1);
        }
        return out;
    }

    private static Map<String, Decimal> amountByType(Set<Id> oppIds, Map<Id, Opportunity> opps) {
        Map<String, Decimal> out = new Map<String, Decimal>{NB_TYPE => 0, EXP_TYPE => 0};
        for (Id oid : oppIds) {
            Opportunity o = opps.get(oid);
            if (o == null) continue;
            String bucket = bucketForType(o.Type);
            if (bucket == null) continue;
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            out.put(bucket, out.get(bucket) + amt);
        }
        return out;
    }

    // Pilot opps roll up under New Business for dashboard bucketing.
    private static String bucketForType(String oppType) {
        if (oppType == EXP_TYPE) return EXP_TYPE;
        if (NB_TYPES_FOR_BUCKETING.contains(oppType)) return NB_TYPE;
        return null;
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

    private static List<AggregateResult> queryEmailCallAggregates(Set<Id> aes, String windowLabel) {
        // Emails are Nektar-tagged ('NektarSender__c = Us' = outbound); Call
        // records in this org have all Nektar fields null, so calls are
        // identified by TaskSubtype alone.
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :aes
                  AND Status = 'Completed'
                  AND ActivityDate = THIS_WEEK
                  AND (
                      (TaskSubtype = 'Email' AND NektarSender__c = 'Us')
                      OR TaskSubtype = 'Call'
                  )
                GROUP BY OwnerId, Owner.Name, TaskSubtype
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
            FROM Task
            WHERE OwnerId IN :aes
              AND Status = 'Completed'
              AND ActivityDate = THIS_FISCAL_QUARTER
              AND (
                  (TaskSubtype = 'Email' AND NektarSender__c = 'Us')
                  OR TaskSubtype = 'Call'
              )
            GROUP BY OwnerId, Owner.Name, TaskSubtype
        ];
    }

    private static List<AggregateResult> queryLinkedInAggregates(Set<Id> aes, String windowLabel) {
        // LinkedIn touches via Sales Navigator integration: TaskSubtype is the
        // generic 'Task' (not 'LinkedIn'), Subject contains 'Sales Navigator'
        // and 'Sent' for outbound. Nektar does not tag these.
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :aes
                  AND TaskSubtype = 'Task'
                  AND Subject LIKE '%Sales Navigator%'
                  AND Subject LIKE '%Sent%'
                  AND ActivityDate = THIS_WEEK
                GROUP BY OwnerId, Owner.Name
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
            FROM Task
            WHERE OwnerId IN :aes
              AND TaskSubtype = 'Task'
              AND Subject LIKE '%Sales Navigator%'
              AND Subject LIKE '%Sent%'
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
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

    // Index 0 = NB count goal, 1 = Exp count goal, 2 = NB amount goal, 3 = Exp amount goal.
    private static Map<Id, Decimal[]> getQuotasForCurrentQuarter() {
        Set<Id> aes = getAeUserIds();
        Map<Id, Decimal[]> out = new Map<Id, Decimal[]>();
        if (aes.isEmpty()) return out;
        Map<String, Integer> fyfq = fiscalYearAndQuarter(Date.today());
        Integer fy = fyfq.get('fy');
        Integer fq = fyfq.get('fq');
        for (PG_Quota__c q : [
            SELECT User__c, NB_Goal__c, Exp_Goal__c, NB_Amount_Goal__c, Exp_Amount_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :aes
              AND Fiscal_Year__c = :fy
              AND Fiscal_Quarter__c = :fq
        ]) {
            out.put(q.User__c, new Decimal[]{
                q.NB_Goal__c          == null ? 0 : q.NB_Goal__c,
                q.Exp_Goal__c         == null ? 0 : q.Exp_Goal__c,
                q.NB_Amount_Goal__c   == null ? 0 : q.NB_Amount_Goal__c,
                q.Exp_Amount_Goal__c  == null ? 0 : q.Exp_Amount_Goal__c
            });
        }
        return out;
    }

    // Index 0 = total count goal, 1 = total amount goal.
    private static Map<Integer, Decimal[]> getQuarterGoals() {
        Set<Id> aes = getAeUserIds();
        Map<Integer, Decimal[]> out = new Map<Integer, Decimal[]>();
        if (aes.isEmpty()) return out;
        for (PG_Quota__c q : [
            SELECT Fiscal_Year__c, Fiscal_Quarter__c,
                   NB_Goal__c, Exp_Goal__c,
                   NB_Amount_Goal__c, Exp_Amount_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :aes
        ]) {
            if (q.Fiscal_Year__c == null || q.Fiscal_Quarter__c == null) continue;
            Integer key = q.Fiscal_Year__c.intValue() * 10 + q.Fiscal_Quarter__c.intValue();
            Decimal countTotal = (q.NB_Goal__c == null ? 0 : q.NB_Goal__c)
                               + (q.Exp_Goal__c == null ? 0 : q.Exp_Goal__c);
            Decimal amtTotal   = (q.NB_Amount_Goal__c == null ? 0 : q.NB_Amount_Goal__c)
                               + (q.Exp_Amount_Goal__c == null ? 0 : q.Exp_Amount_Goal__c);
            Decimal[] existing = out.get(key);
            if (existing == null) {
                out.put(key, new Decimal[]{ countTotal, amtTotal });
            } else {
                existing[0] += countTotal;
                existing[1] += amtTotal;
            }
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
        // Returns null when there's nothing eligible to convert — caller
        // shows "N/A". A literal 0% means "had a chance and didn't convert".
        if (denominator == null || denominator == 0) return null;
        return (Decimal.valueOf(numerator) / Decimal.valueOf(denominator)) * 100;
    }

    private class HeatmapCellComparator implements Comparator<HeatmapCellOpp> {
        public Integer compare(HeatmapCellOpp a, HeatmapCellOpp b) {
            // Reached-target first, then by stage descending, then by amount desc.
            if (a.reachedTarget != b.reachedTarget) return a.reachedTarget ? -1 : 1;
            String aStage = a.stageName == null ? '' : a.stageName;
            String bStage = b.stageName == null ? '' : b.stageName;
            Integer cmp = bStage.compareTo(aStage);
            if (cmp != 0) return cmp;
            Decimal aAmt = a.amount == null ? 0 : a.amount;
            Decimal bAmt = b.amount == null ? 0 : b.amount;
            if (bAmt > aAmt) return 1;
            if (bAmt < aAmt) return -1;
            return 0;
        }
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
