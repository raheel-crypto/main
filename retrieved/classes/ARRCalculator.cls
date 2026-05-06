/**
 * @description Core business logic for Account ARR calculations
 * Handles all Opportunity types and Contract creation/update logic
 */
public with sharing class ARRCalculator {
    
    private static final Integer PROXIMITY_DAYS_THRESHOLD = 2;
    
    /**
     * @description Wrapper class for ARR calculation results
     */
    public class ARRResult {
        public Decimal totalARR { get; set; }
        public Date renewalDate { get; set; }
        public List<Contract> contractsToCreate { get; set; }
        public List<Contract> contractsToUpdate { get; set; }
        public List<Opportunity> opportunitiesToUpdate { get; set; }
        public Boolean hasErrors { get; set; }
        public String errorMessage { get; set; }
        
        public ARRResult() {
            this.totalARR = 0;
            this.renewalDate = null;
            this.contractsToCreate = new List<Contract>();
            this.contractsToUpdate = new List<Contract>();
            this.opportunitiesToUpdate = new List<Opportunity>();
            this.hasErrors = false;
            this.errorMessage = '';
        }
    }
    
    /**
     * @description Calculates ARR for an Account based on its Opportunities
     * @param account The Account record
     * @param opportunities List of closed-won Opportunities for the Account
     * @return ARRResult with calculated values and Contract operations
     */
    public static ARRResult calculateAccountARR(Account account, List<Opportunity> opportunities) {
        ARRResult result = new ARRResult();
        
        if (opportunities == null || opportunities.isEmpty()) {
            return result;
        }
        
        Date previousContractEndDate = null;
        Map<Id, ContractAggregate> contractAggregates = new Map<Id, ContractAggregate>();
        
        // Process each Opportunity in order (already sorted by Contract Start Date)
        for (Opportunity opp : opportunities) {
            
            // Skip Pilot opportunities
            if (opp.Type == 'Pilot') {
                // Update Account ARR for Pilot but don't create Contract
                result.totalARR = getARRValue(opp);
                result.renewalDate = opp.Contract_End_Date__c;
                continue;
            }
            
            // Process based on Opportunity Type
            if (opp.Type == 'New Business' || opp.Type == 'Renewal') {
                result.totalARR = getARRValue(opp);
                result.renewalDate = opp.Contract_End_Date__c;
                
            } else if (opp.Type == 'Upsell') {
                result.totalARR += getARRValue(opp);
                result.renewalDate = opp.Contract_End_Date__c;
                
            } else if (opp.Type == 'Downsell') {
                // Downsell: Update renewal date but don't adjust ARR
                result.renewalDate = opp.Contract_End_Date__c;
            }
            
            // Handle Contract creation or update
            if (opp.ContractId != null) {
                // Existing Contract - aggregate values for update
                if (!contractAggregates.containsKey(opp.ContractId)) {
                    contractAggregates.put(opp.ContractId, new ContractAggregate(opp.ContractId));
                }
                contractAggregates.get(opp.ContractId).addOpportunity(opp);
                
            } else {
                // No Contract - check if we should create one or if it's close to previous Contract
                Boolean shouldSkipContractCreation = false;
                
                if (previousContractEndDate != null && opp.Contract_End_Date__c != null) {
                    Integer daysDifference = Math.abs(previousContractEndDate.daysBetween(opp.Contract_End_Date__c));
                    if (daysDifference <= PROXIMITY_DAYS_THRESHOLD) {
                        // Contract End Dates are close - skip creation (billing proximity rule)
                        shouldSkipContractCreation = true;
                    }
                }
                
                if (!shouldSkipContractCreation) {
                    // Create new Contract
                    Contract newContract = buildNewContract(account.Id, opp);
                    result.contractsToCreate.add(newContract);
                }
            }
            
            // Track previous Contract End Date for proximity check
            previousContractEndDate = opp.Contract_End_Date__c;
        }
        
        // Build Contract updates from aggregates
        for (ContractAggregate agg : contractAggregates.values()) {
            Contract updatedContract = buildUpdatedContract(agg);
            result.contractsToUpdate.add(updatedContract);
        }
        
        return result;
    }
    
    /**
     * @description Builds a new Contract from Opportunity data
     */
    private static Contract buildNewContract(Id accountId, Opportunity opp) {
        Contract con = new Contract();
        con.AccountId = accountId;
        con.Opportunity__c = opp.Id;
        con.Status = 'Draft';
        
        // Date and term calculations
        con.StartDate = opp.Contract_Start_Date__c != null ? opp.Contract_Start_Date__c : opp.CloseDate;
        con.ContractTerm = opp.Contract_Length_Mos__c != null ? Integer.valueOf(opp.Contract_Length_Mos__c) : 12;
        
        if (opp.Contract_End_Date__c != null) {
            con.EndDate = opp.Contract_End_Date__c;
        } else {
            con.EndDate = con.StartDate.addMonths(con.ContractTerm);
        }
        
        // Financial fields
        con.ARR__c = getARRValue(opp);
        con.License_Fee__c = opp.License_Fees__c;
        con.Platform_Connection_Fee__c = opp.Platform_Connection_Fee__c;
        con.Professional_Service_Fees__c = opp.Professional_Service_Fees__c;
        
        // Billing and terms
        con.Billing_Contact__c = opp.Billing_Contact__c;
        con.Billing_Notes__c = opp.Billing_Notes__c;
        con.Credit_Terms__c = opp.Credit_Terms__c;
        con.Payment_Terms__c = opp.Payment_Terms__c;
        
        // Additional fields
        con.ELA__c = opp.ELA__c;
        con.Opt_Out_Date__c = opp.Opt_Out_Date__c;
        con.Opt_Out__c = opp.Opt_Out__c;
        con.Seat_Licenses__c = opp.Seat_Licenses__c;
        
        return con;
    }
    
    /**
     * @description Builds updated Contract from aggregated Opportunity values
     */
    private static Contract buildUpdatedContract(ContractAggregate agg) {
        Contract con = new Contract(Id = agg.contractId);
        con.ARR__c = agg.totalARR;
        con.License_Fee__c = agg.totalLicenseFee;
        con.Platform_Connection_Fee__c = agg.totalPlatformFee;
        con.Professional_Service_Fees__c = agg.totalProfessionalServicesFee;
        return con;
    }
    
    /**
     * @description Gets ARR value from Opportunity (handles both field names)
     */
    private static Decimal getARRValue(Opportunity opp) {
        if (opp.Annual_Recurring_Revenue__c != null) {
            return opp.Annual_Recurring_Revenue__c;
        }
        if (opp.ARR__c != null) {
            return opp.ARR__c;
        }
        return 0;
    }
    
    /**
     * @description Helper class to aggregate values from multiple Opportunities on same Contract
     */
    private class ContractAggregate {
        public Id contractId { get; set; }
        public Decimal totalARR { get; set; }
        public Decimal totalLicenseFee { get; set; }
        public Decimal totalPlatformFee { get; set; }
        public Decimal totalProfessionalServicesFee { get; set; }
        
        public ContractAggregate(Id contractId) {
            this.contractId = contractId;
            this.totalARR = 0;
            this.totalLicenseFee = 0;
            this.totalPlatformFee = 0;
            this.totalProfessionalServicesFee = 0;
        }
        
        public void addOpportunity(Opportunity opp) {
            this.totalARR += getARRValue(opp);
            this.totalLicenseFee += (opp.License_Fees__c != null ? opp.License_Fees__c : 0);
            this.totalPlatformFee += (opp.Platform_Connection_Fee__c != null ? opp.Platform_Connection_Fee__c : 0);
            this.totalProfessionalServicesFee += (opp.Professional_Service_Fees__c != null ? opp.Professional_Service_Fees__c : 0);
        }
    }
}