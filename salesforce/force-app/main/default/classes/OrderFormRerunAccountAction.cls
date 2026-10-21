/**
 * Button action (Re-read an account's deals): calls OrderFormOps.rerunAccount and returns its message
 * for the screen flow to show. The work runs in the background.
 */
public with sharing class OrderFormRerunAccountAction {

    public class Request {
        @InvocableVariable(required=true label='Account Id')
        public Id recordId;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Rerun Order Form Extractions (Account)'
        description='Re-reads every closed-won deal with files on the account, oldest first, then rebuilds the contracts on the account from the new reads in deal order.'
        category='Order Forms'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            try {
                res.message = OrderFormOps.rerunAccount(r.recordId);
            } catch (Exception e) {
                res.message = 'Could not start: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
