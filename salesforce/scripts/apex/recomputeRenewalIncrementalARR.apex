// =============================================================================
// Renewal incremental ARR from the renewal opportunity's Expected Renewal
// =============================================================================
// A renewal's incremental ARR is its ARR minus the ARR that was up for renewal,
// which is the renewal opportunity's Expected Renewal (Expected_Renewal__c).
// The extractor uses it from 2026-10-18 (falling back to the prior ARR when it
// is blank); this brings current renewal extractions up to date without
// re-reading any document. Rows whose opportunity has no Expected Renewal are
// left as they are.
//
// Run AFTER the refresh. DRY_RUN = true (default) lists every change.
//
// Run: sf apex run --target-org rogo --file scripts/apex/recomputeRenewalIncrementalARR.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write

List<Order_Form_Extraction__c> changes = new List<Order_Form_Extraction__c>();
Integer seen = 0;
for (Order_Form_Extraction__c r : [
    SELECT Id, Opportunity__r.Name, Opportunity__r.Expected_Renewal__c,
           Annual_Recurring_Revenue__c, Base_ARR__c, Incremental_ARR__c
    FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Type__c = 'Renewal'
      AND Annual_Recurring_Revenue__c != null AND Opportunity__r.Expected_Renewal__c > 0
]) {
    seen++;
    Decimal base = r.Opportunity__r.Expected_Renewal__c;
    Decimal inc = r.Annual_Recurring_Revenue__c - base;
    if (r.Base_ARR__c == base && r.Incremental_ARR__c == inc) continue;
    System.debug(r.Opportunity__r.Name + ' | ARR ' + r.Annual_Recurring_Revenue__c
        + ' | base ' + r.Base_ARR__c + ' -> ' + base + ' | incremental ' + r.Incremental_ARR__c + ' -> ' + inc);
    changes.add(new Order_Form_Extraction__c(Id = r.Id, Base_ARR__c = base, Incremental_ARR__c = inc));
}
System.debug('--- Renewal extractions with an Expected Renewal: ' + seen + '; to update: ' + changes.size());
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to update.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(changes, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
System.debug('--- Updated ' + ok + ' of ' + changes.size() + '.');
