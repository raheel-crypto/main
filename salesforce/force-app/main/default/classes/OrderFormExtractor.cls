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

    public static Map<Id, List<Id>> findAllSignedDocuments(Set<Id> oppIds) {
        Map<Id, List<Id>> byOpp = new Map<Id, List<Id>>();
        if (oppIds.isEmpty()) return byOpp;

        // Pull Base_Opportunity__c so we can also reach files on the parent
        // (e.g. an Upsell rider's original New Business Order Form + MSA).
        Map<Id, Id> baseByOpp = new Map<Id, Id>();
        for (Opportunity o : [SELECT Id, Base_Opportunity__c FROM Opportunity WHERE Id IN :oppIds]) {
            if (o.Base_Opportunity__c != null) baseByOpp.put(o.Id, o.Base_Opportunity__c);
        }

        Set<Id> entityIds = new Set<Id>(oppIds);
        entityIds.addAll(baseByOpp.values());

        String titlePattern = SIGNED_PREFIX + '%';
        Map<Id, List<Id>> docsByEntity = new Map<Id, List<Id>>();
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :entityIds
              AND ContentDocument.Title LIKE :titlePattern
            ORDER BY ContentDocument.LastModifiedDate DESC
        ]) {
            List<Id> docs = docsByEntity.get(cdl.LinkedEntityId);
            if (docs == null) {
                docs = new List<Id>();
                docsByEntity.put(cdl.LinkedEntityId, docs);
            }
            docs.add(cdl.ContentDocumentId);
        }

        // Combine current-Opp files + base-Opp files (dedup, preserve order).
        for (Id oppId : oppIds) {
            List<Id> ordered = new List<Id>();
            Set<Id> seen = new Set<Id>();
            if (docsByEntity.containsKey(oppId)) {
                for (Id d : docsByEntity.get(oppId)) {
                    if (seen.add(d)) ordered.add(d);
                }
            }
            Id baseId = baseByOpp.get(oppId);
            if (baseId != null && docsByEntity.containsKey(baseId)) {
                for (Id d : docsByEntity.get(baseId)) {
                    if (seen.add(d)) ordered.add(d);
                }
            }
            if (!ordered.isEmpty()) byOpp.put(oppId, ordered);
        }
        return byOpp;
    }
}
