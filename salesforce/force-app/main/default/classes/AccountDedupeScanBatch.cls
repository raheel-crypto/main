public with sharing class AccountDedupeScanBatch implements Database.Batchable<String>, Database.Stateful {

    private final Id scanId;
    private final List<String> scenarioKeys;
    private Integer totalGroups = 0;
    private Set<Id> uniqueAccounts = new Set<Id>();
    private String firstError;

    public AccountDedupeScanBatch(Id scanId, List<String> scenarioKeys) {
        this.scanId = scanId;
        this.scenarioKeys = scenarioKeys;
    }

    public Iterable<String> start(Database.BatchableContext bc) {
        return scenarioKeys;
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        for (String scenarioKey : scope) {
            try {
                List<AccountDedupeScanService.GroupDraft> drafts = AccountDedupeScanService.runScenario(scenarioKey);
                AccountDedupeScanService.persistGroups(scanId, drafts);
                totalGroups += drafts.size();
                for (AccountDedupeScanService.GroupDraft d : drafts) {
                    uniqueAccounts.addAll(d.accountIds);
                }
            } catch (Exception e) {
                if (firstError == null) {
                    firstError = '[' + scenarioKey + '] ' + e.getTypeName() + ': ' + e.getMessage();
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        Dedupe_Scan__c scan = new Dedupe_Scan__c(
            Id = scanId,
            Completed_At__c = System.now(),
            Group_Count__c = totalGroups,
            Account_Count__c = uniqueAccounts.size(),
            Status__c = firstError == null ? 'Completed' : 'Failed',
            Error_Message__c = firstError
        );
        update scan;
    }
}
