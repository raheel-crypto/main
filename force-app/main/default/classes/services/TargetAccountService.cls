public with sharing class TargetAccountService {

    public static List<PipeGenController.AccountRow> build(Id userId) {
        List<Account> accounts = AccountSelector.fetchTargetAccounts(userId);
        List<PipeGenController.AccountRow> rows = new List<PipeGenController.AccountRow>();

        for (Account a : accounts) {
            PipeGenController.AccountRow row = new PipeGenController.AccountRow();
            row.id               = a.Id;
            row.name             = a.Name;
            row.type             = a.Type;
            row.accountStatus    = a.Account_Status__c;
            row.arr              = a.ARR__c;
            row.estimatedTam     = a.Estimated_TAM__c;
            row.website          = a.Website;
            row.contactCount     = a.Contacts.size();
            row.lastActivityDate = a.LastActivityDate;
            if (!a.Gong__Conversations__r.isEmpty()) {
                row.lastGongCallDate = a.Gong__Conversations__r[0].Gong__Call_Start__c;
            }
            rows.add(row);
        }

        // Populate lastActivitySubject — Map lookup avoids O(n²) nested loop
        Set<Id> acctIds = new Set<Id>();
        for (PipeGenController.AccountRow r : rows) acctIds.add(r.id);
        if (!acctIds.isEmpty()) {
            Map<Id, String> subjectByAcct = AccountSelector.fetchLastActivitySubjectByAccount(acctIds);
            for (PipeGenController.AccountRow r : rows) {
                r.lastActivitySubject = subjectByAcct.get(r.id);
            }
        }
        return rows;
    }
}
