import { z } from "zod";

export interface UserPrefs {
  slackUserId: string;
  slackTeamId: string;
  email: string;
  timezone: string;
  preferredHour: number;
  preferredMinute: number;
  lastRunDate: string | null;
  active: boolean;
}

export interface SfTokens {
  slackUserId: string;
  accessToken: string;
  refreshToken: string;
  instanceUrl: string;
  sfUserId: string | null;
  sfUserEmail: string | null;
  environment: "production" | "sandbox";
}

export interface GongCall {
  id: string;
  title: string;
  startedAt: string;
  durationSeconds: number;
  participants: string[];
  brief: string | null;
  callUrl: string | null;
}

export interface SfActivity {
  id: string;
  type: "Task" | "Event";
  subject: string;
  activityDate: string | null;
  description: string | null;
}

export interface SfOpportunity {
  id: string;
  name: string;
  accountId: string;
  accountName: string;
  stageName: string;
  amount: number | null;
  closeDate: string;
  nextStep: string | null;
  ownerId: string;
  lastStageChangeDate: string | null;
}

export interface UsageRow {
  accountId: string;
  metric: string;
  value: number;
  asOf: string;
}

export interface OppContext {
  opp: SfOpportunity;
  activities: SfActivity[];
  calls: GongCall[];
  usage: UsageRow[];
  picklistOptions: { stage: string[] };
}

const SF_WRITABLE_FIELDS = [
  "StageName",
  "NextStep",
  "Amount",
  "CloseDate",
] as const;

export const RecommendedFieldSchema = z.object({
  field: z.enum(SF_WRITABLE_FIELDS),
  currentValue: z.union([z.string(), z.number(), z.null()]),
  recommendedValue: z.union([z.string(), z.number(), z.null()]),
  rationale: z.string().min(1),
});

export const RecommendationSchema = z.object({
  opportunityId: z.string(),
  recap: z.string(),
  fields: z.array(RecommendedFieldSchema),
});

export type RecommendedField = z.infer<typeof RecommendedFieldSchema>;
export type Recommendation = z.infer<typeof RecommendationSchema>;

export interface PendingCard {
  id: string;
  slackUserId: string;
  slackChannel: string;
  slackThreadTs: string;
  slackMessageTs: string;
  opportunityId: string;
  recommendation: Recommendation;
  status: "open" | "applied" | "partial" | "skipped" | "expired";
}

export type AuditAction =
  | "recommended"
  | "accepted"
  | "edited"
  | "skipped"
  | "applied"
  | "apply_failed"
  | "recommend_failed";

export type RogoCustomer = Record<string, unknown>;

export interface RogoBootstrap {
  contract_version?: string;
  generated_at?: string;
  database?: string;
  available_schemas?: string[];
  data_model_doc?: {
    content_md?: string;
    content_sha256?: string;
    bytes?: number;
  };
  customer_directory?: {
    rows: RogoCustomer[];
    row_count?: number;
    refreshed_at?: string;
    content_sha256?: string;
  };
  guardrails?: {
    max_result_rows?: number;
    query_timeout_seconds?: number;
  };
  endpoints?: Record<string, unknown>;
}

export interface RogoQueryResult {
  status?: string;
  columns: string[];
  column_types?: string[];
  rows: unknown[][];
  row_count: number;
  truncated?: boolean;
  echo?: { sql: string; sha256?: string };
  warnings?: string[];
}

export interface RogoBatchDataset {
  id: string;
  sql: string;
  expected_columns?: string[];
  label?: string;
  max_rows?: number;
}

export interface RogoBatchResultDataset {
  id: string;
  status: "ok" | "error";
  columns?: string[];
  column_types?: string[];
  rows?: unknown[][];
  row_count?: number;
  truncated?: boolean;
  echo?: { sql: string; sha256?: string };
  error?: {
    status: string;
    code: string;
    message: string;
    retryable: boolean;
    details?: Record<string, unknown>;
  };
}

export interface RogoBatchResult {
  batch_id?: string;
  generated_at?: string;
  status: "ok" | "partial_success" | "failed";
  datasets: RogoBatchResultDataset[];
  warnings?: string[];
}
