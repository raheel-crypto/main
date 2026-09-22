/**
 * Sends the RevOps Slack notification for a Closed Won submission through the
 * RogoQuoteBotSigned external service. Runs as a queueable so the callout
 * happens after the Opportunity update is committed.
 */
public with sharing class CloseWonNotificationJob implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static Boolean lastRunSucceeded;

    private final Id opportunityId;

    public CloseWonNotificationJob(Id opportunityId) {
        this.opportunityId = opportunityId;
    }

    public void execute(QueueableContext ctx) {
        if (Test.isRunningTest() || OpportunityCloseService.disableExternalCalls) {
            lastRunSucceeded = true;
            return;
        }
        try {
            Invocable.Action action = Invocable.Action.createCustomAction(
                'externalService', 'RogoQuoteBotSigned.notifySignedOrderForm'
            );
            action.setInvocationParameter('opportunity_id', String.valueOf(opportunityId));
            List<Invocable.Action.Result> results = action.invoke();
            lastRunSucceeded = !results.isEmpty() && results[0].isSuccess();
            if (!lastRunSucceeded) {
                System.debug(LoggingLevel.ERROR, 'RevOps Slack notification failed: ' + results);
            }
        } catch (Exception e) {
            lastRunSucceeded = false;
            System.debug(LoggingLevel.ERROR, 'RevOps Slack notification threw: ' + e.getMessage());
        }
    }
}
