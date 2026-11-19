/**
 * What a review of an Order_Form_Extraction__c must cover, defined in the
 * application rather than left to the model: the saved fields that make up the
 * proposed Salesforce payload, the fields a review must account for on each kind
 * of deal, the product lines, and the sources that must be in front of the
 * reviewer. OrderFormReviewer reports anything required that was not covered or
 * not sent - a review with a gap is Incomplete, never Clear.
 *
 * Field names are the extraction's field API names without "__c"
 * (Renewal_Terms, Annual_Recurring_Revenue); product lines are referenced as
 * L<line number>:<product>, the line's stable identity on its extraction
 * (Order_Form_Line__c.Line_Number__c / Product__c).
 */
public with sharing class OrderFormReviewCoverage {

    // The saved values the review audits - the extraction's Salesforce payload.
    // Also the inputs of the review's Input_Hash__c (with HASH_EXTRA_FIELDS).
    public static final List<String> PAYLOAD_FIELDS = new List<String>{
        'Type__c', 'Is_Amendment__c', 'Source_Document_Type__c',
        'Contract_Start_Date__c', 'Contract_End_Date__c', 'End_Date_Source__c',
        'Contract_Length_Months__c', 'Contract_Length_Days__c',
        'Seat_Licenses__c', 'Seats_Added__c', 'Resulting_Seats__c',
        'Value_Basis__c', 'License_Fees__c', 'Platform_Connection_Fee__c', 'Professional_Service_Fees__c',
        'Total_Contract_Value__c', 'Annual_Recurring_Revenue__c', 'Incremental_ARR__c', 'Base_ARR__c',
        'Resulting_ARR__c',
        'Credits_Purchased__c', 'Credits_Added__c', 'Credits_Period__c', 'Credits_Per_Year__c',
        'Credit_Rate__c', 'Credit_Commit_Fee__c', 'Free_Credits__c', 'Overage_Rate__c', 'Ramp_Schedule__c',
        'Free_Tier_Retained__c', 'Credit_Transition_End_Date__c', 'Credit_Transition_Terms__c',
        'Renewal_Terms__c', 'Renewal_Fee_Escalator__c', 'Renewal_Fee_Escalator_Terms__c',
        'Subscription_Schedule__c', 'Payment_Terms__c', 'Credit_Terms__c',
        'Pricing_Structure__c', 'Package_Tier__c', 'ELA__c', 'Credit_Commit__c', 'Credit_Overcommit_Obligation__c',
        'Rate_Limitable__c', 'Rate_Limit_Notes__c', 'Unlimited_Lite__c', 'Free_Max_Mid_Credits__c',
        'Free_Max_Mid_Amount__c',
        'Paid_Trial__c', 'Trial_Price__c', 'Pilot_Success_Criteria__c',
        'Billing_Contact_Email__c', 'Primary_Contact__c', 'Primary_Contact_Phone__c', 'Primary_Contact_Email__c',
        'Billing_Entity_Name__c', 'Billing_Entity_Review__c', 'Billing_Entity_Reg_Id__c',
        'Billing_Entity_Address__c', 'Billing_Entity_Jurisdiction__c',
        'Signature_Date__c', 'Customer_Signer_Name__c', 'Customer_Signer_Title__c',
        'Named_Users__c', 'Requested_By_Name__c', 'Requested_By_Email__c',
        'Special_Terms__c', 'Logo_Publicity_Rights__c', 'Logo_Publicity_Language__c',
        'Seat_Adds_By_Email__c', 'Seat_Adds_By_Email_Terms__c',
        'Credit_Rollover__c', 'Credit_Rollover_Percent__c', 'Credit_Rollover_Terms__c',
        'Subprocessor_Notice_Period__c', 'Subprocessor_Restrictions__c', 'Sub_Processor_List__c',
        'Resolved_Subprocessor_Term__c', 'Subprocessor_Gate_Type__c', 'Consent_Revocable__c',
        'Subprocessor_Objection_Consequence__c', 'Subprocessor_List_Location__c', 'Subprocessor_List_Granularity__c',
        'AI_Model_Change_Gate_Days__c', 'AI_Model_Change_Documentation__c', 'AI_Model_Change_Carveout__c',
        'AI_Change_Reporting_Trigger__c', 'Model_Change_Requirement__c', 'Model_Change_Terms__c',
        'Processing_Location_Gate__c', 'Approved_Locations__c', 'Personal_Data_Disclosure_Gate__c',
        'Release_Notice_Days__c', 'Release_Major_Notice_Days__c', 'Customer_Can_Defer_Release__c',
        'Material_Change_Notice__c', 'AI_Training_Prohibition__c', 'AI_Training_Flowdown_Required__c',
        'Model_Capability_Floor__c', 'LLM_Gate_Confidence__c',
        'Arvo_Seats__c', 'Free_Seats__c', 'Included_Credits__c', 'Lines_Recurring_Annual__c', 'Lines_Mismatch__c'
    };

    // Payload fields added after reviews were recorded: hashed only when set, so
    // adding them does not make every earlier review look out of date.
    public static final Set<String> HASH_WHEN_SET = new Set<String>{
        'Credit_Transition_End_Date__c', 'Credit_Transition_Terms__c'
    };

    // Also hashed: the product lines, how derived values were computed, the
    // evidence, the issues and the full values of cut fields.
    public static final List<String> HASH_EXTRA_FIELDS = new List<String>{
        'Line_Items__c', 'Derived_Fields__c', 'Extract_Evidence__c', 'Extraction_Issues__c', 'Full_Text_Values__c'
    };

    // Raw keys that have no saved field of their own but may carry a finding.
    public static final List<String> RAW_ONLY_KEYS = new List<String>{
        'Recurring_Fees_Stated', 'Incremental_Recurring_Fees', 'Unit_Price', 'Unit_Quantity', 'Currency',
        'Documents', 'Issues', 'Line_Items', 'Extract_Evidence', 'Customer_Signature_Date', 'Rogo_Signature_Date',
        'Model_Change_Consent', 'Model_Change_Notice', 'Model_Change_Conditional'
    };

    private static final List<String> LEGAL = new List<String>{
        'Renewal_Terms', 'Renewal_Fee_Escalator', 'Payment_Terms', 'Credit_Terms', 'Billing_Entity_Name',
        'Subprocessor_Gate_Type', 'Subprocessor_Notice_Period', 'Sub_Processor_List', 'Model_Change_Requirement',
        'AI_Training_Prohibition', 'Logo_Publicity_Rights', 'Credit_Rollover'
    };
    private static final List<String> ECONOMICS = new List<String>{
        'Type', 'Contract_Start_Date', 'Contract_End_Date', 'Contract_Length_Months', 'Seat_Licenses', 'Value_Basis',
        'License_Fees', 'Platform_Connection_Fee', 'Professional_Service_Fees', 'Total_Contract_Value',
        'Annual_Recurring_Revenue', 'Credits_Purchased', 'Credits_Period', 'Credit_Commit_Fee', 'Free_Credits',
        'Credit_Rate', 'Overage_Rate', 'Billing_Contact_Email', 'Signature_Date'
    };
    private static final List<String> AMENDMENT = new List<String>{
        'Seats_Added', 'Credits_Added', 'Incremental_ARR', 'Resulting_ARR'
    };
    private static final List<String> PILOT = new List<String>{ 'Paid_Trial', 'Trial_Price', 'Pilot_Success_Criteria' };
    // An email-only order states few things; the review confirms nothing else was invented.
    private static final List<String> EMAIL_ONLY = new List<String>{
        'Type', 'Seats_Added', 'Seat_Licenses', 'Named_Users', 'Requested_By_Name', 'Requested_By_Email',
        'Billing_Entity_Name', 'Signature_Date', 'License_Fees', 'Total_Contract_Value', 'Line_Items'
    };
    private static final Set<String> AMEND_TYPES = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

    /** Canonical name of an extraction field: the API name without "__c". */
    public static String nameOf(String fieldApiName) {
        return fieldApiName == null ? null : fieldApiName.removeEnd('__c');
    }

    /** The stable reference of a product line. */
    public static String productRef(OrderFormLines.Line l) {
        return 'L' + l.lineNo + ':' + l.product;
    }

    /** Every name a finding or coverage entry may use: the payload fields, the raw-only keys, the schema keys. */
    public static List<String> allowedFields(List<String> schemaKeys) {
        Set<String> seen = new Set<String>();
        List<String> out = new List<String>();
        for (String f : PAYLOAD_FIELDS) if (seen.add(nameOf(f))) out.add(nameOf(f));
        for (String k : RAW_ONLY_KEYS) if (seen.add(k)) out.add(k);
        if (schemaKeys != null) for (String k : schemaKeys) if (seen.add(k)) out.add(k);
        return out;
    }

    /** The fields a review of this extraction must account for. */
    public static List<String> requiredFields(Order_Form_Extraction__c row) {
        List<String> out = new List<String>();
        Boolean emailOnly = row.Source_Document_Type__c == 'Email Confirmation';
        Boolean hasOrderForm = row.Extraction_Status__c == 'Success' || row.Extraction_Status__c == 'Incomplete';
        if (emailOnly) {
            out.addAll(EMAIL_ONLY);
            return out;
        }
        if (hasOrderForm) {
            out.addAll(ECONOMICS);
            // With product lines, each line is required on its own (requiredProducts);
            // with none, the review must still say whether the paper sells lines.
            String lineItems = row.Line_Items__c;
            if (String.isBlank(lineItems) || lineItems.trim() == '[]') out.add('Line_Items');
            if (AMEND_TYPES.contains(row.Type__c)) out.addAll(AMENDMENT);
            if (row.Type__c == 'Pilot') out.addAll(PILOT);
        }
        for (String f : LEGAL) if (!out.contains(f)) out.add(f);
        return out;
    }

    /** Every product line on the extraction must be reviewed on its own. */
    public static List<String> requiredProducts(List<OrderFormLines.Line> lines) {
        List<String> out = new List<String>();
        if (lines != null) for (OrderFormLines.Line l : lines) out.add(productRef(l));
        return out;
    }

    /**
     * Required sources that were not in front of the reviewer: no current-deal
     * file, an order form the extraction used that was not sent, a file left out
     * that the extraction did not dismiss as incidental, and (amendments) no
     * parent contract. Read failures the reviewer reports are added by the caller.
     */
    public static List<String> missingSources(Order_Form_Extraction__c row, OrderFormExtractionJob.SourceRequest req,
                                              Boolean hasBaseOpportunity) {
        List<String> missing = new List<String>();
        if (req == null || req.body == null || req.sentLabels.isEmpty()) {
            missing.add('No document could be sent to the reviewer.');
            if (req != null) for (String s : req.skipped) missing.add('Not sent: ' + s);
            return missing;
        }
        if (req.currentCount == 0) missing.add('No current-deal document was sent.');

        Set<String> sent = new Set<String>();
        for (String t : req.sentTitles) if (t != null) sent.add(t.toLowerCase());
        Map<String, String> classByTitle = classesByTitle(row.Document_Classes__c);
        for (String title : classByTitle.keySet()) {
            String cls = classByTitle.get(title);
            if (cls.contains('[Current]') && cls.contains('Order Form') && !sent.contains(title)) {
                missing.add('The order form the extraction read was not sent: ' + title);
            }
        }
        for (String s : req.skipped) {
            String title = s.contains(' (') ? s.substringBefore(' (') : s;
            String cls = classByTitle.get(title.toLowerCase());
            // Incidental files the extraction itself classed as Other / MNDA are not required.
            if (cls != null && (cls.endsWith('=> Other') || cls.endsWith('=> MNDA'))) continue;
            missing.add('Not sent: ' + s);
        }
        if (AMEND_TYPES.contains(row.Type__c) && hasBaseOpportunity == true && req.parentCount == 0) {
            missing.add('No parent-contract document was sent for this amendment (the base opportunity\'s contract governs '
                + 'the terms it does not change).');
        }
        return missing;
    }

    // Document_Classes__c lines: "FILE n (CURRENT DEAL): <title> [Current] => Order Form (contains: ...)".
    @TestVisible
    private static Map<String, String> classesByTitle(String documentClasses) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(documentClasses)) return out;
        for (String line : documentClasses.split('\n')) {
            Integer colon = line.indexOf('): ');
            Integer bracket = line.lastIndexOf(' [');
            if (colon < 0 || bracket <= colon) continue;
            String title = line.substring(colon + 3, bracket).trim().toLowerCase();
            out.put(title, line.substring(bracket).trim());
        }
        return out;
    }
}
