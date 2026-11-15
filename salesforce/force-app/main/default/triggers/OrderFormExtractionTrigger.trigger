// Keeps each extraction's Order_Form_Line__c records in step with its
// Line_Items__c (OrderFormLines.sync) - whichever path wrote the extraction -
// and marks a review stale when the values it reviewed change
// (OrderFormReviewStaleness). Neither writes the extraction itself.
trigger OrderFormExtractionTrigger on Order_Form_Extraction__c (after insert, after update) {
    OrderFormLines.sync(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    if (Trigger.isUpdate) OrderFormReviewStaleness.afterUpdate(Trigger.new, Trigger.oldMap);
}
