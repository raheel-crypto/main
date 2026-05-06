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
     * @description Request wrapper for single-Opportunity Invocable method (Record-Triggered Flow)
     */
    public class SingleOppRequest {
        @InvocableVariable(label='Opportunity ID' description='The Opportunity that triggered ARR processing' required=true)
        public Id opportunityId;
    }

    /**
     * @description Invocable method for Record-Triggered Flow — processes the Account of a single closed Opportunity.
     * Returns a Result so the Flow can inspect success/failure and route to a fault path or send an alert.
     */
    @InvocableMethod(label='Process ARR For Single Opportunity'
                     description='Calculates ARR and manages Contracts for the Account of a closed Opportunity'
                     category='Opportunity')
    public static List<Result> processSingleOpportunity(List<SingleOppRequest> requests) {
        List<Result> results = new List<Result>();

        if (requests == null || requests.isEmpty()) {
            Result r = new Result();
            r.success = false;
            r.errorMessage = 'No requests provided to processSingleOpportunity';
            System.debug(LoggingLevel.ERROR, 'ARRProcessor.processSingleOpportunity: ' + r.errorMessage);
            results.add(r);
            return results;
        }

        for (SingleOppRequest req : requests) {
            results.add(processSingleAccountFromOpportunity(req.opportunityId));
        }
        return results;
    }

    /**
     * @description Processes a single Account when an Opportunity closes.
     * Returns a Result with full error detail so callers can log or surface failures.
     */
    public static Result processSingleAccountFromOpportunity(Id opportunityId) {
        Result result = new Result();

        try {
            if (opportunityId == null) {
                result.success = false;
                result.errorMessage = 'processSingleAccountFromOpportunity called with null opportunityId';
                System.debug(LoggingLevel.ERROR, 'ARRProcessor: ' + result.errorMessage);
                return result;
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor: starting single-opp processing for Opportunity ' + opportunityId);

            List<Opportunity> opps = [
                SELECT Id, Name, AccountId, Account.Name, StageName, Type
                FROM Opportunity
                WHERE Id = :opportunityId
                LIMIT 1
            ];

            if (opps.isEmpty()) {
                result.success = false;
                result.errorMessage = 'Opportunity not found: ' + opportunityId;
                System.debug(LoggingLevel.ERROR, 'ARRProcessor: ' + result.errorMessage);
                return result;
            }

            if (opps[0].AccountId == null) {
                result.success = false;
                result.errorMessage = 'Opportunity ' + opps[0].Name + ' (' + opportunityId + ') has no Account — cannot process ARR';
                System.debug(LoggingLevel.ERROR, 'ARRProcessor: ' + result.errorMessage);
                return result;
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor: Opportunity "' + opps[0].Name + '" (Type=' + opps[0].Type + ') — processing Account "' + opps[0].Account.Name + '" (' + opps[0].AccountId + ')');

            result = processAccountsInternal(new Set<Id>{ opps[0].AccountId });

            if (!result.success) {
                System.debug(LoggingLevel.ERROR, 'ARRProcessor: processAccountsInternal failed for Opportunity ' + opportunityId + ' / Account ' + opps[0].AccountId + ' — ' + result.errorMessage);
            } else {
                System.debug(LoggingLevel.INFO, 'ARRProcessor: completed for Opportunity ' + opportunityId + ' — accountsProcessed=' + result.accountsProcessed + ', contractsCreated=' + result.contractsCreated + ', contractsUpdated=' + result.contractsUpdated);
            }

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Unhandled exception processing Opportunity ' + opportunityId + ': ' + e.getMessage() + ' | Line ' + e.getLineNumber() + ' | Stack: ' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR, 'ARRProcessor: ' + result.errorMessage);
        }

        return result;
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
                System.debug(LoggingLevel.ERROR, 'ARRProcessor.processAccountsInternal: ' + result.errorMessage);
                return result;
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 1: querying ' + accountIds.size() + ' Account(s): ' + accountIds);

            Map<Id, Account> accountsMap = new Map<Id, Account>([
                SELECT Id,
                       Name,
                       Account_Status__c,
                       ARR__c,
                       Renewal_Date__c
                FROM Account
                WHERE Id IN :accountIds
            ]);

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 1 result: found ' + accountsMap.size() + ' of ' + accountIds.size() + ' Account(s)');

            if (accountsMap.size() < accountIds.size()) {
                Set<Id> missing = new Set<Id>(accountIds);
                missing.removeAll(accountsMap.keySet());
                System.debug(LoggingLevel.WARN, 'ARRProcessor: Account IDs not found (deleted or inaccessible): ' + missing);
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 2: querying closed-won Opportunities');
            Map<Id, List<Opportunity>> oppsByAccount = OpportunityDataAccess.getClosedWonByAccount(accountIds);
            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 2 result: Opportunities found for ' + oppsByAccount.size() + ' Account(s)');

            List<Contract> allContractsToCreate = new List<Contract>();
            List<Contract> allContractsToUpdate = new List<Contract>();
            Map<Id, Account> accountsToUpdate = new Map<Id, Account>();

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 3: calculating ARR per Account');

            for (Id accountId : accountIds) {
                Account acc = accountsMap.get(accountId);

                if (acc == null) {
                    System.debug(LoggingLevel.WARN, 'ARRProcessor: skipping Account ' + accountId + ' — not found in query results (inaccessible or deleted)');
                    result.errorMessage += 'Account ' + accountId + ' not found or inaccessible; ';
                    continue;
                }

                List<Opportunity> opps = oppsByAccount.get(accountId);

                if (opps == null || opps.isEmpty()) {
                    System.debug(LoggingLevel.INFO, 'ARRProcessor: Account "' + acc.Name + '" (' + accountId + ') has no closed-won Opps — status=' + acc.Account_Status__c);
                    if (acc.Account_Status__c != 'Customer') {
                        acc.ARR__c = 0;
                        acc.Renewal_Date__c = null;
                        accountsToUpdate.put(acc.Id, acc);
                    }
                    continue;
                }

                System.debug(LoggingLevel.INFO, 'ARRProcessor: Account "' + acc.Name + '" (' + accountId + ') has ' + opps.size() + ' Opp(s) — status=' + acc.Account_Status__c);

                ARRCalculator.ARRResult arrResult = ARRCalculator.calculateAccountARR(acc, opps);

                System.debug(LoggingLevel.INFO, 'ARRProcessor: ARR result for "' + acc.Name + '" — totalARR=' + arrResult.totalARR + ', renewalDate=' + arrResult.renewalDate + ', contractsToCreate=' + arrResult.contractsToCreate.size() + ', contractsToUpdate=' + arrResult.contractsToUpdate.size());

                if (acc.Account_Status__c == 'Customer') {
                    acc.ARR__c = arrResult.totalARR;
                    acc.Renewal_Date__c = arrResult.renewalDate;
                } else {
                    acc.ARR__c = 0;
                    acc.Renewal_Date__c = null;
                    System.debug(LoggingLevel.INFO, 'ARRProcessor: "' + acc.Name + '" is Former Customer — ARR set to 0');
                }
                accountsToUpdate.put(acc.Id, acc);

                if (!arrResult.contractsToCreate.isEmpty()) {
                    allContractsToCreate.addAll(arrResult.contractsToCreate);
                }
                if (!arrResult.contractsToUpdate.isEmpty()) {
                    allContractsToUpdate.addAll(arrResult.contractsToUpdate);
                }
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 4: updating ' + allContractsToUpdate.size() + ' existing Contract(s)');
            if (!allContractsToUpdate.isEmpty()) {
                List<Id> updatedIds = ContractService.updateContracts(allContractsToUpdate);
                result.contractsUpdated = updatedIds.size();
                System.debug(LoggingLevel.INFO, 'ARRProcessor Step 4 result: ' + result.contractsUpdated + ' Contract(s) updated successfully');
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 5: creating ' + allContractsToCreate.size() + ' new Contract(s)');
            Set<Id> createdContractIds = new Set<Id>();
            if (!allContractsToCreate.isEmpty()) {
                Map<Id, Id> oppToContractMap = ContractService.createContracts(allContractsToCreate);
                result.contractsCreated = oppToContractMap.size();
                createdContractIds.addAll(oppToContractMap.values());
                System.debug(LoggingLevel.INFO, 'ARRProcessor Step 5 result: ' + result.contractsCreated + ' of ' + allContractsToCreate.size() + ' Contract(s) created');

                if (!oppToContractMap.isEmpty()) {
                    System.debug(LoggingLevel.INFO, 'ARRProcessor Step 6: linking Contracts to Opportunities');
                    List<Id> linkedIds = ContractService.linkContractsToOpportunities(oppToContractMap);
                    System.debug(LoggingLevel.INFO, 'ARRProcessor Step 6 result: ' + linkedIds.size() + ' Opportunity link(s) updated');
                }

                if (!createdContractIds.isEmpty()) {
                    System.debug(LoggingLevel.INFO, 'ARRProcessor Step 7: activating ' + createdContractIds.size() + ' Contract(s)');
                    List<Id> activatedIds = ContractService.activateContracts(createdContractIds);
                    System.debug(LoggingLevel.INFO, 'ARRProcessor Step 7 result: ' + activatedIds.size() + ' Contract(s) activated');
                }
            }

            System.debug(LoggingLevel.INFO, 'ARRProcessor Step 8: updating ' + accountsToUpdate.size() + ' Account(s) with calculated ARR');
            if (!accountsToUpdate.isEmpty()) {
                Database.SaveResult[] updateResults = Database.update(accountsToUpdate.values(), false);

                for (Integer i = 0; i < updateResults.size(); i++) {
                    if (updateResults[i].isSuccess()) {
                        result.accountsProcessed++;
                    } else {
                        Account failedAcc = accountsToUpdate.values()[i];
                        for (Database.Error err : updateResults[i].getErrors()) {
                            String errDetail = 'Account "' + failedAcc.Name + '" (' + failedAcc.Id + ') update failed: [' + err.getStatusCode() + '] ' + err.getMessage() + ' (fields: ' + String.join(err.getFields(), ', ') + '); ';
                            result.errorMessage += errDetail;
                            System.debug(LoggingLevel.ERROR, 'ARRProcessor Step 8: ' + errDetail);
                        }
                    }
                }

                System.debug(LoggingLevel.INFO, 'ARRProcessor Step 8 result: ' + result.accountsProcessed + ' Account(s) updated successfully');
            }

            result.success = (result.errorMessage == '');

            if (!result.success) {
                System.debug(LoggingLevel.ERROR, 'ARRProcessor: completed with errors — ' + result.errorMessage);
            } else {
                System.debug(LoggingLevel.INFO, 'ARRProcessor: all steps completed successfully');
            }

        } catch (Exception e) {
            result.success = false;
            result.errorMessage = 'Unhandled exception: ' + e.getMessage() + ' | Line ' + e.getLineNumber() + ' | Stack: ' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR, 'ARRProcessor.processAccountsInternal: ' + result.errorMessage);
        }

        return result;
    }
}