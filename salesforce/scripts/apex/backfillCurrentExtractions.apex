// =============================================================================
// One-off: set Is_Current__c and Supersedes__c on existing extractions
// =============================================================================
// Rows created before version linking have neither. Per Opportunity this marks
// exactly one row current - the best on the quality ladder (Success with dates +
// ARR/TCV > Incomplete > No Order Form / hollow legacy Success > failures),
// ties going to the most recent - and links each row to the one before it.
// Idempotent and non-destructive: re-running changes nothing once it has run.
//
// Run: sf apex run --target-org rogo --file scripts/apex/backfillCurrentExtractions.apex
// =============================================================================

Boolean APPLY = true;   // false = report only

Map<Id, List<Order_Form_Extraction__c>> byOpp = new Map<Id, List<Order_Form_Extraction__c>>();
for (Order_Form_Extraction__c r : [
    SELECT Id, Opportunity__c, Extraction_Status__c, Type__c,
           Contract_Start_Date__c, Contract_End_Date__c,
           Annual_Recurring_Revenue__c, Total_Contract_Value__c, Incremental_ARR__c,
           Trial_Price__c, Paid_Trial__c, Is_Current__c, Supersedes__c, Extracted_At__c, CreatedDate
    FROM Order_Form_Extraction__c
    WHERE Opportunity__c != null
    ORDER BY Opportunity__c, Extracted_At__c ASC NULLS FIRST, CreatedDate ASC
]) {
    if (!byOpp.containsKey(r.Opportunity__c)) byOpp.put(r.Opportunity__c, new List<Order_Form_Extraction__c>());
    byOpp.get(r.Opportunity__c).add(r);
}

List<Order_Form_Extraction__c> updates = new List<Order_Form_Extraction__c>();
Integer linked = 0;
Integer currentChanged = 0;
Map<Integer, Integer> currentByRank = new Map<Integer, Integer>();
for (Id oppId : byOpp.keySet()) {
    List<Order_Form_Extraction__c> rows = byOpp.get(oppId);          // oldest first
    Order_Form_Extraction__c best = null;
    for (Order_Form_Extraction__c r : rows) {
        if (best == null || OrderFormVersioning.rank(r) >= OrderFormVersioning.rank(best)) best = r;  // ties -> newer
    }
    Integer br = OrderFormVersioning.rank(best);
    currentByRank.put(br, (currentByRank.containsKey(br) ? currentByRank.get(br) : 0) + 1);

    Order_Form_Extraction__c prev = null;
    for (Order_Form_Extraction__c r : rows) {
        Boolean wantCurrent = (r.Id == best.Id);
        Id wantSupersedes = (r.Supersedes__c != null) ? r.Supersedes__c : (prev == null ? null : prev.Id);
        if (r.Is_Current__c != wantCurrent || r.Supersedes__c != wantSupersedes) {
            updates.add(new Order_Form_Extraction__c(Id = r.Id, Is_Current__c = wantCurrent, Supersedes__c = wantSupersedes));
            if (r.Is_Current__c != wantCurrent) currentChanged++;
            if (r.Supersedes__c == null && wantSupersedes != null) linked++;
        }
        prev = r;
    }
}

if (APPLY && !updates.isEmpty()) update updates;
System.debug('--- Opportunities: ' + byOpp.size() + ' | rows updated: ' + updates.size()
    + ' | current flag changed: ' + currentChanged + ' | history links added: ' + linked
    + (APPLY ? '' : ' (REPORT ONLY - nothing written)'));
System.debug('--- Current row by quality (3=Success w/ minimums, 2=Incomplete, 1=No Order Form or hollow legacy Success, 0=failure): '
    + currentByRank);
