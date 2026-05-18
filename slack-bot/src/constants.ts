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
