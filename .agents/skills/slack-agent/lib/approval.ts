import type { ApprovalRouting, DealContext, PricingBreakdown, QuoteForm } from "./types.js";

const TIER_BOUNDS = {
  DEAL_DESK_LOW: 0.15,
  POD_LEADER_LOW: 0.25,
  JAMES_LOW: 0.4,
} as const;

/**
 * Decide who can approve this quote.
 *
 * Rules:
 * - Enterprise package → Pod Leader (Opp.Owner.Manager). James countersigns ENT
 *   order forms at the end of the day, so we don't double-route through him here.
 * - discount < 15% → auto-approved, posts to deal desk channel for visibility only.
 * - 15% ≤ discount < 25% → any of the three Deal Desk (RevOps) approvers.
 * - 25% ≤ discount < 40% → Pod Leader.
 * - discount ≥ 40% → James OR any of the three RevOps approvers (escalation
 *   shouldn't block on one person's availability).
 *
 * Approvals are FINAL at each tier — no further escalation.
 */
export function routeApproval(
  form: QuoteForm,
  pricing: PricingBreakdown,
  context: DealContext,
): ApprovalRouting {
  const revops = parseCsvEnv(process.env.DEAL_DESK_APPROVER_IDS);
  const james = process.env.JAMES_SLACK_USER_ID?.trim();

  if (form.package === "Enterprise") {
    const podLeaderId = context.opportunity.manager_slack_user_id;
    const podLeaderName = context.opportunity.manager_name ?? "Pod Leader";
    return {
      tier: "pod_leader",
      allowed_approver_ids: podLeaderId ? [podLeaderId] : [],
      tier_label: `Enterprise package — ${podLeaderName} approval required`,
      reason: "Enterprise package always routes to Pod Leader",
    };
  }

  const pct = pricing.discount_pct;
  if (pct == null || pct < TIER_BOUNDS.DEAL_DESK_LOW) {
    return {
      tier: "auto",
      allowed_approver_ids: [],
      tier_label: "Auto-approved",
      reason:
        pct == null
          ? "No discount applicable"
          : `Discount ${formatPct(pct)} below 15% threshold`,
    };
  }

  if (pct < TIER_BOUNDS.POD_LEADER_LOW) {
    return {
      tier: "deal_desk",
      allowed_approver_ids: revops,
      tier_label: `Discount ${formatPct(pct)} — Deal Desk approval required`,
      reason: "Discount between 15% and 25% — any RevOps approver",
    };
  }

  if (pct < TIER_BOUNDS.JAMES_LOW) {
    const podLeaderId = context.opportunity.manager_slack_user_id;
    const podLeaderName = context.opportunity.manager_name ?? "Pod Leader";
    return {
      tier: "pod_leader",
      allowed_approver_ids: podLeaderId ? [podLeaderId] : [],
      tier_label: `Discount ${formatPct(pct)} — ${podLeaderName} approval required`,
      reason: "Discount between 25% and 40% — Opp Owner's Manager",
    };
  }

  const allowed = [...(james ? [james] : []), ...revops];
  return {
    tier: "james",
    allowed_approver_ids: allowed,
    tier_label: `Discount ${formatPct(pct)} — James or Deal Desk approval required`,
    reason: "Discount ≥ 40% — James or any RevOps approver",
  };
}

/** Server-side check: is this Slack user allowed to act on this request? */
export function isAuthorizedApprover(
  routing: ApprovalRouting,
  slackUserId: string,
): boolean {
  return routing.allowed_approver_ids.includes(slackUserId);
}

function parseCsvEnv(v: string | undefined): string[] {
  if (!v) return [];
  return v
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function formatPct(pct: number): string {
  return `${(pct * 100).toFixed(1)}%`;
}
