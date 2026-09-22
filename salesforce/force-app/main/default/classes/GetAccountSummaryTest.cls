@IsTest
private class GetAccountSummaryTest {

    @TestSetup
    static void makeData() {
        Account acct = new Account(
            Name = 'Acme Holdings',
            Industry = 'Financial Services',
            Type = 'Customer',
            Website = 'acme.example.com',
            BillingCity = 'New York',
            BillingState = 'NY',
            AnnualRevenue = 45600000,
            NumberOfEmployees = 1200
        );
        insert acct;

        insert new List<Contact>{
            new Contact(LastName = 'One', AccountId = acct.Id),
            new Contact(LastName = 'Two', AccountId = acct.Id)
        };

        insert new List<Opportunity>{
            new Opportunity(Name = 'Big Deal', AccountId = acct.Id, StageName = 'Prospecting', Amount = 250000, CloseDate = Date.today().addDays(30)),
            new Opportunity(Name = 'Small Deal', AccountId = acct.Id, StageName = 'Qualification', Amount = 15000, CloseDate = Date.today().addDays(60)),
            new Opportunity(Name = 'Won Deal', AccountId = acct.Id, StageName = 'Closed Won', Amount = 99000, CloseDate = Date.today().addDays(-10))
        };

        insert new Account(Name = 'Empty Co');
    }

    @IsTest
    static void summarizesAccountWithPipeline() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Acme Holdings' LIMIT 1];
        GetAccountSummary.GetAccountSummaryRequest req = new GetAccountSummary.GetAccountSummaryRequest();
        req.accountId = acct.Id;

        Test.startTest();
        List<GetAccountSummary.GetAccountSummaryResponse> results =
            GetAccountSummary.getAccountSummary(new List<GetAccountSummary.GetAccountSummaryRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size());
        GetAccountSummary.GetAccountSummaryResponse res = results[0];
        System.assertEquals('Acme Holdings', res.accountName);
        System.assertEquals('Financial Services', res.industry);
        System.assertEquals('Customer', res.type);
        System.assertEquals('New York, NY', res.billingLocation);
        System.assertEquals('acme.example.com', res.website);
        System.assertEquals(1200, res.numberOfEmployees);
        System.assertEquals(2, res.contactCount);
        System.assertEquals(2, res.openOpportunityCount, 'Closed opportunities must be excluded');
        System.assertEquals(true, res.hasOpenOpportunities);
        System.assertEquals(false, res.isPipelineEmpty);
        System.assertEquals(2, res.opportunities.size());
        System.assertEquals('Big Deal', res.opportunities[0].name, 'Largest amount should come first');
        System.assertEquals('Prospecting', res.opportunities[0].stageName);
        System.assert(res.accountUrl.endsWith('/' + acct.Id), 'URL should end with the account Id');
        System.assert(res.annualRevenue.endsWith('45.6M'), 'Expected compact revenue, got ' + res.annualRevenue);
        System.assert(res.openPipelineAmount.endsWith('265K'), 'Expected compact pipeline, got ' + res.openPipelineAmount);
    }

    @IsTest
    static void handlesAccountWithNoPipelineAndBlankFields() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Empty Co' LIMIT 1];
        GetAccountSummary.GetAccountSummaryRequest req = new GetAccountSummary.GetAccountSummaryRequest();
        req.accountId = acct.Id;

        List<GetAccountSummary.GetAccountSummaryResponse> results =
            GetAccountSummary.getAccountSummary(new List<GetAccountSummary.GetAccountSummaryRequest>{ req });

        GetAccountSummary.GetAccountSummaryResponse res = results[0];
        System.assertEquals('Empty Co', res.accountName);
        System.assertEquals('Not set', res.industry);
        System.assertEquals('Account', res.type, 'Blank Type should fall back so the badge has a label');
        System.assertEquals('Not set', res.billingLocation);
        System.assertEquals('Not set', res.annualRevenue);
        System.assertEquals(0, res.numberOfEmployees);
        System.assertEquals(0, res.contactCount);
        System.assertEquals(0, res.openOpportunityCount);
        System.assertEquals(false, res.hasOpenOpportunities);
        System.assertEquals(true, res.isPipelineEmpty);
        System.assertEquals(0, res.opportunities.size());
    }

    @IsTest
    static void returnsNotFoundForBadIds() {
        GetAccountSummary.GetAccountSummaryRequest missing = new GetAccountSummary.GetAccountSummaryRequest();
        missing.accountId = '001000000000000AAA';
        GetAccountSummary.GetAccountSummaryRequest garbage = new GetAccountSummary.GetAccountSummaryRequest();
        garbage.accountId = 'not-an-id';
        GetAccountSummary.GetAccountSummaryRequest blank = new GetAccountSummary.GetAccountSummaryRequest();

        List<GetAccountSummary.GetAccountSummaryResponse> results = GetAccountSummary.getAccountSummary(
            new List<GetAccountSummary.GetAccountSummaryRequest>{ missing, garbage, blank }
        );

        System.assertEquals(3, results.size(), 'One response per request, even for bad input');
        for (GetAccountSummary.GetAccountSummaryResponse res : results) {
            System.assertEquals('Account not found', res.accountName);
            System.assertEquals(true, res.isPipelineEmpty);
            System.assertEquals(0, res.opportunities.size());
        }
    }

    @IsTest
    static void formatsCurrencyCompactly() {
        System.assert(GetAccountSummary.formatCurrency(950).endsWith('950'));
        System.assert(GetAccountSummary.formatCurrency(1500).endsWith('1.5K'));
        System.assert(GetAccountSummary.formatCurrency(780000).endsWith('780K'));
        System.assert(GetAccountSummary.formatCurrency(2000000).endsWith('2M'));
        System.assert(GetAccountSummary.formatCurrency(1250000000).endsWith('1.3B'));
        System.assert(GetAccountSummary.formatCurrency(-45000).startsWith('-'));
        System.assert(GetAccountSummary.formatCurrency(null).endsWith('0'));
    }

    @IsTest
    static void formatsLocationWithoutRepeatingState() {
        System.assertEquals('MUMBAI, Maharashtra', GetAccountSummary.formatLocation('MUMBAI, Maharashtra', 'Maharashtra', 'India'));
        System.assertEquals('Austin, TX', GetAccountSummary.formatLocation('Austin', 'TX', 'USA'));
        System.assertEquals('Berlin, Germany', GetAccountSummary.formatLocation('Berlin', null, 'Germany'));
        System.assertEquals('Not set', GetAccountSummary.formatLocation(null, '', null));
    }
}
