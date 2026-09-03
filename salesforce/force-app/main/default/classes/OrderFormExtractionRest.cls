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
            insert row;
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
