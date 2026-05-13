import "dotenv/config";

function required(key: string): string {
  const v = process.env[key];
  if (!v) throw new Error(`Missing required env var: ${key}`);
  return v;
}

function optional(key: string, fallback = ""): string {
  return process.env[key] ?? fallback;
}

export const config = {
  publicUrl: optional("STANDUP_PUBLIC_URL", "http://localhost:3002"),
  internalSecret: optional("STANDUP_INTERNAL_SECRET", "dev-internal-secret"),
  oauthStateSecret: optional("STANDUP_OAUTH_STATE_SECRET", "dev-state-secret"),
  dryRun: optional("STANDUP_DRY_RUN", "false") === "true",
  defaultTimezone: optional("STANDUP_DEFAULT_TIMEZONE", "America/Los_Angeles"),
  defaultHour: parseInt(optional("STANDUP_DEFAULT_HOUR", "16"), 10),
  slack: {
    botToken: optional("SLACK_BOT_TOKEN"),
    signingSecret: optional("SLACK_SIGNING_SECRET"),
    auditChannelId: optional("SLACK_AUDIT_CHANNEL_ID"),
  },
  salesforce: {
    clientId: optional("SF_CLIENT_ID"),
    clientSecret: optional("SF_CLIENT_SECRET"),
    loginUrl: optional("SF_LOGIN_URL", "https://login.salesforce.com"),
    callbackUrl:
      optional("STANDUP_PUBLIC_URL", "http://localhost:3002") +
      "/api/oauth/sf/callback",
  },
  gong: {
    accessKey: optional("GONG_ACCESS_KEY"),
    accessKeySecret: optional("GONG_ACCESS_KEY_SECRET"),
    baseUrl: optional("GONG_BASE_URL", "https://api.gong.io"),
  },
  rogo: {
    baseUrl: optional(
      "ROGO_API_BASE_URL",
      "https://rogo-analytics-bot-461481229379.us-central1.run.app"
    ),
    apiKey: optional("ROGO_API_KEY"),
    directorySfKey: optional("ROGO_DIRECTORY_SF_KEY", "salesforce_account_id"),
    directoryCustomerKey: optional(
      "ROGO_DIRECTORY_CUSTOMER_KEY",
      "customer_id"
    ),
    customerJoinColumn: optional("ROGO_CUSTOMER_JOIN_COLUMN", "customer_id"),
    customerTable: optional(
      "ROGO_CUSTOMER_TABLE",
      "REPORT_ENTITIES.CUSTOMER"
    ),
  },
  anthropic: {
    apiKey: optional("ANTHROPIC_API_KEY"),
  },
  postgres: {
    url:
      process.env.POSTGRES_URL ||
      process.env.DATABASE_URL ||
      "",
  },
};

export function assertProduction() {
  required("SLACK_BOT_TOKEN");
  required("SLACK_SIGNING_SECRET");
  required("SF_CLIENT_ID");
  required("SF_CLIENT_SECRET");
  required("ANTHROPIC_API_KEY");
  required("STANDUP_INTERNAL_SECRET");
  required("STANDUP_OAUTH_STATE_SECRET");
  if (!config.postgres.url) throw new Error("Missing POSTGRES_URL/DATABASE_URL");
}
