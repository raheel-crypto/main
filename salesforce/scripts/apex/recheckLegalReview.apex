// =============================================================================
// Re-check Contracts flagged Needs_Legal_Review after the applier fixes
// =============================================================================
// Two applier changes (2026-10-09) stop flagging review for things that are not
// legal conflicts: an amendment's Special Terms now accumulate under a label
// for the deal, and "Not specified" is silence. Contracts flagged before then
// may be flagged only for those reasons (54 of 131 on 2026-10-09).
//
// For each flagged Contract whose Reconciliation Notes show an applier
// CONFLICT, this clears the flag and re-applies the contract's amendments in
// deal order (the current extraction per deal). The applier sets the flag
// again for any genuine conflict. Fresh deals (New Business / Renewal) are NOT
// re-applied, so legal edits made by hand on the Contract are kept. Contracts
// flagged with no CONFLICT in their notes (possibly by hand) are left alone.
//
// Deploy the applier changes FIRST, or this re-flags the same contracts.
//
// DRY_RUN = true (default) lists what it would re-check. Resumable: each
// re-checked contract is marked in its notes and skipped next time; re-run
// until "Remaining: 0". Each run is all-or-nothing.
//
// Run: sf apex run --target-org rogo --file scripts/apex/recheckLegalReview.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to re-check
Integer CAP = 25;         // contracts per run (stops early near a governor limit)
String MARK = 'Review re-checked 2026-10-09';
Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

List<Contract> todo = new List<Contract>();
Integer flagged = 0;
for (Contract c : [
    SELECT Id, ContractNumber, Account.Name, Reconciliation_Notes__c
    FROM Contract WHERE Needs_Legal_Review__c = true ORDER BY ContractNumber
]) {
    flagged++;
    String n = (c.Reconciliation_Notes__c == null) ? '' : c.Reconciliation_Notes__c;
    if (n.contains('CONFLICT') && !n.contains(MARK)) todo.add(c);
}
System.debug('--- Flagged: ' + flagged + '; to re-check: ' + todo.size()
    + ' (the rest show no applier conflict, or were already re-checked)');
if (DRY_RUN) {
    for (Contract c : todo) System.debug(c.ContractNumber + ' | ' + c.Account.Name);
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to re-check.');
    return;
}

Integer done = 0;
Integer cleared = 0;
Integer stillFlagged = 0;
for (Contract c : todo) {
    if (done >= CAP) break;
    if (Limits.getQueries() > Limits.getLimitQueries() - 30
            || Limits.getDmlStatements() > Limits.getLimitDmlStatements() - 20
            || Limits.getCpuTime() > Limits.getLimitCpuTime() - 3000) break;

    List<Order_Form_Extraction__c> amendRows = [
        SELECT Id, Opportunity__r.Name
        FROM Order_Form_Extraction__c
        WHERE Applied_Contract__c = :c.Id AND Is_Current__c = true
          AND Extraction_Status__c IN ('Success', 'Incomplete')
          AND Opportunity__r.Type IN :AMEND
        ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
    ];
    update new Contract(Id = c.Id, Needs_Legal_Review__c = false);

    // Each apply rewrites the notes, so keep every amendment's log.
    List<String> log = new List<String>();
    for (Order_Form_Extraction__c o : amendRows) {
        ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
        req.extractionId = o.Id;
        ContractLegalTermsApplier.Result res = ContractLegalTermsApplier.apply(
            new List<ContractLegalTermsApplier.Request>{ req })[0];
        log.add('[' + o.Opportunity__r.Name + '] ' + res.status
            + (String.isBlank(res.notes) ? '' : '\n' + res.notes));
    }

    Contract after = [SELECT Needs_Legal_Review__c FROM Contract WHERE Id = :c.Id];
    log.add(MARK + (after.Needs_Legal_Review__c ? ': genuine conflict remains.' : ': no conflict remains.'));
    update new Contract(Id = c.Id, Reconciliation_Notes__c = String.join(log, '\n\n').right(32768));

    if (after.Needs_Legal_Review__c) stillFlagged++;
    else cleared++;
    System.debug((after.Needs_Legal_Review__c ? 'STILL FLAGGED' : 'cleared') + ' | ' + c.ContractNumber
        + ' | ' + c.Account.Name + ' | ' + amendRows.size() + ' amendment(s) re-applied');
    done++;
}

System.debug('--- This run: ' + done + ' re-checked, ' + cleared + ' cleared, ' + stillFlagged + ' still flagged.');
System.debug('--- Remaining: ' + (todo.size() - done) + (todo.size() - done > 0 ? ' (re-run)' : ' - done'));
