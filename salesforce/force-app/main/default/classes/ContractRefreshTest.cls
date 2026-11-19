@isTest
private class ContractRefreshTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'CRefresh_Test_Bypass', Label = 'CRefresh Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    private static Account account(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    private static Contract makeContract(Id accountId) {
        Contract c = new Contract(AccountId = accountId, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        insert c;
        return c;
    }

    private static Opportunity closedOpp(Id accountId, String name, Integer daysAgo, Id contractId) {
        Opportunity o = new Opportunity(Name = name, StageName = 'Closed Won', AccountId = accountId, Type = 'New Business',
            CloseDate = Date.today().addDays(-daysAgo), ContractId = contractId);
        insert o;
        return o;
    }

    private static Order_Form_Extraction__c ofe(Id oppId, Boolean current, Id appliedTo) {
        Order_Form_Extraction__c r = new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Is_Current__c = current, Extracted_At__c = System.now().addDays(current ? -1 : -30),
            Applied_Contract__c = appliedTo, Payment_Terms__c = 'Annual');
        insert r;
        return r;
    }

    @isTest
    static void picksOnlyAccountsWhoseContractsAreBehind() {
        // Behind: extracted at close, contract created afterwards, never applied.
        Account late = account('Refresh Late');
        Contract cLate = makeContract(late.Id);
        ofe(closedOpp(late.Id, 'Late NB', 5, cLate.Id).Id, true, null);

        // Waiting: a new deal whose own contract does not exist yet; the old deal is applied.
        Account waiting = account('Refresh Waiting');
        Contract cOld = makeContract(waiting.Id);
        ofe(closedOpp(waiting.Id, 'Waiting Old NB', 400, cOld.Id).Id, true, cOld.Id);
        ofe(closedOpp(waiting.Id, 'Waiting New NB', 1, null).Id, true, null);

        // Harmless: an old version beside its deal's current one.
        Account beside = account('Refresh Beside');
        Contract cBeside = makeContract(beside.Id);
        Opportunity oBeside = closedOpp(beside.Id, 'Beside NB', 50, cBeside.Id);
        ofe(oBeside.Id, true, cBeside.Id);
        ofe(oBeside.Id, false, cBeside.Id);

        // Moved off: the deal is now on another contract; its old version still counts on the first.
        Account moved = account('Refresh Moved');
        Contract cFirst = makeContract(moved.Id);
        Contract cSecond = makeContract(moved.Id);
        Opportunity oMoved = closedOpp(moved.Id, 'Moved NB', 60, cSecond.Id);
        ofe(oMoved.Id, true, cSecond.Id);
        ofe(oMoved.Id, false, cFirst.Id);

        // Pointer: the contract still points at a superseded read.
        Account pointer = account('Refresh Pointer');
        Contract cPointer = makeContract(pointer.Id);
        Opportunity oPointer = closedOpp(pointer.Id, 'Pointer NB', 70, cPointer.Id);
        ofe(oPointer.Id, true, cPointer.Id);
        Order_Form_Extraction__c superseded = ofe(oPointer.Id, false, null);
        update new Contract(Id = cPointer.Id, Latest_Order_Form_Extraction__c = superseded.Id);

        ContractRefresh.Selection s = ContractRefresh.stale();
        System.assertEquals(new Set<Id>{ late.Id, moved.Id, pointer.Id }, s.reasons.keySet(), String.valueOf(s.reasons));
        System.assert(s.reasons.get(late.Id).contains(ContractRefresh.UNAPPLIED));
        System.assert(s.reasons.get(moved.Id).contains(ContractRefresh.MOVED_OFF));
        System.assert(s.reasons.get(pointer.Id).contains(ContractRefresh.POINTER));
        System.assertEquals(1, s.waitingForContract, 'the new deal waits for its contract');
        System.assertEquals(1, s.harmless);
    }

    @isTest
    static void theNightlyRunRebuildsThem() {
        Account late = account('Refresh Run');
        Contract c = makeContract(late.Id);
        Order_Form_Extraction__c r = ofe(closedOpp(late.Id, 'Run NB', 5, c.Id).Id, true, null);

        Test.startTest();
        new ContractRefreshScheduler().execute(null);
        Test.stopTest();

        Contract after = [SELECT Payment_Terms__c, Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assert(after.Reconciliation_Notes__c.startsWith('Rebuilt '), after.Reconciliation_Notes__c);
        System.assertEquals(c.Id, [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Id = :r.Id].Applied_Contract__c);
        System.assert(ContractRefresh.stale().reasons.isEmpty(), 'in step afterwards');
    }

    @isTest
    static void nothingBehind_startsNothing() {
        System.assert(ContractRefresh.run().startsWith('All contracts are in step'));
        try {
            new ContractRefresh().call('other', null);
            System.assert(false, 'an unknown action is refused');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('other'));
        }
    }

    @isTest
    static void canBeScheduled() {
        Test.startTest();
        Id jobId = System.schedule('Contract refresh test', '0 17 2 * * ?', new ContractRefreshScheduler());
        Test.stopTest();
        System.assertEquals('0 17 2 * * ?', [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);
    }
}
