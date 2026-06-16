public with sharing class AccountDedupeScanService {

    public static final Integer MAX_BUCKET_SIZE = 1000;
    public static final Integer MAX_GROUPS_PER_SCENARIO = 5000;

    // Apex heap limit for async: 12 MB. Fetching ~18K accounts with a few fields
    // (~200 bytes each) uses ~3.6 MB — well within limit.
    private static final Integer FETCH_LIMIT = 50000;

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

    // ── exactWebsite ────────────────────────────────────────────────────────

    private static List<GroupDraft> scanExactWebsite() {
        // Prefer Normalized_Domain__c when populated; fall back to normalizing Website in-memory.
        Map<String, List<Id>> buckets = new Map<String, List<Id>>();
        for (Account a : [
            SELECT Id, Website, Normalized_Domain__c
            FROM Account
            WHERE Website != NULL
            LIMIT :FETCH_LIMIT
        ]) {
            String key = String.isNotBlank(a.Normalized_Domain__c)
                ? a.Normalized_Domain__c
                : normalizeUrl(a.Website);
            if (String.isBlank(key)) continue;
            if (!buckets.containsKey(key)) buckets.put(key, new List<Id>());
            buckets.get(key).add(a.Id);
        }
        return draftsFromBuckets(buckets, 'exactWebsite');
    }

    // ── exactLinkedIn ────────────────────────────────────────────────────────

    private static List<GroupDraft> scanExactLinkedIn() {
        Map<String, List<Id>> buckets = new Map<String, List<Id>>();
        for (Account a : [
            SELECT Id, LinkedIn_URL__c
            FROM Account
            WHERE LinkedIn_URL__c != NULL
            LIMIT :FETCH_LIMIT
        ]) {
            String key = normalizeUrl(a.LinkedIn_URL__c);
            if (String.isBlank(key)) continue;
            if (!buckets.containsKey(key)) buckets.put(key, new List<Id>());
            buckets.get(key).add(a.Id);
        }
        return draftsFromBuckets(buckets, 'exactLinkedIn');
    }

    // ── nameNormalizedDomain / nameDomainRoot ────────────────────────────────

    private static List<GroupDraft> scanNameAndField(String fieldName, String scenarioKey) {
        String soql = 'SELECT Id, Name, ' + fieldName + ' FROM Account '
                    + 'WHERE ' + fieldName + ' != NULL AND Name != NULL '
                    + 'LIMIT ' + FETCH_LIMIT;
        List<Account> accts = Database.query(soql);

        // Two-level bucket: fieldValue -> normalizedName -> ids.
        // Using two levels avoids splitting on spaces in normalized names.
        Map<String, Map<String, List<Id>>> byField = new Map<String, Map<String, List<Id>>>();
        for (Account a : accts) {
            String fieldVal = (String) a.get(fieldName);
            if (String.isBlank(fieldVal)) continue;
            String normName = normalizeName(a.Name);
            if (String.isBlank(normName)) continue;
            if (!byField.containsKey(fieldVal)) byField.put(fieldVal, new Map<String, List<Id>>());
            Map<String, List<Id>> byName = byField.get(fieldVal);
            if (!byName.containsKey(normName)) byName.put(normName, new List<Id>());
            byName.get(normName).add(a.Id);
        }

        List<GroupDraft> out = new List<GroupDraft>();
        for (String fieldVal : byField.keySet()) {
            for (String normName : byField.get(fieldVal).keySet()) {
                List<Id> ids = byField.get(fieldVal).get(normName);
                if (ids.size() < 2) continue;
                GroupDraft g = new GroupDraft();
                g.scenarioKey   = scenarioKey;
                g.scenarioLabel = SCENARIO_LABELS.get(scenarioKey);
                g.matchKey      = (normName + ' @ ' + fieldVal).left(255);
                g.accountIds    = ids;
                out.add(g);
                if (out.size() >= MAX_GROUPS_PER_SCENARIO) return out;
            }
        }
        return out;
    }

    // ── fuzzyNameDomainRoot ──────────────────────────────────────────────────

    private static List<GroupDraft> scanFuzzyNameDomainRoot() {
        Map<String, List<Account>> byDomain = new Map<String, List<Account>>();
        for (Account a : [
            SELECT Id, Name, Domain_Root__c
            FROM Account
            WHERE Domain_Root__c != NULL AND Name != NULL
            LIMIT :FETCH_LIMIT
        ]) {
            String dr = a.Domain_Root__c;
            if (!byDomain.containsKey(dr)) byDomain.put(dr, new List<Account>());
            byDomain.get(dr).add(a);
        }

        List<GroupDraft> out = new List<GroupDraft>();
        for (String dr : byDomain.keySet()) {
            List<Account> accts = byDomain.get(dr);
            if (accts.size() < 2) continue;
            if (accts.size() > MAX_BUCKET_SIZE) continue;

            List<List<Id>> clusters = clusterByName(accts);
            for (List<Id> ids : clusters) {
                if (ids.size() < 2) continue;
                GroupDraft g = new GroupDraft();
                g.scenarioKey   = 'fuzzyNameDomainRoot';
                g.scenarioLabel = SCENARIO_LABELS.get('fuzzyNameDomainRoot');
                g.matchKey      = dr;
                g.accountIds    = ids;
                out.add(g);
                if (out.size() >= MAX_GROUPS_PER_SCENARIO) return out;
            }
        }
        return out;
    }

    // ── shared helpers ───────────────────────────────────────────────────────

    private static List<GroupDraft> draftsFromBuckets(Map<String, List<Id>> buckets, String scenarioKey) {
        List<GroupDraft> out = new List<GroupDraft>();
        for (String key : buckets.keySet()) {
            List<Id> ids = buckets.get(key);
            if (ids.size() < 2) continue;
            if (ids.size() > MAX_BUCKET_SIZE) continue;
            GroupDraft g = new GroupDraft();
            g.scenarioKey   = scenarioKey;
            g.scenarioLabel = SCENARIO_LABELS.get(scenarioKey);
            g.matchKey      = key.left(255);
            g.accountIds    = ids;
            out.add(g);
            if (out.size() >= MAX_GROUPS_PER_SCENARIO) break;
        }
        return out;
    }

    // ── union-find clustering ────────────────────────────────────────────────

    private static List<List<Id>> clusterByName(List<Account> accts) {
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

    // ── persist / resolve ────────────────────────────────────────────────────

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
        // Include 'Processing' so the queue drainer's in-flight groups also
        // get auto-resolved on a successful merge — without this, drainer
        // merges complete but the group stays stuck in Processing.
        Set<String> openStatuses = new Set<String>{ 'Open', 'Processing' };
        for (Dedupe_Group_Member__c m : [
            SELECT Group__c FROM Dedupe_Group_Member__c
            WHERE Account__c IN :accountIds AND Group__r.Status__c IN :openStatuses
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
