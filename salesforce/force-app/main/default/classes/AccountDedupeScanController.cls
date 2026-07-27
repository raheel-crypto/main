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
        @AuraEnabled public Id masterAccountId;
        @AuraEnabled public DateTime queuedAt;
        @AuraEnabled public String errorMessage;
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
                      'Member_Count__c, Status__c, Resolved_At__c, Master_Account__c, ' +
                      'Queued_At__c, Error_Message__c ' +
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
            gs.masterAccountId = g.Master_Account__c;
            gs.queuedAt = g.Queued_At__c;
            gs.errorMessage = g.Error_Message__c;
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
        if (!Schema.getGlobalDescribe().containsKey('AccountContactRelation')) return new List<AcrConflict>();

        Set<Id> accountIds = new Set<Id>();
        for (Dedupe_Group_Member__c m : [
            SELECT Account__c FROM Dedupe_Group_Member__c WHERE Group__c = :groupId
        ]) {
            if (m.Account__c != null) accountIds.add(m.Account__c);
        }
        if (accountIds.isEmpty()) return new List<AcrConflict>();

        Map<Id, AcrConflict> byContact = new Map<Id, AcrConflict>();
        Map<Id, Set<Id>> accountsPerContact = new Map<Id, Set<Id>>();

        for (SObject acr : Database.query(
            'SELECT Id, AccountId, Account.Name, ContactId, Contact.Name, Contact.Email, ' +
            '       Contact.Title, Roles, IsDirect ' +
            'FROM AccountContactRelation ' +
            'WHERE AccountId IN :accountIds ' +
            'ORDER BY Contact.Name NULLS LAST LIMIT 5000'
        )) {
            Id contactId = (Id) acr.get('ContactId');
            if (contactId == null) continue;

            if (!byContact.containsKey(contactId)) {
                SObject contact = acr.getSObject('Contact');
                AcrConflict c = new AcrConflict();
                c.contactId    = contactId;
                c.contactName  = contact != null ? (String) contact.get('Name') : null;
                c.contactEmail = contact != null ? (String) contact.get('Email') : null;
                c.contactTitle = contact != null ? (String) contact.get('Title') : null;
                c.relations    = new List<AcrRow>();
                byContact.put(contactId, c);
                accountsPerContact.put(contactId, new Set<Id>());
            }
            SObject account = acr.getSObject('Account');
            Id accountId = (Id) acr.get('AccountId');
            AcrRow row = new AcrRow();
            row.relationId  = (Id) acr.get('Id');
            row.accountId   = accountId;
            row.accountName = account != null ? (String) account.get('Name') : null;
            row.isDirect    = (Boolean) acr.get('IsDirect');
            row.roles       = (String) acr.get('Roles');
            byContact.get(contactId).relations.add(row);
            accountsPerContact.get(contactId).add(accountId);
        }

        List<AcrConflict> out = new List<AcrConflict>();
        for (Id cid : byContact.keySet()) {
            if (accountsPerContact.get(cid).size() > 1) out.add(byContact.get(cid));
        }
        return out;
    }

    /**
     * Consolidate every contact relationship that spans more than one
     * account in the group down to a single ACR row, ideally on the
     * master. Handles every relevant case in a single pass so users
     * don't have to switch masters to clear secondary collisions:
     *
     *  - Contact is directly tied to a duplicate (Contact.AccountId =
     *    dupe) → reparent the Contact to the master. Any existing
     *    indirect ACR on the master is deleted first so the auto-
     *    created direct ACR doesn't collide.
     *  - Contact's direct ACR is on the master and there are indirect
     *    ACRs on duplicates → delete the duplicate-side ACRs.
     *  - Contact has only indirect ACRs across the group → keep the one
     *    on the master if it exists; otherwise keep the first duplicate
     *    ACR (which will migrate to the master cleanly during merge).
     *
     * Returns the total number of relations changed.
     */
    @AuraEnabled
    public static Integer cleanupAcrConflicts(Id groupId, Id masterAccountId) {
        try {
            if (groupId == null) throw new AuraHandledException('Group is required.');
            if (masterAccountId == null) throw new AuraHandledException('Master account is required.');
            // Contacts-to-Multiple-Accounts may not be enabled in all orgs.
            if (!Schema.getGlobalDescribe().containsKey('AccountContactRelation')) return 0;

            Set<Id> accountIds = new Set<Id>();
            for (Dedupe_Group_Member__c m : [
                SELECT Account__c FROM Dedupe_Group_Member__c WHERE Group__c = :groupId
            ]) {
                if (m.Account__c != null) accountIds.add(m.Account__c);
            }
            if (!accountIds.contains(masterAccountId)) {
                throw new AuraHandledException('Master account is not part of this group.');
            }
            if (accountIds.size() < 2) return 0;

            // Use dynamic SOQL so the class compiles even without ACR enabled.
            Map<Id, List<SObject>> byContact = new Map<Id, List<SObject>>();
            for (SObject acr : Database.query(
                'SELECT Id, ContactId, AccountId, IsDirect FROM AccountContactRelation WHERE AccountId IN :accountIds'
            )) {
                Id cid = (Id) acr.get('ContactId');
                if (cid == null) continue;
                if (!byContact.containsKey(cid)) byContact.put(cid, new List<SObject>());
                byContact.get(cid).add(acr);
            }

            List<SObject> toDelete = new List<SObject>();
            Set<Id> contactsToReparent = new Set<Id>();

            for (Id cid : byContact.keySet()) {
                List<SObject> rows = byContact.get(cid);
                if (rows.size() <= 1) continue;

                SObject directRow;
                SObject masterIndirect;
                List<SObject> dupeIndirect = new List<SObject>();
                for (SObject r : rows) {
                    Boolean isDirect = (Boolean) r.get('IsDirect');
                    Id acctId = (Id) r.get('AccountId');
                    if (isDirect == true) {
                        directRow = r;
                    } else if (acctId == masterAccountId) {
                        masterIndirect = r;
                    } else {
                        dupeIndirect.add(r);
                    }
                }

                Id directAcctId = directRow != null ? (Id) directRow.get('AccountId') : null;
                if (directRow != null && directAcctId != masterAccountId) {
                    // Direct ACR is on a dupe → reparent the contact to master.
                    contactsToReparent.add(cid);
                    if (masterIndirect != null) toDelete.add(masterIndirect);
                    toDelete.addAll(dupeIndirect);
                } else if (directRow != null && directAcctId == masterAccountId) {
                    // Already directly on master — drop all dupe indirects.
                    toDelete.addAll(dupeIndirect);
                } else if (masterIndirect != null) {
                    // No direct; master has indirect — drop dupe indirects.
                    toDelete.addAll(dupeIndirect);
                } else if (dupeIndirect.size() > 1) {
                    // No direct, no master ACR — keep first dupe ACR, drop rest.
                    for (Integer i = 1; i < dupeIndirect.size(); i++) toDelete.add(dupeIndirect[i]);
                }
            }

            Integer cleaned = 0;
            if (!toDelete.isEmpty()) {
                Database.delete(toDelete);
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

    /**
     * Mark groups as Resolved without performing a merge — used for "Not a
     * duplicate" / bulk-dismiss flows. Records who dismissed and when.
     */
    @AuraEnabled
    public static Integer dismissGroups(List<Id> groupIds) {
        try {
            if (groupIds == null || groupIds.isEmpty()) return 0;
            List<Dedupe_Group__c> updates = new List<Dedupe_Group__c>();
            DateTime now = System.now();
            Id me = UserInfo.getUserId();
            for (Id gid : groupIds) {
                if (gid == null) continue;
                updates.add(new Dedupe_Group__c(
                    Id = gid,
                    Status__c = 'Resolved',
                    Resolved_At__c = now,
                    Resolved_By__c = me
                ));
            }
            if (updates.isEmpty()) return 0;
            update updates;
            return updates.size();
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    public class ManualAccount {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String website;
    }

    /**
     * Lightweight lookup used by the manual-group picker to show readable
     * names/sites once an Account is selected in the record picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<ManualAccount> getAccountSummaries(List<Id> ids) {
        List<ManualAccount> out = new List<ManualAccount>();
        if (ids == null || ids.isEmpty()) return out;
        for (Account a : [SELECT Id, Name, Website FROM Account WHERE Id IN :ids]) {
            ManualAccount m = new ManualAccount();
            m.accountId = a.Id;
            m.accountName = a.Name;
            m.website = a.Website;
            out.add(m);
        }
        return out;
    }

    /**
     * Create a Dedupe_Group__c covering 2–5 accounts that the user has
     * identified as a hierarchy / fuzzy duplicate set the rules wouldn't
     * catch (e.g. "Pantheon" + "Pantheon International"). Attaches to the
     * provided scan, or spins up a tagged "manual" scan if none is given,
     * so the row shows up in the existing scanner UI exactly like an
     * auto-detected group.
     */
    @AuraEnabled
    public static Id createManualGroup(Id scanId, List<Id> accountIds, String matchKey) {
        try {
            if (accountIds == null || accountIds.size() < 2) {
                throw new AuraHandledException('Pick at least 2 accounts.');
            }
            if (accountIds.size() > 5) {
                throw new AuraHandledException('Manual groups support up to 5 accounts.');
            }
            Set<Id> uniq = new Set<Id>(accountIds);
            if (uniq.size() != accountIds.size()) {
                throw new AuraHandledException('Duplicate accounts in selection.');
            }
            Integer existing = [SELECT COUNT() FROM Account WHERE Id IN :uniq];
            if (existing != uniq.size()) {
                throw new AuraHandledException('One or more accounts could not be found.');
            }

            Id targetScanId = scanId;
            if (targetScanId == null) {
                Dedupe_Scan__c s = new Dedupe_Scan__c(
                    Status__c = 'Completed',
                    Scenarios_Run__c = 'manual',
                    Completed_At__c = System.now(),
                    Group_Count__c = 0,
                    Account_Count__c = 0
                );
                insert s;
                targetScanId = s.Id;
            }

            String key = String.isBlank(matchKey) ? 'manual' : matchKey.trim().left(255);

            Dedupe_Group__c g = new Dedupe_Group__c(
                Scan__c = targetScanId,
                Scenario_Key__c = 'manual',
                Scenario_Label__c = 'Manual',
                Match_Key__c = key,
                Member_Count__c = accountIds.size(),
                Status__c = 'Open'
            );
            insert g;

            List<Dedupe_Group_Member__c> members = new List<Dedupe_Group_Member__c>();
            for (Id aid : accountIds) {
                members.add(new Dedupe_Group_Member__c(Group__c = g.Id, Account__c = aid));
            }
            insert members;

            // Roll counts forward on the scan so the history list stays accurate.
            Dedupe_Scan__c scan = [
                SELECT Group_Count__c, Account_Count__c
                FROM Dedupe_Scan__c WHERE Id = :targetScanId
            ];
            Integer gc = scan.Group_Count__c == null ? 0 : scan.Group_Count__c.intValue();
            Integer ac = scan.Account_Count__c == null ? 0 : scan.Account_Count__c.intValue();
            update new Dedupe_Scan__c(
                Id = targetScanId,
                Group_Count__c = gc + 1,
                Account_Count__c = ac + accountIds.size()
            );

            return g.Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    public class QueueRequest {
        @AuraEnabled public Id groupId;
        @AuraEnabled public Id masterId;
        @AuraEnabled public String notes;
    }

    /**
     * Stamp the picked master + notes onto each group and flip Status__c
     * to Queued so the AccountMergeQueueDrainer Queueable can absorb the
     * duplicates in the background using the MasterWinsFillNulls policy.
     * Enqueues a single drainer chain that will pick up everything just
     * queued — chained Queueables will keep draining until empty.
     */
    @AuraEnabled
    public static Integer queueGroupsForMerge(List<QueueRequest> requests) {
        try {
            if (requests == null || requests.isEmpty()) return 0;
            List<Dedupe_Group__c> updates = new List<Dedupe_Group__c>();
            DateTime now = System.now();
            for (QueueRequest r : requests) {
                if (r == null || r.groupId == null || r.masterId == null) continue;
                updates.add(new Dedupe_Group__c(
                    Id = r.groupId,
                    Master_Account__c = r.masterId,
                    Status__c = 'Queued',
                    Queued_At__c = now,
                    Merge_Notes__c = r.notes,
                    Error_Message__c = null
                ));
            }
            if (updates.isEmpty()) return 0;
            update updates;
            if (!Test.isRunningTest()) {
                // Instantiate dynamically to avoid a circular compile-time
                // dependency (drainer calls back into this class).
                Type drainerType = Type.forName('AccountMergeQueueDrainer');
                if (drainerType != null) {
                    System.enqueueJob((Queueable) drainerType.newInstance());
                }
            }
            return updates.size();
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Pulls a group back to Open and clears queue state — used when a
     * user wants to cancel a queued (but not yet processing) merge.
     */
    @AuraEnabled
    public static Integer requeueAsOpen(List<Id> groupIds) {
        try {
            if (groupIds == null || groupIds.isEmpty()) return 0;
            List<Dedupe_Group__c> updates = new List<Dedupe_Group__c>();
            for (Id gid : groupIds) {
                if (gid == null) continue;
                updates.add(new Dedupe_Group__c(
                    Id = gid,
                    Status__c = 'Open',
                    Queued_At__c = null,
                    Error_Message__c = null
                ));
            }
            if (updates.isEmpty()) return 0;
            update updates;
            return updates.size();
        } catch (Exception e) {
            throw new AuraHandledException(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    public class MemberBusinessRecords {
        @AuraEnabled public Id accountId;
        @AuraEnabled public Integer openOpps;
        @AuraEnabled public Integer renewalOpps;
        @AuraEnabled public Integer activeContracts;
        @AuraEnabled public Integer recentActivities;
    }

    public class GroupRiskSummary {
        @AuraEnabled public Id groupId;
        @AuraEnabled public List<MemberBusinessRecords> members;
    }

    /**
     * For a batch of groups, return per-member counts of business-critical
     * child records (open opps, renewal opps, active contracts, recent
     * activities). Used by the merge safety belt to flag groups where
     * absorbing a duplicate would collide with the master's own records.
     *
     * Uses 4 aggregate queries total regardless of group/member count, so
     * it scales to scanner pages of 100+ groups without governor issues.
     */
    @AuraEnabled(cacheable=false)
    public static List<GroupRiskSummary> getGroupRiskBatch(List<Id> groupIds) {
        List<GroupRiskSummary> out = new List<GroupRiskSummary>();
        if (groupIds == null || groupIds.isEmpty()) return out;

        Map<Id, List<Id>> membersByGroup = new Map<Id, List<Id>>();
        Set<Id> accountIds = new Set<Id>();
        for (Dedupe_Group_Member__c m : [
            SELECT Group__c, Account__c FROM Dedupe_Group_Member__c
            WHERE Group__c IN :groupIds AND Account__c != NULL
        ]) {
            if (!membersByGroup.containsKey(m.Group__c)) {
                membersByGroup.put(m.Group__c, new List<Id>());
            }
            membersByGroup.get(m.Group__c).add(m.Account__c);
            accountIds.add(m.Account__c);
        }
        if (accountIds.isEmpty()) return out;

        Map<Id, Integer> openOpps        = new Map<Id, Integer>();
        Map<Id, Integer> renewalOpps     = new Map<Id, Integer>();
        Map<Id, Integer> activeContracts = new Map<Id, Integer>();
        Map<Id, Integer> recentActs      = new Map<Id, Integer>();

        for (AggregateResult ar : [
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsClosed = false
            GROUP BY AccountId
        ]) {
            openOpps.put((Id) ar.get('acc'), ((Decimal) ar.get('cnt')).intValue());
        }
        for (AggregateResult ar : [
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsClosed = false AND Type = 'Renewal'
            GROUP BY AccountId
        ]) {
            renewalOpps.put((Id) ar.get('acc'), ((Decimal) ar.get('cnt')).intValue());
        }
        for (AggregateResult ar : [
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Contract
            WHERE AccountId IN :accountIds AND Status = 'Activated'
            GROUP BY AccountId
        ]) {
            activeContracts.put((Id) ar.get('acc'), ((Decimal) ar.get('cnt')).intValue());
        }
        // Tasks + Events combined into a single "recent activity" count.
        for (AggregateResult ar : [
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Task
            WHERE AccountId IN :accountIds AND CreatedDate = LAST_N_DAYS:90
            GROUP BY AccountId
        ]) {
            Id aid = (Id) ar.get('acc');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            recentActs.put(aid, (recentActs.containsKey(aid) ? recentActs.get(aid) : 0) + cnt);
        }
        for (AggregateResult ar : [
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Event
            WHERE AccountId IN :accountIds AND CreatedDate = LAST_N_DAYS:90
            GROUP BY AccountId
        ]) {
            Id aid = (Id) ar.get('acc');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            recentActs.put(aid, (recentActs.containsKey(aid) ? recentActs.get(aid) : 0) + cnt);
        }

        for (Id gid : groupIds) {
            GroupRiskSummary grs = new GroupRiskSummary();
            grs.groupId = gid;
            grs.members = new List<MemberBusinessRecords>();
            List<Id> accIds = membersByGroup.get(gid);
            if (accIds != null) {
                for (Id aid : accIds) {
                    MemberBusinessRecords mr = new MemberBusinessRecords();
                    mr.accountId       = aid;
                    mr.openOpps        = openOpps.containsKey(aid)        ? openOpps.get(aid)        : 0;
                    mr.renewalOpps     = renewalOpps.containsKey(aid)     ? renewalOpps.get(aid)     : 0;
                    mr.activeContracts = activeContracts.containsKey(aid) ? activeContracts.get(aid) : 0;
                    mr.recentActivities = recentActs.containsKey(aid)     ? recentActs.get(aid)     : 0;
                    grs.members.add(mr);
                }
            }
            out.add(grs);
        }
        return out;
    }

    public class BulkCandidateMember {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountStatus;
        @AuraEnabled public String industry;
        @AuraEnabled public String website;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Boolean isCustomer;
        @AuraEnabled public Date lastActivityDate;
        @AuraEnabled public DateTime lastModifiedDate;
    }

    public class BulkCandidate {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public String matchKey;
        @AuraEnabled public String scenarioLabel;
        @AuraEnabled public Integer memberCount;
        @AuraEnabled public Id scanId;
        @AuraEnabled public Id suggestedMasterId;
        @AuraEnabled public List<BulkCandidateMember> members;
    }

    public class BulkCandidateResult {
        @AuraEnabled public Id scanId;
        @AuraEnabled public String scanName;
        @AuraEnabled public Integer totalOpenGroups;
        @AuraEnabled public Integer eligibleCount;
        @AuraEnabled public List<BulkCandidate> candidates;
    }

    /**
     * Returns groups eligible for unattended auto-merge:
     *  - Open status
     *  - No member carries open opps, open renewals, or active contracts
     *  - Customer mix matches the requested mode:
     *      'noCustomers' (default) → no member has Account_Status__c='Customer'
     *      'singleCustomer'        → exactly one member is a Customer; that
     *                                customer is the suggested master.
     *
     * If no scanId is provided, defaults to the most-recent completed scan.
     * scenarioFilter restricts to a single scenario key (e.g. 'exactWebsite');
     * blank means "all scenarios".
     */
    @AuraEnabled(cacheable=false)
    public static BulkCandidateResult getBulkMergeCandidates(Id scanId, String scenarioFilter, String customerMode, Integer maxResults) {
        BulkCandidateResult out = new BulkCandidateResult();
        out.candidates = new List<BulkCandidate>();
        out.totalOpenGroups = 0;
        out.eligibleCount = 0;

        Id targetScanId = scanId;
        if (targetScanId == null) {
            List<Dedupe_Scan__c> latest = [
                SELECT Id, Name FROM Dedupe_Scan__c
                WHERE Status__c = 'Completed'
                ORDER BY Completed_At__c DESC NULLS LAST, CreatedDate DESC
                LIMIT 1
            ];
            if (latest.isEmpty()) return out;
            targetScanId = latest[0].Id;
            out.scanName = latest[0].Name;
        } else {
            List<Dedupe_Scan__c> s = [SELECT Id, Name FROM Dedupe_Scan__c WHERE Id = :targetScanId LIMIT 1];
            if (!s.isEmpty()) out.scanName = s[0].Name;
        }
        out.scanId = targetScanId;

        Integer cap = (maxResults == null || maxResults <= 0) ? 100 : Math.min(maxResults, 500);

        String whereClause = 'Scan__c = :targetScanId AND Status__c = \'Open\'';
        if (String.isNotBlank(scenarioFilter)) {
            whereClause += ' AND Scenario_Key__c = :scenarioFilter';
        }
        out.totalOpenGroups = Database.countQuery('SELECT COUNT() FROM Dedupe_Group__c WHERE ' + whereClause);

        String soql = 'SELECT Id, Name, Match_Key__c, Scenario_Label__c, Member_Count__c '
                    + 'FROM Dedupe_Group__c WHERE ' + whereClause
                    + ' ORDER BY Member_Count__c DESC NULLS LAST LIMIT ' + cap;
        List<Dedupe_Group__c> openGroups = Database.query(soql);
        if (openGroups.isEmpty()) return out;

        Set<Id> groupIds = new Set<Id>();
        for (Dedupe_Group__c g : openGroups) groupIds.add(g.Id);

        Map<Id, List<Id>> memberAccountsByGroup = new Map<Id, List<Id>>();
        Set<Id> allAccountIds = new Set<Id>();
        for (Dedupe_Group_Member__c m : [
            SELECT Group__c, Account__c FROM Dedupe_Group_Member__c
            WHERE Group__c IN :groupIds AND Account__c != NULL
        ]) {
            if (!memberAccountsByGroup.containsKey(m.Group__c)) {
                memberAccountsByGroup.put(m.Group__c, new List<Id>());
            }
            memberAccountsByGroup.get(m.Group__c).add(m.Account__c);
            allAccountIds.add(m.Account__c);
        }
        if (allAccountIds.isEmpty()) return out;

        String mode = String.isBlank(customerMode) ? 'noCustomers' : customerMode;

        Map<Id, Account> accountsById = new Map<Id, Account>([
            SELECT Id, Name, Account_Status__c, Industry, Website, Owner.Name,
                   LastActivityDate, LastModifiedDate
            FROM Account WHERE Id IN :allAccountIds
        ]);

        // Critical-record counts across all candidate accounts (4 aggregates).
        Map<Id, Integer> openOpps = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :allAccountIds AND IsClosed = false
            GROUP BY AccountId
        ]);
        Map<Id, Integer> renewalOpps = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Opportunity
            WHERE AccountId IN :allAccountIds AND IsClosed = false AND Type = 'Renewal'
            GROUP BY AccountId
        ]);
        Map<Id, Integer> activeContracts = countByAccount([
            SELECT AccountId acc, COUNT(Id) cnt
            FROM Contract
            WHERE AccountId IN :allAccountIds AND Status = 'Activated'
            GROUP BY AccountId
        ]);

        for (Dedupe_Group__c g : openGroups) {
            List<Id> accIds = memberAccountsByGroup.get(g.Id);
            if (accIds == null || accIds.size() < 2) continue;

            // Count customers and detect any business-record disqualifier.
            Boolean disqualified = false;
            Integer customerCount = 0;
            Id customerId;
            for (Id aid : accIds) {
                Account a = accountsById.get(aid);
                if (a == null) { disqualified = true; break; }
                Boolean isCustomer = a.Account_Status__c != null
                    && a.Account_Status__c.equalsIgnoreCase('Customer');
                if (isCustomer) {
                    customerCount += 1;
                    customerId = aid;
                }
                if ((openOpps.containsKey(aid) ? openOpps.get(aid) : 0) > 0) { disqualified = true; break; }
                if ((renewalOpps.containsKey(aid) ? renewalOpps.get(aid) : 0) > 0) { disqualified = true; break; }
                if ((activeContracts.containsKey(aid) ? activeContracts.get(aid) : 0) > 0) { disqualified = true; break; }
            }
            if (disqualified) continue;

            if (mode == 'singleCustomer') {
                if (customerCount != 1) continue;
            } else {
                // noCustomers — skip any group with even one customer.
                if (customerCount > 0) continue;
            }

            // Suggested master:
            //  - single-customer mode → the customer (preserve their data)
            //  - otherwise → highest LastActivityDate (else LastModifiedDate)
            Id suggested;
            if (mode == 'singleCustomer' && customerId != null) {
                suggested = customerId;
            } else {
                suggested = accIds[0];
                DateTime bestScore;
                for (Id aid : accIds) {
                    Account a = accountsById.get(aid);
                    if (a == null) continue;
                    DateTime score = a.LastActivityDate != null
                        ? DateTime.newInstance(a.LastActivityDate.year(), a.LastActivityDate.month(), a.LastActivityDate.day())
                        : a.LastModifiedDate;
                    if (score != null && (bestScore == null || score > bestScore)) {
                        bestScore = score;
                        suggested = aid;
                    }
                }
            }

            BulkCandidate bc = new BulkCandidate();
            bc.groupId = g.Id;
            bc.groupName = g.Name;
            bc.matchKey = g.Match_Key__c;
            bc.scenarioLabel = g.Scenario_Label__c;
            bc.memberCount = g.Member_Count__c == null ? 0 : g.Member_Count__c.intValue();
            bc.scanId = targetScanId;
            bc.suggestedMasterId = suggested;
            bc.members = new List<BulkCandidateMember>();
            for (Id aid : accIds) {
                Account a = accountsById.get(aid);
                if (a == null) continue;
                BulkCandidateMember bm = new BulkCandidateMember();
                bm.accountId = aid;
                bm.accountName = a.Name;
                bm.accountStatus = a.Account_Status__c;
                bm.industry = a.Industry;
                bm.website = a.Website;
                bm.ownerName = a.Owner != null ? a.Owner.Name : null;
                bm.isCustomer = a.Account_Status__c != null
                    && a.Account_Status__c.equalsIgnoreCase('Customer');
                bm.lastActivityDate = a.LastActivityDate;
                bm.lastModifiedDate = a.LastModifiedDate;
                bc.members.add(bm);
            }
            out.candidates.add(bc);
        }
        out.eligibleCount = out.candidates.size();
        return out;
    }

    public class RecentResult {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public String matchKey;
        @AuraEnabled public String scenarioLabel;
        @AuraEnabled public Integer memberCount;
        @AuraEnabled public String status;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public DateTime lastModifiedDate;
    }

    /**
     * Returns all non-Open groups for the given scan (or the latest completed
     * scan), ordered by LastModifiedDate DESC. Used by the bulk merge UI to
     * show outcomes after queueing without requiring the user to leave the page.
     */
    @AuraEnabled(cacheable=false)
    public static List<RecentResult> getRecentlyProcessed(Id scanId, Integer maxResults) {
        Integer cap = (maxResults == null || maxResults <= 0) ? 100 : Math.min(maxResults, 500);

        Id targetScanId = scanId;
        if (targetScanId == null) {
            List<Dedupe_Scan__c> latest = [
                SELECT Id FROM Dedupe_Scan__c
                WHERE Status__c = 'Completed'
                ORDER BY Completed_At__c DESC NULLS LAST, CreatedDate DESC
                LIMIT 1
            ];
            if (latest.isEmpty()) return new List<RecentResult>();
            targetScanId = latest[0].Id;
        }

        List<RecentResult> out = new List<RecentResult>();
        for (Dedupe_Group__c g : [
            SELECT Id, Name, Match_Key__c, Scenario_Label__c, Member_Count__c,
                   Status__c, Error_Message__c, LastModifiedDate
            FROM Dedupe_Group__c
            WHERE Scan__c = :targetScanId
              AND Status__c != 'Open'
            ORDER BY LastModifiedDate DESC NULLS LAST
            LIMIT :cap
        ]) {
            RecentResult r = new RecentResult();
            r.groupId = g.Id;
            r.groupName = g.Name;
            r.matchKey = g.Match_Key__c;
            r.scenarioLabel = g.Scenario_Label__c;
            r.memberCount = g.Member_Count__c == null ? 0 : g.Member_Count__c.intValue();
            r.status = g.Status__c;
            r.errorMessage = g.Error_Message__c;
            r.lastModifiedDate = g.LastModifiedDate;
            out.add(r);
        }
        return out;
    }

    private static Map<Id, Integer> countByAccount(List<AggregateResult> rows) {
        Map<Id, Integer> m = new Map<Id, Integer>();
        for (AggregateResult ar : rows) {
            m.put((Id) ar.get('acc'), ((Decimal) ar.get('cnt')).intValue());
        }
        return m;
    }
}
