/**
 * Background drainer for queued Account merges.
 *
 * Pulls the oldest Dedupe_Group__c records with Status__c='Queued', marks
 * each Processing, computes the "MasterWinsFillNulls" field source map
 * (master keeps its values; null fields on master get filled from the
 * first duplicate that has a value), revalidates that no critical
 * record-type collision has appeared since queueing, and calls the
 * existing AccountDedupeService.mergeAccounts for the merge.
 *
 * Re-enqueues itself when more groups remain Queued so a single user
 * action can drain an arbitrarily long queue without hitting per-
 * transaction limits.
 */
public with sharing class AccountMergeQueueDrainer implements Queueable {

    private static final Integer MAX_PER_RUN = 5;

    public void execute(QueueableContext qc) {
        List<Dedupe_Group__c> batch = [
            SELECT Id, Master_Account__c, Queued_At__c, Match_Key__c
            FROM Dedupe_Group__c
            WHERE Status__c = 'Queued'
            ORDER BY Queued_At__c ASC NULLS LAST
            LIMIT :MAX_PER_RUN
        ];
        if (batch.isEmpty()) return;

        // Flip to Processing up front so a parallel chain won't re-pick.
        for (Dedupe_Group__c g : batch) g.Status__c = 'Processing';
        update batch;

        for (Dedupe_Group__c g : batch) {
            processOne(g.Id, g.Master_Account__c);
        }

        // Chain if more remain.
        Integer remaining = [SELECT COUNT() FROM Dedupe_Group__c WHERE Status__c = 'Queued'];
        if (remaining > 0 && !Test.isRunningTest()) {
            System.enqueueJob(new AccountMergeQueueDrainer());
        }
    }

    private void processOne(Id groupId, Id masterId) {
        if (masterId == null) {
            markFailed(groupId, 'No master account selected.');
            return;
        }

        // Re-fetch members so we know the duplicate IDs to merge.
        List<Id> dupeIds = new List<Id>();
        Set<Id> allIds = new Set<Id>();
        for (Dedupe_Group_Member__c m : [
            SELECT Account__c FROM Dedupe_Group_Member__c WHERE Group__c = :groupId
        ]) {
            if (m.Account__c == null) continue;
            allIds.add(m.Account__c);
            if (m.Account__c != masterId) dupeIds.add(m.Account__c);
        }
        if (!allIds.contains(masterId)) {
            markFailed(groupId, 'Master account is no longer in the group.');
            return;
        }
        if (dupeIds.isEmpty()) {
            markFailed(groupId, 'No duplicates to merge.');
            return;
        }

        // Revalidate collision risk in case data changed since queueing.
        String collisionReason = detectCollision(masterId, dupeIds);
        if (collisionReason != null) {
            update new Dedupe_Group__c(
                Id = groupId,
                Status__c = 'NeedsReview',
                Error_Message__c = collisionReason
            );
            return;
        }

        // Bail if more than one customer-status account is in the group —
        // that's a merge collision that needs human eyes. Exactly one
        // customer (with everything else a prospect) is fine: the queue
        // workflow specifically suggests the customer as the master and
        // absorbs the prospects into it.
        String customerReason = detectCustomerCollision(masterId, allIds);
        if (customerReason != null) {
            update new Dedupe_Group__c(
                Id = groupId,
                Status__c = 'NeedsReview',
                Error_Message__c = customerReason
            );
            return;
        }

        try {
            Map<String, Id> fieldSourceMap = buildFillNullSources(masterId, allIds);

            // Merge one dupe at a time, cleaning up ACR conflicts before each
            // merge. Batching multiple dupes into a single merge() call causes
            // Salesforce to check ALL pairs (master-dupe AND dupe-dupe), and
            // contacts that moved to master from a prior dupe can re-trigger
            // conflicts with subsequent dupes. Sequential single merges avoid this.
            for (Id dupeId : dupeIds) {
                AccountDedupeScanController.cleanupAcrConflicts(groupId, masterId);
                AccountDedupeService.mergeAccounts(masterId, new List<Id>{ dupeId }, fieldSourceMap);
            }
            // mergeAccounts auto-marks the group Resolved via
            // AccountDedupeScanService.resolveGroups, so no extra DML here.
        } catch (Exception e) {
            markFailed(groupId, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    private String detectCustomerCollision(Id masterId, Set<Id> accountIds) {
        Integer customerCount = 0;
        Boolean masterIsCustomer = false;
        for (Account a : [
            SELECT Id, Account_Status__c FROM Account WHERE Id IN :accountIds
        ]) {
            if (a.Account_Status__c != null && a.Account_Status__c.equalsIgnoreCase('Customer')) {
                customerCount += 1;
                if (a.Id == masterId) masterIsCustomer = true;
            }
        }
        if (customerCount >= 2) {
            return 'Two or more Customer-status accounts in this group — needs manual review.';
        }
        if (customerCount == 1 && !masterIsCustomer) {
            // The single customer would be merged AWAY into a non-customer master.
            return 'The single Customer in this group is not the picked master — pick the Customer as master or review manually.';
        }
        return null;
    }

    private void markFailed(Id groupId, String reason) {
        update new Dedupe_Group__c(
            Id = groupId,
            Status__c = 'Failed',
            Error_Message__c = reason == null ? null : reason.left(32000)
        );
    }

    /**
     * Returns a description of the colliding record type(s) if both master
     * and any duplicate have open opps / renewal opps / active contracts;
     * null when the merge is safe to proceed.
     */
    private String detectCollision(Id masterId, List<Id> dupeIds) {
        Set<Id> dupeSet = new Set<Id>(dupeIds);
        Set<Id> allIds = new Set<Id>(dupeSet);
        allIds.add(masterId);

        Map<Id, Integer> openOpps = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :allIds AND IsClosed = false
            GROUP BY AccountId
        ]);
        Map<Id, Integer> renewals = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :allIds AND IsClosed = false AND Type = 'Renewal'
            GROUP BY AccountId
        ]);
        Map<Id, Integer> contracts = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Contract
            WHERE AccountId IN :allIds AND Status = 'Activated'
            GROUP BY AccountId
        ]);

        List<String> reasons = new List<String>();
        if (zero(openOpps.get(masterId)) > 0) {
            for (Id d : dupeSet) {
                if (zero(openOpps.get(d)) > 0) { reasons.add('open opps'); break; }
            }
        }
        if (zero(renewals.get(masterId)) > 0) {
            for (Id d : dupeSet) {
                if (zero(renewals.get(d)) > 0) { reasons.add('renewal opps'); break; }
            }
        }
        if (zero(contracts.get(masterId)) > 0) {
            for (Id d : dupeSet) {
                if (zero(contracts.get(d)) > 0) { reasons.add('active contracts'); break; }
            }
        }
        if (reasons.isEmpty()) return null;
        return 'Collision detected: both master and a duplicate have ' + String.join(reasons, ', ') + '.';
    }

    private static Map<Id, Integer> countByAccount(List<AggregateResult> rows) {
        Map<Id, Integer> out = new Map<Id, Integer>();
        for (AggregateResult ar : rows) {
            out.put((Id) ar.get('acc'), ((Decimal) ar.get('cnt')).intValue());
        }
        return out;
    }

    private static Integer zero(Integer n) { return n == null ? 0 : n; }

    /**
     * MasterWinsFillNulls policy:
     *   - If master already has a value for a field → no override (master keeps it).
     *   - If master is null and any duplicate has a non-null value → take the first
     *     duplicate's value (override).
     */
    private Map<String, Id> buildFillNullSources(Id masterId, Set<Id> allIds) {
        Map<String, Id> sources = new Map<String, Id>();

        // Build the readable field list from the service's COMPARE_FIELDS,
        // restricted to fields that are updateable (the merge layer will
        // ignore non-updateable fields anyway, but skipping them here
        // saves a describe pass).
        Map<String, Schema.SObjectField> fmap = Account.SObjectType.getDescribe().fields.getMap();
        List<String> fields = new List<String>();
        for (String f : AccountDedupeService.COMPARE_FIELDS) {
            Schema.SObjectField tok = fmap.get(f.toLowerCase());
            if (tok != null && tok.getDescribe().isUpdateable()) fields.add(f);
        }
        if (fields.isEmpty()) return sources;

        String soql = 'SELECT Id, ' + String.join(fields, ', ') + ' FROM Account WHERE Id IN :allIds';
        Map<Id, Account> accs = new Map<Id, Account>((List<Account>) Database.query(soql));
        Account master = accs.get(masterId);
        if (master == null) return sources;

        for (String f : fields) {
            Object mv = master.get(f);
            if (mv != null && String.valueOf(mv) != '') continue; // master already populated
            for (Id id : allIds) {
                if (id == masterId) continue;
                Account a = accs.get(id);
                if (a == null) continue;
                Object av = a.get(f);
                if (av != null && String.valueOf(av) != '') {
                    sources.put(f, id);
                    break;
                }
            }
        }
        return sources;
    }
}
