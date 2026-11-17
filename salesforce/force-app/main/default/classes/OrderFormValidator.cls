/**
 * Deterministic checks on a saved Order_Form_Extraction__c and its product lines
 * - no model involved. They run before every review (their results go to the
 * reviewer as input and onto the review record) and decide part of the review
 * status. Separate from Extraction_Status__c, which only says whether the
 * extraction ran and found an order form.
 *
 *  - response schema: the model's JSON against the prompt's keys and types
 *  - permitted values and Salesforce mapping (Contract / Opportunity picklists)
 *  - provenance: a saved value with no stated source must be derived, and say how
 *  - calculations: lines vs ARR, the fee split, TCV vs the committed fees
 *  - product lines: arithmetic, double seat multiplication, optional / contingent
 *    items counted as committed revenue, basis and quantity scope
 *  - currency, field capacity (cut text / rounded numbers kept in full?)
 *  - evidence: emails verbatim in their quotes, quotes free of interpretation,
 *    renewal notice and escalator conditions borne out by the clause
 *  - saved vs proposed: the stored reply re-read with the current code, compared
 *    with what is saved, allowing the documented normalisations
 *
 * Check status: Fail (a wrong or unsupported value), Warn (a person should look),
 * Pass. Result status: Fail / Warnings / Pass.
 */
public with sharing class OrderFormValidator {

    public class Check {
        public String name;
        public String status;
        public String stage;
        public String field;
        public String productRef;
        public String message;
        public Check(String name, String status, String stage, String field, String productRef, String message) {
            this.name = name;
            this.status = status;
            this.stage = stage;
            this.field = field;
            this.productRef = productRef;
            this.message = message;
        }
    }

    public class Result {
        public List<Check> checks = new List<Check>();
        public String status = 'Pass';
        public Integer failures = 0;
        public Integer warnings = 0;

        public void add(Check c) {
            checks.add(c);
            if (c.status == 'Fail') { failures++; status = 'Fail'; }
            else if (c.status == 'Warn') { warnings++; if (status != 'Fail') status = 'Warnings'; }
        }

        public List<Check> problems() {
            List<Check> out = new List<Check>();
            for (Check c : checks) if (c.status != 'Pass') out.add(c);
            return out;
        }
    }

    public static final String FAIL = 'Fail';
    public static final String WARN = 'Warn';
    public static final String PASS = 'Pass';
    private static final String S_EXTRACTION = 'Extraction';
    private static final String S_CALCULATION = 'Calculation';
    private static final String S_MAPPING = 'Mapping';
    private static final String S_PERSISTENCE = 'Persistence';
    private static final Set<String> AMEND_TYPES = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

    // Saved field -> the raw key the model states it in. A saved value whose raw
    // key is empty must be derived (Derived_Fields__c / End_Date_Source__c).
    @TestVisible private static final Map<String, String> RAW_KEY = new Map<String, String>{
        'Contract_Start_Date__c' => 'Contract_Start_Date', 'Contract_End_Date__c' => 'Contract_End_Date',
        'Contract_Length_Months__c' => 'Contract_Length_Months', 'Seat_Licenses__c' => 'Seat_Licenses',
        'Seats_Added__c' => 'Seats_Added', 'License_Fees__c' => 'License_Fees',
        'Platform_Connection_Fee__c' => 'Platform_Connection_Fee', 'Total_Contract_Value__c' => 'Total_Contract_Value',
        'Credits_Purchased__c' => 'Credits_Purchased', 'Credits_Added__c' => 'Credits_Added',
        'Credit_Rate__c' => 'Credit_Rate_Stated', 'Credit_Commit_Fee__c' => 'Credit_Commit_Fee',
        'Free_Credits__c' => 'Free_Credits', 'Renewal_Fee_Escalator__c' => 'Renewal_Fee_Escalator_Percent',
        'Overage_Rate__c' => 'Overage_Rate'
    };

    private static final Map<String, String> EMAIL_KEYS = new Map<String, String>{
        'Billing_Contact_Email__c' => 'Billing_Contact_Email', 'Primary_Contact_Email__c' => 'Primary_Contact_Email',
        'Requested_By_Email__c' => 'Requested_By_Email'
    };

    // Picklists that flow to the Contract (ContractLegalTermsApplier) and the Opportunity (OrderFormApplier).
    private static final List<String> CONTRACT_PICKLISTS = new List<String>{
        'Renewal_Terms__c', 'Payment_Terms__c', 'Credit_Terms__c', 'Rate_Limitable__c', 'Credit_Rollover__c',
        'Model_Change_Requirement__c', 'Package_Tier__c', 'Free_Tier_Retained__c', 'Unlimited_Lite__c',
        'Free_Max_Mid_Credits__c'
    };
    private static final List<String> OPPORTUNITY_PICKLISTS = new List<String>{
        'Renewal_Terms__c', 'Subscription_Schedule__c', 'Payment_Terms__c', 'Credit_Terms__c'
    };

    private static final Pattern EMAIL = Pattern.compile('[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}');
    // Words that put an interpretation inside a quote rather than source text.
    private static final Pattern INTERPRETATION = Pattern.compile(
        '(?i)(\\bnote:|\\bapex\\b|\\binferred\\b|\\bwe (derived|computed|assume)|\\bcomputed\\b|\\bthe model\\b'
        + '|no clause (was )?found|not found in the|\\bappears to be\\b|\\bpresumably\\b|\\[sic\\]|\\bi\\.e\\.)');
    // A line for something the customer may buy later or owes only if usage exceeds the commitment.
    private static final Pattern OPTIONAL_OR_CONTINGENT = Pattern.compile(
        '(?i)(overage|in excess of|beyond the (credit )?(allocation|commitment)|if (customer )?exceed|optional'
        + '|may (purchase|add|elect)|at customer\'?s option|per additional|additional (authorized )?users? (may|can) be'
        + '|upon request)');
    private static final Pattern ESCALATOR_CONDITION = Pattern.compile(
        '(?i)(greater of|lesser of|\\bcpi\\b|consumer price|not to exceed|no more than|capped|\\bcap\\b|up to \\d)');

    // ===================================================================

    /**
     * row: the saved extraction (every field in OrderFormReviewCoverage.PAYLOAD_FIELDS
     * and HASH_EXTRA_FIELDS, plus Extracted_JSON__c, Raw_Response__c, Opportunity__c,
     * Content_Document_Id__c, Extraction_Status__c, Document_Classes__c).
     * raw: the model's JSON (null when unreadable). proposed: the stored reply
     * re-read with the current code (null when it could not be).
     */
    public static Result validate(Order_Form_Extraction__c row, List<OrderFormLines.Line> lines,
                                  Map<String, Object> raw, Order_Form_Extraction__c proposed) {
        Result r = new Result();
        if (lines == null) lines = new List<OrderFormLines.Line>();
        Map<String, Object> evidence = evidenceOf(row, raw);
        Set<String> derived = derivedFields(row);

        run(r, 'response_schema', checkSchema(raw));
        run(r, 'permitted_values', checkPermittedValues(row));
        run(r, 'enum_gaps_visible', checkEnumGaps(row, raw));
        run(r, 'salesforce_mapping', checkSalesforceMapping(row));
        run(r, 'provenance', checkProvenance(row, raw, derived, evidence));
        run(r, 'lines_vs_arr', checkLinesVsArr(row, evidence));
        run(r, 'fee_split', checkFeeSplit(row, raw, lines));
        run(r, 'tcv_vs_committed_fees', checkTcv(row));
        run(r, 'line_arithmetic', checkLineArithmetic(lines));
        run(r, 'committed_vs_optional', checkCommitted(lines));
        run(r, 'line_basis_and_period', checkLineBasis(row, lines));
        run(r, 'quantity_scope', checkQuantityScope(row, lines));
        run(r, 'currency', checkCurrency(row, raw, lines));
        run(r, 'field_capacity', checkCapacity(row, raw));
        run(r, 'email_verbatim', checkEmails(row, raw, evidence));
        run(r, 'quotes_are_source_text', checkQuotes(evidence));
        run(r, 'renewal_notice', checkRenewal(row, evidence));
        run(r, 'escalator_condition', checkEscalator(row, evidence));
        run(r, 'extraction_issues', checkIssues(row));
        run(r, 'saved_vs_proposed', checkSavedVsProposed(row, proposed));
        return r;
    }

    private static void run(Result r, String name, List<Check> found) {
        if (found == null || found.isEmpty()) {
            r.add(new Check(name, PASS, null, null, null, 'No problems found.'));
            return;
        }
        for (Check c : found) {
            c.name = name;
            r.add(c);
        }
    }

    private static Check failure(String stage, String field, String productRef, String message) {
        return new Check(null, FAIL, stage, field, productRef, message);
    }

    private static Check warning(String stage, String field, String productRef, String message) {
        return new Check(null, WARN, stage, field, productRef, message);
    }

    // ===== response schema =====

    @TestVisible
    private static List<Check> checkSchema(Map<String, Object> raw) {
        List<Check> out = new List<Check>();
        if (raw == null) {
            out.add(warning(S_EXTRACTION, null, null, 'The model\'s extraction JSON could not be read (Extracted_JSON__c and '
                + 'Raw_Response__c); checks against the raw values were skipped.'));
            return out;
        }
        Set<String> known = new Set<String>(OrderFormExtractionJob.promptSchemaKeys());
        // Keys earlier prompts asked for.
        known.addAll(new Set<String>{ 'Pricing_Structure', 'Annual_Recurring_Revenue' });
        List<String> unknown = new List<String>();
        for (String k : raw.keySet()) if (!known.contains(k)) unknown.add(k);
        if (!unknown.isEmpty() && !known.isEmpty()) {
            unknown.sort();
            out.add(warning(S_EXTRACTION, null, null, 'Keys not in the prompt schema: ' + String.join(unknown, ', ') + '.'));
        }
        for (String k : new List<String>{ 'Seat_Licenses', 'Seats_Added', 'License_Fees', 'Platform_Connection_Fee',
                'Professional_Service_Fees', 'Recurring_Fees_Stated', 'Incremental_Recurring_Fees', 'Unit_Price',
                'Unit_Quantity', 'Total_Contract_Value', 'Credits_Purchased', 'Credits_Added', 'Credit_Rate_Stated',
                'Overage_Rate', 'Credit_Commit_Fee', 'Free_Credits', 'Renewal_Fee_Escalator_Percent',
                'Contract_Length_Months', 'Subprocessor_Notice_Period_Days' }) {
            Object v = raw.get(k);
            if (v != null && toDecimal(v) == null) {
                out.add(failure(S_EXTRACTION, k, null, k + ' should be a number but is "' + clip(String.valueOf(v)) + '".'));
            }
        }
        if (raw.containsKey('Documents') && raw.get('Documents') != null && !(raw.get('Documents') instanceof List<Object>)) {
            out.add(warning(S_EXTRACTION, 'Documents', null, 'Documents is not a list; the file classification was not used.'));
        }
        if (raw.containsKey('Line_Items') && raw.get('Line_Items') != null && !(raw.get('Line_Items') instanceof List<Object>)) {
            out.add(failure(S_EXTRACTION, 'Line_Items', null, 'Line_Items is not a list.'));
        }
        return out;
    }

    // ===== permitted values / enum gaps / Salesforce mapping =====

    @TestVisible
    private static List<Check> checkPermittedValues(Order_Form_Extraction__c row) {
        List<Check> out = new List<Check>();
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap();
        for (String f : OrderFormReviewCoverage.PAYLOAD_FIELDS) {
            Object v = row.get(f);
            if (v == null) continue;
            Schema.SObjectField sf = fields.get(f.toLowerCase());
            if (sf == null) continue;
            Schema.DescribeFieldResult dr = sf.getDescribe();
            if (dr.getType() != Schema.DisplayType.PICKLIST) continue;
            if (!picklistValues(dr).contains(String.valueOf(v))) {
                out.add(failure(S_MAPPING, OrderFormReviewCoverage.nameOf(f), null,
                    '"' + v + '" is not a permitted value of ' + f + '.'));
            }
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkEnumGaps(Order_Form_Extraction__c row, Map<String, Object> raw) {
        List<Check> out = new List<Check>();
        if (raw == null) return out;
        String issues = row.Extraction_Issues__c == null ? '' : row.Extraction_Issues__c;
        for (String key : OrderFormExtractionJob.MAPPED_PICKLISTS.keySet()) {
            String answer = raw.get(key) == null ? null : String.valueOf(raw.get(key));
            String f = OrderFormExtractionJob.MAPPED_PICKLISTS.get(key);
            if (String.isBlank(answer) || row.get(f) != null) continue;
            if (issues.contains(key)) continue;
            out.add(warning(S_MAPPING, OrderFormReviewCoverage.nameOf(f), null, 'The model answered "' + clip(answer)
                + '" for ' + key + '; no permitted value fits, the field is blank and no issue records why.'));
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkSalesforceMapping(Order_Form_Extraction__c row) {
        List<Check> out = new List<Check>();
        mappingInto(out, row, 'Contract', CONTRACT_PICKLISTS);
        mappingInto(out, row, 'Opportunity', OPPORTUNITY_PICKLISTS);
        return out;
    }

    private static void mappingInto(List<Check> out, Order_Form_Extraction__c row, String objectName, List<String> picklists) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
        if (t == null) return;
        Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
        for (String f : picklists) {
            Object v = row.get(f);
            Schema.SObjectField target = fields.get(f.toLowerCase());
            if (v == null || target == null) continue;
            // "Not specified" means the paper is silent: the appliers never write it
            // (ContractLegalTermsApplier.NOT_SPECIFIED), so it never reaches the target.
            if (String.valueOf(v) == 'Not specified') continue;
            Schema.DescribeFieldResult dr = target.getDescribe();
            if (dr.getType() != Schema.DisplayType.PICKLIST || !dr.isRestrictedPicklist()) continue;
            if (!picklistValues(dr).contains(String.valueOf(v))) {
                out.add(failure(S_MAPPING, OrderFormReviewCoverage.nameOf(f), null, '"' + v + '" is not permitted on '
                    + objectName + '.' + f + '; writing it there would fail.'));
            }
        }
    }

    private static Set<String> picklistValues(Schema.DescribeFieldResult dr) {
        Set<String> out = new Set<String>();
        for (Schema.PicklistEntry pe : dr.getPicklistValues()) if (pe.isActive()) out.add(pe.getValue());
        return out;
    }

    // ===== provenance =====

    @TestVisible
    private static List<Check> checkProvenance(Order_Form_Extraction__c row, Map<String, Object> raw, Set<String> derived,
                                               Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        if (raw == null) return out;
        Boolean isDownsell = row.Type__c == 'Downsell';
        for (String f : RAW_KEY.keySet()) {
            Object saved = row.get(f);
            if (saved == null) continue;
            String name = OrderFormReviewCoverage.nameOf(f);
            Boolean isDerived = derived.contains(name) || hasDerivedNote(evidence, name)
                || (f == 'Contract_End_Date__c' && (row.End_Date_Source__c == 'Derived' || row.End_Date_Source__c == 'Normalized'));
            Object stated = raw.get(RAW_KEY.get(f));
            if (stated == null) {
                if (!isDerived) {
                    out.add(failure(S_CALCULATION, name, null, name + ' is saved as ' + fmt(saved) + ' but the extraction states '
                        + 'no value and no derivation is recorded - an unsupported value.'));
                }
                continue;
            }
            if (isDerived || sameValue(saved, stated)) continue;
            // Documented normalisations: a downsell's reductions are stored negative.
            if (isDownsell && (f == 'Seats_Added__c' || f == 'Credits_Added__c') && saved instanceof Decimal
                    && toDecimal(stated) != null && ((Decimal) saved).abs() == toDecimal(stated).abs()) continue;
            // A non-positive stated credit rate is dropped on purpose.
            if (f == 'Credit_Rate__c' && toDecimal(stated) != null && toDecimal(stated) <= 0) continue;
            // A whole-number field rounded, with the exact value kept.
            if (fullValues(row).containsKey(f)) continue;
            out.add(warning(S_PERSISTENCE, name, null, name + ' is saved as ' + fmt(saved) + ' but the extraction stated '
                + fmt(stated) + ' and no derivation is recorded (a later edit?).'));
        }
        return out;
    }

    // ===== calculations =====

    @TestVisible
    private static List<Check> checkLinesVsArr(Order_Form_Extraction__c row, Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        if (row.Lines_Mismatch__c != true) return out;
        String why = derivedNote(evidence, 'Lines_Recurring_Annual');
        out.add(failure(S_CALCULATION, 'Lines_Recurring_Annual', null, why != null ? why
            : 'The product lines\' recurring fees a year (' + fmt(row.Lines_Recurring_Annual__c) + ') do not match the ARR.'));
        return out;
    }

    @TestVisible
    private static List<Check> checkFeeSplit(Order_Form_Extraction__c row, Map<String, Object> raw,
                                             List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        if (raw == null || row.License_Fees__c == null || row.Credit_Commit_Fee__c == null) return out;
        Decimal stated = toDecimal(raw.get('Recurring_Fees_Stated'));
        if (stated == null || (row.Value_Basis__c != null && row.Value_Basis__c != 'Annual')) return out;
        Decimal others = nz(OrderFormLines.annualFor(lines, OrderFormLines.OTHER_RECURRING));
        Decimal parts = row.License_Fees__c + row.Credit_Commit_Fee__c + nz(row.Platform_Connection_Fee__c) + others;
        if ((parts - stated).abs() > 1) {
            out.add(failure(S_CALCULATION, 'Credit_Commit_Fee', null, 'Licence ' + fmt(row.License_Fees__c) + ' + credit commitment '
                + fmt(row.Credit_Commit_Fee__c) + ' + hosting ' + fmt(nz(row.Platform_Connection_Fee__c))
                + (others == 0 ? '' : ' + other lines ' + fmt(others)) + ' = ' + fmt(parts)
                + ', not the stated recurring fees ' + fmt(stated) + '.'));
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkTcv(Order_Form_Extraction__c row) {
        List<Check> out = new List<Check>();
        if (AMEND_TYPES.contains(row.Type__c) || row.Type__c == 'Pilot') return out;
        Decimal tcv = row.Total_Contract_Value__c;
        Decimal arr = row.Annual_Recurring_Revenue__c;
        Decimal months = row.Contract_Length_Months__c;
        if (tcv == null || arr == null || months == null || months <= 0 || arr <= 0) return out;
        Decimal expected = arr * months / 12 + nz(row.Professional_Service_Fees__c);
        if ((tcv - expected).abs() > expected * 0.10) {
            out.add(warning(S_CALCULATION, 'Total_Contract_Value', null, 'TCV ' + fmt(tcv) + ' is not the committed fees over '
                + 'the term: ARR ' + fmt(arr) + ' x ' + fmt(months) + ' months / 12'
                + (row.Professional_Service_Fees__c == null ? '' : ' + services ' + fmt(row.Professional_Service_Fees__c))
                + ' = ' + fmt(expected.setScale(2, RoundingMode.HALF_UP)) + '.'));
        }
        return out;
    }

    // ===== product lines =====

    @TestVisible
    private static List<Check> checkLineArithmetic(List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        for (OrderFormLines.Line l : lines) {
            if (l.amount == null || l.unitPrice == null || l.quantity == null || l.quantity == 0) continue;
            Decimal extended = l.unitPrice * l.quantity;
            Decimal tolerance = Math.max((Decimal) 1, l.amount.abs() * 0.01);
            if ((l.amount - extended).abs() <= tolerance) continue;
            String ref = OrderFormReviewCoverage.productRef(l);
            if (l.quantity > 1 && (l.amount - extended * l.quantity).abs() <= tolerance) {
                out.add(failure(S_CALCULATION, null, ref, 'Amount ' + fmt(l.amount) + ' is the unit price ' + fmt(l.unitPrice)
                    + ' multiplied by the ' + fmt(l.quantity) + ' seats twice.'));
            } else {
                out.add(warning(S_EXTRACTION, null, ref, 'Amount ' + fmt(l.amount) + ' is not unit price ' + fmt(l.unitPrice)
                    + ' x ' + fmt(l.quantity) + ' = ' + fmt(extended) + ' (a discount, or a misread).'));
            }
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkCommitted(List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        for (OrderFormLines.Line l : lines) {
            Boolean byName = l.label != null && OPTIONAL_OR_CONTINGENT.matcher(l.label).find();
            Boolean byQuote = l.quote != null && OPTIONAL_OR_CONTINGENT.matcher(l.quote).find();
            if (!byName && !byQuote) continue;
            Boolean counted = l.recurring == true || (l.annualAmount != null && l.annualAmount != 0);
            if (!counted && l.amount == null) continue;
            // The line's own name is a strong signal; wording in its quote may be a
            // committed line that also mentions an option (warn only).
            String msg = 'Line "' + clip(l.label) + '" ' + (byName ? 'is named as' : 'is quoted with wording of')
                + ' an optional future purchase or contingent usage charge but is counted as current committed revenue.';
            out.add(byName ? failure(S_CALCULATION, null, OrderFormReviewCoverage.productRef(l), msg)
                : warning(S_CALCULATION, null, OrderFormReviewCoverage.productRef(l), msg));
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkLineBasis(Order_Form_Extraction__c row, List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        for (OrderFormLines.Line l : lines) {
            String ref = OrderFormReviewCoverage.productRef(l);
            if (l.recurring == true && l.basis == 'One-time') {
                out.add(failure(S_CALCULATION, null, ref, 'A one-time line is counted as recurring.'));
            }
            Boolean credits = l.product != null && l.product.endsWith('Credits');
            if (credits && l.quantity != null && l.period == null) {
                out.add(warning(S_EXTRACTION, null, ref, 'Credits line with no period; its credits a year cannot be worked out.'));
            }
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkQuantityScope(Order_Form_Extraction__c row, List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        Boolean isAmend = AMEND_TYPES.contains(row.Type__c);
        if (row.Type__c == 'Upsell' && row.Seat_Licenses__c != null && row.Seats_Added__c != null
                && row.Resulting_Seats__c != null && row.Resulting_Seats__c < row.Seats_Added__c) {
            out.add(failure(S_CALCULATION, 'Resulting_Seats', null, 'Seats after the upsell (' + fmt(row.Resulting_Seats__c)
                + ') are fewer than the seats it adds (' + fmt(row.Seats_Added__c) + ').'));
        }
        Decimal seatLines;
        for (OrderFormLines.Line l : lines) {
            if (!isAmend && l.change == 'Added') {
                out.add(warning(S_EXTRACTION, null, OrderFormReviewCoverage.productRef(l), 'Line marked "Added" on a '
                    + (row.Type__c == null ? 'deal' : row.Type__c) + ' that is not an amendment.'));
            }
            if (l.product == 'Rogo Seats' && l.quantity != null && l.change != 'Added') {
                seatLines = (seatLines == null ? 0 : seatLines) + l.quantity;
            }
        }
        if (!isAmend && seatLines != null && row.Seat_Licenses__c != null && seatLines != row.Seat_Licenses__c) {
            out.add(warning(S_EXTRACTION, 'Seat_Licenses', null, 'The Rogo seat lines count ' + fmt(seatLines)
                + ' seats; Seat_Licenses is ' + fmt(row.Seat_Licenses__c) + '.'));
        }
        return out;
    }

    // ===== currency =====

    @TestVisible
    private static List<Check> checkCurrency(Order_Form_Extraction__c row, Map<String, Object> raw,
                                             List<OrderFormLines.Line> lines) {
        List<Check> out = new List<Check>();
        String cur = raw == null || raw.get('Currency') == null ? null : String.valueOf(raw.get('Currency')).trim();
        if (String.isNotBlank(cur) && cur.toUpperCase() != 'USD') {
            out.add(failure(S_MAPPING, 'Currency', null, 'The paper prices in ' + cur + '; the saved amounts are '
                + 'not converted but sit in USD currency fields.'));
            return out;
        }
        if (String.isBlank(cur)) {
            for (OrderFormLines.Line l : lines) {
                if (l.quote != null && (l.quote.contains('£') || l.quote.contains('€') || l.quote.contains('GBP')
                        || l.quote.contains('EUR'))) {
                    out.add(warning(S_MAPPING, 'Currency', OrderFormReviewCoverage.productRef(l), 'The line is priced in a '
                        + 'non-USD currency but no currency is recorded.'));
                    break;
                }
            }
        }
        return out;
    }

    // ===== field capacity =====

    @TestVisible
    private static List<Check> checkCapacity(Order_Form_Extraction__c row, Map<String, Object> raw) {
        List<Check> out = new List<Check>();
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap();
        Map<String, Object> full = fullValues(row);
        for (String key : OrderFormExtractionJob.TEXT_VALUE_FIELDS.keySet()) {
            String f = OrderFormExtractionJob.TEXT_VALUE_FIELDS.get(key);
            Object savedObj = row.get(f);
            if (savedObj == null) continue;
            String saved = String.valueOf(savedObj);
            Schema.SObjectField sf = fields.get(f.toLowerCase());
            Integer cap = sf == null ? null : sf.getDescribe().getLength();
            if (cap == null || cap <= 0) continue;
            String name = OrderFormReviewCoverage.nameOf(f);
            Object stated = raw == null ? null : raw.get(key);
            String statedText = stated == null ? null : ((stated instanceof String) ? (String) stated : JSON.serialize(stated));
            if (statedText != null && statedText.length() > cap) {
                if (!full.containsKey(f)) {
                    out.add(failure(S_PERSISTENCE, name, null, name + ' was cut to ' + cap + ' of ' + statedText.length()
                        + ' characters and the full value is not kept anywhere on the record.'));
                }
            } else if (statedText == null && saved.length() >= cap && !full.containsKey(f)) {
                out.add(warning(S_PERSISTENCE, name, null, name + ' fills its ' + cap + '-character field exactly; it may '
                    + 'have been cut, and no full value is kept.'));
            }
        }
        if (raw != null && row.Renewal_Fee_Escalator__c != null) {
            Decimal stated = toDecimal(raw.get('Renewal_Fee_Escalator_Percent'));
            if (stated != null && stated != row.Renewal_Fee_Escalator__c && !full.containsKey('Renewal_Fee_Escalator__c')) {
                out.add(warning(S_PERSISTENCE, 'Renewal_Fee_Escalator', null, 'The clause states ' + fmt(stated)
                    + '%; the whole-number field saved ' + fmt(row.Renewal_Fee_Escalator__c) + '% and the exact value is not kept.'));
            }
        }
        return out;
    }

    // ===== evidence =====

    @TestVisible
    private static List<Check> checkEmails(Order_Form_Extraction__c row, Map<String, Object> raw, Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        for (String f : EMAIL_KEYS.keySet()) {
            Object v = row.get(f);
            if (v == null) continue;
            String saved = String.valueOf(v);
            String key = EMAIL_KEYS.get(f);
            String name = OrderFormReviewCoverage.nameOf(f);
            if (raw != null && raw.get(key) != null) {
                String stated = String.valueOf(raw.get(key));
                Matcher all = EMAIL.matcher(stated);
                Integer count = 0;
                while (all.find()) count++;
                if (count > 1) out.add(warning(S_MAPPING, name, null, 'The extraction gave several addresses ("' + clip(stated)
                    + '"); only the first, ' + saved + ', was saved.'));
            }
            String quote = quoteOf(evidence, key);
            // No quote (extractions before quotes were required): nothing to compare here; the
            // reviewer reads the address in the source itself.
            if (quote == null) continue;
            if (quote.toLowerCase().contains(saved.toLowerCase())) continue;
            String bare = letters(saved);
            String nearMiss;
            Matcher m = EMAIL.matcher(quote);
            while (m.find()) if (letters(m.group()) == bare) nearMiss = m.group();
            if (nearMiss != null) {
                out.add(failure(S_EXTRACTION, name, null, 'Saved ' + saved + ' but the source writes ' + nearMiss
                    + ' - the punctuation was lost.'));
            } else {
                out.add(warning(S_EXTRACTION, name, null, saved + ' does not appear in its quote.'));
            }
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkQuotes(Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        List<String> keys = new List<String>(evidence.keySet());
        keys.sort();
        for (String key : keys) {
            String quote = quoteOf(evidence, key);
            if (quote == null) continue;
            Matcher m = INTERPRETATION.matcher(quote);
            if (m.find()) {
                out.add(warning(S_EXTRACTION, key, null, 'The quote for ' + key + ' contains interpretation ("' + m.group()
                    + '"), not only source text.'));
                if (out.size() >= 10) break;
            }
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkRenewal(Order_Form_Extraction__c row, Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        String value = row.Renewal_Terms__c;
        if (value == null || !value.startsWith('Auto-renew (')) return out;
        Integer days = Integer.valueOf(value.substringBetween('(', '-day'));
        String note = derivedNote(evidence, 'Renewal_Terms');
        if (note != null && note.contains('so 30-day')) {
            out.add(failure(S_EXTRACTION, 'Renewal_Terms', null, 'The 30-day notice is a default the extractor used to add: '
                + 'the clause states no non-renewal notice period. The value should be blank with an enum-gap issue.'));
            return out;
        }
        String quote = quoteOf(evidence, 'Renewal_Terms');
        if (quote == null) return out;
        Integer stated = OrderFormExtractionJob.statedNonRenewalDays(quote);
        if (stated != days) {
            out.add(warning(S_EXTRACTION, 'Renewal_Terms', null, 'Saved ' + value + ' but the quoted clause '
                + (stated == null ? 'states no non-renewal notice period.' : 'states a ' + stated + '-day non-renewal notice.')));
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkEscalator(Order_Form_Extraction__c row, Map<String, Object> evidence) {
        List<Check> out = new List<Check>();
        if (row.Renewal_Fee_Escalator__c == null || String.isNotBlank(row.Renewal_Fee_Escalator_Terms__c)) return out;
        String quote = quoteOf(evidence, 'Renewal_Fee_Escalator_Percent');
        if (quote == null) quote = quoteOf(evidence, 'Renewal_Fee_Escalator');
        if (quote != null && ESCALATOR_CONDITION.matcher(quote).find()) {
            out.add(warning(S_EXTRACTION, 'Renewal_Fee_Escalator', null, 'The escalator ' + fmt(row.Renewal_Fee_Escalator__c)
                + '% has a cap or condition in its clause that is not kept (Renewal_Fee_Escalator_Terms__c is blank).'));
        }
        return out;
    }

    @TestVisible
    private static List<Check> checkIssues(Order_Form_Extraction__c row) {
        List<Check> out = new List<Check>();
        if (String.isBlank(row.Extraction_Issues__c)) return out;
        List<String> issues = row.Extraction_Issues__c.split('\n');
        out.add(warning(S_EXTRACTION, null, null, issues.size() + ' issue(s) the extraction left for a person: '
            + clip(String.join(issues, ' || '), 1500)));
        return out;
    }

    // ===== saved vs proposed =====

    @TestVisible
    private static List<Check> checkSavedVsProposed(Order_Form_Extraction__c row, Order_Form_Extraction__c proposed) {
        List<Check> out = new List<Check>();
        if (row.Raw_Response__c != null && row.Raw_Response__c.length() >= 131072) {
            out.add(warning(S_PERSISTENCE, null, null, 'The stored reply was cut at the field size, so the saved values could '
                + 'not be re-derived and compared.'));
            return out;
        }
        if (proposed == null) {
            out.add(warning(S_PERSISTENCE, null, null, 'No stored reply to re-derive the saved values from.'));
            return out;
        }
        if (proposed.Extraction_Status__c == 'Parse Failed') {
            out.add(warning(S_PERSISTENCE, null, null, 'The stored reply could not be re-read.'));
            return out;
        }
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Order_Form_Extraction__c.fields.getMap();
        List<String> diffs = new List<String>();
        List<String> names = new List<String>(OrderFormReviewCoverage.PAYLOAD_FIELDS);
        names.add('Line_Items__c');
        for (String f : names) {
            Object saved = row.get(f);
            Object fresh = proposed.get(f);
            if (sameValue(saved, fresh)) continue;
            // Email addresses are not case-sensitive.
            if (EMAIL_KEYS.containsKey(f) && saved instanceof String && fresh instanceof String
                    && ((String) saved).equalsIgnoreCase((String) fresh)) continue;
            // Documented normalisation: text cut to the field, with the full value kept.
            if (saved instanceof String && fresh instanceof String) {
                Schema.SObjectField sf = fields.get(f.toLowerCase());
                Integer cap = sf == null ? null : sf.getDescribe().getLength();
                if (cap != null && ((String) fresh).left(cap).equals((String) saved)) continue;
            }
            diffs.add(OrderFormReviewCoverage.nameOf(f) + ': saved ' + fmt(saved) + ', re-derived ' + fmt(fresh));
        }
        if (!diffs.isEmpty()) {
            out.add(warning(S_PERSISTENCE, null, null, diffs.size() + ' saved value(s) differ from what the current code '
                + 'derives from the stored reply (a code change since extraction, a person\'s edit, or a later re-align): '
                + clip(String.join(diffs, '; '), 3000)));
        }
        return out;
    }

    // ===================================================================
    // helpers

    public static Map<String, Object> evidenceOf(Order_Form_Extraction__c row, Map<String, Object> raw) {
        if (String.isNotBlank(row.Extract_Evidence__c)) {
            try {
                Object parsed = JSON.deserializeUntyped(row.Extract_Evidence__c);
                if (parsed instanceof Map<String, Object>) return (Map<String, Object>) parsed;
            } catch (Exception e) {
                // Cut at the field size: fall back to the model's own evidence.
            }
        }
        if (raw != null && raw.get('Extract_Evidence') instanceof Map<String, Object>) {
            return (Map<String, Object>) raw.get('Extract_Evidence');
        }
        return new Map<String, Object>();
    }

    public static Set<String> derivedFields(Order_Form_Extraction__c row) {
        Set<String> out = new Set<String>();
        if (String.isBlank(row.Derived_Fields__c)) return out;
        for (String s : row.Derived_Fields__c.split(';')) {
            String t = s.trim();
            if (t.contains('(')) t = t.substringBefore('(');
            if (t != '') out.add(t);
        }
        return out;
    }

    private static Map<String, Object> fullValues(Order_Form_Extraction__c row) {
        if (String.isBlank(row.Full_Text_Values__c)) return new Map<String, Object>();
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(row.Full_Text_Values__c);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static Boolean hasDerivedNote(Map<String, Object> evidence, String key) {
        return derivedNote(evidence, key) != null;
    }

    private static String derivedNote(Map<String, Object> evidence, String key) {
        Object e = evidence.get(key);
        if (!(e instanceof Map<String, Object>)) return null;
        Object d = ((Map<String, Object>) e).get('derived');
        return d == null ? null : String.valueOf(d);
    }

    public static String quoteOf(Map<String, Object> evidence, String key) {
        Object e = evidence.get(key);
        if (!(e instanceof Map<String, Object>)) return null;
        Object q = ((Map<String, Object>) e).get('quote');
        return (q == null || String.isBlank(String.valueOf(q))) ? null : String.valueOf(q);
    }

    @TestVisible
    private static Boolean sameValue(Object a, Object b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) {
            // A blank string and null are the same saved value; so are an unset and a false checkbox.
            Object other = a == null ? b : a;
            if (other instanceof Boolean) return !((Boolean) other);
            return (other instanceof String) && String.isBlank((String) other);
        }
        if (a instanceof Decimal || b instanceof Decimal) {
            Decimal x = toDecimal(a);
            Decimal y = toDecimal(b);
            return x != null && y != null && x.setScale(6, RoundingMode.HALF_UP) == y.setScale(6, RoundingMode.HALF_UP);
        }
        if (a instanceof Date || b instanceof Date) return String.valueOf(a).left(10) == String.valueOf(b).left(10);
        return String.valueOf(a).equals(String.valueOf(b));
    }

    // An address's letters and digits only: what survives a lost hyphen or dot.
    private static String letters(String email) {
        return email == null ? '' : email.toLowerCase().replaceAll('[^a-z0-9@]', '');
    }

    public static String fmt(Object v) {
        if (v == null) return '(blank)';
        if (v instanceof Decimal) return ((Decimal) v).stripTrailingZeros().toPlainString();
        return clip(String.valueOf(v));
    }

    private static String clip(String s) {
        return clip(s, 200);
    }

    private static String clip(String s, Integer n) {
        if (s == null) return '';
        return s.length() > n ? s.left(n - 3) + '...' : s;
    }

    private static Decimal nz(Decimal v) {
        return v == null ? 0 : v;
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        try {
            return Decimal.valueOf(String.valueOf(v).trim());
        } catch (Exception e) {
            return null;
        }
    }
}
