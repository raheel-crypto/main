/**
 * Agent equivalent of the Closed Lost path of the Close_Opportunity_Button flow.
 *
 * Called without confirm it runs the AI loss analysis so the agent can offer the
 * recommended reason, competitor, and narrative, validates any values supplied,
 * and returns a preview. Called with confirm=true it stamps Closed Lost with the
 * reasons, notes, LOB, prior stage, and AI fields, exactly as the flow does.
 */
public with sharing class SubmitClosedLost {

    @InvocableMethod(
        label='Submit Closed Lost'
        description='Closes an Opportunity as Closed Lost the same way the Close Opportunity screen flow does. Call once without confirm to get the AI-recommended loss reason, competitor, and narrative and to preview the values; call again with confirm=true to stamp Closed Lost with the primary reason, secondary reason, final competitor, CL notes, and LOB/Division. Blank inputs keep the current field values, and blank notes default to the AI narrative.'
        category='Opportunity'
    )
    public static List<Response> submitClosedLost(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            out.add(process(req));
        }
        return out;
    }

    private static Response process(Request req) {
        Response res = blankResponse();
        Id oppId = OpportunityCloseService.parseOpportunityId(req.opportunityId);
        Opportunity opp = oppId == null ? null : OpportunityCloseService.loadOpportunity(oppId);
        if (opp == null) {
            return res.notFound(req.opportunityId);
        }
        res.forOpportunity(opp);
        res.confirmPrompt = OpportunityCloseService.confirmLostPrompt(opp);
        res.changePrompt = OpportunityCloseService.changePrompt(opp);

        if (opp.IsClosed) {
            return res.finish('AlreadyClosed', opp.IsWon ? 'Already Closed Won' : 'Already Closed Lost', 'info',
                'Nothing to submit', 'This opportunity is already closed. No changes were made.');
        }

        Boolean confirm = req.confirm == true;

        // AI loss analysis: run on preview, or on confirm when it has not run yet.
        // In Loss mode the controller writes CL_Reason_AI__c, CL_Narrative_AI__c and
        // Final_Competitor__c itself; writeBackNewFields also persists confidence,
        // evidence tier and next step so the confirm call can reuse them.
        DealScoreAIController.ForensicResult ai = null;
        if (!confirm || String.isBlank(opp.CL_Reason_AI__c)) {
            ai = OpportunityCloseService.runAiAnalysis(opp.Id, 'Loss', true);
            if (ai != null && ai.success != true) {
                res.aiFailureReason = OpportunityCloseService.textOrNotSet(ai.summary);
                res.aiFailed = true;
                ai = null;
            }
            if (ai != null) {
                // Persist the summary the flow stores in CL_Details_AI__c.
                if (String.isNotBlank(ai.summary)) {
                    update new Opportunity(Id = opp.Id, CL_Details_AI__c = ai.summary);
                }
                opp = OpportunityCloseService.loadOpportunity(opp.Id);
            }
        }
        res.aiSummary = firstNonBlank(ai == null ? null : ai.summary, opp.CL_Details_AI__c);
        res.recommendedReason = firstNonBlank(ai == null ? null : ai.clReason, opp.CL_Reason_AI__c);
        res.recommendedCompetitor = firstNonBlank(ai == null ? null : ai.clCompetitor, opp.Final_Competitor__c);
        res.recommendedNarrative = firstNonBlank(ai == null ? null : ai.clNarrative, opp.CL_Narrative_AI__c);
        res.aiConfidence = firstNonBlank(ai == null ? null : ai.confidence, opp.CL_Confidence_AI__c);
        res.hasRecommendation = res.recommendedReason != OpportunityCloseService.NOT_SET;

        // Choice buttons: offered on every response that does not submit (preview or
        // blocked), whatever the confirm flag was, so a blocked confirm still gets them.
        // When the AI analysis failed, a retry button rides along.
        res.reasonChoices = OpportunityCloseService.lostReasonChoices(opp, res.recommendedReason);
        if (res.aiFailed) {
            res.reasonChoices.add(new OpportunityCloseService.Choice('Retry AI analysis',
                OpportunityCloseService.retryAiPrompt(opp), 'secondary'));
        }
        res.hasReasonChoices = true;

        // Merge inputs over existing values (notes default to the AI narrative, like the flow).
        String primary = pick(req.primaryReason, opp.CL_Primary_Reason__c);
        String secondary = pick(req.secondaryReason, opp.CL_Secondary_Reason__c);
        String competitor = pick(req.finalCompetitor, opp.Final_Competitor__c);
        String notes = pick(req.notes, opp.CL_Notes__c);
        if (String.isBlank(notes) && res.recommendedNarrative != OpportunityCloseService.NOT_SET) {
            notes = res.recommendedNarrative;
        }
        String lob = pick(req.lobDivision, opp.LOB_Division__c);

        List<OpportunityCloseService.Row> problems = new List<OpportunityCloseService.Row>();
        primary = requirePicklist(problems, 'CL Primary Reason', 'CL_Primary_Reason__c', primary, true);
        secondary = requirePicklist(problems, 'CL Secondary Reason', 'CL_Secondary_Reason__c', secondary, false);
        competitor = requirePicklist(problems, 'Final Competitor', 'Final_Competitor__c', competitor, false);
        lob = requirePicklist(problems, 'LOB/Division', 'LOB_Division__c', lob, true);
        if (String.isBlank(notes)) {
            problems.add(problem('CL Notes', 'A short note on why the deal was lost is required.'));
        }

        res.rows.add(new OpportunityCloseService.Row('Stage after submit', OpportunityCloseService.STAGE_LOST));
        res.rows.add(new OpportunityCloseService.Row('Closed Lost from Stage', opp.StageName));
        res.rows.add(new OpportunityCloseService.Row('CL Primary Reason', OpportunityCloseService.textOrNotSet(primary)));
        res.rows.add(new OpportunityCloseService.Row('CL Secondary Reason', OpportunityCloseService.textOrNotSet(secondary)));
        res.rows.add(new OpportunityCloseService.Row('Final Competitor', OpportunityCloseService.textOrNotSet(competitor)));
        res.rows.add(new OpportunityCloseService.Row('LOB/Division', OpportunityCloseService.textOrNotSet(lob)));
        res.rows.add(new OpportunityCloseService.Row('CL Notes', OpportunityCloseService.textOrNotSet(notes)));

        if (!problems.isEmpty()) {
            res.problems = problems;
            res.hasProblems = true;
            res.isBlocked = true;
            return res.finish('Blocked', 'Blocked', 'error', 'Cannot submit yet',
                problems.size() + ' issue(s) must be resolved before this opportunity can be closed Lost. Nothing has been saved.');
        }

        if (!confirm) {
            res.isPreview = true;
            return res.finish('ReadyToSubmit', 'Preview', 'info', 'Ready to close as Lost',
                'Review the values below. Confirming sets the stage to Closed Lost and records the reasons and notes. Nothing has been saved yet.');
        }

        Opportunity upd = new Opportunity(Id = opp.Id);
        upd.StageName = OpportunityCloseService.STAGE_LOST;
        upd.CL_Primary_Reason__c = primary;
        upd.CL_Secondary_Reason__c = secondary;
        upd.Final_Competitor__c = competitor;
        upd.CL_Notes__c = notes;
        upd.LOB_Division__c = lob;
        upd.Close_Lost_from_Stage__c = opp.StageName;
        if (res.recommendedReason != OpportunityCloseService.NOT_SET) {
            upd.CL_Reason_AI__c = res.recommendedReason;
        }
        if (res.recommendedNarrative != OpportunityCloseService.NOT_SET) {
            upd.CL_Narrative_AI__c = res.recommendedNarrative;
        }
        if (res.aiSummary != OpportunityCloseService.NOT_SET) {
            upd.CL_Details_AI__c = res.aiSummary;
        }
        if (res.aiConfidence != OpportunityCloseService.NOT_SET) {
            upd.CL_Confidence_AI__c = res.aiConfidence;
        }
        update upd;

        res.reasonChoices = new List<OpportunityCloseService.Choice>();
        res.hasReasonChoices = false;
        res.isSubmitted = true;
        return res.finish('Submitted', 'Closed Lost', 'success', 'Opportunity closed Lost',
            'The opportunity is now Closed Lost with the reasons and notes recorded.');
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static String pick(String input, String existing) {
        return String.isBlank(input) ? existing : input.trim();
    }

    private static String firstNonBlank(String a, String b) {
        if (String.isNotBlank(a)) {
            return a;
        }
        return String.isNotBlank(b) ? b : OpportunityCloseService.NOT_SET;
    }

    private static String requirePicklist(List<OpportunityCloseService.Row> problems, String label, String apiName, String value, Boolean required) {
        if (String.isBlank(value)) {
            if (required) {
                problems.add(problem(label, 'A value is required. Choose one of: ' + OpportunityCloseService.picklistOptions(apiName) + '.'));
            }
            return null;
        }
        String canonical = OpportunityCloseService.matchPicklist(apiName, value);
        if (canonical == null) {
            problems.add(problem(label, '"' + value + '" is not a valid option. Choose one of: ' + OpportunityCloseService.picklistOptions(apiName) + '.'));
            return value;
        }
        return canonical;
    }

    private static OpportunityCloseService.Row problem(String label, String message) {
        return new OpportunityCloseService.Row(label, message, 'alert-circle', 'error');
    }

    private static Response blankResponse() {
        Response r = new Response();
        r.rows = new List<OpportunityCloseService.Row>();
        r.problems = new List<OpportunityCloseService.Row>();
        r.isPreview = false;
        r.isSubmitted = false;
        r.isBlocked = false;
        r.hasProblems = false;
        r.hasRecommendation = false;
        r.aiSummary = OpportunityCloseService.NOT_SET;
        r.recommendedReason = OpportunityCloseService.NOT_SET;
        r.recommendedCompetitor = OpportunityCloseService.NOT_SET;
        r.recommendedNarrative = OpportunityCloseService.NOT_SET;
        r.aiConfidence = OpportunityCloseService.NOT_SET;
        r.aiFailed = false;
        r.aiFailureReason = '';
        r.reasonChoices = new List<OpportunityCloseService.Choice>();
        r.hasReasonChoices = false;
        r.confirmPrompt = '';
        r.changePrompt = '';
        return r;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The 15 or 18 character Id of the Opportunity (starts with 006).' required=true)
        public String opportunityId;
        @InvocableVariable(label='Confirm' description='False or blank previews with the AI recommendation and validates without saving. True stamps Closed Lost. Only set true after the user has reviewed the preview.')
        public Boolean confirm;
        @InvocableVariable(label='CL Primary Reason' description='Picklist, required. Options: Bad Fit Disqualified, Budget Financial, Business Change, Competitive Loss, Duplicate, No Need, No Show / Buyer Canceled, Product / Technical Gap, Security Compliance, Timing Priority, Wrong Authority.')
        public String primaryReason;
        @InvocableVariable(label='CL Secondary Reason' description='Picklist, optional. Options: Hebbia, Claude, Perplexity, BlueFlame, Internal Build, Inaccuracy / Hallucination, Latency / Performance, Missing 3P Data, Missing 1P Data, Budget Not Approved, Funding Shifted, Perceived price too high.')
        public String secondaryReason;
        @InvocableVariable(label='Final Competitor' description='Picklist, optional. Options: AlphaSense, BlueFlame, ChatGPT, Claude, Hebbia, Internal Build, ModelML, Perplexity.')
        public String finalCompetitor;
        @InvocableVariable(label='CL Notes' description='Why the deal was lost. Defaults to the AI narrative when blank.')
        public String notes;
        @InvocableVariable(label='LOB/Division' description='Picklist, required. Options: Investment Banking, Commercial Banking, Corporate Banking, Corporate Finance, Wealth Management, Asset Management, Private Equity, Private Credit, Hedge Fund, Venture Capital / Ventures, Corporate Development, Sales & Trading / Markets.')
        public String lobDivision;
    }

    public class Response {
        @InvocableVariable(label='Opportunity Id') public String opportunityId;
        @InvocableVariable(label='Opportunity Name') public String opportunityName;
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Status' description='ReadyToSubmit, Blocked, Submitted, AlreadyClosed, or NotFound.') public String status;
        @InvocableVariable(label='Status Label') public String statusLabel;
        @InvocableVariable(label='Status Variant' description='Badge variant: success, warning, error, or info.') public String statusVariant;
        @InvocableVariable(label='Headline') public String headline;
        @InvocableVariable(label='Message') public String message;
        @InvocableVariable(label='Is Preview') public Boolean isPreview;
        @InvocableVariable(label='Is Submitted') public Boolean isSubmitted;
        @InvocableVariable(label='Is Blocked') public Boolean isBlocked;
        @InvocableVariable(label='Has Problems') public Boolean hasProblems;
        @InvocableVariable(label='Problems') public List<OpportunityCloseService.Row> problems;
        @InvocableVariable(label='Rows' description='The values that were (or would be) written, as label/value pairs.') public List<OpportunityCloseService.Row> rows;
        @InvocableVariable(label='Has AI Recommendation') public Boolean hasRecommendation;
        @InvocableVariable(label='AI Summary') public String aiSummary;
        @InvocableVariable(label='Recommended Reason' description='AI-recommended CL Primary Reason picklist value.') public String recommendedReason;
        @InvocableVariable(label='Recommended Competitor') public String recommendedCompetitor;
        @InvocableVariable(label='Recommended Narrative' description='AI-written loss narrative, the default for CL Notes.') public String recommendedNarrative;
        @InvocableVariable(label='AI Confidence') public String aiConfidence;
        @InvocableVariable(label='AI Failed' description='True when the AI analysis could not run.') public Boolean aiFailed;
        @InvocableVariable(label='AI Failure Reason' description='Why the AI recommendation is unavailable, when it failed.') public String aiFailureReason;
        @InvocableVariable(label='Loss Reason Choices' description='Buttons for the recommended CL Primary Reason plus common alternatives. Each carries the prompt the button sends.') public List<OpportunityCloseService.Choice> reasonChoices;
        @InvocableVariable(label='Has Loss Reason Choices' description='True on preview and blocked responses, when the user can still pick a reason.') public Boolean hasReasonChoices;
        @InvocableVariable(label='Confirm Prompt') public String confirmPrompt;
        @InvocableVariable(label='Change Prompt') public String changePrompt;
        @InvocableVariable(label='Opportunity URL') public String opportunityUrl;


        public void forOpportunity(Opportunity opp) {
            opportunityId = opp.Id;
            opportunityName = opp.Name;
            accountName = opp.Account == null ? OpportunityCloseService.NOT_SET : opp.Account.Name;
            opportunityUrl = OpportunityCloseService.recordUrl(opp.Id);
        }

        public Response notFound(String requested) {
            opportunityName = 'Opportunity not found';
            accountName = String.isBlank(requested) ? 'No Opportunity Id was provided' : 'No opportunity with Id ' + requested;
            opportunityUrl = URL.getOrgDomainUrl().toExternalForm();
            isBlocked = true;
            return finish('NotFound', 'Not found', 'error', 'Opportunity not found', 'Check the Id and try again.');
        }

        public Response finish(String status, String label, String variant, String headline, String message) {
            this.status = status;
            this.statusLabel = label;
            this.statusVariant = variant;
            this.headline = headline;
            this.message = message;
            return this;
        }
    }
}
