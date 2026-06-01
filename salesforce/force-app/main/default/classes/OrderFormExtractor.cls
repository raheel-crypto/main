public with sharing class OrderFormExtractor {

    @TestVisible
    private static final String SIGNED_PREFIX = 'signed__';

    public class Request {
        @InvocableVariable(required=true label='Opportunity Id')
        public Id opportunityId;
    }

    public class Result {
        @InvocableVariable(label='Status') public String status;
        @InvocableVariable(label='Message') public String message;
        @InvocableVariable(label='Content Document Id') public Id contentDocumentId;
    }

    @InvocableMethod(
        label='Extract Order Form Data'
        description='Finds the signed__* file on each Opportunity and enqueues asynchronous extraction.'
        category='Sales'
    )
    public static List<Result> run(List<Request> requests) {
        Set<Id> oppIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.opportunityId != null) oppIds.add(r.opportunityId);
        }

        Map<Id, ContentDocumentLink> latestByOpp = findLatestSignedLink(oppIds);

        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            if (r == null || r.opportunityId == null) {
                res.status = 'NoDocumentFound';
                res.message = 'Missing opportunityId in request.';
                results.add(res);
                continue;
            }
            ContentDocumentLink cdl = latestByOpp.get(r.opportunityId);
            if (cdl == null) {
                res.status = 'NoDocumentFound';
                res.message = 'No file with Title starting "' + SIGNED_PREFIX + '" found on Opportunity ' + r.opportunityId + '.';
            } else {
                System.enqueueJob(new OrderFormExtractionJob(r.opportunityId, cdl.ContentDocumentId));
                res.status = 'Enqueued';
                res.contentDocumentId = cdl.ContentDocumentId;
                res.message = 'Queued extraction for ContentDocument ' + cdl.ContentDocumentId + '. A new Order_Form_Extraction__c row will be created; apply it via OrderFormApplier.';
            }
            results.add(res);
        }
        return results;
    }

    private static Map<Id, ContentDocumentLink> findLatestSignedLink(Set<Id> oppIds) {
        Map<Id, ContentDocumentLink> latest = new Map<Id, ContentDocumentLink>();
        if (oppIds.isEmpty()) return latest;

        String titlePattern = SIGNED_PREFIX + '%';
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :oppIds
              AND ContentDocument.Title LIKE :titlePattern
            ORDER BY ContentDocument.LastModifiedDate DESC
        ]) {
            if (!latest.containsKey(cdl.LinkedEntityId)) {
                latest.put(cdl.LinkedEntityId, cdl);
            }
        }
        return latest;
    }
}
