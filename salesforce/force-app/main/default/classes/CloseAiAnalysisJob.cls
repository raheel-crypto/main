/**
 * Runs the AI deal analysis (DealScoreAIController) in the background so agent
 * tool calls stay fast. The controller's Claude callout can take 30+ seconds,
 * longer than an MCP tool call may run, so the tools never call it inline.
 *
 * Loss mode: the controller writes CL_Reason_AI__c, CL_Narrative_AI__c and
 * Final_Competitor__c itself (writeBackNewFields also stores confidence, evidence
 * tier and next step); this job adds CL_Details_AI__c, as the screen flow does.
 * Win mode: this job writes the CW AI fields the Closed Won submission used to
 * write inline.
 *
 * Progress is tracked in Opportunity.Agent_AI_Status__c: "Running since <iso>"
 * while queued, "Failed <iso>: <reason>" on failure, cleared on success.
 */
public with sharing class CloseAiAnalysisJob implements Queueable, Database.AllowsCallouts {

    public static final String RUNNING_PREFIX = 'Running since ';
    public static final String FAILED_PREFIX = 'Failed ';

    /** Wraps the analysis call so tests can stub it. */
    /** Background work is not bound by an MCP tool call, so give the model the Apex maximum. */
    public static final Integer BACKGROUND_TIMEOUT_MS = 120000;

    public virtual class Runner {
        public virtual DealScoreAIController.ForensicResult run(Id opportunityId, String mode) {
            DealScoreAIController.calloutTimeoutMs = BACKGROUND_TIMEOUT_MS;
            return OpportunityCloseService.runAiAnalysis(opportunityId, mode, true);
        }
    }

    @TestVisible
    private static Runner runner = new Runner();

    @TestVisible
    private static Boolean lastRunSucceeded;

    private final Id opportunityId;
    private final String mode;

    public CloseAiAnalysisJob(Id opportunityId, String mode) {
        this.opportunityId = opportunityId;
        this.mode = mode;
    }

    public void execute(QueueableContext ctx) {
        DealScoreAIController.ForensicResult ai;
        String failure = null;
        try {
            ai = runner.run(opportunityId, mode);
            if (ai == null) {
                failure = 'AI analysis is unavailable';
            } else if (ai.success != true) {
                failure = String.isBlank(ai.summary) ? 'AI analysis failed' : ai.summary;
            }
        } catch (Exception e) {
            failure = 'AI analysis could not run: ' + e.getTypeName() + ': ' + e.getMessage();
        }

        Opportunity upd = new Opportunity(Id = opportunityId);
        if (failure != null) {
            lastRunSucceeded = false;
            upd.Agent_AI_Status__c = (FAILED_PREFIX + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + ': ' + failure).abbreviate(255);
        } else {
            lastRunSucceeded = true;
            upd.Agent_AI_Status__c = null;
            if (mode == 'Win') {
                upd.CW_AI_Details__c = ai.summary;
                upd.CW_Confidence_AI__c = ai.confidence;
                upd.Next_Step_AI__c = ai.nextStep;
                upd.Evidence_Tier_AI__c = ai.evidenceTier;
            } else if (String.isNotBlank(ai.summary)) {
                upd.CL_Details_AI__c = ai.summary;
            }
        }
        try {
            update upd;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Could not record AI analysis outcome: ' + e.getMessage());
        }
    }
}
