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
    static void scan_clustersOaklinsWhenWebsiteIsMissing() {
        // Reproduces the reported case: Oaklins country offices with no Website
        // set, just names. Should still cluster via the name-based fallback.
        insert new List<Account>{
            new Account(Name = 'Oaklins International'),
            new Account(Name = 'Oaklins UK'),
            new Account(Name = 'Oaklins Germany'),
            new Account(Name = 'Oaklins France'),
            new Account(Name = 'Oaklins Australia')
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result = AccountHierarchyController.scanFamilies();
        Test.stopTest();

        Boolean found = false;
        for (AccountHierarchyService.AccountFamily f : result.families) {
            if (f.brandLabel == 'oaklins') {
                found = true;
                System.assertEquals(5, f.accountCount);
            }
        }
        System.assert(found, 'Oaklins family should be detected from names alone');
    }

    @isTest
    static void scan_handlesArbitraryCountryCodeTlds() {
        // Reproduces the bogus "Com" family from the screenshot: hardcoded
        // multi-part TLDs missed com.lb / com.eg / com.tr, putting brand="com".
        insert new List<Account>{
            new Account(Name = 'Arab Bank LB', Website = 'https://arabbank.com.lb'),
            new Account(Name = 'Arab Bank EG', Website = 'https://arabbank.com.eg'),
            new Account(Name = 'Arab Bank TR', Website = 'https://arabbank.com.tr')
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result = AccountHierarchyController.scanFamilies();
        Test.stopTest();

        for (AccountHierarchyService.AccountFamily f : result.families) {
            System.assertNotEquals('com', f.brandLabel, 'Should never cluster under bare TLD');
        }
        Boolean found = false;
        for (AccountHierarchyService.AccountFamily f : result.families) {
            if (f.brandLabel == 'arabbank') { found = true; break; }
        }
        System.assert(found, 'Should cluster as arabbank');
    }

    @isTest
    static void scan_skipsSocialDomainBrands() {
        // Accounts whose Website happens to be a LinkedIn URL should never be
        // clustered under "linkedin" as a brand.
        insert new List<Account>{
            new Account(Name = 'Northwind Holdings', Website = 'https://linkedin.com/company/northwind-holdings'),
            new Account(Name = 'Globex Corp', Website = 'https://linkedin.com/company/globex')
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result = AccountHierarchyController.scanFamilies();
        Test.stopTest();

        for (AccountHierarchyService.AccountFamily f : result.families) {
            System.assertNotEquals('linkedin', f.brandLabel);
            System.assertNotEquals('facebook', f.brandLabel);
        }
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
            AccountHierarchyController.proposeHierarchy(JSON.serialize(fam));
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
            AccountHierarchyController.proposeHierarchy(JSON.serialize(fam));
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
        AccountHierarchyService.ApplyResult result = AccountHierarchyController.applyChanges(JSON.serialize(changes));
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
        String id = AccountHierarchyController.createGapAccount(JSON.serialize(input));
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

    // ---------- Dedupe-source scan ----------

    @isTest
    static void scanFromDedupeGroups_buildsFamiliesFromGroupMembers() {
        Dedupe_Scan__c scan = new Dedupe_Scan__c(Status__c = 'Completed');
        insert scan;

        Dedupe_Group__c grp = new Dedupe_Group__c(
            Scan__c = scan.Id,
            Scenario_Key__c = 'EXACT_WEBSITE+SAME_LINKEDIN',
            Status__c = 'Open'
        );
        insert grp;

        List<Account> accs = new List<Account>{
            new Account(Name = 'Oaklins International', Website = 'oaklins.com'),
            new Account(Name = 'Oaklins UK',            Website = 'oaklins.co.uk'),
            new Account(Name = 'Oaklins Germany',       Website = 'oaklins.de')
        };
        insert accs;

        List<Dedupe_Group_Member__c> members = new List<Dedupe_Group_Member__c>();
        for (Account a : accs) members.add(new Dedupe_Group_Member__c(Group__c = grp.Id, Account__c = a.Id));
        insert members;

        Test.startTest();
        AccountHierarchyService.ScanResult result =
            AccountHierarchyController.scanFromDedupeGroups(scan.Id);
        Test.stopTest();

        System.assertEquals(1, result.families.size());
        AccountHierarchyService.AccountFamily fam = result.families[0];
        System.assertEquals(3, fam.accountCount);
        System.assertEquals(grp.Id, fam.dedupeGroupId);
        System.assertEquals('EXACT_WEBSITE+SAME_LINKEDIN', fam.matchSignals);
        System.assertEquals('oaklins', fam.brandLabel);
    }

    @isTest
    static void scanFromDedupeGroups_picksLatestCompletedWhenScanIdIsNull() {
        Dedupe_Scan__c older = new Dedupe_Scan__c(Status__c = 'Completed');
        Dedupe_Scan__c newer = new Dedupe_Scan__c(Status__c = 'Completed');
        insert new List<Dedupe_Scan__c>{ older, newer };
        // Inserts in the same transaction share a CreatedDate, so explicitly
        // backdate one to make 'latest' deterministic.
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-1));

        Dedupe_Group__c grp = new Dedupe_Group__c(
            Scan__c = newer.Id, Scenario_Key__c = 'EXACT_WEBSITE', Status__c = 'Open'
        );
        insert grp;

        Account a = new Account(Name = 'Acme A', Website = 'acme.com');
        Account b = new Account(Name = 'Acme B', Website = 'acme.com');
        insert new List<Account>{ a, b };
        insert new List<Dedupe_Group_Member__c>{
            new Dedupe_Group_Member__c(Group__c = grp.Id, Account__c = a.Id),
            new Dedupe_Group_Member__c(Group__c = grp.Id, Account__c = b.Id)
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result =
            AccountHierarchyController.scanFromDedupeGroups(null);
        Test.stopTest();

        System.assertEquals(1, result.families.size());
        System.assertEquals(2, result.families[0].accountCount);
    }

    @isTest
    static void scanFromDedupeGroups_returnsEmptyWhenNoScans() {
        Test.startTest();
        AccountHierarchyService.ScanResult result =
            AccountHierarchyController.scanFromDedupeGroups(null);
        Test.stopTest();

        System.assertEquals(0, result.families.size());
        System.assertEquals(0, result.totalAccountsScanned);
    }

    @isTest
    static void scanFromDedupeGroups_ignoresResolvedGroups() {
        Dedupe_Scan__c scan = new Dedupe_Scan__c(Status__c = 'Completed');
        insert scan;
        Dedupe_Group__c open = new Dedupe_Group__c(
            Scan__c = scan.Id, Scenario_Key__c = 'EXACT_WEBSITE', Status__c = 'Open'
        );
        Dedupe_Group__c resolved = new Dedupe_Group__c(
            Scan__c = scan.Id, Scenario_Key__c = 'EXACT_WEBSITE', Status__c = 'Resolved'
        );
        insert new List<Dedupe_Group__c>{ open, resolved };

        Account a1 = new Account(Name = 'Open A', Website = 'open.com');
        Account a2 = new Account(Name = 'Open B', Website = 'open.com');
        Account r1 = new Account(Name = 'Resolved A', Website = 'resolved.com');
        Account r2 = new Account(Name = 'Resolved B', Website = 'resolved.com');
        insert new List<Account>{ a1, a2, r1, r2 };
        insert new List<Dedupe_Group_Member__c>{
            new Dedupe_Group_Member__c(Group__c = open.Id, Account__c = a1.Id),
            new Dedupe_Group_Member__c(Group__c = open.Id, Account__c = a2.Id),
            new Dedupe_Group_Member__c(Group__c = resolved.Id, Account__c = r1.Id),
            new Dedupe_Group_Member__c(Group__c = resolved.Id, Account__c = r2.Id)
        };

        Test.startTest();
        AccountHierarchyService.ScanResult result =
            AccountHierarchyController.scanFromDedupeGroups(scan.Id);
        Test.stopTest();

        System.assertEquals(1, result.families.size(), 'Only the Open group should surface');
    }

    @isTest
    static void listDedupeScans_returnsScansWithGroupCount() {
        Dedupe_Scan__c scan = new Dedupe_Scan__c(Status__c = 'Completed');
        insert scan;
        insert new Dedupe_Group__c(
            Scan__c = scan.Id, Scenario_Key__c = 'EXACT_WEBSITE', Status__c = 'Open'
        );

        Test.startTest();
        List<AccountHierarchyService.DedupeScanOption> opts =
            AccountHierarchyController.listDedupeScans();
        Test.stopTest();

        System.assert(opts.size() >= 1);
        Boolean found = false;
        for (AccountHierarchyService.DedupeScanOption o : opts) {
            if (o.id == scan.Id) {
                System.assertEquals('Completed', o.status);
                System.assertEquals(1, o.openGroupCount);
                found = true;
            }
        }
        System.assert(found, 'Inserted scan should appear in list');
    }

    // ---------- Controller catch-block coverage ----------

    @isTest
    static void controller_proposeHierarchy_wrapsServiceErrors() {
        Test.startTest();
        try {
            AccountHierarchyController.proposeHierarchy(null);
            System.assert(false, 'Expected exception for null json');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        try {
            // Valid JSON but no accounts -> service throws "family is required".
            AccountHierarchyController.proposeHierarchy('{"brandLabel":"foo"}');
            System.assert(false, 'Expected exception for empty family');
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
            System.assert(false, 'Expected exception for null json');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        try {
            AccountHierarchyController.createGapAccount('{}');
            System.assert(false, 'Expected exception for blank name');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void controller_applyChanges_wrapsServiceErrors() {
        Test.startTest();
        try {
            AccountHierarchyController.applyChanges(null);
            System.assert(false, 'Expected exception for null json');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }

        try {
            // Malformed Id triggers System.StringException inside Account(Id=...).
            AccountHierarchyController.applyChanges(
                '[{"accountId":"not-a-real-id","newParentId":"001000000000000AAA"}]'
            );
            System.assert(false, 'Expected exception for malformed accountId');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }
}
