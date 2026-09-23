/**
 * Read-only check of whether an Opportunity can be closed from the agent:
 * which Closed Won fields already have values, whether a signed order form is
 * attached, and the prompts the widget buttons send to start Won or Lost.
 */
public with sharing class GetCloseReadiness {

    @InvocableMethod(
        label='Get Close Readiness'
        description='Checks whether an Opportunity is ready to be closed. Returns the opportunity header, whether a signed order form is attached, and a checklist of the Closed Won fields showing which still need values. Read-only. Provide the Opportunity Id (starts with 006).'
        category='Opportunity'
    )
    public static List<Response> getCloseReadiness(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            out.add(build(req));
        }
        return out;
    }

    private static Response build(Request req) {
        Response res = new Response();
        res.checklist = new List<OpportunityCloseService.Row>();
        res.neededRows = new List<OpportunityCloseService.Row>();
        res.completeRows = new List<OpportunityCloseService.Row>();
        res.totalFieldCount = OpportunityCloseService.wonFieldSpecs().size();
        res.completedCount = 0;
        res.neededTitle = 'Needed';
        res.completeTitle = 'Complete';
        res.progressLabel = 'Closed Won fields complete';
        Id oppId = OpportunityCloseService.parseOpportunityId(req.opportunityId);
        Opportunity opp = oppId == null ? null : OpportunityCloseService.loadOpportunity(oppId);
        if (opp == null) {
            res.opportunityName = 'Opportunity not found';
            res.accountName = String.isBlank(req.opportunityId) ? 'No Opportunity Id was provided' : 'No opportunity with Id ' + req.opportunityId;
            res.statusLabel = 'Not found';
            res.statusVariant = 'error';
            res.statusMessage = 'Check the Id and try again.';
            res.isClosed = false;
            res.canClose = false;
            res.isRestructure = false;
            res.hasSignedDocument = false;
            res.missingSignedDocument = false;
            res.signedDocumentText = OpportunityCloseService.NOT_SET;
            res.hasMissingFields = false;
            res.missingFieldCount = 0;
            res.missingFieldsText = '';
            res.stageName = OpportunityCloseService.NOT_SET;
            res.amount = OpportunityCloseService.NOT_SET;
            res.closeDate = OpportunityCloseService.NOT_SET;
            res.opportunityType = OpportunityCloseService.NOT_SET;
            res.ownerName = OpportunityCloseService.NOT_SET;
            res.closeWonPrompt = 'Which opportunity should I close?';
            res.closeLostPrompt = 'Which opportunity should I close?';
            res.opportunityUrl = URL.getOrgDomainUrl().toExternalForm();
            res.filesUrl = res.opportunityUrl;
            return res;
        }

        res.opportunityId = opp.Id;
        res.opportunityName = opp.Name;
        res.accountName = opp.Account == null ? OpportunityCloseService.NOT_SET : opp.Account.Name;
        res.stageName = opp.StageName;
        res.amount = OpportunityCloseService.formatCurrency(opp.Amount);
        res.closeDate = OpportunityCloseService.formatDate(opp.CloseDate);
        res.opportunityType = OpportunityCloseService.textOrNotSet(opp.Type);
        res.ownerName = opp.Owner == null ? OpportunityCloseService.NOT_SET : opp.Owner.Name;
        res.opportunityUrl = OpportunityCloseService.recordUrl(opp.Id);
        res.filesUrl = OpportunityCloseService.filesUrl(opp.Id);
        res.isClosed = opp.IsClosed;
        res.canClose = !opp.IsClosed;
        res.isRestructure = OpportunityCloseService.isRestructure(opp);
        res.closeWonPrompt = OpportunityCloseService.closeWonPrompt(opp);
        res.closeLostPrompt = OpportunityCloseService.closeLostPrompt(opp);

        List<String> signed = OpportunityCloseService.signedDocumentTitles(opp.Id);
        res.hasSignedDocument = !signed.isEmpty();
        res.missingSignedDocument = signed.isEmpty() && !opp.IsClosed && !res.isRestructure;
        res.signedDocumentText = signed.isEmpty()
            ? 'No signed order form attached'
            : String.join(signed, ', ');

        List<String> missing = new List<String>();
        String suggestedLob = OpportunityCloseService.suggestLob(opp);
        for (OpportunityCloseService.FieldSpec spec : OpportunityCloseService.wonFieldSpecs()) {
            Boolean needed = spec.required || (spec.key == 'optOutDate' && opp.Opt_Out__c == true);
            Boolean present = OpportunityCloseService.hasValue(spec, opp);
            String value = OpportunityCloseService.displayValue(spec, opp);
            if (present || !needed) {
                OpportunityCloseService.Row done = new OpportunityCloseService.Row(spec.label, value, 'check-circle', 'success');
                res.checklist.add(done);
                res.completeRows.add(done);
            } else {
                String status = (spec.key == 'lobDivision' && suggestedLob != null)
                    ? 'Needed. Will default to ' + suggestedLob + ' from the account type'
                    : 'Needed';
                OpportunityCloseService.Row gap = new OpportunityCloseService.Row(spec.label, status, 'alert-circle', 'warning');
                res.checklist.add(gap);
                res.neededRows.add(gap);
                missing.add(spec.label);
            }
        }
        res.missingFieldCount = missing.size();
        res.hasMissingFields = !missing.isEmpty();
        res.missingFieldsText = missing.isEmpty() ? 'All Closed Won fields have values' : String.join(missing, ', ');
        res.completedCount = res.completeRows.size();
        res.neededTitle = 'Needed (' + res.neededRows.size() + ')';
        res.completeTitle = 'Complete (' + res.completedCount + ')';
        res.progressLabel = res.completedCount + ' of ' + res.totalFieldCount + ' Closed Won fields complete';

        if (opp.IsClosed) {
            res.statusLabel = opp.IsWon ? 'Already Closed Won' : 'Already Closed Lost';
            res.statusVariant = 'info';
            res.statusMessage = 'This opportunity is already closed. Nothing further can be submitted from here.';
        } else if (res.isRestructure) {
            res.statusLabel = 'Restructure';
            res.statusVariant = 'info';
            res.statusMessage = 'Contract Restructure deals close as Won directly without the finance and handoff fields.';
        } else if (res.missingSignedDocument) {
            res.statusLabel = 'Blocked';
            res.statusVariant = 'error';
            res.statusMessage = 'A signed order form must be attached before this can be closed Won. Use the Attach signed order form button to open the opportunity Files, upload a file whose name starts with __signed, then check again.';
        } else if (res.hasMissingFields) {
            res.statusLabel = 'Fields needed';
            res.statusVariant = 'warning';
            res.statusMessage = missing.size() + ' Closed Won field(s) still need values: ' + res.missingFieldsText + '.';
        } else {
            res.statusLabel = 'Ready';
            res.statusVariant = 'success';
            res.statusMessage = 'Every Closed Won field has a value and a signed order form is attached. Review the values, then submit.';
        }
        return res;
    }

    public class Request {
        @InvocableVariable(label='Opportunity Id' description='The 15 or 18 character Id of the Opportunity (starts with 006).' required=true)
        public String opportunityId;
    }

    public class Response {
        @InvocableVariable(label='Opportunity Id') public String opportunityId;
        @InvocableVariable(label='Opportunity Name') public String opportunityName;
        @InvocableVariable(label='Account Name') public String accountName;
        @InvocableVariable(label='Stage') public String stageName;
        @InvocableVariable(label='Amount' description='Formatted currency.') public String amount;
        @InvocableVariable(label='Close Date' description='Formatted date.') public String closeDate;
        @InvocableVariable(label='Opportunity Type') public String opportunityType;
        @InvocableVariable(label='Owner') public String ownerName;
        @InvocableVariable(label='Status Label' description='Ready, Fields needed, Blocked, Restructure, or Already Closed.') public String statusLabel;
        @InvocableVariable(label='Status Variant' description='Badge variant: success, warning, error, or info.') public String statusVariant;
        @InvocableVariable(label='Status Message' description='Plain-English explanation of the status and what to do next.') public String statusMessage;
        @InvocableVariable(label='Is Closed') public Boolean isClosed;
        @InvocableVariable(label='Can Close' description='True when the opportunity is still open.') public Boolean canClose;
        @InvocableVariable(label='Is Contract Restructure') public Boolean isRestructure;
        @InvocableVariable(label='Has Signed Document') public Boolean hasSignedDocument;
        @InvocableVariable(label='Missing Signed Document' description='True when Closed Won is blocked because no signed order form is attached.') public Boolean missingSignedDocument;
        @InvocableVariable(label='Signed Document Text' description='Names of the signed documents found, or a message that none were.') public String signedDocumentText;
        @InvocableVariable(label='Has Missing Fields') public Boolean hasMissingFields;
        @InvocableVariable(label='Missing Field Count') public Integer missingFieldCount;
        @InvocableVariable(label='Missing Fields Text' description='Comma-separated labels of the Closed Won fields that still need values.') public String missingFieldsText;
        @InvocableVariable(label='Checklist' description='Every Closed Won field with its current value and whether it is present.') public List<OpportunityCloseService.Row> checklist;
        @InvocableVariable(label='Needed Rows' description='The Closed Won fields that still need a value.') public List<OpportunityCloseService.Row> neededRows;
        @InvocableVariable(label='Complete Rows' description='The Closed Won fields that already have a value, with the value.') public List<OpportunityCloseService.Row> completeRows;
        @InvocableVariable(label='Completed Count' description='Number of Closed Won fields that have a value.') public Integer completedCount;
        @InvocableVariable(label='Total Field Count' description='Number of Closed Won fields checked.') public Integer totalFieldCount;
        @InvocableVariable(label='Needed Title' description='Accordion title for the needed fields, with the count.') public String neededTitle;
        @InvocableVariable(label='Complete Title' description='Accordion title for the complete fields, with the count.') public String completeTitle;
        @InvocableVariable(label='Progress Label' description='Label for the progress bar, e.g. 4 of 27 Closed Won fields complete.') public String progressLabel;
        @InvocableVariable(label='Files URL' description='Link to the opportunity Files related list, where the signed order form is uploaded.') public String filesUrl;
        @InvocableVariable(label='Close Won Prompt') public String closeWonPrompt;
        @InvocableVariable(label='Close Lost Prompt') public String closeLostPrompt;
        @InvocableVariable(label='Opportunity URL') public String opportunityUrl;
    }
}
