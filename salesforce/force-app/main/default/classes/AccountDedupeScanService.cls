public with sharing class AccountDedupeScanService {

    public static final Integer MAX_BUCKET_SIZE = 1000;
    public static final Integer MAX_GROUPS_PER_SCENARIO = 5000;

    public static final Map<String, String> SCENARIO_LABELS = new Map<String, String>{
        'exactWebsite'         => 'Exact Website',
        'exactLinkedIn'        => 'Exact LinkedIn URL',
        'nameNormalizedDomain' => 'Name + Normalized Domain',
        'nameDomainRoot'       => 'Name + Domain Root',
        'fuzzyNameDomainRoot'  => 'Similar Name + Domain Root'
    };

    public class GroupDraft {
        public String scenarioKey;
        public String scenarioLabel;
        public String matchKey;
        public List<Id> accountIds;
    }

    public static List<GroupDraft> runScenario(String scenarioKey) {
        if (scenarioKey == 'exactWebsite')         return scanExactWebsite();
        if (scenarioKey == 'exactLinkedIn')        return scanExactLinkedIn();
        if (scenarioKey == 'nameNormalizedDomain') return scanNameAndField('Normalized_Domain__c', 'nameNormalizedDomain');
        if (scenarioKey == 'nameDomainRoot')       return scanNameAndField('Domain_Root__c', 'nameDomainRoot');
        if (scenarioKey == 'fuzzyNameDomainRoot')  return scanFuzzyNameDomainRoot();
        return new List<GroupDraft>();
    }

    private static List<GroupDraft> scanExactWebsite() {
        // Use Normalized_Domain__c — the AccountDomainTrigger already normalizes Website into it.
        return groupByExactField('Normalized_Domain__c', 'exactWebsite');
    }

    private static List<GroupDraft> scanExactLinkedIn() {
        // No normalized variant stored — normalize in-memory after collecting buckets.
        List<GroupDraft> out = new List<GroupDraft>();
        for (AggregateResult ar : [
            SELECT LinkedIn_URL__c key, COUNT(Id) cnt
            FROM Account
            WHERE LinkedIn_URL__c != NULL
            GROUP BY LinkedIn_URL__c
            HAVING COUNT(Id) > 1
            LIMIT :MAX_GROUPS_PER_SCENARIO
        ]) {
            String raw = (String) ar.get('key');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            if (cnt > MAX_BUCKET_SIZE) continue;
            String normalized = normalizeUrl(raw);
            if (String.isBlank(normalized)) continue;

            List<Id> ids = new List<Id>();
            for (Account a : [SELECT Id FROM Account WHERE LinkedIn_URL__c = :raw LIMIT :MAX_BUCKET_SIZE]) {
                ids.add(a.Id);
            }
            if (ids.size() < 2) continue;

            GroupDraft g = new GroupDraft();
            g.scenarioKey = 'exactLinkedIn';
            g.scenarioLabel = SCENARIO_LABELS.get('exactLinkedIn');
            g.matchKey = normalized;
            g.accountIds = ids;
            out.add(g);
        }
        return out;
    }

    private static List<GroupDraft> groupByExactField(String fieldName, String scenarioKey) {
        List<GroupDraft> out = new List<GroupDraft>();
        String soql =
            'SELECT ' + fieldName + ' key, COUNT(Id) cnt FROM Account ' +
            'WHERE ' + fieldName + ' != NULL ' +
            'GROUP BY ' + fieldName + ' ' +
            'HAVING COUNT(Id) > 1 ' +
            'LIMIT ' + MAX_GROUPS_PER_SCENARIO;
        for (AggregateResult ar : (List<AggregateResult>) Database.query(soql)) {
            String key = (String) ar.get('key');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            if (cnt > MAX_BUCKET_SIZE) continue;

            String idQuery = 'SELECT Id FROM Account WHERE ' + fieldName + ' = :key LIMIT ' + MAX_BUCKET_SIZE;
            List<Id> ids = new List<Id>();
            for (Account a : (List<Account>) Database.query(idQuery)) {
                ids.add(a.Id);
            }
            if (ids.size() < 2) continue;

            GroupDraft g = new GroupDraft();
            g.scenarioKey = scenarioKey;
            g.scenarioLabel = SCENARIO_LABELS.get(scenarioKey);
            g.matchKey = key;
            g.accountIds = ids;
            out.add(g);
        }
        return out;
    }

    private static List<GroupDraft> scanNameAndField(String fieldName, String scenarioKey) {
        // For each bucket of accounts sharing fieldName, sub-group by normalized name.
        List<GroupDraft> out = new List<GroupDraft>();
        String soql =
            'SELECT ' + fieldName + ' key, COUNT(Id) cnt FROM Account ' +
            'WHERE ' + fieldName + ' != NULL ' +
            'GROUP BY ' + fieldName + ' ' +
            'HAVING COUNT(Id) > 1 ' +
            'LIMIT ' + MAX_GROUPS_PER_SCENARIO;
        for (AggregateResult ar : (List<AggregateResult>) Database.query(soql)) {
            String key = (String) ar.get('key');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            if (cnt > MAX_BUCKET_SIZE) continue;

            String idQuery = 'SELECT Id, Name FROM Account WHERE ' + fieldName + ' = :key LIMIT ' + MAX_BUCKET_SIZE;
            Map<String, List<Id>> byNormalizedName = new Map<String, List<Id>>();
            for (Account a : (List<Account>) Database.query(idQuery)) {
                String norm = normalizeName(a.Name);
                if (String.isBlank(norm)) continue;
                if (!byNormalizedName.containsKey(norm)) byNormalizedName.put(norm, new List<Id>());
                byNormalizedName.get(norm).add(a.Id);
            }
            for (String norm : byNormalizedName.keySet()) {
                List<Id> ids = byNormalizedName.get(norm);
                if (ids.size() < 2) continue;
                GroupDraft g = new GroupDraft();
                g.scenarioKey = scenarioKey;
                g.scenarioLabel = SCENARIO_LABELS.get(scenarioKey);
                g.matchKey = norm + ' @ ' + key;
                g.accountIds = ids;
                out.add(g);
                if (out.size() >= MAX_GROUPS_PER_SCENARIO) return out;
            }
        }
        return out;
    }

    private static List<GroupDraft> scanFuzzyNameDomainRoot() {
        // Bucket by Domain_Root__c, then within each bucket cluster accounts whose
        // normalized names share at least one significant token (length >= 3),
        // OR are within Levenshtein-typo distance.
        List<GroupDraft> out = new List<GroupDraft>();
        for (AggregateResult ar : [
            SELECT Domain_Root__c key, COUNT(Id) cnt
            FROM Account
            WHERE Domain_Root__c != NULL
            GROUP BY Domain_Root__c
            HAVING COUNT(Id) > 1
            LIMIT :MAX_GROUPS_PER_SCENARIO
        ]) {
            String dr = (String) ar.get('key');
            Integer cnt = ((Decimal) ar.get('cnt')).intValue();
            if (cnt > MAX_BUCKET_SIZE) continue;

            List<Account> accts = [
                SELECT Id, Name FROM Account
                WHERE Domain_Root__c = :dr
                LIMIT :MAX_BUCKET_SIZE
            ];
            List<List<Id>> clusters = clusterByName(accts);
            for (List<Id> ids : clusters) {
                if (ids.size() < 2) continue;
                GroupDraft g = new GroupDraft();
                g.scenarioKey = 'fuzzyNameDomainRoot';
                g.scenarioLabel = SCENARIO_LABELS.get('fuzzyNameDomainRoot');
                g.matchKey = dr;
                g.accountIds = ids;
                out.add(g);
                if (out.size() >= MAX_GROUPS_PER_SCENARIO) return out;
            }
        }
        return out;
    }

    private static List<List<Id>> clusterByName(List<Account> accts) {
        // Union-find: each account is its own cluster until linked by a similarity edge.
        Map<Id, Id> parent = new Map<Id, Id>();
        Map<Id, Set<String>> tokensByAccount = new Map<Id, Set<String>>();
        Map<Id, String> normByAccount = new Map<Id, String>();
        for (Account a : accts) {
            parent.put(a.Id, a.Id);
            String norm = normalizeName(a.Name);
            normByAccount.put(a.Id, norm == null ? '' : norm);
            tokensByAccount.put(a.Id, significantTokens(norm));
        }
        List<Id> ids = new List<Id>(parent.keySet());
        for (Integer i = 0; i < ids.size(); i++) {
            for (Integer j = i + 1; j < ids.size(); j++) {
                Id a = ids[i], b = ids[j];
                if (find(parent, a) == find(parent, b)) continue;
                if (similar(normByAccount.get(a), normByAccount.get(b),
                            tokensByAccount.get(a), tokensByAccount.get(b))) {
                    union(parent, a, b);
                }
            }
        }
        Map<Id, List<Id>> grouped = new Map<Id, List<Id>>();
        for (Id id : ids) {
            Id root = find(parent, id);
            if (!grouped.containsKey(root)) grouped.put(root, new List<Id>());
            grouped.get(root).add(id);
        }
        return grouped.values();
    }

    private static Id find(Map<Id, Id> parent, Id x) {
        Id p = parent.get(x);
        while (p != x) {
            x = p;
            p = parent.get(x);
        }
        return p;
    }

    private static void union(Map<Id, Id> parent, Id a, Id b) {
        Id ra = find(parent, a), rb = find(parent, b);
        if (ra != rb) parent.put(ra, rb);
    }

    private static Boolean similar(String n1, String n2, Set<String> t1, Set<String> t2) {
        if (String.isBlank(n1) || String.isBlank(n2)) return false;
        if (n1 == n2) return true;
        if (!t1.isEmpty() && !t2.isEmpty()) {
            Set<String> shared = new Set<String>(t1);
            shared.retainAll(t2);
            if (!shared.isEmpty()) return true;
        }
        Integer dist = AccountDedupeService.levenshtein(n1, n2);
        Integer maxLen = Math.max(n1.length(), n2.length());
        Integer threshold = Math.max(2, (Integer) Math.floor(maxLen * 0.2));
        return dist <= threshold;
    }

    private static String normalizeUrl(String url) {
        return AccountDedupeService.normalizeUrl(url);
    }

    private static String normalizeName(String name) {
        return AccountDedupeService.normalizeName(name);
    }

    private static Set<String> significantTokens(String normalizedName) {
        Set<String> out = new Set<String>();
        if (String.isBlank(normalizedName)) return out;
        for (String t : normalizedName.split(' ')) {
            if (String.isBlank(t) || t.length() < 3) continue;
            out.add(t);
        }
        return out;
    }

    public static void persistGroups(Id scanId, List<GroupDraft> drafts) {
        if (drafts == null || drafts.isEmpty()) return;
        List<Dedupe_Group__c> groups = new List<Dedupe_Group__c>();
        for (GroupDraft d : drafts) {
            Dedupe_Group__c g = new Dedupe_Group__c(
                Scan__c = scanId,
                Scenario_Key__c = d.scenarioKey,
                Scenario_Label__c = d.scenarioLabel,
                Match_Key__c = d.matchKey == null ? null : d.matchKey.left(255),
                Member_Count__c = d.accountIds.size(),
                Status__c = 'Open'
            );
            groups.add(g);
        }
        insert groups;

        List<Dedupe_Group_Member__c> members = new List<Dedupe_Group_Member__c>();
        for (Integer i = 0; i < drafts.size(); i++) {
            Id groupId = groups[i].Id;
            for (Id accountId : drafts[i].accountIds) {
                members.add(new Dedupe_Group_Member__c(Group__c = groupId, Account__c = accountId));
            }
        }
        if (!members.isEmpty()) insert members;
    }

    public static Set<Id> findOpenGroupsForAccounts(Set<Id> accountIds) {
        Set<Id> groupIds = new Set<Id>();
        if (accountIds == null || accountIds.isEmpty()) return groupIds;
        for (Dedupe_Group_Member__c m : [
            SELECT Group__c FROM Dedupe_Group_Member__c
            WHERE Account__c IN :accountIds AND Group__r.Status__c = 'Open'
            LIMIT 10000
        ]) {
            groupIds.add(m.Group__c);
        }
        return groupIds;
    }

    public static void resolveGroups(Set<Id> groupIds) {
        if (groupIds == null || groupIds.isEmpty()) return;
        List<Dedupe_Group__c> toUpdate = new List<Dedupe_Group__c>();
        for (Id gid : groupIds) {
            toUpdate.add(new Dedupe_Group__c(
                Id = gid,
                Status__c = 'Resolved',
                Resolved_At__c = System.now(),
                Resolved_By__c = UserInfo.getUserId()
            ));
        }
        update toUpdate;
    }
}
