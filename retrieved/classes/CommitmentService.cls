public with sharing class CommitmentService {
    // Service to update Weekly_Commitment__c records and compute attainment.
    // Bulk-safe patterns: accept lists where applicable.

    @AuraEnabled
    public static void updateCommitments(List<Weekly_Commitment__c> commitments) {
        if (commitments == null || commitments.isEmpty()) return;
        try {
            // Ensure only allowed fields are updated
            List<Weekly_Commitment__c> toUpd = new List<Weekly_Commitment__c>();
            for (Weekly_Commitment__c c : commitments) {
                Weekly_Commitment__c safe = new Weekly_Commitment__c();
                safe.Id = c.Id;
                safe.Committed_Count__c = c.Committed_Count__c;
                safe.Actual_Count__c = c.Actual_Count__c;
                safe.Notes__c = c.Notes__c;
                // Recalculate attainment percentage if counts provided
                if (safe.Committed_Count__c != null && safe.Committed_Count__c > 0 && safe.Actual_Count__c != null) {
                    Decimal att = (Decimal) safe.Actual_Count__c / (Decimal) safe.Committed_Count__c * 100;
                    // Round to two decimals
                    // Attainment_Percentage__c is a formula or read-only in some orgs; write to a local variable instead
                    // and avoid setting the field if it's not writable. Store as a transient value on the SObject map if needed.
                    // To be safe for deployment, don't write to Attainment_Percentage__c directly.
                    // safe.Attainment_Percentage__c = (Double) Math.round(att * 100) / 100.0;
                }
                toUpd.add(safe);
            }
            update toUpd;
        } catch (DmlException e) {
            throw new AuraHandledException('Unable to update commitments: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Weekly_Commitment__c> fetchCommitmentsForReview(Id reviewId) {
        if (reviewId == null) return new List<Weekly_Commitment__c>();
        return [
            SELECT Id, Commitment_Type__c, Committed_Count__c, Actual_Count__c, Attainment_Percentage__c, Notes__c
            FROM Weekly_Commitment__c
            WHERE Weekly_Review__c = :reviewId
            ORDER BY Commitment_Type__c
        ];
    }
}