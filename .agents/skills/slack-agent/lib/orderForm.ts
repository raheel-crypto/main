import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import PizZip from "pizzip";
import Docxtemplater from "docxtemplater";
import type { ApprovalRequest } from "./types.js";

const MASTER_TEMPLATE = "order-form.docx";

/**
 * Fallback chain for the 4-template era. Used only if the master template
 * doesn't exist on disk -- once `templates/order-form.docx` is shipped, the
 * legacy files can be deleted and these constants become dead code.
 */
const LEGACY_TEMPLATE_FILES = {
  standardNew: "order-form-standard-new.docx",
  standardExisting: "order-form-standard-existing.docx",
  enterpriseNew: "order-form-enterprise-new.docx",
  enterpriseExisting: "order-form-enterprise-existing.docx",
} as const;

const templateCache: Record<string, Buffer> = {};

/**
 * Resolve a template file by trying `process.cwd()/templates/` first, then
 * the path next to this module. On Vercel, esbuild bundles `lib/orderForm.ts`
 * into the calling function's output, so `import.meta.url`-relative paths can
 * drift from where the included template files actually land. `process.cwd()`
 * is the function's project root at runtime and is the more reliable anchor.
 */
async function loadTemplate(filename: string): Promise<Buffer | null> {
  if (templateCache[filename]) return templateCache[filename];

  const candidates = [
    join(process.cwd(), "templates", filename),
    join(dirname(fileURLToPath(import.meta.url)), "..", "templates", filename),
  ];

  for (const path of candidates) {
    try {
      const buf = await readFile(path);
      console.log(`[orderForm] loaded ${filename} from ${path} (${buf.length} bytes)`);
      templateCache[filename] = buf;
      return buf;
    } catch {
      // try next candidate
    }
  }
  return null;
}

/**
 * Pick which legacy template applies for a given request — used only when the
 * master template isn't on disk yet. Once the master ships, this is dead code.
 */
function pickLegacyTemplate(
  segment: string | null,
  type: string | null,
): keyof typeof LEGACY_TEMPLATE_FILES {
  const isEnterprise = segment?.trim().toLowerCase() === "enterprise";
  const isNewBusiness = type?.trim().toLowerCase() === "new business";
  if (isEnterprise) return isNewBusiness ? "enterpriseNew" : "enterpriseExisting";
  return isNewBusiness ? "standardNew" : "standardExisting";
}

export function orderFormFilename(request: ApprovalRequest): string {
  const safeAccount =
    request.context.account.name.replace(/[^A-Za-z0-9_\- ]+/g, "").trim() || "Account";
  return `Rogo Order Form - ${safeAccount}.docx`;
}

/**
 * Generate the prefilled order form for an approved quote.
 *
 * Template tags are `{{Field Name}}` for values and `{{#flag}}…{{/flag}}` for
 * conditional sections / loops. The custom parser handles flat value lookups
 * (including keys with spaces and dots like `{{Account.Name}}`); docxtemplater
 * handles section/loop traversal natively.
 *
 * Prefers `templates/order-form.docx` (the master template with conditional
 * sections). Falls back to the 4-file segment×type set if the master isn't on
 * disk yet, so the transition can happen in a separate commit from the code
 * change without breaking production.
 */
export async function fillOrderForm(request: ApprovalRequest): Promise<Buffer> {
  const master = await loadTemplate(MASTER_TEMPLATE);
  const buf =
    master ??
    (await loadTemplate(
      LEGACY_TEMPLATE_FILES[
        pickLegacyTemplate(
          request.context.account.segment,
          request.context.opportunity.type,
        )
      ],
    ));
  if (!buf) {
    throw new Error(
      `Could not load any order form template (looked for ${MASTER_TEMPLATE} and the 4 legacy variants in templates/)`,
    );
  }

  const zip = new PizZip(buf);
  const doc = new Docxtemplater(zip, {
    delimiters: { start: "{{", end: "}}" },
    paragraphLoop: true,
    linebreaks: true,
    parser: (tag: string) => ({
      get: (scope: Record<string, unknown>) => scope[tag] ?? "",
    }),
  });

  doc.render(buildData(request));

  return doc.getZip().generate({ type: "nodebuffer", compression: "DEFLATE" });
}

function buildData(request: ApprovalRequest): Record<string, unknown> {
  const { context, form, pricing } = request;
  const isEnterprise = context.account.segment?.trim().toLowerCase() === "enterprise";
  const isNewBusiness = context.opportunity.type?.trim().toLowerCase() === "new business";
  // Sort here too -- fetchTermsByCodes already sorts at fetch time, but
  // re-sorting makes render order resilient to snapshot reordering and to
  // future callers that bypass the SOQL helper.
  const terms = [...(form.selected_terms ?? [])].sort(
    (a, b) => a.sort_order - b.sort_order,
  );
  const termScope = (t: (typeof terms)[number]) => ({
    title: t.title,
    body: t.body,
    category: t.category,
  });
  const selectedTerms = terms.map(termScope);

  return {
    // Boolean flags drive the master template's conditional sections.
    // Both positive and negative variants are exposed so legal can write
    // {{#isStandard}}...{{/isStandard}} instead of inverted sections.
    isEnterprise,
    isStandard: !isEnterprise,
    isNewBusiness,
    isExistingCustomer: !isNewBusiness,

    // Catch-all loop -- renders every attached term in Sort_Order__c order.
    // Use this when the template has one "Special Terms" block at the bottom.
    selected_terms: selectedTerms,

    // Per-category buckets -- let the template scatter terms across the
    // doc by Category__c. Each bucket is a subset of selected_terms in the
    // same Sort_Order__c order. Empty buckets render nothing. Categories
    // match the Legal_Term__c.Category__c picklist values.
    terms_payment: termsInCategory(terms, "Payment").map(termScope),
    terms_renewal: termsInCategory(terms, "Renewal").map(termScope),
    terms_liability: termsInCategory(terms, "Liability").map(termScope),
    terms_ip: termsInCategory(terms, "IP").map(termScope),
    terms_data: termsInCategory(terms, "Data").map(termScope),
    terms_termination: termsInCategory(terms, "Termination").map(termScope),
    terms_other: termsInCategory(terms, "Other").map(termScope),

    // Existing flat-key data — unchanged. Templates can reference these
    // unconditionally, or wrap them in {{#isEnterprise}} sections etc.
    "Account.Name": context.account.name,
    "Contract Length": formatContractLength(pricing.contract_months),
    "Contract Start Date": formatDateLong(form.contract_start_date),
    "ARR": formatCurrency(pricing.arr ?? pricing.total_amount),
    "Platform Fee": formatCurrency(pricing.platform_fee_total),
    "Hosting Fee": formatCurrency(form.hosting_fee),
    "hosting fee": formatCurrency(form.hosting_fee),
    "Credits Commit": formatCurrency(pricing.credits_commit_total),
    "credits commit": formatCurrency(pricing.credits_commit_total),
    "Price per user": formatCurrency(form.price_per_user),
    "price per user": formatCurrency(form.price_per_user),
    "Total Credits": formatCount(form.total_credits),
    "Users": form.users,
  };
}

function termsInCategory<T extends { category: string }>(
  terms: ReadonlyArray<T>,
  category: string,
): T[] {
  const target = category.trim().toLowerCase();
  return terms.filter((t) => t.category.trim().toLowerCase() === target);
}

function formatCount(n: number): string {
  return n.toLocaleString("en-US");
}

function formatContractLength(months: number | null): string {
  if (months == null) return "";
  return `${months} months`;
}

/**
 * Format an ISO `YYYY-MM-DD` string as e.g. "May 18, 2026" without timezone drift.
 * `new Date("2026-05-18")` parses as UTC midnight, which renders as the previous
 * day west of UTC — so we parse the parts manually.
 */
function formatDateLong(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return iso;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

function formatCurrency(n: number): string {
  return n.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  });
}
