CREATE TABLE IF NOT EXISTS users (
  slack_user_id TEXT PRIMARY KEY,
  slack_team_id TEXT NOT NULL,
  email TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'America/Los_Angeles',
  preferred_hour SMALLINT NOT NULL DEFAULT 16,
  preferred_minute SMALLINT NOT NULL DEFAULT 0,
  last_run_date DATE,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sf_tokens (
  slack_user_id TEXT PRIMARY KEY REFERENCES users(slack_user_id) ON DELETE CASCADE,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  instance_url TEXT NOT NULL,
  sf_user_id TEXT,
  sf_user_email TEXT,
  environment TEXT NOT NULL DEFAULT 'production',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sf_oauth_state (
  state TEXT PRIMARY KEY,
  slack_user_id TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pending_cards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slack_user_id TEXT NOT NULL,
  slack_channel TEXT NOT NULL,
  slack_thread_ts TEXT NOT NULL,
  slack_message_ts TEXT NOT NULL DEFAULT '',
  opportunity_id TEXT NOT NULL,
  recommendation JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pending_user ON pending_cards(slack_user_id, status);

CREATE TABLE IF NOT EXISTS audit_log (
  id BIGSERIAL PRIMARY KEY,
  slack_user_id TEXT NOT NULL,
  opportunity_id TEXT,
  field_name TEXT,
  action TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT,
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_user_time ON audit_log(slack_user_id, created_at DESC);
