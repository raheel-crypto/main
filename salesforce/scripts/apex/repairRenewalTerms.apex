// =============================================================================
// Correct Contract renewal terms the "Manual renewal" misread put there
// =============================================================================
// Until 2026-10-16 the model answered "Manual renewal" for most clauses that
// renew on their own ("will automatically renew ... at Rogo's then-current
// list pricing unless otherwise mutually agreed" - the agreement there is about
// price - or "unless either party gives notice of non-renewal"). The extractor
// now checks that answer against its quote. Run this AFTER the full refresh.
//
// A refreshed extraction updates its row in place, so the applier does not
// run again and the Contract keeps the old value. For each Contract that says
// "Manual renewal", this takes the renewal terms the applier would lay down
// from the current extractions applied to it (the latest New Business /
// Renewal / Pilot paper; failing that, the first amendment that states one)
// and, when that is now an Auto-renew value, writes it and notes the change.
// Nothing else on the Contract is touched.
//
// DRY_RUN = true (default) lists the changes. Then set DRY_RUN = false.
//
// Run: sf apex run --target-org rogo --file scripts/apex/repairRenewalTerms.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write
Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

Map<Id, Contract> manual = new Map<Id, Contract>([
    SELECT Id, ContractNumber, Account.Name, Reconciliation_Notes__c
    FROM Contract WHERE Renewal_Terms__c = 'Manual renewal'
]);

Map<Id, String> freshValue = new Map<Id, String>();    // latest fresh deal wins
Map<Id, String> freshSource = new Map<Id, String>();
Map<Id, String> amendValue = new Map<Id, String>();    // first amendment that states one
Map<Id, String> amendSource = new Map<Id, String>();
for (Order_Form_Extraction__c o : [
    SELECT Applied_Contract__c, Renewal_Terms__c, Opportunity__r.Name, Opportunity__r.Type
    FROM Order_Form_Extraction__c
    WHERE Applied_Contract__c IN :manual.keySet() AND Is_Current__c = true
      AND Extraction_Status__c IN ('Success', 'Incomplete', 'No Order Form')
    ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
]) {
    if (o.Renewal_Terms__c == null) continue;
    Id c = o.Applied_Contract__c;
    if (!AMEND.contains(o.Opportunity__r.Type)) {
        freshValue.put(c, o.Renewal_Terms__c);           // chronological, so the last one stays
        freshSource.put(c, o.Opportunity__r.Name);
    } else if (!amendValue.containsKey(c)) {
        amendValue.put(c, o.Renewal_Terms__c);
        amendSource.put(c, o.Opportunity__r.Name);
    }
}

List<Contract> updates = new List<Contract>();
for (Contract c : manual.values()) {
    String v = freshValue.containsKey(c.Id) ? freshValue.get(c.Id) : amendValue.get(c.Id);
    String src = freshValue.containsKey(c.Id) ? freshSource.get(c.Id) : amendSource.get(c.Id);
    if (v == null || !v.startsWith('Auto-renew')) continue;
    String note = 'Renewal_Terms__c corrected: "Manual renewal" -> "' + v + '" from the refreshed read of ['
        + src + '] (renewal misread fixed 2026-10-16).';
    System.debug(c.ContractNumber + ' | ' + c.Account.Name + ' | Manual renewal -> ' + v + ' | from ' + src);
    String notes = String.isBlank(c.Reconciliation_Notes__c) ? note : c.Reconciliation_Notes__c + '\n\n' + note;
    updates.add(new Contract(Id = c.Id, Renewal_Terms__c = v, Reconciliation_Notes__c = notes.right(32768)));
}

System.debug('--- Contracts saying Manual renewal: ' + manual.size() + '; to correct: ' + updates.size()
    + ' (the rest are still Manual on the current read, or have no applied extraction).');
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to correct.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(updates, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
System.debug('--- Corrected ' + ok + ' of ' + updates.size() + '.');
