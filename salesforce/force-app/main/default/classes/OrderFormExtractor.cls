public with sharing class OrderFormExtractor {

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
        description='Finds every document on the Opportunity (and its base Opportunity) and enqueues a single multi-document extraction.'
        category='Sales'
    )
    public static List<Result> run(List<Request> requests) {
        Set<Id> oppIds = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.opportunityId != null) oppIds.add(r.opportunityId);
        }

        Map<Id, List<Id>> docsByOpp = findAllDocuments(oppIds);

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
                res.message = 'No documents found on Opportunity ' + r.opportunityId + ' (or its base Opportunity).';
                res.documentCount = 0;
            } else {
                System.enqueueJob(new OrderFormExtractionJob(r.opportunityId, docs));
                res.status = 'Enqueued';
                res.contentDocumentId = docs[0];
                res.documentCount = docs.size();
                res.message = 'Queued extraction for ' + docs.size() + ' document(s).';
            }
            results.add(res);
        }
        return results;
    }

    // Returns every document attached to each Opportunity AND its base
    // Opportunity, most-recently-modified first. Extraction deliberately reads
    // ALL documents - not only the billing-tool "signed__" order forms - so the
    // companion MSA / DPA (where legal terms like the approved subprocessor list
    // live) is included. classifyFilesBySource then prioritizes and fits them to
    // the heap budget. This used to filter on the signed__ prefix, but that
    // prefix is a billing/Tabs marker applied only to order forms, which caused
    // MSAs and DPAs to be silently excluded from extraction.
    public static Map<Id, List<Id>> findAllDocuments(Set<Id> oppIds) {
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

        Map<Id, List<Id>> docsByEntity = new Map<Id, List<Id>>();
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.LastModifiedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :entityIds
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
