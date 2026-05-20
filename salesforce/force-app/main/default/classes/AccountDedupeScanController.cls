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

            Database.executeBatch(new AccountDedupeScanBatch(scan.Id, cleaned), 1);
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
}
