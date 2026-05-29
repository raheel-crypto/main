CREATE TABLE IF NOT EXISTS users (
  slack_user_id TEXT PRIMARY KEY,
  slack_team_id TEXT NOT NULL,
  email TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'America/Los_Angeles',
  preferred_hour SMALLINT NOT NULL DEFAULT 16,
  preferred_minute SMALLINT NOT NULL DEFAULT 0,
  last_run_date DATE,
  active BOOLEAN NOT NULL DEFAULT true,
  gong_realtime_enabled BOOLEAN NOT NULL DEFAULT false,
  gong_firehose_enabled BOOLEAN NOT NULL DEFAULT false,
  nooks_realtime_enabled BOOLEAN NOT NULL DEFAULT false,
  nooks_firehose_enabled BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE users ADD COLUMN IF NOT EXISTS gong_realtime_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS gong_firehose_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_realtime_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_firehose_enabled BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_users_email_lower ON users(LOWER(email));
DROP INDEX IF EXISTS idx_users_email_lower;
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_lower ON users(LOWER(email));
CREATE INDEX IF NOT EXISTS idx_users_gong_firehose ON users(gong_firehose_enabled) WHERE gong_firehose_enabled = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_firehose ON users(nooks_firehose_enabled) WHERE nooks_firehose_enabled = true;

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
  opportunity_id TEXT,
  recommendation JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  kind TEXT NOT NULL DEFAULT 'standup',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE pending_cards ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'standup';
ALTER TABLE pending_cards ALTER COLUMN opportunity_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pending_user ON pending_cards(slack_user_id, status);
CREATE INDEX IF NOT EXISTS idx_pending_kind ON pending_cards(slack_user_id, kind, status);

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

CREATE TABLE IF NOT EXISTS gc_tokens (
  slack_user_id TEXT PRIMARY KEY REFERENCES users(slack_user_id) ON DELETE CASCADE,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  google_email TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS gc_oauth_state (
  state TEXT PRIMARY KEY,
  slack_user_id TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS meeting_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slack_user_id TEXT NOT NULL,
  gcal_event_id TEXT NOT NULL,
  phase TEXT NOT NULL,
  account_id_resolved TEXT,
  fired_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(slack_user_id, gcal_event_id, phase)
);
CREATE INDEX IF NOT EXISTS idx_meeting_runs_user ON meeting_runs(slack_user_id, fired_at DESC);

ALTER TABLE users ADD COLUMN IF NOT EXISTS calendar_pre_enabled  BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS calendar_post_enabled BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_users_calendar_pre  ON users(calendar_pre_enabled)  WHERE calendar_pre_enabled  = true;
CREATE INDEX IF NOT EXISTS idx_users_calendar_post ON users(calendar_post_enabled) WHERE calendar_post_enabled = true;

ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_host_positive      BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_host_neutral       BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_host_negative      BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_firehose_positive  BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_firehose_neutral   BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS nooks_firehose_negative  BOOLEAN NOT NULL DEFAULT false;
UPDATE users SET nooks_host_positive = true, nooks_host_neutral = true, nooks_host_negative = true
  WHERE nooks_realtime_enabled = true
    AND NOT (nooks_host_positive OR nooks_host_neutral OR nooks_host_negative);
UPDATE users SET nooks_firehose_positive = true, nooks_firehose_neutral = true, nooks_firehose_negative = true
  WHERE nooks_firehose_enabled = true
    AND NOT (nooks_firehose_positive OR nooks_firehose_neutral OR nooks_firehose_negative);
CREATE INDEX IF NOT EXISTS idx_users_nooks_host_positive     ON users(nooks_host_positive)     WHERE nooks_host_positive     = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_host_neutral      ON users(nooks_host_neutral)      WHERE nooks_host_neutral      = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_host_negative     ON users(nooks_host_negative)     WHERE nooks_host_negative     = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_firehose_positive ON users(nooks_firehose_positive) WHERE nooks_firehose_positive = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_firehose_neutral  ON users(nooks_firehose_neutral)  WHERE nooks_firehose_neutral  = true;
CREATE INDEX IF NOT EXISTS idx_users_nooks_firehose_negative ON users(nooks_firehose_negative) WHERE nooks_firehose_negative = true;

-- Red Team agent integration
ALTER TABLE users ADD COLUMN IF NOT EXISTS red_team_enabled BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_users_red_team ON users(red_team_enabled) WHERE red_team_enabled = true;

CREATE TABLE IF NOT EXISTS opp_snapshots (
  opportunity_id TEXT PRIMARY KEY,
  snapshot JSONB NOT NULL,
  taken_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_opp_snapshots_taken ON opp_snapshots(taken_at DESC);

CREATE TABLE IF NOT EXISTS red_team_mutes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id TEXT NOT NULL,
  slack_user_id TEXT NOT NULL,
  muted_until TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(opportunity_id, slack_user_id)
);
CREATE INDEX IF NOT EXISTS idx_red_team_mutes_until ON red_team_mutes(muted_until);

-- Owned by the Python red-team-agent (single shared Postgres). The bot owns
-- the migration; the Python service is a reader/writer only.
CREATE TABLE IF NOT EXISTS red_team_cooldowns (
  opportunity_id TEXT PRIMARY KEY,
  cooled_until TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_red_team_cooldowns_until ON red_team_cooldowns(cooled_until);

-- @merlin Q&A in-DM conversation memory. Each user/assistant turn in a
-- single IM is appended; the QA service loads the last N within the
-- last 30 minutes to thread context into the next agent call.
CREATE TABLE IF NOT EXISTS qa_conversation_turns (
  id BIGSERIAL PRIMARY KEY,
  slack_user_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_qa_turns_lookup
  ON qa_conversation_turns(slack_user_id, channel_id, created_at DESC);

-- Deal-channel sync: one Slack channel ↔ one Salesforce Opportunity.
-- Reps bind via `/merlin-deal bind <opp>`; subsequent `/merlin-deal sync` (or
-- the post-bind prompt buttons) pulls channel history → recommender → DMs the
-- binder the standard oppCard. last_synced_at lets us default the sync window
-- to "since the last sync" instead of re-reading every message every time.
CREATE TABLE IF NOT EXISTS channel_bindings (
  slack_channel_id TEXT PRIMARY KEY,
  slack_team_id TEXT NOT NULL,
  opportunity_id TEXT NOT NULL,
  account_id TEXT,
  opportunity_name TEXT NOT NULL,
  account_name TEXT,
  bound_by_slack_user_id TEXT NOT NULL,
  bound_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_synced_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_channel_bindings_opp
  ON channel_bindings(opportunity_id);
CREATE INDEX IF NOT EXISTS idx_channel_bindings_owner
  ON channel_bindings(bound_by_slack_user_id);
