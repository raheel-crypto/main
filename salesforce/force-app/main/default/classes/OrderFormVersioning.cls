/**
 * Version linking and the quality ladder for Order_Form_Extraction__c.
 *
 * Ladder (higher is better):
 *   3  Success that meets the minimums (start + end dates, and ARR or TCV)
 *   2  Incomplete     - an order form was read but minimums are missing
 *   1  No Order Form  - only MSA / MNDA / DPA / other paper (also: a legacy
 *                       "Success" row that never had the minimums)
 *   0  API Failed / Parse Failed / No Document - transient, never displaces
 *
 * A new extraction supersedes the current row only when it ranks at least as
 * high, so a thin re-extraction (e.g. a screenshot) can no longer outrank a
 * complete earlier one. Every new row points at the row it superseded via
 * Supersedes__c; Is_Current__c marks the one to use per Opportunity.
 */
public with sharing class OrderFormVersioning {

    private static final Set<String> AMEND_TYPES =
        new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

    // What a row is missing for Success. Shared by the extractor's status gate
    // and the ladder, so both apply exactly the same rule.
    public static List<String> missingMinimums(Order_Form_Extraction__c r) {
        List<String> missing = new List<String>();
        if (r.Contract_Start_Date__c == null) missing.add('start date');
        if (r.Contract_End_Date__c == null) missing.add('end date');
        if (!hasEconomics(r)) missing.add('ARR or TCV');
        return missing;
    }

    private static Boolean hasEconomics(Order_Form_Extraction__c r) {
        if (r.Annual_Recurring_Revenue__c != null || r.Total_Contract_Value__c != null) return true;
        // An amendment that prices only the change has an ARR figure - the increment.
        if (r.Incremental_ARR__c != null && AMEND_TYPES.contains(r.Type__c)) return true;
        // A pilot's economics are its stated fee (a free pilot states TCV 0 - see the prompt).
        if (r.Type__c == 'Pilot' && r.Trial_Price__c != null) return true;
        return false;
    }

    public static Integer rank(Order_Form_Extraction__c r) {
        if (r == null) return -1;
        String s = r.Extraction_Status__c;
        if (s == 'Success') return missingMinimums(r).isEmpty() ? 3 : 1;
        if (s == 'Incomplete') return 2;
        if (s == 'No Order Form') return 1;
        return 0;
    }

    public static Boolean isAtLeastAsGood(Order_Form_Extraction__c fresh, Order_Form_Extraction__c current) {
        if (current == null) return true;
        Integer f = rank(fresh);
        return f > 0 && f >= rank(current);
    }

    // The row to compare against per Opportunity: the one flagged current; for
    // rows created before versioning (none flagged), the best-ranked row with ties
    // going to the most recent - the same rule as backfillCurrentExtractions.apex.
    public static Map<Id, Order_Form_Extraction__c> loadCurrentByOpp(Set<Id> oppIds) {
        Map<Id, Order_Form_Extraction__c> out = new Map<Id, Order_Form_Extraction__c>();
        if (oppIds == null || oppIds.isEmpty()) return out;
        for (Order_Form_Extraction__c r : [
            SELECT Id, Opportunity__c, Extraction_Status__c, Type__c,
                   Contract_Start_Date__c, Contract_End_Date__c,
                   Annual_Recurring_Revenue__c, Total_Contract_Value__c, Incremental_ARR__c,
                   Trial_Price__c, Paid_Trial__c, Is_Current__c, Rerun__c,
                   Extracted_At__c, LastModifiedDate
            FROM Order_Form_Extraction__c
            WHERE Opportunity__c IN :oppIds
            ORDER BY Opportunity__c, Is_Current__c DESC, Extracted_At__c DESC NULLS LAST, CreatedDate DESC
        ]) {
            Order_Form_Extraction__c have = out.get(r.Opportunity__c);
            // Rows arrive current-first, then newest-first: keep the first unless
            // nothing is flagged current and this older row ranks strictly higher.
            if (have == null || (have.Is_Current__c != true && r.Is_Current__c != true && rank(r) > rank(have))) {
                out.put(r.Opportunity__c, r);
            }
        }
        return out;
    }

    public static void insertWithVersioning(List<Order_Form_Extraction__c> rows) {
        insertWithVersioning(rows, null);
    }

    /**
     * Insert new extraction rows, linking each to the row it supersedes and
     * deciding which is current. forceReplaceOpps: Opportunities a person
     * flagged for rerun (Rerun__c) - there any readable result (rank > 0)
     * replaces the current row even if it ranks lower.
     */
    public static void insertWithVersioning(List<Order_Form_Extraction__c> rows, Set<Id> forceReplaceOpps) {
        if (rows == null || rows.isEmpty()) return;
        Set<Id> oppIds = new Set<Id>();
        for (Order_Form_Extraction__c r : rows) if (r.Opportunity__c != null) oppIds.add(r.Opportunity__c);
        Map<Id, Order_Form_Extraction__c> current = loadCurrentByOpp(oppIds);

        Map<Id, Order_Form_Extraction__c> demote = new Map<Id, Order_Form_Extraction__c>();
        for (Order_Form_Extraction__c r : rows) {
            if (r.Opportunity__c == null) { r.Is_Current__c = true; continue; }
            Order_Form_Extraction__c cur = current.get(r.Opportunity__c);
            if (cur != null && cur.Id != null) r.Supersedes__c = cur.Id;
            Boolean forced = forceReplaceOpps != null && forceReplaceOpps.contains(r.Opportunity__c) && rank(r) > 0;
            if (cur == null || forced || isAtLeastAsGood(r, cur)) {
                r.Is_Current__c = true;
                if (cur != null && cur.Is_Current__c == true) {
                    if (cur.Id != null) demote.put(cur.Id, new Order_Form_Extraction__c(Id = cur.Id, Is_Current__c = false));
                    else cur.Is_Current__c = false;   // an earlier row in this same list
                }
                current.put(r.Opportunity__c, r);
            } else {
                r.Is_Current__c = false;
            }
        }
        insert rows;
        if (!demote.isEmpty()) update demote.values();
    }
}
