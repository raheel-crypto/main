import { getPool } from "./client.js";
import type {
  AuditAction,
  PendingCard,
  Recommendation,
  SfTokens,
  UserPrefs,
} from "../types.js";

export async function upsertUser(
  p: Omit<UserPrefs, "lastRunDate" | "active"> & { active?: boolean }
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO users (slack_user_id, slack_team_id, email, timezone, preferred_hour, preferred_minute, active)
     VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7, true))
     ON CONFLICT (slack_user_id) DO UPDATE SET
       slack_team_id = EXCLUDED.slack_team_id,
       email = EXCLUDED.email,
       timezone = EXCLUDED.timezone,
       preferred_hour = EXCLUDED.preferred_hour,
       preferred_minute = EXCLUDED.preferred_minute,
       active = COALESCE($7, users.active)`,
    [
      p.slackUserId,
      p.slackTeamId,
      p.email,
      p.timezone,
      p.preferredHour,
      p.preferredMinute,
      p.active ?? null,
    ]
  );
}

export async function getUser(slackUserId: string): Promise<UserPrefs | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT slack_user_id, slack_team_id, email, timezone, preferred_hour,
            preferred_minute, last_run_date, active
       FROM users WHERE slack_user_id = $1`,
    [slackUserId]
  );
  const r = rows[0];
  if (!r) return null;
  return {
    slackUserId: r.slack_user_id,
    slackTeamId: r.slack_team_id,
    email: r.email,
    timezone: r.timezone,
    preferredHour: r.preferred_hour,
    preferredMinute: r.preferred_minute,
    lastRunDate: r.last_run_date ? String(r.last_run_date) : null,
    active: r.active,
  };
}

export async function getDueUsers(): Promise<UserPrefs[]> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT slack_user_id, slack_team_id, email, timezone, preferred_hour,
            preferred_minute, last_run_date, active
       FROM users WHERE active = true`
  );
  return rows.map((r) => ({
    slackUserId: r.slack_user_id,
    slackTeamId: r.slack_team_id,
    email: r.email,
    timezone: r.timezone,
    preferredHour: r.preferred_hour,
    preferredMinute: r.preferred_minute,
    lastRunDate: r.last_run_date ? String(r.last_run_date) : null,
    active: r.active,
  }));
}

export async function markRunComplete(
  slackUserId: string,
  localDateIso: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE users SET last_run_date = $2 WHERE slack_user_id = $1`,
    [slackUserId, localDateIso]
  );
}

export async function upsertSfTokens(t: SfTokens): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO sf_tokens (slack_user_id, access_token, refresh_token, instance_url,
       sf_user_id, sf_user_email, environment, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, now())
     ON CONFLICT (slack_user_id) DO UPDATE SET
       access_token = EXCLUDED.access_token,
       refresh_token = EXCLUDED.refresh_token,
       instance_url = EXCLUDED.instance_url,
       sf_user_id = EXCLUDED.sf_user_id,
       sf_user_email = EXCLUDED.sf_user_email,
       environment = EXCLUDED.environment,
       updated_at = now()`,
    [
      t.slackUserId,
      t.accessToken,
      t.refreshToken,
      t.instanceUrl,
      t.sfUserId,
      t.sfUserEmail,
      t.environment,
    ]
  );
}

export async function updateSfAccessToken(
  slackUserId: string,
  accessToken: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE sf_tokens SET access_token = $2, updated_at = now() WHERE slack_user_id = $1`,
    [slackUserId, accessToken]
  );
}

export async function getSfTokens(slackUserId: string): Promise<SfTokens | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT slack_user_id, access_token, refresh_token, instance_url,
            sf_user_id, sf_user_email, environment
       FROM sf_tokens WHERE slack_user_id = $1`,
    [slackUserId]
  );
  const r = rows[0];
  if (!r) return null;
  return {
    slackUserId: r.slack_user_id,
    accessToken: r.access_token,
    refreshToken: r.refresh_token,
    instanceUrl: r.instance_url,
    sfUserId: r.sf_user_id,
    sfUserEmail: r.sf_user_email,
    environment: r.environment,
  };
}

export async function insertOauthState(
  state: string,
  slackUserId: string,
  codeVerifier: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO sf_oauth_state (state, slack_user_id, code_verifier) VALUES ($1, $2, $3)`,
    [state, slackUserId, codeVerifier]
  );
}

export async function consumeOauthState(
  state: string
): Promise<{ slackUserId: string; codeVerifier: string } | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `DELETE FROM sf_oauth_state WHERE state = $1 RETURNING slack_user_id, code_verifier`,
    [state]
  );
  const r = rows[0];
  if (!r) return null;
  return { slackUserId: r.slack_user_id, codeVerifier: r.code_verifier };
}

export async function insertPendingCard(
  c: Omit<PendingCard, "id" | "slackMessageTs" | "status"> & {
    slackMessageTs?: string;
  }
): Promise<string> {
  const pool = getPool();
  const { rows } = await pool.query(
    `INSERT INTO pending_cards (slack_user_id, slack_channel, slack_thread_ts, slack_message_ts, opportunity_id, recommendation)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
    [
      c.slackUserId,
      c.slackChannel,
      c.slackThreadTs,
      c.slackMessageTs ?? "",
      c.opportunityId,
      JSON.stringify(c.recommendation),
    ]
  );
  return rows[0].id;
}

export async function setCardMessageTs(
  id: string,
  messageTs: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE pending_cards SET slack_message_ts = $2 WHERE id = $1`,
    [id, messageTs]
  );
}

export async function getPendingCard(id: string): Promise<PendingCard | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT id, slack_user_id, slack_channel, slack_thread_ts, slack_message_ts,
            opportunity_id, recommendation, status
       FROM pending_cards WHERE id = $1`,
    [id]
  );
  const r = rows[0];
  if (!r) return null;
  return {
    id: r.id,
    slackUserId: r.slack_user_id,
    slackChannel: r.slack_channel,
    slackThreadTs: r.slack_thread_ts,
    slackMessageTs: r.slack_message_ts,
    opportunityId: r.opportunity_id,
    recommendation:
      typeof r.recommendation === "string"
        ? (JSON.parse(r.recommendation) as Recommendation)
        : (r.recommendation as Recommendation),
    status: r.status,
  };
}

export async function setCardStatus(
  id: string,
  status: PendingCard["status"]
): Promise<void> {
  const pool = getPool();
  await pool.query(`UPDATE pending_cards SET status = $2 WHERE id = $1`, [
    id,
    status,
  ]);
}

export async function appendAudit(row: {
  slackUserId: string;
  opportunityId?: string | null;
  fieldName?: string | null;
  action: AuditAction;
  oldValue?: string | null;
  newValue?: string | null;
  metadata?: Record<string, unknown>;
}): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO audit_log (slack_user_id, opportunity_id, field_name, action, old_value, new_value, metadata)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      row.slackUserId,
      row.opportunityId ?? null,
      row.fieldName ?? null,
      row.action,
      row.oldValue ?? null,
      row.newValue ?? null,
      row.metadata ? JSON.stringify(row.metadata) : null,
    ]
  );
}
