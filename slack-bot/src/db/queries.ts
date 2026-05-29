import { getPool } from "./client.js";
import type {
  AuditAction,
  BriefPayload,
  BuySignalPayload,
  GcTokens,
  MeetingPickerPayload,
  MeetingRun,
  PendingCard,
  PendingCardKind,
  NooksDispositionBucket,
  PostMeetingPayload,
  ProposedField,
  Recommendation,
  RecordUpdateProposal,
  BulkRecordUpdateProposal,
  SfApplyError,
  SfTokens,
  UserPrefs,
} from "../types.js";

interface UserRow {
  slack_user_id: string;
  slack_team_id: string;
  email: string;
  timezone: string;
  preferred_hour: number;
  preferred_minute: number;
  last_run_date: string | Date | null;
  active: boolean;
  gong_realtime_enabled: boolean | null;
  gong_firehose_enabled: boolean | null;
  nooks_realtime_enabled: boolean | null;
  nooks_firehose_enabled: boolean | null;
  nooks_host_positive: boolean | null;
  nooks_host_neutral: boolean | null;
  nooks_host_negative: boolean | null;
  nooks_firehose_positive: boolean | null;
  nooks_firehose_neutral: boolean | null;
  nooks_firehose_negative: boolean | null;
  calendar_pre_enabled: boolean | null;
  calendar_post_enabled: boolean | null;
  red_team_enabled: boolean | null;
}

function rowToUserPrefs(r: UserRow): UserPrefs {
  const nooksHostPositive = r.nooks_host_positive ?? false;
  const nooksHostNeutral = r.nooks_host_neutral ?? false;
  const nooksHostNegative = r.nooks_host_negative ?? false;
  const nooksFirehosePositive = r.nooks_firehose_positive ?? false;
  const nooksFirehoseNeutral = r.nooks_firehose_neutral ?? false;
  const nooksFirehoseNegative = r.nooks_firehose_negative ?? false;
  return {
    slackUserId: r.slack_user_id,
    slackTeamId: r.slack_team_id,
    email: r.email,
    timezone: r.timezone,
    preferredHour: r.preferred_hour,
    preferredMinute: r.preferred_minute,
    lastRunDate: r.last_run_date ? String(r.last_run_date) : null,
    active: r.active,
    gongRealtimeEnabled: r.gong_realtime_enabled ?? false,
    gongFirehoseEnabled: r.gong_firehose_enabled ?? false,
    nooksRealtimeEnabled:
      nooksHostPositive || nooksHostNeutral || nooksHostNegative,
    nooksFirehoseEnabled:
      nooksFirehosePositive || nooksFirehoseNeutral || nooksFirehoseNegative,
    nooksHostPositive,
    nooksHostNeutral,
    nooksHostNegative,
    nooksFirehosePositive,
    nooksFirehoseNeutral,
    nooksFirehoseNegative,
    calendarPreEnabled: r.calendar_pre_enabled ?? false,
    calendarPostEnabled: r.calendar_post_enabled ?? false,
    redTeamEnabled: r.red_team_enabled ?? false,
  };
}

const USER_SELECT_COLUMNS = `slack_user_id, slack_team_id, email, timezone, preferred_hour,
            preferred_minute, last_run_date, active, gong_realtime_enabled,
            gong_firehose_enabled, nooks_realtime_enabled, nooks_firehose_enabled,
            nooks_host_positive, nooks_host_neutral, nooks_host_negative,
            nooks_firehose_positive, nooks_firehose_neutral, nooks_firehose_negative,
            calendar_pre_enabled, calendar_post_enabled, red_team_enabled`;

export async function upsertUser(
  p: Omit<
    UserPrefs,
    | "lastRunDate"
    | "active"
    | "gongRealtimeEnabled"
    | "gongFirehoseEnabled"
    | "nooksRealtimeEnabled"
    | "nooksFirehoseEnabled"
    | "nooksHostPositive"
    | "nooksHostNeutral"
    | "nooksHostNegative"
    | "nooksFirehosePositive"
    | "nooksFirehoseNeutral"
    | "nooksFirehoseNegative"
    | "calendarPreEnabled"
    | "calendarPostEnabled"
    | "redTeamEnabled"
  > & {
    active?: boolean;
  }
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
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE slack_user_id = $1`,
    [slackUserId]
  );
  const r = rows[0] as UserRow | undefined;
  if (!r) return null;
  return rowToUserPrefs(r);
}

export async function getUserByEmail(email: string): Promise<UserPrefs | null> {
  if (!email) return null;
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1`,
    [email]
  );
  const r = rows[0] as UserRow | undefined;
  if (!r) return null;
  return rowToUserPrefs(r);
}

export async function updateSubscriptionPrefs(
  slackUserId: string,
  patch: {
    gongRealtimeEnabled?: boolean;
    gongFirehoseEnabled?: boolean;
    nooksHostPositive?: boolean;
    nooksHostNeutral?: boolean;
    nooksHostNegative?: boolean;
    nooksFirehosePositive?: boolean;
    nooksFirehoseNeutral?: boolean;
    nooksFirehoseNegative?: boolean;
    calendarPreEnabled?: boolean;
    calendarPostEnabled?: boolean;
    redTeamEnabled?: boolean;
  }
): Promise<void> {
  const pool = getPool();
  // Update the granular Nooks per-disposition columns AND mirror the
  // legacy boolean flags so any reader still expecting them keeps working
  // until those columns are dropped.
  await pool.query(
    `UPDATE users
        SET gong_realtime_enabled    = COALESCE($2, gong_realtime_enabled),
            gong_firehose_enabled    = COALESCE($3, gong_firehose_enabled),
            nooks_host_positive      = COALESCE($4, nooks_host_positive),
            nooks_host_neutral       = COALESCE($5, nooks_host_neutral),
            nooks_host_negative      = COALESCE($6, nooks_host_negative),
            nooks_firehose_positive  = COALESCE($7, nooks_firehose_positive),
            nooks_firehose_neutral   = COALESCE($8, nooks_firehose_neutral),
            nooks_firehose_negative  = COALESCE($9, nooks_firehose_negative),
            calendar_pre_enabled     = COALESCE($10, calendar_pre_enabled),
            calendar_post_enabled    = COALESCE($11, calendar_post_enabled),
            red_team_enabled         = COALESCE($12, red_team_enabled)
      WHERE slack_user_id = $1`,
    [
      slackUserId,
      patch.gongRealtimeEnabled ?? null,
      patch.gongFirehoseEnabled ?? null,
      patch.nooksHostPositive ?? null,
      patch.nooksHostNeutral ?? null,
      patch.nooksHostNegative ?? null,
      patch.nooksFirehosePositive ?? null,
      patch.nooksFirehoseNeutral ?? null,
      patch.nooksFirehoseNegative ?? null,
      patch.calendarPreEnabled ?? null,
      patch.calendarPostEnabled ?? null,
      patch.redTeamEnabled ?? null,
    ]
  );
  await pool.query(
    `UPDATE users
        SET nooks_realtime_enabled = (nooks_host_positive OR nooks_host_neutral OR nooks_host_negative),
            nooks_firehose_enabled = (nooks_firehose_positive OR nooks_firehose_neutral OR nooks_firehose_negative)
      WHERE slack_user_id = $1`,
    [slackUserId]
  );
}

export async function getCalendarEnrolledUsers(): Promise<UserPrefs[]> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users
      WHERE calendar_pre_enabled = true OR calendar_post_enabled = true`
  );
  return (rows as UserRow[]).map(rowToUserPrefs);
}

export async function upsertGcTokens(t: GcTokens): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO gc_tokens (slack_user_id, access_token, refresh_token, expires_at, google_email, updated_at)
     VALUES ($1, $2, $3, $4, $5, now())
     ON CONFLICT (slack_user_id) DO UPDATE SET
       access_token = EXCLUDED.access_token,
       refresh_token = EXCLUDED.refresh_token,
       expires_at = EXCLUDED.expires_at,
       google_email = EXCLUDED.google_email,
       updated_at = now()`,
    [t.slackUserId, t.accessToken, t.refreshToken, t.expiresAt, t.googleEmail]
  );
}

export async function getGcTokens(slackUserId: string): Promise<GcTokens | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT slack_user_id, access_token, refresh_token, expires_at, google_email
       FROM gc_tokens WHERE slack_user_id = $1`,
    [slackUserId]
  );
  const r = rows[0];
  if (!r) return null;
  return {
    slackUserId: r.slack_user_id,
    accessToken: r.access_token,
    refreshToken: r.refresh_token,
    expiresAt: r.expires_at instanceof Date ? r.expires_at.toISOString() : String(r.expires_at),
    googleEmail: r.google_email ?? null,
  };
}

export async function updateGcAccessToken(
  slackUserId: string,
  accessToken: string,
  expiresAtIso: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE gc_tokens SET access_token = $2, expires_at = $3, updated_at = now()
      WHERE slack_user_id = $1`,
    [slackUserId, accessToken, expiresAtIso]
  );
}

export async function insertGcOauthState(
  state: string,
  slackUserId: string,
  codeVerifier: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO gc_oauth_state (state, slack_user_id, code_verifier) VALUES ($1, $2, $3)`,
    [state, slackUserId, codeVerifier]
  );
}

export async function consumeGcOauthState(
  state: string
): Promise<{ slackUserId: string; codeVerifier: string } | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `DELETE FROM gc_oauth_state WHERE state = $1 RETURNING slack_user_id, code_verifier`,
    [state]
  );
  const r = rows[0];
  if (!r) return null;
  return { slackUserId: r.slack_user_id, codeVerifier: r.code_verifier };
}

export async function insertMeetingRun(row: {
  slackUserId: string;
  gcalEventId: string;
  phase: "pre" | "post" | "picker";
  accountIdResolved?: string | null;
}): Promise<{ inserted: boolean }> {
  const pool = getPool();
  const result = await pool.query(
    `INSERT INTO meeting_runs (slack_user_id, gcal_event_id, phase, account_id_resolved)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (slack_user_id, gcal_event_id, phase) DO NOTHING
     RETURNING id`,
    [row.slackUserId, row.gcalEventId, row.phase, row.accountIdResolved ?? null]
  );
  return { inserted: (result.rowCount ?? 0) > 0 };
}

export async function meetingRunExists(
  slackUserId: string,
  gcalEventId: string,
  phase: "pre" | "post" | "picker"
): Promise<boolean> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT 1 FROM meeting_runs WHERE slack_user_id = $1 AND gcal_event_id = $2 AND phase = $3 LIMIT 1`,
    [slackUserId, gcalEventId, phase]
  );
  return rows.length > 0;
}

export async function getFirehoseSubscribers(
  feed: "gong" | "nooks"
): Promise<UserPrefs[]> {
  const pool = getPool();
  const whereClause =
    feed === "gong"
      ? "gong_firehose_enabled = true"
      : "(nooks_firehose_positive OR nooks_firehose_neutral OR nooks_firehose_negative)";
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE ${whereClause}`
  );
  return (rows as UserRow[]).map(rowToUserPrefs);
}

export async function getNooksFirehoseSubscribersFor(
  bucket: NooksDispositionBucket
): Promise<UserPrefs[]> {
  const pool = getPool();
  const column =
    bucket === "positive"
      ? "nooks_firehose_positive"
      : bucket === "neutral"
        ? "nooks_firehose_neutral"
        : "nooks_firehose_negative";
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE ${column} = true`
  );
  return (rows as UserRow[]).map(rowToUserPrefs);
}

export async function getDueUsers(): Promise<UserPrefs[]> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE active = true`
  );
  return (rows as UserRow[]).map(rowToUserPrefs);
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

export async function insertPendingCard(c: {
  slackUserId: string;
  slackChannel: string;
  slackThreadTs: string;
  slackMessageTs?: string;
  opportunityId: string | null;
  recommendation:
    | Recommendation
    | BriefPayload
    | BuySignalPayload
    | PostMeetingPayload
    | MeetingPickerPayload
    | RecordUpdateProposal
    | BulkRecordUpdateProposal;
  kind?: PendingCardKind;
}): Promise<string> {
  const pool = getPool();
  const { rows } = await pool.query(
    `INSERT INTO pending_cards (slack_user_id, slack_channel, slack_thread_ts, slack_message_ts, opportunity_id, recommendation, kind)
     VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
    [
      c.slackUserId,
      c.slackChannel,
      c.slackThreadTs,
      c.slackMessageTs ?? "",
      c.opportunityId,
      JSON.stringify(c.recommendation),
      c.kind ?? "standup",
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
            opportunity_id, recommendation, status, kind
       FROM pending_cards WHERE id = $1`,
    [id]
  );
  const r = rows[0];
  if (!r) return null;
  const recommendation =
    typeof r.recommendation === "string"
      ? JSON.parse(r.recommendation)
      : r.recommendation;
  const base = {
    id: r.id,
    slackUserId: r.slack_user_id,
    slackChannel: r.slack_channel,
    slackThreadTs: r.slack_thread_ts,
    slackMessageTs: r.slack_message_ts,
    status: r.status,
  };
  const kind: PendingCardKind =
    r.kind === "brief"
      ? "brief"
      : r.kind === "buy_signal"
        ? "buy_signal"
        : r.kind === "post_meeting"
          ? "post_meeting"
          : r.kind === "meeting_picker"
            ? "meeting_picker"
            : r.kind === "qa_proposal"
              ? "qa_proposal"
              : r.kind === "record_proposal"
                ? "record_proposal"
                : r.kind === "bulk_record_proposal"
                  ? "bulk_record_proposal"
                  : "standup";
  if (kind === "brief") {
    return {
      ...base,
      kind: "brief",
      opportunityId: r.opportunity_id ?? null,
      recommendation: recommendation as BriefPayload,
    };
  }
  if (kind === "buy_signal") {
    return {
      ...base,
      kind: "buy_signal",
      opportunityId: null,
      recommendation: recommendation as BuySignalPayload,
    };
  }
  if (kind === "post_meeting") {
    return {
      ...base,
      kind: "post_meeting",
      opportunityId: null,
      recommendation: recommendation as PostMeetingPayload,
    };
  }
  if (kind === "meeting_picker") {
    return {
      ...base,
      kind: "meeting_picker",
      opportunityId: null,
      recommendation: recommendation as MeetingPickerPayload,
    };
  }
  if (kind === "qa_proposal") {
    return {
      ...base,
      kind: "qa_proposal",
      opportunityId: r.opportunity_id,
      recommendation: recommendation as Recommendation,
    };
  }
  if (kind === "record_proposal") {
    return {
      ...base,
      kind: "record_proposal",
      opportunityId: r.opportunity_id ?? null,
      recommendation: recommendation as RecordUpdateProposal,
    };
  }
  if (kind === "bulk_record_proposal") {
    return {
      ...base,
      kind: "bulk_record_proposal",
      opportunityId: null,
      recommendation: recommendation as BulkRecordUpdateProposal,
    };
  }
  return {
    ...base,
    kind: "standup",
    opportunityId: r.opportunity_id,
    recommendation: recommendation as Recommendation,
  };
}

export async function updatePendingCardRecommendation(
  id: string,
  recommendation: unknown
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE pending_cards SET recommendation = $2 WHERE id = $1`,
    [id, JSON.stringify(recommendation)]
  );
}

export async function getRecentBuySignalAccountIds(
  slackUserId: string,
  withinDays: number
): Promise<Set<string>> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT recommendation->>'accountId' AS account_id
       FROM pending_cards
      WHERE slack_user_id = $1
        AND kind = 'buy_signal'
        AND created_at > now() - ($2::int || ' days')::interval`,
    [slackUserId, withinDays]
  );
  const out = new Set<string>();
  for (const r of rows as { account_id: string | null }[]) {
    if (r.account_id) out.add(r.account_id);
  }
  return out;
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

export interface RecentBulkFailureRecord {
  recordId: string;
  recordName: string | null;
  errors: SfApplyError[];
}

export interface RecentBulkFailure {
  cardId: string;
  sobjectType: string;
  recap: string;
  originalFields: ProposedField[];
  failedRecords: RecentBulkFailureRecord[];
  failedAtIso: string;
}

export async function getRecentBulkFailures(
  slackUserId: string,
  withinMinutes: number
): Promise<RecentBulkFailure[]> {
  const pool = getPool();
  const { rows } = await pool.query<{
    batch_id: string | null;
    sobject_type: string | null;
    record_id: string | null;
    errors: unknown;
    latest_at: Date;
  }>(
    `
    SELECT DISTINCT ON (metadata->>'batchId', metadata->>'recordId')
      metadata->>'batchId' AS batch_id,
      metadata->>'sobjectType' AS sobject_type,
      metadata->>'recordId' AS record_id,
      metadata->'errors' AS errors,
      created_at AS latest_at
    FROM audit_log
    WHERE slack_user_id = $1
      AND action = 'bulk_record_apply_failed'
      AND created_at > now() - ($2::int || ' minutes')::interval
    ORDER BY metadata->>'batchId', metadata->>'recordId', created_at DESC
    `,
    [slackUserId, withinMinutes]
  );

  const batchMap = new Map<
    string,
    {
      sobjectType: string;
      records: Map<string, SfApplyError[]>;
      latestAt: Date;
    }
  >();
  for (const r of rows) {
    const batchId = r.batch_id;
    const recordId = r.record_id;
    if (!batchId || !recordId) continue;
    const errors = Array.isArray(r.errors)
      ? (r.errors as SfApplyError[])
      : typeof r.errors === "string"
        ? (JSON.parse(r.errors) as SfApplyError[])
        : [];
    const bucket =
      batchMap.get(batchId) ?? {
        sobjectType: r.sobject_type ?? "Unknown",
        records: new Map<string, SfApplyError[]>(),
        latestAt: r.latest_at,
      };
    bucket.records.set(recordId, errors);
    if (r.latest_at > bucket.latestAt) bucket.latestAt = r.latest_at;
    batchMap.set(batchId, bucket);
  }

  if (batchMap.size === 0) return [];

  const cardIds = [...batchMap.keys()];
  const { rows: cardRows } = await pool.query<{
    id: string;
    recommendation: unknown;
  }>(
    `SELECT id, recommendation FROM pending_cards WHERE id = ANY($1::uuid[]) AND kind = 'bulk_record_proposal'`,
    [cardIds]
  );
  const cardById = new Map<string, BulkRecordUpdateProposal>();
  for (const c of cardRows) {
    const payload =
      typeof c.recommendation === "string"
        ? (JSON.parse(c.recommendation) as BulkRecordUpdateProposal)
        : (c.recommendation as BulkRecordUpdateProposal);
    cardById.set(c.id, payload);
  }

  const out: RecentBulkFailure[] = [];
  for (const [batchId, bucket] of batchMap) {
    const proposal = cardById.get(batchId);
    if (!proposal) continue;
    const nameById = new Map(
      proposal.recordSummaries.map((s) => [s.recordId, s.recordName])
    );
    const failedRecords: RecentBulkFailureRecord[] = [];
    for (const [recordId, errors] of bucket.records) {
      failedRecords.push({
        recordId,
        recordName: nameById.get(recordId) ?? null,
        errors,
      });
    }
    out.push({
      cardId: batchId,
      sobjectType: proposal.sobjectType,
      recap: proposal.recap,
      originalFields: proposal.fields,
      failedRecords,
      failedAtIso: bucket.latestAt.toISOString(),
    });
  }
  out.sort((a, b) => b.failedAtIso.localeCompare(a.failedAtIso));
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Red Team helpers

export async function getRedTeamEnabledUsers(): Promise<UserPrefs[]> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT ${USER_SELECT_COLUMNS}
       FROM users WHERE red_team_enabled = true`
  );
  return (rows as UserRow[]).map(rowToUserPrefs);
}

export async function getOppSnapshot(
  opportunityId: string
): Promise<{ snapshot: Record<string, unknown>; takenAt: string } | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT snapshot, taken_at FROM opp_snapshots WHERE opportunity_id = $1`,
    [opportunityId]
  );
  const r = rows[0];
  if (!r) return null;
  const snap =
    typeof r.snapshot === "string"
      ? (JSON.parse(r.snapshot) as Record<string, unknown>)
      : (r.snapshot as Record<string, unknown>);
  const takenAt =
    r.taken_at instanceof Date ? r.taken_at.toISOString() : String(r.taken_at);
  return { snapshot: snap, takenAt };
}

export async function upsertOppSnapshot(
  opportunityId: string,
  snapshot: Record<string, unknown>
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO opp_snapshots (opportunity_id, snapshot, taken_at)
     VALUES ($1, $2, now())
     ON CONFLICT (opportunity_id) DO UPDATE SET
       snapshot = EXCLUDED.snapshot,
       taken_at = now()`,
    [opportunityId, JSON.stringify(snapshot)]
  );
}

export async function getRedTeamMute(
  opportunityId: string,
  slackUserId: string
): Promise<{ mutedUntilIso: string } | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT muted_until FROM red_team_mutes
      WHERE opportunity_id = $1 AND slack_user_id = $2 AND muted_until > now()
      LIMIT 1`,
    [opportunityId, slackUserId]
  );
  const r = rows[0];
  if (!r) return null;
  const iso =
    r.muted_until instanceof Date
      ? r.muted_until.toISOString()
      : String(r.muted_until);
  return { mutedUntilIso: iso };
}

export async function upsertRedTeamMute(
  opportunityId: string,
  slackUserId: string,
  mutedUntilIso: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO red_team_mutes (opportunity_id, slack_user_id, muted_until)
     VALUES ($1, $2, $3)
     ON CONFLICT (opportunity_id, slack_user_id) DO UPDATE SET
       muted_until = EXCLUDED.muted_until`,
    [opportunityId, slackUserId, mutedUntilIso]
  );
}

export interface QaConversationTurn {
  role: "user" | "assistant";
  content: string;
}

export async function getRecentQaTurns(
  slackUserId: string,
  channelId: string,
  withinMinutes: number,
  maxTurns: number
): Promise<QaConversationTurn[]> {
  const pool = getPool();
  const { rows } = await pool.query<{ role: string; content: string }>(
    `SELECT role, content
       FROM qa_conversation_turns
      WHERE slack_user_id = $1
        AND channel_id = $2
        AND created_at >= NOW() - ($3 || ' minutes')::interval
      ORDER BY created_at DESC
      LIMIT $4`,
    [slackUserId, channelId, String(withinMinutes), maxTurns]
  );
  // Re-order oldest → newest for the agent's messages list.
  return rows
    .map((r) => ({
      role: r.role === "assistant" ? "assistant" : "user",
      content: r.content,
    }))
    .reverse() as QaConversationTurn[];
}

export async function appendQaTurn(
  slackUserId: string,
  channelId: string,
  role: "user" | "assistant",
  content: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO qa_conversation_turns (slack_user_id, channel_id, role, content)
     VALUES ($1, $2, $3, $4)`,
    [slackUserId, channelId, role, content.slice(0, 12_000)]
  );
}

// ─── Channel bindings ──────────────────────────────────────────────────────

export interface ChannelBinding {
  slackChannelId: string;
  slackTeamId: string;
  opportunityId: string;
  accountId: string | null;
  opportunityName: string;
  accountName: string | null;
  boundBySlackUserId: string;
  boundAt: string;
  lastSyncedAt: string | null;
}

function rowToChannelBinding(r: any): ChannelBinding {
  return {
    slackChannelId: r.slack_channel_id,
    slackTeamId: r.slack_team_id,
    opportunityId: r.opportunity_id,
    accountId: r.account_id,
    opportunityName: r.opportunity_name,
    accountName: r.account_name,
    boundBySlackUserId: r.bound_by_slack_user_id,
    boundAt:
      r.bound_at instanceof Date ? r.bound_at.toISOString() : String(r.bound_at),
    lastSyncedAt: r.last_synced_at
      ? r.last_synced_at instanceof Date
        ? r.last_synced_at.toISOString()
        : String(r.last_synced_at)
      : null,
  };
}

export async function upsertChannelBinding(input: {
  slackChannelId: string;
  slackTeamId: string;
  opportunityId: string;
  accountId: string | null;
  opportunityName: string;
  accountName: string | null;
  boundBySlackUserId: string;
}): Promise<void> {
  const pool = getPool();
  await pool.query(
    `INSERT INTO channel_bindings (
       slack_channel_id, slack_team_id, opportunity_id, account_id,
       opportunity_name, account_name, bound_by_slack_user_id
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (slack_channel_id) DO UPDATE SET
       slack_team_id = EXCLUDED.slack_team_id,
       opportunity_id = EXCLUDED.opportunity_id,
       account_id = EXCLUDED.account_id,
       opportunity_name = EXCLUDED.opportunity_name,
       account_name = EXCLUDED.account_name,
       bound_by_slack_user_id = EXCLUDED.bound_by_slack_user_id,
       bound_at = now(),
       last_synced_at = NULL`,
    [
      input.slackChannelId,
      input.slackTeamId,
      input.opportunityId,
      input.accountId,
      input.opportunityName,
      input.accountName,
      input.boundBySlackUserId,
    ]
  );
}

export async function getChannelBinding(
  slackChannelId: string
): Promise<ChannelBinding | null> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT * FROM channel_bindings WHERE slack_channel_id = $1 LIMIT 1`,
    [slackChannelId]
  );
  return rows[0] ? rowToChannelBinding(rows[0]) : null;
}

export async function deleteChannelBinding(
  slackChannelId: string
): Promise<boolean> {
  const pool = getPool();
  const r = await pool.query(
    `DELETE FROM channel_bindings WHERE slack_channel_id = $1`,
    [slackChannelId]
  );
  return (r.rowCount ?? 0) > 0;
}

export async function setChannelLastSyncedAt(
  slackChannelId: string,
  iso: string
): Promise<void> {
  const pool = getPool();
  await pool.query(
    `UPDATE channel_bindings SET last_synced_at = $2 WHERE slack_channel_id = $1`,
    [slackChannelId, iso]
  );
}

export async function getChannelBindingsForOpp(
  opportunityId: string
): Promise<ChannelBinding[]> {
  const pool = getPool();
  const { rows } = await pool.query(
    `SELECT * FROM channel_bindings WHERE opportunity_id = $1`,
    [opportunityId]
  );
  return rows.map(rowToChannelBinding);
}
