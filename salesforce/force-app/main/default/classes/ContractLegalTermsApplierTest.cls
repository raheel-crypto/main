@isTest
private class ContractLegalTermsApplierTest {

    // The org blocks creating an Opportunity at a closed stage; makeOpp inserts at
    // Closed Won. Grant the running test user the Bypass_Validations custom
    // permission (its own transaction, so the permission cache reflects it and the
    // setup DML doesn't collide with record DML). No-op if the permission is absent.
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'CLTA_Test_Bypass', Label = 'CLTA Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

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
    static void fresh_pilotWithoutOwnContractNeverLandsOnAccountContract() {
        // LionTree: a pilot with no contract of its own overwrote the Land contract.
        Account a = makeAccount();
        Contract land = makeContract(a.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });
        Opportunity pilot = makeOpp(a.Id, 'Pilot', null, null);
        Order_Form_Extraction__c ofe = makeOfe(pilot.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Monthly' });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('NoContract', res.status);
        System.assert(res.notes.contains('No Contract of its own'), res.notes);
        System.assertEquals('Annual', [SELECT Payment_Terms__c FROM Contract WHERE Id = :land.Id].Payment_Terms__c);
        System.assertEquals(null, [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Id = :ofe.Id].Applied_Contract__c);
    }

    @isTest
    static void fresh_landsOnContractThatRecordsItsOpportunity() {
        Account a = makeAccount();
        Opportunity nb = makeOpp(a.Id, 'New Business', null, null);
        Contract other = makeContract(a.Id, null);
        Contract own = makeContract(a.Id, new Map<String, Object>{ 'Source_Opportunity_Id__c' => String.valueOf(nb.Id) });
        Contract newest = makeContract(a.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(nb.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Quarterly' });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals(own.Id, res.contractId);
        System.assertEquals('Quarterly', [SELECT Payment_Terms__c FROM Contract WHERE Id = :own.Id].Payment_Terms__c);
        System.assertEquals(null, [SELECT Payment_Terms__c FROM Contract WHERE Id = :newest.Id].Payment_Terms__c);
        System.assertEquals(ofe.Id, [SELECT Latest_Order_Form_Extraction__c FROM Contract WHERE Id = :own.Id].Latest_Order_Form_Extraction__c);
    }

    @isTest
    static void upsellFallback_prefersTheAccountsNonPilotContract() {
        Account a = makeAccount();
        Contract main = makeContract(a.Id, null);
        Opportunity pilotOpp = makeOpp(a.Id, 'Pilot', null, null);
        Contract pilotContract = makeContract(a.Id, new Map<String, Object>{ 'Opportunity__c' => pilotOpp.Id });  // newer
        Opportunity up = makeOpp(a.Id, 'Upsell', null, null);
        Order_Form_Extraction__c ofe = makeOfe(up.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 60 });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals(main.Id, res.contractId, 'the pilot contract is newer but is a pilot\'s');
        System.assertEquals(null, [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :pilotContract.Id].Subprocessor_Notice_Period__c);
    }

    private static Opportunity closedOpp(Id accountId, String type, Integer daysAgo, Id contractId) {
        Opportunity o = new Opportunity(Name = type + ' ' + daysAgo, StageName = 'Closed Won', AccountId = accountId,
            Type = type, CloseDate = Date.today().addDays(-daysAgo), ContractId = contractId);
        insert o;
        return o;
    }

    @isTest
    static void upsellWithoutBase_landsOnTheLatestPriorRenewalsContract() {
        // Core Advisors / Creuza "Renewal Upsell": no base deal, closed with the
        // renewal - it amends the renewal's contract, not the account's newest.
        Account a = makeAccount();
        Contract nbContract = makeContract(a.Id, null);
        Contract renewalContract = makeContract(a.Id, null);
        Contract laterContract = makeContract(a.Id, null);
        closedOpp(a.Id, 'New Business', 400, nbContract.Id);
        closedOpp(a.Id, 'Renewal', 10, renewalContract.Id);
        closedOpp(a.Id, 'New Business', -30, laterContract.Id);   // closes after the upsell
        Opportunity up = closedOpp(a.Id, 'Upsell', 10, null);
        Order_Form_Extraction__c ofe = makeOfe(up.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 45 });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(new Set<Id>{ ofe.Id });
        Test.stopTest();

        System.assertEquals(renewalContract.Id, res.contractId);
        System.assertEquals(renewalContract.Id, targets.get(ofe.Id), 'the repair check agrees with the applier');
        System.assertEquals(45, [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :renewalContract.Id].Subprocessor_Notice_Period__c);
    }

    @isTest
    static void upsellOnAContractMadeForIt_landsOnTheBaseDealsContract() {
        Account a = makeAccount();
        Contract nbContract = makeContract(a.Id, null);
        closedOpp(a.Id, 'New Business', 200, nbContract.Id);
        Opportunity up = closedOpp(a.Id, 'Upsell', 20, null);
        Contract madeForUpsell = makeContract(a.Id, new Map<String, Object>{ 'Opportunity__c' => up.Id });
        up.ContractId = madeForUpsell.Id;
        update up;
        Order_Form_Extraction__c ofe = makeOfe(up.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals(nbContract.Id, res.contractId, 'the upsell amends the contract it was sold on');
    }

    @isTest
    static void currentTargets_freshDealWithoutOwnContractHasNone() {
        Account a = makeAccount();
        makeContract(a.Id, null);
        Opportunity pilot = makeOpp(a.Id, 'Pilot', null, null);
        Order_Form_Extraction__c ofe = makeOfe(pilot.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Monthly' });

        Test.startTest();
        Map<Id, Id> targets = ContractLegalTermsApplier.currentTargets(new Set<Id>{ ofe.Id });
        Test.stopTest();

        System.assert(!targets.containsKey(ofe.Id), String.valueOf(targets));
    }

    @isTest
    static void clearedTerms_blanksManagedTermsOnly() {
        Contract c = ContractLegalTermsApplier.clearedTerms(null);
        Map<String, Object> f = c.getPopulatedFieldsAsMap();
        System.assertEquals(null, f.get('Renewal_Terms__c'));
        System.assert(f.containsKey('Renewal_Terms__c'));
        System.assertEquals(false, f.get('ELA__c'));
        System.assertEquals(false, f.get('Seat_Adds_By_Email__c'));
        System.assert(f.containsKey('Credits_Per_Year__c') && f.get('Credits_Per_Year__c') == null);
        System.assertEquals(false, f.get('Needs_Legal_Review__c'));
        System.assert(!f.containsKey('Primary_Contact__c'), 'contacts kept');
        System.assert(!f.containsKey('Billing_Entity_Name__c'), 'billing kept');
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

    // ===== Billing details: fill blanks only =====

    @isTest
    static void billing_freshDealFillsBlanksAndSplitsAddress() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity o = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Billing_Contact_Email__c' => 'ap@acmecapital.com',
            'Billing_Entity_Name__c' => 'Acme Capital LLC',
            'Billing_Entity_Address__c' => '711 Fifth Avenue, 10th Floor, New York, NY 10022'
        });

        Test.startTest();
        runOne(ofe.Id);
        Test.stopTest();

        Contract after = [
            SELECT Billing_Contact__c, Billing_Entity_Name__c, Billing_Entity_Address__c,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals('ap@acmecapital.com', after.Billing_Contact__c);
        System.assertEquals('Acme Capital LLC', after.Billing_Entity_Name__c);
        System.assertEquals('711 Fifth Avenue, 10th Floor, New York, NY 10022', after.Billing_Entity_Address__c);
        System.assertEquals('711 Fifth Avenue, 10th Floor', after.BillingStreet);
        System.assertEquals('New York', after.BillingCity);
        System.assertEquals('NY', after.BillingState);
        System.assertEquals('10022', after.BillingPostalCode);
        System.assertEquals('United States', after.BillingCountry);
    }

    @isTest
    static void billing_neverOverwritesExistingValues() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Billing_Contact__c' => 'old-ap@acmecapital.com',
            'BillingStreet' => '1 Old Road',
            'BillingCity' => 'Boston'
        });
        Opportunity o = makeOpp(a.Id, 'Upsell', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Billing_Contact_Email__c' => 'new-ap@acmecapital.com',
            'Billing_Entity_Name__c' => 'Acme Capital LLC',
            'Billing_Entity_Address__c' => '711 Fifth Avenue, New York, NY 10022'
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        Contract after = [
            SELECT Billing_Contact__c, Billing_Entity_Name__c, Billing_Entity_Address__c,
                   BillingStreet, BillingCity, BillingState, Needs_Legal_Review__c
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals(false, res.needsReview);
        System.assertEquals('old-ap@acmecapital.com', after.Billing_Contact__c, 'existing AP email kept');
        System.assertEquals('Acme Capital LLC', after.Billing_Entity_Name__c, 'blank filled');
        System.assertEquals('711 Fifth Avenue, New York, NY 10022', after.Billing_Entity_Address__c, 'blank filled');
        System.assertEquals('1 Old Road', after.BillingStreet, 'existing address never mixed with another');
        System.assertEquals('Boston', after.BillingCity);
        System.assertEquals(null, after.BillingState);
    }

    @isTest
    static void billingBackfill_fillsFromAppliedExtractionsInDealOrder() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity first = new Opportunity(Name = 'First Opp', StageName = 'Closed Won', AccountId = a.Id,
            Type = 'New Business', CloseDate = Date.today().addDays(-30));
        insert first;
        Opportunity later = makeOpp(a.Id, 'Upsell', null, first.Id);
        // Incomplete rows: legal terms apply, and no create-time automation touches them.
        makeOfe(first.Id, new Map<String, Object>{
            'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true, 'Applied_Contract__c' => c.Id,
            'Billing_Entity_Name__c' => 'First Entity LLC',
            'Billing_Entity_Address__c' => '86 Brook Street, London W1K 5AY'
        });
        makeOfe(later.Id, new Map<String, Object>{
            'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true, 'Applied_Contract__c' => c.Id,
            'Billing_Entity_Name__c' => 'Later Entity LLC',
            'Billing_Contact_Email__c' => 'ap@later.com',
            'Seat_Adds_By_Email__c' => true,
            'Seat_Adds_By_Email_Terms__c' => 'Customer may add users by emailing sales@rogo.ai.'
        });

        Test.startTest();
        List<Contract> changes = ContractLegalTermsApplier.backfillBillingAndSeatAdds(new Set<Id>{ c.Id });
        Test.stopTest();

        System.assertEquals(1, changes.size());
        Contract ch = changes[0];
        System.assertEquals('First Entity LLC', ch.Billing_Entity_Name__c, 'earliest deal wins');
        System.assertEquals('ap@later.com', ch.Billing_Contact__c, 'a later deal still fills a blank');
        System.assertEquals('86 Brook Street', ch.BillingStreet);
        System.assertEquals('London', ch.BillingCity);
        System.assertEquals('W1K 5AY', ch.BillingPostalCode);
        System.assertEquals('United Kingdom', ch.BillingCountry);
        System.assertEquals(true, ch.Seat_Adds_By_Email__c, 'a later deal adds the seat-adds term');
        System.assertEquals('Customer may add users by emailing sales@rogo.ai.', ch.Seat_Adds_By_Email_Terms__c);
    }

    @isTest
    static void seatAdds_freshWritesAndAmendmentOnlyAdds() {
        Account a = makeAccount();
        Contract withTerm = makeContract(a.Id, new Map<String, Object>{
            'Seat_Adds_By_Email__c' => true,
            'Seat_Adds_By_Email_Terms__c' => 'Add seats by emailing sales@rogo.ai.'
        });
        Contract without = makeContract(a.Id, null);
        Opportunity upKeep = makeOpp(a.Id, 'Upsell', withTerm.Id, null);
        Opportunity upAdd = makeOpp(a.Id, 'Upsell', without.Id, null);
        // An upsell silent on it never removes the term...
        Order_Form_Extraction__c silent = makeOfe(upKeep.Id, new Map<String, Object>{ 'Seat_Adds_By_Email__c' => false });
        // ...and one that grants it adds it, with its sentence.
        Order_Form_Extraction__c grants = makeOfe(upAdd.Id, new Map<String, Object>{
            'Seat_Adds_By_Email__c' => true,
            'Seat_Adds_By_Email_Terms__c' => 'Customer may add Authorized Users by contacting its Account Executive.'
        });

        Test.startTest();
        ContractLegalTermsApplier.Result r1 = runOne(silent.Id);
        ContractLegalTermsApplier.Result r2 = runOne(grants.Id);
        Test.stopTest();

        Contract kept = [SELECT Seat_Adds_By_Email__c, Seat_Adds_By_Email_Terms__c FROM Contract WHERE Id = :withTerm.Id];
        Contract added = [SELECT Seat_Adds_By_Email__c, Seat_Adds_By_Email_Terms__c FROM Contract WHERE Id = :without.Id];
        System.assertEquals(false, r1.needsReview);
        System.assertEquals(false, r2.needsReview);
        System.assertEquals(true, kept.Seat_Adds_By_Email__c);
        System.assertEquals('Add seats by emailing sales@rogo.ai.', kept.Seat_Adds_By_Email_Terms__c);
        System.assertEquals(true, added.Seat_Adds_By_Email__c);
        System.assert(added.Seat_Adds_By_Email_Terms__c.contains('Account Executive'), added.Seat_Adds_By_Email_Terms__c);
    }

    @isTest
    static void backfillModelChange_laysTheColumnDownInDealOrder() {
        Account a = makeAccount();
        Contract quiet = makeContract(a.Id, null);
        Contract disputed = makeContract(a.Id, null);
        Opportunity nb1 = closedOpp(a.Id, 'New Business', 300, null);
        Opportunity up1 = closedOpp(a.Id, 'Upsell', 100, null);
        Opportunity nb2 = closedOpp(a.Id, 'New Business', 300, null);
        Opportunity up2 = closedOpp(a.Id, 'Upsell', 100, null);
        // Incomplete rows: no create-time automation applies them.
        makeOfe(nb1.Id, new Map<String, Object>{ 'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true,
            'Applied_Contract__c' => quiet.Id, 'Model_Change_Requirement__c' => 'Approval',
            'Model_Change_Terms__c' => 'Approval: before a model outside the approved list. AI Schedule 4.' });
        makeOfe(up1.Id, new Map<String, Object>{ 'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true,
            'Applied_Contract__c' => quiet.Id, 'Model_Change_Requirement__c' => 'None identified' });
        makeOfe(nb2.Id, new Map<String, Object>{ 'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true,
            'Applied_Contract__c' => disputed.Id, 'Model_Change_Requirement__c' => 'Notice',
            'Model_Change_Terms__c' => 'Notice: 30 days before material model changes. 2.3.' });
        makeOfe(up2.Id, new Map<String, Object>{ 'Extraction_Status__c' => 'Incomplete', 'Is_Current__c' => true,
            'Applied_Contract__c' => disputed.Id, 'Model_Change_Requirement__c' => 'Approval',
            'Model_Change_Terms__c' => 'Approval: prior written consent. AI Addendum 5.' });

        Test.startTest();
        List<Contract> changes = ContractLegalTermsApplier.backfillModelChange(new Set<Id>{ quiet.Id, disputed.Id });
        Test.stopTest();

        Map<Id, Contract> byId = new Map<Id, Contract>(changes);
        System.assertEquals('Approval', byId.get(quiet.Id).Model_Change_Requirement__c, 'an upsell\'s silence keeps the answer');
        System.assertEquals(null, byId.get(quiet.Id).getPopulatedFieldsAsMap().get('Needs_Legal_Review__c'));
        System.assertEquals('Notice', byId.get(disputed.Id).Model_Change_Requirement__c, 'the contract keeps the first answer');
        System.assertEquals(true, byId.get(disputed.Id).Needs_Legal_Review__c, 'a different real answer is a conflict');
        System.assert(byId.get(disputed.Id).Reconciliation_Notes__c.contains('CONFLICT Model_Change_Requirement__c'));
    }

    // ===== Running credit total (signed: Downsell subtracts) =====

    @isTest
    static void creditTotal_signedSumAcrossOFEs() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);

        // New Business on the contract (1000), an Upsell (+500) and a Downsell (-200),
        // the amendments resolving to the same contract via Base_Opportunity.
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{ 'Credits_Purchased__c' => 1000 });
        Opportunity up = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{ 'Credits_Purchased__c' => 500 });
        Opportunity dn = makeOpp(a.Id, 'Downsell', null, nb.Id);
        Order_Form_Extraction__c ofeDn = makeOfe(dn.Id, new Map<String, Object>{ 'Credits_Purchased__c' => 200 });

        Test.startTest();
        runOne(ofeNb.Id);   // 1000
        runOne(ofeUp.Id);   // +500 -> 1500
        runOne(ofeDn.Id);   // -200 -> 1300
        Test.stopTest();

        Contract after = [SELECT Total_Credits_Purchased__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(1300, after.Total_Credits_Purchased__c, 'Signed sum: 1000 + 500 - 200');
    }

    @isTest
    static void creditTotal_isIdempotentOnReapply() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{ 'Credits_Purchased__c' => 1000 });

        Test.startTest();
        runOne(ofeNb.Id);
        runOne(ofeNb.Id);   // re-apply the SAME OFE - must not double-count to 2000
        Test.stopTest();

        Contract after = [SELECT Total_Credits_Purchased__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(1000, after.Total_Credits_Purchased__c, 'Re-apply recomputes, never doubles');
    }

    // ===== Contract pointer: never stamped from the account fallback =====

    @isTest
    static void pointer_notStampedForAccountFallbackContract() {
        // BlackRock: the new term's opp had no contract, so the account fallback
        // picked an older contract - that must not become its pointer.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity o = makeOpp(a.Id, 'Upsell', null, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 30 });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals(c.Id, res.contractId, 'Terms still reconcile onto the fallback contract');
        Contract after = [SELECT Latest_Order_Form_Extraction__c, Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(null, after.Latest_Order_Form_Extraction__c, 'Pointer not moved by a fallback match');
        System.assert(after.Reconciliation_Notes__c.contains('pointer not moved'), after.Reconciliation_Notes__c);
    }

    @isTest
    static void pointer_stampedWhenFallbackContractIsTheDealsSourceOpp() {
        Account a = makeAccount();
        Opportunity o = makeOpp(a.Id, 'Upsell', null, null);
        // The opp itself has no ContractId, but the contract records it as its source.
        Contract c = makeContract(a.Id, new Map<String, Object>{ 'Opportunity__c' => o.Id });
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 30 });

        Test.startTest();
        runOne(ofe.Id);
        Test.stopTest();

        Contract after = [SELECT Latest_Order_Form_Extraction__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(ofe.Id, after.Latest_Order_Form_Extraction__c);
    }

    @isTest
    static void isSourceOpportunity_matchesLookupOrExternalId() {
        Account a = makeAccount();
        Opportunity o = makeOpp(a.Id, 'New Business', null, null);
        Contract viaId = new Contract();
        viaId.put('Source_Opportunity_Id__c', String.valueOf(o.Id).left(15));
        System.assertEquals(true, ContractLegalTermsApplier.isSourceOpportunity(viaId, o.Id), '15-char id matches');
        Contract junk = new Contract();
        junk.put('Source_Opportunity_Id__c', 'not-an-id');
        System.assertEquals(false, ContractLegalTermsApplier.isSourceOpportunity(junk, o.Id));
        System.assertEquals(false, ContractLegalTermsApplier.isSourceOpportunity(null, o.Id));
    }

    @isTest
    static void creditTotal_amendmentUsesCapturedIncrementNotRestatedTotal() {
        // NB buys 200k; the upsell order form restates 300k as the new TOTAL and the
        // extractor captured the +100k increment. The contract total must be 300k,
        // not 200k + 300k.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{ 'Credits_Purchased__c' => 200000 });
        Opportunity up = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{
            'Credits_Purchased__c' => 300000, 'Credits_Added__c' => 100000 });

        Test.startTest();
        runOne(ofeNb.Id);
        runOne(ofeUp.Id);
        Test.stopTest();

        Contract after = [SELECT Total_Credits_Purchased__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(300000, after.Total_Credits_Purchased__c);
    }

    @isTest
    static void creditTotal_countsOneRowPerDealAcrossVersions() {
        // The NB deal was extracted twice (versions are kept as history): an older
        // 200k row and the current 250k row, both already stamped to the contract.
        // Only the current one counts, so an upsell adding 50k lands on 300k, not 500k.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        makeOfe(nb.Id, new Map<String, Object>{
            'Credits_Purchased__c' => 200000, 'Applied_Contract__c' => c.Id, 'Is_Current__c' => false,
            'Extracted_At__c' => System.now().addDays(-2) });
        makeOfe(nb.Id, new Map<String, Object>{
            'Credits_Purchased__c' => 250000, 'Applied_Contract__c' => c.Id, 'Is_Current__c' => true,
            'Extracted_At__c' => System.now().addDays(-1) });
        Opportunity up = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{
            'Credits_Purchased__c' => 300000, 'Credits_Added__c' => 50000 });

        Test.startTest();
        runOne(ofeUp.Id);
        Test.stopTest();

        Contract after = [SELECT Total_Credits_Purchased__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(300000, after.Total_Credits_Purchased__c, 'Current NB row (250k) + 50k added');
    }

    @isTest
    static void noOrderForm_appliesLegalTermsWithoutMovingPointer() {
        // MidCap: only an MNDA + MSA came through. The MSA's legal terms are still the
        // source of truth, but with no order form the contract must not point at it.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity o = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Extraction_Status__c' => 'No Order Form',
            'Payment_Terms__c' => 'Annual',
            'Package_Tier__c' => 'Enterprise' });   // an MSA tier table is not this deal's product

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        System.assertEquals('Applied', res.status);
        Contract after = [SELECT Payment_Terms__c, Latest_Order_Form_Extraction__c, Reconciliation_Notes__c,
                                 Package_Tier__c, Pricing_Structure__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Annual', after.Payment_Terms__c, 'Legal terms applied from the MSA');
        System.assertEquals(null, after.Package_Tier__c, 'No order form -> no product terms');
        System.assertEquals(null, after.Pricing_Structure__c);
        System.assertEquals(null, after.Latest_Order_Form_Extraction__c, 'Pointer not moved without an order form');
        System.assert(after.Reconciliation_Notes__c.contains('Applied legal terms only'), after.Reconciliation_Notes__c);
    }

    // ===== Usage + product terms (ContractUsageRollup) =====

    @isTest
    static void usage_freshDealWritesProductAndCreditTerms() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(nb.Id, new Map<String, Object>{
            'Package_Tier__c' => 'Enterprise', 'Unlimited_Lite__c' => 'Inferred (Enterprise)',
            'Free_Tier_Retained__c' => 'Yes', 'Overage_Rate__c' => 0.04,
            'Credits_Purchased__c' => 200000, 'Credits_Period__c' => 'year', 'Credits_Per_Year__c' => 200000,
            'Credit_Rate__c' => 0.05, 'Credit_Commit__c' => true });

        Test.startTest();
        runOne(ofe.Id);
        Test.stopTest();

        Contract after = [SELECT Package_Tier__c, Unlimited_Lite__c, Free_Tier_Retained__c, Overage_Rate__c,
                                 Credits_Per_Year__c, Credit_Rate__c, Pricing_Structure__c, Reconciliation_Notes__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Enterprise', after.Package_Tier__c);
        System.assertEquals('Inferred (Enterprise)', after.Unlimited_Lite__c);
        System.assertEquals('Yes', after.Free_Tier_Retained__c);
        System.assertEquals(0.04, after.Overage_Rate__c);
        System.assertEquals(200000, after.Credits_Per_Year__c);
        System.assertEquals(0.05, after.Credit_Rate__c);
        System.assertEquals('Seats: Credit-Based Usage', after.Pricing_Structure__c);
        System.assert(after.Reconciliation_Notes__c.contains('Usage / product'), after.Reconciliation_Notes__c);
    }

    @isTest
    static void usage_upsellLatestWinsRateBlendsAndOrderDoesNotMatter() {
        // NB: Team, Unlimited Lite stated Yes, 200k credits/yr at 0.05, overage 0.04.
        // Upsell: silent on tier, Lite only inferred, +100k credits/yr at 0.02, overage 0.03.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{
            'Package_Tier__c' => 'Team', 'Unlimited_Lite__c' => 'Yes', 'Overage_Rate__c' => 0.04,
            'Credits_Purchased__c' => 200000, 'Credits_Period__c' => 'year', 'Credits_Per_Year__c' => 200000,
            'Credit_Rate__c' => 0.05 });
        Opportunity up = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{
            'Package_Tier__c' => 'Not specified', 'Unlimited_Lite__c' => 'Inferred (Enterprise)',
            'Overage_Rate__c' => 0.03, 'Credits_Added__c' => 100000, 'Credits_Period__c' => 'year',
            'Contract_Length_Months__c' => 12, 'Credit_Rate__c' => 0.02 });

        Test.startTest();
        runOne(ofeNb.Id);
        runOne(ofeUp.Id);
        runOne(ofeNb.Id);   // re-applying the older paper must not roll the contract back
        Test.stopTest();

        Contract after = [SELECT Package_Tier__c, Unlimited_Lite__c, Overage_Rate__c, Credits_Per_Year__c,
                                 Credit_Rate__c, Needs_Legal_Review__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Team', after.Package_Tier__c, 'A silent paper never erases');
        System.assertEquals('Yes', after.Unlimited_Lite__c, 'An inference never overrides a stated Yes');
        System.assertEquals(0.03, after.Overage_Rate__c, 'Latest stated rate wins, whatever the apply order');
        System.assertEquals(300000, after.Credits_Per_Year__c, '200k + 100k added');
        System.assertEquals(0.04, after.Credit_Rate__c, '(0.05 x 200k + 0.02 x 100k) / 300k');
        System.assertEquals(false, after.Needs_Legal_Review__c, 'Usage changes never trigger legal review');
    }

    @isTest
    static void usage_coTermedCreditsAddedAreAnnualised() {
        // Corvex-style: +1M credits for a 6-month co-termed remainder = 2M per year.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{
            'Credits_Per_Year__c' => 1000000, 'Credit_Rate__c' => 0.04 });
        Opportunity up = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{
            'Credits_Added__c' => 1000000, 'Credits_Period__c' => 'contract', 'Contract_Length_Months__c' => 6 });

        Test.startTest();
        runOne(ofeNb.Id);
        runOne(ofeUp.Id);
        Test.stopTest();

        Contract after = [SELECT Credits_Per_Year__c, Credit_Rate__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(3000000, after.Credits_Per_Year__c, '1M + 1M x 12/6');
        System.assertEquals(0.04, after.Credit_Rate__c, 'An unpriced tranche does not move the blended rate');
    }

    @isTest
    static void usage_backfillRecomputesWithoutTouchingLegalTerms() {
        // A contract whose deal was applied before the usage fields existed.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        makeOfe(nb.Id, new Map<String, Object>{
            'Applied_Contract__c' => c.Id, 'Is_Current__c' => true,
            'Package_Tier__c' => 'Team', 'Credits_Per_Year__c' => 100000, 'Credit_Rate__c' => 0.05,
            'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        ContractUsageRollup.runBackfill();
        Test.stopTest();

        Contract after = [SELECT Package_Tier__c, Credits_Per_Year__c, Credit_Rate__c, Pricing_Structure__c,
                                 Payment_Terms__c, Needs_Legal_Review__c, Reconciliation_Notes__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Team', after.Package_Tier__c);
        System.assertEquals(100000, after.Credits_Per_Year__c);
        System.assertEquals(0.05, after.Credit_Rate__c);
        System.assertEquals('Seats: Credit-Based Usage', after.Pricing_Structure__c);
        System.assertEquals(null, after.Payment_Terms__c, 'Backfill never applies legal terms');
        System.assertEquals(false, after.Needs_Legal_Review__c);
        System.assert(after.Reconciliation_Notes__c.contains('recomputed'), after.Reconciliation_Notes__c);
        System.assertEquals(0, ContractUsageRollup.refresh(new Set<Id>{ c.Id }), 'Idempotent: nothing left to change');
    }

    @isTest
    static void notSpecified_isSilentNeverATermOrConflict() {
        // Janssen: "Wrote Rate_Limitable__c = Not specified (new term)".
        Account a = makeAccount();
        Contract fresh = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', fresh.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{ 'Rate_Limitable__c' => 'Not specified' });

        Contract amended = makeContract(a.Id, new Map<String, Object>{ 'Rate_Limitable__c' => 'Yes' });
        Opportunity base = makeOpp(a.Id, 'New Business', amended.Id, null);
        Opportunity up = makeOpp(a.Id, 'Upsell', null, base.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{ 'Rate_Limitable__c' => 'Not specified' });

        Test.startTest();
        runOne(ofeNb.Id);
        ContractLegalTermsApplier.Result upRes = runOne(ofeUp.Id);
        Test.stopTest();

        System.assertEquals(null, [SELECT Rate_Limitable__c FROM Contract WHERE Id = :fresh.Id].Rate_Limitable__c);
        Contract after = [SELECT Rate_Limitable__c, Needs_Legal_Review__c FROM Contract WHERE Id = :amended.Id];
        System.assertEquals('Yes', after.Rate_Limitable__c);
        System.assertEquals(false, after.Needs_Legal_Review__c);
        System.assertEquals(false, upRes.needsReview);
    }

    @isTest
    static void specialTerms_accumulateOnAmendmentsWithoutReview() {
        // Siris / Finnea: each paper's special terms differ in wording - that is
        // not a legal conflict. They stack under a label for the deal.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{ 'Special_Terms__c' => 'MFN clause.' });
        Opportunity base = makeOpp(a.Id, 'New Business', c.Id, null);
        Opportunity up = makeOpp(a.Id, 'Upsell', null, base.Id);
        Order_Form_Extraction__c ofeUp = makeOfe(up.Id, new Map<String, Object>{
            'Special_Terms__c' => 'Additional users at $5,000 per user per year, co-termed.' });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofeUp.Id);
        runOne(ofeUp.Id);   // re-applying the same paper adds nothing
        Test.stopTest();

        Contract after = [SELECT Special_Terms__c, Needs_Legal_Review__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(false, res.needsReview);
        System.assertEquals(false, after.Needs_Legal_Review__c);
        System.assert(after.Special_Terms__c.startsWith('MFN clause.'), after.Special_Terms__c);
        System.assert(after.Special_Terms__c.contains('[Upsell Opp, closed '), after.Special_Terms__c);
        System.assertEquals(1, after.Special_Terms__c.countMatches('co-termed'), 'Added once: ' + after.Special_Terms__c);
    }

    @isTest
    static void freeText_rewordingIsNotedNotFlagged() {
        // Great Hill / Annaly: the amendment re-reads the same MSA clause and the
        // model words it differently. A structured term still conflicts.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Subprocessor_Restrictions__c' => 'Arvo may not amend the DPA adversely without Client consent (Rider 2.1).',
            'Rate_Limit_Notes__c' => 'Rogo may throttle excessive use.'
        });
        Opportunity o = makeOpp(a.Id, 'Upsell', c.Id, null);
        Order_Form_Extraction__c ofe = makeOfe(o.Id, new Map<String, Object>{
            'Subprocessor_Restrictions__c' => 'DPA may not be amended in a way that adversely affects Client without its consent (Rider Section 2.1).',
            'Rate_Limit_Notes__c' => 'Excessive use may be limited or throttled by Rogo.'
        });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        Contract after = [
            SELECT Subprocessor_Restrictions__c, Rate_Limit_Notes__c, Needs_Legal_Review__c, Reconciliation_Notes__c
            FROM Contract WHERE Id = :c.Id
        ];
        System.assertEquals(false, res.needsReview, res.notes);
        System.assertEquals(false, after.Needs_Legal_Review__c);
        System.assert(after.Subprocessor_Restrictions__c.startsWith('Arvo may not amend'), 'contract keeps its text');
        System.assertEquals('Rogo may throttle excessive use.', after.Rate_Limit_Notes__c);
        System.assert(after.Reconciliation_Notes__c.contains('Kept Subprocessor_Restrictions__c (this order words it differently'),
            after.Reconciliation_Notes__c);
        System.assert(!after.Reconciliation_Notes__c.contains('CONFLICT'), after.Reconciliation_Notes__c);
    }

    // ===== Legal's "Model changes: notice or approval" column =====

    @isTest
    static void modelChange_freshWritesAmendmentSilenceKeepsAndConflictFlags() {
        Account a = makeAccount();
        Contract c = makeContract(a.Id, null);
        Opportunity nb = makeOpp(a.Id, 'New Business', c.Id, null);
        Order_Form_Extraction__c ofeNb = makeOfe(nb.Id, new Map<String, Object>{
            'Model_Change_Requirement__c' => 'Approval',
            'Model_Change_Terms__c' => 'Approval: Before introducing a model outside the approved list; no fixed lead time. AI Schedule §4.' });
        // An upsell paper without the MSA's AI terms: silence, never an override.
        Opportunity up1 = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeSilent = makeOfe(up1.Id, new Map<String, Object>{
            'Model_Change_Requirement__c' => 'None identified',
            'Model_Change_Terms__c' => 'None identified: No notice or approval requirement identified.' });
        // A different real answer: legal review, contract unchanged.
        Opportunity up2 = makeOpp(a.Id, 'Upsell', null, nb.Id);
        Order_Form_Extraction__c ofeDiffers = makeOfe(up2.Id, new Map<String, Object>{
            'Model_Change_Requirement__c' => 'Notice',
            'Model_Change_Terms__c' => 'Notice: 30 days before material model changes; customer may reject. §2.3.' });

        Test.startTest();
        runOne(ofeNb.Id);
        ContractLegalTermsApplier.Result silentRes = runOne(ofeSilent.Id);
        Contract afterSilent = [SELECT Model_Change_Requirement__c, Model_Change_Terms__c, Needs_Legal_Review__c
                                FROM Contract WHERE Id = :c.Id];
        ContractLegalTermsApplier.Result differsRes = runOne(ofeDiffers.Id);
        Test.stopTest();

        System.assertEquals('Approval', afterSilent.Model_Change_Requirement__c);
        System.assert(afterSilent.Model_Change_Terms__c.startsWith('Approval: Before introducing'), afterSilent.Model_Change_Terms__c);
        System.assertEquals(false, silentRes.needsReview);
        System.assertEquals(false, afterSilent.Needs_Legal_Review__c);

        Contract after = [SELECT Model_Change_Requirement__c, Needs_Legal_Review__c, Reconciliation_Notes__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals(true, differsRes.needsReview);
        System.assertEquals('Approval', after.Model_Change_Requirement__c, 'Conflict never overwrites');
        System.assertEquals(true, after.Needs_Legal_Review__c);
        System.assert(after.Reconciliation_Notes__c.contains('CONFLICT Model_Change_Requirement__c'), after.Reconciliation_Notes__c);
    }

    @isTest
    static void modelChange_realAnswerReplacesUnresolved() {
        // The NB paper referenced an AI Schedule that wasn't attached; the upsell's paper has it.
        Account a = makeAccount();
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Model_Change_Requirement__c' => 'Unresolved',
            'Model_Change_Terms__c' => 'Unresolved: Referenced AI Schedule is missing.' });
        Opportunity base = makeOpp(a.Id, 'New Business', c.Id, null);
        Opportunity up = makeOpp(a.Id, 'Upsell', null, base.Id);
        Order_Form_Extraction__c ofe = makeOfe(up.Id, new Map<String, Object>{
            'Model_Change_Requirement__c' => 'Notice',
            'Model_Change_Terms__c' => 'Notice: 30 days before material model changes; customer may reject. AI Schedule §2.3.' });

        Test.startTest();
        ContractLegalTermsApplier.Result res = runOne(ofe.Id);
        Test.stopTest();

        Contract after = [SELECT Model_Change_Requirement__c, Model_Change_Terms__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals(false, res.needsReview);
        System.assertEquals('Notice', after.Model_Change_Requirement__c);
        System.assert(after.Model_Change_Terms__c.contains('AI Schedule §2.3'), after.Model_Change_Terms__c);
    }
}
