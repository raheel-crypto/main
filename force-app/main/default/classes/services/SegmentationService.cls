public with sharing class SegmentationService {

    public static String computeSegment(
        String status, Decimal arr, Integer openCount, Integer earlyCount,
        Boolean hasRecentCL, Boolean hasOldCL, Boolean hasOnlyOldCL,
        Date lastActivity, Date thirtyAgo
    ) {
        Boolean isCustomer       = 'Customer'.equals(status);
        Boolean isFormerCustomer = 'Former Customer'.equals(status);
        Boolean isProspect       = 'Prospect'.equals(status);

        if (isCustomer && arr != null && arr > 0) return 'Expansion';
        if (earlyCount > 0 && !isCustomer && !isFormerCustomer) return 'Early Stage';
        if (isProspect && (openCount == 0 || hasOnlyOldCL)) return 'Uncracked';
        if (!isCustomer && !isFormerCustomer && openCount == 0 && hasRecentCL) return 'Recent Closed Lost';
        if (!isCustomer && !isFormerCustomer && openCount == 0
                && lastActivity != null && lastActivity >= thirtyAgo) return 'No Opportunities';
        return 'Other';
    }

    public static List<PipeGenController.AccountCard> buildAccountCards(Id userId) {
        Date today        = Date.today();
        Date thirtyAgo    = today.addDays(-30);
        Date sixMonthsAgo = today.addDays(-180);

        List<Account> accounts = AccountSelector.fetchAllForSelection(userId);
        List<PipeGenController.AccountCard> cards = new List<PipeGenController.AccountCard>();

        for (Account a : accounts) {
            Integer openOppCount    = 0;
            Integer earlyStageCount = 0;
            Boolean hasRecentCL     = false;
            Boolean hasOldCL        = false;
            Boolean hasOnlyOldCL    = true;

            for (Opportunity o : a.Opportunities) {
                if (!o.IsClosed) {
                    openOppCount++;
                    hasOnlyOldCL = false;
                    if (PipeGenConfig.isEarlyStage(o.StageName)) earlyStageCount++;
                } else if (o.StageName == PipeGenConfig.CLOSED_LOST && o.CloseDate != null) {
                    if (o.CloseDate >= sixMonthsAgo) hasRecentCL = true;
                    else hasOldCL = true;
                }
            }

            PipeGenController.AccountCard card = new PipeGenController.AccountCard();
            card.id                = a.Id;
            card.name              = a.Name;
            card.type              = a.Type;
            card.industry          = a.Industry;
            card.isTargeted        = a.Target_Account__c;
            card.contactCount      = a.Contacts.size();
            card.openOppCount      = openOppCount;
            card.earlyStageOppCount = earlyStageCount;
            card.accountStatus     = a.Account_Status__c;
            card.arr               = a.ARR__c;
            card.accountTier       = a.Account_Tier__c;
            card.estimatedTam      = a.Estimated_TAM__c;
            card.bankerCount       = a.Number_of_Bankers__c != null ? a.Number_of_Bankers__c.intValue() : 0;
            card.website           = a.Website;
            card.lastActivityDate  = a.LastActivityDate;
            card.segment           = computeSegment(
                a.Account_Status__c, a.ARR__c, openOppCount, earlyStageCount,
                hasRecentCL, hasOldCL, hasOnlyOldCL,
                a.LastActivityDate, thirtyAgo
            );
            cards.add(card);
        }
        return cards;
    }
}
