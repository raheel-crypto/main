/**
 * The review sweep: current extractions from the last Sweep_Days__c days that
 * have no current, up-to-date review. One extraction per execute (scope 1: one
 * model callout per transaction). An extraction whose current review still
 * matches its values, files and prompts is skipped without a callout; one that
 * has used Max_Attempts__c reviews for this version is left alone (bounded
 * retries, no correction loop). Schedulable, so it can run hourly:
 *   System.schedule('Order form review sweep', '0 15 * * * ?', new OrderFormReviewBatch());
 */
public with sharing class OrderFormReviewBatch implements Database.Batchable<SObject>, Database.AllowsCallouts,
        Database.Stateful, Schedulable {

    public Integer reviewed = 0;
    public Integer skipped = 0;
    public Integer failed = 0;
    private final Integer days;

    public OrderFormReviewBatch() {
        this(null);
    }

    public OrderFormReviewBatch(Integer days) {
        Decimal configured = OrderFormReviewer.settings().Sweep_Days__c;
        this.days = days != null ? days : (configured == null ? 30 : configured.intValue());
    }

    public static String targetWhere(Integer days) {
        return 'Is_Current__c = true AND Extraction_Status__c IN (\'Success\', \'Incomplete\', \'No Order Form\') '
            + 'AND Extracted_At__c = LAST_N_DAYS:' + days;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (!OrderFormReviewer.isOn()) {
            return Database.getQueryLocator('SELECT Id FROM Order_Form_Extraction__c WHERE Id = null');
        }
        return Database.getQueryLocator('SELECT Id FROM Order_Form_Extraction__c WHERE ' + targetWhere(days)
            + ' ORDER BY Extracted_At__c DESC');
    }

    public void execute(Database.BatchableContext bc, List<Order_Form_Extraction__c> scope) {
        for (Order_Form_Extraction__c r : scope) {
            try {
                OrderFormReviewer.Outcome o = OrderFormReviewer.reviewAndSave(r.Id, false);
                if (o.review == null) skipped++;
                else if (o.review.Status__c == 'Failed') failed++;
                else reviewed++;
            } catch (Exception e) {
                failed++;
                System.debug(LoggingLevel.ERROR, 'Order form review of ' + r.Id + ' failed: ' + e.getMessage());
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'Order form review sweep: ' + reviewed + ' reviewed, ' + failed + ' failed, '
            + skipped + ' skipped (up to date, out of attempts, or reviewer off).');
    }

    public void execute(SchedulableContext sc) {
        if (OrderFormReviewer.isOn()) Database.executeBatch(new OrderFormReviewBatch(), 1);
    }
}
