import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import PizZip from "pizzip";
import Docxtemplater from "docxtemplater";
import type { ApprovalRequest } from "./types.js";

const TEMPLATES_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "templates",
);

const TEMPLATE_FILES = {
  enterprise: "order-form-enterprise.docx",
  standard: "order-form.docx",
} as const;

const templateCache: Partial<Record<keyof typeof TEMPLATE_FILES, Buffer>> = {};

async function loadTemplate(kind: keyof typeof TEMPLATE_FILES): Promise<Buffer> {
  if (!templateCache[kind]) {
    templateCache[kind] = await readFile(join(TEMPLATES_DIR, TEMPLATE_FILES[kind]));
  }
  return templateCache[kind]!;
}

function pickTemplate(segment: string | null): keyof typeof TEMPLATE_FILES {
  return segment?.trim().toLowerCase() === "enterprise" ? "enterprise" : "standard";
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
  const kind = pickTemplate(request.context.account.segment);
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
    "Platform Fee": formatCurrency(pricing.platform_fee_total),
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
