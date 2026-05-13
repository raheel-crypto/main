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
  "Description",
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
