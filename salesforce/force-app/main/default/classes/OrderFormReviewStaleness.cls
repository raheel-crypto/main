/**
 * Marks reviews stale when what they reviewed changes. A review stores the
 * hashes of the extraction values it saw (Input_Hash__c), the file versions
 * (Source_Hash__c) and the prompts / model settings (Prompt_Version__c).
 *
 *  - Extraction values: the Order_Form_Extraction__c trigger (after update)
 *    compares each current review's Input_Hash__c with the row as saved - a
 *    person's edit, a re-align or a backfill makes it stale at once.
 *  - Files and prompts: checked whenever a review is requested and by the sweep
 *    (OrderFormReviewBatch), since a new file version or prompt does not touch
 *    the extraction row.
 *
 * Only Order_Form_Review__c is written; the extraction is never changed.
 */
public with sharing class OrderFormReviewStaleness {

    /** Trigger hook: mark current reviews stale for rows whose reviewed values changed. */
    public static void afterUpdate(List<Order_Form_Extraction__c> rows, Map<Id, Order_Form_Extraction__c> oldMap) {
        if (rows == null || oldMap == null) return;
        Map<Id, List<String>> changedById = new Map<Id, List<String>>();
        List<String> watched = new List<String>(OrderFormReviewCoverage.PAYLOAD_FIELDS);
        watched.addAll(OrderFormReviewCoverage.HASH_EXTRA_FIELDS);
        for (Order_Form_Extraction__c r : rows) {
            Order_Form_Extraction__c old = oldMap.get(r.Id);
            if (old == null) continue;
            List<String> changed = new List<String>();
            for (String f : watched) {
                // equals(): a case-only correction is a change too.
                if (!OrderFormReviewer.canonValue(r.get(f)).equals(OrderFormReviewer.canonValue(old.get(f)))) {
                    changed.add(OrderFormReviewCoverage.nameOf(f));
                }
            }
            if (!changed.isEmpty()) changedById.put(r.Id, changed);
        }
        if (changedById.isEmpty()) return;
        Map<Id, Order_Form_Extraction__c> byId = new Map<Id, Order_Form_Extraction__c>(rows);
        List<Order_Form_Review__c> stale = new List<Order_Form_Review__c>();
        for (Order_Form_Review__c rev : [
            SELECT Id, Extraction__c, Input_Hash__c FROM Order_Form_Review__c
            WHERE Extraction__c IN :changedById.keySet() AND Is_Current__c = true AND Is_Stale__c = false
        ]) {
            if (OrderFormReviewer.inputHash(byId.get(rev.Extraction__c)).equals(rev.Input_Hash__c)) continue;
            List<String> changed = changedById.get(rev.Extraction__c);
            stale.add(new Order_Form_Review__c(Id = rev.Id, Is_Stale__c = true,
                Stale_Reason__c = ('Extraction values changed after the review: ' + String.join(changed, ', ')).left(255)));
        }
        if (!stale.isEmpty()) update stale;
    }

    /**
     * The current review of an extraction, re-checked against its files and the
     * prompts: returns the reason it is stale (and marks it, unless the caller
     * saves it later), or null when it is still up to date. No callout.
     */
    public static String recheck(Order_Form_Review__c current, String sourceHash, String promptVersion) {
        if (current == null || current.Is_Stale__c == true) return null;
        String why;
        if (current.Source_Hash__c != sourceHash) why = 'A file the extraction read has a new version (or files changed).';
        else if (current.Prompt_Version__c != promptVersion) why = 'The reviewer or extraction prompt, schema or model settings changed.';
        if (why != null) {
            current.Is_Stale__c = true;
            current.Stale_Reason__c = why.left(255);
        }
        return why;
    }
}
