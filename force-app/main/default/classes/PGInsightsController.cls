/**
 * PGInsightsController
 *
 * Backs the pgInsightsApp LWC with aggregated Pipeline Generation metrics:
 * WoW/MoM creation pacing, S1 progress by quarter, top SQO performers, and
 * per-rep outbound activity (calls, emails, LinkedIn, meetings).
 *
 * Org-specific mapping (edit the constants block below if these change):
 *   - AEs are identified by User.Pod__c and IsActive (BDR title excluded).
 *   - "New Business" = Opportunity.Type 'New Business'.
 *   - "Expansion"    = Opportunity.Type 'Upsell'.
 *   - S1 reached     = Opportunity.Stage_1__c = TRUE; date via Stage_1_Start_Date__c.
 *   - Outbound Email/Call/LinkedIn = Task.TaskSubtype with Status='Completed'.
 *   - Meetings       = Task.TaskSubtype 'Task' AND Meeting_Type__c in MEETING_TYPES.
 */
public with sharing class PGInsightsController {

    // ---- Org-specific configuration --------------------------------------------------

    private static final Set<String> AE_PODS = new Set<String>{
        'ENT 1', 'ENT 2', 'MM/HV', 'NV'
    };

    private static final String NB_TYPE  = 'New Business';
    private static final String EXP_TYPE = 'Upsell';

    private static final Set<String> MEETING_TYPES = new Set<String>{
        'First Meeting',
        'Prospect Meeting',
        'Discovery',
        'Deal Progression',
        'POV Validation & Alignment',
        'POV Readout'
    };

    // Default goals (S1 SQOs per quarter) when no Custom Metadata is configured.
    // Replace with PG_Insights_Setting__mdt later if the org adds it.
    private static final Decimal DEFAULT_NB_S1_GOAL_QTD  = 0;
    private static final Decimal DEFAULT_EXP_S1_GOAL_QTD = 0;

    // ---- Internal cache --------------------------------------------------------------

    private static Set<Id> aeUserIdsCache;

    private static Set<Id> getAeUserIds() {
        if (aeUserIdsCache != null) {
            return aeUserIdsCache;
        }
        Set<Id> ids = new Set<Id>();
        for (User u : [
            SELECT Id, Title, Pod__c
            FROM User
            WHERE IsActive = TRUE
              AND Pod__c IN :AE_PODS
        ]) {
            if (u.Title == null || !u.Title.containsIgnoreCase('BDR')) {
                ids.add(u.Id);
            }
        }
        aeUserIdsCache = ids;
        return ids;
    }

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
        Set<Id> aes = getAeUserIds();
        if (aes.isEmpty()) {
            return emptyPacing(windowLabel);
        }

        Map<String, Integer> current = countOppsCreatedByType(aes, windowLabel, false);
        Map<String, Integer> prior   = countOppsCreatedByType(aes, windowLabel, true);

        PacingKpis kpis = new PacingKpis();
        kpis.windowLabel  = windowLabel;
        kpis.newBusiness  = current.get(NB_TYPE);
        kpis.expansion    = current.get(EXP_TYPE);
        Integer total     = kpis.newBusiness + kpis.expansion;
        kpis.nbPctOfTotal = total == 0 ? 0 : (Decimal.valueOf(kpis.newBusiness) / total) * 100;
        kpis.deltaNB      = kpis.newBusiness - prior.get(NB_TYPE);
        kpis.deltaExp     = kpis.expansion   - prior.get(EXP_TYPE);

        Integer priorTotal = prior.get(NB_TYPE) + prior.get(EXP_TYPE);
        Decimal priorPct   = priorTotal == 0 ? 0 : (Decimal.valueOf(prior.get(NB_TYPE)) / priorTotal) * 100;
        kpis.deltaPct      = kpis.nbPctOfTotal - priorPct;
        return kpis;
    }

    @AuraEnabled(cacheable=true)
    public static List<QuarterRow> getStageProgressByQuarter(Integer numQuarters) {
        Set<Id> aes = getAeUserIds();
        Integer n = (numQuarters == null || numQuarters <= 0) ? 8 : numQuarters;
        List<QuarterRow> rows = new List<QuarterRow>();
        if (aes.isEmpty()) {
            return rows;
        }

        // Group by fiscal year/quarter using the stage 1 entry date.
        // LAST_N_FISCAL_QUARTERS:n covers prior quarters only — explicitly OR
        // in THIS_FISCAL_QUARTER to include current-quarter data.
        AggregateResult[] aggs = [
            SELECT FISCAL_YEAR(Stage_1_Start_Date__c) fy,
                   FISCAL_QUARTER(Stage_1_Start_Date__c) fq,
                   Type t,
                   COUNT(Id) cnt
            FROM Opportunity
            WHERE Stage_1__c = TRUE
              AND Stage_1_Start_Date__c != NULL
              AND OwnerId IN :aes
              AND Type IN (:NB_TYPE, :EXP_TYPE)
              AND (Stage_1_Start_Date__c = LAST_N_FISCAL_QUARTERS:8
                   OR Stage_1_Start_Date__c = THIS_FISCAL_QUARTER)
            GROUP BY FISCAL_YEAR(Stage_1_Start_Date__c),
                     FISCAL_QUARTER(Stage_1_Start_Date__c),
                     Type
            ORDER BY FISCAL_YEAR(Stage_1_Start_Date__c),
                     FISCAL_QUARTER(Stage_1_Start_Date__c)
        ];

        Map<String, QuarterRow> byKey = new Map<String, QuarterRow>();
        for (AggregateResult ar : aggs) {
            Integer fy = (Integer) ar.get('fy');
            Integer fq = (Integer) ar.get('fq');
            String type = (String) ar.get('t');
            Integer cnt = (Integer) ar.get('cnt');
            String key = 'FY' + fy + '-Q' + fq;
            QuarterRow row = byKey.get(key);
            if (row == null) {
                row = new QuarterRow();
                row.fiscalLabel = key;
                row.nbCount = 0;
                row.expCount = 0;
                row.goal = DEFAULT_NB_S1_GOAL_QTD + DEFAULT_EXP_S1_GOAL_QTD;
                byKey.put(key, row);
            }
            if (type == NB_TYPE) {
                row.nbCount = cnt;
            } else if (type == EXP_TYPE) {
                row.expCount = cnt;
            }
        }
        rows.addAll(byKey.values());
        // Trim to requested window (most recent N).
        if (rows.size() > n) {
            List<QuarterRow> trimmed = new List<QuarterRow>();
            for (Integer i = rows.size() - n; i < rows.size(); i++) {
                trimmed.add(rows[i]);
            }
            rows = trimmed;
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static S1Status getS1StatusQTD() {
        S1Status s = new S1Status();
        s.nbCount = 0;
        s.expCount = 0;
        s.goalMTD = DEFAULT_NB_S1_GOAL_QTD + DEFAULT_EXP_S1_GOAL_QTD;
        s.attainmentPct = 0;

        Set<Id> aes = getAeUserIds();
        if (aes.isEmpty()) {
            return s;
        }

        for (AggregateResult ar : [
            SELECT Type t, COUNT(Id) cnt
            FROM Opportunity
            WHERE Stage_1__c = TRUE
              AND Stage_1_Start_Date__c = THIS_FISCAL_QUARTER
              AND OwnerId IN :aes
              AND Type IN (:NB_TYPE, :EXP_TYPE)
            GROUP BY Type
        ]) {
            String type = (String) ar.get('t');
            Integer cnt = (Integer) ar.get('cnt');
            if (type == NB_TYPE) s.nbCount = cnt;
            else if (type == EXP_TYPE) s.expCount = cnt;
        }
        s.attainmentPct = s.goalMTD == 0 ? 0 : ((s.nbCount + s.expCount) / s.goalMTD) * 100;
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static List<PerformerRow> getTopPerformers(Integer topN) {
        Integer n = (topN == null || topN <= 0) ? 5 : topN;
        Set<Id> aes = getAeUserIds();
        List<PerformerRow> result = new List<PerformerRow>();
        if (aes.isEmpty()) {
            return result;
        }

        Map<Id, PerformerRow> byOwner = new Map<Id, PerformerRow>();
        for (AggregateResult ar : [
            SELECT OwnerId oid, Owner.Name oname, Type t, COUNT(Id) cnt
            FROM Opportunity
            WHERE Stage_1__c = TRUE
              AND Stage_1_Start_Date__c = THIS_FISCAL_QUARTER
              AND OwnerId IN :aes
              AND Type IN (:NB_TYPE, :EXP_TYPE)
            GROUP BY OwnerId, Owner.Name, Type
        ]) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            String type = (String) ar.get('t');
            Integer cnt = (Integer) ar.get('cnt');

            PerformerRow row = byOwner.get(oid);
            if (row == null) {
                row = new PerformerRow();
                row.ownerId = oid;
                row.ownerName = oname;
                row.nbCount = 0;
                row.expCount = 0;
                row.goal = DEFAULT_NB_S1_GOAL_QTD + DEFAULT_EXP_S1_GOAL_QTD;
                byOwner.put(oid, row);
            }
            if (type == NB_TYPE) row.nbCount = cnt;
            else if (type == EXP_TYPE) row.expCount = cnt;
        }

        for (PerformerRow row : byOwner.values()) {
            row.attainmentPct = row.goal == 0 ? 0
                : ((row.nbCount + row.expCount) / row.goal) * 100;
            result.add(row);
        }
        // Sort desc by attainment, fall back to total count when goals are unset.
        result.sort(new PerformerComparator());
        if (result.size() > n) {
            List<PerformerRow> trimmed = new List<PerformerRow>();
            for (Integer i = 0; i < n; i++) {
                trimmed.add(result[i]);
            }
            result = trimmed;
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<OutreachRow> getIndividualOutreach(String windowLabel) {
        Set<Id> aes = getAeUserIds();
        List<OutreachRow> result = new List<OutreachRow>();
        if (aes.isEmpty()) {
            return result;
        }

        Map<Id, OutreachRow> byOwner = new Map<Id, OutreachRow>();
        for (Id oid : aes) {
            OutreachRow row = new OutreachRow();
            row.ownerId = oid;
            row.emails = 0;
            row.calls = 0;
            row.linkedin = 0;
            row.meetings = 0;
            row.total = 0;
            byOwner.put(oid, row);
        }

        // Outbound Email / Call / LinkedIn
        for (AggregateResult ar : queryOutreachAggregates(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            String subtype = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = byOwner.get(oid);
            if (row == null) continue;
            row.ownerName = oname;
            if (subtype == 'Email') row.emails = cnt;
            else if (subtype == 'Call') row.calls = cnt;
            else if (subtype == 'LinkedIn') row.linkedin = cnt;
        }

        // Meetings (Task with Meeting_Type__c populated)
        for (AggregateResult ar : queryMeetingAggregates(aes, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = byOwner.get(oid);
            if (row == null) continue;
            if (row.ownerName == null) row.ownerName = oname;
            row.meetings = cnt;
        }

        for (OutreachRow row : byOwner.values()) {
            row.total = row.emails + row.calls + row.linkedin + row.meetings;
            if (row.ownerName != null) {
                result.add(row);
            }
        }
        result.sort(new OutreachComparator());
        return result;
    }

    // ---- Private helpers -------------------------------------------------------------

    private static Map<String, Integer> countOppsCreatedByType(
        Set<Id> aes, String windowLabel, Boolean priorPeriod
    ) {
        Map<String, Integer> out = new Map<String, Integer>{
            NB_TYPE => 0,
            EXP_TYPE => 0
        };

        // Use Stage_1_Start_Date__c as the "creation of pipeline" trigger.
        // Switch to CreatedDate if the team prefers raw opportunity creation.
        List<AggregateResult> aggs;
        if (windowLabel == 'WoW' && !priorPeriod) {
            aggs = [
                SELECT Type t, COUNT(Id) cnt FROM Opportunity
                WHERE Stage_1_Start_Date__c = THIS_WEEK
                  AND OwnerId IN :aes
                  AND Type IN (:NB_TYPE, :EXP_TYPE)
                GROUP BY Type
            ];
        } else if (windowLabel == 'WoW' && priorPeriod) {
            aggs = [
                SELECT Type t, COUNT(Id) cnt FROM Opportunity
                WHERE Stage_1_Start_Date__c = LAST_WEEK
                  AND OwnerId IN :aes
                  AND Type IN (:NB_TYPE, :EXP_TYPE)
                GROUP BY Type
            ];
        } else if (windowLabel == 'MoM' && !priorPeriod) {
            aggs = [
                SELECT Type t, COUNT(Id) cnt FROM Opportunity
                WHERE Stage_1_Start_Date__c = THIS_MONTH
                  AND OwnerId IN :aes
                  AND Type IN (:NB_TYPE, :EXP_TYPE)
                GROUP BY Type
            ];
        } else {
            aggs = [
                SELECT Type t, COUNT(Id) cnt FROM Opportunity
                WHERE Stage_1_Start_Date__c = LAST_MONTH
                  AND OwnerId IN :aes
                  AND Type IN (:NB_TYPE, :EXP_TYPE)
                GROUP BY Type
            ];
        }
        for (AggregateResult ar : aggs) {
            out.put((String) ar.get('t'), (Integer) ar.get('cnt'));
        }
        return out;
    }

    private static List<AggregateResult> queryOutreachAggregates(Set<Id> aes, String windowLabel) {
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

    private static List<AggregateResult> queryMeetingAggregates(Set<Id> aes, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :aes
                  AND Meeting_Type__c IN :MEETING_TYPES
                  AND CompletedDateTime = THIS_WEEK
                GROUP BY OwnerId, Owner.Name
            ];
        }
        return [
            SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
            FROM Task
            WHERE OwnerId IN :aes
              AND Meeting_Type__c IN :MEETING_TYPES
              AND CompletedDateTime = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
        ];
    }

    private static PacingKpis emptyPacing(String windowLabel) {
        PacingKpis k = new PacingKpis();
        k.windowLabel = windowLabel;
        k.newBusiness = 0;
        k.expansion = 0;
        k.nbPctOfTotal = 0;
        k.deltaNB = 0;
        k.deltaExp = 0;
        k.deltaPct = 0;
        return k;
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
