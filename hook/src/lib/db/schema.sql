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
