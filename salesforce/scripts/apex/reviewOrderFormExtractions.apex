// =============================================================================
// Review saved order form extractions (shadow mode) - no re-read, no new lines
// =============================================================================
// The reviewer audits a saved extraction and its product lines against the
// deal's own files and records findings (Order Form Review / Review Findings
// related lists on the extraction). It never changes the extraction, its lines,
// the opportunity or the contract.
//
// - EXTRACTION_IDS: review just these (e.g. the Peel Hunt extraction).
//   Leave empty to start the sweep instead: current extractions from the last
//   Sweep Days (setting) without a current, up-to-date review.
// - FORCE = true reviews again even when the current review is up to date or
//   out of attempts.
// - RERUN_REVIEWED_IN_LAST_DAYS = N (e.g. 2): review again (forced) every
//   extraction whose current review was made in the last N days - to compare a
//   batch before and after a change. Needed after a change to Rogo's online
//   terms or the subprocessor list: those do not make a review out of date (they
//   are not part of its hashes, so a website edit does not re-review everything).
// - REVIEW_ALL_JOBS = N (e.g. 4): review EVERY current extraction (any date) in N
//   job chains running side by side. Extractions whose current review is up to
//   date are skipped without an API call, so it can be started again safely.
// - DRY_RUN = true (default) only reports the setting and what would be reviewed.
// - SCHEDULE_HOURLY = true also schedules the sweep every hour (once).
//
// Each review is one API call (about a minute) and costs roughly what the
// Estimated Cost (USD) field on the review shows.
//
// Run: sf apex run --target-org rogo --file scripts/apex/reviewOrderFormExtractions.apex
// =============================================================================

Boolean DRY_RUN = true;              // <-- false to start
Boolean FORCE = false;
Boolean SCHEDULE_HOURLY = false;
Integer RERUN_REVIEWED_IN_LAST_DAYS = 0;   // <-- e.g. 2 to redo the latest pilot
Integer REVIEW_ALL_JOBS = 0;               // <-- e.g. 4 to review every current extraction
List<Id> EXTRACTION_IDS = new List<Id>{
    // 'a1Gcv00000Fl9K9EAJ'
};

Order_Form_Review_Setting__mdt s = OrderFormReviewer.settings();
System.debug('--- Reviewer setting: Mode=' + s.Mode__c + ', Model=' + s.Model__c + ', Effort=' + s.Effort__c
    + ', Max Attempts=' + s.Max_Attempts__c + ', Sweep Days=' + s.Sweep_Days__c);
if (!OrderFormReviewer.isOn()) {
    System.debug('--- The reviewer is OFF. Setup > Custom Metadata Types > Order Form Review Setting > Manage Records > '
        + 'Default > Edit, set Mode to Shadow.');
    return;
}

Integer sweepDays = s.Sweep_Days__c == null ? 30 : s.Sweep_Days__c.intValue();
Integer targets = Database.countQuery('SELECT COUNT() FROM Order_Form_Extraction__c WHERE '
    + OrderFormReviewBatch.targetWhere(sweepDays));
System.debug('--- Current extractions in the sweep window: ' + targets);
for (AggregateResult ar : [
    SELECT Status__c st, COUNT(Id) n FROM Order_Form_Review__c WHERE Is_Current__c = true GROUP BY Status__c
]) {
    System.debug('   current reviews ' + ar.get('st') + ': ' + ar.get('n'));
}
System.debug('   stale current reviews: ' + [SELECT COUNT() FROM Order_Form_Review__c WHERE Is_Current__c = true AND Is_Stale__c = true]);

if (EXTRACTION_IDS.isEmpty() && RERUN_REVIEWED_IN_LAST_DAYS > 0) {
    Datetime since = Datetime.now().addDays(-RERUN_REVIEWED_IN_LAST_DAYS);
    for (Order_Form_Review__c r : [
        SELECT Extraction__c FROM Order_Form_Review__c
        WHERE Is_Current__c = true AND CreatedDate >= :since ORDER BY CreatedDate
    ]) {
        if (!EXTRACTION_IDS.contains(r.Extraction__c)) EXTRACTION_IDS.add(r.Extraction__c);
    }
    FORCE = true;
    System.debug('--- Re-review (forced): ' + EXTRACTION_IDS.size() + ' extraction(s) whose current review is from the '
        + 'last ' + RERUN_REVIEWED_IN_LAST_DAYS + ' day(s).');
}

List<List<Id>> chains = new List<List<Id>>();
if (EXTRACTION_IDS.isEmpty() && REVIEW_ALL_JOBS > 0) {
    List<Id> everyId = new List<Id>();
    for (Order_Form_Extraction__c r : [
        SELECT Id FROM Order_Form_Extraction__c
        WHERE Is_Current__c = true AND Extraction_Status__c IN ('Success', 'Incomplete', 'No Order Form')
        ORDER BY Opportunity__r.CloseDate DESC
    ]) {
        everyId.add(r.Id);
    }
    Integer jobs = Math.max(1, Math.min(REVIEW_ALL_JOBS, 10));
    for (Integer i = 0; i < jobs; i++) chains.add(new List<Id>());
    for (Integer i = 0; i < everyId.size(); i++) chains[Math.mod(i, jobs)].add(everyId[i]);
    System.debug('--- Review every current extraction: ' + everyId.size() + ' in ' + jobs + ' job chain(s) side by side '
        + '(about ' + Math.max(1, everyId.size() / jobs) + ' minute(s)); up-to-date ones are skipped without an API call.');
}

if (DRY_RUN) {
    System.debug('--- DRY RUN: nothing started. ' + (EXTRACTION_IDS.isEmpty()
        ? 'Set DRY_RUN = false to start the sweep (extractions already up to date are skipped without an API call).'
        : 'Set DRY_RUN = false to review ' + EXTRACTION_IDS.size() + ' extraction(s).'));
    return;
}
if (!chains.isEmpty()) {
    for (List<Id> chain : chains) if (!chain.isEmpty()) System.debug('--- ' + OrderFormReviewJob.enqueue(chain, FORCE));
} else if (!EXTRACTION_IDS.isEmpty()) {
    System.debug('--- ' + OrderFormReviewJob.enqueue(EXTRACTION_IDS, FORCE));
} else {
    Id jobId = Database.executeBatch(new OrderFormReviewBatch(), 1);
    System.debug('--- Sweep started: ' + jobId + ' (Setup > Apex Jobs).');
}
if (SCHEDULE_HOURLY) {
    String name = 'Order form review sweep';
    if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :name] == 0) {
        System.schedule(name, '0 15 * * * ?', new OrderFormReviewBatch());
        System.debug('--- Scheduled hourly (at :15).');
    } else {
        System.debug('--- Already scheduled.');
    }
}
