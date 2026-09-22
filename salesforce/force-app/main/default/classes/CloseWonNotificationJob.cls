/**
 * Sends the RevOps Slack notification for a Closed Won submission through the
 * RogoQuoteBotSigned external service. Runs as a queueable so the callout
 * happens after the Opportunity update is committed.
 */
public with sharing class CloseWonNotificationJob implements Queueable, Database.AllowsCallouts {

    public static final String ACTION_NAME = 'RogoQuoteBotSigned.notifySignedOrderForm';

    /** Wraps the external-service invocation so tests can stub it. */
    public virtual class Invoker {
        public virtual List<Invocable.Action.Result> invoke(Invocable.Action action) {
            return action.invoke();
        }
    }

    @TestVisible
    private static Invoker invoker = new Invoker();

    @TestVisible
    private static Boolean lastRunSucceeded;

    private final Id opportunityId;

    public CloseWonNotificationJob(Id opportunityId) {
        this.opportunityId = opportunityId;
    }

    public void execute(QueueableContext ctx) {
        if (OpportunityCloseService.disableExternalCalls) {
            lastRunSucceeded = true;
            return;
        }
        try {
            Invocable.Action action = Invocable.Action.createCustomAction('externalService', ACTION_NAME);
            action.setInvocationParameter('opportunity_id', String.valueOf(opportunityId));
            List<Invocable.Action.Result> results = invoker.invoke(action);
            lastRunSucceeded = results != null && !results.isEmpty() && results[0].isSuccess();
            if (!lastRunSucceeded) {
                System.debug(LoggingLevel.ERROR, 'RevOps Slack notification failed: ' + results);
            }
        } catch (Exception e) {
            lastRunSucceeded = false;
            System.debug(LoggingLevel.ERROR, 'RevOps Slack notification threw: ' + e.getMessage());
        }
    }
}
