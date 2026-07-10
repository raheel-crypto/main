/**
 * Applies the LEGAL TERMS of an Order_Form_Extraction__c to a Contract.
 *
 * Commercial metrics (seats, ARR, fees, license count, pricing structure,
 * package tier, credit amounts) are intentionally NOT handled here - a
 * separate agent owns those. This class only moves the legal-term fields.
 *
 * Behavior by deal type:
 *   - New Business / Renewal / Pilot: the Contract is freshly created for the
 *     deal, so we straight-write the extracted legal terms onto it.
 *   - Upsell / Downsell / Contract Restructure: the deal amends an EXISTING
 *     contract, so we reconcile field-by-field:
 *       * Contract blank, OFE has value      -> write (new term)
 *       * OFE null / silent                  -> preserve the Contract value
 *       * Both present and different         -> CONFLICT: do NOT overwrite,
 *         record it in Reconciliation_Notes__c and set Needs_Legal_Review__c.
 *       * Boolean legal terms (ELA, credit commits) only go false->true
 *         (a term can be added by an upsell, never silently removed).
 */
public with sharing class ContractLegalTermsApplier {

    public class Request {
        @InvocableVariable(required=true label='Order Form Extraction Id')
        public Id extractionId;
    }

    public class Result {
        @InvocableVariable(label='Applied') public Boolean applied;
        @InvocableVariable(label='Status') public String status; // Applied | Reconciled | NeedsReview | NoContract | NotSuccess | NotFound
        @InvocableVariable(label='Needs Legal Review') public Boolean needsReview;
        @InvocableVariable(label='Contract Id') public Id contractId;
        @InvocableVariable(label='Notes') public String notes;
    }

    // Amend-existing-contract deal types. Everything else is a fresh contract.
    private static final Set<String> AMEND_TYPES = new Set<String>{
        'Upsell', 'Downsell', 'Contract Restructure'
    };

    // OFE field -> Contract field. Same API names here, but kept explicit so a
    // divergence is a one-line change. isBoolean flags the add-only fields.
    private class LegalField {
        String ofe; String contract; Boolean isBoolean;
        LegalField(String o, String c, Boolean b) { ofe = o; contract = c; isBoolean = b; }
    }
    private static final List<LegalField> LEGAL_FIELDS = new List<LegalField>{
        new LegalField('Renewal_Terms__c', 'Renewal_Terms__c', false),
        new LegalField('Renewal_Fee_Escalator__c', 'Renewal_Fee_Escalator__c', false),
        new LegalField('Payment_Terms__c', 'Payment_Terms__c', false),
        new LegalField('Credit_Terms__c', 'Credit_Terms__c', false),
        new LegalField('Rate_Limitable__c', 'Rate_Limitable__c', false),
        new LegalField('Rate_Limit_Notes__c', 'Rate_Limit_Notes__c', false),
        new LegalField('Subprocessor_Notice_Period__c', 'Subprocessor_Notice_Period__c', false),
        new LegalField('Subprocessor_Restrictions__c', 'Subprocessor_Restrictions__c', false),
        new LegalField('Special_Terms__c', 'Special_Terms__c', false),
        new LegalField('ELA__c', 'ELA__c', true),
        new LegalField('Credit_Commit__c', 'Credit_Commit__c', true),
        new LegalField('Credit_Overcommit_Obligation__c', 'Credit_Overcommit_Obligation__c', true)
    };

    @InvocableMethod(
        label='Apply Order Form Legal Terms to Contract'
        description='Writes an order form extraction''s legal terms to the deal''s Contract; reconciles (never silently overwrites) on upsells.'
        category='Sales'
    )
    public static List<Result> apply(List<Request> requests) {
        Set<Id> extractionIds = new Set<Id>();
        for (Request r : requests) if (r != null && r.extractionId != null) extractionIds.add(r.extractionId);

        Map<Id, Order_Form_Extraction__c> ofes = new Map<Id, Order_Form_Extraction__c>([
            SELECT Id, Extraction_Status__c, Opportunity__c,
                   Opportunity__r.Type, Opportunity__r.AccountId, Opportunity__r.ContractId,
                   Opportunity__r.Base_Opportunity__c, Opportunity__r.Base_Opportunity__r.ContractId,
                   Renewal_Terms__c, Renewal_Fee_Escalator__c, Payment_Terms__c, Credit_Terms__c,
                   Rate_Limitable__c, Rate_Limit_Notes__c,
                   Subprocessor_Notice_Period__c, Subprocessor_Restrictions__c, Special_Terms__c,
                   ELA__c, Credit_Commit__c, Credit_Overcommit_Obligation__c
            FROM Order_Form_Extraction__c
            WHERE Id IN :extractionIds
        ]);

        // Resolve target Contract Ids and bulk-load the account-fallback contracts.
        Map<Id, Id> targetContractByOfe = new Map<Id, Id>();
        Set<Id> accountsNeedingFallback = new Set<Id>();
        for (Order_Form_Extraction__c ofe : ofes.values()) {
            Id direct = resolveDirectContract(ofe);
            if (direct != null) targetContractByOfe.put(ofe.Id, direct);
            else if (ofe.Opportunity__r != null && ofe.Opportunity__r.AccountId != null)
                accountsNeedingFallback.add(ofe.Opportunity__r.AccountId);
        }
        Map<Id, Id> latestContractByAccount = new Map<Id, Id>();
        if (!accountsNeedingFallback.isEmpty()) {
            for (Contract c : [
                SELECT Id, AccountId FROM Contract
                WHERE AccountId IN :accountsNeedingFallback
                ORDER BY CreatedDate DESC
            ]) {
                if (!latestContractByAccount.containsKey(c.AccountId))
                    latestContractByAccount.put(c.AccountId, c.Id);
            }
        }

        // Load the target Contracts with the legal fields for reconciliation.
        Set<Id> contractIds = new Set<Id>(targetContractByOfe.values());
        for (Order_Form_Extraction__c ofe : ofes.values()) {
            if (!targetContractByOfe.containsKey(ofe.Id) && ofe.Opportunity__r != null
                    && ofe.Opportunity__r.AccountId != null) {
                Id fb = latestContractByAccount.get(ofe.Opportunity__r.AccountId);
                if (fb != null) { targetContractByOfe.put(ofe.Id, fb); contractIds.add(fb); }
            }
        }
        Map<Id, Contract> contractsById = contractIds.isEmpty()
            ? new Map<Id, Contract>()
            : new Map<Id, Contract>([
                SELECT Id, Renewal_Terms__c, Renewal_Fee_Escalator__c, Payment_Terms__c, Credit_Terms__c,
                       Rate_Limitable__c, Rate_Limit_Notes__c,
                       Subprocessor_Notice_Period__c, Subprocessor_Restrictions__c, Special_Terms__c,
                       ELA__c, Credit_Commit__c, Credit_Overcommit_Obligation__c
                FROM Contract WHERE Id IN :contractIds
            ]);

        Map<Id, Contract> toUpdate = new Map<Id, Contract>();
        Map<Id, Id> ofeContractStamp = new Map<Id, Id>();   // OFE Id -> Contract it was applied to
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result res = new Result();
            res.applied = false;
            res.needsReview = false;
            results.add(res);

            if (req == null || req.extractionId == null) { res.status = 'NotFound'; res.notes = 'No extractionId.'; continue; }
            Order_Form_Extraction__c ofe = ofes.get(req.extractionId);
            if (ofe == null) { res.status = 'NotFound'; res.notes = 'Extraction not found.'; continue; }
            if (ofe.Extraction_Status__c != 'Success') {
                res.status = 'NotSuccess';
                res.notes = 'Extraction status is "' + ofe.Extraction_Status__c + '".';
                continue;
            }
            Id contractId = targetContractByOfe.get(ofe.Id);
            if (contractId == null) {
                res.status = 'NoContract';
                res.notes = 'No Contract linked to the Opportunity or its Account.';
                continue;
            }
            res.contractId = contractId;

            Contract current = contractsById.get(contractId);
            Contract changes = toUpdate.containsKey(contractId) ? toUpdate.get(contractId) : new Contract(Id = contractId);

            Boolean isAmend = ofe.Opportunity__r != null && AMEND_TYPES.contains(ofe.Opportunity__r.Type);
            List<String> log = new List<String>();
            Boolean conflict = isAmend
                ? reconcile(current, ofe, changes, log)
                : freshWrite(current, ofe, changes, log);

            changes.Latest_Order_Form_Extraction__c = ofe.Id;
            changes.Reconciliation_Notes__c = truncate(String.join(log, '\n'), 32768);
            if (conflict) changes.Needs_Legal_Review__c = true;
            toUpdate.put(contractId, changes);
            ofeContractStamp.put(ofe.Id, contractId);   // paper-trail link back to the OFE

            res.applied = true;
            res.needsReview = conflict;
            res.status = isAmend ? (conflict ? 'NeedsReview' : 'Reconciled') : 'Applied';
            res.notes = changes.Reconciliation_Notes__c;
        }

        if (!toUpdate.isEmpty()) update toUpdate.values();

        // Stamp each OFE with the Contract it was applied to, so the Contract's
        // "Order Form Extractions" related list shows the full chain (NB/Renewal
        // that created it + every upsell). Correct even for upsells, since we
        // used resolveDirectContract to find the base deal's contract.
        if (!ofeContractStamp.isEmpty()) {
            List<Order_Form_Extraction__c> stamps = new List<Order_Form_Extraction__c>();
            for (Id ofeId : ofeContractStamp.keySet()) {
                stamps.add(new Order_Form_Extraction__c(Id = ofeId, Applied_Contract__c = ofeContractStamp.get(ofeId)));
            }
            update stamps;
        }
        return results;
    }

    /** Direct contract: base Opp's contract for amendments, else this Opp's contract. */
    private static Id resolveDirectContract(Order_Form_Extraction__c ofe) {
        if (ofe.Opportunity__r == null) return null;
        Boolean isAmend = AMEND_TYPES.contains(ofe.Opportunity__r.Type);
        if (isAmend && ofe.Opportunity__r.Base_Opportunity__c != null
                && ofe.Opportunity__r.Base_Opportunity__r != null
                && ofe.Opportunity__r.Base_Opportunity__r.ContractId != null) {
            return ofe.Opportunity__r.Base_Opportunity__r.ContractId;
        }
        return ofe.Opportunity__r.ContractId;   // may be null -> caller falls back to Account
    }

    /** Fresh contract: authoritative write of every non-null legal term. */
    private static Boolean freshWrite(Contract current, Order_Form_Extraction__c ofe, Contract changes, List<String> log) {
        for (LegalField f : LEGAL_FIELDS) {
            Object v = ofe.get(f.ofe);
            if (f.isBoolean) {
                changes.put(f.contract, v == true);
                if (v == true) log.add('Set ' + f.contract + ' = true');
            } else if (v != null) {
                changes.put(f.contract, v);
                log.add('Wrote ' + f.contract + ' = ' + v);
            }
        }
        return false; // fresh contract never conflicts
    }

    /** Upsell reconcile: fill new, preserve silent, flag conflicts. Returns true if any conflict. */
    private static Boolean reconcile(Contract current, Order_Form_Extraction__c ofe, Contract changes, List<String> log) {
        Boolean conflict = false;
        for (LegalField f : LEGAL_FIELDS) {
            Object ofeVal = ofe.get(f.ofe);
            Object curVal = current == null ? null : current.get(f.contract);

            if (f.isBoolean) {
                // Add-only: false->true writes; never silently remove a legal boolean.
                if (ofeVal == true && curVal != true) {
                    changes.put(f.contract, true);
                    log.add('Added ' + f.contract + ' = true (introduced by this order)');
                }
                continue;
            }
            if (ofeVal == null) {
                continue; // order form silent on this term -> preserve contract
            }
            if (curVal == null) {
                changes.put(f.contract, ofeVal);
                log.add('Wrote ' + f.contract + ' = ' + ofeVal + ' (new term)');
            } else if (!sameValue(curVal, ofeVal)) {
                conflict = true;
                log.add('CONFLICT ' + f.contract + ': contract="' + curVal + '" vs order form="' + ofeVal
                        + '" - left contract unchanged, needs legal review');
            }
        }
        if (conflict) log.add('>>> One or more legal terms conflict with the existing contract. Review required.');
        return conflict;
    }

    private static Boolean sameValue(Object a, Object b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        if (a instanceof Decimal && b instanceof Decimal) return (Decimal) a == (Decimal) b;
        return String.valueOf(a) == String.valueOf(b);
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) return null;
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }
}
