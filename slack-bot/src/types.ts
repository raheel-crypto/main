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
  /** @deprecated derived from nooksHost{Positive,Neutral,Negative} — true if any is on. */
  nooksRealtimeEnabled: boolean;
  /** @deprecated derived from nooksFirehose{Positive,Neutral,Negative} — true if any is on. */
  nooksFirehoseEnabled: boolean;
  nooksHostPositive: boolean;
  nooksHostNeutral: boolean;
  nooksHostNegative: boolean;
  nooksFirehosePositive: boolean;
  nooksFirehoseNeutral: boolean;
  nooksFirehoseNegative: boolean;
  calendarPreEnabled: boolean;
  calendarPostEnabled: boolean;
  redTeamEnabled: boolean;
}

export type NooksDispositionBucket = "positive" | "neutral" | "negative";

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
  "Notes__c",
  "Deal_Description__c",
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

export type PendingCardKind =
  | "standup"
  | "brief"
  | "buy_signal"
  | "post_meeting"
  | "meeting_picker"
  | "qa_proposal"
  | "record_proposal"
  | "bulk_record_proposal"
  | "notion_sync";

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

export interface PostMeetingMatchedContact {
  id: string;
  name: string | null;
  email: string;
  title: string | null;
}

export interface PostMeetingUnmatchedAttendee {
  email: string;
  displayName: string | null;
  domain: string;
}

export interface PostMeetingOpportunity {
  id: string;
  name: string;
  stage: string;
  amount: number | null;
  closeDate: string | null;
  nextStep: string | null;
}

export interface PostMeetingPayload {
  gcalEventId: string;
  eventTitle: string;
  startIso: string | null;
  endIso: string | null;
  accountId: string;
  accountName: string;
  matchedContacts: PostMeetingMatchedContact[];
  unmatchedAttendees: PostMeetingUnmatchedAttendee[];
  openOpportunities: PostMeetingOpportunity[];
}

export interface PostMeetingPendingCard extends PendingCardBase {
  kind: "post_meeting";
  opportunityId: null;
  recommendation: PostMeetingPayload;
}

export interface MeetingPickerCandidate {
  id: string;
  name: string;
  reason: string;
}

export interface MeetingPickerPayload {
  kind: "meeting_picker";
  gcalEventId: string;
  eventTitle: string;
  startIso: string | null;
  externalEmails: string[];
  externalDomains: string[];
  candidates: MeetingPickerCandidate[];
}

export interface MeetingPickerPendingCard extends PendingCardBase {
  kind: "meeting_picker";
  opportunityId: null;
  recommendation: MeetingPickerPayload;
}

export interface QaProposalPendingCard extends PendingCardBase {
  kind: "qa_proposal";
  opportunityId: string;
  recommendation: Recommendation;
}

export type ProposedFieldType =
  | "string"
  | "textarea"
  | "picklist"
  | "multipicklist"
  | "date"
  | "datetime"
  | "currency"
  | "double"
  | "int"
  | "percent"
  | "boolean"
  | "reference"
  | "id"
  | "email"
  | "phone"
  | "url";

export interface ProposedField {
  field: string;
  fieldLabel: string;
  fieldType: ProposedFieldType;
  currentValue: string | number | boolean | null;
  recommendedValue: string | number | boolean | null;
  currentDisplay?: string | null;
  recommendedDisplay?: string | null;
  referenceTo?: string;
  picklistValues?: string[];
  rationale: string;
}

export interface RecordUpdateProposal {
  sobjectType: string;
  recordId: string;
  recordName: string;
  contextLabel: string;
  recap: string;
  fields: ProposedField[];
}

export interface RecordProposalPendingCard extends PendingCardBase {
  kind: "record_proposal";
  opportunityId: string | null;
  recommendation: RecordUpdateProposal;
}

export interface SfApplyError {
  statusCode: string;
  message: string;
  fields: string[];
}

export interface BulkRecordSummary {
  recordId: string;
  recordName: string;
  contextLabel?: string;
  currentValues: Record<string, string | number | boolean | null>;
}

export interface BulkRecordUpdateProposal {
  sobjectType: string;
  recordSummaries: BulkRecordSummary[];
  fields: ProposedField[];
  recap: string;
  excludedRecordIds: string[];
  confirmed: boolean;
  instanceUrl: string;
}

export interface BulkRecordProposalPendingCard extends PendingCardBase {
  kind: "bulk_record_proposal";
  opportunityId: null;
  recommendation: BulkRecordUpdateProposal;
}

export type PendingCard =
  | StandupPendingCard
  | BriefPendingCard
  | BuySignalPendingCard
  | PostMeetingPendingCard
  | MeetingPickerPendingCard
  | QaProposalPendingCard
  | RecordProposalPendingCard
  | BulkRecordProposalPendingCard;

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
  | "meeting_picker_surfaced"
  | "qa_proposed_update"
  | "qa_propose_failed"
  | "gong_post_call_surfaced"
  | "gong_post_call_dropped"
  | "record_proposed_update"
  | "record_apply_failed"
  | "record_applied"
  | "bulk_record_proposed"
  | "bulk_record_excluded"
  | "bulk_record_apply_confirmed"
  | "bulk_record_applied"
  | "bulk_record_apply_failed"
  | "red_team_intel_surfaced"
  | "red_team_intel_dropped"
  | "red_team_intel_failed"
  | "red_team_eval_shadow"
  | "notion_synced"
  | "notion_sync_dropped";

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

export const BriefRecentWinSchema = z.object({
  id: z.string(),
  name: z.string(),
  amount: z.number().nullable().optional(),
  closedDate: z.string().nullable().optional(),
  type: z.string().nullable().optional(),
});

const FlatMetricValue = z.union([z.string(), z.number()]);
const TrajectoryMetricValue = z.object({
  mean: FlatMetricValue.nullable().optional(),
  min: FlatMetricValue.nullable().optional(),
  max: FlatMetricValue.nullable().optional(),
  trajectory: z.string().nullable().optional(),
});
const MetricValue = z.union([FlatMetricValue, TrajectoryMetricValue]);

export const BriefUsageMetricsSchema = z
  .object({
    dauWau: MetricValue.nullable().optional(),
    wauEnrolled: MetricValue.nullable().optional(),
    queriesPerUser: MetricValue.nullable().optional(),
    enrolledUsers: FlatMetricValue.nullable().optional(),
    // Aliases kept so older pending_cards rows still parse.
    wauMau: MetricValue.nullable().optional(),
    dauWauL28d: MetricValue.nullable().optional(),
  })
  .passthrough();

export const BriefUsageSchema = z.object({
  status: z
    .enum(["customer", "prospect", "no_data", "unknown"])
    .nullable()
    .optional(),
  metrics: BriefUsageMetricsSchema.nullable().optional(),
  commentary: z.string().nullable().optional(),
});

export const BriefPayloadSchema = z.object({
  accountId: z.string(),
  accountName: z.string(),
  accountOwner: z.string().nullable().optional(),
  accountWebsite: z.string().nullable().optional(),
  snapshot: z.string(),
  recentCalls: z.array(BriefCallSchema).default([]),
  recentActivities: z.array(BriefActivitySchema).default([]),
  openOpportunities: z.array(BriefOpportunitySchema).default([]),
  recentWins: z.array(BriefRecentWinSchema).default([]),
  usageTrend: z.string().nullable().optional(),
  usage: BriefUsageSchema.nullable().optional(),
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
export type BriefUsage = z.infer<typeof BriefUsageSchema>;
export type BriefUsageMetrics = z.infer<typeof BriefUsageMetricsSchema>;
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

// ─────────────────────────────────────────────────────────────────────────────
// Red Team agent — Merlin sends an OpportunityContext to a separate Python
// service that role-plays adversaries; service returns structured arguments
// Merlin renders and DMs.

export type RedTeamTriggerEvent =
  | "gong_call"
  | "daily_sweep"
  | "stage_advance"
  | "manual";

export interface RedTeamGongTranscriptSegment {
  speakerId: string | null;
  speakerName: string | null;
  speakerAffiliation: "Internal" | "External" | "Unknown" | string | null;
  text: string;
  startSec: number | null;
  endSec: number | null;
}

export interface RedTeamGongCall {
  callId: string;
  title: string | null;
  startedAt: string | null;
  durationSec: number | null;
  url: string | null;
  parties: {
    name: string | null;
    email: string | null;
    affiliation: string | null;
    title: string | null;
  }[];
  brief: string | null;
  transcript: { speakerSegments: RedTeamGongTranscriptSegment[] } | null;
}

export interface RedTeamFieldChange {
  field: string;
  oldValue: string | number | boolean | null;
  newValue: string | number | boolean | null;
  changedAt: string;
  source: "field_history" | "snapshot_diff";
}

export interface RedTeamActivity {
  type: "Task" | "Event";
  subject: string;
  activityDate: string | null;
  description: string | null;
}

export interface RedTeamIntelPackRequest {
  schemaVersion: "1";
  opportunity: {
    id: string;
    name: string;
    stageName: string;
    type: string | null;
    amount: number | null;
    closeDate: string | null;
    nextStep: string | null;
    ownerId: string;
    accountId: string;
    accountName: string;
    isRenewal: boolean;
    customFields: Record<string, unknown>;
  };
  owner: {
    sfUserId: string | null;
    name: string | null;
    email: string | null;
    slackUserId: string;
  };
  account: {
    id: string;
    name: string;
    industry: string | null;
    website: string | null;
  };
  recentFieldChanges: RedTeamFieldChange[];
  gongCalls: RedTeamGongCall[];
  activities: RedTeamActivity[];
  triggerEvent: RedTeamTriggerEvent;
  triggerMetadata: {
    callId?: string;
    previousStage?: string;
  };
  shadowMode: boolean;
}

export interface RedTeamCitation {
  sourceType:
    | "dead_deal"
    | "gong_quote"
    | "objection_quote"
    | "competitor_profile"
    | "field_change"
    | "other";
  quote: string;
  sourceLabel: string;
  sourceUrl?: string | null;
}

export interface RedTeamClaim {
  statement: string;
  patternMatch?: string | null;
  citations: RedTeamCitation[];
}

export interface RedTeamRecommendedAction {
  action: string;
  ownerRole: string;
  byDate: string;
  expectedSignal: string;
}

export interface RedTeamPersonaArgument {
  persona: string;
  headline: string;
  riskScore: number;
  claims: RedTeamClaim[];
  recommendedActions: RedTeamRecommendedAction[];
}

export const RedTeamCitationSchema = z.object({
  sourceType: z
    .enum([
      "dead_deal",
      "gong_quote",
      "objection_quote",
      "competitor_profile",
      "field_change",
      "other",
    ])
    .default("other"),
  quote: z.string().min(1),
  sourceLabel: z.string().min(1),
  sourceUrl: z.string().nullable().optional(),
});

export const RedTeamClaimSchema = z.object({
  statement: z.string().min(1),
  patternMatch: z.string().nullable().optional(),
  citations: z.array(RedTeamCitationSchema).default([]),
});

export const RedTeamRecommendedActionSchema = z.object({
  action: z.string().min(1),
  ownerRole: z.string().default(""),
  byDate: z.string().default(""),
  expectedSignal: z.string().default(""),
});

export const RedTeamPersonaArgumentSchema = z.object({
  persona: z.string().min(1),
  headline: z.string().min(1),
  riskScore: z.number().min(0).max(1).default(0),
  claims: z.array(RedTeamClaimSchema).default([]),
  recommendedActions: z.array(RedTeamRecommendedActionSchema).default([]),
});

export const RedTeamRunResultSchema = z.object({
  evaluatedAt: z.string(),
  shadowMode: z.boolean().default(false),
  firedTriggers: z.array(z.string()).default([]),
  personasInvoked: z.array(RedTeamPersonaArgumentSchema).default([]),
  auditLogEntry: z.string().default(""),
  cooldownUntilIso: z.string().nullable().optional(),
  dropReason: z.string().nullable().optional(),
});

export type RedTeamRunResult = z.infer<typeof RedTeamRunResultSchema>;
