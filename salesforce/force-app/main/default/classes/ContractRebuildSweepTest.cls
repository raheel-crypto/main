@isTest
private class ContractRebuildSweepTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'CRSweep_Test_Bypass', Label = 'CRSweep Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private static Contract makeContract(Id accountId, Map<String, Object> values) {
        Contract c = new Contract(AccountId = accountId, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        if (values != null) for (String k : values.keySet()) c.put(k, values.get(k));
        insert c;
        return c;
    }

    private static Opportunity closedOpp(Id accountId, String name, Integer daysAgo, Id contractId) {
        Opportunity o = new Opportunity(Name = name, StageName = 'Closed Won', AccountId = accountId, Type = 'New Business',
            CloseDate = Date.today().addDays(-daysAgo), ContractId = contractId);
        insert o;
        return o;
    }

    private static Order_Form_Extraction__c currentOfe(Id oppId, Id appliedTo, Map<String, Object> values) {
        Order_Form_Extraction__c r = new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now().addDays(-1), Applied_Contract__c = appliedTo);
        if (values != null) for (String k : values.keySet()) r.put(k, values.get(k));
        insert r;
        return r;
    }

    @isTest
    static void rebuildsEachAccountsContractsFromTheirCurrentExtractions() {
        Account a = new Account(Name = 'Sweep A');
        Account b = new Account(Name = 'Sweep B');
        insert new List<Account>{ a, b };
        // A: a stray value from old paper; its re-read deal is on no contract yet.
        Contract ca = makeContract(a.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 99 });
        Opportunity oa = closedOpp(a.Id, 'Sweep A NB', 100, ca.Id);
        Order_Form_Extraction__c ra = currentOfe(oa.Id, null, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 30 });
        // B: already applied, but the contract lost a term.
        Contract cb = makeContract(b.Id, null);
        Opportunity ob = closedOpp(b.Id, 'Sweep B NB', 50, cb.Id);
        currentOfe(ob.Id, cb.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        System.enqueueJob(new ContractRebuildSweep(new List<Id>{ a.Id, b.Id }));
        Test.stopTest();

        Contract afterA = [SELECT Subprocessor_Notice_Period__c, Reconciliation_Notes__c FROM Contract WHERE Id = :ca.Id];
        System.assertEquals(30, afterA.Subprocessor_Notice_Period__c, 'the current extraction, not the stray 99');
        System.assert(afterA.Reconciliation_Notes__c.startsWith('Rebuilt '), afterA.Reconciliation_Notes__c);
        System.assertEquals(ca.Id, [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Id = :ra.Id].Applied_Contract__c);
        Contract afterB = [SELECT Payment_Terms__c, Reconciliation_Notes__c FROM Contract WHERE Id = :cb.Id];
        System.assertEquals('Annual', afterB.Payment_Terms__c, 'the second account is rebuilt too');
        System.assert(afterB.Reconciliation_Notes__c.contains('[Sweep B NB]'), afterB.Reconciliation_Notes__c);
    }

    @isTest
    static void aContinuationFinishesTheAccountsDeals() {
        Account a = new Account(Name = 'Sweep Continue');
        insert a;
        Contract c = makeContract(a.Id, new Map<String, Object>{ 'Reconciliation_Notes__c' => 'Rebuilt today.' });
        Opportunity o = closedOpp(a.Id, 'Sweep Continue NB', 20, c.Id);
        Order_Form_Extraction__c r = currentOfe(o.Id, null, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        System.enqueueJob(new ContractRebuildSweep(new List<Id>(), new List<Id>{ r.Id }));
        Test.stopTest();

        Contract after = [SELECT Payment_Terms__c, Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assert(after.Reconciliation_Notes__c.startsWith('Rebuilt today.')
            && after.Reconciliation_Notes__c.contains('[Sweep Continue NB]'), after.Reconciliation_Notes__c);
    }

    @isTest
    static void nothingToDo() {
        Test.startTest();
        System.enqueueJob(new ContractRebuildSweep(new List<Id>()));
        System.enqueueJob(new ContractRebuildSweep(null));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Contract]);
    }
}
