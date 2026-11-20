/**
 * REST endpoint for the off-platform large-document extractor.
 *
 * A local Files-API job (scripts/large-doc-extractor/) handles documents too
 * large for the Apex heap: it downloads the file, calls Anthropic, and POSTs the
 * raw Messages API response here. This resource runs the SAME mapping as the
 * in-platform pipeline (OrderFormExtractionJob.buildFromResponseBody) and
 * inserts the Order_Form_Extraction__c, so the row is identical to a normal one.
 *
 * POST /services/apexrest/OrderFormExtractionFromResponse
 * Body: { "opportunityId": "006...", "contentDocumentIds": ["069...","069..."],
 *         "responseBody": "<raw Anthropic Messages API response JSON>" }
 *
 * GET /services/apexrest/OrderFormExtractionFromResponse
 * Returns Rogo's standard terms block exactly as the Apex extractor sends it
 * (RogoStandardTerms: online T&Cs, DPA, SLA, subprocessor list), so the script's
 * reads see the same terms: { "termsBlock": "...", "sources": ["..."] }.
 */
@RestResource(urlMapping='/OrderFormExtractionFromResponse/*')
global with sharing class OrderFormExtractionRest {

    global class Payload {
        global Id opportunityId;
        global List<Id> contentDocumentIds;
        global String responseBody;
    }

    global class ApiResult {
        global String extractionId;
        global String status;
        global String message;
    }

    global class TermsResult {
        global String termsBlock;
        global List<String> sources;
    }

    @HttpGet
    global static TermsResult doGet() {
        TermsResult out = new TermsResult();
        RogoStandardTerms.Library lib = RogoStandardTerms.library();
        out.termsBlock = lib.promptBlock();
        out.sources = lib.sourceLines();
        return out;
    }

    @HttpPost
    global static ApiResult doPost() {
        ApiResult out = new ApiResult();
        try {
            Payload p = (Payload) JSON.deserialize(
                RestContext.request.requestBody.toString(), Payload.class);
            if (p.opportunityId == null) {
                out.status = 'Error';
                out.message = 'opportunityId is required.';
                return out;
            }
            Order_Form_Extraction__c row = OrderFormExtractionJob.buildFromResponseBody(
                p.opportunityId, p.contentDocumentIds, p.responseBody);
            OrderFormVersioning.insertWithVersioning(new List<Order_Form_Extraction__c>{ row });
            OrderFormExtractionJob.splitRenewalUpsellPairs(new Set<Id>{ p.opportunityId });
            out.extractionId = row.Id;
            out.status = row.Extraction_Status__c;
            out.message = row.Error_Message__c;
        } catch (Exception e) {
            out.status = 'Error';
            out.message = e.getMessage();
        }
        return out;
    }
}
