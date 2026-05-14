export type Package = "Standard" | "Plus" | "Premium" | "Enterprise";
export type RequestSource = "slack" | "salesforce";
export type ApprovalTier = "auto" | "deal_desk" | "pod_leader" | "james";
export type ApprovalState = "pending" | "approved" | "rejected";

/** Raw fields the rep enters in the Slack modal or LWC form. */
export interface QuoteForm {
  package: Package;
  users: number;
  price_per_user: number;
  total_credits: number;
  /** Display-only — rep-entered. Subset of total_credits given for free. */
  free_credits: number;
  hosting_fee: number;
  pricing_discussed: boolean;
  notes: string;
}

/** Derived monetary breakdown — output of `lib/pricing.ts`. */
export interface PricingBreakdown {
  platform_fee_total: number;
  credits_commit_total: number;
  hosting_fee_total: number;
  total_amount: number;
  /** Null for Enterprise (no list price). */
  list_price_per_user: number | null;
  /** Null for Enterprise. */
  discount_per_user: number | null;
  /** 0–1. Null for Enterprise. */
  discount_pct: number | null;
}

/** Resolved opportunity context from SFDC. */
export interface DealContext {
  account: {
    id: string;
    name: string;
    segment: string | null;
  };
  opportunity: {
    id: string;
    name: string;
    stage: string;
    amount: number | null;
    close_date: string;
    owner_id: string;
    owner_name: string;
    owner_slack_user_id: string | null;
    manager_name: string | null;
    manager_slack_user_id: string | null;
  };
}

export interface Requester {
  source: RequestSource;
  slack_user_id: string;
  slack_user_name: string | null;
  confirmation_channel: string | null;
}

/** Agent output: prose only. Numbers are deterministic, computed elsewhere. */
export interface AgentOutput {
  summary: string;
  flags: string[];
}

/** Routing decision for an approval request. */
export interface ApprovalRouting {
  tier: ApprovalTier;
  /** Slack user IDs allowed to approve/reject. Empty for auto-approved. */
  allowed_approver_ids: string[];
  /** Human label rendered in the message header. */
  tier_label: string;
  /** Reason — e.g. "Discount 32% — Pod Leader approval required". */
  reason: string;
}

/** Persisted approval record (Upstash KV). */
export interface ApprovalRequest {
  request_id: string;
  state: ApprovalState;
  created_at: string;
  decided_at: string | null;
  decided_by_slack_user_id: string | null;
  decided_by_name: string | null;
  routing: ApprovalRouting;
  context: DealContext;
  form: QuoteForm;
  pricing: PricingBreakdown;
  agent: AgentOutput;
  requester: Requester;
  slack_message: {
    channel: string;
    ts: string;
  } | null;
}

export interface ProcessQuoteJob {
  context: DealContext;
  form: QuoteForm;
  requester: Requester;
}

export interface SlashCommandPayload {
  command: string;
  text: string;
  user_id: string;
  user_name: string;
  channel_id: string;
  response_url: string;
  team_id: string;
  trigger_id: string;
}
