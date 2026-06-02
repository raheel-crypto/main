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
        @InvocableVariable(label='Primary Content Document Id') public Id contentDocumentId;
        @InvocableVariable(label='Document Count') public Integer documentCount;
    }

    @InvocableMethod(
        label='Extract Order Form Data'
        description='Finds every signed__* file on the Opportunity and enqueues a single multi-document extraction.'
        category='Sales'
    )
    public static List<Result> run(List<Request> requests) {
        Set<Id> oppIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.opportunityId != null) oppIds.add(r.opportunityId);
        }

        Map<Id, List<Id>> docsByOpp = findAllSignedDocuments(oppIds);

        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            if (r == null || r.opportunityId == null) {
                res.status = 'NoDocumentFound';
                res.message = 'Missing opportunityId in request.';
                res.documentCount = 0;
                results.add(res);
                continue;
            }
            List<Id> docs = docsByOpp.get(r.opportunityId);
            if (docs == null || docs.isEmpty()) {
                res.status = 'NoDocumentFound';
                res.message = 'No file with Title starting "' + SIGNED_PREFIX + '" found on Opportunity ' + r.opportunityId + '.';
                res.documentCount = 0;
            } else {
                System.enqueueJob(new OrderFormExtractionJob(r.opportunityId, docs));
                res.status = 'Enqueued';
                res.contentDocumentId = docs[0];
                res.documentCount = docs.size();
                res.message = 'Queued extraction for ' + docs.size() + ' signed document(s).';
            }
            results.add(res);
        }
        return results;
    }

    private static Map<Id, List<Id>> findAllSignedDocuments(Set<Id> oppIds) {
        Map<Id, List<Id>> byOpp = new Map<Id, List<Id>>();
        if (oppIds.isEmpty()) return byOpp;

        String titlePattern = SIGNED_PREFIX + '%';
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :oppIds
              AND ContentDocument.Title LIKE :titlePattern
            ORDER BY ContentDocument.LastModifiedDate DESC
        ]) {
            List<Id> docs = byOpp.get(cdl.LinkedEntityId);
            if (docs == null) {
                docs = new List<Id>();
                byOpp.put(cdl.LinkedEntityId, docs);
            }
            docs.add(cdl.ContentDocumentId);
        }
        return byOpp;
    }
}
