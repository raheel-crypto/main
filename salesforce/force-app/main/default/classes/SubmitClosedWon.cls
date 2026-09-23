/**
 * Agent equivalent of the Closed Won path of the Close_Opportunity_Button flow.
 *
 * Two-step: called without confirm it validates and returns a preview of the
 * values that would be written; called with confirm=true it writes them,
 * notifies RevOps in Slack, and queues order-form extraction. Like the screen
 * flow it does not stamp Closed Won (RevOps does after validating), except for
 * Contract Restructure deals, which close directly.
 *
 * Inputs left blank keep the value already on the Opportunity, so the agent only
 * needs to supply what is missing or changing.
 */
public with sharing class SubmitClosedWon {

    @InvocableMethod(
        label='Submit Closed Won'
        description='Submits an Opportunity as Closed Won the same way the Close Opportunity screen flow does. Requires a signed order form already attached to the Opportunity. Call once without confirm to validate and preview the values; call again with confirm=true to write the finance and handoff fields, notify RevOps in Slack, and queue order form extraction. RevOps stamps the stage after validating. Blank inputs keep the current field values.'
        category='Opportunity'
    )
    public static List<Response> submitClosedWon(List<Request> requests) {
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
        res.confirmPrompt = OpportunityCloseService.confirmWonPrompt(opp);
        res.changePrompt = OpportunityCloseService.changePrompt(opp);

        if (opp.IsClosed) {
            return res.finish('AlreadyClosed', opp.IsWon ? 'Already Closed Won' : 'Already Closed Lost', 'info',
                'Nothing to submit', 'This opportunity is already closed. No changes were made.');
        }

        Boolean confirm = req.confirm == true;

        // Contract Restructure: no form, closes directly.
        if (OpportunityCloseService.isRestructure(opp)) {
            res.rows.add(new OpportunityCloseService.Row('Opportunity Type', opp.Type));
            res.rows.add(new OpportunityCloseService.Row('Stage after submit', OpportunityCloseService.STAGE_WON));
            if (!confirm) {
                res.isPreview = true;
                return res.finish('ReadyToSubmit', 'Preview', 'info', 'Ready to close as Won',
                    'Contract Restructure deals close directly. Confirming will set the stage to Closed Won and notify RevOps in Slack. Nothing has been saved yet.');
            }
            Opportunity upd = new Opportunity(Id = opp.Id);
            upd.StageName = OpportunityCloseService.STAGE_WON;
            upd.CW_Submission_Source__c = OpportunityCloseService.SUBMISSION_SOURCE;
            update upd;
            OpportunityCloseService.queueOrderFormExtraction(opp.Id);
            OpportunityCloseService.notifyRevOpsAfterCommit(opp.Id);
            res.isSubmitted = true;
            return res.finish('Submitted', 'Closed Won', 'success', 'Closed Won submitted',
                'The opportunity is now Closed Won and RevOps has been notified in Slack.');
        }

        // Merge inputs over existing values and validate. A blank LOB/Division defaults
        // from the account's Business Type, with buttons offered to change it.
        Map<String, Object> values = merged(req, opp);
        Boolean lobExplicit = String.isNotBlank((String) values.get('lobDivision'));
        String suggestedLob = lobExplicit ? null : OpportunityCloseService.suggestLob(opp);
        if (!lobExplicit) {
            values.put('lobDivision', suggestedLob);
            res.lobChoices = OpportunityCloseService.lobChoices(opp, suggestedLob, 'Won');
            res.hasLobChoices = true;
        }
        List<OpportunityCloseService.Row> problems = validate(values, opp);
        List<String> signed = OpportunityCloseService.signedDocumentTitles(opp.Id);
        if (signed.isEmpty()) {
            res.needsSignedDocument = true;
            problems.add(0, new OpportunityCloseService.Row('Signed order form',
                'No signed order form is attached. Use the Upload signed order form button, drop the file there, then try again.',
                'alert-circle', 'error'));
        }

        for (OpportunityCloseService.FieldSpec spec : OpportunityCloseService.wonFieldSpecs()) {
            String shown = display(spec, values.get(spec.key));
            if (spec.key == 'lobDivision' && suggestedLob != null) {
                shown += OpportunityCloseService.SUGGESTED_SUFFIX;
            }
            res.rows.add(new OpportunityCloseService.Row(spec.label, shown));
        }
        res.rows.add(new OpportunityCloseService.Row('Willing to Provide References',
            OpportunityCloseService.formatBoolean((Boolean) values.get('willingToProvideReferences'))));

        if (!problems.isEmpty()) {
            res.problems = problems;
            res.hasProblems = true;
            res.isBlocked = true;
            return res.finish('Blocked', 'Blocked', 'error', 'Cannot submit yet',
                problems.size() + ' issue(s) must be resolved before this opportunity can be submitted as Closed Won. Nothing has been saved.');
        }

        if (!confirm) {
            res.isPreview = true;
            return res.finish('ReadyToSubmit', 'Preview', 'info', 'Ready to submit Closed Won',
                'Review the values below. Confirming writes them to the opportunity, notifies RevOps in Slack to validate and mark the deal Closed Won, and queues order form extraction. Nothing has been saved yet.');
        }

        // Confirmed: write the fields now; the AI win analysis runs in the background
        // (CloseAiAnalysisJob) after commit, because its callout can outlast a tool call.
        Opportunity upd = new Opportunity(Id = opp.Id);
        upd.LOB_Division__c = (String) values.get('lobDivision');
        upd.Pricing_Structure__c = (String) values.get('pricingStructure');
        upd.Deal_Description__c = (String) values.get('dealDescription');
        upd.Purchase_Driver__c = (String) values.get('purchaseDriver');
        upd.Rollout_Timeline__c = (String) values.get('rolloutTimeline');
        upd.Success_Criteria__c = (String) values.get('successCriteria');
        upd.Upsell_Potential__c = (String) values.get('upsellPotential');
        upd.Implementation_Notes__c = (String) values.get('implementationNotes');
        upd.Key_Risks__c = (String) values.get('keyRisks');
        upd.Amount = (Decimal) values.get('amount');
        upd.Contract_Start_Date__c = (Date) values.get('contractStartDate');
        upd.Contract_End_Date__c = (Date) values.get('contractEndDate');
        upd.Contract_Length_Mos__c = (Decimal) values.get('contractLengthMonths');
        upd.Annual_Recurring_Revenue__c = (Decimal) values.get('annualRecurringRevenue');
        upd.Total_Contract_Value__c = (Decimal) values.get('totalContractValue');
        upd.License_Fees__c = (Decimal) values.get('licenseFee');
        upd.Platform_Connection_Fee__c = (Decimal) values.get('platformConnectionFee');
        upd.Professional_Service_Fees__c = (Decimal) values.get('professionalServicesFees');
        upd.Seat_Licenses__c = (Decimal) values.get('seatLicenses');
        upd.Payment_Terms__c = (String) values.get('paymentTerms');
        upd.Credit_Terms__c = (String) values.get('creditTerms');
        upd.Billing_Notes__c = (String) values.get('billingNotes');
        upd.Billing_Contact__c = (String) values.get('billingContactEmail');
        upd.Renewal_Terms__c = (String) values.get('renewalTerms');
        upd.ELA__c = (Boolean) values.get('isEla');
        upd.Opt_Out__c = (Boolean) values.get('optOut');
        upd.Opt_Out_Date__c = (Date) values.get('optOutDate');
        upd.CW_Screen_Flow_Used__c = true; // same flag the screen flow and Slack port set
        upd.CW_Submission_Source__c = OpportunityCloseService.SUBMISSION_SOURCE;
        update upd;

        if (opp.AccountId != null) {
            update new Account(Id = opp.AccountId, Provide_References__c = (Boolean) values.get('willingToProvideReferences'));
        }

        OpportunityCloseService.queueOrderFormExtraction(opp.Id);
        OpportunityCloseService.notifyRevOpsAfterCommit(opp.Id);
        if (OpportunityCloseService.startAiAnalysis(opp, 'Win')) {
            res.aiRunning = true;
            res.aiStatusText = 'The AI win summary is being generated in the background and will be saved to the opportunity when it finishes.';
        }

        res.isSubmitted = true;
        res.lobChoices = new List<OpportunityCloseService.Choice>();
        res.hasLobChoices = false;
        return res.finish('Submitted', 'Submitted to RevOps', 'success', 'Closed Won submitted',
            'The finance and handoff fields are saved and a Slack has been sent to RevOps to validate and mark the opportunity Closed Won. Order form extraction has been queued.');
    }

    // ─── Merge and validation ────────────────────────────────────────────

    /** Input value when provided, otherwise the value already on the record. */
    private static Map<String, Object> merged(Request req, Opportunity opp) {
        Map<String, Object> v = new Map<String, Object>();
        v.put('lobDivision', pick(req.lobDivision, opp.LOB_Division__c));
        v.put('pricingStructure', pick(req.pricingStructure, opp.Pricing_Structure__c));
        v.put('dealDescription', pick(req.dealDescription, opp.Deal_Description__c));
        v.put('purchaseDriver', pick(req.purchaseDriver, opp.Purchase_Driver__c));
        v.put('rolloutTimeline', pick(req.rolloutTimeline, opp.Rollout_Timeline__c));
        v.put('successCriteria', pick(req.successCriteria, opp.Success_Criteria__c));
        v.put('upsellPotential', pick(req.upsellPotential, opp.Upsell_Potential__c));
        v.put('implementationNotes', pick(req.implementationNotes, opp.Implementation_Notes__c));
        v.put('keyRisks', pick(req.keyRisks, opp.Key_Risks__c));
        v.put('amount', req.amount != null ? req.amount : opp.Amount);
        v.put('contractStartDate', req.contractStartDate != null ? req.contractStartDate : opp.Contract_Start_Date__c);
        v.put('contractEndDate', req.contractEndDate != null ? req.contractEndDate : opp.Contract_End_Date__c);
        v.put('contractLengthMonths', req.contractLengthMonths != null ? Decimal.valueOf(req.contractLengthMonths) : opp.Contract_Length_Mos__c);
        v.put('annualRecurringRevenue', req.annualRecurringRevenue != null ? req.annualRecurringRevenue : opp.Annual_Recurring_Revenue__c);
        v.put('totalContractValue', req.totalContractValue != null ? req.totalContractValue : opp.Total_Contract_Value__c);
        v.put('licenseFee', req.licenseFee != null ? req.licenseFee : opp.License_Fees__c);
        v.put('platformConnectionFee', req.platformConnectionFee != null ? req.platformConnectionFee : opp.Platform_Connection_Fee__c);
        v.put('professionalServicesFees', req.professionalServicesFees != null ? req.professionalServicesFees : opp.Professional_Service_Fees__c);
        v.put('seatLicenses', req.seatLicenses != null ? Decimal.valueOf(req.seatLicenses) : opp.Seat_Licenses__c);
        v.put('paymentTerms', pick(req.paymentTerms, opp.Payment_Terms__c));
        v.put('creditTerms', pick(req.creditTerms, opp.Credit_Terms__c));
        v.put('billingNotes', pick(req.billingNotes, opp.Billing_Notes__c));
        v.put('billingContactEmail', pick(req.billingContactEmail, opp.Billing_Contact__c));
        v.put('renewalTerms', pick(req.renewalTerms, opp.Renewal_Terms__c));
        v.put('isEla', req.isEla != null ? req.isEla : (opp.ELA__c == true));
        v.put('optOut', req.optOut != null ? req.optOut : (opp.Opt_Out__c == true));
        v.put('optOutDate', req.optOutDate != null ? req.optOutDate : opp.Opt_Out_Date__c);
        Boolean existingRefs = opp.Account == null ? false : (opp.Account.Provide_References__c == true);
        v.put('willingToProvideReferences', req.willingToProvideReferences != null ? req.willingToProvideReferences : existingRefs);
        return v;
    }

    private static String pick(String input, String existing) {
        return String.isBlank(input) ? existing : input.trim();
    }

    private static List<OpportunityCloseService.Row> validate(Map<String, Object> v, Opportunity opp) {
        List<OpportunityCloseService.Row> problems = new List<OpportunityCloseService.Row>();
        for (OpportunityCloseService.FieldSpec spec : OpportunityCloseService.wonFieldSpecs()) {
            Object val = v.get(spec.key);
            Boolean needed = spec.required || (spec.key == 'optOutDate' && (Boolean) v.get('optOut') == true);
            if (spec.kind == 'boolean') {
                continue;
            }
            Boolean blank = val == null || (val instanceof String && String.isBlank((String) val));
            if (blank) {
                if (needed) {
                    problems.add(problem(spec.label, spec.key == 'optOutDate'
                        ? 'Required because Opt Out is true.'
                        : 'A value is required.'));
                }
                continue;
            }
            if (spec.kind == 'picklist') {
                String canonical = OpportunityCloseService.matchPicklist(spec.apiName, (String) val);
                if (canonical == null) {
                    problems.add(problem(spec.label, '"' + val + '" is not a valid option. Choose one of: '
                        + OpportunityCloseService.picklistOptions(spec.apiName) + '.'));
                } else {
                    v.put(spec.key, canonical);
                }
            } else if (spec.kind == 'email') {
                if (!OpportunityCloseService.isValidEmail((String) val)) {
                    problems.add(problem(spec.label, 'Please provide a valid email address (e.g. billing@example.com).'));
                }
            } else if (spec.key == 'billingNotes' && ((String) val).length() > 255) {
                problems.add(problem(spec.label, 'Must be under 255 characters. Short and sweet.'));
            }
        }
        Date startDate = (Date) v.get('contractStartDate');
        Date endDate = (Date) v.get('contractEndDate');
        if (startDate != null && endDate != null && !(endDate > startDate)) {
            problems.add(problem('Contract End Date', 'Must be after the Contract Start Date.'));
        }
        return problems;
    }

    private static OpportunityCloseService.Row problem(String label, String message) {
        return new OpportunityCloseService.Row(label, message, 'alert-circle', 'error');
    }

    private static String display(OpportunityCloseService.FieldSpec spec, Object val) {
        if (spec.kind == 'currency') {
            return OpportunityCloseService.formatCurrency((Decimal) val);
        }
        if (spec.kind == 'number') {
            return OpportunityCloseService.formatNumber((Decimal) val);
        }
        if (spec.kind == 'date') {
            return OpportunityCloseService.formatDate((Date) val);
        }
        if (spec.kind == 'boolean') {
            return OpportunityCloseService.formatBoolean((Boolean) val);
        }
        return OpportunityCloseService.textOrNotSet((String) val);
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
        r.lobChoices = new List<OpportunityCloseService.Choice>();
        r.hasLobChoices = false;
        r.needsSignedDocument = false;
        r.filesUrl = '';
        r.uploadUrl = '';
        r.aiRunning = false;
        r.aiStatusText = '';
        r.refreshPrompt = '';
        r.retryPrompt = '';
        r.confirmPrompt = '';
        r.changePrompt = '';
        return r;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The 15 or 18 character Id of the Opportunity (starts with 006).' required=true)
        public String opportunityId;
        @InvocableVariable(label='Confirm' description='False or blank previews and validates without saving. True writes the values and notifies RevOps. Only set true after the user has reviewed the preview.')
        public Boolean confirm;

        @InvocableVariable(label='LOB/Division' description='Picklist. Options: Investment Banking, Commercial Banking, Corporate Banking, Corporate Finance, Wealth Management, Asset Management, Private Equity, Private Credit, Hedge Fund, Venture Capital / Ventures, Corporate Development, Sales & Trading / Markets.')
        public String lobDivision;
        @InvocableVariable(label='Pricing Structure' description='Picklist. Options: Seats: Unlimited Usage, No Throttling; Seats: Unlimited Usage, with Throttling; Seats: Credit-Based Usage; ELA: Unlimited Usage, No Throttling; ELA: Unlimited Usage, with Throttling; ELA: Credit-Based Usage; Custom.')
        public String pricingStructure;
        @InvocableVariable(label='Deal Description') public String dealDescription;
        @InvocableVariable(label='Purchase Driver' description='Why the customer bought.') public String purchaseDriver;
        @InvocableVariable(label='Rollout Timeline' description='Picklist. Options: Immediate, Delayed, Phased.') public String rolloutTimeline;
        @InvocableVariable(label='Success Criteria') public String successCriteria;
        @InvocableVariable(label='Upsell Potential' description='Picklist. Options: Yes, No, Maybe.') public String upsellPotential;
        @InvocableVariable(label='Implementation Notes') public String implementationNotes;
        @InvocableVariable(label='Key Risks') public String keyRisks;
        @InvocableVariable(label='Amount' description='Opportunity amount in the org currency.') public Decimal amount;
        @InvocableVariable(label='Contract Start Date') public Date contractStartDate;
        @InvocableVariable(label='Contract End Date' description='Must be after the start date.') public Date contractEndDate;
        @InvocableVariable(label='Contract Length (Months)') public Integer contractLengthMonths;
        @InvocableVariable(label='Annual Recurring Revenue') public Decimal annualRecurringRevenue;
        @InvocableVariable(label='Total Contract Value') public Decimal totalContractValue;
        @InvocableVariable(label='License Fee') public Decimal licenseFee;
        @InvocableVariable(label='Platform Connection Fee') public Decimal platformConnectionFee;
        @InvocableVariable(label='Professional Services Fees') public Decimal professionalServicesFees;
        @InvocableVariable(label='Seat Licenses') public Integer seatLicenses;
        @InvocableVariable(label='Payment Terms' description='Picklist. Options: Annual, Semi-Annual, Quarterly, Monthly.') public String paymentTerms;
        @InvocableVariable(label='Credit Terms' description='Picklist. Options: Net-15, Net-30, Net-45, Net-60.') public String creditTerms;
        @InvocableVariable(label='Billing Notes' description='Under 255 characters.') public String billingNotes;
        @InvocableVariable(label='Billing Contact Email') public String billingContactEmail;
        @InvocableVariable(label='Renewal Terms' description='Picklist. Options: Auto-renew (90-day), Auto-renew (60-day), Auto-renew (30-day), Manual renewal.') public String renewalTerms;
        @InvocableVariable(label='ELA' description='True when this is an enterprise license agreement.') public Boolean isEla;
        @InvocableVariable(label='Opt Out' description='True when the contract has an opt-out clause.') public Boolean optOut;
        @InvocableVariable(label='Opt-Out Date' description='Required when Opt Out is true.') public Date optOutDate;
        @InvocableVariable(label='Willing to Provide References' description='Whether the account is willing to act as a reference. Saved on the Account.') public Boolean willingToProvideReferences;
    }

    public class Response {
        @InvocableVariable(label='Opportunity Id') public String opportunityId;
        @InvocableVariable(label='Opportunity Name') public String opportunityName;
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Status' description='ReadyToSubmit, Blocked, Submitted, AlreadyClosed, or NotFound.') public String status;
        @InvocableVariable(label='Status Label') public String statusLabel;
        @InvocableVariable(label='Status Variant' description='Badge variant: success, warning, error, or info.') public String statusVariant;
        @InvocableVariable(label='Headline') public String headline;
        @InvocableVariable(label='Message' description='Plain-English explanation of what happened or what to do next.') public String message;
        @InvocableVariable(label='Is Preview' description='True when nothing was saved and the user should confirm.') public Boolean isPreview;
        @InvocableVariable(label='Is Submitted') public Boolean isSubmitted;
        @InvocableVariable(label='Is Blocked') public Boolean isBlocked;
        @InvocableVariable(label='Has Problems') public Boolean hasProblems;
        @InvocableVariable(label='Problems' description='Validation problems that block submission. Each has the field label and the issue.') public List<OpportunityCloseService.Row> problems;
        @InvocableVariable(label='Rows' description='The values that were (or would be) written, as label/value pairs.') public List<OpportunityCloseService.Row> rows;
        @InvocableVariable(label='Has AI Recommendation' description='Always false for Closed Won; present so the same card renders Won and Lost.') public Boolean hasRecommendation;
        @InvocableVariable(label='AI Summary' description='AI win summary written to the opportunity on submit, when available.') public String aiSummary;
        @InvocableVariable(label='Recommended Reason' description='Not used for Closed Won.') public String recommendedReason;
        @InvocableVariable(label='Recommended Competitor' description='Not used for Closed Won.') public String recommendedCompetitor;
        @InvocableVariable(label='Recommended Narrative' description='Not used for Closed Won.') public String recommendedNarrative;
        @InvocableVariable(label='AI Confidence' description='AI win confidence when available.') public String aiConfidence;
        @InvocableVariable(label='AI Failed' description='True when the AI analysis could not run.') public Boolean aiFailed;
        @InvocableVariable(label='AI Failure Reason' description='Why the AI win analysis is unavailable, when it failed.') public String aiFailureReason;
        @InvocableVariable(label='Loss Reason Choices' description='Always empty for Closed Won; present so the same card renders Won and Lost.') public List<OpportunityCloseService.Choice> reasonChoices;
        @InvocableVariable(label='Has Loss Reason Choices' description='Always false for Closed Won.') public Boolean hasReasonChoices;
        @InvocableVariable(label='LOB/Division Choices' description='Buttons for LOB/Division when it was not set explicitly: the account-based suggestion first, then common LOBs.') public List<OpportunityCloseService.Choice> lobChoices;
        @InvocableVariable(label='Has LOB/Division Choices') public Boolean hasLobChoices;
        @InvocableVariable(label='Needs Signed Document' description='True when submission is blocked because no signed order form is attached.') public Boolean needsSignedDocument;
        @InvocableVariable(label='Files URL' description='Link to the opportunity Files related list in Salesforce.') public String filesUrl;
        @InvocableVariable(label='Upload URL' description='Link to the Deal Portal upload page for the signed order form, or the Files list when not configured.') public String uploadUrl;
        @InvocableVariable(label='AI Running' description='True after submit while the background AI win summary is being generated.') public Boolean aiRunning;
        @InvocableVariable(label='AI Status Text' description='Plain-English progress of the background AI analysis.') public String aiStatusText;
        @InvocableVariable(label='Confirm Prompt') public String confirmPrompt;
        @InvocableVariable(label='Change Prompt') public String changePrompt;
        @InvocableVariable(label='Refresh Prompt' description='Not used for Closed Won; present so the same card renders Won and Lost.') public String refreshPrompt;
        @InvocableVariable(label='Retry Prompt' description='Not used for Closed Won; present so the same card renders Won and Lost.') public String retryPrompt;
        @InvocableVariable(label='Opportunity URL') public String opportunityUrl;


        public void forOpportunity(Opportunity opp) {
            opportunityId = opp.Id;
            opportunityName = opp.Name;
            accountName = opp.Account == null ? OpportunityCloseService.NOT_SET : opp.Account.Name;
            opportunityUrl = OpportunityCloseService.recordUrl(opp.Id);
            filesUrl = OpportunityCloseService.filesUrl(opp.Id);
            uploadUrl = OpportunityCloseService.uploadUrl(opp.Id);
        }

        public Response notFound(String requested) {
            opportunityName = 'Opportunity not found';
            accountName = String.isBlank(requested) ? 'No Opportunity Id was provided' : 'No opportunity with Id ' + requested;
            opportunityUrl = URL.getOrgDomainUrl().toExternalForm();
            filesUrl = opportunityUrl;
            uploadUrl = opportunityUrl;
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
