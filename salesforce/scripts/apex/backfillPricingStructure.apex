// =============================================================================
// Backfill Pricing_Structure__c using the deterministic axes
// =============================================================================
// Recomputes Pricing_Structure__c on existing OFE rows from:
//   1. ELA__c (true -> "ELA: ...", false -> "Seats: ...")
//   2. Credit_Commit__c OR Credits_Purchased__c > 0 -> "Credit-Based Usage"
//   3. Otherwise unlimited path; Rate_Limitable__c='Yes' -> "with Throttling",
//      else "No Throttling".
//
// Does NOT re-run extraction - it just recomputes the picklist value from
// fields already on the row. Cheap, no API cost.
//
// For rows that were extracted BEFORE the new credit / rate-limit fields
// shipped, Credit_Commit__c will default to false and Rate_Limitable__c will
// be null - so those rows collapse to "Unlimited Usage, No Throttling" per
// side (or Credit-Based if Credits_Purchased__c is set). Once you re-extract
// those rows with the new prompt, this backfill can be re-run to sharpen.
//
// Run:
//   sf apex run --target-org rogo-dev --file scripts/apex/backfillPricingStructure.apex
// Re-run in batches until "All caught up."
// =============================================================================

Integer CHUNK = 1000;

List<Order_Form_Extraction__c> rows = [
    SELECT Id, ELA__c, Credit_Commit__c, Credits_Purchased__c, Rate_Limitable__c,
           Pricing_Structure__c
    FROM Order_Form_Extraction__c
    ORDER BY LastModifiedDate ASC
    LIMIT :CHUNK
];
if (rows.isEmpty()) {
    System.debug('--- No OFE rows to process.');
    return;
}

List<Order_Form_Extraction__c> toUpdate = new List<Order_Form_Extraction__c>();
Map<String, Integer> counts = new Map<String, Integer>();
Integer unchanged = 0;

for (Order_Form_Extraction__c r : rows) {
    String derived = OrderFormExtractionJob.derivePricingStructure(r);
    counts.put(derived, (counts.containsKey(derived) ? counts.get(derived) : 0) + 1);
    if (derived != r.Pricing_Structure__c) {
        r.Pricing_Structure__c = derived;
        toUpdate.add(r);
    } else {
        unchanged++;
    }
}

if (!toUpdate.isEmpty()) update toUpdate;

System.debug('--- Processed ' + rows.size() + ' rows; ' + toUpdate.size() + ' updated, ' +
             unchanged + ' already correct.');
System.debug('--- Distribution: ' + counts);
System.debug('--- Re-run until this script reports 0 updated. (Idempotent; safe.)');
