import type { Package, PricingBreakdown, QuoteForm } from "./types.js";

const CREDIT_COMMIT_RATE = 0.02;

export const PACKAGE_LIST_PRICE: Record<Package, number | null> = {
  Standard: 6000,
  Plus: 8000,
  Premium: 10000,
  Enterprise: null,
};

export function calculatePricing(form: QuoteForm): PricingBreakdown {
  const platformFeeRaw = form.price_per_user * form.users;
  const creditsCommit = form.total_credits * CREDIT_COMMIT_RATE;
  const platformFee = platformFeeRaw - creditsCommit;
  const hosting = form.hosting_fee;
  const total = platformFee + creditsCommit + hosting;

  const listPrice = PACKAGE_LIST_PRICE[form.package];
  const discountPerUser = listPrice != null ? listPrice - form.price_per_user : null;
  const discountPct =
    listPrice != null && listPrice > 0 && discountPerUser != null
      ? discountPerUser / listPrice
      : null;

  return {
    platform_fee_total: round2(platformFee),
    credits_commit_total: round2(creditsCommit),
    hosting_fee_total: round2(hosting),
    total_amount: round2(total),
    list_price_per_user: listPrice,
    discount_per_user: discountPerUser != null ? round2(discountPerUser) : null,
    discount_pct: discountPct,
  };
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
