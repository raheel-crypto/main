/**
 * Reviews extractions in the background, one per job (a review is one model
 * callout of up to two minutes, and a transaction gets 120 seconds of callouts).
 * The rest of the list is passed on to a new job. Shadow mode: only review
 * records are written (OrderFormReviewer.save).
 */
public with sharing class OrderFormReviewJob implements Queueable, Database.AllowsCallouts {

    private final List<Id> extractionIds;
    private final Boolean force;

    public OrderFormReviewJob(List<Id> extractionIds, Boolean force) {
        this.extractionIds = extractionIds == null ? new List<Id>() : extractionIds;
        this.force = force == true;
    }

    public void execute(QueueableContext ctx) {
        if (extractionIds.isEmpty()) return;
        List<Id> rest = new List<Id>(extractionIds);
        Id next = rest.remove(0);
        try {
            OrderFormReviewer.reviewAndSave(next, force);
        } catch (Exception e) {
            // One extraction's failure must not stop the others; it stays without a review.
            System.debug(LoggingLevel.ERROR, 'Order form review of ' + next + ' failed: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
        if (!rest.isEmpty() && !Test.isRunningTest()) System.enqueueJob(new OrderFormReviewJob(rest, force));
    }

    /** Queue reviews; returns a message for a button or script. */
    public static String enqueue(List<Id> extractionIds, Boolean force) {
        if (!OrderFormReviewer.isOn()) {
            return 'The reviewer is off. Set Mode to Shadow on the "Default" Order Form Review Setting to turn it on.';
        }
        if (extractionIds == null || extractionIds.isEmpty()) return 'Nothing to review.';
        Id jobId = System.enqueueJob(new OrderFormReviewJob(extractionIds, force));
        return 'Review started (job ' + jobId + ') for ' + extractionIds.size() + ' extraction(s). It takes a minute or '
            + 'two each; refresh the page to see the Reviews and Review Findings related lists.';
    }
}
