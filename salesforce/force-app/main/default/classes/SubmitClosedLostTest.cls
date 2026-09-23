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
        System.assertEquals('Bad Fit Disqualified', p.reasonChoices[0].label);
        System.assert(p.reasonChoices[0].prompt.contains(o.Id));
        System.assert(p.reasonChoices[0].prompt.contains('"Bad Fit Disqualified"'));
        System.assertEquals('Other reason', p.reasonChoices[3].label);
        System.assertEquals(false, p.hasLobChoices, 'LOB was given explicitly, so no LOB buttons');
        System.assert(p.filesUrl.contains(o.Id) && p.filesUrl.contains('AttachedContentDocuments'));
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
        System.assertEquals(true, res.hasReasonChoices, 'A blocked confirm still offers reason buttons');
        System.assertEquals('Bad Fit Disqualified', res.reasonChoices[0].label);
        System.assertEquals(true, res.hasLobChoices, 'No LOB anywhere, so LOB buttons are offered');
        System.assertEquals('Private Equity', res.lobChoices[0].label, 'No account type, so the most common LOB leads');
        System.assertEquals('More LOB options', res.lobChoices[res.lobChoices.size() - 1].label);
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
    static void previewStartsBackgroundAiOnceAndReportsProgress() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        SubmitClosedLost.Response first = run(request(o.Id, false));
        System.assertEquals(true, first.aiRunning, 'First preview starts the analysis');
        System.assert(first.aiStatusText.contains('started'));
        System.assert(first.refreshPrompt.contains(o.Id));
        System.assertEquals(1, Limits.getQueueableJobs(), 'One job queued');
        System.assert([SELECT Agent_AI_Status__c FROM Opportunity WHERE Id = :o.Id].Agent_AI_Status__c.startsWith(CloseAiAnalysisJob.RUNNING_PREFIX));

        SubmitClosedLost.Response second = run(request(o.Id, false));
        System.assertEquals(true, second.aiRunning, 'Still running');
        System.assert(second.aiStatusText.contains('still running'));
        System.assertEquals(1, Limits.getQueueableJobs(), 'A running analysis is not queued twice');

        // Confirm never waits for the AI and never starts it.
        SubmitClosedLost.Request confirm = request(o.Id, true);
        confirm.primaryReason = 'No Need';
        confirm.notes = 'Went quiet';
        confirm.lobDivision = 'Private Equity';
        SubmitClosedLost.Response c = run(confirm);
        System.assertEquals('Submitted', c.status);
        System.assertEquals(false, c.aiRunning);
        System.assertEquals(1, Limits.getQueueableJobs());
    }

    @IsTest
    static void failedAiShowsReasonAndRetryStartsAgain() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        o.Agent_AI_Status__c = CloseAiAnalysisJob.FAILED_PREFIX + '2026-09-23T10:00:00Z: AI analysis failed: Read timed out';
        update o;

        SubmitClosedLost.Response failed = run(request(o.Id, false));
        System.assertEquals(true, failed.aiFailed);
        System.assertEquals(false, failed.aiRunning);
        System.assert(failed.aiFailureReason.contains('Read timed out'), failed.aiFailureReason);
        Boolean sawRetry = false;
        for (OpportunityCloseService.Choice ch : failed.reasonChoices) {
            if (ch.label == 'Retry AI analysis') {
                sawRetry = ch.prompt.contains('retryAi=true');
            }
        }
        System.assert(sawRetry, 'Retry button offered with a retryAi prompt');
        System.assertEquals(0, Limits.getQueueableJobs(), 'A failed analysis is not restarted silently');

        SubmitClosedLost.Request retry = request(o.Id, false);
        retry.retryAi = true;
        SubmitClosedLost.Response retried = run(retry);
        System.assertEquals(true, retried.aiRunning);
        System.assertEquals(false, retried.aiFailed);
        System.assertEquals(1, Limits.getQueueableJobs());
    }

    @IsTest
    static void recommendationComesFromRecordFields() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);
        o.CL_Reason_AI__c = 'Competitive Loss';
        o.CL_Narrative_AI__c = 'Lost to Hebbia on price.';
        o.Final_Competitor__c = 'Hebbia';
        o.CL_Confidence_AI__c = 'High';
        update o;

        SubmitClosedLost.Response p = run(request(o.Id, false));
        System.assertEquals(true, p.hasRecommendation);
        System.assertEquals(false, p.aiRunning, 'Nothing to run when the record already holds a recommendation');
        System.assertEquals('Competitive Loss', p.recommendedReason);
        System.assertEquals('Hebbia', p.recommendedCompetitor);
        System.assertEquals('Use recommended: Competitive Loss', p.reasonChoices[0].label);
        System.assertEquals(0, Limits.getQueueableJobs());
    }

    @IsTest
    static void lobDefaultsFromAccountBusinessType() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = OpportunityCloseServiceTest.makeAccount();
        a.Business_Type__c = 'investment_bank';
        update a;
        Opportunity o = OpportunityCloseServiceTest.makeBareOpportunity(a.Id);

        SubmitClosedLost.Request preview = request(o.Id, false);
        preview.primaryReason = 'No Need';
        preview.notes = 'Went quiet after the pilot';
        SubmitClosedLost.Response p = run(preview);

        System.assertEquals('ReadyToSubmit', p.status, 'Suggested LOB satisfies the requirement: ' + JSON.serialize(p.problems));
        System.assertEquals(true, p.hasLobChoices);
        System.assertEquals('Use suggested: Investment Banking', p.lobChoices[0].label);
        System.assertEquals('primary', p.lobChoices[0].variant);
        System.assert(p.lobChoices[0].prompt.contains('"Investment Banking"') && p.lobChoices[0].prompt.contains('Closed Lost'));
        Boolean sawSuggestedRow = false;
        for (OpportunityCloseService.Row r : p.rows) {
            if (r.label == 'LOB/Division') {
                sawSuggestedRow = r.value == 'Investment Banking' + OpportunityCloseService.SUGGESTED_SUFFIX;
            }
        }
        System.assert(sawSuggestedRow, 'Row shows the suggested LOB with its suffix');

        SubmitClosedLost.Request confirm = request(o.Id, true);
        confirm.primaryReason = 'No Need';
        confirm.notes = 'Went quiet after the pilot';
        SubmitClosedLost.Response c = run(confirm);
        System.assertEquals('Submitted', c.status);
        System.assertEquals(false, c.hasLobChoices);
        System.assertEquals('Investment Banking', [SELECT LOB_Division__c FROM Opportunity WHERE Id = :o.Id].LOB_Division__c);

        System.assertEquals(null, OpportunityCloseService.suggestLob(null));
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
