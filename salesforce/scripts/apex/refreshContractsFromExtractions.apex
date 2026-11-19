// =============================================================================
// Refresh contracts from their deals' latest extractions (mass rebuild)
// =============================================================================
// The Contract "Rebuild Order Form Terms" button, for many accounts at once.
// For each account, the contract terms the applier manages are blanked (legal
// terms, special terms, model changes, usage and credit fields, the legal
// review flag - contacts and billing details are kept) and filled again from
// the deals' CURRENT extractions: new business / renewal / pilot first, then
// amendments, each oldest first. Conflicts between deals are flagged for legal
// review again. No files are re-read. ARR, seats and fees are not touched (the
// Quote Bot owns them). A hand edit to one of the managed fields on a contract
// is replaced by the extracted value.
//
// MODE
//   'STALE' (default): only accounts whose contracts are behind their deals,
//      as the nightly refresh picks them (ContractRefresh) - a current
//      extraction that is on no contract although its contract now exists
//      (new, or re-read since the last apply; a deal whose contract is not
//      created yet waits), a contract that still points at a superseded extraction,
//      or a superseded extraction left on a contract its deal has since moved
//      off (its credits still count there). An old version sitting beside its
//      deal's current one on the same contract is harmless (the applier counts
//      each deal once) and is not a reason on its own.
//   'ALL': every account that has a contract and a current extraction.
// ONLY_ACCOUNTS: just these accounts (name starts with, or an Account Id).
// SKIP_REBUILT_TODAY = true skips accounts whose contracts were all rebuilt
//   today, so after a stop you can simply run it again.
// DRY_RUN = true (default) only reports what it would do. Then set it to false.
//
// It works one account per background job (a few seconds each): Setup > Apex
// Jobs, "ContractRebuildSweep". Afterwards, a dry run in STALE mode should find
// (almost) nothing; whatever is left could not be applied - look at those.
//
// Run: sf apex run --target-org rogo --file scripts/apex/refreshContractsFromExtractions.apex
// =============================================================================

String MODE = 'STALE';              // <-- 'STALE' or 'ALL'
Boolean DRY_RUN = true;             // <-- false to start
Boolean SKIP_REBUILT_TODAY = true;
List<String> ONLY_ACCOUNTS = new List<String>{
    // 'Peel Hunt', '001...'
};

Set<String> APPLICABLE = new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };
String R_ALL = 'ALL mode';

Map<Id, Set<String>> reasons = new Map<Id, Set<String>>();
Map<String, Integer> reasonCounts = new Map<String, Integer>();

if (MODE == 'ALL') {
    for (Order_Form_Extraction__c r : [
        SELECT Opportunity__r.AccountId FROM Order_Form_Extraction__c
        WHERE Is_Current__c = true AND Extraction_Status__c IN :APPLICABLE AND Opportunity__r.AccountId != null
    ]) {
        Id a = r.Opportunity__r.AccountId;
        if (!reasons.containsKey(a)) reasons.put(a, new Set<String>());
        reasons.get(a).add(R_ALL);
    }
} else {
    // The same selection the nightly refresh uses (ContractRefresh).
    ContractRefresh.Selection sel = ContractRefresh.stale();
    reasons = sel.reasons;
    System.debug('--- ' + sel.harmless + ' superseded extraction(s) sit beside their deal\'s current one on the same '
        + 'contract: harmless, not a reason on their own (cleaned up when the account is rebuilt anyway).');
    System.debug('--- ' + sel.waitingForContract + ' current extraction(s) wait for their contract to be created '
        + '(left until it exists).');
}

// Only these accounts.
if (!ONLY_ACCOUNTS.isEmpty()) {
    Set<Id> only = new Set<Id>();
    List<String> patterns = new List<String>();
    for (String s : ONLY_ACCOUNTS) {
        if (s.startsWith('001') && (s.length() == 15 || s.length() == 18)) only.add(Id.valueOf(s));
        else patterns.add(s + '%');
    }
    if (!patterns.isEmpty()) for (Account a : [SELECT Id FROM Account WHERE Name LIKE :patterns]) only.add(a.Id);
    for (Id a : new List<Id>(reasons.keySet())) if (!only.contains(a)) reasons.remove(a);
}

// Only accounts that have a contract to apply to; and (optionally) not rebuilt today.
Map<Id, List<Contract>> contractsByAccount = new Map<Id, List<Contract>>();
for (Contract c : [SELECT Id, AccountId, ContractNumber, Reconciliation_Notes__c FROM Contract WHERE AccountId IN :reasons.keySet()]) {
    if (!contractsByAccount.containsKey(c.AccountId)) contractsByAccount.put(c.AccountId, new List<Contract>());
    contractsByAccount.get(c.AccountId).add(c);
}
Integer noContract = 0;
Integer rebuiltToday = 0;
String todayHeader = 'Rebuilt ' + String.valueOf(Date.today());
for (Id a : new List<Id>(reasons.keySet())) {
    List<Contract> cs = contractsByAccount.get(a);
    if (cs == null || cs.isEmpty()) {
        reasons.remove(a);
        noContract++;
        continue;
    }
    if (SKIP_REBUILT_TODAY) {
        Boolean allToday = true;
        for (Contract c : cs) {
            if (c.Reconciliation_Notes__c == null || !c.Reconciliation_Notes__c.startsWith(todayHeader)) allToday = false;
        }
        if (allToday) {
            reasons.remove(a);
            rebuiltToday++;
        }
    }
}

List<Id> targets = new List<Id>();
Integer contractCount = 0;
List<String> sample = new List<String>();
for (Account a : [SELECT Id, Name FROM Account WHERE Id IN :reasons.keySet() ORDER BY Name]) {
    targets.add(a.Id);
    contractCount += contractsByAccount.get(a.Id).size();
    for (String r : reasons.get(a.Id)) reasonCounts.put(r, (reasonCounts.containsKey(r) ? reasonCounts.get(r) : 0) + 1);
    if (sample.size() < 40) {
        sample.add('   ' + a.Name + ' (' + contractsByAccount.get(a.Id).size() + ' contract(s)): '
            + String.join(new List<String>(reasons.get(a.Id)), '; '));
    }
}

System.debug('--- Mode ' + MODE + ': ' + targets.size() + ' account(s), ' + contractCount + ' contract(s) to rebuild.');
for (String r : reasonCounts.keySet()) System.debug('   ' + reasonCounts.get(r) + ' account(s): ' + r);
if (noContract > 0) System.debug('   (' + noContract + ' account(s) left out: no contract to apply to)');
if (rebuiltToday > 0) System.debug('   (' + rebuiltToday + ' account(s) left out: already rebuilt today)');
System.debug('--- First ' + sample.size() + ':');
for (String s : sample) System.debug(s);

if (targets.isEmpty()) {
    System.debug('--- Nothing to do.');
    return;
}
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing changed. Set DRY_RUN = false to rebuild these ' + targets.size()
        + ' account(s), one per background job (about ' + Math.max(1, targets.size() * 10 / 60) + ' minute(s)).');
    return;
}
Id jobId = System.enqueueJob(new ContractRebuildSweep(targets));
System.debug('--- Started: ' + targets.size() + ' account(s), one per job (first job ' + jobId
    + '). Progress: Setup > Apex Jobs, ContractRebuildSweep.');
