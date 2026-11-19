// =============================================================================
// Nightly contract refresh: schedule, check or stop it
// =============================================================================
// Deals are extracted when they close, but their contracts are usually created
// hours later, so the extraction was never applied to them. The nightly
// refresh (ContractRefreshScheduler -> ContractRefresh) finds the accounts
// whose contracts are behind their deals' current extractions and rebuilds
// them, one account per background job - the same as the Contract "Rebuild
// Order Form Terms" button. ARR, seats and fees are never touched; a deal whose
// contract does not exist yet waits until it does.
//
// ACTION
//   'STATUS'     (default) - is it scheduled, when it runs next, and what a run
//                 would pick right now. Changes nothing.
//   'SCHEDULE'   - schedule it nightly at RUN_AT (your Salesforce time zone).
//   'UNSCHEDULE' - stop it.
//   'RUN_NOW'    - run it once now (the same as tonight's run).
//
// Run: sf apex run --target-org rogo --file scripts/apex/scheduleContractRefresh.apex
// =============================================================================

String ACTION = 'STATUS';           // <-- 'STATUS', 'SCHEDULE', 'UNSCHEDULE' or 'RUN_NOW'
Integer RUN_AT_HOUR = 2;            // 2:17 am, after the day's contracts are created
Integer RUN_AT_MINUTE = 17;

String NAME = 'Order form contract refresh (nightly)';
List<CronTrigger> jobs = [
    SELECT Id, State, NextFireTime, PreviousFireTime, CronExpression FROM CronTrigger
    WHERE CronJobDetail.Name = :NAME
];

if (ACTION == 'SCHEDULE') {
    if (!jobs.isEmpty()) {
        System.debug('--- Already scheduled (' + jobs[0].CronExpression + '), next run ' + jobs[0].NextFireTime
            + '. To change the time, UNSCHEDULE first.');
        return;
    }
    String cron = '0 ' + RUN_AT_MINUTE + ' ' + RUN_AT_HOUR + ' * * ?';
    Id jobId = System.schedule(NAME, cron, new ContractRefreshScheduler());
    CronTrigger ct = [SELECT NextFireTime FROM CronTrigger WHERE Id = :jobId];
    System.debug('--- Scheduled nightly (' + cron + '). First run: ' + ct.NextFireTime + '.');
    return;
}
if (ACTION == 'UNSCHEDULE') {
    for (CronTrigger ct : jobs) System.abortJob(ct.Id);
    System.debug('--- ' + (jobs.isEmpty() ? 'It was not scheduled.' : 'Stopped.'));
    return;
}
if (ACTION == 'RUN_NOW') {
    System.debug('--- ' + ContractRefresh.run() + ' Progress: Setup > Apex Jobs, ContractRebuildSweep.');
    return;
}

// STATUS
if (jobs.isEmpty()) {
    System.debug('--- Not scheduled. Set ACTION = \'SCHEDULE\' to run it nightly.');
} else {
    System.debug('--- Scheduled: ' + jobs[0].State + ', ' + jobs[0].CronExpression + '. Last run: '
        + jobs[0].PreviousFireTime + '. Next run: ' + jobs[0].NextFireTime + '.');
}
if (ContractRefresh.sweepRunning()) System.debug('--- A rebuild sweep is running right now.');
ContractRefresh.Selection sel = ContractRefresh.stale();
Map<String, Integer> counts = new Map<String, Integer>();
for (Set<String> rs : sel.reasons.values()) {
    for (String r : rs) counts.put(r, (counts.containsKey(r) ? counts.get(r) : 0) + 1);
}
System.debug('--- A run now would rebuild ' + sel.reasons.size() + ' account(s).');
for (String r : counts.keySet()) System.debug('   ' + counts.get(r) + ' account(s): ' + r);
System.debug('   ' + sel.waitingForContract + ' current extraction(s) wait for their contract to be created.');
List<String> names = new List<String>();
for (Account a : [SELECT Name FROM Account WHERE Id IN :sel.reasons.keySet() ORDER BY Name LIMIT 30]) names.add(a.Name);
if (!names.isEmpty()) System.debug('   ' + String.join(names, ', ') + (sel.reasons.size() > 30 ? ', ...' : ''));
