// =============================================================================
// Renewal + upsell sold together: count the expansion on the upsell
// =============================================================================
// When a renewal and an upsell on the same account close within 14 days, the
// renewal's paper usually states the new total, so its incremental ARR took the
// whole expansion - and when the upsell's own paper also stated it, the growth
// was counted twice (Raymond James, DC Advisory, Leerink, Boxwood, Jefferies,
// Nomura). The current process books the growth on the upsell, so:
//   - the renewal's incremental = what the renewal opportunity booked minus its
//     base (Expected Renewal, else the prior ARR);
//   - an upsell whose paper states no increment of its own gets the rest of the
//     renewal paper's growth; one that states its increment keeps it.
// Separate papers (the renewal paper is no more than the renewal booked) are
// left alone. New extractions do this automatically (RenewalUpsellSplit).
//
// DRY_RUN = true (default) lists every change. Then set DRY_RUN = false.
//
// Run: sf apex run --target-org rogo --file scripts/apex/splitRenewalUpsellPairs.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write

Set<Id> accounts = new Set<Id>();
for (AggregateResult ar : [
    SELECT Opportunity__r.AccountId a FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Opportunity__r.Type = 'Renewal' AND Opportunity__r.AccountId != null
    GROUP BY Opportunity__r.AccountId
]) {
    accounts.add((Id) ar.get('a'));
}

List<Order_Form_Extraction__c> changes = RenewalUpsellSplit.planForAccounts(accounts);
for (Order_Form_Extraction__c c : changes) System.debug(RenewalUpsellSplit.notes.get(c.Id));
System.debug('--- Accounts with a renewal: ' + accounts.size() + '; extraction rows to change: ' + changes.size());
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to apply.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(changes, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
System.debug('--- Updated ' + ok + ' of ' + changes.size() + '.');
