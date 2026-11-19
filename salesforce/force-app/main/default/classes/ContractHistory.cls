/**
 * The running history of a contract (Contract.Contract_History__c): new
 * business or renewal, then every upsell, downsell and restructure in order -
 * what each bought or changed - and the open items. Claude writes it from the
 * facts assembled here (the contract's terms, each applied deal's extraction,
 * the Contract Term Changes and the billing split). The facts are hashed with
 * the model and prompt version, so a history is only rewritten when they change
 * (ContractHistoryJob). Model: Order_Form_Review_Setting__mdt History_Model__c
 * (blank = no history is written).
 */
public with sharing class ContractHistory {

    public static final String PROMPT_VERSION = 'contract-history-v1';
    private static final Set<String> APPLICABLE = new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };

    @TestVisible
    private static final String SYSTEM_PROMPT =
        'You write the running history of one customer contract for Rogo\'s revenue, finance and legal teams. You are '
        + 'given the contract\'s current terms, every deal applied to it in order (new business or renewal first, then '
        + 'upsells, downsells and restructures) with the figures from each deal\'s order form, the contract term '
        + 'changes (terms a later deal added or would change, legal\'s decisions on them, and flags), and any billing '
        + 'split.\n\n'
        + 'Write:\n'
        + '1. One short paragraph per deal, oldest first, starting with its close date and deal name: what kind of deal '
        + 'it was, its term, the seats, fees and credits it bought or added, any credit transition period, and the '
        + 'terms it added or changed (with legal\'s decision where there is one). Use the order form figures exactly as '
        + 'given and say they are per the order form. Never compute totals, ARR or anything else that is not given.\n'
        + '2. "Where it stands:" one or two sentences on the contract today - its term, credit allocation and key legal '
        + 'terms, as given.\n'
        + '3. "Open items:" a dash list of the Open term changes and flags (the term, the contract\'s value and the new '
        + 'value, and the deal), or "None."\n\n'
        + 'Use only the facts given; leave out anything that is not there rather than guess. Plain text: no markdown '
        + 'headings or bold. Under 350 words.';

    public static String model() {
        Order_Form_Review_Setting__mdt s = OrderFormReviewer.settings();
        return s == null ? null : s.History_Model__c;
    }

    public static String hashOf(String factText, String modelName) {
        return OrderFormReviewer.sha256(PROMPT_VERSION + '\n' + modelName + '\n' + factText);
    }

    /** The facts a history is written from, as labelled lines (stable: no timestamps). */
    public static String facts(Id contractId) {
        List<Contract> cs = [
            SELECT Id, ContractNumber, Account.Name, Status, StartDate, EndDate, ContractTerm, Billing_Entity_Name__c,
                   Split_Billing__c, Renewal_Terms__c, Renewal_Fee_Escalator__c, Payment_Terms__c, Credit_Terms__c,
                   Credit_Transition_End_Date__c, Credits_Per_Year__c, Credit_Rate__c, Total_Credits_Purchased__c,
                   Overage_Rate__c, Credit_Rollover__c, Model_Change_Requirement__c, Subprocessor_Notice_Period__c,
                   Seat_Adds_By_Email__c, ELA__c, Credit_Commit__c, Needs_Legal_Review__c, Special_Terms__c
            FROM Contract WHERE Id = :contractId
        ];
        if (cs.isEmpty()) return '';
        Contract c = cs[0];
        List<String> out = new List<String>();
        out.add('CONTRACT ' + c.ContractNumber + (c.Account == null ? '' : ' - ' + c.Account.Name));
        add(out, 'Status', c.Status);
        add(out, 'Term', (c.StartDate == null ? '?' : String.valueOf(c.StartDate)) + ' to '
            + (c.EndDate == null ? '?' : String.valueOf(c.EndDate))
            + (c.ContractTerm == null ? '' : ' (' + c.ContractTerm + ' months)'));
        add(out, 'Contracting / billing entity', c.Billing_Entity_Name__c);
        add(out, 'Renewal', c.Renewal_Terms__c);
        add(out, 'Renewal fee escalator %', c.Renewal_Fee_Escalator__c);
        add(out, 'Payment schedule', c.Payment_Terms__c);
        add(out, 'Payment terms', c.Credit_Terms__c);
        add(out, 'Credits per year', c.Credits_Per_Year__c);
        add(out, 'Blended credit rate', c.Credit_Rate__c);
        add(out, 'Total credits purchased', c.Total_Credits_Purchased__c);
        add(out, 'Overage rate', c.Overage_Rate__c);
        add(out, 'Credit transition period ends', c.Credit_Transition_End_Date__c);
        add(out, 'Credit rollover', c.Credit_Rollover__c);
        add(out, 'Model changes', c.Model_Change_Requirement__c);
        add(out, 'Subprocessor notice days', c.Subprocessor_Notice_Period__c);
        if (c.ELA__c == true) out.add('- ELA: yes');
        if (c.Credit_Commit__c == true) out.add('- Credit commitment: yes');
        if (c.Seat_Adds_By_Email__c == true) out.add('- Seats can be added by email: yes');
        if (c.Needs_Legal_Review__c == true) out.add('- Needs legal review: yes');
        if (String.isNotBlank(c.Special_Terms__c)) add(out, 'Special terms', c.Special_Terms__c.left(1500));

        out.add('');
        out.add('DEALS (oldest first)');
        Integer n = 0;
        for (Order_Form_Extraction__c d : [
            SELECT Name, Opportunity__r.Name, Opportunity__r.Type, Opportunity__r.CloseDate, Extraction_Status__c,
                   Source_Document_Type__c, Contract_Start_Date__c, Contract_End_Date__c, Contract_Length_Months__c,
                   Seat_Licenses__c, Seats_Added__c, Arvo_Seats__c, License_Fees__c, Platform_Connection_Fee__c,
                   Professional_Service_Fees__c, Annual_Recurring_Revenue__c, Incremental_ARR__c,
                   Total_Contract_Value__c, Credits_Purchased__c, Credits_Added__c, Credits_Period__c,
                   Credit_Commit_Fee__c, Free_Credits__c, Credit_Transition_End_Date__c, Renewal_Terms__c,
                   Payment_Terms__c, Billing_Entity_Name__c, Signature_Date__c, Contract_Flags__c
            FROM Order_Form_Extraction__c
            WHERE Applied_Contract__c = :contractId AND Is_Current__c = true AND Extraction_Status__c IN :APPLICABLE
            ORDER BY Opportunity__r.CloseDate ASC NULLS FIRST, Opportunity__r.CreatedDate ASC
        ]) {
            n++;
            out.add('Deal ' + n + ': ' + (d.Opportunity__r == null ? d.Name : d.Opportunity__r.Name)
                + (d.Opportunity__r == null ? '' : ' (' + d.Opportunity__r.Type + ', closed '
                    + String.valueOf(d.Opportunity__r.CloseDate) + ')'));
            add(out, 'Paper', d.Source_Document_Type__c + (d.Signature_Date__c == null ? '' : ', signed '
                + String.valueOf(d.Signature_Date__c)));
            if (d.Extraction_Status__c != 'Success') add(out, 'Read status', d.Extraction_Status__c);
            add(out, 'Term', (d.Contract_Start_Date__c == null ? '' : String.valueOf(d.Contract_Start_Date__c))
                + (d.Contract_End_Date__c == null ? '' : ' to ' + String.valueOf(d.Contract_End_Date__c))
                + (d.Contract_Length_Months__c == null ? '' : ' (' + d.Contract_Length_Months__c + ' months)'));
            add(out, 'Seats (total)', d.Seat_Licenses__c);
            add(out, 'Seats added', d.Seats_Added__c);
            add(out, 'Meeting assistant (Arvo) seats', d.Arvo_Seats__c);
            add(out, 'License / platform fees per year', d.License_Fees__c);
            add(out, 'Platform connection fee', d.Platform_Connection_Fee__c);
            add(out, 'Professional services fees', d.Professional_Service_Fees__c);
            add(out, 'ARR per the order form', d.Annual_Recurring_Revenue__c);
            add(out, 'Incremental ARR per the order form', d.Incremental_ARR__c);
            add(out, 'Total contract value per the order form', d.Total_Contract_Value__c);
            add(out, 'Credits purchased', d.Credits_Purchased__c == null ? null
                : d.Credits_Purchased__c.format() + (d.Credits_Period__c == null ? '' : ' per ' + d.Credits_Period__c));
            add(out, 'Credits added', d.Credits_Added__c == null ? null
                : d.Credits_Added__c.format() + (d.Credits_Period__c == null ? '' : ' per ' + d.Credits_Period__c));
            add(out, 'Credit commitment fee per year', d.Credit_Commit_Fee__c);
            add(out, 'Complimentary credits', d.Free_Credits__c);
            add(out, 'Credit transition period ends', d.Credit_Transition_End_Date__c);
            add(out, 'Renewal', d.Renewal_Terms__c);
            add(out, 'Payment schedule', d.Payment_Terms__c);
            add(out, 'Entity on the paper', d.Billing_Entity_Name__c);
            add(out, 'Flags', d.Contract_Flags__c);
        }
        if (n == 0) out.add('(no deals applied yet)');

        List<String> changes = new List<String>();
        for (Contract_Term_Change__c t : [
            SELECT Change_Type__c, Status__c, Term__c, Base_Value__c, New_Value__c, Opportunity__r.Name, Deal_Date__c,
                   Decision_Note__c
            FROM Contract_Term_Change__c WHERE Contract__c = :contractId
            ORDER BY Deal_Date__c ASC NULLS FIRST, Name ASC
        ]) {
            changes.add('- ' + t.Change_Type__c + ' / ' + t.Status__c + ': ' + t.Term__c
                + (t.Base_Value__c == null ? '' : ' - contract "' + t.Base_Value__c.left(300) + '"')
                + (t.New_Value__c == null ? '' : ' -> deal "' + t.New_Value__c.left(300) + '"')
                + (t.Opportunity__r == null ? '' : ' (' + t.Opportunity__r.Name + ')')
                + (String.isBlank(t.Decision_Note__c) ? '' : ' Note: ' + t.Decision_Note__c.left(300)));
        }
        out.add('');
        out.add('CONTRACT TERM CHANGES');
        if (changes.isEmpty()) out.add('(none)');
        else out.addAll(changes);

        List<String> splits = new List<String>();
        for (Billing_Split__c b : [
            SELECT Entity_Name__c, Seats__c, Annual_Amount__c, Status__c FROM Billing_Split__c
            WHERE Contract__c = :contractId ORDER BY Name
        ]) {
            splits.add('- ' + b.Entity_Name__c + (b.Seats__c == null ? '' : ', ' + b.Seats__c + ' seats')
                + (b.Annual_Amount__c == null ? '' : ', ' + b.Annual_Amount__c + ' per year')
                + (b.Status__c == null ? '' : ' (' + b.Status__c + ')'));
        }
        if (!splits.isEmpty()) {
            out.add('');
            out.add('BILLING SPLIT');
            out.addAll(splits);
        }
        return String.join(out, '\n');
    }

    private static void add(List<String> out, String label, Object value) {
        if (value == null) return;
        String s = value instanceof Decimal ? ((Decimal) value).stripTrailingZeros().toPlainString() : String.valueOf(value);
        if (String.isBlank(s) || s.trim() == '?' || s.trim() == 'null') return;
        out.add('- ' + label + ': ' + s.trim());
    }

    /** Claude's history for these facts. Throws on an API error or an empty answer. */
    public static String write(String factText, String modelName, Integer timeoutMs) {
        Map<String, Object> body = new Map<String, Object>{
            'model' => modelName,
            'max_tokens' => 2000,
            'output_config' => new Map<String, Object>{ 'effort' => 'low' },
            'system' => SYSTEM_PROMPT,
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => 'Contract facts:\n\n' + factText }
            }
        };
        HttpResponse resp = OrderFormExtractionJob.callAnthropic(JSON.serialize(body), null, timeoutMs);
        if (resp.getStatusCode() != 200) {
            throw new HistoryException('HTTP ' + resp.getStatusCode() + ': ' + resp.getBody().left(200));
        }
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
        List<String> texts = new List<String>();
        Object content = envelope.get('content');
        if (content instanceof List<Object>) {
            for (Object block : (List<Object>) content) {
                if (!(block instanceof Map<String, Object>)) continue;
                Map<String, Object> b = (Map<String, Object>) block;
                if (b.get('type') == 'text' && b.get('text') != null) texts.add(String.valueOf(b.get('text')));
            }
        }
        String text = String.join(texts, '\n').trim();
        if (String.isBlank(text)) throw new HistoryException('The model returned no text (stop reason '
            + envelope.get('stop_reason') + ').');
        return text;
    }

    public class HistoryException extends Exception {}
}
