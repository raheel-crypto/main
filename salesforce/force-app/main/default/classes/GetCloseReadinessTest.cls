@IsTest
private class GetCloseReadinessTest {

    private static GetCloseReadiness.Response run(String oppId) {
        GetCloseReadiness.Request req = new GetCloseReadiness.Request();
        req.opportunityId = oppId;
        return GetCloseReadiness.getCloseReadiness(new List<GetCloseReadiness.Request>{ req })[0];
    }

    @IsTest
    static void readyWhenAllFieldsAndSignedDocPresent() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeReadyOpportunity(a.Id);
        OpportunityCloseServiceTest.attachSignedDocument(o.Id, '__signed Order Form');

        GetCloseReadiness.Response res = run(o.Id);

        System.assertEquals('Ready', res.statusLabel);
        System.assertEquals('success', res.statusVariant);
        System.assertEquals(true, res.hasSignedDocument);
        System.assertEquals(false, res.missingSignedDocument);
        System.assertEquals(false, res.hasMissingFields);
        System.assertEquals(0, res.missingFieldCount);
        System.assertEquals(true, res.canClose);
        System.assertEquals(27, res.checklist.size());
        System.assert(res.closeWonPrompt.contains(o.Id));
        System.assert(res.opportunityUrl.endsWith(o.Id));
        System.assertEquals('Close Test Co', res.accountName);
    }

    @IsTest
    static void blockedWithoutSignedDocAndListsMissingFields() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        GetCloseReadiness.Response res = run(o.Id);

        System.assertEquals('Blocked', res.statusLabel, 'Missing signed doc outranks missing fields');
        System.assertEquals(true, res.missingSignedDocument);
        System.assertEquals(true, res.hasMissingFields);
        System.assert(res.missingFieldCount > 20, 'Most fields should be missing, got ' + res.missingFieldCount);
        System.assert(res.missingFieldsText.contains('Purchase Driver'));
        Boolean sawNeeded = false;
        for (OpportunityCloseService.Row row : res.checklist) {
            if (row.value == 'Needed') {
                sawNeeded = true;
                System.assertEquals('alert-circle', row.icon);
            }
        }
        System.assert(sawNeeded);
    }

    @IsTest
    static void fieldsNeededWhenSignedDocPresent() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        OpportunityCloseServiceTest.attachSignedDocument(o.Id, 'signed__Order Form');

        GetCloseReadiness.Response res = run(o.Id);

        System.assertEquals('Fields needed', res.statusLabel);
        System.assertEquals('warning', res.statusVariant);
    }

    @IsTest
    static void restructureAndClosedAndNotFound() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity restructure = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        restructure.Type = 'Contract Restructure';
        update restructure;
        System.assertEquals('Restructure', run(restructure.Id).statusLabel);

        Opportunity lost = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        lost.StageName = 'Closed Lost';
        lost.CL_Primary_Reason__c = 'No Need';
        lost.CL_Notes__c = 'Test';
        update lost;
        GetCloseReadiness.Response closed = run(lost.Id);
        System.assertEquals(true, closed.isClosed);
        System.assertEquals(false, closed.canClose);
        System.assert(closed.statusLabel.startsWith('Already Closed'));

        GetCloseReadiness.Response missing = run('not-an-id');
        System.assertEquals('Not found', missing.statusLabel);
        System.assertEquals(false, missing.canClose);
    }
}
