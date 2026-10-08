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
}
