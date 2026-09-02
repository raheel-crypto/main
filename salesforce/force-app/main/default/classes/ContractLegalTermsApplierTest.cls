@isTest
private class ContractLegalTermsApplierTest {

    private static Account makeAccount() {
        Account a = new Account(Name = 'Test Account');
        insert a;
        return a;
    }

    private static Contract makeContract(Id accountId, Map<String, Object> legalValues) {
        Contract c = new Contract(
            AccountId = accountId,
            Status = 'Draft',
            StartDate = Date.today(),
            ContractTerm = 12
        );
        if (legalValues != null) for (String k : legalValues.keySet()) c.put(k, legalValues.get(k));
        insert c;
        return c;
    }

    private static Opportunity makeOpp(Id accountId, String type, Id contractId, Id baseOppId) {
        Opportunity o = new Opportunity(
            Name = type + ' Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            AccountId = accountId,
            Type = type,
            ContractId = contractId,
            Base_Opportunity__c = baseOppId
        );
        insert o;
        return o;
    }

    private static Order_Form_Extraction__c makeOfe(Id oppId, Map<String, Object> legalValues) {
        Order_Form_Extraction__c ofe = new Order_Form_Extraction__c(
            Opportunity__c = oppId,
            Extraction_Status__c = 'Success',
            Extracted_At__c = System.now()
        );
        for (String k : legalValues.keySet()) ofe.put(k, legalValues.get(k));
        insert ofe;
        return ofe;
    }

    private static ContractLegalTermsApplier.Result runOne(Id ofeId) {
        ContractLegalTermsApplier.Request req = new ContractLegalTermsApplier.Request();
        req.extractionId = ofeId;
        return ContractLegalTermsApplier.apply(new List<ContractLegalTermsApplier.Request>{ req })[0];
    }

    @isTest
    static void freshWrite_newBusinessWritesAllLegalTerms() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);           // empty fresh contract
        Opportunity o = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Renewal_Terms__c' => 'Auto-renew (90-day)',
            'Renewal_Fee_Escalator__c' => 5,
            'Payment_Terms__c' => 'Annual',
            'Credit_Terms__c' => 'Net-30',
            'Subprocessor_Notice_Period__c' => 30,
            'Special_Terms__c' => 'MFN clause.',
            'ELA__c' => true,
            'Credit_Commit__c' => true
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('Applied', res.status);
        System.assertEquals(false, res.needsReview);

        Contract after = [
            SELECT Renewal_Terms__c, Renewal_Fee_Escalator__c, Payment_Terms__c, Credit_Terms__c,
                   Subprocessor_Notice_Period__c, Special_Terms__c, ELA__c, Credit_Commit__c,
                   Needs_Legal_Review__c, Latest_Order_Form_Extraction__c
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals('Auto-renew (90-day)', after.Renewal_Terms__c);
        System.assertEquals(5, after.Renewal_Fee_Escalator__c);
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assertEquals('Net-30', after.Credit_Terms__c);
        System.assertEquals(30, after.Subprocessor_Notice_Period__c);
        System.assertEquals(true, after.ELA__c);
        System.assertEquals(true, after.Credit_Commit__c);
        System.assertEquals(false, after.Needs_Legal_Review__c);
        System.assertEquals(ofe.Id, after.Latest_Order_Form_Extraction__c);

        // Paper-trail link stamped back on the OFE.
        Order_Form_Extraction__c ofeAfter = [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Id = :ofe.Id];
        System.assertEquals(c.Id, ofeAfter.Applied_Contract__c);
    }

    @isTest
    static void upsell_newTermWrittenSilentPreserved() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Renewal_Terms__c' => 'Auto-renew (90-day)',   // already set
            'Payment_Terms__c' => 'Annual'
        });
        Opportunity o = makeOpp(a.Id, 'Upsell', c.Id, null);
        // Upsell introduces Subprocessor notice (new), restates same Renewal_Terms,
        // and is silent on Payment_Terms.
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Renewal_Terms__c' => 'Auto-renew (90-day)',
            'Subprocessor_Notice_Period__c' => 60
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('Reconciled', res.status);
        System.assertEquals(false, res.needsReview);

        Contract after = [
            SELECT Renewal_Terms__c, Payment_Terms__c, Subprocessor_Notice_Period__c, Needs_Legal_Review__c
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals(60, after.Subprocessor_Notice_Period__c, 'New term written');
        System.assertEquals('Annual', after.Payment_Terms__c, 'Silent term preserved');
        System.assertEquals(false, after.Needs_Legal_Review__c);
    }

    @isTest
    static void upsell_conflictFlaggedNotOverwritten() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Payment_Terms__c' => 'Annual'
        });
        Opportunity o = makeOpp(a.Id, 'Upsell', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Payment_Terms__c' => 'Quarterly'   // conflicts with existing 'Annual'
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('NeedsReview', res.status);
        System.assertEquals(true, res.needsReview);

        Contract after = [
            SELECT Payment_Terms__c, Needs_Legal_Review__c, Reconciliation_Notes__c
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals('Annual', after.Payment_Terms__c, 'Conflict must NOT overwrite the existing contract');
        System.assertEquals(true, after.Needs_Legal_Review__c);
        System.assert(after.Reconciliation_Notes__c.contains('CONFLICT Payment_Terms__c'),
            'Conflict should be logged: ' + after.Reconciliation_Notes__c);
    }

    @isTest
    static void upsell_booleanAddsButNeverRemoves() {
        Account a = makeAccount();
        // Contract starts with ELA true, Credit_Commit false.
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'ELA__c' => true,
            'Credit_Commit__c' => false
        });
        Opportunity o = makeOpp(a.Id, 'Upsell', c.Id, null);
        // Upsell OFE: ELA false (silent/absent), Credit_Commit true (adds it).
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'ELA__c' => false,
            'Credit_Commit__c' => true
        });

        Test.startTest();
        runOne(ofe.Id);
        Test.stopTest();

        Contract after = [SELECT ELA__c, Credit_Commit__c, Needs_Legal_Review__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(true, after.ELA__c, 'Existing ELA must not be removed by a silent/false upsell');
        System.assertEquals(true, after.Credit_Commit__c, 'Credit_Commit added by the upsell');
        System.assertEquals(false, after.Needs_Legal_Review__c, 'Boolean add is not a conflict');
    }

    @isTest
    static void upsell_fallsBackToAccountContractWhenOppHasNone() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });
        // Opp has NO ContractId and no base opp -> should fall back to the
        // account's most recent contract.
        Opportunity o = makeOpp(a.Id, 'Upsell', null, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Subprocessor_Notice_Period__c' => 45
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals(c.Id, res.contractId, 'Should resolve the account fallback contract');
        Contract after = [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(45, after.Subprocessor_Notice_Period__c);
    }

    @isTest
    static void noContract_returnsNoContractStatus() {
        Account a = makeAccount();
        Opportunity o = makeOpp(a.Id, 'New Business', null, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Payment_Terms__c' => 'Annual'
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('NoContract', res.status);
        System.assertEquals(false, res.applied);
    }

    @isTest
    static void notSuccess_isSkipped() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity o = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofe = new Order_Form_Extraction__c(
            Opportunity__c = o.Id,
            Extraction_Status__c = 'API Failed',
            Extracted_At__c = System.now(),
            Payment_Terms__c = 'Annual'
        );
        insert ofe;

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('NotSuccess', res.status);
        Contract after = [SELECT Payment_Terms__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(null, after.Payment_Terms__c, 'Failed extraction should not write to the contract');
    }

    @isTest
    static void contactFields_freshWriteAndLatestWinsOnUpsell() {
        Account a = makeAccount();

        // New Business contract - empty; contact block should write straight through.
        Contract nbContract = makeContract(a.Id, null);
        Opportunity nbOpp = makeOpp(a.Id, 'New Business', nbContract.Id, null);
        Order_Form_Extraction__c nbOfe = makeOfe(nbOpp.Id, new Map<String, Object>{
            'Primary_Contact__c' => 'Eric Castillo',
            'Primary_Contact_Phone__c' => '212-644-4200',
            'Primary_Contact_Email__c' => 'ecastillo@liontree.com'
        });

        // Upsell contract - existing contact; latest order form should win, no review.
        Contract upContract = makeContract(a.Id, new Map<String, Object>{
            'Primary_Contact__c' => 'Old Contact',
            'Primary_Contact_Email__c' => 'old@liontree.com'
        });
        Opportunity upOpp = makeOpp(a.Id, 'Upsell', upContract.Id, null);
        Order_Form_Extraction__c upOfe = makeOfe(upOpp.Id, new Map<String, Object>{
            'Primary_Contact__c' => 'New Contact',
            'Primary_Contact_Phone__c' => '646-000-1111'    // fills a blank; silent on email
        });

        Test.startTest();
        ContractLegalTermsApplier.Result nbRes = runOne(nbOfe.Id);
        ContractLegalTermsApplier.Result upRes = runOne(upOfe.Id);
        Test.stopTest();

        System.assertEquals('Applied', nbRes.status);
        Contract nbAfter = [SELECT Primary_Contact__c, Primary_Contact_Phone__c, Primary_Contact_Email__c
                            FROM Contract WHERE Id = :nbContract.Id];
        System.assertEquals('Eric Castillo', nbAfter.Primary_Contact__c);
        System.assertEquals('212-644-4200', nbAfter.Primary_Contact_Phone__c);
        System.assertEquals('ecastillo@liontree.com', nbAfter.Primary_Contact_Email__c);

        System.assertEquals('Reconciled', upRes.status);
        System.assertEquals(false, upRes.needsReview, 'A changed contact must not trigger legal review');
        Contract upAfter = [SELECT Primary_Contact__c, Primary_Contact_Phone__c, Primary_Contact_Email__c, Needs_Legal_Review__c
                            FROM Contract WHERE Id = :upContract.Id];
        System.assertEquals('New Contact', upAfter.Primary_Contact__c, 'Latest order form wins');
        System.assertEquals('646-000-1111', upAfter.Primary_Contact_Phone__c, 'Blank filled from order form');
        System.assertEquals('old@liontree.com', upAfter.Primary_Contact_Email__c, 'Silent field preserved');
        System.assertEquals(false, upAfter.Needs_Legal_Review__c);
    }
}
