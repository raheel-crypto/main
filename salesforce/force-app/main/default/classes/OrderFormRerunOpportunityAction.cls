/**
 * Button action (Re-read one deal): calls OrderFormOps.rerunOpportunity and returns its message
 * for the screen flow to show. The work runs in the background.
 */
public with sharing class OrderFormRerunOpportunityAction {

    public class Request {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id recordId;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Rerun Order Form Extraction (Opportunity)'
        description='Re-reads this deal from every file on it and its base deal, then rebuilds the contract it lands on from all of the deals on that contract, in order.'
        category='Order Forms'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            try {
                res.message = OrderFormOps.rerunOpportunity(r.recordId);
            } catch (Exception e) {
                res.message = 'Could not start: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
