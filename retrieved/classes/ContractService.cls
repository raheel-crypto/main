/**
 * @description Service class for Contract CRUD operations
 * Handles bulk Contract creation, updates, and activation
 */
public with sharing class ContractService {
    
    /**
     * @description Creates Contracts in bulk with error handling
     * @param contracts List of Contracts to create
     * @return Map of Opportunity IDs to created Contract IDs
     */
    public static Map<Id, Id> createContracts(List<Contract> contracts) {
        Map<Id, Id> oppToContractMap = new Map<Id, Id>();
        
        if (contracts == null || contracts.isEmpty()) {
            return oppToContractMap;
        }
        
        // Insert Contracts
        Database.SaveResult[] results = Database.insert(contracts, false);
        
        // Process results and build mapping
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                Contract con = contracts[i];
                oppToContractMap.put(con.Opportunity__c, results[i].getId());
            } else {
                // Log errors
                String errors = '';
                for (Database.Error err : results[i].getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug('Error creating Contract for Opportunity ' + contracts[i].Opportunity__c + ': ' + errors);
            }
        }
        
        return oppToContractMap;
    }
    
    /**
     * @description Updates Contracts in bulk with error handling
     * @param contracts List of Contracts to update
     * @return List of successfully updated Contract IDs
     */
    public static List<Id> updateContracts(List<Contract> contracts) {
        List<Id> successIds = new List<Id>();
        
        if (contracts == null || contracts.isEmpty()) {
            return successIds;
        }
        
        Database.SaveResult[] results = Database.update(contracts, false);
        
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successIds.add(results[i].getId());
            } else {
                // Log errors
                String errors = '';
                for (Database.Error err : results[i].getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug('Error updating Contract ' + contracts[i].Id + ': ' + errors);
            }
        }
        
        return successIds;
    }
    
    /**
     * @description Activates Contracts by setting Status to 'Activated'
     * @param contractIds Set of Contract IDs to activate
     * @return List of successfully activated Contract IDs
     */
    public static List<Id> activateContracts(Set<Id> contractIds) {
        List<Id> successIds = new List<Id>();
        
        if (contractIds == null || contractIds.isEmpty()) {
            return successIds;
        }
        
        List<Contract> contractsToActivate = new List<Contract>();
        for (Id contractId : contractIds) {
            contractsToActivate.add(new Contract(
                Id = contractId,
                Status = 'Activated'
            ));
        }
        
        Database.SaveResult[] results = Database.update(contractsToActivate, false);
        
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successIds.add(results[i].getId());
            } else {
                String errors = '';
                for (Database.Error err : results[i].getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug('Error activating Contract ' + contractsToActivate[i].Id + ': ' + errors);
            }
        }
        
        return successIds;
    }
    
    /**
     * @description Links created Contracts to their Opportunities
     * @param oppToContractMap Map of Opportunity ID to Contract ID
     * @return List of successfully updated Opportunity IDs
     */
    public static List<Id> linkContractsToOpportunities(Map<Id, Id> oppToContractMap) {
        List<Id> successIds = new List<Id>();
        
        if (oppToContractMap == null || oppToContractMap.isEmpty()) {
            return successIds;
        }
        
        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        for (Id oppId : oppToContractMap.keySet()) {
            oppsToUpdate.add(new Opportunity(
                Id = oppId,
                ContractId = oppToContractMap.get(oppId)
            ));
        }
        
        Database.SaveResult[] results = Database.update(oppsToUpdate, false);
        
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                successIds.add(results[i].getId());
            } else {
                String errors = '';
                for (Database.Error err : results[i].getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug('Error linking Contract to Opportunity ' + oppsToUpdate[i].Id + ': ' + errors);
            }
        }
        
        return successIds;
    }
}