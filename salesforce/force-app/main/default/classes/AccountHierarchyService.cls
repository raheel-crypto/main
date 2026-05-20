/**
 * Core logic for the Account Hierarchy widget:
 *   - clusters Accounts by normalized brand label (e.g. all Oaklins country offices)
 *   - asks Claude to propose a parent-child hierarchy with gap detection
 *   - applies the proposed ParentId changes
 *   - creates a missing ultimate-parent Account
 *
 * This class has no @AuraEnabled methods — it's pure logic so it can be reused
 * from controllers, schedulers, or tests without UI coupling.
 */
public with sharing class AccountHierarchyService {

    private static final Set<String> MULTI_PART_TLDS = new Set<String>{
        'co.uk','org.uk','ac.uk','gov.uk','ltd.uk','plc.uk',
        'com.au','net.au','org.au','edu.au','gov.au','id.au',
        'co.nz','net.nz','org.nz','govt.nz',
        'com.br','com.mx','com.ar','com.co','com.pe','com.cl',
        'com.sg','com.my','com.hk','com.tw','com.cn',
        'co.jp','or.jp','ne.jp','ac.jp','go.jp',
        'co.kr','or.kr',
        'co.in','co.za','co.il','co.ke','co.ug',
        'com.tr','com.sa','com.ua'
    };

    private static final Set<String> STRIP_SUBDOMAINS = new Set<String>{
        'www','m','en','us','uk','de','fr','es','it','nl','au','ca'
    };

    // ---------- DTOs ---------- //

    public class AccountInFamily {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String website;
        @AuraEnabled public String normalizedDomain;
        @AuraEnabled public String brandLabel;
        @AuraEnabled public String billingCountry;
        @AuraEnabled public String billingState;
        @AuraEnabled public String billingCity;
        @AuraEnabled public String linkedInUrl;
        @AuraEnabled public String industry;
        @AuraEnabled public String accountType;
        @AuraEnabled public String parentId;
        @AuraEnabled public String parentName;
    }

    public class AccountFamily {
        @AuraEnabled public String brandLabel;
        @AuraEnabled public String representativeName;
        @AuraEnabled public List<String> normalizedDomains;
        @AuraEnabled public List<String> billingCountries;
        @AuraEnabled public Integer accountCount;
        @AuraEnabled public Integer withParentCount;
        @AuraEnabled public List<AccountInFamily> accounts;
    }

    public class ScanResult {
        @AuraEnabled public List<AccountFamily> families;
        @AuraEnabled public String linkedInField;
        @AuraEnabled public Integer totalAccountsScanned;
    }

    public class HierarchyGap {
        @AuraEnabled public String gapId;
        @AuraEnabled public String proposedName;
        @AuraEnabled public String reason;
        @AuraEnabled public String suggestedWebsite;
        @AuraEnabled public String suggestedBillingCountry;
    }

    public class HierarchyNode {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String kind; // 'ultimate-parent' | 'regional-parent' | 'child' | 'gap'
        @AuraEnabled public String accountId;
        @AuraEnabled public String parentNodeId;
        @AuraEnabled public String currentParentId;
        @AuraEnabled public String proposedParentId; // Salesforce Id OR 'GAP:<gapId>'
        @AuraEnabled public String billingCountry;
        @AuraEnabled public String website;
        @AuraEnabled public String rationale;
        @AuraEnabled public Boolean isChange;
    }

    public class HierarchyProposal {
        @AuraEnabled public AccountFamily family;
        @AuraEnabled public String summary;
        @AuraEnabled public Boolean hasUltimateParent;
        @AuraEnabled public String ultimateParentNodeId;
        @AuraEnabled public List<HierarchyNode> nodes;
        @AuraEnabled public List<HierarchyGap> gaps;
        @AuraEnabled public List<String> warnings;
    }

    public class HierarchyChange {
        @AuraEnabled public String accountId;
        @AuraEnabled public String newParentId;
    }

    public class ApplyFailure {
        @AuraEnabled public String accountId;
        @AuraEnabled public String errorMessage;
    }

    public class ApplyResult {
        @AuraEnabled public List<HierarchyChange> applied;
        @AuraEnabled public List<ApplyFailure> failed;
    }

    // ---------- Domain normalization ---------- //

    @TestVisible
    private class Normalized {
        public String domain;
        public String brand;
    }

    @TestVisible
    private static Normalized normalizeWebsite(String raw) {
        if (String.isBlank(raw)) return null;
        String u = raw.trim().toLowerCase();
        // strip protocol
        if (u.startsWith('http://')) u = u.substring(7);
        else if (u.startsWith('https://')) u = u.substring(8);
        if (u.startsWith('//')) u = u.substring(2);
        // strip path/query/fragment
        Integer slash = u.indexOf('/');
        if (slash >= 0) u = u.substring(0, slash);
        Integer q = u.indexOf('?');
        if (q >= 0) u = u.substring(0, q);
        Integer h = u.indexOf('#');
        if (h >= 0) u = u.substring(0, h);
        // strip port
        Integer colon = u.indexOf(':');
        if (colon >= 0) u = u.substring(0, colon);

        if (String.isBlank(u) || !u.contains('.')) return null;

        List<String> parts = new List<String>();
        for (String p : u.split('\\.')) {
            if (String.isNotBlank(p)) parts.add(p);
        }
        if (parts.size() < 2) return null;

        // Drop common geo/language subdomains.
        while (parts.size() > 2 && STRIP_SUBDOMAINS.contains(parts[0])) {
            parts.remove(0);
        }

        Integer sz = parts.size();
        List<String> registeredParts;
        String lastTwo = parts[sz-2] + '.' + parts[sz-1];
        if (sz >= 3 && MULTI_PART_TLDS.contains(lastTwo)) {
            registeredParts = new List<String>{ parts[sz-3], parts[sz-2], parts[sz-1] };
        } else {
            registeredParts = new List<String>{ parts[sz-2], parts[sz-1] };
        }

        Normalized n = new Normalized();
        n.brand = registeredParts[0];
        if (String.isBlank(n.brand) || n.brand.length() < 2) return null;
        n.domain = String.join(registeredParts, '.');
        return n;
    }

    @TestVisible
    private static String detectLinkedInField() {
        for (Schema.SObjectField fld : Account.SObjectType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = fld.getDescribe();
            String name = d.getName().toLowerCase();
            String label = (d.getLabel() == null ? '' : d.getLabel()).toLowerCase();
            if (name.contains('linkedin') || label.contains('linkedin')) {
                return d.getName();
            }
        }
        return null;
    }

    // ---------- Scan ---------- //

    public static ScanResult scanFamilies() {
        ScanResult out = new ScanResult();
        out.linkedInField = detectLinkedInField();
        out.families = new List<AccountFamily>();
        out.totalAccountsScanned = 0;

        List<String> fields = new List<String>{
            'Id','Name','Website','BillingCountry','BillingState','BillingCity',
            'ParentId','Parent.Name','Type','Industry'
        };
        if (out.linkedInField != null) fields.add(out.linkedInField);

        String soql =
            'SELECT ' + String.join(fields, ', ') +
            ' FROM Account WHERE Website != null' +
            ' WITH USER_MODE' +
            ' LIMIT 5000';

        List<SObject> records;
        try {
            records = Database.query(soql);
        } catch (Exception e) {
            // Fall back without USER_MODE if the org's API version doesn't support it.
            soql = soql.replace(' WITH USER_MODE', '');
            records = Database.query(soql);
        }

        List<AccountInFamily> enriched = new List<AccountInFamily>();
        for (SObject sob : records) {
            Account a = (Account) sob;
            Normalized n = normalizeWebsite(a.Website);
            AccountInFamily af = new AccountInFamily();
            af.id = a.Id;
            af.name = a.Name;
            af.website = a.Website;
            af.normalizedDomain = n == null ? null : n.domain;
            af.brandLabel = n == null ? null : n.brand;
            af.billingCountry = a.BillingCountry;
            af.billingState = a.BillingState;
            af.billingCity = a.BillingCity;
            af.industry = a.Industry;
            af.accountType = a.Type;
            af.parentId = a.ParentId;
            af.parentName = a.Parent == null ? null : a.Parent.Name;
            if (out.linkedInField != null) {
                Object v = a.get(out.linkedInField);
                af.linkedInUrl = v == null ? null : String.valueOf(v);
            }
            enriched.add(af);
        }
        out.totalAccountsScanned = enriched.size();

        Map<String, List<AccountInFamily>> byBrand = new Map<String, List<AccountInFamily>>();
        for (AccountInFamily af : enriched) {
            if (String.isBlank(af.brandLabel)) continue;
            if (!byBrand.containsKey(af.brandLabel)) {
                byBrand.put(af.brandLabel, new List<AccountInFamily>());
            }
            byBrand.get(af.brandLabel).add(af);
        }

        for (String brand : byBrand.keySet()) {
            List<AccountInFamily> accounts = byBrand.get(brand);
            if (accounts.size() < 2) continue;

            Boolean hasOrphan = false;
            Map<String, Integer> domainCounts = new Map<String, Integer>();
            for (AccountInFamily af : accounts) {
                if (af.parentId == null) hasOrphan = true;
                if (af.normalizedDomain != null) {
                    Integer c = domainCounts.containsKey(af.normalizedDomain) ? domainCounts.get(af.normalizedDomain) : 0;
                    domainCounts.put(af.normalizedDomain, c + 1);
                }
            }
            Boolean hasSharedDomain = false;
            for (Integer c : domainCounts.values()) if (c > 1) hasSharedDomain = true;
            if (!hasOrphan && !hasSharedDomain) continue;

            Set<String> uniqueDomains = new Set<String>();
            Set<String> uniqueCountries = new Set<String>();
            Integer withParent = 0;
            String representative = accounts[0].name;
            for (AccountInFamily af : accounts) {
                if (af.normalizedDomain != null) uniqueDomains.add(af.normalizedDomain);
                if (String.isNotBlank(af.billingCountry)) uniqueCountries.add(af.billingCountry);
                if (af.parentId != null) withParent++;
                if (af.parentId == null && representative == accounts[0].name) representative = af.name;
            }

            AccountFamily f = new AccountFamily();
            f.brandLabel = brand;
            f.representativeName = representative;
            f.normalizedDomains = new List<String>(uniqueDomains);
            f.billingCountries = new List<String>(uniqueCountries);
            f.accountCount = accounts.size();
            f.withParentCount = withParent;
            f.accounts = accounts;
            out.families.add(f);
        }

        // Largest families first.
        out.families.sort(new FamilySizeComparator());
        return out;
    }

    private class FamilySizeComparator implements Comparator<AccountFamily> {
        public Integer compare(AccountFamily a, AccountFamily b) {
            return b.accountCount - a.accountCount;
        }
    }

    // ---------- Propose ---------- //

    private static final String PROPOSAL_SYSTEM_PROMPT =
        'You are a Salesforce data-quality expert specializing in B2B account hierarchies. ' +
        'You analyze groups of Salesforce Account records that appear related (same brand, related domains, ' +
        'country-office naming patterns) and propose a clean parent-child hierarchy.\n\n' +
        'For each family you must:\n' +
        '1. Decide whether one of the supplied accounts is the global/ultimate parent.\n' +
        '2. If no clear ultimate parent exists among the supplied accounts, propose a synthetic "gap" node ' +
        'that the user should create (e.g. "Oaklins International" when only country offices exist).\n' +
        '3. Propose intermediate regional parents only when the evidence is strong; otherwise put country ' +
        'offices directly under the ultimate parent.\n' +
        '4. Output ONLY valid JSON. No prose, no markdown.\n\n' +
        'Heuristics:\n' +
        '- The account whose website is the canonical brand domain (e.g. "oaklins.com") is usually the ultimate parent.\n' +
        '- Names containing "Global", "Worldwide", "International", "Holdings", "Group", "HQ" suggest ultimate parents.\n' +
        '- BillingCountry matching the domain country usually indicates a country office, not the HQ.\n' +
        '- Different LinkedIn URLs strongly suggest these are separate real legal entities.\n' +
        '- Same LinkedIn URL across accounts suggests true duplicates — flag in warnings, do not propose parentage.\n' +
        '- Never propose a cycle or self-parent.\n\n' +
        'Return JSON in exactly this shape:\n' +
        '{\n' +
        '  "summary": "1-2 sentence overall explanation.",\n' +
        '  "ultimateParentAccountId": "<Salesforce Id or null>",\n' +
        '  "gaps": [{"gapId":"gap_1","proposedName":"Acme International","reason":"Why","suggestedWebsite":"acme.com","suggestedBillingCountry":null}],\n' +
        '  "relationships": [{"childAccountId":"<Id>","parentRef":"<Id or gap_1>","rationale":"Why"}],\n' +
        '  "warnings": ["..."]\n' +
        '}\n\n' +
        'If the family is NOT a hierarchy (e.g. true duplicates), return relationships=[] and explain in warnings.';

    public static HierarchyProposal proposeHierarchy(AccountFamily family) {
        if (family == null || family.accounts == null) {
            throw new IllegalArgumentException('family is required');
        }

        List<Object> accountPayload = new List<Object>();
        for (AccountInFamily af : family.accounts) {
            accountPayload.add(new Map<String, Object>{
                'Id' => af.id,
                'Name' => af.name,
                'Website' => af.website,
                'NormalizedDomain' => af.normalizedDomain,
                'BillingCountry' => af.billingCountry,
                'BillingState' => af.billingState,
                'BillingCity' => af.billingCity,
                'LinkedIn' => af.linkedInUrl,
                'Industry' => af.industry,
                'Type' => af.accountType,
                'CurrentParentId' => af.parentId,
                'CurrentParentName' => af.parentName
            });
        }

        String userMessage =
            'Analyze this group of Salesforce Account records sharing brand label "' +
            family.brandLabel + '" and propose a parent-child hierarchy.\n\n' +
            'Number of accounts: ' + family.accountCount + '\n' +
            'Distinct normalized domains: ' + String.join(family.normalizedDomains, ', ') + '\n' +
            'Distinct billing countries: ' + String.join(family.billingCountries, ', ') + '\n\n' +
            'Accounts:\n' + JSON.serializePretty(accountPayload) +
            '\n\nPropose the hierarchy now. Return ONLY JSON.';

        String rawText = AnthropicClient.complete(PROPOSAL_SYSTEM_PROMPT, userMessage, 4096);
        return buildProposal(family, parseProposalJson(rawText));
    }

    @TestVisible
    private static Map<String, Object> parseProposalJson(String text) {
        if (String.isBlank(text)) throw new AnthropicClient.AnthropicException('Empty response from Claude');
        String cleaned = text.trim();
        if (cleaned.startsWith('```')) {
            Integer nl = cleaned.indexOf('\n');
            if (nl > 0) cleaned = cleaned.substring(nl + 1);
            if (cleaned.endsWith('```')) cleaned = cleaned.substring(0, cleaned.length() - 3).trim();
        }
        Integer first = cleaned.indexOf('{');
        Integer last  = cleaned.lastIndexOf('}');
        if (first < 0 || last < 0 || last <= first) {
            throw new AnthropicClient.AnthropicException('Claude did not return JSON');
        }
        String jsonPart = cleaned.substring(first, last + 1);
        return (Map<String, Object>) JSON.deserializeUntyped(jsonPart);
    }

    @TestVisible
    private static HierarchyProposal buildProposal(AccountFamily family, Map<String, Object> raw) {
        Map<String, AccountInFamily> accountsById = new Map<String, AccountInFamily>();
        for (AccountInFamily a : family.accounts) accountsById.put(a.id, a);

        // Parse gaps.
        List<HierarchyGap> gaps = new List<HierarchyGap>();
        Map<String, HierarchyGap> gapsById = new Map<String, HierarchyGap>();
        List<Object> rawGaps = (List<Object>) raw.get('gaps');
        Integer idx = 0;
        if (rawGaps != null) {
            for (Object o : rawGaps) {
                Map<String, Object> g = (Map<String, Object>) o;
                HierarchyGap hg = new HierarchyGap();
                hg.gapId = (String) g.get('gapId');
                if (String.isBlank(hg.gapId)) hg.gapId = 'gap_' + (++idx);
                hg.proposedName = (String) g.get('proposedName');
                if (String.isBlank(hg.proposedName)) hg.proposedName = family.brandLabel + ' (Ultimate Parent)';
                hg.reason = (String) g.get('reason');
                hg.suggestedWebsite = (String) g.get('suggestedWebsite');
                if (String.isBlank(hg.suggestedWebsite) && !family.normalizedDomains.isEmpty()) {
                    hg.suggestedWebsite = family.normalizedDomains[0];
                }
                hg.suggestedBillingCountry = (String) g.get('suggestedBillingCountry');
                gaps.add(hg);
                gapsById.put(hg.gapId, hg);
            }
        }

        String ultimateAccountId = (String) raw.get('ultimateParentAccountId');
        if (ultimateAccountId != null && !accountsById.containsKey(ultimateAccountId)) ultimateAccountId = null;
        String ultimateNodeId = ultimateAccountId;
        if (ultimateNodeId == null && !gaps.isEmpty()) ultimateNodeId = gaps[0].gapId;

        // Index proposed relationships.
        Map<String, Map<String, String>> proposedParentByAccount = new Map<String, Map<String, String>>();
        List<Object> rels = (List<Object>) raw.get('relationships');
        if (rels != null) {
            for (Object o : rels) {
                Map<String, Object> r = (Map<String, Object>) o;
                String childId  = (String) r.get('childAccountId');
                String parentRef = (String) r.get('parentRef');
                if (String.isBlank(childId) || String.isBlank(parentRef)) continue;
                if (!accountsById.containsKey(childId)) continue;
                if (childId == parentRef) continue;
                proposedParentByAccount.put(childId, new Map<String, String>{
                    'ref' => parentRef,
                    'rationale' => (String) r.get('rationale')
                });
            }
        }

        // Build node list — gaps first so they appear even if unreferenced.
        List<HierarchyNode> nodes = new List<HierarchyNode>();
        for (HierarchyGap g : gaps) {
            HierarchyNode hn = new HierarchyNode();
            hn.id = g.gapId;
            hn.name = g.proposedName;
            hn.kind = 'gap';
            hn.accountId = null;
            hn.parentNodeId = null;
            hn.currentParentId = null;
            hn.proposedParentId = null;
            hn.billingCountry = g.suggestedBillingCountry;
            hn.website = g.suggestedWebsite;
            hn.rationale = g.reason;
            hn.isChange = false;
            nodes.add(hn);
        }

        // Pre-compute which accounts have children, so we can flag regional parents.
        Set<String> referencedAsParent = new Set<String>();
        for (Map<String, String> entry : proposedParentByAccount.values()) {
            referencedAsParent.add(entry.get('ref'));
        }

        for (AccountInFamily a : family.accounts) {
            Map<String, String> rel = proposedParentByAccount.get(a.id);
            String parentRef = rel == null ? null : rel.get('ref');

            String parentNodeId = null;
            String proposedParentId = null;
            String kind = 'child';

            if (parentRef != null && accountsById.containsKey(parentRef)) {
                parentNodeId = parentRef;
                proposedParentId = parentRef;
            } else if (parentRef != null && gapsById.containsKey(parentRef)) {
                parentNodeId = parentRef;
                proposedParentId = 'GAP:' + parentRef;
            }

            if (a.id == ultimateAccountId) {
                kind = 'ultimate-parent';
                parentNodeId = null;
                proposedParentId = null;
            } else if (parentNodeId == null && ultimateNodeId != null) {
                // Default unparented accounts under the ultimate parent.
                parentNodeId = ultimateNodeId;
                proposedParentId = ultimateAccountId != null ? ultimateAccountId : 'GAP:' + ultimateNodeId;
            }

            if (kind == 'child' && referencedAsParent.contains(a.id)) {
                kind = 'regional-parent';
            }

            HierarchyNode hn = new HierarchyNode();
            hn.id = a.id;
            hn.name = a.name;
            hn.kind = kind;
            hn.accountId = a.id;
            hn.parentNodeId = parentNodeId;
            hn.currentParentId = a.parentId;
            hn.proposedParentId = proposedParentId;
            hn.billingCountry = a.billingCountry;
            hn.website = a.website;
            hn.rationale = rel == null ? (kind == 'ultimate-parent' ? 'Identified as the global/ultimate parent.' : '') : rel.get('rationale');
            hn.isChange = (proposedParentId != null && proposedParentId != a.parentId);
            nodes.add(hn);
        }

        HierarchyProposal p = new HierarchyProposal();
        p.family = family;
        p.summary = (String) raw.get('summary');
        p.hasUltimateParent = ultimateAccountId != null;
        p.ultimateParentNodeId = ultimateNodeId;
        p.nodes = nodes;
        p.gaps = gaps;
        p.warnings = new List<String>();
        List<Object> rawWarn = (List<Object>) raw.get('warnings');
        if (rawWarn != null) for (Object w : rawWarn) p.warnings.add((String) w);
        return p;
    }

    // ---------- Apply ---------- //

    public static ApplyResult applyChanges(List<HierarchyChange> changes) {
        ApplyResult out = new ApplyResult();
        out.applied = new List<HierarchyChange>();
        out.failed = new List<ApplyFailure>();
        if (changes == null || changes.isEmpty()) return out;

        List<HierarchyChange> safe = new List<HierarchyChange>();
        List<Account> updates = new List<Account>();
        for (HierarchyChange c : changes) {
            if (String.isBlank(c.accountId) || String.isBlank(c.newParentId)) continue;
            if (c.accountId == c.newParentId) continue;
            safe.add(c);
            updates.add(new Account(Id = c.accountId, ParentId = c.newParentId));
        }
        if (updates.isEmpty()) return out;

        Database.SaveResult[] results = Database.update(updates, false);
        for (Integer i = 0; i < results.size(); i++) {
            Database.SaveResult r = results[i];
            HierarchyChange c = safe[i];
            if (r.isSuccess()) {
                out.applied.add(c);
            } else {
                ApplyFailure f = new ApplyFailure();
                f.accountId = c.accountId;
                List<String> errs = new List<String>();
                for (Database.Error e : r.getErrors()) errs.add(e.getMessage());
                f.errorMessage = String.join(errs, '; ');
                out.failed.add(f);
            }
        }
        return out;
    }

    // ---------- Gap creation ---------- //

    public class GapInput {
        @AuraEnabled public String gapName;
        @AuraEnabled public String website;
        @AuraEnabled public String billingCountry;
        @AuraEnabled public String description;
    }

    public static Id createGapAccount(GapInput input) {
        if (input == null || String.isBlank(input.gapName)) {
            throw new IllegalArgumentException('name is required');
        }
        Account a = new Account(Name = input.gapName);
        if (String.isNotBlank(input.website)) a.Website = input.website;
        if (String.isNotBlank(input.billingCountry)) a.BillingCountry = input.billingCountry;
        if (String.isNotBlank(input.description)) a.Description = input.description;
        insert a;
        return a.Id;
    }
}
