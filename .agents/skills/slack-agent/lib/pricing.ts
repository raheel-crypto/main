import type { Package, PricingBreakdown, QuoteForm } from "./types.js";

const CREDIT_COMMIT_RATE = 0.02;

export const PACKAGE_LIST_PRICE: Record<Package, number | null> = {
  Standard: 7500,
  Premium: 10000,
  Enterprise: null,
};

export function calculatePricing(form: QuoteForm): PricingBreakdown {
  // price_per_user is the ALL-IN annual rate per seat -- it includes the
  // hosting share and the credit-commit share. The customer pays exactly
  // price_per_user * users per year; hosting and credits commit are
  // internal allocations carved out of that revenue for the order form
  // breakdown, NOT additive line items on top.
  const total = form.price_per_user * form.users;
  const creditsCommit = form.total_credits * CREDIT_COMMIT_RATE;
  const hosting = form.hosting_fee;
  const platformFee = total - creditsCommit - hosting;

  const listPrice = PACKAGE_LIST_PRICE[form.package];
  // Discount compares the rep-entered all-in per-user rate against the list
  // per-user rate. That's what the rep and the approver think about ("$4,500
  // vs $7,500 list = 40%") and what drives routing decisions. We don't
  // re-derive a "platform-only" rate by subtracting hosting/credits here --
  // doing so inflates the discount on deals that bundle hosting (e.g. a
  // Standard quote with $100K hosting attached would show 80%+ discount on
  // the same $4,500/user the rep entered).
  const discountPerUser =
    listPrice != null ? listPrice - form.price_per_user : null;
  const discountPct =
    listPrice != null && listPrice > 0 && discountPerUser != null
      ? discountPerUser / listPrice
      : null;

  // ARR = annual sum of recurring fees (same value as total_amount; surfaced
  // separately so reports / blocks can pivot on it).
  // TCV = ARR × contract_months / 12. Sales contracts run in whole months,
  // so we snap day deltas to the nearest month for consistent math
  // (e.g. an 18-month deal = 1.5 × ARR exactly, not 1.49).
  const arr = round2(total);
  const months = computeContractMonths(form.contract_start_date, form.contract_end_date);
  const tcv = months != null ? round2(arr * (months / 12)) : null;

  return {
    platform_fee_total: round2(platformFee),
    credits_commit_total: round2(creditsCommit),
    hosting_fee_total: round2(hosting),
    total_amount: round2(total),
    list_price_per_user: listPrice,
    discount_per_user: discountPerUser != null ? round2(discountPerUser) : null,
    discount_pct: discountPct,
    arr,
    tcv,
    contract_months: months,
  };
}

function computeContractMonths(
  start: string | null | undefined,
  end: string | null | undefined,
): number | null {
  if (!start || !end) return null;
  const s = Date.parse(start);
  const e = Date.parse(end);
  if (Number.isNaN(s) || Number.isNaN(e) || e <= s) return null;
  const days = (e - s) / (24 * 60 * 60 * 1000);
  return Math.round(days / 30.4375); // avg days/month
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
