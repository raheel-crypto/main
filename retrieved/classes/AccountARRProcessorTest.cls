/**
 * @description Comprehensive test class for Account ARR processing
 * Tests all Apex classes: AccountARRProcessor, ARRCalculator, ContractService, OpportunityDataAccess
 */
@isTest
private class AccountARRProcessorTest {
    
    /**
     * @description Test data setup
     */
    @TestSetup
    static void setupTestData() {
        // Create test Accounts
        List<Account> accounts = new List<Account>{
            new Account(Name = 'Test Customer Account 1', Account_Status__c = 'Customer'),
            new Account(Name = 'Test Customer Account 2', Account_Status__c = 'Customer'),
            new Account(Name = 'Test Former Customer Account', Account_Status__c = 'Former Customer'),
            new Account(Name = 'Test Account for Bulk', Account_Status__c = 'Customer')
        };
        insert accounts;
        
        // Create Opportunities for Account 1 - New Business
        Opportunity opp1 = new Opportunity(
            Name = 'Test New Business Opp',
            AccountId = accounts[0].Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-30),
            Type = 'New Business',
            Amount = 50000,
            Annual_Recurring_Revenue__c = 50000,
            License_Fees__c = 30000,
            Platform_Connection_Fee__c = 15000,
            Professional_Service_Fees__c = 5000,
            Contract_Start_Date__c = Date.today().addDays(-30),
            Contract_End_Date__c = Date.today().addDays(335),
            Contract_Length_Mos__c = 12,
            Billing_Contact__c = 'billing@test.com',
            Payment_Terms__c = 'Annual',
            Seat_Licenses__c = 100
        );
        insert opp1;
        
        // Create Opportunities for Account 2 - Multiple types
        List<Opportunity> account2Opps = new List<Opportunity>{
            new Opportunity(
                Name = 'Test Renewal Opp',
                AccountId = accounts[1].Id,
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(-60),
                Type = 'Renewal',
                Amount = 60000,
                Annual_Recurring_Revenue__c = 60000,
                Contract_Start_Date__c = Date.today().addDays(-60),
                Contract_End_Date__c = Date.today().addDays(305),
                Contract_Length_Mos__c = 12
            ),
            new Opportunity(
                Name = 'Test Upsell Opp',
                AccountId = accounts[1].Id,
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(-20),
                Type = 'Upsell',
                Amount = 20000,
                Annual_Recurring_Revenue__c = 20000,
                Contract_Start_Date__c = Date.today().addDays(-20),
                Contract_End_Date__c = Date.today().addDays(345),
                Contract_Length_Mos__c = 12
            )
        };
        insert account2Opps;
        
        // Create Pilot Opportunity for Account 3
        Opportunity pilotOpp = new Opportunity(
            Name = 'Test Pilot Opp',
            AccountId = accounts[2].Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-10),
            Type = 'Pilot',
            Amount = 5000,
            Annual_Recurring_Revenue__c = 5000,
            Contract_Start_Date__c = Date.today().addDays(-10),
            Contract_End_Date__c = Date.today().addDays(80),
            Contract_Length_Mos__c = 3
        );
        insert pilotOpp;
    }
    
    /**
     * @description Test batch processing via Invocable method - New Business
     */
    @isTest
    static void testProcessAccountBatch_NewBusiness() {
        // Get test Account
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Customer Account 1' LIMIT 1];
        
        // Create request
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        // Verify results
        System.assertEquals(1, results.size(), 'Should return one result');
        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Processing should succeed: ' + result.errorMessage);
        System.assertEquals(1, result.accountsProcessed, 'Should process 1 Account');
        System.assertEquals(1, result.contractsCreated, 'Should create 1 Contract');
        System.assertEquals(0, result.contractsUpdated, 'Should not update any Contracts');
        
        // Verify Account ARR
        Account updatedAcc = [SELECT ARR__c, Renewal_Date__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(50000, updatedAcc.ARR__c, 'Account ARR should be 50000');
        System.assertNotEquals(null, updatedAcc.Renewal_Date__c, 'Renewal Date should be set');
        
        // Verify Contract created
        List<Contract> contracts = [SELECT Id, Status, ARR__c FROM Contract WHERE AccountId = :acc.Id];
        System.assertEquals(1, contracts.size(), 'Should create 1 Contract');
        System.assertEquals('Activated', contracts[0].Status, 'Contract should be Activated');
        System.assertEquals(50000, contracts[0].ARR__c, 'Contract ARR should be 50000');
        
        // Verify Opportunity linked to Contract
        Opportunity opp = [SELECT ContractId FROM Opportunity WHERE AccountId = :acc.Id LIMIT 1];
        System.assertNotEquals(null, opp.ContractId, 'Opportunity should be linked to Contract');
    }
    
    /**
     * @description Test Renewal and Upsell logic
     */
    @isTest
    static void testProcessAccountBatch_RenewalAndUpsell() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Customer Account 2' LIMIT 1];
        
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Processing should succeed: ' + result.errorMessage);
        System.assertEquals(1, result.accountsProcessed, 'Should process 1 Account');
        System.assertEquals(2, result.contractsCreated, 'Should create 2 Contracts');
        
        // Verify Account ARR (Renewal + Upsell)
        Account updatedAcc = [SELECT ARR__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(80000, updatedAcc.ARR__c, 'Account ARR should be 80000 (60k + 20k)');
    }
    
    /**
     * @description Test Pilot Opportunity (should skip Contract creation)
     */
    @isTest
    static void testProcessAccountBatch_Pilot() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Former Customer Account' LIMIT 1];
        
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Processing should succeed');
        System.assertEquals(1, result.accountsProcessed, 'Should process 1 Account');
        System.assertEquals(0, result.contractsCreated, 'Should NOT create Contract for Pilot');
        
        // Verify Account ARR is 0 (Former Customer)
        Account updatedAcc = [SELECT ARR__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(0, updatedAcc.ARR__c, 'Former Customer ARR should be 0');
        
        // Verify no Contracts created
        List<Contract> contracts = [SELECT Id FROM Contract WHERE AccountId = :acc.Id];
        System.assertEquals(0, contracts.size(), 'Should not create Contract for Pilot');
    }
    
    /**
     * @description Test Former Customer (ARR should be set to 0)
     */
    @isTest
    static void testFormerCustomer_ARRSetToZero() {
        // Create Former Customer with an Opportunity
        Account formerCustomer = new Account(
            Name = 'Former Customer Test',
            Account_Status__c = 'Former Customer',
            ARR__c = 50000 // Has existing ARR
        );
        insert formerCustomer;
        
        Opportunity opp = new Opportunity(
            Name = 'Old Business',
            AccountId = formerCustomer.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-100),
            Type = 'New Business',
            Amount = 50000,
            Annual_Recurring_Revenue__c = 50000,
            Contract_Start_Date__c = Date.today().addDays(-100),
            Contract_End_Date__c = Date.today().addDays(-10) // Expired
        );
        insert opp;
        
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ formerCustomer.Id };
        
        Test.startTest();
        AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        // Verify ARR is 0 for Former Customer
        Account updatedAcc = [SELECT ARR__c, Renewal_Date__c FROM Account WHERE Id = :formerCustomer.Id];
        System.assertEquals(0, updatedAcc.ARR__c, 'Former Customer ARR should be 0');
        System.assertEquals(null, updatedAcc.Renewal_Date__c, 'Former Customer Renewal Date should be null');
    }
    
    /**
     * @description Test Contract proximity rule (2-day threshold)
     */
    @isTest
    static void testContractProximityRule() {
        Account acc = new Account(Name = 'Proximity Test Account', Account_Status__c = 'Customer');
        insert acc;
        
        Date baseDate = Date.today();
        
        // Create two Opportunities with Contract End Dates within 2 days
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'First Opp',
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = baseDate.addDays(-60),
                Type = 'New Business',
                Amount = 30000,
                Annual_Recurring_Revenue__c = 30000,
                Contract_Start_Date__c = baseDate.addDays(-60),
                Contract_End_Date__c = baseDate.addDays(305) // End date 1
            ),
            new Opportunity(
                Name = 'Second Opp',
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = baseDate.addDays(-30),
                Type = 'Upsell',
                Amount = 10000,
                Annual_Recurring_Revenue__c = 10000,
                Contract_Start_Date__c = baseDate.addDays(-30),
                Contract_End_Date__c = baseDate.addDays(306) // Within 2 days of first
            )
        };
        insert opps;
        
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        // Verify only 1 Contract created (second skipped due to proximity)
        AccountARRProcessor.Result result = results[0];
        System.assertEquals(1, result.contractsCreated, 'Should create only 1 Contract due to proximity rule');
        
        // Verify ARR still calculated correctly
        Account updatedAcc = [SELECT ARR__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(40000, updatedAcc.ARR__c, 'ARR should be 40000 (both opps counted)');
    }
    
    /**
     * @description Test bulk processing (200+ Accounts)
     */
    @isTest
    static void testBulkProcessing() {
        // Create 201 Accounts with Opportunities
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 201; i++) {
            accounts.add(new Account(
                Name = 'Bulk Test Account ' + i,
                Account_Status__c = 'Customer'
            ));
        }
        insert accounts;
        
        List<Opportunity> opps = new List<Opportunity>();
        for (Account acc : accounts) {
            opps.add(new Opportunity(
                Name = 'Bulk Opp for ' + acc.Name,
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = Date.today(),
                Type = 'New Business',
                Amount = 10000,
                Annual_Recurring_Revenue__c = 10000,
                Contract_Start_Date__c = Date.today(),
                Contract_End_Date__c = Date.today().addDays(365)
            ));
        }
        insert opps;
        
        List<Id> accountIds = new List<Id>();
        for (Account acc : accounts) {
            accountIds.add(acc.Id);
        }
        
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = accountIds;
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        // Verify bulk processing succeeded
        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Bulk processing should succeed: ' + result.errorMessage);
        System.assertEquals(201, result.accountsProcessed, 'Should process all 201 Accounts');
        System.assertEquals(201, result.contractsCreated, 'Should create 201 Contracts');
    }
    
    /**
     * @description Test AccountARRSingleProcessor invocable method (for Record-Triggered Flow)
     */
    @isTest
    static void testProcessSingleAccountFromOpportunity() {
        Account acc = new Account(Name = 'Single Opp Test', Account_Status__c = 'Customer');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Single Test Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'New Business',
            Amount = 25000,
            Annual_Recurring_Revenue__c = 25000,
            Contract_Start_Date__c = Date.today(),
            Contract_End_Date__c = Date.today().addDays(365)
        );
        insert opp;

        AccountARRSingleProcessor.Request req = new AccountARRSingleProcessor.Request();
        req.opportunityId = opp.Id;

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRSingleProcessor.processSingleOpportunity(
            new List<AccountARRSingleProcessor.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(true, results[0].success, 'Processing should succeed: ' + results[0].errorMessage);

        Account updatedAcc = [SELECT ARR__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(25000, updatedAcc.ARR__c, 'Account ARR should be updated');

        List<Contract> contracts = [SELECT Id FROM Contract WHERE AccountId = :acc.Id];
        System.assertEquals(1, contracts.size(), 'Should create 1 Contract');
    }

    /**
     * @description Test AccountARRSingleProcessor with null requests list
     */
    @isTest
    static void testProcessSingleOpportunity_NullRequests() {
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRSingleProcessor.processSingleOpportunity(null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one error result');
        System.assertEquals(false, results[0].success, 'Should fail with null requests');
        System.assert(results[0].errorMessage.contains('No requests'), 'Should have descriptive error message');
    }
    
    /**
     * @description Test error handling - null requests
     */
    @isTest
    static void testErrorHandling_NullRequests() {
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(null);
        Test.stopTest();
        
        System.assertEquals(1, results.size(), 'Should return error result');
        System.assertEquals(false, results[0].success, 'Should fail with null requests');
        System.assert(results[0].errorMessage.contains('No requests'), 'Should have error message');
    }
    
    /**
     * @description Test error handling - empty Account IDs
     */
    @isTest
    static void testErrorHandling_EmptyAccountIds() {
        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>();
        
        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();
        
        System.assertEquals(false, results[0].success, 'Should fail with empty Account IDs');
    }
    
    /**
     * @description Test OpportunityDataAccess methods
     */
    @isTest
    static void testOpportunityDataAccess() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Customer Account 1' LIMIT 1];

        Test.startTest();
        Map<Id, List<Opportunity>> oppsByAccount = OpportunityDataAccess.getClosedWonByAccount(new Set<Id>{ acc.Id });
        Test.stopTest();

        System.assert(oppsByAccount.containsKey(acc.Id), 'Should return Opportunities for Account');
        System.assertEquals(1, oppsByAccount.get(acc.Id).size(), 'Should return 1 Opportunity');
    }

    /**
     * @description Test Downsell opportunity type - ARR stays at prior value, renewal date updates
     */
    @isTest
    static void testARRCalculator_Downsell() {
        Account acc = new Account(Name = 'Downsell Test Account', Account_Status__c = 'Customer');
        insert acc;

        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(
                Name = 'New Business Before Downsell',
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(-60),
                Type = 'New Business',
                Amount = 50000,
                Annual_Recurring_Revenue__c = 50000,
                Contract_Start_Date__c = Date.today().addDays(-60),
                Contract_End_Date__c = Date.today().addDays(305)
            ),
            new Opportunity(
                Name = 'Downsell Opp',
                AccountId = acc.Id,
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(-30),
                Type = 'Downsell',
                Amount = 10000,
                Annual_Recurring_Revenue__c = 10000,
                Contract_Start_Date__c = Date.today().addDays(-30),
                Contract_End_Date__c = Date.today().addDays(340)
            )
        };
        insert opps;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Processing should succeed: ' + results[0].errorMessage);
        Account updatedAcc = [SELECT ARR__c, Renewal_Date__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(50000, updatedAcc.ARR__c, 'ARR should remain at New Business value after Downsell');
        System.assertNotEquals(null, updatedAcc.Renewal_Date__c, 'Renewal date should be set from Downsell');
    }

    /**
     * @description Test opportunity already linked to a Contract - triggers ContractAggregate/update path
     */
    @isTest
    static void testARRCalculator_ExistingContract() {
        Account acc = new Account(Name = 'Existing Contract Test', Account_Status__c = 'Customer');
        insert acc;

        Contract existingContract = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today().addDays(-60),
            ContractTerm = 12,
            ARR__c = 30000
        );
        insert existingContract;
        existingContract.Status = 'Activated';
        update existingContract;

        Opportunity opp = new Opportunity(
            Name = 'Existing Contract Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-60),
            Type = 'New Business',
            Amount = 30000,
            Annual_Recurring_Revenue__c = 30000,
            ContractId = existingContract.Id,
            Contract_Start_Date__c = Date.today().addDays(-60),
            Contract_End_Date__c = Date.today().addDays(305),
            License_Fees__c = 20000,
            Platform_Connection_Fee__c = 5000,
            Professional_Service_Fees__c = 5000
        );
        insert opp;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Processing should succeed: ' + result.errorMessage);
        System.assertEquals(0, result.contractsCreated, 'Should not create new Contract');
        System.assertEquals(1, result.contractsUpdated, 'Should update existing Contract');

        Contract updatedContract = [SELECT ARR__c FROM Contract WHERE Id = :existingContract.Id];
        System.assertEquals(30000, updatedContract.ARR__c, 'Contract ARR should be updated');
    }

    /**
     * @description Test getARRValue when both ARR fields are null - returns 0
     */
    @isTest
    static void testARRCalculator_BothARRFieldsNull() {
        Account acc = new Account(Name = 'Zero ARR Test', Account_Status__c = 'Customer');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Zero ARR Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'New Business',
            Amount = 0,
            Contract_Start_Date__c = Date.today(),
            Contract_End_Date__c = Date.today().addDays(365)
        );
        insert opp;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Processing should succeed: ' + results[0].errorMessage);
        Account updatedAcc = [SELECT ARR__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(0, updatedAcc.ARR__c, 'ARR should be 0 when both ARR fields are null');
    }

    /**
     * @description Test buildNewContract with null Contract_Start_Date__c, Contract_End_Date__c, and Contract_Length_Mos__c
     */
    @isTest
    static void testARRCalculator_NullContractDates() {
        Account acc = new Account(Name = 'Null Dates Test', Account_Status__c = 'Customer');
        insert acc;

        Opportunity opp = new Opportunity(
            Name = 'Null Dates Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'New Business',
            Amount = 20000,
            Annual_Recurring_Revenue__c = 20000
        );
        insert opp;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        AccountARRProcessor.Result result = results[0];
        System.assertEquals(true, result.success, 'Should succeed with null dates');
        System.assertEquals(1, result.contractsCreated, 'Should create Contract');

        List<Contract> contracts = [SELECT StartDate, ContractTerm FROM Contract WHERE AccountId = :acc.Id];
        System.assertEquals(1, contracts.size(), 'Should create 1 Contract');
        System.assertEquals(Date.today(), contracts[0].StartDate, 'Start date should default to CloseDate');
        System.assertEquals(12, contracts[0].ContractTerm, 'Contract term should default to 12');
    }

    /**
     * @description Test OpportunityDataAccess.getOpportunitiesByContract
     */
    @isTest
    static void testOpportunityDataAccess_GetByContract() {
        Account acc = new Account(Name = 'Contract Query Test', Account_Status__c = 'Customer');
        insert acc;

        Contract con = new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today(),
            ContractTerm = 12
        );
        insert con;
        con.Status = 'Activated';
        update con;

        Opportunity opp = new Opportunity(
            Name = 'Contract Query Opp',
            AccountId = acc.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Type = 'New Business',
            Amount = 10000,
            Annual_Recurring_Revenue__c = 10000,
            ContractId = con.Id,
            Contract_Start_Date__c = Date.today(),
            Contract_End_Date__c = Date.today().addDays(365)
        );
        insert opp;

        Test.startTest();
        Map<Id, List<Opportunity>> result = OpportunityDataAccess.getOpportunitiesByContract(new Set<Id>{ con.Id });
        Test.stopTest();

        System.assert(result.containsKey(con.Id), 'Should return Opportunities for Contract');
        System.assertEquals(1, result.get(con.Id).size(), 'Should return 1 Opportunity');
    }

    /**
     * @description Test OpportunityDataAccess null and empty inputs
     */
    @isTest
    static void testOpportunityDataAccess_EmptyInputs() {
        Test.startTest();
        System.assertEquals(0, OpportunityDataAccess.getClosedWonByAccount(null).size(), 'Should return empty map for null');
        System.assertEquals(0, OpportunityDataAccess.getClosedWonByAccount(new Set<Id>()).size(), 'Should return empty map for empty set');
        System.assertEquals(0, OpportunityDataAccess.getOpportunitiesByContract(null).size(), 'Should return empty map for null');
        System.assertEquals(0, OpportunityDataAccess.getOpportunitiesByContract(new Set<Id>()).size(), 'Should return empty map for empty set');
        Test.stopTest();
    }

    /**
     * @description Test ContractService null and empty inputs for all methods
     */
    @isTest
    static void testContractService_NullEmpty() {
        Test.startTest();
        System.assertEquals(0, ContractService.createContracts(null).size(), 'createContracts null should return empty');
        System.assertEquals(0, ContractService.createContracts(new List<Contract>()).size(), 'createContracts empty should return empty');
        System.assertEquals(0, ContractService.updateContracts(null).size(), 'updateContracts null should return empty');
        System.assertEquals(0, ContractService.updateContracts(new List<Contract>()).size(), 'updateContracts empty should return empty');
        System.assertEquals(0, ContractService.activateContracts(null).size(), 'activateContracts null should return empty');
        System.assertEquals(0, ContractService.activateContracts(new Set<Id>()).size(), 'activateContracts empty should return empty');
        System.assertEquals(0, ContractService.linkContractsToOpportunities(null).size(), 'linkContractsToOpportunities null should return empty');
        System.assertEquals(0, ContractService.linkContractsToOpportunities(new Map<Id, Id>()).size(), 'linkContractsToOpportunities empty should return empty');
        Test.stopTest();
    }

    /**
     * @description Test processSingleAccountFromOpportunity with null ID (no exception)
     */
    @isTest
    static void testProcessSingleAccount_NullId() {
        Test.startTest();
        AccountARRProcessor.processSingleAccountFromOpportunity(null);
        Test.stopTest();
        System.assert(true, 'No exception should be thrown for null opportunityId');
    }

    /**
     * @description Test Customer account with no Opportunities - ARR not modified
     */
    @isTest
    static void testCustomerAccount_NoOpportunities() {
        Account acc = new Account(Name = 'Customer No Opps', Account_Status__c = 'Customer', ARR__c = 0);
        insert acc;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Processing should succeed');
        System.assertEquals(0, results[0].accountsProcessed, 'Customer with no opps should not be counted');
    }

    /**
     * @description Test Former Customer with no Opportunities - ARR set to 0
     */
    @isTest
    static void testFormerCustomerAccount_NoOpportunities() {
        Account acc = new Account(Name = 'Former Customer No Opps', Account_Status__c = 'Former Customer', ARR__c = 25000);
        insert acc;

        AccountARRProcessor.Request req = new AccountARRProcessor.Request();
        req.accountIds = new List<Id>{ acc.Id };

        Test.startTest();
        List<AccountARRProcessor.Result> results = AccountARRProcessor.processAccountBatch(new List<AccountARRProcessor.Request>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Processing should succeed');
        Account updatedAcc = [SELECT ARR__c, Renewal_Date__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(0, updatedAcc.ARR__c, 'Former Customer ARR should be set to 0');
        System.assertEquals(null, updatedAcc.Renewal_Date__c, 'Former Customer Renewal Date should be null');
    }
}