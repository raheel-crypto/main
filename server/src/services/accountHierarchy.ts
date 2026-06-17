import Anthropic from "@anthropic-ai/sdk";
import { Connection } from "jsforce";
import { config } from "../config.js";

const anthropic = new Anthropic({ apiKey: config.anthropic.apiKey });

// Multi-part TLDs we strip so we can extract a meaningful "brand label".
// e.g. oaklins.com.au -> brand "oaklins", oaklins.co.uk -> brand "oaklins"
const MULTI_PART_TLDS = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk",
  "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
  "co.nz", "net.nz", "org.nz", "govt.nz",
  "com.br", "com.mx", "com.ar", "com.co", "com.pe", "com.cl",
  "com.sg", "com.my", "com.hk", "com.tw", "com.cn",
  "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
  "co.kr", "or.kr",
  "co.in", "co.za", "co.il", "co.ke", "co.ug",
  "com.tr", "com.sa", "com.ua",
]);

// Common subdomain prefixes to strip before extracting the registered domain.
const STRIP_SUBDOMAINS = new Set(["www", "m", "en", "us", "uk", "de", "fr", "es", "it", "nl", "au", "ca"]);

export interface AccountInFamily {
  id: string;
  name: string;
  website: string | null;
  normalizedDomain: string | null;
  brandLabel: string | null;
  billingCountry: string | null;
  billingState: string | null;
  billingCity: string | null;
  linkedInUrl: string | null;
  industry: string | null;
  type: string | null;
  parentId: string | null;
  parentName: string | null;
  recordTypeId: string | null;
}

export interface AccountFamily {
  brandLabel: string;
  representativeName: string;
  normalizedDomains: string[];
  billingCountries: string[];
  accountCount: number;
  withParentCount: number;
  accounts: AccountInFamily[];
}

export interface HierarchyNode {
  id: string; // Salesforce Account ID OR a synthetic gap id like "gap_1"
  name: string;
  kind: "ultimate-parent" | "regional-parent" | "child" | "gap";
  accountId: string | null; // null for gaps
  parentNodeId: string | null;
  currentParentId: string | null;
  proposedParentId: string | null; // value to write (string for existing, "GAP:<gapId>" for a gap)
  billingCountry: string | null;
  website: string | null;
  rationale: string;
  isChange: boolean;
}

export interface HierarchyGap {
  gapId: string;
  proposedName: string;
  reason: string;
  suggestedWebsite: string | null;
  suggestedBillingCountry: string | null;
}

export interface HierarchyProposal {
  family: AccountFamily;
  summary: string;
  hasUltimateParent: boolean;
  ultimateParentNodeId: string | null;
  nodes: HierarchyNode[];
  gaps: HierarchyGap[];
  warnings: string[];
}

function normalizeWebsite(raw: string | null): { domain: string; brand: string } | null {
  if (!raw) return null;
  let url = raw.trim().toLowerCase();
  if (!url) return null;
  url = url.replace(/^https?:\/\//, "");
  url = url.replace(/^\/\//, "");
  // strip path/query/fragment
  url = url.split("/")[0].split("?")[0].split("#")[0];
  url = url.replace(/:\d+$/, ""); // strip port
  if (!url || !url.includes(".")) return null;

  const parts = url.split(".").filter(Boolean);
  if (parts.length < 2) return null;

  // Strip common geo/language subdomain (e.g. www.oaklins.com, en.oaklins.com).
  while (parts.length > 2 && STRIP_SUBDOMAINS.has(parts[0])) {
    parts.shift();
  }

  // Strip multi-part TLD if present.
  const lastTwo = parts.slice(-2).join(".");
  let registeredParts: string[];
  if (parts.length >= 3 && MULTI_PART_TLDS.has(lastTwo)) {
    registeredParts = parts.slice(-3);
  } else {
    registeredParts = parts.slice(-2);
  }

  const domain = registeredParts.join(".");
  const brand = registeredParts[0];
  if (!brand || brand.length < 2) return null;
  return { domain, brand };
}

const LINKEDIN_FIELD_PATTERNS = [/^linkedin/i, /linkedin.*url/i, /linkedin.*profile/i];

async function detectLinkedInField(conn: Connection): Promise<string | null> {
  try {
    const desc = await conn.describe("Account");
    const field = desc.fields.find((f) =>
      LINKEDIN_FIELD_PATTERNS.some((p) => p.test(f.name)) ||
      LINKEDIN_FIELD_PATTERNS.some((p) => p.test(f.label))
    );
    return field?.name || null;
  } catch {
    return null;
  }
}

export async function scanAccountFamilies(
  conn: Connection,
  options: { minFamilySize?: number; maxFamilies?: number } = {}
): Promise<{ families: AccountFamily[]; linkedInField: string | null; totalAccountsScanned: number }> {
  const minFamilySize = options.minFamilySize ?? 2;
  const maxFamilies = options.maxFamilies ?? 50;

  const linkedInField = await detectLinkedInField(conn);

  const fields = [
    "Id", "Name", "Website", "BillingCountry", "BillingState", "BillingCity",
    "ParentId", "Parent.Name", "Type", "Industry", "RecordTypeId",
  ];
  if (linkedInField) fields.push(linkedInField);

  // Limit to accounts with a website (the basis for grouping). 5000 cap is safe.
  const soql = `SELECT ${fields.join(", ")} FROM Account WHERE Website != null LIMIT 5000`;
  const result = await conn.query<any>(soql);

  const records = result.records || [];

  type RawAccount = Record<string, any>;
  const enriched: AccountInFamily[] = records.map((r: RawAccount) => {
    const n = normalizeWebsite(r.Website);
    return {
      id: r.Id,
      name: r.Name,
      website: r.Website || null,
      normalizedDomain: n?.domain || null,
      brandLabel: n?.brand || null,
      billingCountry: r.BillingCountry || null,
      billingState: r.BillingState || null,
      billingCity: r.BillingCity || null,
      linkedInUrl: linkedInField ? r[linkedInField] || null : null,
      industry: r.Industry || null,
      type: r.Type || null,
      parentId: r.ParentId || null,
      parentName: r.Parent?.Name || null,
      recordTypeId: r.RecordTypeId || null,
    };
  });

  // Group by brand label, since we want to catch country-TLD variations too.
  const byBrand = new Map<string, AccountInFamily[]>();
  for (const a of enriched) {
    if (!a.brandLabel) continue;
    if (!byBrand.has(a.brandLabel)) byBrand.set(a.brandLabel, []);
    byBrand.get(a.brandLabel)!.push(a);
  }

  const families: AccountFamily[] = [];
  for (const [brand, accounts] of byBrand) {
    if (accounts.length < minFamilySize) continue;

    // Only surface families that are interesting: at least one account lacks a parent,
    // OR multiple accounts share the same domain (the duplicate-looking case).
    const hasOrphan = accounts.some((a) => !a.parentId);
    const sameDomainCount = new Map<string, number>();
    for (const a of accounts) {
      if (a.normalizedDomain) {
        sameDomainCount.set(a.normalizedDomain, (sameDomainCount.get(a.normalizedDomain) || 0) + 1);
      }
    }
    const hasSharedDomain = Array.from(sameDomainCount.values()).some((c) => c > 1);
    if (!hasOrphan && !hasSharedDomain) continue;

    const domains = Array.from(new Set(accounts.map((a) => a.normalizedDomain).filter(Boolean))) as string[];
    const countries = Array.from(new Set(accounts.map((a) => a.billingCountry).filter(Boolean))) as string[];
    const withParent = accounts.filter((a) => a.parentId).length;
    const representative = accounts.find((a) => !a.parentId)?.name || accounts[0].name;

    families.push({
      brandLabel: brand,
      representativeName: representative,
      normalizedDomains: domains,
      billingCountries: countries,
      accountCount: accounts.length,
      withParentCount: withParent,
      accounts,
    });
  }

  // Largest families first.
  families.sort((a, b) => b.accountCount - a.accountCount);

  return {
    families: families.slice(0, maxFamilies),
    linkedInField,
    totalAccountsScanned: enriched.length,
  };
}

const PROPOSAL_SYSTEM_PROMPT = `You are a Salesforce data-quality expert specializing in B2B account hierarchies. You analyze groups of Salesforce Account records that appear to be related (same brand, related domains, country-office naming patterns) and propose a clean parent-child hierarchy.

For each family you must:
1. Decide whether one of the supplied accounts is the global/ultimate parent (the worldwide HQ).
2. If no clear ultimate parent exists among the supplied accounts, propose a synthetic "gap" node that the user should create (e.g. "Oaklins International" when only country offices exist).
3. If the brand uses regional hubs (e.g. an EMEA HQ on top of country offices), propose intermediate parents only when the evidence is strong; otherwise put country offices directly under the ultimate parent.
4. Output ONLY valid JSON. No prose, no markdown.

Heuristics to use:
- The account whose website is the canonical brand domain (e.g. "oaklins.com" rather than "oaklins.de") is usually the ultimate parent.
- An account whose name contains "Global", "Worldwide", "International", "Holdings", "Group", or "HQ" is often the ultimate parent.
- An account whose BillingCountry matches the domain country (e.g. "Germany" + ".de") is usually a country office, not the HQ.
- Different LinkedIn URLs strongly suggest these are separate real legal entities (not duplicates).
- Same exact LinkedIn URL across accounts suggests true duplicates that should be merged, not parented — flag this in warnings instead of proposing parentage.
- Never propose a cycle. Never propose an account as its own parent.

Return JSON in exactly this shape:
{
  "summary": "1-2 sentence overall explanation of the proposed hierarchy.",
  "ultimateParentAccountId": "<Salesforce Id of the ultimate parent among supplied accounts, or null if a gap is needed>",
  "gaps": [
    {
      "gapId": "gap_1",
      "proposedName": "Acme International",
      "reason": "Why this gap is needed.",
      "suggestedWebsite": "acme.com",
      "suggestedBillingCountry": null
    }
  ],
  "relationships": [
    {
      "childAccountId": "<Salesforce Id>",
      "parentRef": "<Salesforce Id of an existing account OR 'gap_1' for a synthetic node>",
      "rationale": "Why this parentage."
    }
  ],
  "warnings": ["Any data-quality concerns, e.g. true duplicates that should be merged."]
}

If the family is NOT actually a hierarchy (e.g. they look like genuine duplicates of the same legal entity), return relationships=[] and explain in warnings.`;

interface AIProposalRaw {
  summary?: string;
  ultimateParentAccountId?: string | null;
  gaps?: HierarchyGap[];
  relationships?: { childAccountId: string; parentRef: string; rationale?: string }[];
  warnings?: string[];
}

function parseProposalJson(text: string): AIProposalRaw {
  // strip ```json fences if present
  let cleaned = text.trim();
  if (cleaned.startsWith("```")) {
    cleaned = cleaned.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "");
  }
  const match = cleaned.match(/\{[\s\S]*\}/);
  if (!match) throw new Error("Claude did not return JSON");
  return JSON.parse(match[0]);
}

export async function proposeHierarchy(family: AccountFamily): Promise<HierarchyProposal> {
  const userMessage = `Analyze this group of Salesforce Account records that appear to share the brand label "${family.brandLabel}" and propose a parent-child hierarchy.

Number of accounts: ${family.accountCount}
Distinct normalized domains: ${family.normalizedDomains.join(", ") || "none"}
Distinct billing countries: ${family.billingCountries.join(", ") || "none"}

Accounts:
${JSON.stringify(
  family.accounts.map((a) => ({
    Id: a.id,
    Name: a.name,
    Website: a.website,
    NormalizedDomain: a.normalizedDomain,
    BillingCountry: a.billingCountry,
    BillingState: a.billingState,
    BillingCity: a.billingCity,
    LinkedIn: a.linkedInUrl,
    Industry: a.industry,
    Type: a.type,
    CurrentParentId: a.parentId,
    CurrentParentName: a.parentName,
  })),
  null,
  2
)}

Propose the hierarchy now. Return ONLY JSON.`;

  const response = await anthropic.messages.create({
    model: "claude-sonnet-4-6",
    max_tokens: 4096,
    system: PROPOSAL_SYSTEM_PROMPT,
    messages: [{ role: "user", content: userMessage }],
  });

  const text = response.content[0]?.type === "text" ? response.content[0].text : "";
  const raw = parseProposalJson(text);

  return buildProposal(family, raw);
}

function buildProposal(family: AccountFamily, raw: AIProposalRaw): HierarchyProposal {
  const accountsById = new Map(family.accounts.map((a) => [a.id, a]));
  const gaps: HierarchyGap[] = (raw.gaps || []).map((g, idx) => ({
    gapId: g.gapId || `gap_${idx + 1}`,
    proposedName: g.proposedName || `${family.brandLabel} (Ultimate Parent)`,
    reason: g.reason || "No clear ultimate parent found among supplied accounts.",
    suggestedWebsite: g.suggestedWebsite || family.normalizedDomains[0] || null,
    suggestedBillingCountry: g.suggestedBillingCountry || null,
  }));
  const gapsById = new Map(gaps.map((g) => [g.gapId, g]));

  // Resolve the ultimate parent: prefer one chosen by Claude; otherwise default to the first gap.
  let ultimateAccountId: string | null = raw.ultimateParentAccountId || null;
  if (ultimateAccountId && !accountsById.has(ultimateAccountId)) ultimateAccountId = null;

  let ultimateNodeId: string | null = ultimateAccountId;
  if (!ultimateNodeId && gaps.length > 0) {
    ultimateNodeId = gaps[0].gapId;
  }

  const relationships = (raw.relationships || []).filter(
    (r) => r.childAccountId && r.parentRef && accountsById.has(r.childAccountId)
  );

  // Build parent map: accountId -> proposed parentRef (existing accountId or gapId)
  const proposedParentByAccount = new Map<string, { ref: string; rationale: string }>();
  for (const r of relationships) {
    if (r.parentRef === r.childAccountId) continue; // ignore self-loop
    proposedParentByAccount.set(r.childAccountId, {
      ref: r.parentRef,
      rationale: r.rationale || "",
    });
  }

  // Build nodes: gaps first (so they appear in the graph even if unreferenced), then accounts.
  const nodes: HierarchyNode[] = [];

  for (const gap of gaps) {
    nodes.push({
      id: gap.gapId,
      name: gap.proposedName,
      kind: "gap",
      accountId: null,
      parentNodeId: null,
      currentParentId: null,
      proposedParentId: null,
      billingCountry: gap.suggestedBillingCountry,
      website: gap.suggestedWebsite,
      rationale: gap.reason,
      isChange: false,
    });
  }

  for (const acc of family.accounts) {
    const rel = proposedParentByAccount.get(acc.id);
    const parentRef = rel?.ref || null;

    let parentNodeId: string | null = null;
    let proposedParentId: string | null = null;
    let kind: HierarchyNode["kind"] = "child";

    if (parentRef && accountsById.has(parentRef)) {
      parentNodeId = parentRef;
      proposedParentId = parentRef;
    } else if (parentRef && gapsById.has(parentRef)) {
      parentNodeId = parentRef;
      proposedParentId = `GAP:${parentRef}`;
    }

    if (acc.id === ultimateAccountId) {
      kind = "ultimate-parent";
      parentNodeId = null;
      proposedParentId = null;
    } else if (!parentNodeId && ultimateNodeId) {
      // Default unparented accounts under the ultimate parent.
      parentNodeId = ultimateNodeId;
      proposedParentId = ultimateAccountId
        ? ultimateAccountId
        : `GAP:${ultimateNodeId}`;
    }

    // Tag node as a "regional-parent" if other accounts in the family point to it.
    const hasChildren = Array.from(proposedParentByAccount.values()).some(
      (v) => v.ref === acc.id
    );
    if (kind === "child" && hasChildren) kind = "regional-parent";

    // Detect change vs current value. We compare to currentParentId for real account refs;
    // gap refs are always changes.
    const isChange =
      proposedParentId !== null && proposedParentId !== acc.parentId;

    nodes.push({
      id: acc.id,
      name: acc.name,
      kind,
      accountId: acc.id,
      parentNodeId,
      currentParentId: acc.parentId,
      proposedParentId,
      billingCountry: acc.billingCountry,
      website: acc.website,
      rationale: rel?.rationale || (kind === "ultimate-parent" ? "Identified as the global/ultimate parent." : ""),
      isChange,
    });
  }

  return {
    family,
    summary: raw.summary || "",
    hasUltimateParent: !!ultimateAccountId,
    ultimateParentNodeId: ultimateNodeId,
    nodes,
    gaps,
    warnings: raw.warnings || [],
  };
}

export interface HierarchyApplyChange {
  accountId: string;
  newParentId: string;
}

export interface HierarchyApplyResult {
  applied: { accountId: string; newParentId: string }[];
  failed: { accountId: string; error: string }[];
}

export async function applyHierarchyChanges(
  conn: Connection,
  changes: HierarchyApplyChange[]
): Promise<HierarchyApplyResult> {
  const result: HierarchyApplyResult = { applied: [], failed: [] };
  if (changes.length === 0) return result;

  // Guard against self-parenting before sending to Salesforce.
  const safe = changes.filter((c) => c.accountId && c.newParentId && c.accountId !== c.newParentId);
  if (safe.length === 0) return result;

  // jsforce supports array updates on sobject (composite request style).
  const updates = safe.map((c) => ({ Id: c.accountId, ParentId: c.newParentId }));
  const resp = await conn.sobject("Account").update(updates, { allOrNone: false });
  const arr = Array.isArray(resp) ? resp : [resp];

  arr.forEach((r, i) => {
    const change = safe[i];
    if (r.success) {
      result.applied.push({ accountId: change.accountId, newParentId: change.newParentId });
    } else {
      const errors = (r as any).errors || [];
      const msg = errors.map((e: any) => e.message || e).join("; ") || "Update failed";
      result.failed.push({ accountId: change.accountId, error: msg });
    }
  });

  return result;
}

export interface CreateGapAccountInput {
  name: string;
  website?: string | null;
  billingCountry?: string | null;
  description?: string | null;
}

export async function createGapAccount(
  conn: Connection,
  input: CreateGapAccountInput
): Promise<{ id: string }> {
  const record: Record<string, unknown> = { Name: input.name };
  if (input.website) record.Website = input.website;
  if (input.billingCountry) record.BillingCountry = input.billingCountry;
  if (input.description) record.Description = input.description;

  const resp = await conn.sobject("Account").create(record);
  const single = Array.isArray(resp) ? resp[0] : resp;
  if (!single.success) {
    const errors = (single as any).errors || [];
    throw new Error(errors.map((e: any) => e.message || e).join("; ") || "Failed to create Account");
  }
  return { id: single.id as string };
}
