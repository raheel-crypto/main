/**
 * Shared logic for the agent-driven Close Opportunity experience.
 *
 * Mirrors the production Close_Opportunity_Button screen flow:
 *  - Closed Won collects the finance + handoff fields, requires a signed order
 *    form already attached to the Opportunity, writes the fields, notifies
 *    RevOps in Slack, and queues order-form extraction. It does NOT stamp
 *    Closed Won; RevOps does that after validating (Contract Restructure is
 *    the exception and closes directly).
 *  - Closed Lost stamps Closed Lost with the reasons, notes, LOB, prior stage,
 *    and the AI loss-analysis fields.
 *
 * Used by GetCloseReadiness, SubmitClosedWon, and SubmitClosedLost.
 */
public with sharing class OpportunityCloseService {

    /** Tests set this to skip the Claude and Slack callouts. */
    @TestVisible
    public static Boolean disableExternalCalls = false;

    public static final String STAGE_WON = 'Closed Won';
    public static final String STAGE_LOST = 'Closed Lost';
    public static final String TYPE_RESTRUCTURE = 'Contract Restructure';
    public static final String SUBMISSION_SOURCE = 'Agent';
    public static final String NOT_SET = 'Not set';

    // ─── Field specification for the Closed Won form ─────────────────────

    public class FieldSpec {
        public String key;      // camelCase name used by the tool inputs
        public String apiName;  // Opportunity field
        public String label;
        public String kind;     // text, longtext, picklist, currency, number, date, boolean, email
        public Boolean required;
        public FieldSpec(String key, String apiName, String label, String kind, Boolean required) {
            this.key = key; this.apiName = apiName; this.label = label; this.kind = kind; this.required = required;
        }
    }

    private static List<FieldSpec> wonSpecs;

    /** The Closed Won fields in the order the screen flow shows them. */
    public static List<FieldSpec> wonFieldSpecs() {
        if (wonSpecs == null) {
            wonSpecs = new List<FieldSpec>{
                new FieldSpec('lobDivision', 'LOB_Division__c', 'LOB/Division', 'picklist', true),
                new FieldSpec('pricingStructure', 'Pricing_Structure__c', 'Pricing Structure', 'picklist', true),
                new FieldSpec('dealDescription', 'Deal_Description__c', 'Deal Description', 'longtext', true),
                new FieldSpec('purchaseDriver', 'Purchase_Driver__c', 'Purchase Driver', 'longtext', true),
                new FieldSpec('rolloutTimeline', 'Rollout_Timeline__c', 'Rollout Timeline', 'picklist', true),
                new FieldSpec('successCriteria', 'Success_Criteria__c', 'Success Criteria', 'longtext', true),
                new FieldSpec('upsellPotential', 'Upsell_Potential__c', 'Upsell Potential', 'picklist', true),
                new FieldSpec('implementationNotes', 'Implementation_Notes__c', 'Implementation Notes', 'longtext', true),
                new FieldSpec('keyRisks', 'Key_Risks__c', 'Key Risks', 'longtext', true),
                new FieldSpec('amount', 'Amount', 'Amount', 'currency', true),
                new FieldSpec('contractStartDate', 'Contract_Start_Date__c', 'Contract Start Date', 'date', true),
                new FieldSpec('contractEndDate', 'Contract_End_Date__c', 'Contract End Date', 'date', true),
                new FieldSpec('contractLengthMonths', 'Contract_Length_Mos__c', 'Contract Length (Months)', 'number', true),
                new FieldSpec('annualRecurringRevenue', 'Annual_Recurring_Revenue__c', 'Annual Recurring Revenue', 'currency', true),
                new FieldSpec('totalContractValue', 'Total_Contract_Value__c', 'Total Contract Value', 'currency', true),
                new FieldSpec('licenseFee', 'License_Fees__c', 'License Fee', 'currency', true),
                new FieldSpec('platformConnectionFee', 'Platform_Connection_Fee__c', 'Platform Connection Fee', 'currency', true),
                new FieldSpec('professionalServicesFees', 'Professional_Service_Fees__c', 'Professional Services Fees', 'currency', true),
                new FieldSpec('seatLicenses', 'Seat_Licenses__c', 'Seat Licenses', 'number', true),
                new FieldSpec('paymentTerms', 'Payment_Terms__c', 'Payment Terms', 'picklist', true),
                new FieldSpec('creditTerms', 'Credit_Terms__c', 'Credit Terms', 'picklist', true),
                new FieldSpec('billingNotes', 'Billing_Notes__c', 'Billing Notes', 'longtext', true),
                new FieldSpec('billingContactEmail', 'Billing_Contact__c', 'Billing Contact', 'email', true),
                new FieldSpec('renewalTerms', 'Renewal_Terms__c', 'Renewal Terms', 'picklist', true),
                new FieldSpec('isEla', 'ELA__c', 'ELA', 'boolean', true),
                new FieldSpec('optOut', 'Opt_Out__c', 'Opt Out', 'boolean', true),
                new FieldSpec('optOutDate', 'Opt_Out_Date__c', 'Opt-Out Date', 'date', false)
            };
        }
        return wonSpecs;
    }

    // ─── Queries ─────────────────────────────────────────────────────────

    public static Opportunity loadOpportunity(Id opportunityId) {
        List<Opportunity> opps = [
            SELECT Id, Name, StageName, IsClosed, IsWon, Amount, CloseDate, Type, OwnerId, Owner.Name,
                   AccountId, Account.Name, Account.Provide_References__c, Account.Business_Type__c,
                   LOB_Division__c, Pricing_Structure__c, Deal_Description__c, Purchase_Driver__c,
                   Rollout_Timeline__c, Success_Criteria__c, Upsell_Potential__c, Implementation_Notes__c,
                   Key_Risks__c, Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Mos__c,
                   Annual_Recurring_Revenue__c, Total_Contract_Value__c, License_Fees__c,
                   Platform_Connection_Fee__c, Professional_Service_Fees__c, Seat_Licenses__c,
                   Payment_Terms__c, Credit_Terms__c, Billing_Notes__c, Billing_Contact__c, Renewal_Terms__c,
                   ELA__c, Opt_Out__c, Opt_Out_Date__c,
                   CL_Primary_Reason__c, CL_Secondary_Reason__c, Final_Competitor__c, CL_Notes__c,
                   CL_Reason_AI__c, CL_Narrative_AI__c, CL_Details_AI__c, CL_Confidence_AI__c,
                   Evidence_Tier_AI__c, Next_Step_AI__c, Agent_AI_Status__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0];
    }

    public static Id parseOpportunityId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSobjectType() == Opportunity.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Titles of documents on the Opportunity that mark a signed order form.
     * The screen flow searches for "__signed" but renames uploads to "signed__",
     * so both prefixes count.
     */
    public static List<String> signedDocumentTitles(Id opportunityId) {
        List<String> titles = new List<String>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :opportunityId
            ORDER BY SystemModstamp DESC
        ]) {
            String t = cdl.ContentDocument.Title;
            if (t != null && (t.toLowerCase().startsWith('__signed') || t.toLowerCase().startsWith('signed__'))) {
                titles.add(t);
            }
        }
        return titles;
    }

    public static Boolean isRestructure(Opportunity opp) {
        return opp != null && opp.Type == TYPE_RESTRUCTURE;
    }

    // ─── Validation helpers ──────────────────────────────────────────────

    /**
     * Returns the canonical active picklist value matching the input
     * (case-insensitive on value or label), or null when it is not valid.
     */
    public static String matchPicklist(String fieldApiName, String input) {
        if (String.isBlank(input)) {
            return null;
        }
        Schema.SObjectField f = Schema.SObjectType.Opportunity.fields.getMap().get(fieldApiName);
        if (f == null) {
            return null;
        }
        String needle = input.trim().toLowerCase();
        for (Schema.PicklistEntry pe : f.getDescribe().getPicklistValues()) {
            if (!pe.isActive()) {
                continue;
            }
            if (pe.getValue().toLowerCase() == needle || pe.getLabel().toLowerCase() == needle) {
                return pe.getValue();
            }
        }
        return null;
    }

    public static String picklistOptions(String fieldApiName) {
        List<String> vals = new List<String>();
        Schema.SObjectField f = Schema.SObjectType.Opportunity.fields.getMap().get(fieldApiName);
        if (f != null) {
            for (Schema.PicklistEntry pe : f.getDescribe().getPicklistValues()) {
                if (pe.isActive()) {
                    vals.add(pe.getValue());
                }
            }
        }
        return String.join(vals, ', ');
    }

    public static Boolean isValidEmail(String email) {
        return String.isNotBlank(email)
            && Pattern.matches('^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$', email.trim());
    }

    // ─── Formatting ──────────────────────────────────────────────────────

    public static String formatCurrency(Decimal amount) {
        if (amount == null) {
            return NOT_SET;
        }
        String symbol = currencySymbol();
        String sign = amount < 0 ? '-' : '';
        return sign + symbol + amount.abs().setScale(0, RoundingMode.HALF_UP).format();
    }

    public static String formatNumber(Decimal n) {
        return n == null ? NOT_SET : n.setScale(0, RoundingMode.HALF_UP).format();
    }

    public static String formatDate(Date d) {
        return d == null ? NOT_SET : d.format();
    }

    public static String formatBoolean(Boolean b) {
        return b == true ? 'Yes' : 'No';
    }

    public static String textOrNotSet(String s) {
        return String.isBlank(s) ? NOT_SET : s;
    }

    public static String currencySymbol() {
        String iso = UserInfo.getDefaultCurrency();
        if (iso == 'USD' || iso == 'CAD' || iso == 'AUD') {
            return '$';
        }
        if (iso == 'EUR') {
            return '€';
        }
        if (iso == 'GBP') {
            return '£';
        }
        return iso == null ? '' : iso + ' ';
    }

    /** Display value of a Closed Won field as currently stored on the record. */
    public static String displayValue(FieldSpec spec, Opportunity opp) {
        Object v = opp.get(spec.apiName);
        if (spec.kind == 'currency') {
            return formatCurrency((Decimal) v);
        }
        if (spec.kind == 'number') {
            return formatNumber((Decimal) v);
        }
        if (spec.kind == 'date') {
            return formatDate((Date) v);
        }
        if (spec.kind == 'boolean') {
            return formatBoolean((Boolean) v);
        }
        return textOrNotSet((String) v);
    }

    public static Boolean hasValue(FieldSpec spec, Opportunity opp) {
        Object v = opp.get(spec.apiName);
        if (spec.kind == 'boolean') {
            return true; // a checkbox always has a value
        }
        if (v == null) {
            return false;
        }
        return !(v instanceof String) || String.isNotBlank((String) v);
    }

    public static String recordUrl(Id recordId) {
        return URL.getOrgDomainUrl().toExternalForm() + '/' + recordId;
    }

    // ─── Prompts the widget buttons send back to the agent ───────────────

    public static String closeWonPrompt(Opportunity opp) {
        return 'Close opportunity ' + opp.Id + ' (' + opp.Name + ') as Closed Won. Run the preview, then ask me for every '
            + 'missing field in a single message, grouped into deal details, contract dates and money, and billing.';
    }

    /** Deep link to the opportunity's Files related list, where the signed order form gets uploaded. */
    public static String filesUrl(Id opportunityId) {
        return URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Opportunity/' + opportunityId + '/related/AttachedContentDocuments/view';
    }

    public static String closeLostPrompt(Opportunity opp) {
        return 'Close opportunity ' + opp.Id + ' (' + opp.Name + ') as Closed Lost. Show me the recommended reason first.';
    }

    public static String confirmWonPrompt(Opportunity opp) {
        return 'Confirm and submit Closed Won for opportunity ' + opp.Id + ' with the values shown in the preview.';
    }

    public static String confirmLostPrompt(Opportunity opp) {
        return 'Confirm and submit Closed Lost for opportunity ' + opp.Id + ' with the values shown in the preview.';
    }

    public static String changePrompt(Opportunity opp) {
        return 'I want to change some values before submitting the close for opportunity ' + opp.Id + '.';
    }

    /** Tail shared by every choice-button prompt: one round trip for whatever is still missing. */
    private static final String ONE_MESSAGE_TAIL =
        ' Keep every other value from the current preview. If anything required is still missing, ask me for all of it in one message.';

    public static String lostReasonPrompt(Opportunity opp, String reason) {
        return 'Close opportunity ' + opp.Id + ' (' + opp.Name + ') as Closed Lost with CL Primary Reason "' + reason
            + '". Keep the recommended competitor and narrative unless I say otherwise, then show me the preview.' + ONE_MESSAGE_TAIL;
    }

    public static String lobPrompt(Opportunity opp, String lob, String mode) {
        return 'Use LOB/Division "' + lob + '" for opportunity ' + opp.Id + ' (' + opp.Name + ') and re-run the Closed ' + mode
            + ' preview.' + ONE_MESSAGE_TAIL;
    }

    public static String moreLobPrompt(Opportunity opp) {
        return 'I want a different LOB/Division for opportunity ' + opp.Id + '. List the LOB/Division options and ask me which one applies.';
    }

    public static String retryAiPrompt(Opportunity opp) {
        return 'Retry the AI loss analysis for opportunity ' + opp.Id + ' (call Submit Closed Lost with retryAi=true) and show me the '
            + 'Closed Lost preview.' + ONE_MESSAGE_TAIL;
    }

    public static String refreshLostPrompt(Opportunity opp) {
        return 'Show me the Closed Lost preview for opportunity ' + opp.Id + ' again; the AI analysis should be done now.' + ONE_MESSAGE_TAIL;
    }

    // ─── Background AI analysis ──────────────────────────────────────────

    /** A running analysis older than this is treated as lost and started again. */
    @TestVisible private static final Integer AI_STALE_MINUTES = 3;

    /** Parsed view of Opportunity.Agent_AI_Status__c. */
    public class AiState {
        public Boolean running = false;
        public Boolean failed = false;
        public String reason;
        public Datetime since;
    }

    public static AiState aiState(Opportunity opp) {
        AiState s = new AiState();
        String raw = opp == null ? null : opp.Agent_AI_Status__c;
        if (String.isBlank(raw)) {
            return s;
        }
        if (raw.startsWith(CloseAiAnalysisJob.RUNNING_PREFIX)) {
            s.since = parseIso(raw.substring(CloseAiAnalysisJob.RUNNING_PREFIX.length()).trim());
            Boolean stale = s.since == null || s.since.addMinutes(AI_STALE_MINUTES) < Datetime.now();
            if (stale) {
                s.failed = true;
                s.reason = 'The previous AI analysis did not finish.';
            } else {
                s.running = true;
            }
        } else if (raw.startsWith(CloseAiAnalysisJob.FAILED_PREFIX)) {
            s.failed = true;
            Integer colon = raw.indexOf(': ');
            s.reason = colon > 0 ? raw.substring(colon + 2) : raw;
        }
        return s;
    }

    private static Datetime parseIso(String iso) {
        try {
            return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Marks the opportunity as analysing and queues the background job. Returns
     * false when the job could not be queued (governor limit), in which case the
     * status is left untouched.
     */
    /** Number of analysis jobs this transaction started; tests read it because org triggers queue jobs of their own. */
    @TestVisible private static Integer aiJobsStarted = 0;

    public static Boolean startAiAnalysis(Opportunity opp, String mode) {
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return false;
        }
        update new Opportunity(Id = opp.Id,
            Agent_AI_Status__c = CloseAiAnalysisJob.RUNNING_PREFIX + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        System.enqueueJob(new CloseAiAnalysisJob(opp.Id, mode));
        aiJobsStarted++;
        return true;
    }

    public static String secondsAgoText(Datetime since) {
        if (since == null) {
            return '';
        }
        Long secs = (Datetime.now().getTime() - since.getTime()) / 1000;
        return ' It started ' + secs + ' seconds ago.';
    }

    public static String otherReasonPrompt(Opportunity opp) {
        return 'I want a different loss reason for opportunity ' + opp.Id + '. List the CL Primary Reason options and ask me which one applies.';
    }

    // ─── Loss reason choice buttons ──────────────────────────────────────

    /** Reasons offered as buttons, ordered by how often closed-lost deals in this org use them. */
    @TestVisible private static final List<String> COMMON_LOSS_REASONS = new List<String>{
        'Bad Fit Disqualified', 'Timing Priority', 'No Show / Buyer Canceled', 'No Need', 'Budget Financial', 'Competitive Loss'
    };
    @TestVisible private static final Integer MAX_REASON_ALTERNATIVES = 3;

    // ─── LOB/Division defaults and choice buttons ────────────────────────

    /**
     * Account Business Type predicts LOB/Division almost one to one in this org
     * (e.g. private_equity -> Private Equity in 1,546 of 1,567 deals), so a blank
     * LOB defaults from it. "other" is deliberately absent: it is too noisy to guess.
     */
    @TestVisible private static final Map<String, String> LOB_BY_BUSINESS_TYPE = new Map<String, String>{
        'private_equity' => 'Private Equity',
        'investment_bank' => 'Investment Banking',
        'Corporate' => 'Corporate Finance',
        'hedge_fund' => 'Hedge Fund',
        'Asset Manager' => 'Asset Management',
        'venture_capital' => 'Venture Capital / Ventures',
        'Private Credit' => 'Private Credit',
        'Consulting Firm' => 'Consulting',
        'Family Office' => 'Wealth Management',
        'Wealth Manager' => 'Wealth Management',
        'Commercial Bank' => 'Commercial Banking'
    };
    /** LOBs offered as buttons, ordered by how often deals in this org use them. */
    @TestVisible private static final List<String> COMMON_LOBS = new List<String>{
        'Private Equity', 'Investment Banking', 'Corporate Finance', 'Hedge Fund', 'Asset Management'
    };
    @TestVisible private static final Integer MAX_LOB_ALTERNATIVES = 4;
    public static final String SUGGESTED_SUFFIX = ' (suggested from account type)';

    /** The LOB/Division the account's Business Type implies, as an active picklist value, or null. */
    public static String suggestLob(Opportunity opp) {
        if (opp == null || opp.Account == null || String.isBlank(opp.Account.Business_Type__c)) {
            return null;
        }
        String lob = LOB_BY_BUSINESS_TYPE.get(opp.Account.Business_Type__c);
        return lob == null ? null : matchPicklist('LOB_Division__c', lob);
    }

    /**
     * "Use suggested: X" first when the account implies an LOB, then up to four
     * common LOBs, then a button that asks the agent to list every option.
     */
    public static List<Choice> lobChoices(Opportunity opp, String suggestedLob, String mode) {
        List<Choice> choices = new List<Choice>();
        Set<String> used = new Set<String>();
        if (String.isNotBlank(suggestedLob)) {
            choices.add(new Choice('Use suggested: ' + suggestedLob, lobPrompt(opp, suggestedLob, mode), 'primary'));
            used.add(suggestedLob);
        }
        Integer alternatives = 0;
        for (String lob : COMMON_LOBS) {
            if (alternatives >= MAX_LOB_ALTERNATIVES) {
                break;
            }
            String canonical = matchPicklist('LOB_Division__c', lob);
            if (canonical == null || used.contains(canonical)) {
                continue;
            }
            choices.add(new Choice(canonical, lobPrompt(opp, canonical, mode), 'secondary'));
            used.add(canonical);
            alternatives++;
        }
        choices.add(new Choice('More LOB options', moreLobPrompt(opp), 'secondary'));
        return choices;
    }

    /**
     * The recommended reason (if any) as the primary choice, then up to three
     * common alternatives, then an "Other reason" button that asks the agent to
     * list every option. Only active picklist values are offered.
     */
    public static List<Choice> lostReasonChoices(Opportunity opp, String recommendedReason) {
        List<Choice> choices = new List<Choice>();
        Set<String> used = new Set<String>();
        Boolean hasRecommendation = String.isNotBlank(recommendedReason) && recommendedReason != NOT_SET
            && matchPicklist('CL_Primary_Reason__c', recommendedReason) != null;
        if (hasRecommendation) {
            String canonical = matchPicklist('CL_Primary_Reason__c', recommendedReason);
            choices.add(new Choice('Use recommended: ' + canonical, lostReasonPrompt(opp, canonical), 'primary'));
            used.add(canonical);
        }
        Integer alternatives = 0;
        for (String reason : COMMON_LOSS_REASONS) {
            if (alternatives >= MAX_REASON_ALTERNATIVES) {
                break;
            }
            String canonical = matchPicklist('CL_Primary_Reason__c', reason);
            if (canonical == null || used.contains(canonical)) {
                continue;
            }
            choices.add(new Choice(canonical, lostReasonPrompt(opp, canonical), 'secondary'));
            used.add(canonical);
            alternatives++;
        }
        choices.add(new Choice('Other reason', otherReasonPrompt(opp), 'secondary'));
        return choices;
    }

    // ─── External calls (Claude analysis, RevOps Slack) ──────────────────

    /**
     * Runs DealScoreAIController in Win or Loss mode. Returns null when external
     * calls are disabled (tests). On failure returns a result with success=false
     * and the reason in summary so the card can show why no recommendation exists.
     */
    public static DealScoreAIController.ForensicResult runAiAnalysis(Id opportunityId, String mode, Boolean writeBackNewFields) {
        if (disableExternalCalls) {
            return null;
        }
        try {
            DealScoreAIController.ForensicRequest req = new DealScoreAIController.ForensicRequest();
            req.opportunityId = opportunityId;
            req.mode = mode;
            req.writeBackNewFields = writeBackNewFields;
            List<DealScoreAIController.ForensicResult> results =
                DealScoreAIController.getForensicAnalysis(new List<DealScoreAIController.ForensicRequest>{ req });
            if (results != null && !results.isEmpty()) {
                // success=false carries the failure reason in summary; callers surface it.
                return results[0];
            }
        } catch (Exception e) {
            DealScoreAIController.ForensicResult failed = new DealScoreAIController.ForensicResult();
            failed.success = false;
            failed.summary = 'AI analysis could not run: ' + e.getTypeName() + ': ' + e.getMessage();
            return failed;
        }
        return null;
    }

    /** Queues the RevOps Slack notification (a callout, so it runs after commit). */
    public static void notifyRevOpsAfterCommit(Id opportunityId) {
        if (disableExternalCalls) {
            return;
        }
        System.enqueueJob(new CloseWonNotificationJob(opportunityId));
    }

    /** Queues order-form extraction, exactly as the screen flow does after success. */
    public static void queueOrderFormExtraction(Id opportunityId) {
        if (disableExternalCalls) {
            return;
        }
        try {
            OrderFormExtractor.Request req = new OrderFormExtractor.Request();
            req.opportunityId = opportunityId;
            OrderFormExtractor.run(new List<OrderFormExtractor.Request>{ req });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Order form extraction not queued: ' + e.getMessage());
        }
    }

    // ─── Shared output row ───────────────────────────────────────────────

    /** A label/value pair rendered as a row in the widgets. */
    public class Row {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String icon;
        @AuraEnabled public String color;
        public Row() {}
        public Row(String label, String value) {
            this.label = label;
            this.value = value;
            this.icon = 'check-circle';
            this.color = 'success';
        }
        public Row(String label, String value, String icon, String color) {
            this.label = label;
            this.value = value;
            this.icon = icon;
            this.color = color;
        }
    }

    /** A button the widget renders; clicking it sends the prompt back to the agent. */
    public class Choice {
        @AuraEnabled public String label;
        @AuraEnabled public String prompt;
        @AuraEnabled public String variant;
        public Choice() {}
        public Choice(String label, String prompt, String variant) {
            this.label = label;
            this.prompt = prompt;
            this.variant = variant;
        }
    }
}
