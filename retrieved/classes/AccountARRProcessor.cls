/**
 * @description Main processor for Account ARR calculations
 * Provides Invocable methods for Flow integration and orchestrates all ARR operations
 */
public with sharing class AccountARRProcessor {
    
    /**
     * @description Request wrapper for Invocable method (Scheduled Flow)
     */
    public class Request {
        @InvocableVariable(label='Account IDs' description='List of Account IDs to process' required=true)
        public List<Id> accountIds;
    }
    
    /**
     * @description Result wrapper for Invocable method
     */
    public class Result {
        @InvocableVariable(label='Success' description='Whether processing was successful')
        public Boolean success;
        
        @InvocableVariable(label='Accounts Processed' description='Number of Accounts successfully processed')
        public Integer accountsProcessed;
        
        @InvocableVariable(label='Contracts Created' description='Number of Contracts created')
        public Integer contractsCreated;
        
        @InvocableVariable(label='Contracts Updated' description='Number of Contracts updated')
        public Integer contractsUpdated;
        
        @InvocableVariable(label='Error Message' description='Error details if processing failed')
        public String errorMessage;
        
        public Result() {
            this.success = true;
            this.accountsProcessed = 0;
            this.contractsCreated = 0;
            this.contractsUpdated = 0;
            this.errorMessage = '';
        }
    }
    
    /**
     * @description Invocable method for batch processing Accounts (called by Scheduled Flow)
     * @param requests List of Request objects containing Account IDs
     * @return List of Result objects with processing status
     */
    @InvocableMethod(label='Process Account ARR Batch' 
                     description='Calculates ARR and manages Contracts for multiple Accounts'
                     category='Account')
    public static List<Result> processAccountBatch(List<Request> requests) {
        List<Result> results = new List<Result>();
        
        if (requests == null || requests.isEmpty()) {
            Result errorResult = new Result();
            errorResult.success = false;
            errorResult.errorMessage = 'No requests provided';
            results.add(errorResult);
            return results;
        }
        
        // Collect all Account IDs from requests
        Set<Id> allAccountIds = new Set<Id>();
        for (Request req : requests) {
            if (req.accountIds != null) {
                allAccountIds.addAll(req.accountIds);
            }
        }
        
        // Process the Accounts
        Result result = processAccountsInternal(allAccountIds);
        results.add(result);
        
        return results;
    }
    
    /**
     * @description Processes a single Account when an Opportunity closes (called by Record-Triggered Flow)
     * @param opportunityId The Opportunity that triggered the process
     */
    public static void processSingleAccountFromOpportunity(Id opportunityId) {
        if (opportunityId == null) {
            System.debug('OpportunityId is null, cannot process');
            return;
        }
        
        // Get the Opportunity and its Account
        List<Opportunity> opps = [
            SELECT Id, AccountId 
            FROM Opportunity 
            WHERE Id = :opportunityId 
            LIMIT 1
        ];
        
        if (opps.isEmpty() || opps[0].AccountId == null) {
            System.debug('Opportunity not found or has no Account: ' + opportunityId);
            return;
        }
        
        Set<Id> accountIds = new Set<Id>{ opps[0].AccountId };
        processAccountsInternal(accountIds);
    }
    
    /**
     * @description Internal method that performs the actual ARR processing
     * @param accountIds Set of Account IDs to process
     * @return Result object with processing statistics
     */
    private static Result processAccountsInternal(Set<Id> accountIds) {
        Result result = new Result();
        
        try {
            if (accountIds == null || accountIds.isEmpty()) {
                result.success = false;
                result.errorMessage = 'No Account IDs provided';
                return result;
            }
            
            // Step 1: Query Accounts
            Map<Id, Account> accountsMap = new Map<Id, Account>([
                SELECT Id, 
                       Account_Status__c,
                       ARR__c,
                       Renewal_Date__c
                FROM Account
                WHERE Id IN :accountIds
            ]);
            
            // Step 2: Query all closed-won Opportunities for these Accounts
            Map<Id, List<Opportunity>> oppsByAccount = OpportunityDataAccess.getClosedWonByAccount(accountIds);
            
            // Step 3: Calculate ARR for each Account and collect Contract operations
            List<Contract> allContractsToCreate = new List<Contract>();
            List<Contract> allContractsToUpdate = new List<Contract>();
            Map<Id, Account> accountsToUpdate = new Map<Id, Account>();
            
            for (Id accountId : accountIds) {
                Account acc = accountsMap.get(accountId);
                List<Opportunity> opps = oppsByAccount.get(accountId);
                
                if (opps == null || opps.isEmpty()) {
                    // No opportunities, set ARR to 0 if not a Customer
                    if (acc.Account_Status__c != 'Customer') {
                        acc.ARR__c = 0;
                        acc.Renewal_Date__c = null;
                        accountsToUpdate.put(acc.Id, acc);
                    }
                    continue;
                }
                
                // Calculate ARR for this Account
                ARRCalculator.ARRResult arrResult = ARRCalculator.calculateAccountARR(acc, opps);
                
                // Update Account fields
                if (acc.Account_Status__c == 'Customer') {
                    acc.ARR__c = arrResult.totalARR;
                    acc.Renewal_Date__c = arrResult.renewalDate;
                } else {
                    // Former Customer - set to 0
                    acc.ARR__c = 0;
                    acc.Renewal_Date__c = null;
                }
                accountsToUpdate.put(acc.Id, acc);
                
                // Collect Contract operations
                if (!arrResult.contractsToCreate.isEmpty()) {
                    allContractsToCreate.addAll(arrResult.contractsToCreate);
                }
                if (!arrResult.contractsToUpdate.isEmpty()) {
                    allContractsToUpdate.addAll(arrResult.contractsToUpdate);
                }
            }
            
            // Step 4: Update existing Contracts first
            if (!allContractsToUpdate.isEmpty()) {
                List<Id> updatedIds = ContractService.updateContracts(allContractsToUpdate);
                result.contractsUpdated = updatedIds.size();
            }
            
            // Step 5: Create new Contracts
            Set<Id> createdContractIds = new Set<Id>();
            if (!allContractsToCreate.isEmpty()) {
                Map<Id, Id> oppToContractMap = ContractService.createContracts(allContractsToCreate);
                result.contractsCreated = oppToContractMap.size();
                createdContractIds.addAll(oppToContractMap.values());
                
                // Step 6: Link Contracts to Opportunities
                if (!oppToContractMap.isEmpty()) {
                    ContractService.linkContractsToOpportunities(oppToContractMap);
                }
                
                // Step 7: Activate newly created Contracts
                if (!createdContractIds.isEmpty()) {
                    ContractService.activateContracts(createdContractIds);
                }
            }
            
            // Step 8: Update Accounts with calculated ARR
            if (!accountsToUpdate.isEmpty()) {
                Database.SaveResult[] updateResults = Database.update(accountsToUpdate.values(), false);
                
                for (Database.SaveResult sr : updateResults) {
                    if (sr.isSuccess()) {
                        result.accountsProcessed++;
                    } else {
                        for (Database.Error err : sr.getErrors()) {
                            result.errorMessage += 'Account update error: ' + err.getMessage() + '; ';
                        }
                    }
                }
            }
            
            // Set overall success
            result.success = (result.errorMessage == '');
            
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Exception: ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString();
            System.debug('Error in processAccountsInternal: ' + result.errorMessage);
        }
        
        return result;
    }
}