/**
 * Thin @AuraEnabled facade over AccountHierarchyService for the
 * accountHierarchy LWC. All exceptions are wrapped in AuraHandledException
 * so the client gets clean, user-displayable error messages.
 */
public with sharing class AccountHierarchyController {

    @AuraEnabled
    public static AccountHierarchyService.ScanResult scanFamilies() {
        try {
            return AccountHierarchyService.scanFamilies();
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    @AuraEnabled
    public static AccountHierarchyService.HierarchyProposal proposeHierarchy(
        AccountHierarchyService.AccountFamily family
    ) {
        try {
            return AccountHierarchyService.proposeHierarchy(family);
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    @AuraEnabled
    public static AccountHierarchyService.ApplyResult applyChanges(
        List<AccountHierarchyService.HierarchyChange> changes
    ) {
        try {
            return AccountHierarchyService.applyChanges(changes);
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    @AuraEnabled
    public static String createGapAccount(AccountHierarchyService.GapInput input) {
        try {
            return AccountHierarchyService.createGapAccount(input);
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    private static AuraHandledException uiError(Exception e) {
        AuraHandledException ahe = new AuraHandledException(e.getMessage());
        ahe.setMessage(e.getMessage());
        return ahe;
    }
}
