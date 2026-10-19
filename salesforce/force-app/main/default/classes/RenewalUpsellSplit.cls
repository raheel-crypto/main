/**
 * Renewal and upsell closing together: the expansion counts on the upsell.
 *
 * A renewal and an upsell on the same account that close within WINDOW_DAYS are
 * usually sold on one paper that states the new total. Sales books the renewal
 * at its own amount (the renewal opportunity's ARR) and the growth on the
 * upsell, and the extractions follow that split:
 *  - the renewal's incremental ARR = what the renewal opportunity booked minus
 *    the renewal base (Base_ARR__c: Expected Renewal, else the prior ARR);
 *  - an upsell whose own paper states no increment gets the rest of the renewal
 *    paper's growth (paper total minus what the renewal booked).
 * An upsell that states its own increment keeps it. Nothing changes when the
 * renewal paper comes to no more than the renewal booked (separate papers).
 * Every change is marked derived in the evidence, and re-running is idempotent.
 */
public with sharing class RenewalUpsellSplit {

    @TestVisible private static final Integer WINDOW_DAYS = 14;
    @TestVisible private static final String MARK = 'Incremental_ARR(renewal+upsell)';

    // What each planned change does, by extraction Id (for dry runs).
    public static Map<Id, String> notes = new Map<Id, String>();

    /** Plan and save the split for the pairs on these opportunities' accounts. */
    public static void applyForOpportunities(Set<Id> oppIds) {
        List<Order_Form_Extraction__c> changes = planForOpportunities(oppIds);
        if (!changes.isEmpty()) Database.update(changes, false);
    }

    public static List<Order_Form_Extraction__c> planForOpportunities(Set<Id> oppIds) {
        Set<Id> accounts = new Set<Id>();
        if (oppIds == null || oppIds.isEmpty()) return new List<Order_Form_Extraction__c>();
        for (Opportunity o : [SELECT AccountId FROM Opportunity WHERE Id IN :oppIds AND AccountId != null]) {
            accounts.add(o.AccountId);
        }
        return planForAccounts(accounts);
    }

    /** The changes for every renewal + upsell pair on these accounts, unsaved. */
    public static List<Order_Form_Extraction__c> planForAccounts(Set<Id> accountIds) {
        notes.clear();
        List<Order_Form_Extraction__c> out = new List<Order_Form_Extraction__c>();
        if (accountIds == null || accountIds.isEmpty()) return out;

        Map<Id, List<Order_Form_Extraction__c>> renewalsByAccount = new Map<Id, List<Order_Form_Extraction__c>>();
        Map<Id, List<Order_Form_Extraction__c>> upsellsByAccount = new Map<Id, List<Order_Form_Extraction__c>>();
        for (Order_Form_Extraction__c r : [
            SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.AccountId,
                   Opportunity__r.CloseDate, Opportunity__r.Annual_Recurring_Revenue__c,
                   Annual_Recurring_Revenue__c, Base_ARR__c, Incremental_ARR__c,
                   Derived_Fields__c, Extract_Evidence__c
            FROM Order_Form_Extraction__c
            WHERE Is_Current__c = true AND Opportunity__r.AccountId IN :accountIds
              AND Opportunity__r.Type IN ('Renewal', 'Upsell') AND Opportunity__r.CloseDate != null
        ]) {
            Map<Id, List<Order_Form_Extraction__c>> bucket =
                r.Opportunity__r.Type == 'Renewal' ? renewalsByAccount : upsellsByAccount;
            if (!bucket.containsKey(r.Opportunity__r.AccountId)) {
                bucket.put(r.Opportunity__r.AccountId, new List<Order_Form_Extraction__c>());
            }
            bucket.get(r.Opportunity__r.AccountId).add(r);
        }

        for (Id acct : renewalsByAccount.keySet()) {
            if (!upsellsByAccount.containsKey(acct)) continue;
            for (Order_Form_Extraction__c ren : renewalsByAccount.get(acct)) {
                Decimal total = ren.Annual_Recurring_Revenue__c;
                Decimal booked = ren.Opportunity__r.Annual_Recurring_Revenue__c;
                if (total == null || booked == null) continue;
                List<Order_Form_Extraction__c> companions = new List<Order_Form_Extraction__c>();
                for (Order_Form_Extraction__c up : upsellsByAccount.get(acct)) {
                    Integer gap = Math.abs(ren.Opportunity__r.CloseDate.daysBetween(up.Opportunity__r.CloseDate));
                    if (gap <= WINDOW_DAYS) companions.add(up);
                }
                if (companions.isEmpty()) continue;
                Decimal extra = total - booked;
                if (extra <= Math.max((Decimal) 1, total.abs() * 0.005)) continue;   // separate papers

                String names = '';
                for (Order_Form_Extraction__c up : companions) {
                    names += (names == '' ? '' : '; ') + up.Opportunity__r.Name;
                }
                // The renewal: its own change only.
                if (ren.Base_ARR__c != null) {
                    Decimal own = booked - ren.Base_ARR__c;
                    if (ren.Incremental_ARR__c != own) {
                        out.add(marked(ren, own, 'Renewal paper ' + total + ' includes ' + extra
                            + ' of expansion sold on [' + names + ']; it counts there. Renewal booked ' + booked
                            + ' minus base ' + ren.Base_ARR__c + ' = ' + own + '.'));
                    }
                }
                // Upsells: one that states no increment of its own takes the rest.
                List<Order_Form_Extraction__c> open = new List<Order_Form_Extraction__c>();
                Decimal stated = 0;
                for (Order_Form_Extraction__c up : companions) {
                    Boolean ours = up.Derived_Fields__c != null && up.Derived_Fields__c.contains(MARK);
                    if (ours || up.Incremental_ARR__c == null || up.Incremental_ARR__c == 0) open.add(up);
                    else stated += up.Incremental_ARR__c;
                }
                if (open.size() == 1) {
                    Order_Form_Extraction__c up = open[0];
                    Decimal rest = extra - stated;
                    if (rest > 0 && up.Incremental_ARR__c != rest) {
                        out.add(marked(up, rest, 'Sold with [' + ren.Opportunity__r.Name + ']: renewal paper ' + total
                            + ' minus the renewal\'s booked ' + booked
                            + (stated == 0 ? '' : ' minus ' + stated + ' stated on the other upsell(s)')
                            + ' = ' + rest + ' of expansion, counted here.'));
                    }
                }
            }
        }
        return out;
    }

    private static Order_Form_Extraction__c marked(Order_Form_Extraction__c src, Decimal inc, String note) {
        Order_Form_Extraction__c c = new Order_Form_Extraction__c(Id = src.Id, Incremental_ARR__c = inc);
        List<String> fields = String.isBlank(src.Derived_Fields__c)
            ? new List<String>() : src.Derived_Fields__c.split(';');
        if (!fields.contains(MARK)) fields.add(MARK);
        c.Derived_Fields__c = String.join(fields, ';').left(255);
        try {
            Map<String, Object> ev = String.isBlank(src.Extract_Evidence__c)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(src.Extract_Evidence__c);
            ev.put('Incremental_ARR', new Map<String, Object>{ 'clause' => 'Computed by extractor', 'derived' => note });
            c.Extract_Evidence__c = JSON.serialize(ev).left(32768);
        } catch (Exception e) {
            // Evidence that is not a JSON object is left as it is.
        }
        notes.put(src.Id, src.Opportunity__r.Name + ' | incremental ' + src.Incremental_ARR__c + ' -> ' + inc + ' | ' + note);
        return c;
    }
}
