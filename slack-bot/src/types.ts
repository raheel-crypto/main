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

export type PendingCardKind = "standup" | "brief";

export interface PendingCardBase {
  id: string;
  slackUserId: string;
  slackChannel: string;
  slackThreadTs: string;
  slackMessageTs: string;
  status: "open" | "applied" | "partial" | "skipped" | "expired";
}

export interface StandupPendingCard extends PendingCardBase {
  kind: "standup";
  opportunityId: string;
  recommendation: Recommendation;
}

export interface BriefPendingCard extends PendingCardBase {
  kind: "brief";
  opportunityId: string | null;
  recommendation: BriefPayload;
}

export type PendingCard = StandupPendingCard | BriefPendingCard;

export type AuditAction =
  | "recommended"
  | "accepted"
  | "edited"
  | "skipped"
  | "applied"
  | "apply_failed"
  | "recommend_failed"
  | "briefed"
  | "brief_failed"
  | "qa_answered"
  | "qa_failed";

const BRIEF_SUGGESTION_KINDS = [
  "update_next_step",
  "update_close_date",
  "update_stage",
  "update_amount",
] as const;

export const BriefSuggestionSchema = z.object({
  kind: z.enum(BRIEF_SUGGESTION_KINDS),
  opportunityId: z.string(),
  value: z.union([z.string(), z.number()]),
  reasoning: z.string().min(1),
});

export const BriefCallSchema = z.object({
  id: z.string(),
  title: z.string(),
  startedAt: z.string(),
  brief: z.string().nullable().optional(),
  callUrl: z.string().nullable().optional(),
});

export const BriefActivitySchema = z.object({
  type: z.string(),
  subject: z.string(),
  when: z.string().nullable().optional(),
  who: z.string().nullable().optional(),
});

export const BriefOpportunitySchema = z.object({
  id: z.string(),
  name: z.string(),
  stage: z.string(),
  amount: z.number().nullable().optional(),
  closeDate: z.string().nullable().optional(),
  lastStageChangeDate: z.string().nullable().optional(),
});

export const BriefPayloadSchema = z.object({
  accountId: z.string(),
  accountName: z.string(),
  snapshot: z.string(),
  recentCalls: z.array(BriefCallSchema).default([]),
  recentActivities: z.array(BriefActivitySchema).default([]),
  openOpportunities: z.array(BriefOpportunitySchema).default([]),
  usageTrend: z.string().nullable().optional(),
  talkingPoints: z.array(z.string()).default([]),
  suggestedActions: z.array(BriefSuggestionSchema).default([]),
});

export const BriefDisambiguateSchema = z.object({
  kind: z.literal("disambiguate"),
  candidates: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      industry: z.string().nullable().optional(),
      ownerName: z.string().nullable().optional(),
    })
  ),
});

export type BriefPayload = z.infer<typeof BriefPayloadSchema>;
export type BriefSuggestion = z.infer<typeof BriefSuggestionSchema>;
export type BriefSuggestionKind = (typeof BRIEF_SUGGESTION_KINDS)[number];
export type BriefDisambiguate = z.infer<typeof BriefDisambiguateSchema>;

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
