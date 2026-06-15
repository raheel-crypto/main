public with sharing class AccountDedupeScanController {

    public class ScanSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public DateTime startedAt;
        @AuraEnabled public DateTime completedAt;
        @AuraEnabled public Integer groupCount;
        @AuraEnabled public Integer accountCount;
        @AuraEnabled public String scenariosRun;
        @AuraEnabled public String errorMessage;
    }

    public class GroupSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String scenarioKey;
        @AuraEnabled public String scenarioLabel;
        @AuraEnabled public String matchKey;
        @AuraEnabled public Integer memberCount;
        @AuraEnabled public String status;
        @AuraEnabled public DateTime resolvedAt;
        @AuraEnabled public List<MemberSummary> members;
    }

    public class MemberSummary {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String website;
        @AuraEnabled public String linkedIn;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Boolean deleted;
    }

    public class ScenarioOption {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
    }

    public class AcrConflict {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactEmail;
        @AuraEnabled public String contactTitle;
        @AuraEnabled public List<AcrRow> relations;
    }

    public class AcrRow {
        @AuraEnabled public Id relationId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Boolean isDirect;
        @AuraEnabled public String roles;
    }

    @AuraEnabled(cacheable=true)
    public static List<ScenarioOption> listScenarios() {
        List<ScenarioOption> out = new List<ScenarioOption>();
        for (String key : new List<String>{
            'exactWebsite', 'exactLinkedIn', 'nameNormalizedDomain', 'nameDomainRoot', 'fuzzyNameDomainRoot'
        }) {
            ScenarioOption o = new ScenarioOption();
            o.key = key;
            o.label = AccountDedupeScanService.SCENARIO_LABELS.get(key);
            out.add(o);
        }
        return out;
    }

    @AuraEnabled
    public static Id startScan(List<String> scenarioKeys) {
        try {
            if (scenarioKeys == null || scenarioKeys.isEmpty()) {
                throw new AuraHandledException('Pick at least one scenario to scan.');
            }
            Set<String> allowed = AccountDedupeScanService.SCENARIO_LABELS.keySet();
            List<String> cleaned = new List<String>();
            for (String k : scenarioKeys) {
                if (allowed.contains(k)) cleaned.add(k);
            }
            if (cleaned.isEmpty()) {
                throw new AuraHandledException('No valid scenarios selected.');
            }

            Dedupe_Scan__c scan = new Dedupe_Scan__c(
                Status__c = 'Running',
                Scenarios_Run__c = String.join(cleaned, ',')
            );
            insert scan;

            // Scope = 1 in production so each scenario gets its own 50K-SOQL-row
            // budget — each fetches ~18K accounts, so packing multiple into a
            // single execute() blows the limit and rolls back the transaction.
            // Tests must run all scenarios in one execute() since Test.stopTest()
            // only invokes one execute() callback.
            Integer scope = Test.isRunningTest() ? Math.max(cleaned.size(), 1) : 1;
            Database.executeBatch(new AccountDedupeScanBatch(scan.Id, cleaned), scope);
            return scan.Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<ScanSummary> listScans(Integer maxResults) {
        Integer cap = (maxResults == null || maxResults <= 0) ? 20 : Math.min(maxResults, 100);
        List<ScanSummary> out = new List<ScanSummary>();
        for (Dedupe_Scan__c s : [
            SELECT Id, Name, Status__c, CreatedDate, Completed_At__c,
                   Group_Count__c, Account_Count__c, Scenarios_Run__c, Error_Message__c
            FROM Dedupe_Scan__c
            ORDER BY CreatedDate DESC
            LIMIT :cap
        ]) {
            ScanSummary o = new ScanSummary();
            o.id = s.Id;
            o.name = s.Name;
            o.status = s.Status__c;
            o.startedAt = s.CreatedDate;
            o.completedAt = s.Completed_At__c;
            o.groupCount = s.Group_Count__c == null ? 0 : s.Group_Count__c.intValue();
            o.accountCount = s.Account_Count__c == null ? 0 : s.Account_Count__c.intValue();
            o.scenariosRun = s.Scenarios_Run__c;
            o.errorMessage = s.Error_Message__c;
            out.add(o);
        }
        return out;
    }

    @AuraEnabled(cacheable=false)
    public static List<GroupSummary> listGroups(Id scanId, String statusFilter, String scenarioFilter) {
        if (scanId == null) return new List<GroupSummary>();

        String soql = 'SELECT Id, Name, Scenario_Key__c, Scenario_Label__c, Match_Key__c, ' +
                      'Member_Count__c, Status__c, Resolved_At__c ' +
                      'FROM Dedupe_Group__c WHERE Scan__c = :scanId';
        if (String.isNotBlank(statusFilter)) {
            soql += ' AND Status__c = :statusFilter';
        }
        if (String.isNotBlank(scenarioFilter)) {
            soql += ' AND Scenario_Key__c = :scenarioFilter';
        }
        soql += ' ORDER BY Status__c ASC, Member_Count__c DESC LIMIT 500';

        List<Dedupe_Group__c> rows = Database.query(soql);
        Set<Id> groupIds = new Set<Id>();
        for (Dedupe_Group__c g : rows) groupIds.add(g.Id);

        Map<Id, List<MemberSummary>> membersByGroup = new Map<Id, List<MemberSummary>>();
        if (!groupIds.isEmpty()) {
            for (Dedupe_Group_Member__c m : [
                SELECT Id, Group__c, Account__c, Account__r.Name, Account__r.Website,
                       Account__r.LinkedIn_URL__c, Account__r.Owner.Name
                FROM Dedupe_Group_Member__c
                WHERE Group__c IN :groupIds
                ORDER BY Account__r.Name ASC NULLS LAST
            ]) {
                MemberSummary ms = new MemberSummary();
                ms.accountId = m.Account__c;
                ms.accountName = m.Account__r != null ? m.Account__r.Name : null;
                ms.website = m.Account__r != null ? m.Account__r.Website : null;
                ms.linkedIn = m.Account__r != null ? m.Account__r.LinkedIn_URL__c : null;
                ms.ownerName = (m.Account__r != null && m.Account__r.Owner != null) ? m.Account__r.Owner.Name : null;
                ms.deleted = (m.Account__c == null);
                if (!membersByGroup.containsKey(m.Group__c)) membersByGroup.put(m.Group__c, new List<MemberSummary>());
                membersByGroup.get(m.Group__c).add(ms);
            }
        }

        List<GroupSummary> out = new List<GroupSummary>();
        for (Dedupe_Group__c g : rows) {
            GroupSummary gs = new GroupSummary();
            gs.id = g.Id;
            gs.name = g.Name;
            gs.scenarioKey = g.Scenario_Key__c;
            gs.scenarioLabel = g.Scenario_Label__c;
            gs.matchKey = g.Match_Key__c;
            gs.memberCount = g.Member_Count__c == null ? 0 : g.Member_Count__c.intValue();
            gs.status = g.Status__c;
            gs.resolvedAt = g.Resolved_At__c;
            gs.members = membersByGroup.containsKey(g.Id) ? membersByGroup.get(g.Id) : new List<MemberSummary>();
            out.add(gs);
        }
        return out;
    }

    /**
     * For a group, return every Contact that has AccountContactRelation rows on
     * more than one account in the group. These are the relationships that
     * typically block Account merges with "Duplicate AccountContactRelation".
     */
    @AuraEnabled(cacheable=false)
    public static List<AcrConflict> listAcrConflicts(Id groupId) {
        if (groupId == null) return new List<AcrConflict>();

        Set<Id> accountIds = new Set<Id>();
        for (Dedupe_Group_Member__c m : [
            SELECT Account__c FROM Dedupe_Group_Member__c WHERE Group__c = :groupId
        ]) {
            if (m.Account__c != null) accountIds.add(m.Account__c);
        }
        if (accountIds.isEmpty()) return new List<AcrConflict>();

        Map<Id, AcrConflict> byContact = new Map<Id, AcrConflict>();
        Map<Id, Set<Id>> accountsPerContact = new Map<Id, Set<Id>>();

        for (AccountContactRelation acr : [
            SELECT Id, AccountId, Account.Name, ContactId, Contact.Name, Contact.Email,
                   Contact.Title, Roles, IsDirect
            FROM AccountContactRelation
            WHERE AccountId IN :accountIds
            ORDER BY Contact.Name NULLS LAST
            LIMIT 5000
        ]) {
            if (acr.ContactId == null) continue;

            if (!byContact.containsKey(acr.ContactId)) {
                AcrConflict c = new AcrConflict();
                c.contactId    = acr.ContactId;
                c.contactName  = acr.Contact != null ? acr.Contact.Name : null;
                c.contactEmail = acr.Contact != null ? acr.Contact.Email : null;
                c.contactTitle = acr.Contact != null ? acr.Contact.Title : null;
                c.relations    = new List<AcrRow>();
                byContact.put(acr.ContactId, c);
                accountsPerContact.put(acr.ContactId, new Set<Id>());
            }
            AcrRow row = new AcrRow();
            row.relationId  = acr.Id;
            row.accountId   = acr.AccountId;
            row.accountName = acr.Account != null ? acr.Account.Name : null;
            row.isDirect    = acr.IsDirect;
            row.roles       = acr.Roles;
            byContact.get(acr.ContactId).relations.add(row);
            accountsPerContact.get(acr.ContactId).add(acr.AccountId);
        }

        List<AcrConflict> out = new List<AcrConflict>();
        for (Id cid : byContact.keySet()) {
            if (accountsPerContact.get(cid).size() > 1) out.add(byContact.get(cid));
        }
        return out;
    }

    /**
     * For contacts whose relationships span the group's accounts, retain only
     * their relationship to the master:
     *  - IsDirect=false on a duplicate → delete
     *  - IsDirect=true on a duplicate → reparent the Contact to the master
     *    (Salesforce auto-moves the direct relationship and upgrades the
     *    existing indirect on the master if present)
     * Returns the number of relations cleaned up.
     */
    @AuraEnabled
    public static Integer cleanupAcrConflicts(Id groupId, Id masterAccountId) {
        try {
            if (groupId == null) throw new AuraHandledException('Group is required.');
            if (masterAccountId == null) throw new AuraHandledException('Master account is required.');

            Set<Id> accountIds = new Set<Id>();
            for (Dedupe_Group_Member__c m : [
                SELECT Account__c FROM Dedupe_Group_Member__c WHERE Group__c = :groupId
            ]) {
                if (m.Account__c != null) accountIds.add(m.Account__c);
            }
            if (!accountIds.contains(masterAccountId)) {
                throw new AuraHandledException('Master account is not part of this group.');
            }
            Set<Id> dupeAccountIds = new Set<Id>(accountIds);
            dupeAccountIds.remove(masterAccountId);
            if (dupeAccountIds.isEmpty()) return 0;

            // Conflict = contact has an ACR on master AND on at least one dupe.
            Set<Id> contactsOnMaster = new Set<Id>();
            for (AccountContactRelation acr : [
                SELECT ContactId FROM AccountContactRelation WHERE AccountId = :masterAccountId
            ]) {
                if (acr.ContactId != null) contactsOnMaster.add(acr.ContactId);
            }
            if (contactsOnMaster.isEmpty()) return 0;

            List<AccountContactRelation> dupeAcrs = [
                SELECT Id, ContactId, AccountId, IsDirect
                FROM AccountContactRelation
                WHERE AccountId IN :dupeAccountIds AND ContactId IN :contactsOnMaster
            ];
            if (dupeAcrs.isEmpty()) return 0;

            List<AccountContactRelation> toDelete = new List<AccountContactRelation>();
            Set<Id> contactsToReparent = new Set<Id>();
            for (AccountContactRelation acr : dupeAcrs) {
                if (acr.IsDirect) contactsToReparent.add(acr.ContactId);
                else toDelete.add(new AccountContactRelation(Id = acr.Id));
            }

            Integer cleaned = 0;
            if (!toDelete.isEmpty()) {
                delete toDelete;
                cleaned += toDelete.size();
            }
            if (!contactsToReparent.isEmpty()) {
                List<Contact> updates = new List<Contact>();
                for (Id cid : contactsToReparent) {
                    updates.add(new Contact(Id = cid, AccountId = masterAccountId));
                }
                update updates;
                cleaned += contactsToReparent.size();
            }
            return cleaned;
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }
}
