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
  gongRealtimeEnabled: boolean;
  gongFirehoseEnabled: boolean;
  nooksRealtimeEnabled: boolean;
  nooksFirehoseEnabled: boolean;
  calendarPreEnabled: boolean;
  calendarPostEnabled: boolean;
}

export interface GcTokens {
  slackUserId: string;
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
  googleEmail: string | null;
}

export interface GcalAttendee {
  email: string;
  displayName?: string | null;
  responseStatus?: string | null;
  organizer?: boolean | null;
  self?: boolean | null;
  resource?: boolean | null;
  optional?: boolean | null;
}

export interface GcalEvent {
  id: string;
  status?: string | null;
  summary?: string | null;
  description?: string | null;
  start?: { dateTime?: string | null; date?: string | null; timeZone?: string | null };
  end?: { dateTime?: string | null; date?: string | null; timeZone?: string | null };
  organizer?: { email?: string | null; displayName?: string | null; self?: boolean | null };
  attendees?: GcalAttendee[];
  htmlLink?: string | null;
  hangoutLink?: string | null;
  conferenceData?: { conferenceId?: string | null };
}

export interface MeetingRun {
  id: string;
  slackUserId: string;
  gcalEventId: string;
  phase: "pre" | "post" | "picker";
  accountIdResolved: string | null;
  firedAt: string;
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

export type PendingCardKind = "standup" | "brief" | "buy_signal";

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

export interface BuySignalPendingCard extends PendingCardBase {
  kind: "buy_signal";
  opportunityId: null;
  recommendation: BuySignalPayload;
}

export type PendingCard =
  | StandupPendingCard
  | BriefPendingCard
  | BuySignalPendingCard;

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
  | "qa_failed"
  | "buy_signal_surfaced"
  | "buy_signal_dropped"
  | "opportunity_created"
  | "opportunity_create_failed"
  | "task_created"
  | "task_create_failed"
  | "gong_realtime_surfaced"
  | "gong_realtime_dropped"
  | "nooks_realtime_surfaced"
  | "nooks_realtime_dropped"
  | "contact_created"
  | "contact_create_failed"
  | "meeting_briefed"
  | "meeting_brief_failed"
  | "meeting_post_surfaced"
  | "meeting_picker_surfaced";

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

export interface NooksUserData {
  userId?: string;
  email?: string;
  name?: string;
}

export interface NooksProspectData {
  prospectId?: string;
  name?: string;
  phoneNumber?: string;
  email?: string;
  linkedInUrl?: string;
}

export interface NooksAccountData {
  accountId?: string;
  name?: string;
}

export interface NooksDisposition {
  id?: string;
  name?: string;
}

export interface NooksSequenceData {
  sequenceName?: string;
  sequenceStep?: string;
}

export interface NooksCallData {
  callId: string;
  workspaceId?: string;
  userData?: NooksUserData;
  prospectData?: NooksProspectData;
  accountData?: NooksAccountData;
  callDirection?: string;
  status?: string;
  disposition?: NooksDisposition;
  startedAt?: string;
  durationSeconds?: number;
  recordingUrl?: string;
  notes?: string;
  transcriptUrl?: string;
  sequenceData?: NooksSequenceData;
}

export interface NooksWebhookPayload {
  event: string;
  eventId: string;
  occurredAt?: string;
  callData: NooksCallData;
}

export interface GongWebhookParty {
  id?: string | null;
  name?: string | null;
  emailAddress?: string | null;
  userId?: string | null;
  speakerId?: string | null;
  title?: string | null;
  affiliation?: "Internal" | "External" | "Unknown" | string | null;
  methods?: string[] | null;
  phoneNumber?: string | null;
}

export interface GongWebhookMetaData {
  id: string;
  url?: string | null;
  title?: string | null;
  started?: string | null;
  scheduled?: string | null;
  duration?: number | null;
  primaryUserId?: string | null;
  direction?: string | null;
  scope?: string | null;
  language?: string | null;
  workspaceId?: string | null;
}

export interface GongContextField {
  name: string;
  value: unknown;
}

export interface GongContextObject {
  objectType: string;
  objectId: string;
  fields?: GongContextField[] | null;
  timing?: string | null;
}

export interface GongContextBlock {
  system: string;
  objects?: GongContextObject[] | null;
}

export interface GongContentTopic {
  name: string;
  duration?: number | null;
}

export interface GongWebhookCallData {
  metaData: GongWebhookMetaData;
  parties?: GongWebhookParty[] | null;
  context?: GongContextBlock[] | null;
  content?: { topics?: GongContentTopic[] | null; [key: string]: unknown } | null;
  [key: string]: unknown;
}

export interface GongWebhookPayload {
  callData: GongWebhookCallData;
  isTest?: boolean | null;
  isPrivate?: boolean | null;
  [key: string]: unknown;
}

export const GongCallInsightSchema = z.object({
  summary: z.string(),
  positives: z.array(z.string()).default([]),
  negatives: z.array(z.string()).default([]),
  nextSteps: z.array(z.string()).default([]),
});
export type GongCallInsight = z.infer<typeof GongCallInsightSchema>;

export interface PositiveApolloCall {
  taskId: string;
  accountId: string;
  ownerId: string;
  ownerName: string | null;
  subject: string;
  activityDate: string | null;
  createdDate: string | null;
  description: string | null;
}

const BUY_SIGNAL_ACTION_KINDS = [
  "create_opportunity",
  "log_task",
  "no_action",
] as const;

export const BuySignalSuggestedOppSchema = z.object({
  name: z.string().min(1),
  stage: z.string().min(1),
  amount: z.number().nullable().optional(),
  closeDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});

export const BuySignalSuggestedTaskSchema = z.object({
  subject: z.string().min(1),
  dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  description: z.string().nullable().optional(),
});

export const BuySignalRecommendationSchema = z.object({
  headline: z.string().min(1),
  suggestedAction: z.enum(BUY_SIGNAL_ACTION_KINDS),
  suggestedOpp: BuySignalSuggestedOppSchema.nullable().optional(),
  suggestedTask: BuySignalSuggestedTaskSchema.nullable().optional(),
  rationale: z.string().min(1),
});

export const BuySignalCallSummarySchema = z.object({
  taskId: z.string(),
  ownerName: z.string().nullable().optional(),
  activityDate: z.string().nullable().optional(),
  subject: z.string(),
  description: z.string().nullable().optional(),
});

export const BuySignalPayloadSchema = z.object({
  accountId: z.string(),
  accountName: z.string(),
  callCount: z.number().int().nonnegative(),
  mostRecentCallDate: z.string().nullable().optional(),
  calls: z.array(BuySignalCallSummarySchema).default([]),
  headline: z.string(),
  suggestedAction: z.enum(BUY_SIGNAL_ACTION_KINDS),
  suggestedOpp: BuySignalSuggestedOppSchema.nullable().optional(),
  suggestedTask: BuySignalSuggestedTaskSchema.nullable().optional(),
  rationale: z.string(),
});

export type BuySignalSuggestedOpp = z.infer<typeof BuySignalSuggestedOppSchema>;
export type BuySignalSuggestedTask = z.infer<typeof BuySignalSuggestedTaskSchema>;
export type BuySignalRecommendation = z.infer<
  typeof BuySignalRecommendationSchema
>;
export type BuySignalPayload = z.infer<typeof BuySignalPayloadSchema>;
export type BuySignalActionKind = (typeof BUY_SIGNAL_ACTION_KINDS)[number];
