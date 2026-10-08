/**
 * Usage + product terms for a Contract, folded from the order forms applied to
 * it (one current row per deal) in DEAL order - oldest first - so the result
 * is the same whatever order the extractions were applied in.
 *
 *   - Product / usage fields (package tier, Unlimited Lite, free Max/Mid, free
 *     tier, overage rate): the most recent paper that STATES a value wins. A
 *     silent or "Not specified" paper never erases, and "Inferred (Enterprise)"
 *     never overrides an explicit Yes / No.
 *   - Credits_Per_Year: a fresh deal (or an amendment restating the allocation)
 *     sets it; a later amendment adds its annualised Credits_Added (a downsell's
 *     is already negative).
 *   - Credit_Rate: blended - each tranche's rate weighted by its annual credits,
 *     across the allocation-setting paper and every amendment adding credits
 *     since. Reductions change the allocation, not the blended rate.
 *
 * ARR, seats and fees are deliberately absent: Contract.ARR__c, Seat_Licenses__c
 * and the fee fields are owned by the Opportunity flows (they roll into Account
 * ARR), so the order form figures stay on the extraction for comparison.
 */
public with sharing class ContractUsageRollup implements Database.Batchable<SObject> {

    // OFE field -> Contract field of the same API name.
    public static final List<String> PRODUCT_FIELDS = new List<String>{
        'Package_Tier__c', 'Unlimited_Lite__c', 'Free_Max_Mid_Credits__c',
        'Free_Max_Mid_Amount__c', 'Free_Tier_Retained__c', 'Overage_Rate__c'
    };

    private static final Set<String> AMEND_TYPES = new Set<String>{
        'Upsell', 'Downsell', 'Contract Restructure'
    };
    private static final String INFERRED = 'Inferred (Enterprise)';

    public class Result {
        public Map<String, Object> values = new Map<String, Object>();   // product field -> folded value
        public Map<String, String> sources = new Map<String, String>();  // product field -> deal it came from
        public Decimal creditsPerYear;
        public Decimal creditRate;
        public List<String> notes = new List<String>();
        public Boolean anyOrderForm = false;   // at least one paper was an order form
    }

    /**
     * rows: one extraction per deal, any order. Each needs Opportunity__r
     * (Name, Type, CloseDate, CreatedDate) for ordering and labels.
     */
    public static Result fold(List<Order_Form_Extraction__c> rows) {
        List<DealRow> ordered = new List<DealRow>();
        for (Order_Form_Extraction__c r : rows) if (r != null) ordered.add(new DealRow(r));
        ordered.sort();

        Result res = new Result();
        Decimal annual = null;
        Decimal weightedFee = 0;
        Decimal ratedCredits = 0;
        for (DealRow d : ordered) {
            Order_Form_Extraction__c r = d.row;
            if (r.Extraction_Status__c == 'No Order Form') continue;   // no economics on the paper
            res.anyOrderForm = true;

            for (String f : PRODUCT_FIELDS) {
                Object v = r.get(f);
                if (v == null || v == 'Not specified') continue;
                Object cur = res.values.get(f);
                if (v == INFERRED && (cur == 'Yes' || cur == 'No')) continue;
                res.values.put(f, v);
                res.sources.put(f, d.label);
            }

            Decimal rate = r.Credit_Rate__c;
            if (!d.isAmend || r.Credits_Per_Year__c != null) {
                // A fresh deal's paper (or an amendment restating the whole
                // allocation) sets the contract's allocation and rate.
                if (r.Credits_Per_Year__c == null) continue;
                annual = r.Credits_Per_Year__c;
                weightedFee = 0;
                ratedCredits = 0;
                if (rate != null && annual > 0) {
                    weightedFee = rate * annual;
                    ratedCredits = annual;
                }
            } else if (r.Credits_Added__c != null) {
                Decimal added = OrderFormExtractionJob.creditsPerYear(
                    r.Credits_Added__c, r.Credits_Period__c, r.Contract_Length_Months__c);
                if (added == null) {
                    res.notes.add(d.label + ': ' + r.Credits_Added__c + ' credits added with no period / term length'
                        + ' - not annualised, Credits Per Year left as is.');
                    continue;
                }
                annual = (annual == null ? 0 : annual) + added;
                if (added > 0 && rate != null) {
                    weightedFee += rate * added;
                    ratedCredits += added;
                }
            }
        }
        res.creditsPerYear = (annual == null) ? null : annual.setScale(2, RoundingMode.HALF_UP);
        res.creditRate = (ratedCredits > 0) ? weightedFee.divide(ratedCredits, 6, RoundingMode.HALF_UP) : null;
        return res;
    }

    /**
     * Puts the folded values on `changes` where they differ from `current` and
     * returns a log line per change. Pricing structure is recomputed from the
     * contract's own ELA / credit-commit / credits / throttling terms (as they
     * stand after `changes`) once an order form has been read; a hand-set
     * "Custom" is left alone. Nothing the papers never state is cleared.
     */
    public static List<String> writeTo(Result r, Contract current, Contract changes) {
        List<String> log = new List<String>(r.notes);
        for (String f : PRODUCT_FIELDS) {
            if (r.values.containsKey(f)) setIfChanged(current, changes, f, r.values.get(f), 'from ' + r.sources.get(f), log);
        }
        if (r.creditsPerYear != null) {
            setIfChanged(current, changes, 'Credits_Per_Year__c', r.creditsPerYear, 'annual credit allocation', log);
        }
        if (r.creditRate != null) {
            setIfChanged(current, changes, 'Credit_Rate__c', r.creditRate, 'blended committed rate', log);
        }
        Object curPs = (current == null) ? null : current.get('Pricing_Structure__c');
        if (r.anyOrderForm && curPs != 'Custom') {
            Decimal credits = (r.creditsPerYear != null)
                ? r.creditsPerYear : (Decimal) after(current, changes, 'Total_Credits_Purchased__c');
            String ps = OrderFormExtractionJob.derivePricingStructure(new Order_Form_Extraction__c(
                ELA__c = (Boolean) after(current, changes, 'ELA__c') == true,
                Credit_Commit__c = (Boolean) after(current, changes, 'Credit_Commit__c') == true,
                Credits_Purchased__c = credits,
                Rate_Limitable__c = (String) after(current, changes, 'Rate_Limitable__c')));
            setIfChanged(current, changes, 'Pricing_Structure__c', ps, 'from the contract\'s ELA / credit / throttling terms', log);
        }
        return log;
    }

    /**
     * Recomputes the usage + product fields of these contracts from every deal
     * already applied to them (one row per deal: the current one, else the
     * latest). Touches nothing else - no legal terms, so no review flags.
     * Returns the number of contracts updated.
     */
    public static Integer refresh(Set<Id> contractIds) {
        if (contractIds == null || contractIds.isEmpty()) return 0;
        Map<Id, List<Order_Form_Extraction__c>> dealsByContract = new Map<Id, List<Order_Form_Extraction__c>>();
        Set<String> seen = new Set<String>();
        for (Order_Form_Extraction__c r : [
            SELECT Applied_Contract__c, Opportunity__c, Opportunity__r.Name, Opportunity__r.Type,
                   Opportunity__r.CloseDate, Opportunity__r.CreatedDate,
                   Extraction_Status__c, Type__c, Extracted_At__c, Package_Tier__c, Unlimited_Lite__c,
                   Free_Max_Mid_Credits__c, Free_Max_Mid_Amount__c, Free_Tier_Retained__c, Overage_Rate__c,
                   Credit_Rate__c, Credits_Per_Year__c, Credits_Added__c, Credits_Period__c, Contract_Length_Months__c
            FROM Order_Form_Extraction__c
            WHERE Applied_Contract__c IN :contractIds
              AND Extraction_Status__c IN ('Success', 'Incomplete', 'No Order Form')
            ORDER BY Opportunity__c, Is_Current__c DESC, Extracted_At__c DESC NULLS LAST
        ]) {
            String key = r.Applied_Contract__c + ':' + (r.Opportunity__c != null ? (String) r.Opportunity__c : (String) r.Id);
            if (seen.contains(key)) continue;
            seen.add(key);
            if (!dealsByContract.containsKey(r.Applied_Contract__c))
                dealsByContract.put(r.Applied_Contract__c, new List<Order_Form_Extraction__c>());
            dealsByContract.get(r.Applied_Contract__c).add(r);
        }
        if (dealsByContract.isEmpty()) return 0;

        List<Contract> updates = new List<Contract>();
        for (Contract c : [
            SELECT Id, Package_Tier__c, Unlimited_Lite__c, Free_Max_Mid_Credits__c, Free_Max_Mid_Amount__c,
                   Free_Tier_Retained__c, Overage_Rate__c, Credits_Per_Year__c, Credit_Rate__c,
                   Pricing_Structure__c, Total_Credits_Purchased__c, ELA__c, Credit_Commit__c,
                   Rate_Limitable__c, Reconciliation_Notes__c
            FROM Contract WHERE Id IN :dealsByContract.keySet()
        ]) {
            Contract changes = new Contract(Id = c.Id);
            List<String> log = writeTo(fold(dealsByContract.get(c.Id)), c, changes);
            if (changes.getPopulatedFieldsAsMap().size() <= 1) continue;   // only Id: nothing changed
            String notes = (c.Reconciliation_Notes__c == null ? '' : c.Reconciliation_Notes__c + '\n')
                + 'Usage / product (recomputed ' + String.valueOf(Date.today()) + '):\n' + String.join(log, '\n');
            changes.Reconciliation_Notes__c = notes.length() > 32768 ? notes.substring(0, 32768) : notes;
            updates.add(changes);
        }
        if (!updates.isEmpty()) update updates;
        return updates.size();
    }

    // ----- Backfill: recompute every contract that has applied extractions -----
    // Chunks of 50: each Contract update runs the contract flows.

    public static Id runBackfill() {
        return Database.executeBatch(new ContractUsageRollup(), 50);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(
            'SELECT Id FROM Contract WHERE Id IN ' +
            '(SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Applied_Contract__c != null)');
    }

    public void execute(Database.BatchableContext bc, List<Contract> scope) {
        refresh(new Map<Id, Contract>(scope).keySet());
    }

    public void finish(Database.BatchableContext bc) {}

    // The value a Contract field will hold once `changes` land.
    private static Object after(Contract current, Contract changes, String f) {
        if (changes.getPopulatedFieldsAsMap().containsKey(f)) return changes.get(f);
        return (current == null) ? null : current.get(f);
    }

    private static void setIfChanged(Contract current, Contract changes, String f, Object v, String why, List<String> log) {
        Object cur = (current == null) ? null : current.get(f);
        if (same(cur, v)) return;
        changes.put(f, v);
        log.add((cur == null ? 'Wrote ' + f + ' = ' + v : 'Updated ' + f + ': "' + cur + '" -> "' + v + '"')
            + ' (' + why + ')');
    }

    private static Boolean same(Object a, Object b) {
        if (a == null || b == null) return a == b;
        if (a instanceof Decimal && b instanceof Decimal) return (Decimal) a == (Decimal) b;
        return String.valueOf(a) == String.valueOf(b);
    }

    // Deal order: close date, then creation; on a tie the fresh deal precedes
    // its amendments, then the earlier extraction.
    private class DealRow implements Comparable {
        Order_Form_Extraction__c row;
        Boolean isAmend;
        String label;
        Date closeDate;
        Datetime created;

        DealRow(Order_Form_Extraction__c r) {
            row = r;
            Opportunity o = r.Opportunity__r;
            String type = (o != null && o.Type != null) ? o.Type : r.Type__c;
            isAmend = AMEND_TYPES.contains(type);
            closeDate = (o == null) ? null : o.CloseDate;
            created = (o == null) ? null : o.CreatedDate;
            label = (o != null && o.Name != null ? o.Name : 'Opportunity ' + r.Opportunity__c)
                + (closeDate == null ? '' : ' (closed ' + String.valueOf(closeDate) + ')');
        }

        public Integer compareTo(Object other) {
            DealRow b = (DealRow) other;
            Integer c = cmp(closeDate, b.closeDate);
            if (c == 0) c = cmp(created, b.created);
            if (c == 0 && isAmend != b.isAmend) c = isAmend ? 1 : -1;
            if (c == 0) c = cmp(row.Extracted_At__c, b.row.Extracted_At__c);
            return c;
        }
    }

    // Nulls sort first (unknown dates are treated as oldest).
    private static Integer cmp(Date a, Date b) {
        if (a == b) return 0;
        if (a == null) return -1;
        if (b == null) return 1;
        return a < b ? -1 : 1;
    }

    private static Integer cmp(Datetime a, Datetime b) {
        if (a == b) return 0;
        if (a == null) return -1;
        if (b == null) return 1;
        return a < b ? -1 : 1;
    }
}
