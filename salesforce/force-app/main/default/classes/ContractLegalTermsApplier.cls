/**
 * Applies the LEGAL TERMS of an Order_Form_Extraction__c to a Contract, plus
 * its usage + product terms (ContractUsageRollup: package tier, free tiers,
 * overage rate, annual credits, blended credit rate, pricing structure) and the
 * running Total_Credits_Purchased__c.
 *
 * ARR, seats and fees are intentionally NOT written: the Opportunity flows own
 * Contract.ARR__c / Seat_Licenses__c / the fee fields and roll them into
 * Account ARR.
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
    // A picklist answer meaning the paper is silent: never written as a term,
    // never a conflict, and replaced by any real value.
    private static final String NOT_SPECIFIED = 'Not specified';

    // Statuses whose legal terms may be applied. Failed reads never are.
    private static final Set<String> APPLICABLE_STATUSES =
        new Set<String>{ 'Success', 'Incomplete', 'No Order Form' };

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

    // Contact-info fields (NOT legal terms). Applied to the Contract too, but a
    // changed primary contact is normal info churn, not a legal conflict: the
    // latest order form wins and it never sets Needs_Legal_Review__c.
    private static final List<LegalField> CONTACT_FIELDS = new List<LegalField>{
        new LegalField('Primary_Contact__c', 'Primary_Contact__c', false),
        new LegalField('Primary_Contact_Phone__c', 'Primary_Contact_Phone__c', false),
        new LegalField('Primary_Contact_Email__c', 'Primary_Contact_Email__c', false)
    };

    @InvocableMethod(
        label='Apply Order Form Legal Terms to Contract'
        description='Writes order form legal terms to the deal Contract; reconciles (never silently overwrites) on upsells.'
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
                   ELA__c, Credit_Commit__c, Credit_Overcommit_Obligation__c, Credits_Purchased__c,
                   Credits_Added__c,
                   Primary_Contact__c, Primary_Contact_Phone__c, Primary_Contact_Email__c,
                   Opportunity__r.Name, Opportunity__r.CloseDate, Opportunity__r.CreatedDate,
                   Type__c, Extracted_At__c, Package_Tier__c, Unlimited_Lite__c, Free_Max_Mid_Credits__c,
                   Free_Max_Mid_Amount__c, Free_Tier_Retained__c, Overage_Rate__c, Credit_Rate__c,
                   Credits_Per_Year__c, Credits_Period__c, Contract_Length_Months__c
            FROM Order_Form_Extraction__c
            WHERE Id IN :extractionIds
        ]);

        // Resolve target Contract Ids and bulk-load the account-fallback contracts.
        Map<Id, Id> targetContractByOfe = new Map<Id, Id>();
        Set<Id> resolvedDirectly = new Set<Id>();   // OFEs whose contract came from their own / base opp
        Set<Id> accountsNeedingFallback = new Set<Id>();
        for (Order_Form_Extraction__c ofe : ofes.values()) {
            Id direct = resolveDirectContract(ofe);
            if (direct != null) { targetContractByOfe.put(ofe.Id, direct); resolvedDirectly.add(ofe.Id); }
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
                       ELA__c, Credit_Commit__c, Credit_Overcommit_Obligation__c,
                       Primary_Contact__c, Primary_Contact_Phone__c, Primary_Contact_Email__c,
                       Opportunity__c, Source_Opportunity_Id__c,
                       Package_Tier__c, Unlimited_Lite__c, Free_Max_Mid_Credits__c, Free_Max_Mid_Amount__c,
                       Free_Tier_Retained__c, Overage_Rate__c, Credits_Per_Year__c, Credit_Rate__c,
                       Pricing_Structure__c, Total_Credits_Purchased__c
                FROM Contract WHERE Id IN :contractIds
            ]);

        // Running credit total per contract (Total_Credits_Purchased__c), recomputed
        // as a SIGNED SUM across every Success OFE applied to the contract: fresh
        // deals add Credits_Purchased__c; amendments add their Credits_Added__c (the
        // change - an upsell order form usually restates the whole contract, so its
        // Credits_Purchased__c is a total, not an increment), falling back to the
        // signed Credits_Purchased__c when no increment was captured. Recompute (not
        // increment) so it stays correct across re-runs / re-applies. Seed from OFEs
        // already stamped to these contracts, EXCLUDING the ones in this call (those
        // are added below as they apply, so a re-applied OFE is counted exactly once).
        // Versions are kept as history, so count ONE row per deal (the current one,
        // else the latest) and skip deals being applied in this call.
        Map<Id, Decimal> creditTotalByContract = new Map<Id, Decimal>();
        Map<Id, List<Order_Form_Extraction__c>> priorDealsByContract = new Map<Id, List<Order_Form_Extraction__c>>();
        if (!contractIds.isEmpty()) {
            Set<Id> oppsInThisCall = new Set<Id>();
            for (Order_Form_Extraction__c o : ofes.values()) if (o.Opportunity__c != null) oppsInThisCall.add(o.Opportunity__c);
            Set<Id> counted = new Set<Id>();
            for (Order_Form_Extraction__c prior : [
                SELECT Credits_Purchased__c, Credits_Added__c, Applied_Contract__c, Opportunity__c, Opportunity__r.Type,
                       Opportunity__r.Name, Opportunity__r.CloseDate, Opportunity__r.CreatedDate,
                       Extraction_Status__c, Type__c, Extracted_At__c, Package_Tier__c, Unlimited_Lite__c,
                       Free_Max_Mid_Credits__c, Free_Max_Mid_Amount__c, Free_Tier_Retained__c, Overage_Rate__c,
                       Credit_Rate__c, Credits_Per_Year__c, Credits_Period__c, Contract_Length_Months__c
                FROM Order_Form_Extraction__c
                WHERE Applied_Contract__c IN :contractIds
                  AND Extraction_Status__c IN :APPLICABLE_STATUSES
                  AND Id NOT IN :extractionIds
                  AND Opportunity__c NOT IN :oppsInThisCall
                ORDER BY Opportunity__c, Is_Current__c DESC, Extracted_At__c DESC NULLS LAST
            ]) {
                if (counted.contains(prior.Opportunity__c)) continue;
                counted.add(prior.Opportunity__c);
                if (!priorDealsByContract.containsKey(prior.Applied_Contract__c))
                    priorDealsByContract.put(prior.Applied_Contract__c, new List<Order_Form_Extraction__c>());
                priorDealsByContract.get(prior.Applied_Contract__c).add(prior);
                addCreditContribution(creditTotalByContract, prior.Applied_Contract__c, prior.Credits_Purchased__c,
                    prior.Credits_Added__c, prior.Opportunity__r != null ? prior.Opportunity__r.Type : null);
            }
        }

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
            // Incomplete / No Order Form rows still carry valid legal terms (an MSA
            // is the source of truth for them); only failed reads are skipped.
            if (!APPLICABLE_STATUSES.contains(ofe.Extraction_Status__c)) {
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

            // Only point the contract at this extraction when it really is this
            // contract's paper: the contract was resolved from the deal's own (or
            // base) opportunity, or the extraction's opp is the contract's source
            // opp. An account-fallback contract is someone else's paper - that is
            // how BlackRock's new term pointed at an April pilot.
            if (ofe.Extraction_Status__c != 'Success') {
                log.add('Applied legal terms only: extraction status is ' + ofe.Extraction_Status__c
                    + ', so Latest_Order_Form_Extraction__c was left unchanged.');
            } else if (resolvedDirectly.contains(ofe.Id) || isSourceOpportunity(current, ofe.Opportunity__c)) {
                changes.Latest_Order_Form_Extraction__c = ofe.Id;
            } else {
                log.add('Contract pointer not moved: this contract was found via the account fallback and is not '
                    + 'this deal\'s contract, so Latest_Order_Form_Extraction__c was left unchanged.');
            }
            changes.Reconciliation_Notes__c = truncate(String.join(log, '\n'), 32768);
            if (conflict) changes.Needs_Legal_Review__c = true;

            // Fold this OFE into the contract's running credit total (signed), then
            // write the recomputed total. Set even when it is 0 - the field is a
            // computed rollup, so an accurate 0 is correct.
            addCreditContribution(creditTotalByContract, contractId, ofe.Credits_Purchased__c,
                ofe.Credits_Added__c, ofe.Opportunity__r != null ? ofe.Opportunity__r.Type : null);
            changes.Total_Credits_Purchased__c = creditTotalByContract.containsKey(contractId)
                ? creditTotalByContract.get(contractId) : 0;

            toUpdate.put(contractId, changes);
            ofeContractStamp.put(ofe.Id, contractId);   // paper-trail link back to the OFE

            res.applied = true;
            res.needsReview = conflict;
            res.status = isAmend ? (conflict ? 'NeedsReview' : 'Reconciled') : 'Applied';
            res.notes = changes.Reconciliation_Notes__c;
        }

        applyUsageRollup(toUpdate, contractsById, ofes, ofeContractStamp, priorDealsByContract);

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

    // Usage + product terms: fold every deal on each touched contract - the prior
    // applied deals plus this call's - in deal order (ContractUsageRollup), then
    // write what changed. A field the papers never state is left as it is.
    private static void applyUsageRollup(Map<Id, Contract> toUpdate, Map<Id, Contract> contractsById,
            Map<Id, Order_Form_Extraction__c> ofes, Map<Id, Id> ofeContractStamp,
            Map<Id, List<Order_Form_Extraction__c>> priorDealsByContract) {
        Map<Id, Map<Id, Order_Form_Extraction__c>> callDealsByContract = new Map<Id, Map<Id, Order_Form_Extraction__c>>();
        for (Id ofeId : ofeContractStamp.keySet()) {
            Id contractId = ofeContractStamp.get(ofeId);
            Order_Form_Extraction__c ofe = ofes.get(ofeId);
            if (!callDealsByContract.containsKey(contractId))
                callDealsByContract.put(contractId, new Map<Id, Order_Form_Extraction__c>());
            callDealsByContract.get(contractId).put(ofe.Opportunity__c != null ? ofe.Opportunity__c : ofe.Id, ofe);
        }

        for (Id contractId : callDealsByContract.keySet()) {
            List<Order_Form_Extraction__c> deals = new List<Order_Form_Extraction__c>(callDealsByContract.get(contractId).values());
            if (priorDealsByContract.containsKey(contractId)) deals.addAll(priorDealsByContract.get(contractId));
            ContractUsageRollup.Result r = ContractUsageRollup.fold(deals);

            Contract changes = toUpdate.get(contractId);
            List<String> log = ContractUsageRollup.writeTo(r, contractsById.get(contractId), changes);
            if (!log.isEmpty()) {
                String notes = (changes.Reconciliation_Notes__c == null ? '' : changes.Reconciliation_Notes__c + '\n')
                    + 'Usage / product:\n' + String.join(log, '\n');
                changes.Reconciliation_Notes__c = truncate(notes, 32768);
            }
        }
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
            } else if (v != null && v != NOT_SPECIFIED) {
                changes.put(f.contract, v);
                log.add('Wrote ' + f.contract + ' = ' + v);
            }
        }
        // Contact info: straight write of whatever the order form states.
        for (LegalField f : CONTACT_FIELDS) {
            Object v = ofe.get(f.ofe);
            if (v != null) {
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
            if (ofeVal == null || ofeVal == NOT_SPECIFIED) {
                continue; // order form silent on this term -> preserve contract
            }
            if (curVal == null || curVal == NOT_SPECIFIED) {
                changes.put(f.contract, ofeVal);
                log.add('Wrote ' + f.contract + ' = ' + ofeVal + ' (new term)');
            } else if (!sameValue(curVal, ofeVal)) {
                conflict = true;
                log.add('CONFLICT ' + f.contract + ': contract="' + curVal + '" vs order form="' + ofeVal
                        + '" - left contract unchanged, needs legal review');
            }
        }
        // Contact info: latest order form wins - fill blanks and update changes,
        // but a differing contact is NOT a legal conflict and never triggers review.
        for (LegalField f : CONTACT_FIELDS) {
            Object ofeVal = ofe.get(f.ofe);
            if (ofeVal == null) continue; // order form silent -> preserve contract
            Object curVal = current == null ? null : current.get(f.contract);
            if (curVal == null) {
                changes.put(f.contract, ofeVal);
                log.add('Wrote ' + f.contract + ' = ' + ofeVal + ' (new)');
            } else if (!sameValue(curVal, ofeVal)) {
                changes.put(f.contract, ofeVal);
                log.add('Updated ' + f.contract + ': "' + curVal + '" -> "' + ofeVal + '" (latest order form)');
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

    // Is oppId the contract's source opportunity (Opportunity__c lookup, or the
    // Source_Opportunity_Id__c external id - 15 or 18 characters)?
    @TestVisible
    private static Boolean isSourceOpportunity(Contract c, Id oppId) {
        if (c == null || oppId == null) return false;
        if (c.Opportunity__c == oppId) return true;
        if (String.isNotBlank(c.Source_Opportunity_Id__c)) {
            try {
                return Id.valueOf(c.Source_Opportunity_Id__c) == oppId;
            } catch (Exception e) {
                return false;
            }
        }
        return false;
    }

    // One OFE's contribution to the running credit total: an amendment's captured
    // increment (already signed) when present, else the signed Credits_Purchased__c.
    private static void addCreditContribution(Map<Id, Decimal> totals, Id contractId, Decimal purchased,
                                              Decimal added, String oppType) {
        if (contractId == null) return;
        if (added != null && AMEND_TYPES.contains(oppType)) {
            Decimal running = totals.containsKey(contractId) ? totals.get(contractId) : 0;
            totals.put(contractId, running + added);
            return;
        }
        addSignedCredits(totals, contractId, purchased, oppType);
    }

    // Adds one OFE's credits to the contract's running total: Downsell subtracts,
    // every other type adds. Null credits contribute nothing.
    @TestVisible
    private static void addSignedCredits(Map<Id, Decimal> totals, Id contractId,
                                         Decimal credits, String oppType) {
        if (contractId == null || credits == null) return;
        Decimal signed = ('Downsell' == oppType) ? -credits : credits;
        Decimal running = totals.containsKey(contractId) ? totals.get(contractId) : 0;
        totals.put(contractId, running + signed);
    }
}
