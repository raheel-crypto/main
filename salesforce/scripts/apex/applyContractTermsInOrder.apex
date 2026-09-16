// =============================================================================
// Apply Contract legal terms in the proper order (New Business -> upsells)
// =============================================================================
// Applies ContractLegalTermsApplier to every Success extraction that hasn't been
// applied yet (Applied_Contract__c = null), in the correct order so a contract's
// terms are laid down before any amendment reconciles against them:
//   1) fresh-contract deals first (New Business / Renewal / Pilot),
//   2) then amendments (Upsell / Downsell / Contract Restructure),
//   both ordered by CloseDate ascending (chronological).
//
// WHY one apply() call per OFE: ContractLegalTermsApplier loads the target
// Contract once per call and reconciles against it. Calling it per-OFE in order
// means each amendment sees the PRIOR calls' committed changes (DML earlier in a
// transaction is visible to later SOQL), so upsells reconcile against the
// New Business terms - not a blank contract.
//
// Governor-safe: capped at CAP apply() calls per run (each is ~3 SOQL / 2 DML).
// Resumable - applied OFEs get stamped Applied_Contract__c, so re-run until
// "Remaining unapplied" is 0.
//
// Run: sf apex run --target-org rogo --file scripts/apex/applyContractTermsInOrder.apex
// (or paste into Dev Console -> Execute Anonymous)
// =============================================================================

Integer CAP = 25;   // apply() calls per run; re-run until nothing remains

Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

// Unapplied Success extractions, chronological.
List<Order_Form_Extraction__c> unapplied = [
    SELECT Id, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.CloseDate
    FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success'
      AND Applied_Contract__c = null
      AND Opportunity__c != null
    ORDER BY Opportunity__r.CloseDate ASC NULLS LAST
];

// Partition: fresh-contract deals before amendments (both already date-sorted).
List<Order_Form_Extraction__c> ordered = new List<Order_Form_Extraction__c>();
List<Order_Form_Extraction__c> amends = new List<Order_Form_Extraction__c>();
for (Order_Form_Extraction__c o : unapplied) {
    String t = (o.Opportunity__r != null) ? o.Opportunity__r.Type : null;
    if (t != null && AMEND.contains(t)) amends.add(o);
    else ordered.add(o);   // New Business / Renewal / Pilot / (untyped) first
}
ordered.addAll(amends);

System.debug('--- Unapplied Success extractions: ' + unapplied.size()
    + ' (fresh: ' + (ordered.size() - amends.size()) + ', amendments: ' + amends.size() + ')');

// Apply in order, one call each so each reconciles against prior committed state.
Integer done = 0;
Map<String, Integer> statusCounts = new Map<String, Integer>();
List<String> notable = new List<String>();
for (Order_Form_Extraction__c o : ordered) {
    if (done >= CAP) break;
    ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
    req.extractionId = o.Id;
    ContractLegalTermsApplier.Result res = ContractLegalTermsApplier.apply(
        new List<ContractLegalTermsApplier.Request>{ req })[0];

    Integer c = statusCounts.containsKey(res.status) ? statusCounts.get(res.status) : 0;
    statusCounts.put(res.status, c + 1);
    // Surface anything that isn't a clean apply so gaps/conflicts are visible.
    if (res.status != 'Applied') {
        notable.add((o.Opportunity__r != null ? o.Opportunity__r.Name : o.Id)
            + ' [' + (o.Opportunity__r != null ? o.Opportunity__r.Type : '?') + '] -> '
            + res.status + (String.isBlank(res.notes) ? '' : ' | ' + res.notes.left(200)));
    }
    done++;
}

System.debug('--- Applied this run: ' + done);
System.debug('--- Status counts: ' + statusCounts);
for (String n : notable) System.debug('NOTE: ' + n);

Integer remaining = [
    SELECT COUNT() FROM Order_Form_Extraction__c
    WHERE Extraction_Status__c = 'Success' AND Applied_Contract__c = null AND Opportunity__c != null
];
System.debug('--- Remaining unapplied after this run: ' + remaining + ' (re-run if > 0)');
