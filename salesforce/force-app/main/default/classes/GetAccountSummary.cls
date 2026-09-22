/**
 * Invocable action that summarizes an Account for the accountSummaryCard HXL widget.
 *
 * Exposed as an MCP tool through a custom MCP server. The response fields match the
 * widget's schema.json one-to-one so the getAccountSummary Lightning Type renderer can
 * bind each attribute from {!$attrs.outputValues.<field>}.
 *
 * Currency and date fields are returned pre-formatted as text because the widget
 * expression language has no formatting functions.
 */
global with sharing class GetAccountSummary {

    private static final Integer TOP_OPPORTUNITY_LIMIT = 5;
    private static final String NOT_SET = 'Not set';

    @InvocableMethod(
        label='Get Account Summary'
        description='Returns a summary of a Salesforce account: firmographics, owner, location, contact count, open pipeline totals, and the top open opportunities. Provide the Account Id.'
        category='Account'
    )
    global static List<GetAccountSummaryResponse> getAccountSummary(List<GetAccountSummaryRequest> requests) {
        Set<Id> accountIds = new Set<Id>();
        for (GetAccountSummaryRequest req : requests) {
            Id parsed = parseAccountId(req.accountId);
            if (parsed != null) {
                accountIds.add(parsed);
            }
        }

        Map<Id, Account> accountsById = queryAccounts(accountIds);
        Map<Id, Integer> contactCounts = countContacts(accountIds);
        Map<Id, PipelineTotals> pipelineByAccount = aggregatePipeline(accountIds);
        Map<Id, List<Opportunity>> topOppsByAccount = queryTopOpportunities(accountIds);

        String baseUrl = URL.getOrgDomainUrl().toExternalForm();

        List<GetAccountSummaryResponse> responses = new List<GetAccountSummaryResponse>();
        for (GetAccountSummaryRequest req : requests) {
            Id accountId = parseAccountId(req.accountId);
            Account acct = accountId == null ? null : accountsById.get(accountId);
            if (acct == null) {
                responses.add(notFoundResponse(req.accountId));
                continue;
            }
            responses.add(buildResponse(
                acct,
                contactCounts.get(acct.Id),
                pipelineByAccount.get(acct.Id),
                topOppsByAccount.get(acct.Id),
                baseUrl
            ));
        }
        return responses;
    }

    // ─── Queries ─────────────────────────────────────────────────────────

    private static Map<Id, Account> queryAccounts(Set<Id> accountIds) {
        if (accountIds.isEmpty()) {
            return new Map<Id, Account>();
        }
        return new Map<Id, Account>([
            SELECT Id, Name, Industry, Type, Owner.Name, Website,
                   BillingCity, BillingState, BillingCountry,
                   AnnualRevenue, NumberOfEmployees
            FROM Account
            WHERE Id IN :accountIds
            WITH USER_MODE
        ]);
    }

    private static Map<Id, Integer> countContacts(Set<Id> accountIds) {
        Map<Id, Integer> counts = new Map<Id, Integer>();
        if (accountIds.isEmpty()) {
            return counts;
        }
        for (AggregateResult ar : [
            SELECT AccountId acctId, COUNT(Id) total
            FROM Contact
            WHERE AccountId IN :accountIds
            WITH USER_MODE
            GROUP BY AccountId
        ]) {
            counts.put((Id) ar.get('acctId'), (Integer) ar.get('total'));
        }
        return counts;
    }

    private static Map<Id, PipelineTotals> aggregatePipeline(Set<Id> accountIds) {
        Map<Id, PipelineTotals> totals = new Map<Id, PipelineTotals>();
        if (accountIds.isEmpty()) {
            return totals;
        }
        for (AggregateResult ar : [
            SELECT AccountId acctId, COUNT(Id) total, SUM(Amount) amountSum
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsClosed = false
            WITH USER_MODE
            GROUP BY AccountId
        ]) {
            PipelineTotals t = new PipelineTotals();
            t.openCount = (Integer) ar.get('total');
            t.openAmount = (Decimal) ar.get('amountSum');
            totals.put((Id) ar.get('acctId'), t);
        }
        return totals;
    }

    private static Map<Id, List<Opportunity>> queryTopOpportunities(Set<Id> accountIds) {
        Map<Id, List<Opportunity>> byAccount = new Map<Id, List<Opportunity>>();
        if (accountIds.isEmpty()) {
            return byAccount;
        }
        for (Opportunity opp : [
            SELECT Id, AccountId, Name, StageName, Amount, CloseDate
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsClosed = false
            WITH USER_MODE
            ORDER BY Amount DESC NULLS LAST, CloseDate ASC
        ]) {
            List<Opportunity> opps = byAccount.get(opp.AccountId);
            if (opps == null) {
                opps = new List<Opportunity>();
                byAccount.put(opp.AccountId, opps);
            }
            if (opps.size() < TOP_OPPORTUNITY_LIMIT) {
                opps.add(opp);
            }
        }
        return byAccount;
    }

    // ─── Response assembly ───────────────────────────────────────────────

    private static GetAccountSummaryResponse buildResponse(
        Account acct,
        Integer contactCount,
        PipelineTotals pipeline,
        List<Opportunity> topOpps,
        String baseUrl
    ) {
        GetAccountSummaryResponse res = new GetAccountSummaryResponse();
        res.accountName = acct.Name;
        res.industry = defaultIfBlank(acct.Industry, NOT_SET);
        res.type = defaultIfBlank(acct.Type, 'Account');
        res.ownerName = acct.Owner == null ? NOT_SET : defaultIfBlank(acct.Owner.Name, NOT_SET);
        res.billingLocation = formatLocation(acct.BillingCity, acct.BillingState, acct.BillingCountry);
        res.website = defaultIfBlank(acct.Website, NOT_SET);
        res.annualRevenue = acct.AnnualRevenue == null ? NOT_SET : formatCurrency(acct.AnnualRevenue);
        res.numberOfEmployees = acct.NumberOfEmployees == null ? 0 : acct.NumberOfEmployees;
        res.contactCount = contactCount == null ? 0 : contactCount;

        Integer openCount = pipeline == null || pipeline.openCount == null ? 0 : pipeline.openCount;
        Decimal openAmount = pipeline == null || pipeline.openAmount == null ? 0 : pipeline.openAmount;
        res.openOpportunityCount = openCount;
        res.openPipelineAmount = formatCurrency(openAmount);
        res.hasOpenOpportunities = openCount > 0;
        res.isPipelineEmpty = openCount == 0;

        res.opportunities = new List<OpportunitySummary>();
        if (topOpps != null) {
            for (Opportunity opp : topOpps) {
                res.opportunities.add(new OpportunitySummary(opp));
            }
        }

        res.accountUrl = baseUrl + '/' + acct.Id;
        return res;
    }

    private static GetAccountSummaryResponse notFoundResponse(String requestedId) {
        GetAccountSummaryResponse res = new GetAccountSummaryResponse();
        res.accountName = 'Account not found';
        res.industry = String.isBlank(requestedId) ? 'No Account Id was provided' : 'No account with Id ' + requestedId;
        res.type = 'Unknown';
        res.ownerName = NOT_SET;
        res.billingLocation = NOT_SET;
        res.website = NOT_SET;
        res.annualRevenue = NOT_SET;
        res.numberOfEmployees = 0;
        res.contactCount = 0;
        res.openOpportunityCount = 0;
        res.openPipelineAmount = formatCurrency(0);
        res.hasOpenOpportunities = false;
        res.isPipelineEmpty = true;
        res.opportunities = new List<OpportunitySummary>();
        res.accountUrl = URL.getOrgDomainUrl().toExternalForm();
        return res;
    }

    // ─── Formatting helpers ──────────────────────────────────────────────

    private static Id parseAccountId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSobjectType() == Account.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static String defaultIfBlank(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    @TestVisible
    private static String formatLocation(String city, String state, String country) {
        List<String> parts = new List<String>();
        Boolean stateShown = false;
        if (!String.isBlank(city)) {
            parts.add(city.trim());
        }
        if (!String.isBlank(state)) {
            // Some records store "City, State" in the city field already; avoid repeating the state.
            if (parts.isEmpty() || !parts[0].toLowerCase().contains(state.trim().toLowerCase())) {
                parts.add(state.trim());
            }
            stateShown = true;
        }
        if (!String.isBlank(country) && !stateShown) {
            parts.add(country.trim());
        }
        return parts.isEmpty() ? NOT_SET : String.join(parts, ', ');
    }

    /**
     * Compact currency formatting for card display: $1.2B, $45.6M, $780K, $950.
     */
    @TestVisible
    private static String formatCurrency(Decimal amount) {
        if (amount == null) {
            amount = 0;
        }
        String symbol = currencySymbol();
        Decimal absAmount = amount.abs();
        String sign = amount < 0 ? '-' : '';
        if (absAmount >= 1000000000) {
            return sign + symbol + trimDecimal(absAmount.divide(1000000000, 1, RoundingMode.HALF_UP)) + 'B';
        }
        if (absAmount >= 1000000) {
            return sign + symbol + trimDecimal(absAmount.divide(1000000, 1, RoundingMode.HALF_UP)) + 'M';
        }
        if (absAmount >= 1000) {
            return sign + symbol + trimDecimal(absAmount.divide(1000, 1, RoundingMode.HALF_UP)) + 'K';
        }
        return sign + symbol + absAmount.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String trimDecimal(Decimal value) {
        String s = String.valueOf(value);
        return s.endsWith('.0') ? s.removeEnd('.0') : s;
    }

    private static String currencySymbol() {
        String iso = UserInfo.getDefaultCurrency();
        if (iso == 'USD' || iso == 'CAD' || iso == 'AUD') {
            return '$';
        }
        if (iso == 'EUR') {
            return '€';
        }
        if (iso == 'GBP') {
            return '£';
        }
        return iso == null ? '' : iso + ' ';
    }

    // ─── DTOs ────────────────────────────────────────────────────────────

    global class GetAccountSummaryRequest {
        @InvocableVariable(label='Account Id' description='The 15 or 18 character Id of the Account to summarize.' required=true)
        global String accountId;
    }

    global class GetAccountSummaryResponse {
        @InvocableVariable(label='Account Name' description='Display name of the account.')
        global String accountName;

        @InvocableVariable(label='Industry' description='Industry of the account, or "Not set".')
        global String industry;

        @InvocableVariable(label='Account Type' description='Account type such as Customer or Prospect. Defaults to "Account" when blank.')
        global String type;

        @InvocableVariable(label='Owner' description='Full name of the account owner.')
        global String ownerName;

        @InvocableVariable(label='Location' description='Billing city and state or country, formatted for display.')
        global String billingLocation;

        @InvocableVariable(label='Website' description='Account website.')
        global String website;

        @InvocableVariable(label='Annual Revenue' description='Annual revenue formatted as compact currency, e.g. $45.6M.')
        global String annualRevenue;

        @InvocableVariable(label='Employees' description='Number of employees.')
        global Integer numberOfEmployees;

        @InvocableVariable(label='Contacts' description='Number of contacts on the account.')
        global Integer contactCount;

        @InvocableVariable(label='Open Opportunities' description='Number of opportunities that are not closed.')
        global Integer openOpportunityCount;

        @InvocableVariable(label='Open Pipeline' description='Sum of open opportunity amounts formatted as compact currency.')
        global String openPipelineAmount;

        @InvocableVariable(label='Has Open Opportunities' description='True when at least one open opportunity exists.')
        global Boolean hasOpenOpportunities;

        @InvocableVariable(label='Pipeline Is Empty' description='True when there are no open opportunities.')
        global Boolean isPipelineEmpty;

        @InvocableVariable(label='Top Open Opportunities' description='Up to five open opportunities ordered by amount.')
        global List<OpportunitySummary> opportunities;

        @InvocableVariable(label='Account URL' description='Link to the account record in Salesforce.')
        global String accountUrl;
    }

    global class OpportunitySummary {
        @AuraEnabled global String name;
        @AuraEnabled global String stageName;
        @AuraEnabled global String amount;
        @AuraEnabled global String closeDate;

        global OpportunitySummary() {}

        global OpportunitySummary(Opportunity opp) {
            this.name = opp.Name;
            this.stageName = defaultIfBlank(opp.StageName, NOT_SET);
            this.amount = opp.Amount == null ? NOT_SET : formatCurrency(opp.Amount);
            this.closeDate = opp.CloseDate == null ? NOT_SET : opp.CloseDate.format();
        }
    }

    private class PipelineTotals {
        Integer openCount;
        Decimal openAmount;
    }
}
