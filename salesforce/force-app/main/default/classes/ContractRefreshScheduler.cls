/**
 * Nightly: rebuilds the contracts that fell behind their deals' extractions
 * (ContractRefresh.run). ContractRefresh is looked up by name, so it and the
 * classes it uses stay deployable while this job is scheduled - Salesforce
 * blocks deploying a scheduled class and the classes it references.
 *
 * Schedule, check or stop it: scripts/apex/scheduleContractRefresh.apex.
 */
public with sharing class ContractRefreshScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        Type worker = Type.forName('ContractRefresh');
        if (worker == null) return;
        Object message = ((Callable) worker.newInstance()).call('run', new Map<String, Object>());
        System.debug(LoggingLevel.INFO, 'Contract refresh: ' + message);
    }
}
