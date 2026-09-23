@IsTest
private class SubmitClosedWonTest {

    private static SubmitClosedWon.Response run(SubmitClosedWon.Request req) {
        return SubmitClosedWon.submitClosedWon(new List<SubmitClosedWon.Request>{ req })[0];
    }

    private static SubmitClosedWon.Request request(Id oppId, Boolean confirm) {
        SubmitClosedWon.Request req = new SubmitClosedWon.Request();
        req.opportunityId = oppId;
        req.confirm = confirm;
        return req;
    }

    @IsTest
    static void previewThenSubmitWritesFieldsWithoutStampingStage() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeReadyOpportunity(a.Id);
        OpportunityCloseServiceTest.attachSignedDocument(o.Id, '__signed Order Form');

        SubmitClosedWon.Request preview = request(o.Id, false);
        preview.billingNotes = 'Updated by agent';
        preview.willingToProvideReferences = true;
        SubmitClosedWon.Response p = run(preview);
        System.assertEquals('ReadyToSubmit', p.status);
        System.assertEquals(true, p.isPreview);
        System.assertEquals(false, p.hasProblems);
        System.assertEquals(28, p.rows.size(), '27 fields plus references');
        System.assert(p.confirmPrompt.contains(o.Id));
        System.assertEquals(false, p.hasLobChoices, 'LOB already on the record');
        System.assertEquals(false, p.needsSignedDocument);
        System.assert(p.filesUrl.contains(o.Id));
        Opportunity untouched = [SELECT Billing_Notes__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Invoice on signature', untouched.Billing_Notes__c, 'Preview must not save');

        SubmitClosedWon.Request confirm = request(o.Id, true);
        confirm.billingNotes = 'Updated by agent';
        confirm.willingToProvideReferences = true;
        confirm.seatLicenses = 12;
        Test.startTest();
        SubmitClosedWon.Response c = run(confirm);
        Test.stopTest();

        System.assertEquals('Submitted', c.status);
        System.assertEquals(true, c.isSubmitted);
        System.assertEquals(true, c.aiRunning, 'Win summary is generated in the background');
        Opportunity saved = [
            SELECT StageName, Billing_Notes__c, Seat_Licenses__c, CW_Screen_Flow_Used__c, CW_Submission_Source__c,
                   Purchase_Driver__c, Account.Provide_References__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        System.assertEquals('5 - Contracting', saved.StageName, 'RevOps stamps Closed Won, not the agent');
        System.assertEquals('Updated by agent', saved.Billing_Notes__c);
        System.assertEquals(12, saved.Seat_Licenses__c);
        System.assertEquals('Faster diligence', saved.Purchase_Driver__c, 'Blank inputs keep existing values');
        System.assertEquals(true, saved.CW_Screen_Flow_Used__c);
        System.assertEquals('Agent', saved.CW_Submission_Source__c);
        System.assertEquals(true, saved.Account.Provide_References__c);
    }

    @IsTest
    static void blockedWithoutSignedDocumentAndReportsProblems() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        SubmitClosedWon.Request req = request(o.Id, true);
        req.paymentTerms = 'Whenever';
        req.billingContactEmail = 'not-an-email';
        req.billingNotes = 'x'.repeat(300);
        req.contractStartDate = Date.today();
        req.contractEndDate = Date.today().addDays(-1);
        req.optOut = true;
        SubmitClosedWon.Response res = run(req);

        System.assertEquals('Blocked', res.status);
        System.assertEquals(true, res.isBlocked);
        System.assertEquals(true, res.hasProblems);
        System.assertEquals('Signed order form', res.problems[0].label, 'Signed doc problem listed first');
        System.assertEquals(true, res.needsSignedDocument);
        System.assert(res.uploadUrl.contains(o.Id), 'Upload link carries the opportunity');
        System.assertEquals(true, res.hasLobChoices, 'Bare deal has no LOB, so LOB buttons are offered');
        System.assert(res.lobChoices[0].prompt.contains('Closed Won'));
        Set<String> labels = new Set<String>();
        for (OpportunityCloseService.Row r : res.problems) {
            labels.add(r.label);
        }
        System.assert(labels.contains('Payment Terms'), 'Invalid picklist value flagged');
        System.assert(labels.contains('Billing Contact'), 'Bad email flagged');
        System.assert(labels.contains('Billing Notes'), 'Long notes flagged');
        System.assert(labels.contains('Contract End Date'), 'End before start flagged');
        System.assert(labels.contains('Opt-Out Date'), 'Opt-out date required when opt out is true');
        System.assert(labels.contains('Purchase Driver'), 'Missing required field flagged');
        Opportunity untouched = [SELECT Payment_Terms__c, StageName FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(null, untouched.Payment_Terms__c, 'Blocked call must not save');
    }

    @IsTest
    static void restructureClosesDirectly() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        // Validation rules still require the handoff fields at Closed Won, so start from a complete deal.
        Opportunity o = OpportunityCloseServiceTest.makeReadyOpportunity(a.Id);
        o.Type = 'Contract Restructure';
        update o;

        SubmitClosedWon.Response preview = run(request(o.Id, false));
        System.assertEquals('ReadyToSubmit', preview.status);

        Test.startTest();
        SubmitClosedWon.Response res = run(request(o.Id, true));
        Test.stopTest();
        System.assertEquals('Submitted', res.status);
        Opportunity saved = [SELECT StageName, CW_Submission_Source__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Closed Won', saved.StageName);
        System.assertEquals('Agent', saved.CW_Submission_Source__c);
    }

    @IsTest
    static void alreadyClosedAndNotFound() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        o.StageName = 'Closed Lost';
        o.CL_Primary_Reason__c = 'No Need';
        o.CL_Notes__c = 'Test';
        update o;
        System.assertEquals('AlreadyClosed', run(request(o.Id, true)).status);

        SubmitClosedWon.Request bad = new SubmitClosedWon.Request();
        bad.opportunityId = 'nope';
        System.assertEquals('NotFound', run(bad).status);
    }
}
