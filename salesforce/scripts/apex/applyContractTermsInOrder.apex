// =============================================================================
// Apply Contract legal terms in the proper order (New Business -> upsells)
// =============================================================================
// (Also writes the usage + product fields - tier, free tiers, overage rate,
// Credits Per Year, blended Credit Rate, Pricing Structure - via
// ContractUsageRollup. For contracts applied before those fields existed, run
// backfillContractUsage.apex afterwards.)
//
// Applies ContractLegalTermsApplier to every CURRENT (Is_Current__c) readable
// extraction (Success, Incomplete, or No Order Form - the last two contribute
// legal terms only and never move the contract pointer) that hasn't been applied yet (Applied_Contract__c = null) - one per
// opportunity, so superseded versions are never applied - in the correct order so a contract's
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
// Governor-safe: capped at CAP apply() calls per run, and stops early if the
// transaction nears its query / DML / CPU limits. A row that errors is rolled
// back on its own (savepoint), reported, and skipped - the rest still apply.
// Resumable - applied OFEs get stamped Applied_Contract__c, so re-run until
// "Remaining" is 0.
//
// Deals with NO Contract to land on are listed, not attempted: a fresh deal
// (new business / renewal / pilot) with no contract of its own, or an
// amendment with none on its opp, its base opp or the account. The applier
// would answer NoContract every time and they would block the queue. They apply on a later run once a Contract exists. New Success rows are
// also applied automatically by the "Order Form Extraction [Async] Update Slack
// CW Notice to RevOps" flow; this script catches everything else.
//
// Run: sf apex run --target-org rogo --file scripts/apex/applyContractTermsInOrder.apex
// (or paste into Dev Console -> Execute Anonymous)
// =============================================================================

Integer CAP = 25;   // apply() calls per run; re-run until nothing remains

Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };
String UNAPPLIED_FILTER = 'Extraction_Status__c IN (\'Success\', \'Incomplete\', \'No Order Form\') '
    + 'AND Is_Current__c = true AND Applied_Contract__c = null AND Opportunity__c != null';
String UNAPPLIED_SOQL = 'SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.CloseDate, '
    + 'Opportunity__r.AccountId, Opportunity__r.ContractId, Opportunity__r.Base_Opportunity__r.ContractId '
    + 'FROM Order_Form_Extraction__c WHERE ' + UNAPPLIED_FILTER
    + ' ORDER BY Opportunity__r.CloseDate ASC NULLS LAST';

// Unapplied current extractions, chronological.
List<Order_Form_Extraction__c> unapplied = Database.query(UNAPPLIED_SOQL);

// Accounts that have at least one Contract (the applier's fallback target).
Set<Id> acctIds = new Set<Id>();
for (Order_Form_Extraction__c o : unapplied) if (o.Opportunity__r.AccountId != null) acctIds.add(o.Opportunity__r.AccountId);
Set<Id> acctsWithContract = new Set<Id>();
for (AggregateResult ar : [SELECT AccountId a FROM Contract WHERE AccountId IN :acctIds GROUP BY AccountId]) {
    acctsWithContract.add((Id) ar.get('a'));
}

// A fresh deal (new business / renewal / pilot) applies only to its own
// contract: the opp's ContractId or a contract recording the opp as its source.
Set<Id> freshOppIds = new Set<Id>();
for (Order_Form_Extraction__c o : unapplied) {
    if (o.Opportunity__r.ContractId == null && (o.Opportunity__r.Type == null || !AMEND.contains(o.Opportunity__r.Type))) {
        freshOppIds.add(o.Opportunity__c);
    }
}
Set<String> freshIdText = new Set<String>();
for (Id oid : freshOppIds) { freshIdText.add(String.valueOf(oid)); freshIdText.add(String.valueOf(oid).left(15)); }
Set<Id> oppsWithSourcedContract = new Set<Id>();
for (Contract c : [
    SELECT Opportunity__c, Source_Opportunity_Id__c FROM Contract
    WHERE Opportunity__c IN :freshOppIds OR Source_Opportunity_Id__c IN :freshIdText
]) {
    if (c.Opportunity__c != null) oppsWithSourcedContract.add(c.Opportunity__c);
    try { if (String.isNotBlank(c.Source_Opportunity_Id__c)) oppsWithSourcedContract.add(Id.valueOf(c.Source_Opportunity_Id__c)); }
    catch (Exception e) { }
}

// Partition: no contract to land on (reported) / fresh-contract deals / amendments.
List<Order_Form_Extraction__c> ordered = new List<Order_Form_Extraction__c>();
List<Order_Form_Extraction__c> amends = new List<Order_Form_Extraction__c>();
List<String> noContract = new List<String>();
for (Order_Form_Extraction__c o : unapplied) {
    Opportunity opp = o.Opportunity__r;
    if (!hasTarget(opp, o.Opportunity__c, AMEND, acctsWithContract, oppsWithSourcedContract)) {
        noContract.add(opp.Name + ' [' + opp.Type + ']');
        continue;
    }
    if (opp.Type != null && AMEND.contains(opp.Type)) amends.add(o);
    else ordered.add(o);   // New Business / Renewal / Pilot / (untyped) first
}
ordered.addAll(amends);

System.debug('--- Unapplied current extractions: ' + unapplied.size() + ' = ' + ordered.size()
    + ' with a Contract to land on (fresh: ' + (ordered.size() - amends.size()) + ', amendments: ' + amends.size()
    + ') + ' + noContract.size() + ' with no Contract anywhere (not attempted)');

// Apply in order, one call each so each reconciles against prior committed state.
Integer done = 0;
Integer failed = 0;
Boolean stoppedEarly = false;
Map<String, Integer> statusCounts = new Map<String, Integer>();
List<String> notable = new List<String>();
for (Order_Form_Extraction__c o : ordered) {
    if (done >= CAP) break;
    if (Limits.getQueries() > Limits.getLimitQueries() - 15
            || Limits.getDmlStatements() > Limits.getLimitDmlStatements() - 15
            || Limits.getCpuTime() > Limits.getLimitCpuTime() - 2000) {
        stoppedEarly = true;
        break;
    }
    String name = (o.Opportunity__r != null ? o.Opportunity__r.Name : o.Id) + ' ['
        + (o.Opportunity__r != null ? o.Opportunity__r.Type : '?') + ']';
    ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
    req.extractionId = o.Id;
    Savepoint sp = Database.setSavepoint();
    ContractLegalTermsApplier.Result res;
    try {
        res = ContractLegalTermsApplier.apply(new List<ContractLegalTermsApplier.Request>{ req })[0];
    } catch (Exception e) {
        Database.rollback(sp);
        failed++;
        notable.add('ERROR ' + name + ' -> ' + e.getTypeName() + ': ' + e.getMessage().left(300));
        done++;
        continue;
    }

    Integer c = statusCounts.containsKey(res.status) ? statusCounts.get(res.status) : 0;
    statusCounts.put(res.status, c + 1);
    // Surface anything that isn't a clean apply so gaps/conflicts are visible.
    if (res.status != 'Applied') {
        notable.add(name + ' -> ' + res.status + (String.isBlank(res.notes) ? '' : ' | ' + res.notes.left(200)));
    }
    done++;
}

System.debug('--- Attempted this run: ' + done + (failed > 0 ? ' (' + failed + ' errored and were rolled back)' : '')
    + (stoppedEarly ? ' - stopped early near a governor limit' : ''));
System.debug('--- Status counts: ' + statusCounts);
for (String n : notable) System.debug('NOTE: ' + n);

Integer remaining = 0;
for (Order_Form_Extraction__c o : Database.query(UNAPPLIED_SOQL)) {
    if (hasTarget(o.Opportunity__r, o.Opportunity__c, AMEND, acctsWithContract, oppsWithSourcedContract)) remaining++;
}
System.debug('--- Remaining to apply: ' + remaining + (remaining > 0 ? ' (re-run)' : ' - done'));
if (!noContract.isEmpty()) {
    System.debug('--- No Contract to land on (' + noContract.size() + '; a fresh deal needs its own): '
        + String.join(noContract, '; ').left(3000));
}

// Own contract (or a contract recording the opp) for any deal; the base deal's
// or, for an amendment only, any of the account's contracts.
Boolean hasTarget(Opportunity opp, Id oppId, Set<String> amend, Set<Id> acctsWithContract, Set<Id> sourced) {
    if (opp.ContractId != null || sourced.contains(oppId)) return true;
    Boolean isAmend = opp.Type != null && amend.contains(opp.Type);
    if (!isAmend) return false;
    return (opp.Base_Opportunity__r != null && opp.Base_Opportunity__r.ContractId != null)
        || acctsWithContract.contains(opp.AccountId);
}
