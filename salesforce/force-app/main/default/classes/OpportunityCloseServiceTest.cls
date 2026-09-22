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
