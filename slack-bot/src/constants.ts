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

export const RED_TEAM_HTTP_TIMEOUT_MS = 280_000;
export const RED_TEAM_FIELD_HISTORY_LOOKBACK_DAYS = 30;
export const RED_TEAM_GONG_CALL_LIMIT = 5;
export const RED_TEAM_ACTIVITY_LIMIT = 25;
export const RED_TEAM_TRANSCRIPT_SEGMENT_LIMIT = 400;
export const RED_TEAM_SWEEP_CONCURRENCY = 3;
export const RED_TEAM_DEFAULT_OPP_FIELDS = [
  // MEDDPICC evidence text fields (Rogo SF: <Dim>_Evidence__c;
  // Pain follows the Implicate_<Dim>_Evidence__c convention)
  "Notes__c",
  "Deal_Description__c",
  "Champion_Evidence__c",
  "Economic_Buyer_Evidence__c",
  "Decision_Criteria_Evidence__c",
  "Decision_Process_Evidence__c",
  "Paper_Process_Evidence__c",
  "Implicate_Pain_Evidence__c",
  "Competition_Evidence__c",
  "Metrics_Evidence__c",
  // MEDDPICC scores — triggers.yaml field_threshold rules key off these
  "Overall_Score__c",
  "Champion_Score__c",
  "Competition_Score__c",
  "Decision_Process_Score__c",
  "Decision_Criteria_Score__c",
  "Economic_Buyer_Score__c",
  "Paper_Process_Score__c",
  "Implicate_Pain_Score__c",
  "Metrics_Score__c",
  // Strategic fields used for trigger gates + intel-pack retrieval
  "Final_Competitor__c",
  "Segment__c",
  "Business_Type__c",
  "ForecastCategoryName",
  "Last_Touch_With_Decision_Maker__c",
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
