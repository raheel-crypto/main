@isTest
private class ContractTermChangeTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'CTC_Test_Bypass', Label = 'CTC Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private class Deal {
        Account acct;
        Contract contract;
        Opportunity nb;
        Opportunity up;
        Order_Form_Extraction__c nbRead;
        Order_Form_Extraction__c upRead;
    }

    // A contract with its new business deal and an upsell on it.
    private static Deal deal(Map<String, Object> nbValues, Map<String, Object> upValues) {
        Deal d = new Deal();
        d.acct = new Account(Name = 'Term Change Co');
        insert d.acct;
        d.contract = new Contract(AccountId = d.acct.Id, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        insert d.contract;
        d.nb = new Opportunity(Name = 'TC New Business', StageName = 'Closed Won', AccountId = d.acct.Id,
            Type = 'New Business', CloseDate = Date.today().addDays(-300), ContractId = d.contract.Id);
        insert d.nb;
        d.up = new Opportunity(Name = 'TC Upsell', StageName = 'Closed Won', AccountId = d.acct.Id, Type = 'Upsell',
            CloseDate = Date.today().addDays(-10), Base_Opportunity__c = d.nb.Id);
        insert d.up;
        d.nbRead = read(d.nb.Id, nbValues);
        d.upRead = read(d.up.Id, upValues);
        return d;
    }

    private static Order_Form_Extraction__c read(Id oppId, Map<String, Object> values) {
        Order_Form_Extraction__c r = new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now());
        if (values != null) for (String k : values.keySet()) r.put(k, values.get(k));
        insert r;
        return r;
    }

    private static void rebuild(Contract c) {
        OrderFormOps.rebuild(null, new Set<Id>{ c.Id });
    }

    private static List<Contract_Term_Change__c> changes(Id contractId) {
        return [
            SELECT Id, Change_Type__c, Status__c, Field__c, Term__c, Base_Value__c, New_Value__c, Opportunity__c,
                   Extraction__c, Source_Quote__c, Decided_By__c, Decided_At__c, Decision_Note__c, Key__c
            FROM Contract_Term_Change__c WHERE Contract__c = :contractId ORDER BY Field__c
        ];
    }

    private static Contract_Term_Change__c only(List<Contract_Term_Change__c> rows, String field) {
        for (Contract_Term_Change__c t : rows) if (t.Field__c == field) return t;
        return null;
    }

    @isTest
    static void aConflictIsRecordedOpenAndTheContractKeepsItsTerm() {
        Deal d = deal(new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' },
            new Map<String, Object>{ 'Payment_Terms__c' => 'Quarterly', 'Renewal_Terms__c' => 'Auto-renew (60-day)',
                'Extract_Evidence__c' => JSON.serialize(new Map<String, Object>{ 'Payment_Terms' => new Map<String, Object>{
                    'clause' => 'Order Form - Fees', 'quote' => 'payable quarterly in advance' } }) });
        rebuild(d.contract);

        Contract after = [SELECT Payment_Terms__c, Renewal_Terms__c, Needs_Legal_Review__c, Contract_History_Stale__c
                          FROM Contract WHERE Id = :d.contract.Id];
        System.assertEquals('Annual', after.Payment_Terms__c, 'the contract keeps its term until legal decides');
        System.assertEquals('Auto-renew (60-day)', after.Renewal_Terms__c, 'a new term is written');
        System.assertEquals(true, after.Needs_Legal_Review__c);
        System.assertEquals(true, after.Contract_History_Stale__c, 'marked for its history');

        List<Contract_Term_Change__c> rows = changes(d.contract.Id);
        Contract_Term_Change__c conflict = only(rows, 'Payment_Terms__c');
        System.assertEquals('Conflict', conflict.Change_Type__c);
        System.assertEquals('Open', conflict.Status__c);
        System.assertEquals('Annual', conflict.Base_Value__c);
        System.assertEquals('Quarterly', conflict.New_Value__c);
        System.assertEquals(d.up.Id, conflict.Opportunity__c);
        System.assertEquals(d.upRead.Id, conflict.Extraction__c);
        System.assertEquals('Order Form - Fees: "payable quarterly in advance"', conflict.Source_Quote__c);
        System.assertEquals(String.valueOf(d.contract.Id) + ':' + String.valueOf(d.up.Id) + ':Payment_Terms__c', conflict.Key__c);
        Contract_Term_Change__c added = only(rows, 'Renewal_Terms__c');
        System.assertEquals('Added', added.Change_Type__c);
        System.assertEquals('Info', added.Status__c);
    }

    @isTest
    static void anAcceptedChangeWinsAndSurvivesRebuilds() {
        Deal d = deal(new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' },
            new Map<String, Object>{ 'Payment_Terms__c' => 'Quarterly' });
        rebuild(d.contract);
        Contract_Term_Change__c conflict = only(changes(d.contract.Id), 'Payment_Terms__c');

        Test.startTest();
        conflict.Status__c = 'Accepted';
        conflict.Decision_Note__c = 'Quarterly agreed with the customer.';
        update conflict;   // the trigger rebuilds the contract
        Test.stopTest();

        Contract after = [SELECT Payment_Terms__c, Needs_Legal_Review__c, Reconciliation_Notes__c FROM Contract
                          WHERE Id = :d.contract.Id];
        System.assertEquals('Quarterly', after.Payment_Terms__c, after.Reconciliation_Notes__c);
        System.assertEquals(false, after.Needs_Legal_Review__c, 'nothing is left open');
        System.assert(after.Reconciliation_Notes__c.contains('change accepted by legal'), after.Reconciliation_Notes__c);
        Contract_Term_Change__c decided = only(changes(d.contract.Id), 'Payment_Terms__c');
        System.assertEquals('Accepted', decided.Status__c);
        System.assertEquals(UserInfo.getUserId(), decided.Decided_By__c);
        System.assertNotEquals(null, decided.Decided_At__c);

        // Another rebuild: the decision holds, and the change is not duplicated.
        rebuild(d.contract);
        System.assertEquals('Quarterly', [SELECT Payment_Terms__c FROM Contract WHERE Id = :d.contract.Id].Payment_Terms__c);
        System.assertEquals(1, [SELECT COUNT() FROM Contract_Term_Change__c WHERE Contract__c = :d.contract.Id
                                AND Field__c = 'Payment_Terms__c']);

        // The deal's value changes (a re-read): the decision no longer applies.
        update new Order_Form_Extraction__c(Id = d.upRead.Id, Payment_Terms__c = 'Monthly');
        rebuild(d.contract);
        Contract_Term_Change__c reopened = only(changes(d.contract.Id), 'Payment_Terms__c');
        System.assertEquals('Open', reopened.Status__c);
        System.assertEquals('Monthly', reopened.New_Value__c);
        System.assert(reopened.Decision_Note__c.startsWith('Reopened'), reopened.Decision_Note__c);
        System.assertEquals('Annual', [SELECT Payment_Terms__c FROM Contract WHERE Id = :d.contract.Id].Payment_Terms__c);
    }

    @isTest
    static void aRejectedChangeKeepsTheContractsTerm() {
        Deal d = deal(new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' },
            new Map<String, Object>{ 'Payment_Terms__c' => 'Quarterly' });
        rebuild(d.contract);
        Contract_Term_Change__c conflict = only(changes(d.contract.Id), 'Payment_Terms__c');
        Test.startTest();
        conflict.Status__c = 'Rejected';
        update conflict;
        Test.stopTest();
        Contract after = [SELECT Payment_Terms__c, Needs_Legal_Review__c FROM Contract WHERE Id = :d.contract.Id];
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assertEquals(false, after.Needs_Legal_Review__c);
    }

    @isTest
    static void aSignedUpsellForAnotherEntityIsFlagged() {
        Deal d = deal(new Map<String, Object>{ 'Billing_Entity_Name__c' => 'Jefferies LLC' },
            new Map<String, Object>{ 'Billing_Entity_Name__c' => 'Jefferies Financial Group Inc.',
                'Source_Document_Type__c' => 'Order Form', 'Signature_Date__c' => Date.today().addDays(-10) });
        rebuild(d.contract);

        Contract_Term_Change__c flag = only(changes(d.contract.Id), 'Billing_Entity_Name__c');
        System.assertEquals('Entity Mismatch', flag.Change_Type__c);
        System.assertEquals('Open', flag.Status__c);
        System.assertEquals('Jefferies LLC', flag.Base_Value__c);
        System.assertEquals('Jefferies Financial Group Inc.', flag.New_Value__c);
        Order_Form_Extraction__c upAfter = [SELECT Contract_Flags__c, Has_Contract_Flags__c FROM Order_Form_Extraction__c
                                            WHERE Id = :d.upRead.Id];
        System.assert(upAfter.Contract_Flags__c.startsWith('[Entity Mismatch]'), upAfter.Contract_Flags__c);
        System.assertEquals(true, upAfter.Has_Contract_Flags__c);
        System.assertEquals(true, [SELECT Needs_Legal_Review__c FROM Contract WHERE Id = :d.contract.Id].Needs_Legal_Review__c);
    }

    @isTest
    static void theSameEntityWrittenDifferentlyIsNotFlagged() {
        Deal d = deal(new Map<String, Object>{ 'Billing_Entity_Name__c' => 'RKS Asset Management, S.L.U.' },
            new Map<String, Object>{ 'Billing_Entity_Name__c' => 'RKS Asset Management SLU',
                'Source_Document_Type__c' => 'Order Form', 'Customer_Signer_Name__c' => 'Henry Gallego' });
        rebuild(d.contract);
        System.assertEquals(null, only(changes(d.contract.Id), 'Billing_Entity_Name__c'));
        System.assertEquals(false, [SELECT Has_Contract_Flags__c FROM Order_Form_Extraction__c WHERE Id = :d.upRead.Id]
            .Has_Contract_Flags__c);

        System.assert(ContractLegalTermsApplier.sameEntity('Alvarez & Marsal Holdings, LLC', 'alvarez and marsal holdings'));
        System.assert(!ContractLegalTermsApplier.sameEntity('Acme Europe Ltd', 'Acme Holdings Inc'));
    }

    @isTest
    static void anUpsellIntroducingCreditsIsFlagged() {
        Deal d = deal(new Map<String, Object>{ 'Seat_Licenses__c' => 5 },
            new Map<String, Object>{ 'Credits_Added__c' => 1000000, 'Credits_Period__c' => 'year' });
        rebuild(d.contract);
        Contract_Term_Change__c flag = only(changes(d.contract.Id), 'Total_Credits_Purchased__c');
        System.assertEquals('Credits Introduced', flag.Change_Type__c);
        System.assertEquals('Open', flag.Status__c);
        System.assert(flag.New_Value__c.contains('1,000,000 credits per year'), flag.New_Value__c);

        // Acknowledged: no longer a reason for legal review.
        Test.startTest();
        flag.Status__c = 'Accepted';
        update flag;
        Test.stopTest();
        System.assertEquals(false, [SELECT Needs_Legal_Review__c FROM Contract WHERE Id = :d.contract.Id].Needs_Legal_Review__c);
        System.assert([SELECT Contract_Flags__c FROM Order_Form_Extraction__c WHERE Id = :d.upRead.Id]
            .Contract_Flags__c.endsWith('(acknowledged)'));
    }

    @isTest
    static void signedPaperBillingAnEntityOffTheSplitIsFlagged() {
        Deal d = deal(new Map<String, Object>{ 'Billing_Entity_Name__c' => 'Acme Holdings Inc',
                'Source_Document_Type__c' => 'Order Form', 'Signature_Date__c' => Date.today().addDays(-300) },
            new Map<String, Object>());
        insert new Billing_Split__c(Contract__c = d.contract.Id, Entity_Name__c = 'Acme Europe Ltd');
        rebuild(d.contract);
        Contract_Term_Change__c flag = only(changes(d.contract.Id), 'Billing_Split__c');
        System.assertEquals('Billing Split Mismatch', flag.Change_Type__c);
        System.assertEquals('Acme Europe Ltd', flag.Base_Value__c);
        System.assert([SELECT Contract_Flags__c FROM Order_Form_Extraction__c WHERE Id = :d.nbRead.Id]
            .Contract_Flags__c.startsWith('[Billing Split Mismatch]'));
    }

    @isTest
    static void theCreditTransitionPeriodLandsOnTheContract() {
        Deal d = deal(new Map<String, Object>{ 'Credit_Transition_End_Date__c' => Date.newInstance(2026, 10, 14),
                'Credit_Transition_Terms__c' => 'Transition Period ... through October 14, 2026, inclusive' },
            new Map<String, Object>());
        rebuild(d.contract);
        Contract after = [SELECT Credit_Transition_End_Date__c, Credit_Transition_Terms__c FROM Contract
                          WHERE Id = :d.contract.Id];
        System.assertEquals(Date.newInstance(2026, 10, 14), after.Credit_Transition_End_Date__c);
        System.assert(after.Credit_Transition_Terms__c.startsWith('Transition Period'));
        System.assertEquals('2026-10-14', ContractLegalTermsApplier.canonTerm(Date.newInstance(2026, 10, 14)));
        System.assertEquals('30', ContractLegalTermsApplier.canonTerm(30.00));
    }
}
