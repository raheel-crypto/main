/**
 * @description Invocable entry point for Record-Triggered Flows that fire on individual Opportunities.
 * Kept separate from AccountARRProcessor because Salesforce allows only one @InvocableMethod per class.
 */
public with sharing class AccountARRSingleProcessor {

    public class Request {
        @InvocableVariable(label='Opportunity ID' description='The Opportunity that triggered ARR processing' required=true)
        public Id opportunityId;
    }

    @InvocableMethod(label='Process ARR For Single Opportunity'
                     description='Calculates ARR and manages Contracts for the Account of a closed Opportunity'
                     category='Opportunity')
    public static List<AccountARRProcessor.Result> processSingleOpportunity(List<Request> requests) {
        List<AccountARRProcessor.Result> results = new List<AccountARRProcessor.Result>();

        if (requests == null || requests.isEmpty()) {
            AccountARRProcessor.Result r = new AccountARRProcessor.Result();
            r.success = false;
            r.errorMessage = 'No requests provided to processSingleOpportunity';
            System.debug(LoggingLevel.ERROR, 'AccountARRSingleProcessor: ' + r.errorMessage);
            results.add(r);
            return results;
        }

        for (Request req : requests) {
            results.add(AccountARRProcessor.processSingleAccountFromOpportunity(req.opportunityId));
        }
        return results;
    }
}
