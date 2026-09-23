@IsTest
private class SubmitClosedLostTest {

    private static SubmitClosedLost.Response run(SubmitClosedLost.Request req) {
        return SubmitClosedLost.submitClosedLost(new List<SubmitClosedLost.Request>{ req })[0];
    }

    private static SubmitClosedLost.Request request(Id oppId, Boolean confirm) {
        SubmitClosedLost.Request req = new SubmitClosedLost.Request();
        req.opportunityId = oppId;
        req.confirm = confirm;
        return req;
    }

    @IsTest
    static void previewThenConfirmStampsClosedLost() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        SubmitClosedLost.Request preview = request(o.Id, false);
        preview.primaryReason = 'competitive loss';
        preview.finalCompetitor = 'Hebbia';
        preview.notes = 'Went with the incumbent';
        preview.lobDivision = 'Private Equity';
        SubmitClosedLost.Response p = run(preview);
        System.assertEquals('ReadyToSubmit', p.status);
        System.assertEquals(true, p.isPreview);
        System.assertEquals(false, p.hasRecommendation, 'No AI in tests');
        System.assertEquals(7, p.rows.size());
        System.assertEquals(true, p.hasReasonChoices);
        System.assertEquals(4, p.reasonChoices.size(), 'Three common reasons plus Other when there is no recommendation');
        System.assertEquals('Competitive Loss', p.reasonChoices[0].label);
        System.assert(p.reasonChoices[0].prompt.contains(o.Id));
        System.assert(p.reasonChoices[0].prompt.contains('"Competitive Loss"'));
        System.assertEquals('Other reason', p.reasonChoices[3].label);
        System.assertEquals('3 - POV', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName, 'Preview must not save');

        SubmitClosedLost.Request confirm = request(o.Id, true);
        confirm.primaryReason = 'Competitive Loss';
        confirm.finalCompetitor = 'Hebbia';
        confirm.notes = 'Went with the incumbent';
        confirm.lobDivision = 'Private Equity';
        SubmitClosedLost.Response c = run(confirm);

        System.assertEquals('Submitted', c.status);
        System.assertEquals(false, c.hasReasonChoices, 'No reason buttons once submitted');
        Opportunity saved = [
            SELECT StageName, CL_Primary_Reason__c, Final_Competitor__c, CL_Notes__c, LOB_Division__c, Close_Lost_from_Stage__c
            FROM Opportunity WHERE Id = :o.Id
        ];
        System.assertEquals('Closed Lost', saved.StageName);
        System.assertEquals('Competitive Loss', saved.CL_Primary_Reason__c, 'Case-insensitive picklist match canonicalised');
        System.assertEquals('Hebbia', saved.Final_Competitor__c);
        System.assertEquals('Went with the incumbent', saved.CL_Notes__c);
        System.assertEquals('Private Equity', saved.LOB_Division__c);
        System.assertEquals('3 - POV', saved.Close_Lost_from_Stage__c);
    }

    @IsTest
    static void blockedWhenReasonNotesOrLobMissingOrInvalid() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        SubmitClosedLost.Request req = request(o.Id, true);
        req.secondaryReason = 'Not a real reason';
        SubmitClosedLost.Response res = run(req);

        System.assertEquals('Blocked', res.status);
        Set<String> labels = new Set<String>();
        for (OpportunityCloseService.Row r : res.problems) {
            labels.add(r.label);
        }
        System.assert(labels.contains('CL Primary Reason'));
        System.assert(labels.contains('CL Secondary Reason'));
        System.assert(labels.contains('CL Notes'));
        System.assert(labels.contains('LOB/Division'));
        System.assertEquals('3 - POV', [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName);
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

        SubmitClosedLost.Request bad = new SubmitClosedLost.Request();
        bad.opportunityId = 'nope';
        System.assertEquals('NotFound', run(bad).status);
    }

    @IsTest
    static void recommendedReasonLeadsTheChoices() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        List<OpportunityCloseService.Choice> choices = OpportunityCloseService.lostReasonChoices(o, 'budget financial');

        System.assertEquals(5, choices.size(), 'Recommended + three alternatives + Other');
        System.assertEquals('Use recommended: Budget Financial', choices[0].label);
        System.assertEquals('primary', choices[0].variant);
        System.assert(choices[0].prompt.contains('"Budget Financial"'));
        Set<String> labels = new Set<String>();
        for (OpportunityCloseService.Choice c : choices) {
            System.assert(labels.add(c.label), 'Duplicate choice ' + c.label);
            System.assertNotEquals(null, c.prompt);
        }
        System.assert(!labels.contains('Budget Financial'), 'Recommended reason is not repeated as an alternative');
        System.assertEquals('Other reason', choices[4].label);

        List<OpportunityCloseService.Choice> noRec = OpportunityCloseService.lostReasonChoices(o, OpportunityCloseService.NOT_SET);
        System.assertEquals(4, noRec.size());
        System.assertEquals('secondary', noRec[0].variant);
    }
}
