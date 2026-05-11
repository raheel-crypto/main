/**
 * PGGtmInsightsController
 *
 * Backs the pgGtmInsightsApp LWC with Pipeline Generation metrics for the
 * GTM Associate team. GTMs book opps but don't typically work them after
 * handoff, so the headline metric is "opps booked" with a secondary
 * "qualified" (Stage 2+) pass-through rate.
 *
 * Attribution is via Opportunity.Booked_By__c (lookup to User), not
 * OwnerId — the AE who eventually owns the deal is irrelevant to GTM
 * credit. Goals reuse PG_Quota__c.NB_Goal__c (count) and
 * NB_Amount_Goal__c ($) since GTMs don't separate NB vs Upsell.
 */
public with sharing class PGGtmInsightsController {

    // ---- Org-specific configuration ------------------------------------------------

    private static final String GTM_ROLE_NAME = 'GTM Associate';
    private static final String GTM_TITLE     = 'GTM Associate';

    private static final Set<String> ALL_DASHBOARD_TYPES = new Set<String>{
        'New Business', 'Upsell', 'Pilot'
    };

    private static final Set<String> STAGE_2_PLUS = new Set<String>{
        '2 - Discovery',
        '3 - POV',
        '4 - Proposal',
        '5 - Contracting',
        'Closed Won'
    };

    // ---- Per-transaction caches ----------------------------------------------------

    private static Set<Id> gtmUserIdsCache;
    private static Integer fiscalStartMonthCache;

    // Test seam — mirrors the AE controller pattern. OpportunityHistory does
    // not auto-create rows in this org's test context, so the qualified-
    // detection query is replaced with a hand-crafted map in tests.
    @TestVisible
    private static Map<Id, DateTime> mockFirstStage2PlusByOpp;

    // ---- Result wrappers -----------------------------------------------------------

    public class GtmStatus {
        @AuraEnabled public String windowLabel;
        @AuraEnabled public Integer booked;
        @AuraEnabled public Integer qualified;
        @AuraEnabled public Decimal passThroughPct;
        @AuraEnabled public Decimal bookedAmount;
        @AuraEnabled public Decimal qualifiedAmount;
        @AuraEnabled public Decimal passThroughAmtPct;
        @AuraEnabled public Decimal goal;
        @AuraEnabled public Decimal amountGoal;
        @AuraEnabled public Decimal attainmentPct;
        @AuraEnabled public Decimal amountAttainmentPct;
    }

    public class TrendBucket {
        @AuraEnabled public String label;
        @AuraEnabled public Integer bookedCount;
        @AuraEnabled public Integer qualifiedCount;
        @AuraEnabled public Decimal bookedAmount;
        @AuraEnabled public Decimal qualifiedAmount;
    }

    public class GtmRow {
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Integer booked;
        @AuraEnabled public Integer qualified;
        @AuraEnabled public Decimal passThroughPct;
        @AuraEnabled public Decimal bookedAmount;
        @AuraEnabled public Decimal qualifiedAmount;
        @AuraEnabled public Decimal passThroughAmtPct;
        @AuraEnabled public Decimal goal;
        @AuraEnabled public Decimal amountGoal;
        @AuraEnabled public Decimal attainmentPct;
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

    // ---- @AuraEnabled API ----------------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static GtmStatus getGtmStatus(String windowLabel) {
        GtmStatus s = new GtmStatus();
        s.windowLabel = windowLabel;
        s.booked = 0;
        s.qualified = 0;
        s.passThroughPct = 0;
        s.bookedAmount = 0;
        s.qualifiedAmount = 0;
        s.passThroughAmtPct = 0;
        s.goal = 0;
        s.amountGoal = 0;
        s.attainmentPct = 0;
        s.amountAttainmentPct = 0;

        Set<Id> gtms = getGtmUserIds();
        if (gtms.isEmpty()) return s;

        Date[] window = getWindowDates(windowLabel);
        Map<Id, Opportunity> booked = getBookedInWindow(gtms, window[0], window[1]);
        if (!booked.isEmpty()) {
            Map<Id, DateTime> qualified = getFirstStage2PlusByOpp(booked.keySet());
            s.booked = booked.size();
            s.qualified = qualified.size();
            Decimal totalAmt = 0, qualAmt = 0;
            for (Id oid : booked.keySet()) {
                Decimal a = booked.get(oid).Amount == null ? 0 : booked.get(oid).Amount;
                totalAmt += a;
                if (qualified.containsKey(oid)) qualAmt += a;
            }
            s.bookedAmount = totalAmt;
            s.qualifiedAmount = qualAmt;
            s.passThroughPct = s.booked == 0 ? 0
                : (Decimal.valueOf(s.qualified) / s.booked) * 100;
            s.passThroughAmtPct = totalAmt == 0 ? 0 : (qualAmt / totalAmt) * 100;
        }

        // Goals: reuse NB_Goal__c + NB_Amount_Goal__c on PG_Quota__c, summed
        // across all GTMs and prorated by days-into-window.
        Decimal[] quotaSums = sumGtmQuotas(gtms);
        Decimal proration = windowProration(windowLabel);
        s.goal       = quotaSums[0] * proration;
        s.amountGoal = quotaSums[1] * proration;
        s.attainmentPct       = s.goal       == 0 ? 0 : (s.booked       / s.goal)       * 100;
        s.amountAttainmentPct = s.amountGoal == 0 ? 0 : (s.bookedAmount / s.amountGoal) * 100;
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static List<TrendBucket> getBookedTrendByWeek() {
        // Weekly buckets for the current fiscal quarter only.
        Date qStart = startOfCurrentFiscalQuarter();
        Date today = Date.today();
        Set<Id> gtms = getGtmUserIds();
        List<TrendBucket> result = new List<TrendBucket>();
        if (gtms.isEmpty()) return result;

        Map<Id, Opportunity> booked = getBookedInWindow(gtms, qStart, today);
        Map<Id, DateTime> qualified = getFirstStage2PlusByOpp(booked.keySet());

        Integer currentWeekIndex = today.daysBetween(qStart) * -1 / 7;
        Map<Integer, TrendBucket> byKey = new Map<Integer, TrendBucket>();
        for (Integer i = 0; i <= currentWeekIndex; i++) {
            Date wkStart = qStart.addDays(i * 7);
            TrendBucket tb = new TrendBucket();
            tb.label = wkStart.month() + '/' + wkStart.day();
            tb.bookedCount = 0;
            tb.qualifiedCount = 0;
            tb.bookedAmount = 0;
            tb.qualifiedAmount = 0;
            byKey.put(i, tb);
        }

        for (Id oid : booked.keySet()) {
            Opportunity o = booked.get(oid);
            Date created = o.CreatedDate.date();
            if (created < qStart || created > today) continue;
            Integer wkIdx = created.daysBetween(qStart) * -1 / 7;
            TrendBucket tb = byKey.get(wkIdx);
            if (tb == null) continue;
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            tb.bookedCount += 1;
            tb.bookedAmount += amt;
            if (qualified.containsKey(oid)) {
                tb.qualifiedCount += 1;
                tb.qualifiedAmount += amt;
            }
        }

        List<Integer> sortedKeys = new List<Integer>(byKey.keySet());
        sortedKeys.sort();
        for (Integer k : sortedKeys) result.add(byKey.get(k));
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<TrendBucket> getBookedTrendByQuarter(Integer numQuarters) {
        Integer n = (numQuarters == null || numQuarters <= 0) ? 6 : numQuarters;
        Set<Id> gtms = getGtmUserIds();
        List<TrendBucket> result = new List<TrendBucket>();
        if (gtms.isEmpty()) return result;

        // Look back N+1 quarters from today to cover edge cases at quarter
        // boundaries. We'll trim to the most recent N actual results.
        Date startBound = startOfCurrentFiscalQuarter().addMonths(-3 * n);
        Map<Id, Opportunity> booked = getBookedInWindow(gtms, startBound, Date.today());
        Map<Id, DateTime> qualified = getFirstStage2PlusByOpp(booked.keySet());

        Map<Integer, TrendBucket> byKey = new Map<Integer, TrendBucket>();
        for (Id oid : booked.keySet()) {
            Opportunity o = booked.get(oid);
            Date d = o.CreatedDate.date();
            Integer sortKey = fiscalSortKey(d);
            TrendBucket tb = byKey.get(sortKey);
            if (tb == null) {
                tb = new TrendBucket();
                tb.label = fiscalLabelFor(d);
                tb.bookedCount = 0;
                tb.qualifiedCount = 0;
                tb.bookedAmount = 0;
                tb.qualifiedAmount = 0;
                byKey.put(sortKey, tb);
            }
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            tb.bookedCount += 1;
            tb.bookedAmount += amt;
            if (qualified.containsKey(oid)) {
                tb.qualifiedCount += 1;
                tb.qualifiedAmount += amt;
            }
        }
        List<Integer> sortedKeys = new List<Integer>(byKey.keySet());
        sortedKeys.sort();
        List<TrendBucket> rows = new List<TrendBucket>();
        for (Integer k : sortedKeys) rows.add(byKey.get(k));
        if (rows.size() > n) {
            List<TrendBucket> trimmed = new List<TrendBucket>();
            for (Integer i = rows.size() - n; i < rows.size(); i++) trimmed.add(rows[i]);
            rows = trimmed;
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static List<GtmRow> getGtmRanking(String windowLabel) {
        Set<Id> gtms = getGtmUserIds();
        List<GtmRow> result = new List<GtmRow>();
        if (gtms.isEmpty()) return result;

        Date[] window = getWindowDates(windowLabel);
        Map<Id, Opportunity> booked = getBookedInWindow(gtms, window[0], window[1]);
        Map<Id, DateTime> qualified = getFirstStage2PlusByOpp(booked.keySet());
        Map<Id, Decimal[]> quotasByUser = getGtmQuotasByUser(gtms);
        Decimal proration = windowProration(windowLabel);

        Map<Id, GtmRow> byOwner = new Map<Id, GtmRow>();
        // Initialize a row for every GTM so a rep with zero bookings still
        // appears (with 0 / 0 / N/A pass-through).
        for (User u : [SELECT Id, Name FROM User WHERE Id IN :gtms]) {
            GtmRow row = new GtmRow();
            row.ownerId = u.Id;
            row.ownerName = u.Name;
            row.booked = 0;
            row.qualified = 0;
            row.passThroughPct = 0;
            row.bookedAmount = 0;
            row.qualifiedAmount = 0;
            row.passThroughAmtPct = 0;
            Decimal[] g = quotasByUser.get(u.Id);
            row.goal       = g == null ? 0 : g[0] * proration;
            row.amountGoal = g == null ? 0 : g[1] * proration;
            row.attainmentPct = 0;
            row.amountAttainmentPct = 0;
            byOwner.put(u.Id, row);
        }

        for (Id oid : booked.keySet()) {
            Opportunity o = booked.get(oid);
            GtmRow row = byOwner.get(o.Booked_By__c);
            if (row == null) continue;
            Decimal amt = o.Amount == null ? 0 : o.Amount;
            row.booked += 1;
            row.bookedAmount += amt;
            if (qualified.containsKey(oid)) {
                row.qualified += 1;
                row.qualifiedAmount += amt;
            }
        }

        for (GtmRow row : byOwner.values()) {
            row.passThroughPct    = row.booked       == 0 ? 0
                : (Decimal.valueOf(row.qualified)  / row.booked)       * 100;
            row.passThroughAmtPct = row.bookedAmount == 0 ? 0
                : (row.qualifiedAmount             / row.bookedAmount) * 100;
            row.attainmentPct       = row.goal       == 0 ? 0
                : (row.booked       / row.goal)       * 100;
            row.amountAttainmentPct = row.amountGoal == 0 ? 0
                : (row.bookedAmount / row.amountGoal) * 100;
            result.add(row);
        }
        // Default sort: booked count desc; LWC can resort by metric.
        result.sort(new GtmRowComparator());
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<OutreachRow> getIndividualOutreach(String windowLabel) {
        Set<Id> gtms = getGtmUserIds();
        List<OutreachRow> result = new List<OutreachRow>();
        if (gtms.isEmpty()) return result;

        Map<Id, OutreachRow> byOwner = new Map<Id, OutreachRow>();

        // Emails + Calls
        for (AggregateResult ar : queryEmailCallAggregates(gtms, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            String subtype = (String) ar.get('st');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            if (subtype == 'Email')     row.emails = cnt;
            else if (subtype == 'Call') row.calls  = cnt;
        }

        // LinkedIn — Sales Navigator integration
        for (AggregateResult ar : queryLinkedInAggregates(gtms, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            row.linkedin = cnt;
        }

        // Meetings — Discovery / First Meeting Events that actually happened
        for (AggregateResult ar : queryEventMeetings(gtms, windowLabel)) {
            Id oid = (Id) ar.get('oid');
            String oname = (String) ar.get('oname');
            Integer cnt = (Integer) ar.get('cnt');
            OutreachRow row = ensureRow(byOwner, oid, oname);
            row.meetings = cnt;
        }

        // Manager info enrichment
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

    // ---- Private helpers -----------------------------------------------------------

    private static Set<Id> getGtmUserIds() {
        if (gtmUserIdsCache != null) return gtmUserIdsCache;
        Set<Id> ids = new Set<Id>();
        for (User u : [
            SELECT Id FROM User
            WHERE IsActive = TRUE
              AND UserRole.Name = :GTM_ROLE_NAME
              AND Title = :GTM_TITLE
        ]) {
            ids.add(u.Id);
        }
        gtmUserIdsCache = ids;
        return ids;
    }

    private static Map<Id, Opportunity> getBookedInWindow(Set<Id> gtms, Date startDate, Date endDate) {
        if (gtms.isEmpty()) return new Map<Id, Opportunity>();
        DateTime startDt = DateTime.newInstance(startDate, Time.newInstance(0, 0, 0, 0));
        DateTime endDt   = DateTime.newInstance(endDate.addDays(1), Time.newInstance(0, 0, 0, 0));
        return new Map<Id, Opportunity>([
            SELECT Id, Amount, Booked_By__c, CreatedDate, StageName
            FROM Opportunity
            WHERE Booked_By__c IN :gtms
              AND Type IN :ALL_DASHBOARD_TYPES
              AND CreatedDate >= :startDt
              AND CreatedDate < :endDt
        ]);
    }

    private static Map<Id, DateTime> getFirstStage2PlusByOpp(Set<Id> oppIds) {
        if (mockFirstStage2PlusByOpp != null) return mockFirstStage2PlusByOpp;
        Map<Id, DateTime> out = new Map<Id, DateTime>();
        if (oppIds == null || oppIds.isEmpty()) return out;
        for (AggregateResult ar : [
            SELECT OpportunityId oid, MIN(CreatedDate) firstDt
            FROM OpportunityHistory
            WHERE StageName IN :STAGE_2_PLUS
              AND OpportunityId IN :oppIds
            GROUP BY OpportunityId
        ]) {
            out.put((Id) ar.get('oid'), (DateTime) ar.get('firstDt'));
        }
        return out;
    }

    // ---- Quotas ----

    // Returns [totalCountGoal, totalAmountGoal] across all GTMs for current quarter.
    private static Decimal[] sumGtmQuotas(Set<Id> gtms) {
        Decimal[] out = new Decimal[]{ 0, 0 };
        if (gtms.isEmpty()) return out;
        Map<String, Integer> fyfq = fiscalYearAndQuarter(Date.today());
        Integer fy = fyfq.get('fy');
        Integer fq = fyfq.get('fq');
        for (PG_Quota__c q : [
            SELECT NB_Goal__c, NB_Amount_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :gtms
              AND Fiscal_Year__c = :fy
              AND Fiscal_Quarter__c = :fq
        ]) {
            out[0] += (q.NB_Goal__c == null ? 0 : q.NB_Goal__c);
            out[1] += (q.NB_Amount_Goal__c == null ? 0 : q.NB_Amount_Goal__c);
        }
        return out;
    }

    // Returns per-user current-quarter quota: ownerId -> [countGoal, amountGoal].
    private static Map<Id, Decimal[]> getGtmQuotasByUser(Set<Id> gtms) {
        Map<Id, Decimal[]> out = new Map<Id, Decimal[]>();
        if (gtms.isEmpty()) return out;
        Map<String, Integer> fyfq = fiscalYearAndQuarter(Date.today());
        Integer fy = fyfq.get('fy');
        Integer fq = fyfq.get('fq');
        for (PG_Quota__c q : [
            SELECT User__c, NB_Goal__c, NB_Amount_Goal__c
            FROM PG_Quota__c
            WHERE User__c IN :gtms
              AND Fiscal_Year__c = :fy
              AND Fiscal_Quarter__c = :fq
        ]) {
            out.put(q.User__c, new Decimal[]{
                q.NB_Goal__c        == null ? 0 : q.NB_Goal__c,
                q.NB_Amount_Goal__c == null ? 0 : q.NB_Amount_Goal__c
            });
        }
        return out;
    }

    // ---- Outreach query helpers (mirror PGInsightsController) ------------------------

    private static List<AggregateResult> queryEmailCallAggregates(Set<Id> gtms, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, TaskSubtype st, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :gtms
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
            WHERE OwnerId IN :gtms
              AND Status = 'Completed'
              AND ActivityDate = THIS_FISCAL_QUARTER
              AND (
                  (TaskSubtype = 'Email' AND NektarSender__c = 'Us')
                  OR TaskSubtype = 'Call'
              )
            GROUP BY OwnerId, Owner.Name, TaskSubtype
        ];
    }

    private static List<AggregateResult> queryLinkedInAggregates(Set<Id> gtms, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Task
                WHERE OwnerId IN :gtms
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
            WHERE OwnerId IN :gtms
              AND TaskSubtype = 'Task'
              AND Subject LIKE '%Sales Navigator%'
              AND Subject LIKE '%Sent%'
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
        ];
    }

    private static List<AggregateResult> queryEventMeetings(Set<Id> gtms, String windowLabel) {
        if (windowLabel == 'CW') {
            return [
                SELECT OwnerId oid, Owner.Name oname, COUNT(Id) cnt
                FROM Event
                WHERE OwnerId IN :gtms
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
            WHERE OwnerId IN :gtms
              AND NektarSender__c = 'Us'
              AND NektarStatus__c = 'completed'
              AND Meeting_Type__c IN ('Discovery', 'First Meeting')
              AND ActivityDate = THIS_FISCAL_QUARTER
            GROUP BY OwnerId, Owner.Name
        ];
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

    // ---- Date / fiscal helpers -----------------------------------------------------

    // Returns [start, end] inclusive for the chosen window.
    private static Date[] getWindowDates(String windowLabel) {
        Date today = Date.today();
        if (windowLabel == 'CM') {
            return new Date[]{ today.toStartOfMonth(), today };
        }
        return new Date[]{ startOfCurrentFiscalQuarter(), today };
    }

    private static Decimal windowProration(String windowLabel) {
        Date today = Date.today();
        Date wStart, wEnd;
        if (windowLabel == 'CM') {
            wStart = today.toStartOfMonth();
            wEnd   = wStart.addMonths(1).addDays(-1);
        } else {
            wStart = startOfCurrentFiscalQuarter();
            wEnd   = wStart.addMonths(3).addDays(-1);
        }
        Integer daysElapsed = today.daysBetween(wStart) * -1 + 1;
        Integer totalDays = wEnd.daysBetween(wStart) * -1 + 1;
        if (totalDays <= 0) return 1;
        if (daysElapsed > totalDays) daysElapsed = totalDays;
        return Decimal.valueOf(daysElapsed) / Decimal.valueOf(totalDays);
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

    private static Integer fiscalSortKey(Date d) {
        Map<String, Integer> fyfq = fiscalYearAndQuarter(d);
        return fyfq.get('fy') * 10 + fyfq.get('fq');
    }

    private static String fiscalLabelFor(Date d) {
        Map<String, Integer> fyfq = fiscalYearAndQuarter(d);
        return 'FY' + fyfq.get('fy') + '-Q' + fyfq.get('fq');
    }

    // ---- Comparators -----------------------------------------------------------------

    private class GtmRowComparator implements Comparator<GtmRow> {
        public Integer compare(GtmRow a, GtmRow b) {
            if (b.booked != a.booked) return b.booked > a.booked ? 1 : -1;
            if (b.bookedAmount > a.bookedAmount) return 1;
            if (b.bookedAmount < a.bookedAmount) return -1;
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
