// ARR_Hook_Trigger.trigger
// Fires Hook callouts when a won Opportunity changes in a way that may affect ARR.
// Filter: opportunities that just became Won, or already-won opps whose ARR/Type/CloseDate changed.

trigger ARR_Hook_Trigger on Opportunity (after insert, after update) {
    Set<Id> accountIdsToNotify = new Set<Id>();

    for (Opportunity newOpp : Trigger.new) {
        Opportunity oldOpp = Trigger.isUpdate ? Trigger.oldMap.get(newOpp.Id) : null;

        Boolean justBecameWon = newOpp.IsWon && (oldOpp == null || !oldOpp.IsWon);
        Boolean wonAndChanged = newOpp.IsWon && oldOpp != null && (
            newOpp.Annual_Recurring_Revenue__c != oldOpp.Annual_Recurring_Revenue__c ||
            newOpp.Type != oldOpp.Type ||
            newOpp.CloseDate != oldOpp.CloseDate
        );

        if ((justBecameWon || wonAndChanged) && newOpp.AccountId != null) {
            accountIdsToNotify.add(newOpp.AccountId);
        }
    }

    if (!accountIdsToNotify.isEmpty()) {
        ARR_Hook_Callout.notifyAsync(accountIdsToNotify);
    }
}
