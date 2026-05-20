public with sharing class AccountDedupeService {

    public static final List<String> COMPARE_FIELDS = new List<String>{
        'Name',
        'Website',
        'LinkedIn_URL__c',
        'Normalized_Domain__c',
        'Domain_Root__c',
        'Phone',
        'Industry',
        'AnnualRevenue',
        'NumberOfEmployees',
        'BillingStreet',
        'BillingCity',
        'BillingState',
        'BillingPostalCode',
        'BillingCountry',
        'Description'
    };

    private static final List<String> READ_ONLY_FIELDS = new List<String>{
        'OwnerId',
        'CreatedDate',
        'LastModifiedDate'
    };

    private static final Integer MAX_CANDIDATES = 200;
    private static final Integer FUZZY_ABSOLUTE_THRESHOLD = 2;
    private static final Decimal FUZZY_RATIO_THRESHOLD = 0.2;

    public class FieldMeta {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean updateable;
    }

    public class ScenarioResult {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String description;
        @AuraEnabled public List<Id> matchIds = new List<Id>();
    }

    public class DedupeResult {
        @AuraEnabled public Id sourceId;
        @AuraEnabled public List<FieldMeta> fields;
        @AuraEnabled public List<ScenarioResult> scenarios;
        @AuraEnabled public Map<Id, Map<String, Object>> records;
    }

    public static DedupeResult findDuplicates(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('Account Id is required.');
        }

        Account source = querySingleAccount(accountId);

        Set<Id> candidateIds = new Set<Id>();
        candidateIds.addAll(candidatesByExactField('Website', source.Website));
        candidateIds.addAll(candidatesByExactField('LinkedIn_URL__c', source.LinkedIn_URL__c));
        candidateIds.addAll(candidatesByExactField('Normalized_Domain__c', source.Normalized_Domain__c));
        candidateIds.addAll(candidatesByExactField('Domain_Root__c', source.Domain_Root__c));
        candidateIds.remove(accountId);

        Map<Id, Account> candidates = new Map<Id, Account>();
        if (!candidateIds.isEmpty()) {
            for (Account a : queryAccounts(candidateIds)) {
                candidates.put(a.Id, a);
            }
        }

        List<ScenarioResult> scenarios = new List<ScenarioResult>{
            buildScenario('exactWebsite', 'Exact Website',
                'Same Website (host comparison, ignoring protocol/www/trailing slash).',
                matchesExactWebsite(source, candidates.values())),
            buildScenario('exactLinkedIn', 'Exact LinkedIn URL',
                'Same LinkedIn_URL__c value (normalized).',
                matchesExactLinkedIn(source, candidates.values())),
            buildScenario('nameNormalizedDomain', 'Name + Normalized Domain',
                'Exact normalized name match (suffixes like Inc/LLC/Corp stripped) AND same Normalized_Domain__c. High precision.',
                matchesNameAndField(source, candidates.values(), 'Normalized_Domain__c')),
            buildScenario('nameDomainRoot', 'Name + Domain Root',
                'Exact normalized name match AND same Domain_Root__c. High precision.',
                matchesNameAndField(source, candidates.values(), 'Domain_Root__c')),
            buildScenario('fuzzyNameDomainRoot', 'Similar Name + Domain Root',
                'Same Domain_Root__c with a fuzzy name match: shared significant token OR Levenshtein typo distance. Catches regional offices like "Oaklins Denmark" vs "Oaklins Italy".',
                matchesFuzzyNameDomainRoot(source, candidates.values()))
        };

        Set<Id> referencedIds = new Set<Id>{ accountId };
        for (ScenarioResult s : scenarios) {
            referencedIds.addAll(s.matchIds);
        }

        DedupeResult result = new DedupeResult();
        result.sourceId = accountId;
        result.fields = buildFieldMeta();
        result.scenarios = scenarios;
        result.records = new Map<Id, Map<String, Object>>();
        result.records.put(accountId, accountToMap(source));
        for (Id id : referencedIds) {
            if (id != accountId && candidates.containsKey(id)) {
                result.records.put(id, accountToMap(candidates.get(id)));
            }
        }
        return result;
    }

    public static void mergeAccounts(Id masterId, List<Id> duplicateIds, Map<String, Id> fieldSourceMap) {
        if (masterId == null || duplicateIds == null || duplicateIds.isEmpty()) {
            throw new AuraHandledException('Master Id and at least one duplicate Id are required.');
        }
        if (duplicateIds.contains(masterId)) {
            throw new AuraHandledException('Master cannot also be in the duplicates list.');
        }

        // Build a minimal master sObject (Id + any cherry-picked field values).
        // We deliberately do NOT carry audit fields (CreatedDate, LastModifiedDate,
        // OwnerId) onto the record we hand to merge — those would be rejected
        // with INVALID_FIELD_FOR_INSERT_UPDATE since merge applies the master
        // sObject's field values as an update.
        Account master = new Account(Id = masterId);
        applyCherryPickValues(master, masterId, fieldSourceMap);

        // Apex merge accepts List<ID> for the duplicates argument, capped at 2 per call.
        List<Id> chunk = new List<Id>();
        for (Id dupId : duplicateIds) {
            if (dupId == null || dupId == masterId) continue;
            chunk.add(dupId);
            if (chunk.size() == 2) {
                merge master chunk;
                chunk = new List<Id>();
            }
        }
        if (!chunk.isEmpty()) {
            merge master chunk;
        }
    }

    private static void applyCherryPickValues(Account master, Id masterId, Map<String, Id> fieldSourceMap) {
        if (fieldSourceMap == null || fieldSourceMap.isEmpty()) return;

        Set<String> updateableFields = updateableFieldNames();
        Set<Id> sourceIds = new Set<Id>();
        List<String> fields = new List<String>();
        for (String f : fieldSourceMap.keySet()) {
            if (!updateableFields.contains(f)) continue;
            Id sid = fieldSourceMap.get(f);
            if (sid == null || sid == masterId) continue;
            sourceIds.add(sid);
            fields.add(f);
        }
        if (sourceIds.isEmpty() || fields.isEmpty()) return;

        String soql = 'SELECT Id, ' + String.join(fields, ', ') + ' FROM Account WHERE Id IN :sourceIds';
        Map<Id, Account> sources = new Map<Id, Account>((List<Account>) Database.query(soql));

        for (String f : fields) {
            Id sid = fieldSourceMap.get(f);
            if (sid == null || !sources.containsKey(sid)) continue;
            master.put(f, sources.get(sid).get(f));
        }
    }

    // ---------- queries ----------

    private static Account querySingleAccount(Id accountId) {
        List<Account> results = queryAccounts(new Set<Id>{ accountId });
        if (results.isEmpty()) {
            throw new AuraHandledException('Account not found or not accessible.');
        }
        return results[0];
    }

    private static List<Account> queryAccounts(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return new List<Account>();
        String fieldList = String.join(allReadFields(), ', ');
        String soql = 'SELECT Id, ' + fieldList + ' FROM Account WHERE Id IN :ids LIMIT ' + MAX_CANDIDATES;
        return Database.query(soql);
    }

    private static List<Id> candidatesByExactField(String fieldName, String value) {
        List<Id> ids = new List<Id>();
        if (String.isBlank(value)) return ids;
        String normalized = (fieldName == 'Website' || fieldName == 'LinkedIn_URL__c')
            ? normalizeUrl(value)
            : value;
        if (String.isBlank(normalized)) return ids;
        String soql = 'SELECT Id FROM Account WHERE ' + fieldName + ' != NULL AND ' + fieldName + ' = :normalized LIMIT ' + MAX_CANDIDATES;
        for (Account a : Database.query(soql)) {
            ids.add(a.Id);
        }
        return ids;
    }

    // ---------- scenario matchers ----------

    private static List<Id> matchesExactWebsite(Account source, List<Account> candidates) {
        List<Id> hits = new List<Id>();
        String sw = normalizeUrl(source.Website);
        if (String.isBlank(sw)) return hits;
        for (Account a : candidates) {
            if (normalizeUrl(a.Website) == sw) hits.add(a.Id);
        }
        return hits;
    }

    private static List<Id> matchesExactLinkedIn(Account source, List<Account> candidates) {
        List<Id> hits = new List<Id>();
        String sl = normalizeUrl(source.LinkedIn_URL__c);
        if (String.isBlank(sl)) return hits;
        for (Account a : candidates) {
            if (normalizeUrl(a.LinkedIn_URL__c) == sl) hits.add(a.Id);
        }
        return hits;
    }

    private static List<Id> matchesNameAndField(Account source, List<Account> candidates, String fieldName) {
        List<Id> hits = new List<Id>();
        String srcName = normalizeName(source.Name);
        Object srcField = source.get(fieldName);
        if (String.isBlank(srcName) || srcField == null || String.isBlank(String.valueOf(srcField))) return hits;
        for (Account a : candidates) {
            Object cmp = a.get(fieldName);
            if (cmp == null) continue;
            if (String.valueOf(cmp) == String.valueOf(srcField) && normalizeName(a.Name) == srcName) {
                hits.add(a.Id);
            }
        }
        return hits;
    }

    private static List<Id> matchesFuzzyNameDomainRoot(Account source, List<Account> candidates) {
        List<Id> hits = new List<Id>();
        if (String.isBlank(source.Domain_Root__c) || String.isBlank(source.Name)) return hits;
        String srcName = normalizeName(source.Name);
        Set<String> srcTokens = significantTokens(srcName);
        for (Account a : candidates) {
            if (a.Domain_Root__c != source.Domain_Root__c) continue;
            String cmp = normalizeName(a.Name);
            if (String.isBlank(cmp)) continue;
            if (cmp == srcName) {
                hits.add(a.Id);
                continue;
            }
            // Token overlap: share at least one significant token (length >= 3).
            // Catches "Oaklins Denmark" vs "Oaklins Italy" where Levenshtein
            // distance between the suffix words is too large to help.
            Set<String> cmpTokens = significantTokens(cmp);
            if (!cmpTokens.isEmpty() && !srcTokens.isEmpty()) {
                Set<String> shared = new Set<String>(srcTokens);
                shared.retainAll(cmpTokens);
                if (!shared.isEmpty()) {
                    hits.add(a.Id);
                    continue;
                }
            }
            // Typo-style fuzzy fallback.
            Integer dist = levenshtein(srcName, cmp);
            Integer maxLen = Math.max(srcName.length(), cmp.length());
            Integer threshold = Math.max(FUZZY_ABSOLUTE_THRESHOLD, (Integer)Math.floor(maxLen * FUZZY_RATIO_THRESHOLD));
            if (dist <= threshold) hits.add(a.Id);
        }
        return hits;
    }

    @TestVisible
    private static Set<String> significantTokens(String normalizedName) {
        Set<String> out = new Set<String>();
        if (String.isBlank(normalizedName)) return out;
        for (String t : normalizedName.split(' ')) {
            if (String.isBlank(t)) continue;
            if (t.length() < 3) continue;
            out.add(t);
        }
        return out;
    }

    // ---------- normalization ----------

    @TestVisible
    private static String normalizeUrl(String url) {
        if (String.isBlank(url)) return null;
        String s = url.trim().toLowerCase();
        s = s.replaceFirst('^https?://', '');
        s = s.replaceFirst('^www\\.', '');
        s = s.replaceFirst('/+$', '');
        return s;
    }

    @TestVisible
    private static String normalizeName(String name) {
        if (String.isBlank(name)) return null;
        String s = name.toLowerCase();
        s = s.replaceAll('[\\.,&\\-_/]', ' ');
        s = s.replaceAll('\\b(inc|incorporated|llc|ltd|limited|corp|corporation|company|co|gmbh|sa|plc|holdings|group|holding)\\b', '');
        s = s.replaceAll('[^a-z0-9 ]', '');
        s = s.replaceAll('\\s+', ' ').trim();
        return s;
    }

    @TestVisible
    private static Integer levenshtein(String a, String b) {
        if (a == null) a = '';
        if (b == null) b = '';
        Integer m = a.length();
        Integer n = b.length();
        if (m == 0) return n;
        if (n == 0) return m;
        List<Integer> prev = new List<Integer>();
        for (Integer i = 0; i <= n; i++) prev.add(i);
        for (Integer i = 1; i <= m; i++) {
            List<Integer> curr = new List<Integer>{ i };
            for (Integer j = 1; j <= n; j++) {
                Integer cost = (a.substring(i - 1, i) == b.substring(j - 1, j)) ? 0 : 1;
                Integer val = Math.min(
                    Math.min(curr[j - 1] + 1, prev[j] + 1),
                    prev[j - 1] + cost
                );
                curr.add(val);
            }
            prev = curr;
        }
        return prev[n];
    }

    // ---------- helpers ----------

    private static ScenarioResult buildScenario(String key, String label, String description, List<Id> matchIds) {
        ScenarioResult r = new ScenarioResult();
        r.key = key;
        r.label = label;
        r.description = description;
        r.matchIds = matchIds;
        return r;
    }

    private static List<String> allReadFields() {
        List<String> out = new List<String>();
        out.addAll(COMPARE_FIELDS);
        out.addAll(READ_ONLY_FIELDS);
        out.add('Owner.Name');
        return out;
    }

    private static Set<String> updateableFieldNames() {
        Set<String> out = new Set<String>();
        Map<String, Schema.SObjectField> fmap = Account.SObjectType.getDescribe().fields.getMap();
        for (String f : COMPARE_FIELDS) {
            Schema.SObjectField token = fmap.get(f.toLowerCase());
            if (token != null && token.getDescribe().isUpdateable()) {
                out.add(f);
            }
        }
        return out;
    }

    private static List<FieldMeta> buildFieldMeta() {
        List<FieldMeta> out = new List<FieldMeta>();
        Map<String, Schema.SObjectField> fmap = Account.SObjectType.getDescribe().fields.getMap();
        for (String f : COMPARE_FIELDS) {
            Schema.SObjectField token = fmap.get(f.toLowerCase());
            if (token == null) continue;
            Schema.DescribeFieldResult d = token.getDescribe();
            FieldMeta m = new FieldMeta();
            m.apiName = d.getName();
            m.label = d.getLabel();
            m.type = String.valueOf(d.getType());
            m.updateable = d.isUpdateable();
            out.add(m);
        }
        for (String f : READ_ONLY_FIELDS) {
            Schema.SObjectField token = fmap.get(f.toLowerCase());
            if (token == null) continue;
            Schema.DescribeFieldResult d = token.getDescribe();
            FieldMeta m = new FieldMeta();
            m.apiName = d.getName();
            m.label = d.getLabel();
            m.type = String.valueOf(d.getType());
            m.updateable = false;
            out.add(m);
        }
        FieldMeta ownerNameMeta = new FieldMeta();
        ownerNameMeta.apiName = 'OwnerName';
        ownerNameMeta.label = 'Owner';
        ownerNameMeta.type = 'STRING';
        ownerNameMeta.updateable = false;
        out.add(ownerNameMeta);
        return out;
    }

    private static Map<String, Object> accountToMap(Account a) {
        Map<String, Object> m = new Map<String, Object>();
        m.put('Id', a.Id);
        for (String f : COMPARE_FIELDS) {
            m.put(f, a.get(f));
        }
        for (String f : READ_ONLY_FIELDS) {
            m.put(f, a.get(f));
        }
        m.put('OwnerName', a.Owner != null ? a.Owner.Name : null);
        return m;
    }
}
