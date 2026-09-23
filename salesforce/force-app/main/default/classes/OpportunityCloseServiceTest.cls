@IsTest
public class OpportunityCloseServiceTest {

    /** Shared test data for the close-opportunity classes. */
    public static Account makeAccount() {
        Account a = new Account(Name = 'Close Test Co');
        insert a;
        return a;
    }

    /** An open opportunity with every Closed Won field populated. */
    public static Opportunity makeReadyOpportunity(Id accountId) {
        Opportunity o = new Opportunity(
            Name = 'Ready Deal',
            AccountId = accountId,
            StageName = '5 - Contracting',
            CloseDate = Date.today().addDays(10),
            Amount = 120000,
            LeadSource = 'Event',
            Type = 'New Business',
            LOB_Division__c = 'Investment Banking',
            Pricing_Structure__c = 'Seats: Credit-Based Usage',
            Deal_Description__c = 'Ten seats for the M&A team',
            Purchase_Driver__c = 'Faster diligence',
            Rollout_Timeline__c = 'Immediate',
            Success_Criteria__c = 'Weekly active use by 8 of 10 seats',
            Upsell_Potential__c = 'Yes',
            Implementation_Notes__c = 'Kickoff next week',
            Key_Risks__c = 'Champion leaving in Q1',
            Contract_Start_Date__c = Date.today(),
            Contract_End_Date__c = Date.today().addYears(1),
            Contract_Length_Mos__c = 12,
            Annual_Recurring_Revenue__c = 120000,
            Total_Contract_Value__c = 120000,
            License_Fees__c = 110000,
            Platform_Connection_Fee__c = 5000,
            Professional_Service_Fees__c = 5000,
            Seat_Licenses__c = 10,
            Payment_Terms__c = 'Annual',
            Credit_Terms__c = 'Net-30',
            Billing_Notes__c = 'Invoice on signature',
            Billing_Contact__c = 'billing@example.com',
            Renewal_Terms__c = 'Auto-renew (90-day)',
            ELA__c = false,
            Opt_Out__c = false
        );
        insert o;
        return o;
    }

    /** An open opportunity missing most Closed Won fields. */
    public static Opportunity makeBareOpportunity(Id accountId) {
        Opportunity o = new Opportunity(
            Name = 'Bare Deal',
            AccountId = accountId,
            StageName = '3 - POV',
            CloseDate = Date.today().addDays(30),
            Amount = 50000,
            LeadSource = 'Event',
            Type = 'New Business'
        );
        insert o;
        return o;
    }

    /** Attaches a file whose title marks it as the signed order form. */
    public static void attachSignedDocument(Id opportunityId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('signed'),
            IsMajorVersion = true
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = opportunityId, ContentDocumentId = docId, ShareType = 'V');
    }

    @IsTest
    static void detectsBothSignedPrefixes() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        System.assertEquals(0, OpportunityCloseService.signedDocumentTitles(o.Id).size());
        attachSignedDocument(o.Id, '__signed Order Form');
        attachSignedDocument(o.Id, 'signed__Order Form v2');
        attachSignedDocument(o.Id, 'Unsigned draft');
        System.assertEquals(2, OpportunityCloseService.signedDocumentTitles(o.Id).size());
    }

    @IsTest
    static void matchesPicklistsCaseInsensitively() {
        System.assertEquals('Net-30', OpportunityCloseService.matchPicklist('Credit_Terms__c', 'net-30'));
        System.assertEquals(null, OpportunityCloseService.matchPicklist('Credit_Terms__c', 'Net-90'));
        System.assertEquals(null, OpportunityCloseService.matchPicklist('Credit_Terms__c', ''));
        System.assertEquals(null, OpportunityCloseService.matchPicklist('Not_A_Field__c', 'x'));
        System.assert(OpportunityCloseService.picklistOptions('Payment_Terms__c').contains('Annual'));
    }

    @IsTest
    static void validatesEmailsAndFormats() {
        System.assert(OpportunityCloseService.isValidEmail('billing@example.com'));
        System.assert(!OpportunityCloseService.isValidEmail('billing@example'));
        System.assert(!OpportunityCloseService.isValidEmail(''));
        System.assert(OpportunityCloseService.formatCurrency(1234567).endsWith('1,234,567'));
        System.assert(OpportunityCloseService.formatCurrency(-50).startsWith('-'));
        System.assertEquals('Not set', OpportunityCloseService.formatCurrency(null));
        System.assertEquals('Not set', OpportunityCloseService.formatNumber(null));
        System.assertEquals('Not set', OpportunityCloseService.formatDate(null));
        System.assertEquals('Yes', OpportunityCloseService.formatBoolean(true));
        System.assertEquals('No', OpportunityCloseService.formatBoolean(null));
        System.assertEquals('Not set', OpportunityCloseService.textOrNotSet(' '));
        System.assertEquals(27, OpportunityCloseService.wonFieldSpecs().size());
    }

    @IsTest
    static void parsesOpportunityIdsOnly() {
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        System.assertEquals(o.Id, OpportunityCloseService.parseOpportunityId(' ' + o.Id + ' '));
        System.assertEquals(null, OpportunityCloseService.parseOpportunityId(a.Id));
        System.assertEquals(null, OpportunityCloseService.parseOpportunityId('garbage'));
        System.assertEquals(null, OpportunityCloseService.parseOpportunityId(null));
    }

    /** Stub invokers so the Slack job's callout path runs without a callout. */
    private class EmptyInvoker extends CloseWonNotificationJob.Invoker {
        public override List<Invocable.Action.Result> invoke(Invocable.Action action) {
            return new List<Invocable.Action.Result>();
        }
    }

    private class ThrowingInvoker extends CloseWonNotificationJob.Invoker {
        public override List<Invocable.Action.Result> invoke(Invocable.Action action) {
            throw new CalloutException('simulated outage');
        }
    }

    /** Stub AI runners so the background analysis job runs without a callout. */
    private class SucceedingAiRunner extends CloseAiAnalysisJob.Runner {
        public override DealScoreAIController.ForensicResult run(Id opportunityId, String mode) {
            DealScoreAIController.ForensicResult r = new DealScoreAIController.ForensicResult();
            r.success = true;
            r.summary = 'Summary for ' + mode;
            r.confidence = 'High';
            r.nextStep = 'Send the recap';
            r.evidenceTier = 'Tier 1';
            return r;
        }
    }

    private class FailingAiRunner extends CloseAiAnalysisJob.Runner {
        public override DealScoreAIController.ForensicResult run(Id opportunityId, String mode) {
            DealScoreAIController.ForensicResult r = new DealScoreAIController.ForensicResult();
            r.success = false;
            r.summary = 'AI analysis failed: Read timed out';
            return r;
        }
    }

    @IsTest
    static void aiJobLossSuccessWritesDetailsAndClearsStatus() {
        CloseAiAnalysisJob.runner = new SucceedingAiRunner();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.assertEquals(true, OpportunityCloseService.startAiAnalysis(OpportunityCloseService.loadOpportunity(o.Id), 'Loss'));
        Opportunity running = [SELECT Agent_AI_Status__c FROM Opportunity WHERE Id = :o.Id];
        System.assert(running.Agent_AI_Status__c.startsWith(CloseAiAnalysisJob.RUNNING_PREFIX), running.Agent_AI_Status__c);
        System.assertEquals(true, OpportunityCloseService.aiState(running).running);
        Test.stopTest();
        Opportunity done = [SELECT Agent_AI_Status__c, CL_Details_AI__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(true, CloseAiAnalysisJob.lastRunSucceeded);
        System.assertEquals(null, done.Agent_AI_Status__c, 'Status cleared on success');
        System.assertEquals('Summary for Loss', done.CL_Details_AI__c);
    }

    @IsTest
    static void aiJobWinSuccessWritesWinFields() {
        CloseAiAnalysisJob.runner = new SucceedingAiRunner();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.enqueueJob(new CloseAiAnalysisJob(o.Id, 'Win'));
        Test.stopTest();
        Opportunity done = [SELECT CW_AI_Details__c, CW_Confidence_AI__c, Next_Step_AI__c, Evidence_Tier_AI__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals('Summary for Win', done.CW_AI_Details__c);
        System.assertEquals('High', done.CW_Confidence_AI__c);
        System.assertEquals('Send the recap', done.Next_Step_AI__c);
        System.assertEquals('Tier 1', done.Evidence_Tier_AI__c);
    }

    @IsTest
    static void aiJobFailureRecordsReasonAndStateParsesIt() {
        CloseAiAnalysisJob.runner = new FailingAiRunner();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.enqueueJob(new CloseAiAnalysisJob(o.Id, 'Loss'));
        Test.stopTest();
        Opportunity failed = [SELECT Agent_AI_Status__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(false, CloseAiAnalysisJob.lastRunSucceeded);
        System.assert(failed.Agent_AI_Status__c.startsWith(CloseAiAnalysisJob.FAILED_PREFIX), failed.Agent_AI_Status__c);
        OpportunityCloseService.AiState s = OpportunityCloseService.aiState(failed);
        System.assertEquals(true, s.failed);
        System.assertEquals(false, s.running);
        System.assertEquals('AI analysis failed: Read timed out', s.reason);

        // A "running" marker older than the stale window counts as failed too.
        Opportunity stale = new Opportunity(Agent_AI_Status__c = CloseAiAnalysisJob.RUNNING_PREFIX + '2020-01-01T00:00:00Z');
        OpportunityCloseService.AiState staleState = OpportunityCloseService.aiState(stale);
        System.assertEquals(true, staleState.failed);
        System.assertEquals(false, staleState.running);
        System.assertEquals(false, OpportunityCloseService.aiState(new Opportunity()).failed, 'Blank status is idle');
    }

    @IsTest
    static void aiJobSurvivesARunnerException() {
        CloseAiAnalysisJob.runner = new ThrowingAiRunner();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.enqueueJob(new CloseAiAnalysisJob(o.Id, 'Loss'));
        Test.stopTest();
        System.assertEquals(false, CloseAiAnalysisJob.lastRunSucceeded);
        System.assert([SELECT Agent_AI_Status__c FROM Opportunity WHERE Id = :o.Id].Agent_AI_Status__c.contains('simulated outage'));
    }

    private class ThrowingAiRunner extends CloseAiAnalysisJob.Runner {
        public override DealScoreAIController.ForensicResult run(Id opportunityId, String mode) {
            throw new CalloutException('simulated outage');
        }
    }

    @IsTest
    static void slackJobReportsFailureWhenServiceReturnsNothing() {
        OpportunityCloseService.disableExternalCalls = false;
        CloseWonNotificationJob.invoker = new EmptyInvoker();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.enqueueJob(new CloseWonNotificationJob(o.Id));
        Test.stopTest();
        System.assertEquals(false, CloseWonNotificationJob.lastRunSucceeded);
    }

    @IsTest
    static void slackJobSurvivesAnException() {
        OpportunityCloseService.disableExternalCalls = false;
        CloseWonNotificationJob.invoker = new ThrowingInvoker();
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        Test.startTest();
        System.enqueueJob(new CloseWonNotificationJob(o.Id));
        Test.stopTest();
        System.assertEquals(false, CloseWonNotificationJob.lastRunSucceeded, 'Exception is caught, not rethrown');
    }

    @IsTest
    static void externalCallsAreSkippedWhenDisabled() {
        OpportunityCloseService.disableExternalCalls = true;
        Account a = makeAccount();
        Opportunity o = makeBareOpportunity(a.Id);
        System.assertEquals(null, OpportunityCloseService.runAiAnalysis(o.Id, 'Win', false));
        OpportunityCloseService.notifyRevOpsAfterCommit(o.Id);
        OpportunityCloseService.queueOrderFormExtraction(o.Id);

        Test.startTest();
        System.enqueueJob(new CloseWonNotificationJob(o.Id));
        Test.stopTest();
        System.assertEquals(true, CloseWonNotificationJob.lastRunSucceeded, 'Job should short-circuit in tests');
    }
}
