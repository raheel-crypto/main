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
  // Discount math compares the customer's effective platform-only per-seat
  // rate against the platform-only list price. Subtract hosting + credits
  // out of the per-user total before comparing, so a discount stays
  // platform-vs-platform even on deals that carry hosting.
  const effectivePlatformPerUser =
    form.users > 0 ? platformFee / form.users : null;
  const discountPerUser =
    listPrice != null && effectivePlatformPerUser != null
      ? listPrice - effectivePlatformPerUser
      : null;
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
