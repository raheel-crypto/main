export type UserRole = "sales_rep" | "manager" | "admin";

export type CommitmentType =
  | "outbound_volume"
  | "deal_action"
  | "meeting_target"
  | "pipeline_generation"
  | "follow_up";

export type CommitmentStatus = "pending" | "met" | "missed" | "exceeded";

export type ReviewStatus = "draft" | "submitted" | "reviewed";

export type ActivityType =
  | "call"
  | "email"
  | "meeting"
  | "linkedin"
  | "crm_update"
  | "note";

export type ActivitySource =
  | "gong"
  | "nektar"
  | "salesforce"
  | "apollo"
  | "manual";

export interface User {
  id: string;
  auth_id?: string;
  email: string;
  full_name: string;
  role: UserRole;
  manager_id?: string;
  created_at: string;
}

export interface Account {
  id: string;
  external_id?: string;
  source: string;
  name: string;
  domain?: string;
  industry?: string;
  employee_count?: number;
  created_at: string;
}

export interface Deal {
  id: string;
  account_id: string;
  external_id?: string;
  source: string;
  name: string;
  amount?: number;
  stage: string;
  close_date?: string;
  owner_id: string;
  created_at: string;
  updated_at: string;
  account?: Account;
}

export interface ReviewWeek {
  id: string;
  rep_id: string;
  week_start: string;
  status: ReviewStatus;
  manager_notes?: string;
  reviewed_by?: string;
  reviewed_at?: string;
  created_at: string;
  rep?: User;
  commitments?: WeeklyCommitment[];
  focus_accounts?: WeeklyFocusAccount[];
}

export interface WeeklyFocusAccount {
  id: string;
  review_week_id: string;
  account_id: string;
  priority: number;
  notes?: string;
  created_at: string;
  account?: Account;
}

export interface WeeklyCommitment {
  id: string;
  review_week_id: string;
  commitment_type: CommitmentType;
  description: string;
  target_value?: number;
  target_amount?: number;
  deal_id?: string;
  account_id?: string;
  actual_value: number;
  actual_amount: number;
  status: CommitmentStatus;
  created_at: string;
  deal?: Deal;
  account?: Account;
}

export interface Activity {
  id: string;
  external_id?: string;
  source: ActivitySource;
  activity_type: ActivityType;
  rep_id: string;
  account_id?: string;
  deal_id?: string;
  contact_email?: string;
  contact_name?: string;
  direction?: "inbound" | "outbound";
  duration_seconds?: number;
  occurred_at: string;
  metadata: Record<string, unknown>;
  created_at: string;
  account?: Account;
  deal?: Deal;
}

export interface Integration {
  id: string;
  user_id: string;
  provider: ActivitySource;
  status: "pending" | "connected" | "error";
  last_sync_at?: string;
  error_message?: string;
  created_at: string;
}

export interface ReviewComment {
  id: string;
  review_week_id: string;
  user_id: string;
  content: string;
  created_at: string;
  user?: User;
}

// Helper type for commitment display
export const COMMITMENT_TYPE_LABELS: Record<CommitmentType, string> = {
  outbound_volume: "Outbound Volume",
  deal_action: "Deal Action",
  meeting_target: "Meeting Target",
  pipeline_generation: "Pipeline Generation",
  follow_up: "Follow-up Tasks",
};

export const COMMITMENT_TYPE_ICONS: Record<CommitmentType, string> = {
  outbound_volume: "send",
  deal_action: "file-check",
  meeting_target: "calendar",
  pipeline_generation: "trending-up",
  follow_up: "refresh-cw",
};
