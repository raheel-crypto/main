/**
 * Thin @AuraEnabled facade over AccountHierarchyService for the
 * accountHierarchy LWC. All exceptions are wrapped in AuraHandledException
 * so the client gets clean, user-displayable error messages.
 *
 * Mutation methods accept JSON strings rather than typed inner-class params:
 * LWC's automatic Apex parameter deserialization can drop nested list fields
 * on reactive proxies, so we marshal explicitly via JSON.deserialize.
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
    public static AccountHierarchyService.HierarchyProposal proposeHierarchy(String familyJson) {
        try {
            if (String.isBlank(familyJson)) {
                throw new IllegalArgumentException('familyJson is required');
            }
            AccountHierarchyService.AccountFamily family = (AccountHierarchyService.AccountFamily)
                JSON.deserialize(familyJson, AccountHierarchyService.AccountFamily.class);
            return AccountHierarchyService.proposeHierarchy(family);
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    @AuraEnabled
    public static AccountHierarchyService.ApplyResult applyChanges(String changesJson) {
        try {
            if (String.isBlank(changesJson)) {
                throw new IllegalArgumentException('changesJson is required');
            }
            List<AccountHierarchyService.HierarchyChange> changes =
                (List<AccountHierarchyService.HierarchyChange>) JSON.deserialize(
                    changesJson, List<AccountHierarchyService.HierarchyChange>.class
                );
            return AccountHierarchyService.applyChanges(changes);
        } catch (Exception e) {
            throw uiError(e);
        }
    }

    @AuraEnabled
    public static String createGapAccount(String inputJson) {
        try {
            if (String.isBlank(inputJson)) {
                throw new IllegalArgumentException('inputJson is required');
            }
            AccountHierarchyService.GapInput input = (AccountHierarchyService.GapInput)
                JSON.deserialize(inputJson, AccountHierarchyService.GapInput.class);
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
