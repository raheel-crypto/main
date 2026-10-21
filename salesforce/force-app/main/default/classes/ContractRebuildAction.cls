/**
 * Button action (Rebuild a contract): calls OrderFormOps.rebuildContract and returns its message
 * for the screen flow to show. The work runs in the background.
 */
public with sharing class ContractRebuildAction {

    public class Request {
        @InvocableVariable(required=true label='Contract Id')
        public Id recordId;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Rebuild Contract Terms from Order Forms'
        description='Blanks the terms the applier manages on the contract and re-applies the current extractions of its deals, oldest first. No re-reading; ARR, seats and fees untouched.'
        category='Order Forms'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            try {
                res.message = OrderFormOps.rebuildContract(r.recordId);
            } catch (Exception e) {
                res.message = 'Could not start: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
