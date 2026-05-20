@isTest
private class AccountHierarchyControllerTest {

    private class AnthropicMock implements HttpCalloutMock {
        private String body;
        public AnthropicMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            System.assert(req.getEndpoint().contains('Anthropic_Claude'), 'Should call Named Credential');
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":' +
                JSON.serialize(this.body) + '}],"model":"claude","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}');
            return res;
        }
    }

    private static List<Account> seedOaklinsFamily() {
        List<Account> accs = new List<Account>{
            new Account(Name = 'Oaklins Germany', Website = 'https://oaklins.de', BillingCountry = 'Germany'),
            new Account(Name = 'Oaklins France',  Website = 'https://oaklins.fr', BillingCountry = 'France'),
            new Account(Name = 'Oaklins UK',      Website = 'https://oaklins.co.uk', BillingCountry = 'United Kingdom'),
            new Account(Name = 'Oaklins Australia', Website = 'http://www.oaklins.com.au/', BillingCountry = 'Australia')
        };
        insert accs;
        return accs;
    }

    @isTest
    static void scan_groupsCountryOfficesByBrand() {
        seedOaklinsFamily();
        // Second smaller family — forces the size comparator to actually run.
        insert new List<Account>{
            new Account(Name = 'Acme US', Website = 'acme.com', BillingCountry = 'United States'),
            new Account(Name = 'Acme DE', Website = 'acme.de', BillingCountry = 'Germany')
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result = AccountHierarchyController.scanFamilies();
        Test.stopTest();

        System.assertEquals(6, result.totalAccountsScanned, 'Should scan all inserted accounts');
        System.assertEquals(2, result.families.size(), 'Should cluster into two brand families');
        // Largest family first.
        System.assertEquals('oaklins', result.families[0].brandLabel);
        System.assertEquals(4, result.families[0].accountCount);
        System.assertEquals('acme', result.families[1].brandLabel);
        System.assertEquals(2, result.families[1].accountCount);
    }

    @isTest
    static void propose_parsesClaudeJsonAndAssignsParents() {
        List<Account> accs = seedOaklinsFamily();

        // Build a fake Claude response declaring one of them as ultimate parent.
        String claudeJson =
            '{"summary":"Oaklins International should sit above the country offices.",' +
            '"ultimateParentAccountId":"' + accs[0].Id + '",' +
            '"gaps":[],' +
            '"relationships":[' +
                '{"childAccountId":"' + accs[1].Id + '","parentRef":"' + accs[0].Id + '","rationale":"DE child"},' +
                '{"childAccountId":"' + accs[2].Id + '","parentRef":"' + accs[0].Id + '","rationale":"FR child"},' +
                '{"childAccountId":"' + accs[3].Id + '","parentRef":"' + accs[0].Id + '","rationale":"UK child"}' +
            '],"warnings":[]}';

        Test.setMock(HttpCalloutMock.class, new AnthropicMock(claudeJson));

        AccountHierarchyService.ScanResult scan = AccountHierarchyController.scanFamilies();
        AccountHierarchyService.AccountFamily fam = scan.families[0];

        Test.startTest();
        AccountHierarchyService.HierarchyProposal proposal =
            AccountHierarchyController.proposeHierarchy(fam);
        Test.stopTest();

        System.assert(proposal.hasUltimateParent, 'Ultimate parent should be detected');
        System.assertEquals(accs[0].Id, proposal.ultimateParentNodeId);
        System.assertEquals(4, proposal.nodes.size());
        System.assertEquals(0, proposal.gaps.size());

        Integer changes = 0;
        for (AccountHierarchyService.HierarchyNode n : proposal.nodes) {
            if (n.isChange) changes++;
        }
        System.assertEquals(3, changes, 'Three country offices should be marked as changes');
    }

    @isTest
    static void propose_createsGapWhenNoUltimateParentFound() {
        List<Account> accs = seedOaklinsFamily();

        String claudeJson =
            '{"summary":"No global HQ exists; a gap is needed.",' +
            '"ultimateParentAccountId":null,' +
            '"gaps":[{"gapId":"gap_1","proposedName":"Oaklins International",' +
                '"reason":"No global HQ Account exists.","suggestedWebsite":"oaklins.com","suggestedBillingCountry":null}],' +
            '"relationships":[],' +
            '"warnings":[]}';
        Test.setMock(HttpCalloutMock.class, new AnthropicMock(claudeJson));

        AccountHierarchyService.AccountFamily fam = AccountHierarchyController.scanFamilies().families[0];

        Test.startTest();
        AccountHierarchyService.HierarchyProposal proposal =
            AccountHierarchyController.proposeHierarchy(fam);
        Test.stopTest();

        System.assertEquals(false, proposal.hasUltimateParent);
        System.assertEquals(1, proposal.gaps.size());
        System.assertEquals('gap_1', proposal.ultimateParentNodeId);
        // Every account should be marked as a change pointing at the gap.
        Integer gapPointers = 0;
        for (AccountHierarchyService.HierarchyNode n : proposal.nodes) {
            if (n.kind != 'gap' && n.proposedParentId != null && n.proposedParentId.startsWith('GAP:')) gapPointers++;
        }
        System.assertEquals(4, gapPointers);
    }

    @isTest
    static void apply_updatesParentIdsAndIgnoresSelfReferences() {
        List<Account> accs = seedOaklinsFamily();
        List<AccountHierarchyService.HierarchyChange> changes = new List<AccountHierarchyService.HierarchyChange>();
        AccountHierarchyService.HierarchyChange c1 = new AccountHierarchyService.HierarchyChange();
        c1.accountId = accs[1].Id;
        c1.newParentId = accs[0].Id;
        changes.add(c1);

        // Self-parent should be silently dropped.
        AccountHierarchyService.HierarchyChange selfRef = new AccountHierarchyService.HierarchyChange();
        selfRef.accountId = accs[2].Id;
        selfRef.newParentId = accs[2].Id;
        changes.add(selfRef);

        Test.startTest();
        AccountHierarchyService.ApplyResult result = AccountHierarchyController.applyChanges(changes);
        Test.stopTest();

        System.assertEquals(1, result.applied.size());
        System.assertEquals(0, result.failed.size());
        Account refreshed = [SELECT ParentId FROM Account WHERE Id = :accs[1].Id];
        System.assertEquals(accs[0].Id, refreshed.ParentId);
    }

    @isTest
    static void createGap_insertsAccount() {
        AccountHierarchyService.GapInput input = new AccountHierarchyService.GapInput();
        input.gapName = 'Oaklins International';
        input.website = 'oaklins.com';
        input.description = 'created by test';

        Test.startTest();
        String id = AccountHierarchyController.createGapAccount(input);
        Test.stopTest();

        Account created = [SELECT Name, Website FROM Account WHERE Id = :id];
        System.assertEquals('Oaklins International', created.Name);
        System.assertEquals('oaklins.com', created.Website);
    }

    private class AnthropicErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(401);
            r.setBody('{"error":"invalid api key"}');
            return r;
        }
    }

    private class AnthropicGarbageMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('not actually json');
            return r;
        }
    }

    private class AnthropicEmptyContentMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"id":"x","type":"message","role":"assistant","content":[],"model":"claude"}');
            return r;
        }
    }

    private class AnthropicNonTextMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"id":"x","type":"message","role":"assistant","content":[{"type":"image","source":{}}],"model":"claude"}');
            return r;
        }
    }

    @isTest
    static void anthropicClient_throwsOnNonSuccess() {
        Test.setMock(HttpCalloutMock.class, new AnthropicErrorMock());

        Test.startTest();
        try {
            AnthropicClient.complete('system', 'user', 100);
            System.assert(false, 'Should have thrown');
        } catch (AnthropicClient.AnthropicException e) {
            System.assert(e.getMessage().contains('401'));
        }
        Test.stopTest();
    }

    @isTest
    static void anthropicClient_throwsOnUnparseableBody() {
        Test.setMock(HttpCalloutMock.class, new AnthropicGarbageMock());
        Test.startTest();
        try {
            AnthropicClient.complete('s', 'u', 100);
            System.assert(false, 'Should have thrown');
        } catch (AnthropicClient.AnthropicException e) {
            System.assert(e.getMessage().contains('parse'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void anthropicClient_throwsOnEmptyContent() {
        Test.setMock(HttpCalloutMock.class, new AnthropicEmptyContentMock());
        Test.startTest();
        try {
            AnthropicClient.complete('s', 'u', 100);
            System.assert(false, 'Should have thrown');
        } catch (AnthropicClient.AnthropicException e) {
            System.assert(e.getMessage().contains('content'));
        }
        Test.stopTest();
    }

    @isTest
    static void anthropicClient_throwsOnNonTextContentBlock() {
        Test.setMock(HttpCalloutMock.class, new AnthropicNonTextMock());
        Test.startTest();
        try {
            AnthropicClient.complete('s', 'u', 100);
            System.assert(false, 'Should have thrown');
        } catch (AnthropicClient.AnthropicException e) {
            System.assert(e.getMessage().contains('text'));
        }
        Test.stopTest();
    }

    // ---------- Controller catch-block coverage ----------

    @isTest
    static void controller_proposeHierarchy_wrapsServiceErrors() {
        Test.startTest();
        try {
            AccountHierarchyController.proposeHierarchy(null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void controller_createGapAccount_wrapsServiceErrors() {
        Test.startTest();
        try {
            AccountHierarchyController.createGapAccount(null);
            System.assert(false, 'Expected exception for null input');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        AccountHierarchyService.GapInput blank = new AccountHierarchyService.GapInput();
        try {
            AccountHierarchyController.createGapAccount(blank);
            System.assert(false, 'Expected exception for blank name');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void controller_applyChanges_wrapsServiceErrors() {
        AccountHierarchyService.HierarchyChange bad = new AccountHierarchyService.HierarchyChange();
        bad.accountId = 'not-a-real-id';
        bad.newParentId = '001000000000000AAA';

        Test.startTest();
        try {
            AccountHierarchyController.applyChanges(new List<AccountHierarchyService.HierarchyChange>{ bad });
            System.assert(false, 'Expected exception for malformed accountId');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }
}
