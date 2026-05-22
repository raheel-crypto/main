export type Package = "Standard" | "Premium" | "Enterprise";
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
  /** ISO date string YYYY-MM-DD. */
  contract_start_date: string;
  /** ISO date string YYYY-MM-DD. */
  contract_end_date: string;
  notes: string;
  /**
   * Pre-approved legal terms the rep attached to this deal. Resolved from
   * the SFDC Legal_Term__c library at submit time and snapshotted here so
   * legal can't change wording between submit and approval. Defaults to
   * empty when the rep selects nothing or the field is missing (Slack modal,
   * older approvals deserialized from KV).
   */
  selected_terms: SelectedTerm[];
}

/**
 * A pre-approved legal clause attached to a quote. Snapshotted from
 * Legal_Term__c at submit time — `body` is the verbatim text rendered into
 * the order form, immune to mid-flight edits in SFDC.
 */
export interface SelectedTerm {
  /** Stable code from Legal_Term__c.Term_Code__c (e.g. "PAY_NET_90"). */
  term_code: string;
  /** SFDC Id, for drill-back / audit. */
  sfdc_id: string;
  title: string;
  body: string;
  category: string;
  /** Minimum approval tier this term requires, regardless of discount. */
  required_tier: ApprovalTier;
  /** Stable rendering order from Legal_Term__c.Sort_Order__c. */
  sort_order: number;
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
  /**
   * Annual Recurring Revenue. Same value as total_amount; surfaced as a
   * named field so reports can pivot on it.
   */
  arr: number | null;
  /**
   * Total Contract Value = ARR × (contract months / 12).
   * Null if contract dates aren't supplied or are invalid.
   */
  tcv: number | null;
  /** Whole-month contract term derived from start/end dates. Null if invalid. */
  contract_months: number | null;
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
    /** Opportunity.Type picklist value (e.g. "New Business"). Used to pick
     *  the right order form template. */
    type: string | null;
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
  /** Optional list of Term_Code__c values the rep selected in the LWC.
   *  The processor hydrates these into form.selected_terms via SOQL so
   *  the snapshot is authoritative — the LWC never sends term bodies. */
  selected_term_codes?: string[];
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
