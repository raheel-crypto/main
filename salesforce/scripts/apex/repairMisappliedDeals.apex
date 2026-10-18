// =============================================================================
// Rebuild Contracts another deal's paper was applied to by mistake
// =============================================================================
// Until 2026-10-16 a deal with no contract of its own was applied to "the
// account's newest contract". For a pilot / renewal / new business that is
// another deal's contract, and as a fresh deal it overwrote that contract's
// terms (LionTree's 2025 pilot set its Land contract to Unlimited). Deals
// applied before their own contract existed also landed on the prior
// contract, and upsells applied before their base deal was linked landed on a
// different contract than the base deal's. The applier no longer does this.
//
// A deal is on the wrong contract when the applier would now put it somewhere
// else (ContractLegalTermsApplier.currentTargets - the same rules it applies
// with; an upsell goes on its base deal's contract, or the latest new business
// / renewal before it). For each damaged Contract this, in one step:
//   1. detaches the wrongly applied deals (Applied_Contract__c cleared - the
//      next applyContractTermsInOrder.apex puts each on its own contract, or
//      lists it as having none),
//   2. blanks the term fields the applier manages (ContractLegalTermsApplier
//      .clearedTerms: legal terms, special terms, model changes, usage and
//      credit fields, review flag; contacts and billing details are kept),
//   3. re-applies the contract's own deals in deal order (new business /
//      renewal first, then amendments), which re-flags any genuine conflict.
//
// Run AFTER the refresh, BEFORE applyContractTermsInOrder.apex.
// DRY_RUN = true (default) lists each damaged contract with the deals it
// would detach and re-apply. Resumable: re-run until "Remaining: 0".
//
// Run: sf apex run --target-org rogo --file scripts/apex/repairMisappliedDeals.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to rebuild
Integer CAP = 8;          // contracts per run (stops early near a governor limit)
Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };
Set<String> APPLICABLE = new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };

List<Order_Form_Extraction__c> rows = [
    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.CloseDate,
           Opportunity__r.CreatedDate, Extraction_Status__c, Applied_Contract__c,
           Applied_Contract__r.ContractNumber, Applied_Contract__r.Account.Name
    FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Applied_Contract__c != null
    ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
];

// Where the applier would put each one now. A row is on the wrong contract
// when that differs from where it was applied (or it has no contract now).
Set<Id> rowIds = new Set<Id>();
for (Order_Form_Extraction__c r : rows) rowIds.add(r.Id);
Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(rowIds);

Map<Id, List<Order_Form_Extraction__c>> wrongByContract = new Map<Id, List<Order_Form_Extraction__c>>();
Map<Id, List<Order_Form_Extraction__c>> rightByContract = new Map<Id, List<Order_Form_Extraction__c>>();
Map<Id, String> moveTo = new Map<Id, String>();   // OFE -> where it goes next (for the dry run)
for (Order_Form_Extraction__c r : rows) {
    Id t = targets.get(r.Id);
    Boolean wrong = t != r.Applied_Contract__c;
    if (wrong) moveTo.put(r.Id, t == null ? 'no contract of its own' : String.valueOf(t));
    Map<Id, List<Order_Form_Extraction__c>> bucket = wrong ? wrongByContract : rightByContract;
    if (!bucket.containsKey(r.Applied_Contract__c)) bucket.put(r.Applied_Contract__c, new List<Order_Form_Extraction__c>());
    bucket.get(r.Applied_Contract__c).add(r);
}
Map<Id, String> numberById = new Map<Id, String>();
Set<Id> destIds = new Set<Id>();
for (String v : moveTo.values()) if (v.startsWith('800')) destIds.add(Id.valueOf(v));
for (Contract c : [SELECT Id, ContractNumber FROM Contract WHERE Id IN :destIds]) numberById.put(c.Id, c.ContractNumber);

System.debug('--- Damaged contracts: ' + wrongByContract.size());
if (DRY_RUN) {
    for (Id cid : wrongByContract.keySet()) {
        Order_Form_Extraction__c firstRow = wrongByContract.get(cid)[0];
        List<String> wrongNames = new List<String>();
        for (Order_Form_Extraction__c r : wrongByContract.get(cid)) {
            String dest = moveTo.get(r.Id);
            if (dest != null && dest.startsWith('800') && numberById.containsKey(Id.valueOf(dest))) dest = numberById.get(Id.valueOf(dest));
            wrongNames.add(r.Opportunity__r.Name + ' [' + r.Opportunity__r.Type + '] -> ' + dest);
        }
        List<String> rightNames = new List<String>();
        if (rightByContract.containsKey(cid)) for (Order_Form_Extraction__c r : rightByContract.get(cid)) rightNames.add(r.Opportunity__r.Name);
        System.debug(firstRow.Applied_Contract__r.ContractNumber + ' | ' + firstRow.Applied_Contract__r.Account.Name
            + ' | detach: ' + String.join(wrongNames, '; ')
            + ' | re-apply: ' + (rightNames.isEmpty() ? '(none - terms left blank until its own deal applies)' : String.join(rightNames, '; ')));
    }
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to rebuild.');
    return;
}

Integer done = 0;
Boolean outOfRoom = false;
List<String> failures = new List<String>();
for (Id cid : wrongByContract.keySet()) {
    if (done >= CAP) break;
    if (Limits.getQueries() > Limits.getLimitQueries() - 40
            || Limits.getDmlStatements() > Limits.getLimitDmlStatements() - 25
            || Limits.getCpuTime() > Limits.getLimitCpuTime() - 3000) break;
    List<Order_Form_Extraction__c> wrongRows = wrongByContract.get(cid);
    String label = wrongRows[0].Applied_Contract__r.ContractNumber + ' | ' + wrongRows[0].Applied_Contract__r.Account.Name;
    Savepoint sp = Database.setSavepoint();
    try {
        List<Order_Form_Extraction__c> detach = new List<Order_Form_Extraction__c>();
        List<String> wrongNames = new List<String>();
        for (Order_Form_Extraction__c r : wrongRows) {
            detach.add(new Order_Form_Extraction__c(Id = r.Id, Applied_Contract__c = null));
            wrongNames.add(r.Opportunity__r.Name);
        }
        update detach;
        update ContractLegalTermsApplier.clearedTerms(cid);

        // Own deals: fresh first, then amendments, each chronological.
        List<Order_Form_Extraction__c> ordered = new List<Order_Form_Extraction__c>();
        List<Order_Form_Extraction__c> amends = new List<Order_Form_Extraction__c>();
        if (rightByContract.containsKey(cid)) {
            for (Order_Form_Extraction__c r : rightByContract.get(cid)) {
                if (!APPLICABLE.contains(r.Extraction_Status__c)) continue;
                if (r.Opportunity__r.Type != null && AMEND.contains(r.Opportunity__r.Type)) amends.add(r);
                else ordered.add(r);
            }
        }
        ordered.addAll(amends);
        List<String> log = new List<String>{
            'Rebuilt 2026-10-16: removed terms applied here by mistake from [' + String.join(wrongNames, '; ')
            + '] and re-applied this contract\'s own deals in order.' };
        for (Order_Form_Extraction__c r : ordered) {
            if (Limits.getQueries() > Limits.getLimitQueries() - 20
                    || Limits.getDmlStatements() > Limits.getLimitDmlStatements() - 10
                    || Limits.getCpuTime() > Limits.getLimitCpuTime() - 1500) {
                outOfRoom = true;
                break;
            }
            ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
            req.extractionId = r.Id;
            ContractLegalTermsApplier.Result res = ContractLegalTermsApplier.apply(
                new List<ContractLegalTermsApplier.Request>{ req })[0];
            log.add('[' + r.Opportunity__r.Name + '] ' + res.status + (String.isBlank(res.notes) ? '' : '\n' + res.notes));
        }
        if (outOfRoom) {
            Database.rollback(sp);   // never leave a contract half rebuilt; it goes first next run
            break;
        }
        update new Contract(Id = cid, Reconciliation_Notes__c = String.join(log, '\n\n').left(32768));
        System.debug('rebuilt | ' + label + ' | detached ' + wrongRows.size() + ', re-applied ' + ordered.size());
    } catch (Exception e) {
        Database.rollback(sp);
        failures.add(label + ': ' + e.getMessage().left(300));
    }
    done++;
}
if (outOfRoom) System.debug('--- Stopped before a contract with many deals ran out of room this run; it is untouched.');
for (String f : failures) System.debug('FAILED ' + f);
System.debug('--- This run: ' + done + ' contract(s)' + (failures.isEmpty() ? '' : ', ' + failures.size() + ' failed and rolled back'));
System.debug('--- Remaining: ' + (wrongByContract.size() - done) + (wrongByContract.size() - done > 0 ? ' (re-run)' : ' - done'));
