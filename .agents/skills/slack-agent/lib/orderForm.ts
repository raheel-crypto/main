import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import PizZip from "pizzip";
import Docxtemplater from "docxtemplater";
import type { ApprovalRequest } from "./types.js";

/**
 * Four templates: cross of {standard, enterprise} × {new business, existing
 * customer}. Legal requires different language for new-business vs
 * renewal/expansion deals, so the order form picks one per quote.
 */
const TEMPLATE_FILES = {
  standardNew: "order-form-standard-new.docx",
  standardExisting: "order-form-standard-existing.docx",
  enterpriseNew: "order-form-enterprise-new.docx",
  enterpriseExisting: "order-form-enterprise-existing.docx",
} as const;

const templateCache: Partial<Record<keyof typeof TEMPLATE_FILES, Buffer>> = {};

/**
 * Resolve a template file by trying both `process.cwd()` and the path next to
 * this module. On Vercel, esbuild bundles `lib/orderForm.ts` into the calling
 * function's output, so `import.meta.url`-relative paths can drift from where
 * the included template files actually land. `process.cwd()` is the function's
 * project root at runtime and is the more reliable anchor — but we keep both
 * as fallbacks for local dev where the bundled path works.
 */
async function loadTemplate(kind: keyof typeof TEMPLATE_FILES): Promise<Buffer> {
  if (templateCache[kind]) return templateCache[kind]!;

  const filename = TEMPLATE_FILES[kind];
  const candidates = [
    join(process.cwd(), "templates", filename),
    join(dirname(fileURLToPath(import.meta.url)), "..", "templates", filename),
  ];

  const errors: string[] = [];
  for (const path of candidates) {
    try {
      const buf = await readFile(path);
      console.log(`[orderForm] loaded ${kind} from ${path} (${buf.length} bytes)`);
      templateCache[kind] = buf;
      return buf;
    } catch (e) {
      errors.push(`${path}: ${(e as Error).message}`);
    }
  }
  throw new Error(`Could not load template ${filename}. Tried:\n${errors.join("\n")}`);
}

function pickTemplate(
  segment: string | null,
  type: string | null,
): keyof typeof TEMPLATE_FILES {
  const isEnterprise = segment?.trim().toLowerCase() === "enterprise";
  const isNewBusiness = type?.trim().toLowerCase() === "new business";
  if (isEnterprise) return isNewBusiness ? "enterpriseNew" : "enterpriseExisting";
  return isNewBusiness ? "standardNew" : "standardExisting";
}

export function orderFormFilename(request: ApprovalRequest): string {
  const safeAccount = request.context.account.name.replace(/[^A-Za-z0-9_\- ]+/g, "").trim() || "Account";
  return `Rogo Order Form - ${safeAccount}.docx`;
}

/**
 * Generate the prefilled order form for an approved quote.
 *
 * Template tags are `{{Field Name}}` — including ones with spaces and dots
 * (e.g. `{{Account.Name}}`, `{{Contract Length}}`). The custom parser treats
 * each tag as a literal key into the data object so the SFDC-style names in
 * the template map 1:1 to the keys below without needing nested objects.
 */
export async function fillOrderForm(request: ApprovalRequest): Promise<Buffer> {
  const kind = pickTemplate(
    request.context.account.segment,
    request.context.opportunity.type,
  );
  const buf = await loadTemplate(kind);
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

function buildData(request: ApprovalRequest): Record<string, string | number> {
  const { context, form, pricing } = request;
  return {
    "Account.Name": context.account.name,
    "Contract Length": formatContractLength(pricing.contract_months),
    "Contract Start Date": formatDateLong(form.contract_start_date),
    // Standard template uses {{ARR}} (no hosting fee in non-Enterprise deals,
    // so the order form just shows the ARR). Enterprise template uses
    // {{Platform Fee}} broken out separately from the hosting fee line.
    "ARR": formatCurrency(pricing.arr ?? pricing.total_amount),
    "Platform Fee": formatCurrency(pricing.platform_fee_total),
    // Enterprise templates also break out hosting fee + credits commit.
    // Provide both casings so the templates can edit the case without code.
    "Hosting Fee": formatCurrency(form.hosting_fee),
    "hosting fee": formatCurrency(form.hosting_fee),
    "Credits Commit": formatCurrency(pricing.credits_commit_total),
    "credits commit": formatCurrency(pricing.credits_commit_total),
    // Standard template uses "Price per user"; enterprise template uses
    // lowercase "price per user". Provide both so either template renders.
    "Price per user": formatCurrency(form.price_per_user),
    "price per user": formatCurrency(form.price_per_user),
    // Total Credits is a credit count, not a dollar amount.
    "Total Credits": formatCount(form.total_credits),
    "Users": form.users,
  };
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
