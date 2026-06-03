-- Hook database schema. Apply once after Neon setup.

CREATE TABLE IF NOT EXISTS sf_token_cache (
  id TEXT PRIMARY KEY,
  access_token TEXT NOT NULL,
  instance_url TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
  id BIGSERIAL PRIMARY KEY,
  trigger_kind TEXT NOT NULL,
  account_id TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ,
  accounts_checked INT,
  gaps_found INT,
  digest_message_ts TEXT
);

CREATE TABLE IF NOT EXISTS gaps (
  id BIGSERIAL PRIMARY KEY,
  run_id BIGINT REFERENCES runs(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  account_name TEXT,
  stored_arr NUMERIC,
  expected_arr NUMERIC,
  gap_usd NUMERIC,
  category TEXT,
  rule_applied TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  slack_message_ts TEXT
);

CREATE INDEX IF NOT EXISTS gaps_account_idx ON gaps(account_id);
CREATE INDEX IF NOT EXISTS gaps_run_idx ON gaps(run_id);

CREATE TABLE IF NOT EXISTS slack_threads (
  thread_ts TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  account_id TEXT,
  run_id BIGINT REFERENCES runs(id) ON DELETE SET NULL,
  context JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS slack_threads_account_idx ON slack_threads(account_id);

-- Human-in-the-loop write proposals. Hook proposes an action by inserting a row;
-- a button in Slack carries the row's ID; clicking the button executes the write
-- and stamps the audit fields.
CREATE TABLE IF NOT EXISTS pending_actions (
  id BIGSERIAL PRIMARY KEY,
  kind TEXT NOT NULL,
  account_id TEXT,
  opportunity_id TEXT,
  target_object TEXT NOT NULL,
  target_field TEXT NOT NULL,
  current_value TEXT,
  proposed_value TEXT NOT NULL,
  button_text TEXT NOT NULL,
  button_style TEXT,
  confirm_text TEXT NOT NULL,
  reason TEXT,
  gap_id BIGINT REFERENCES gaps(id) ON DELETE SET NULL,
  slack_channel_id TEXT,
  slack_message_ts TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at TIMESTAMPTZ,
  applied_by_slack_user_id TEXT,
  applied_by_slack_user_name TEXT,
  result TEXT,
  error_message TEXT
);

CREATE INDEX IF NOT EXISTS pending_actions_account_idx ON pending_actions(account_id);
CREATE INDEX IF NOT EXISTS pending_actions_message_idx ON pending_actions(slack_message_ts);
