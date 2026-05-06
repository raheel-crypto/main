/**
 * @description Data Access Object for Opportunity queries
 * Provides bulkified SOQL queries for ARR processing
 */
public with sharing class OpportunityDataAccess {
    
    /**
     * @description Retrieves all closed-won Opportunities for given Accounts
     * @param accountIds Set of Account IDs to query
     * @return Map of Account ID to List of Opportunities (sorted by Contract Start Date)
     */
    public static Map<Id, List<Opportunity>> getClosedWonByAccount(Set<Id> accountIds) {
        Map<Id, List<Opportunity>> opportunitiesByAccount = new Map<Id, List<Opportunity>>();
        
        if (accountIds == null || accountIds.isEmpty()) {
            return opportunitiesByAccount;
        }
        
        List<Opportunity> opportunities = [
            SELECT Id, 
                   AccountId,
                   Type,
                   StageName,
                   IsWon,
                   Amount,
                   CloseDate,
                   ContractId,
                   Contract_Start_Date__c,
                   Contract_End_Date__c,
                   Contract_Length_Mos__c,
                   Annual_Recurring_Revenue__c,
                   ARR__c,
                   License_Fees__c,
                   Platform_Connection_Fee__c,
                   Professional_Service_Fees__c,
                   Billing_Contact__c,
                   Billing_Notes__c,
                   ELA__c,
                   Opt_Out_Date__c,
                   Opt_Out__c,
                   Credit_Terms__c,
                   Payment_Terms__c,
                   Seat_Licenses__c
            FROM Opportunity
            WHERE AccountId IN :accountIds
              AND IsWon = true
            ORDER BY AccountId, Contract_Start_Date__c ASC NULLS FIRST, CloseDate ASC
        ];
        
        // Group by Account
        for (Opportunity opp : opportunities) {
            if (!opportunitiesByAccount.containsKey(opp.AccountId)) {
                opportunitiesByAccount.put(opp.AccountId, new List<Opportunity>());
            }
            opportunitiesByAccount.get(opp.AccountId).add(opp);
        }
        
        return opportunitiesByAccount;
    }
    
    /**
     * @description Retrieves Opportunities related to specific Contract IDs
     * @param contractIds Set of Contract IDs
     * @return Map of Contract ID to List of Opportunities
     */
    public static Map<Id, List<Opportunity>> getOpportunitiesByContract(Set<Id> contractIds) {
        Map<Id, List<Opportunity>> oppsByContract = new Map<Id, List<Opportunity>>();
        
        if (contractIds == null || contractIds.isEmpty()) {
            return oppsByContract;
        }
        
        List<Opportunity> opportunities = [
            SELECT Id,
                   ContractId,
                   ARR__c,
                   Annual_Recurring_Revenue__c,
                   License_Fees__c,
                   Platform_Connection_Fee__c,
                   Professional_Service_Fees__c
            FROM Opportunity
            WHERE ContractId IN :contractIds
              AND IsWon = true
        ];
        
        for (Opportunity opp : opportunities) {
            if (!oppsByContract.containsKey(opp.ContractId)) {
                oppsByContract.put(opp.ContractId, new List<Opportunity>());
            }
            oppsByContract.get(opp.ContractId).add(opp);
        }
        
        return oppsByContract;
    }
}