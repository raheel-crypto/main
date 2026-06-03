// =============================================================================
// Realign Order_Form_Extraction__c.Type__c with Opportunity.Type
// =============================================================================
// One-shot fix for rows whose extracted Type__c doesn't match the parent Opp's
// Type. Going forward, OrderFormExtractionJob always writes Opp.Type to Type__c,
// but historical rows captured Claude's classification.
//
// Also recomputes Incremental_ARR__c when the corrected Type__c moves a row
// from non-expansion to expansion (or vice versa).
//
// Run repeatedly (1000 rows at a time) until "All caught up." is printed.
//   sf apex run --target-org rogo --file scripts/apex/realignOFETypeWithOpp.apex
// =============================================================================

Integer CHUNK = 1000;
Set<String> EXPANSION_TYPES = new Set<String>{'Upsell','Renewal','Downsell','Contract Restructure'};

List<Order_Form_Extraction__c> rows = [
    SELECT Id, Opportunity__c, Type__c,
           Annual_Recurring_Revenue__c, Incremental_ARR__c, Base_ARR__c,
           Opportunity__r.Type
    FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success'
      AND Opportunity__r.Type != null
      AND Type__c != Opportunity__r.Type
    LIMIT :CHUNK
];

if (rows.isEmpty()) {
    System.debug('--- All caught up. No rows need Type__c realignment.');
    return;
}
System.debug('--- Realigning Type__c on ' + rows.size() + ' row(s).');

// Gather Opp Ids for base ARR lookup of rows whose corrected Type is expansion.
Set<Id> baseOppIds = new Set<Id>();
Map<Id, Id> baseOppByOpp = new Map<Id, Id>();
Set<Id> oppsNeedingBase = new Set<Id>();
for (Order_Form_Extraction__c r : rows) {
    if (EXPANSION_TYPES.contains(r.Opportunity__r.Type)) {
        oppsNeedingBase.add(r.Opportunity__c);
    }
}
for (Opportunity opp : [SELECT Id, Base_Opportunity__c FROM Opportunity WHERE Id IN :oppsNeedingBase]) {
    if (opp.Base_Opportunity__c != null) {
        baseOppByOpp.put(opp.Id, opp.Base_Opportunity__c);
        baseOppIds.add(opp.Base_Opportunity__c);
    }
}

// Bulk-load base ARR (OFE preferred, Opp field fallback).
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
    for (Opportunity base : [
        SELECT Id, Annual_Recurring_Revenue__c FROM Opportunity
        WHERE Id IN :baseOppIds AND Annual_Recurring_Revenue__c != null
    ]) {
        if (!baseARRByOpp.containsKey(base.Id)) baseARRByOpp.put(base.Id, base.Annual_Recurring_Revenue__c);
    }
}

Integer changedType = 0, recomputedIncremental = 0, clearedIncremental = 0;
for (Order_Form_Extraction__c r : rows) {
    r.Type__c = r.Opportunity__r.Type;
    changedType++;

    // Re-evaluate Incremental_ARR based on the new Type__c.
    if (r.Annual_Recurring_Revenue__c == null) continue;

    if (!EXPANSION_TYPES.contains(r.Type__c)) {
        // Non-expansion (New Business / Pilot / Debooking): incremental = total
        r.Incremental_ARR__c = r.Annual_Recurring_Revenue__c;
        r.Base_ARR__c = null;
        recomputedIncremental++;
    } else {
        Id baseOppId = baseOppByOpp.get(r.Opportunity__c);
        Decimal baseARR = baseOppId == null ? null : baseARRByOpp.get(baseOppId);
        if (baseARR != null) {
            r.Base_ARR__c = baseARR;
            r.Incremental_ARR__c = r.Annual_Recurring_Revenue__c - baseARR;
            recomputedIncremental++;
        } else {
            // No way to compute incremental for an expansion deal without a base ARR.
            r.Incremental_ARR__c = null;
            r.Base_ARR__c = null;
            clearedIncremental++;
        }
    }
}

update rows;
System.debug('--- Done. Type changed: ' + changedType + '; Incremental_ARR recomputed: ' +
             recomputedIncremental + '; cleared (no base): ' + clearedIncremental);

Integer remaining = [
    SELECT COUNT() FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success'
      AND Opportunity__r.Type != null
      AND Type__c != Opportunity__r.Type
];
System.debug('--- ' + remaining + ' row(s) remaining for next run.');
