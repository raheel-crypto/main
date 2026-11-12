// =============================================================================
// Recover credit commitments the reads missed, and fix the credit rate
// =============================================================================
// Some reads missed the paper's "Credit Commitment: USD $46,000.00 per year"
// line, so the licence fee - the seats' price - was divided by the credits
// (Peel Hunt 0.03 instead of 0.02; DC Advisory renewal 0.055 instead of 0.0173).
// The extractor now recovers the commitment from the stated recurring total
// when that total quotes a credit line (total - licence - hosting).
//
// This applies the same rule to rows already extracted, WITHOUT re-reading:
// each candidate's stored Anthropic reply is run through the current Apex
// (OrderFormExtractionJob.buildFromResponseBody - no API call), and only
// Credit_Commit_Fee__c, Credit_Rate__c and Credits_Per_Year__c are copied
// back (with their evidence notes). Nothing else on the row changes. Then the
// accounts' contracts are rebuilt so the contract credit rate follows.
//
// Candidates: current new business / renewal / pilot rows with a credit rate
// but no commitment, whose ARR is above the licence + hosting fees.
// DRY_RUN = true (default) lists what would change. Then set DRY_RUN = false.
// If it stops near a limit, run it again - finished rows are no longer candidates.
//
// Run: sf apex run --target-org rogo --file scripts/apex/recoverCreditCommitments.apex
// =============================================================================

Boolean DRY_RUN = true;   // <-- false to write and rebuild the contracts

Set<String> AMEND = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };
List<Order_Form_Extraction__c> candidates = new List<Order_Form_Extraction__c>();
for (Order_Form_Extraction__c r : [
    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.AccountId, Type__c, Raw_Response__c,
           License_Fees__c, Platform_Connection_Fee__c, Annual_Recurring_Revenue__c,
           Credit_Commit_Fee__c, Credit_Rate__c, Credits_Per_Year__c, Derived_Fields__c, Extract_Evidence__c
    FROM Order_Form_Extraction__c
    WHERE Is_Current__c = true AND Credit_Commit_Fee__c = null AND Credit_Rate__c != null
      AND License_Fees__c != null AND Annual_Recurring_Revenue__c != null
      AND Opportunity__r.StageName = 'Closed Won'
]) {
    if (r.Type__c != null && AMEND.contains(r.Type__c)) continue;
    Decimal gap = r.Annual_Recurring_Revenue__c - r.License_Fees__c
        - (r.Platform_Connection_Fee__c == null ? 0 : r.Platform_Connection_Fee__c);
    if (gap > 1 && String.isNotBlank(r.Raw_Response__c)) candidates.add(r);
}
System.debug('--- Candidates: ' + candidates.size());

List<Order_Form_Extraction__c> updates = new List<Order_Form_Extraction__c>();
Set<Id> accounts = new Set<Id>();
Integer unchanged = 0;
for (Order_Form_Extraction__c r : candidates) {
    if (Limits.getQueries() > Limits.getLimitQueries() - 20) {
        System.debug('--- Stopped near the query limit; run again for the rest.');
        break;
    }
    Order_Form_Extraction__c fresh = OrderFormExtractionJob.buildFromResponseBody(r.Opportunity__c, new List<Id>(), r.Raw_Response__c);
    if (fresh.Credit_Commit_Fee__c == null) {
        unchanged++;
        System.debug('no commitment found | ' + r.Opportunity__r.Name);
        continue;
    }
    Order_Form_Extraction__c u = new Order_Form_Extraction__c(Id = r.Id, Credit_Commit_Fee__c = fresh.Credit_Commit_Fee__c,
        Credit_Rate__c = fresh.Credit_Rate__c, Credits_Per_Year__c = fresh.Credits_Per_Year__c);
    List<String> derived = String.isBlank(r.Derived_Fields__c) ? new List<String>() : r.Derived_Fields__c.split(';');
    for (String f : new List<String>{ 'Credit_Commit_Fee', 'Credit_Rate' }) if (!derived.contains(f)) derived.add(f);
    u.Derived_Fields__c = String.join(derived, ';').left(255);
    try {
        Map<String, Object> ev = String.isBlank(r.Extract_Evidence__c)
            ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(r.Extract_Evidence__c);
        Map<String, Object> freshEv = (Map<String, Object>) JSON.deserializeUntyped(fresh.Extract_Evidence__c);
        for (String k : new List<String>{ 'Credit_Commit_Fee', 'Credit_Rate', 'Credits_Per_Year' }) {
            if (freshEv.containsKey(k)) ev.put(k, freshEv.get(k));
        }
        u.Extract_Evidence__c = JSON.serialize(ev).left(32768);
    } catch (Exception e) {
        // Evidence that is not a JSON object is left as it is.
    }
    updates.add(u);
    if (r.Opportunity__r.AccountId != null) accounts.add(r.Opportunity__r.AccountId);
    System.debug(r.Opportunity__r.Name + ' | commitment ' + fresh.Credit_Commit_Fee__c + ' | rate ' + r.Credit_Rate__c
        + ' -> ' + fresh.Credit_Rate__c);
}
System.debug('--- To fix: ' + updates.size() + '; no commitment in the stored reply: ' + unchanged
    + '; accounts whose contracts get rebuilt: ' + accounts.size());
if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing written. Set DRY_RUN = false to write and rebuild.');
    return;
}
Integer ok = 0;
for (Database.SaveResult sr : Database.update(updates, false)) {
    if (sr.isSuccess()) ok++;
    else System.debug('FAILED ' + sr.getId() + ': ' + sr.getErrors()[0].getMessage());
}
Integer queued = 0;
for (Id acct : accounts) {
    if (queued >= Limits.getLimitQueueableJobs() - 1) {
        System.debug('--- Queue limit reached; rebuild the rest with the contract buttons.');
        break;
    }
    OrderFormOps.rebuildAccount(acct);
    queued++;
}
System.debug('--- Fixed ' + ok + ' of ' + updates.size() + ' extraction(s); rebuilding contracts on ' + queued
    + ' account(s) (Setup > Apex Jobs).');
