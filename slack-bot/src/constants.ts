export const MODEL = "claude-sonnet-4-20250514";
export const INSIGHTS_MODEL = "claude-haiku-4-5-20251001";
export const INSIGHTS_MAX_TOKENS = 1024;
export const RECOMMENDER_MAX_TOKENS = 4096;
export const MAX_TOOL_ITERATIONS = 10;
export const RECOMMENDER_CONCURRENCY = 3;
export const STANDUP_TIMEOUT_BUDGET_MS = 270_000;

export const BUY_SIGNAL_LOOKBACK_DAYS = 7;
export const BUY_SIGNAL_DEDUP_DAYS = 7;
export const BUY_SIGNAL_MAX_CARDS_PER_RUN = 5;
export const BUY_SIGNAL_SUBJECT_PATTERN = "%[Apollo]%Connected - Positive%";

export const RED_TEAM_HTTP_TIMEOUT_MS = 90_000;
export const RED_TEAM_FIELD_HISTORY_LOOKBACK_DAYS = 30;
export const RED_TEAM_GONG_CALL_LIMIT = 5;
export const RED_TEAM_ACTIVITY_LIMIT = 25;
export const RED_TEAM_TRANSCRIPT_SEGMENT_LIMIT = 400;
export const RED_TEAM_SWEEP_CONCURRENCY = 3;
export const RED_TEAM_DEFAULT_OPP_FIELDS = [
  "Notes__c",
  "Deal_Description__c",
  "Champion__c",
  "Economic_Buyer__c",
  "Decision_Criteria__c",
  "Pain__c",
  "Competition__c",
] as const;

export const NOOKS_FILTER_DIRECTION = "outbound";
export const NOOKS_FILTER_DISPOSITIONS = [
  "Connected - Positive",
  "Connected - Neutral",
  "Connected - Negative",
];
export const TZ_OPTIONS = [
  "America/Los_Angeles",
  "America/Denver",
  "America/Chicago",
  "America/New_York",
  "Europe/London",
  "Europe/Berlin",
  "Asia/Singapore",
  "Asia/Tokyo",
  "Australia/Sydney",
];
