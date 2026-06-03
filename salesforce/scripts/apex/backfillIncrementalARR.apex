// =============================================================================
// Backfill Incremental_ARR__c + Base_ARR__c on existing OFE rows
// =============================================================================
// Computes the two new fields on every successful extraction that was created
// before the incremental-ARR feature shipped. No callouts; just SOQL + DML.
//
// For New Business / Pilot / Type=null: Incremental_ARR = Annual_Recurring_Revenue.
// For Upsell / Renewal / Downsell / Contract Restructure with Base_Opportunity__c
//   populated: Incremental_ARR = ARR - base.ARR; Base_ARR = base.ARR.
// For expansion-type deals with no Base_Opportunity__c, leaves both null.
//
// Run repeatedly (1000 rows at a time) until "All caught up." is printed.
//   sf apex run --target-org rogo-prod --file salesforce/scripts/apex/backfillIncrementalARR.apex
// =============================================================================

Integer CHUNK = 1000;
Set<String> EXPANSION_TYPES = new Set<String>{'Upsell','Renewal','Downsell','Contract Restructure'};

List<Order_Form_Extraction__c> rows = [
    SELECT Id, Opportunity__c, Type__c,
           Annual_Recurring_Revenue__c, Incremental_ARR__c, Base_ARR__c
    FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success'
      AND Annual_Recurring_Revenue__c != null
      AND Incremental_ARR__c = null
    LIMIT :CHUNK
];

if (rows.isEmpty()) {
    System.debug('--- All caught up. No rows need Incremental_ARR__c computed.');
    return;
}
System.debug('--- Processing ' + rows.size() + ' OFE row(s)');

Set<Id> oppIds = new Set<Id>();
for (Order_Form_Extraction__c r : rows) oppIds.add(r.Opportunity__c);

Map<Id, Opportunity> oppById = new Map<Id, Opportunity>([
    SELECT Id, Base_Opportunity__c FROM Opportunity WHERE Id IN :oppIds
]);

// Collect base Opp Ids that need ARR lookup
Set<Id> baseOppIds = new Set<Id>();
for (Order_Form_Extraction__c r : rows) {
    if (!EXPANSION_TYPES.contains(r.Type__c)) continue;
    Opportunity opp = oppById.get(r.Opportunity__c);
    if (opp != null && opp.Base_Opportunity__c != null) baseOppIds.add(opp.Base_Opportunity__c);
}

// Bulk load preferred source: latest successful OFE ARR per base Opp.
Map<Id, Decimal> baseARRByOpp = new Map<Id, Decimal>();
if (!baseOppIds.isEmpty()) {
    for (Order_Form_Extraction__c base : [
        SELECT Opportunity__c, Annual_Recurring_Revenue__c, CreatedDate
        FROM Order_Form_Extraction__c
        WHERE Opportunity__c IN :baseOppIds
          AND Extraction_Status__c = 'Success'
          AND Annual_Recurring_Revenue__c != null
        ORDER BY CreatedDate DESC
    ]) {
        if (!baseARRByOpp.containsKey(base.Opportunity__c)) {
            baseARRByOpp.put(base.Opportunity__c, base.Annual_Recurring_Revenue__c);
        }
    }
    // Fallback source: the base Opp's own Annual_Recurring_Revenue__c field
    // for bases that predate the signed__* convention.
    for (Opportunity base : [
        SELECT Id, Annual_Recurring_Revenue__c
        FROM Opportunity
        WHERE Id IN :baseOppIds
          AND Annual_Recurring_Revenue__c != null
    ]) {
        if (!baseARRByOpp.containsKey(base.Id)) {
            baseARRByOpp.put(base.Id, base.Annual_Recurring_Revenue__c);
        }
    }
}

// Compute updates
List<Order_Form_Extraction__c> toUpdate = new List<Order_Form_Extraction__c>();
Integer countNewBiz = 0;
Integer countWithBase = 0;
Integer countMissingBase = 0;

for (Order_Form_Extraction__c r : rows) {
    if (!EXPANSION_TYPES.contains(r.Type__c)) {
        // New Business / Pilot / null Type: incremental = total
        r.Incremental_ARR__c = r.Annual_Recurring_Revenue__c;
        toUpdate.add(r);
        countNewBiz++;
        continue;
    }
    Opportunity opp = oppById.get(r.Opportunity__c);
    if (opp == null || opp.Base_Opportunity__c == null) {
        countMissingBase++;
        continue;
    }
    Decimal baseARR = baseARRByOpp.get(opp.Base_Opportunity__c);
    if (baseARR == null) {
        countMissingBase++;
        continue;
    }
    r.Base_ARR__c = baseARR;
    r.Incremental_ARR__c = r.Annual_Recurring_Revenue__c - baseARR;
    toUpdate.add(r);
    countWithBase++;
}

if (!toUpdate.isEmpty()) update toUpdate;

System.debug('--- Updated: ' + toUpdate.size() + ' rows');
System.debug('---   New Business / Pilot (incremental = total): ' + countNewBiz);
System.debug('---   Upsell-style with base ARR found: ' + countWithBase);
System.debug('---   Upsell-style skipped (no base or no base extraction): ' + countMissingBase);

Integer remaining = [
    SELECT COUNT() FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success'
      AND Annual_Recurring_Revenue__c != null
      AND Incremental_ARR__c = null
];
System.debug('--- ' + remaining + ' row(s) remaining for next run.');
