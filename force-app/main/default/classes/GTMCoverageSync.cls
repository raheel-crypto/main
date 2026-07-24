public with sharing class GTMCoverageSync {
    public static void sync(List<Id> toActivate, List<Id> toDeactivate, Id repId, String coverageType) {
        try {
            if ((toActivate == null || toActivate.isEmpty()) &&
                (toDeactivate == null || toDeactivate.isEmpty())) return;

            Set<Id> allAccountIds = new Set<Id>();
            if (toActivate   != null) allAccountIds.addAll(toActivate);
            if (toDeactivate != null) allAccountIds.addAll(toDeactivate);

            Map<Id, GTM_Coverage__c> existingByAccount = new Map<Id, GTM_Coverage__c>();
            for (GTM_Coverage__c cov : [
                SELECT Id, Account__c, Is_Active__c
                FROM GTM_Coverage__c
                WHERE Rep__c = :repId
                  AND Account__c IN :allAccountIds
                  AND Coverage_Type__c = :coverageType
            ]) {
                existingByAccount.put(cov.Account__c, cov);
            }

            Date today = Date.today();
            List<GTM_Coverage__c> toInsert = new List<GTM_Coverage__c>();
            List<GTM_Coverage__c> toUpdate = new List<GTM_Coverage__c>();

            for (Id acctId : (toActivate != null ? toActivate : new List<Id>())) {
                GTM_Coverage__c existing = existingByAccount.get(acctId);
                if (existing != null) {
                    if (!existing.Is_Active__c) {
                        existing.Is_Active__c = true;
                        existing.Date_Added__c = today;
                        existing.Date_Removed__c = null;
                        toUpdate.add(existing);
                    }
                } else {
                    toInsert.add(new GTM_Coverage__c(
                        Account__c      = acctId,
                        Rep__c          = repId,
                        Coverage_Type__c = coverageType,
                        Is_Active__c    = true,
                        Date_Added__c   = today
                    ));
                }
            }

            for (Id acctId : (toDeactivate != null ? toDeactivate : new List<Id>())) {
                GTM_Coverage__c existing = existingByAccount.get(acctId);
                if (existing != null && existing.Is_Active__c) {
                    existing.Is_Active__c = false;
                    existing.Date_Removed__c = today;
                    toUpdate.add(existing);
                }
            }

            if (!toInsert.isEmpty()) insert toInsert;
            if (!toUpdate.isEmpty()) update toUpdate;
        } catch (Exception e) {
            // Silent — checkboxes remain source of truth; junction write is best-effort
        }
    }
}
