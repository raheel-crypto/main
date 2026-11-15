/**
 * Button action on the Order Form Extraction page (Review Order Form
 * Extraction): reviews this saved extraction in the background - no re-read,
 * no new product lines. Force reruns a review that is already up to date or out
 * of attempts. Shadow mode: only review records are written.
 */
public with sharing class OrderFormReviewAction {

    public class Request {
        @InvocableVariable(required=true label='Order Form Extraction Id')
        public Id recordId;
        @InvocableVariable(label='Force (review again even if up to date)')
        public Boolean force;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Review Order Form Extraction'
        description='Audits a saved extraction and its product lines against the deal\'s documents (shadow mode: records findings only).'
        category='Order Forms'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            try {
                res.message = OrderFormReviewJob.enqueue(new List<Id>{ r.recordId }, r.force == true);
            } catch (Exception e) {
                res.message = 'Could not start: ' + e.getMessage();
            }
            out.add(res);
        }
        return out;
    }
}
