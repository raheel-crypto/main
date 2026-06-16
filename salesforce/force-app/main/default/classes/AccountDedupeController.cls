public with sharing class AccountDedupeController {

    @AuraEnabled(cacheable=false)
    public static AccountDedupeService.DedupeResult findDuplicates(Id recordId) {
        try {
            return AccountDedupeService.findDuplicates(recordId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AccountDedupeController.findDuplicates: '
                + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static AccountDedupeService.CompareData getCompareData(List<Id> accountIds) {
        try {
            return AccountDedupeService.getCompareData(accountIds);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AccountDedupeController.getCompareData: '
                + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void mergeAccounts(Id masterId, List<Id> duplicateIds, Map<String, Id> fieldSourceMap) {
        try {
            AccountDedupeService.mergeAccounts(masterId, duplicateIds, fieldSourceMap);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AccountDedupeController.mergeAccounts: '
                + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }
}
