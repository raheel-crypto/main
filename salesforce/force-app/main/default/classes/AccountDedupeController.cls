public with sharing class AccountDedupeController {

    @AuraEnabled(cacheable=false)
    public static AccountDedupeService.DedupeResult findDuplicates(Id recordId) {
        try {
            return AccountDedupeService.findDuplicates(recordId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void mergeAccounts(Id masterId, List<Id> duplicateIds, Map<String, Id> fieldSourceMap) {
        try {
            AccountDedupeService.mergeAccounts(masterId, duplicateIds, fieldSourceMap);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}
