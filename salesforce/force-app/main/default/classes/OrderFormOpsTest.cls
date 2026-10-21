@isTest
private class OrderFormOpsTest {

    // Closed Won opportunities are inserted directly: grant the Bypass_Validations
    // custom permission in its own transaction (as the other order form tests do).
    @testSetup
    static void grantValidationBypass() {
        List<CustomPermission> perms = [
            SELECT Id FROM CustomPermission WHERE DeveloperName = 'Bypass_Validations' LIMIT 1
        ];
        if (perms.isEmpty()) return;
        PermissionSet ps = new PermissionSet(Name = 'OFOps_Test_Bypass', Label = 'OFOps Test Bypass');
        insert ps;
        insert new SetupEntityAccess(ParentId = ps.Id, SetupEntityId = perms[0].Id);
        insert new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = ps.Id);
    }

    // A Messages API reply whose text is a complete order form read.
    private class MockAnthropic implements HttpCalloutMock {
        Integer noticeDays;
        MockAnthropic(Integer noticeDays) { this.noticeDays = noticeDays; }
        public HttpResponse respond(HttpRequest req) {
            Map<String, Object> fields = new Map<String, Object>{
                'Documents' => new List<Object>{ new Map<String, Object>{
                    'file' => 'FILE 1 (CURRENT DEAL): signed__OrderForm', 'group' => 'Current', 'class' => 'Order Form' } },
                'Contract_Start_Date' => '2026-01-01',
                'Contract_Length_Months' => 12,
                'Total_Contract_Value' => 10000,
                'Subprocessor_Notice_Period_Days' => noticeDays
            };
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => 'claude-sonnet-5',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(fields) } },
                'stop_reason' => 'end_turn',
                'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 200 }
            }));
            return r;
        }
    }

    private static Contract makeContract(Id accountId, Map<String, Object> values) {
        Contract c = new Contract(AccountId = accountId, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12);
        if (values != null) for (String k : values.keySet()) c.put(k, values.get(k));
        insert c;
        return c;
    }

    private static Opportunity closedOpp(Id accountId, String name, String type, Integer daysAgo, Id contractId, Id baseId) {
        Opportunity o = new Opportunity(Name = name, StageName = 'Closed Won', AccountId = accountId, Type = type,
            CloseDate = Date.today().addDays(-daysAgo), ContractId = contractId, Base_Opportunity__c = baseId);
        insert o;
        return o;
    }

    private static Order_Form_Extraction__c currentOfe(Id oppId, Id appliedTo, Map<String, Object> values) {
        Order_Form_Extraction__c r = new Order_Form_Extraction__c(Opportunity__c = oppId, Extraction_Status__c = 'Success',
            Is_Current__c = true, Extracted_At__c = System.now().addDays(-30), Applied_Contract__c = appliedTo);
        if (values != null) for (String k : values.keySet()) r.put(k, values.get(k));
        insert r;
        return r;
    }

    private static void attachFile(Id parentId) {
        insert new ContentVersion(Title = 'signed__Order Form', PathOnClient = 'signed__Order Form.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake pdf bytes for unit test'), FirstPublishLocationId = parentId);
    }

    @isTest
    static void rebuildContract_reappliesItsDealsOldestFirst() {
        Account a = new Account(Name = 'Rebuild Co');
        insert a;
        // Wrong terms left by another deal's paper, flagged for review.
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Subprocessor_Notice_Period__c' => 99, 'Needs_Legal_Review__c' => true });
        Opportunity nb = closedOpp(a.Id, 'Rebuild NB', 'New Business', 400, c.Id, null);
        Opportunity up = closedOpp(a.Id, 'Rebuild Upsell', 'Upsell', 10, null, nb.Id);
        currentOfe(up.Id, c.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 30, 'ELA__c' => true });
        currentOfe(nb.Id, c.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 30 });

        Test.startTest();
        ContractRebuildAction.Request req = new ContractRebuildAction.Request();
        req.recordId = c.Id;
        String message = ContractRebuildAction.run(new List<ContractRebuildAction.Request>{ req })[0].message;
        Test.stopTest();

        System.assert(message.startsWith('Rebuilding contract'), message);
        Contract after = [SELECT Subprocessor_Notice_Period__c, ELA__c, Needs_Legal_Review__c, Reconciliation_Notes__c
                          FROM Contract WHERE Id = :c.Id];
        System.assertEquals(30, after.Subprocessor_Notice_Period__c, 'the deals\' terms, not the stray 99');
        System.assertEquals(true, after.ELA__c, 'the upsell added ELA');
        System.assertEquals(false, after.Needs_Legal_Review__c, 'the deals agree, so no conflict is left');
        System.assert(after.Reconciliation_Notes__c.startsWith('Rebuilt '), after.Reconciliation_Notes__c);
        System.assert(after.Reconciliation_Notes__c.indexOf('[Rebuild NB]') < after.Reconciliation_Notes__c.indexOf('[Rebuild Upsell]'),
            'new business first, then the upsell');
        for (Order_Form_Extraction__c r : [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Opportunity__r.AccountId = :a.Id]) {
            System.assertEquals(c.Id, r.Applied_Contract__c);
        }
    }

    @isTest
    static void rebuildContract_movesAMisappliedDealToItsOwnContract() {
        Account a = new Account(Name = 'Widen Co');
        insert a;
        Contract own = makeContract(a.Id, null);
        Contract wrong = makeContract(a.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 45 });
        Opportunity nb = closedOpp(a.Id, 'Widen NB', 'New Business', 400, own.Id, null);
        Opportunity up = closedOpp(a.Id, 'Widen Upsell', 'Upsell', 10, null, nb.Id);
        currentOfe(nb.Id, own.Id, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });
        currentOfe(up.Id, wrong.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 45 });

        Test.startTest();
        OrderFormOps.rebuildContract(wrong.Id);
        Test.stopTest();

        Contract w = [SELECT Subprocessor_Notice_Period__c, Reconciliation_Notes__c FROM Contract WHERE Id = :wrong.Id];
        System.assertEquals(null, w.Subprocessor_Notice_Period__c, 'the upsell\'s terms leave the wrong contract');
        System.assert(w.Reconciliation_Notes__c.endsWith(OrderFormOps.NONE_LANDED), w.Reconciliation_Notes__c);
        Contract o = [SELECT Subprocessor_Notice_Period__c, Payment_Terms__c, Reconciliation_Notes__c FROM Contract WHERE Id = :own.Id];
        System.assertEquals(45, o.Subprocessor_Notice_Period__c, 'the upsell lands on its base deal\'s contract');
        System.assertEquals('Annual', o.Payment_Terms__c, 'rebuilt with its own new business too');
        System.assert(o.Reconciliation_Notes__c.contains('[Widen NB]') && o.Reconciliation_Notes__c.contains('[Widen Upsell]'));
    }

    @isTest
    static void rerunOpportunity_replacesTheCurrentReadAndRebuildsItsContract() {
        Account a = new Account(Name = 'Rerun Co');
        insert a;
        Contract c = makeContract(a.Id, new Map<String, Object>{ 'Subprocessor_Notice_Period__c' => 99 });
        Opportunity nb = closedOpp(a.Id, 'Rerun NB', 'New Business', 100, c.Id, null);
        Order_Form_Extraction__c old = currentOfe(nb.Id, c.Id, new Map<String, Object>{
            'Subprocessor_Notice_Period__c' => 99, 'Rerun__c' => true });
        attachFile(nb.Id);
        Test.setMock(HttpCalloutMock.class, new MockAnthropic(45));

        Test.startTest();
        OrderFormRerunOpportunityAction.Request req = new OrderFormRerunOpportunityAction.Request();
        req.recordId = nb.Id;
        String message = OrderFormRerunOpportunityAction.run(new List<OrderFormRerunOpportunityAction.Request>{ req })[0].message;
        Test.stopTest();

        System.assert(message.startsWith('Re-reading Rerun NB'), message);
        Order_Form_Extraction__c cur = [SELECT Id, Supersedes__c, Applied_Contract__c, Subprocessor_Notice_Period__c
                                        FROM Order_Form_Extraction__c WHERE Opportunity__c = :nb.Id AND Is_Current__c = true];
        System.assertNotEquals(old.Id, cur.Id, 'the re-read is the current row');
        System.assertEquals(old.Id, cur.Supersedes__c, 'and points back at the old one');
        System.assertEquals(45, cur.Subprocessor_Notice_Period__c);
        System.assertEquals(c.Id, cur.Applied_Contract__c, 'applied in the rebuild');
        System.assertEquals(false, [SELECT Rerun__c FROM Order_Form_Extraction__c WHERE Id = :old.Id].Rerun__c);
        System.assertEquals(45, [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :c.Id].Subprocessor_Notice_Period__c);
    }

    @isTest
    static void rerunOpportunity_keepsAFullerReadOverOneThatDroppedFiles() {
        Account a = new Account(Name = 'Fuller Co');
        insert a;
        Contract c = makeContract(a.Id, null);
        Opportunity nb = closedOpp(a.Id, 'Fuller NB', 'New Business', 100, c.Id, null);
        // e.g. written by the large-document script: every file read.
        Order_Form_Extraction__c old = currentOfe(nb.Id, c.Id, new Map<String, Object>{
            'Subprocessor_Notice_Period__c' => 77, 'Docs_Dropped__c' => false });
        attachFile(nb.Id);
        insert new ContentVersion(Title = 'Redline', PathOnClient = 'Redline.docx',
            VersionData = Blob.valueOf('docx bytes'), FirstPublishLocationId = nb.Id);   // not readable in Apex
        Test.setMock(HttpCalloutMock.class, new MockAnthropic(45));

        Test.startTest();
        OrderFormOps.rerunOpportunity(nb.Id);
        Test.stopTest();

        Order_Form_Extraction__c reread = [SELECT Is_Current__c, Supersedes__c, Docs_Dropped__c FROM Order_Form_Extraction__c
                                           WHERE Opportunity__c = :nb.Id AND Id != :old.Id];
        System.assertEquals(true, reread.Docs_Dropped__c);
        System.assertEquals(false, reread.Is_Current__c, 'kept as history only');
        System.assertEquals(old.Id, reread.Supersedes__c);
        System.assertEquals(true, [SELECT Is_Current__c FROM Order_Form_Extraction__c WHERE Id = :old.Id].Is_Current__c);
        System.assertEquals(77, [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :c.Id].Subprocessor_Notice_Period__c);
    }

    @isTest
    static void rerunAccount_rereadsDealsWithFilesThenRebuilds() {
        Account a = new Account(Name = 'Account Rerun Co');
        insert a;
        Contract c = makeContract(a.Id, null);
        Opportunity nb = closedOpp(a.Id, 'Account Rerun NB', 'New Business', 100, c.Id, null);
        attachFile(nb.Id);
        Test.setMock(HttpCalloutMock.class, new MockAnthropic(60));

        Test.startTest();
        OrderFormRerunAccountAction.Request req = new OrderFormRerunAccountAction.Request();
        req.recordId = a.Id;
        String message = OrderFormRerunAccountAction.run(new List<OrderFormRerunAccountAction.Request>{ req })[0].message;
        Test.stopTest();

        System.assert(message.startsWith('Re-reading 1 deal(s) on Account Rerun Co'), message);
        System.assertEquals(60, [SELECT Subprocessor_Notice_Period__c FROM Contract WHERE Id = :c.Id].Subprocessor_Notice_Period__c,
            'a first read is applied in the account rebuild');
    }

    @isTest
    static void nothingToDo_saysSo() {
        Account a = new Account(Name = 'No Files Co');
        insert a;
        Opportunity nb = closedOpp(a.Id, 'No Files NB', 'New Business', 100, null, null);

        System.assert(OrderFormOps.rerunAccount(a.Id).startsWith('No closed-won deals with files'));
        System.assert(OrderFormOps.rerunOpportunity(nb.Id).startsWith('No files on No Files NB'));
        System.assertEquals('Account not found.', OrderFormOps.rerunAccount(null));
        System.assertEquals('Opportunity not found.', OrderFormOps.rerunOpportunity(null));
        System.assertEquals('Contract not found.', OrderFormOps.rebuildContract(null));
        System.assertEquals('Account not found.', OrderFormOps.rebuildAccount(null));
        System.assertEquals(0, OrderFormOps.rebuild(null, null).size());
    }

    @isTest
    static void continuation_addsToTheNotes() {
        Account a = new Account(Name = 'Continue Co');
        insert a;
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Reconciliation_Notes__c' => 'Rebuilt today.\n\n' + OrderFormOps.NONE_LANDED });
        Opportunity nb = closedOpp(a.Id, 'Continue NB', 'New Business', 100, c.Id, null);
        Order_Form_Extraction__c r = currentOfe(nb.Id, null, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        List<Id> left = OrderFormOps.applyInOrder(new List<Id>{ r.Id }, false);
        String notes = [SELECT Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id].Reconciliation_Notes__c;
        System.enqueueJob(new ContractRebuildJob(new Set<Id>{ a.Id }, null));
        Test.stopTest();

        System.assertEquals(0, left.size());
        System.assert(notes.startsWith('Rebuilt today.') && notes.contains('[Continue NB]'), notes);
        System.assert(!notes.contains(OrderFormOps.NONE_LANDED), 'the placeholder goes once a deal lands: ' + notes);
        String rebuilt = [SELECT Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id].Reconciliation_Notes__c;
        System.assert(rebuilt.startsWith('Rebuilt ' + String.valueOf(Date.today())) && rebuilt.contains('[Continue NB]'), rebuilt);
    }

    @isTest
    static void followUpJob_appliesTheRestAndAddsToTheNotes() {
        Account a = new Account(Name = 'Follow Up Co');
        insert a;
        Contract c = makeContract(a.Id, new Map<String, Object>{
            'Reconciliation_Notes__c' => 'Rebuilt today.\n\n' + OrderFormOps.NONE_LANDED });
        Opportunity nb = closedOpp(a.Id, 'Follow Up NB', 'New Business', 100, c.Id, null);
        Order_Form_Extraction__c r = currentOfe(nb.Id, null, new Map<String, Object>{ 'Payment_Terms__c' => 'Annual' });

        Test.startTest();
        System.enqueueJob(new ContractRebuildJob(new List<Id>{ r.Id }));
        Test.stopTest();

        Contract after = [SELECT Payment_Terms__c, Reconciliation_Notes__c FROM Contract WHERE Id = :c.Id];
        System.assertEquals('Annual', after.Payment_Terms__c);
        System.assert(after.Reconciliation_Notes__c.startsWith('Rebuilt today.')
            && after.Reconciliation_Notes__c.contains('[Follow Up NB]'), after.Reconciliation_Notes__c);
        System.assert(!after.Reconciliation_Notes__c.contains(OrderFormOps.NONE_LANDED), after.Reconciliation_Notes__c);
        System.assertEquals(c.Id, [SELECT Applied_Contract__c FROM Order_Form_Extraction__c WHERE Id = :r.Id].Applied_Contract__c);
    }
}
