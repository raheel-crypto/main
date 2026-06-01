import { Connection } from "jsforce";
import { DateTime } from "luxon";
import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import { getChannelBindingsForOpps } from "../db/queries.js";
import type {
  GongCall,
  OppChannelContext,
  OppContext,
  SfOpportunity,
  UsageRow,
} from "../types.js";
import { fetchChannelTranscript } from "./channelSync.js";
import { getUsageProvider } from "./usageDb.js";
import { getCallsForUserToday } from "./gong.js";
import {
  escapeSoql as escape,
  fetchActivities,
  fetchLastStageChangesForOpps,
} from "./sfReads.js";

/** Standup channel-context lookback: 7 days. Per the v1 spec. */
const STANDUP_CHANNEL_LOOKBACK_DAYS = 7;
/** Per-opp transcript cap (much tighter than the manual-sync 60k since the
 *  standup processes up to 50 opps in a single prompt budget). */
const STANDUP_CHANNEL_MAX_CHARS = 8_000;
/** Per-opp message cap for the standup. */
const STANDUP_CHANNEL_MAX_MESSAGES = 80;

export async function getStagePicklist(conn: Connection): Promise<string[]> {
  try {
    const desc = await conn.describe("Opportunity");
    const stageField = desc.fields.find((f) => f.name === "StageName");
    if (!stageField || !stageField.picklistValues) return [];
    return stageField.picklistValues
      .filter((p) => p.active)
      .map((p) => p.value);
  } catch {
    return [];
  }
}

async function fetchOpenOpps(
  conn: Connection,
  ownerId: string
): Promise<SfOpportunity[]> {
  const soql = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           NextStep, OwnerId
      FROM Opportunity
     WHERE OwnerId = '${escape(ownerId)}' AND IsClosed = false
     ORDER BY CloseDate ASC NULLS LAST
     LIMIT 50`;
  const result = await conn.query(soql);
  return result.records.map((r: any) => ({
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    stageName: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
    lastStageChangeDate: null,
  }));
}

export interface BuildContextInput {
  conn: Connection;
  sfUserId: string;
  email: string;
  timezone: string;
}

export interface BuildContextResult {
  opps: OppContext[];
  totalCalls: number;
  totalActivities: number;
}

export async function buildContext(
  input: BuildContextInput
): Promise<BuildContextResult> {
  const todayStart = DateTime.now()
    .setZone(input.timezone)
    .startOf("day")
    .toUTC()
    .toISO()!;
  const now = DateTime.now().toUTC().toISO()!;

  const [opps, stagePicklist, callsResult] = await Promise.all([
    fetchOpenOpps(input.conn, input.sfUserId),
    getStagePicklist(input.conn),
    getCallsForUserToday(input.email, todayStart, now).catch((err) => {
      console.error("[gong] fetch failed:", err.message);
      return [] as GongCall[];
    }),
  ]);

  const oppIds = opps.map((o) => o.id);
  const stageChanges = await fetchLastStageChangesForOpps(input.conn, oppIds);

  let earliestSince = todayStart;
  for (const dt of stageChanges.values()) {
    if (dt < earliestSince) earliestSince = dt;
  }

  const [activitiesByOpp, usageRows] = await Promise.all([
    fetchActivities(input.conn, oppIds, earliestSince),
    getUsageProvider()
      .getUsageForAccounts(
        Array.from(new Set(opps.map((o) => o.accountId))),
        DateTime.now().toISODate()!
      )
      .catch((err) => {
        console.error("[usage] fetch failed:", err.message);
        return [] as UsageRow[];
      }),
  ]);

  const usageByAccount = new Map<string, UsageRow[]>();
  for (const u of usageRows) {
    const arr = usageByAccount.get(u.accountId) ?? [];
    arr.push(u);
    usageByAccount.set(u.accountId, arr);
  }

  // Channel-bound opps get last-7-days transcripts injected. One Postgres
  // query for all opps' bindings; one Slack API call per bound channel
  // (parallelized). Bot must be in the channel — out-of-channel errors are
  // caught and the opp ctx just lacks channel content for this run.
  const channelContextByOppId = await maybeBuildChannelContexts(
    opps.map((o) => o.id)
  );

  const oppsWithContext: OppContext[] = opps.map((opp) => ({
    opp: { ...opp, lastStageChangeDate: stageChanges.get(opp.id) ?? null },
    activities: activitiesByOpp.get(opp.id) ?? [],
    calls: matchCallsToOpp(callsResult, opp),
    usage: usageByAccount.get(opp.accountId) ?? [],
    picklistOptions: { stage: stagePicklist },
    channelContext: channelContextByOppId.get(opp.id),
  }));

  const totalActivities = oppsWithContext.reduce(
    (n, o) => n + o.activities.length,
    0
  );

  return {
    opps: oppsWithContext,
    totalCalls: callsResult.length,
    totalActivities,
  };
}

/**
 * Build an OppContext for a single Opportunity by id. Skips Gong-call and
 * usage fetches — callers that want those should still go through
 * `buildContext`. Designed for on-demand flows (notion sync, channel sync,
 * @merlin brief) where the document/transcript is the recommender's input,
 * not Gong/Usage.
 */
export async function buildContextForSingleOpp(
  conn: Connection,
  opportunityId: string
): Promise<OppContext | null> {
  const soql = `
    SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate,
           NextStep, OwnerId
      FROM Opportunity
     WHERE Id = '${escape(opportunityId)}'
     LIMIT 1`;
  const result = await conn.query(soql);
  const r = (result.records as any[])[0];
  if (!r) return null;
  const opp: SfOpportunity = {
    id: r.Id,
    name: r.Name,
    accountId: r.AccountId,
    accountName: r.Account?.Name ?? "",
    stageName: r.StageName,
    amount: r.Amount ?? null,
    closeDate: r.CloseDate,
    nextStep: r.NextStep ?? null,
    ownerId: r.OwnerId,
    lastStageChangeDate: null,
  };
  const [stageChanges, stagePicklist, activitiesByOpp] = await Promise.all([
    fetchLastStageChangesForOpps(conn, [opp.id]),
    getStagePicklist(conn),
    fetchActivities(
      conn,
      [opp.id],
      DateTime.utc().minus({ days: 90 }).toISO()!
    ),
  ]);
  opp.lastStageChangeDate = stageChanges.get(opp.id) ?? null;
  return {
    opp,
    activities: activitiesByOpp.get(opp.id) ?? [],
    calls: [],
    usage: [],
    picklistOptions: { stage: stagePicklist },
  };
}

/**
 * For each opp id, return the last-7-days transcript of the bound channel (if
 * any). If an opp has multiple bindings, we read all of them and concatenate
 * (single-team-multi-channel is rare; happens when both #ent-acme-renewal and
 * #ent-acme-exec exist and both got bound). Errors per channel are swallowed
 * and that channel just contributes nothing — the standup doesn't fail.
 */
async function maybeBuildChannelContexts(
  opportunityIds: string[]
): Promise<Map<string, OppChannelContext>> {
  const out = new Map<string, OppChannelContext>();
  if (opportunityIds.length === 0) return out;
  if (!config.slack.botToken) return out;

  const bindingsByOpp = await getChannelBindingsForOpps(opportunityIds);
  if (bindingsByOpp.size === 0) return out;

  const slack = new WebClient(config.slack.botToken);
  const sinceIso = DateTime.utc()
    .minus({ days: STANDUP_CHANNEL_LOOKBACK_DAYS })
    .toISO()!;

  // Flatten to (oppId, channelId) and fetch in parallel.
  type Pair = { oppId: string; channelId: string };
  const pairs: Pair[] = [];
  for (const [oppId, bindings] of bindingsByOpp) {
    for (const b of bindings) {
      pairs.push({ oppId, channelId: b.slackChannelId });
    }
  }

  const results = await Promise.all(
    pairs.map(async (p) => {
      try {
        const r = await fetchChannelTranscript(slack, p.channelId, sinceIso, {
          maxChars: STANDUP_CHANNEL_MAX_CHARS,
          maxMessages: STANDUP_CHANNEL_MAX_MESSAGES,
        });
        return { ...p, ...r, ok: true as const };
      } catch (err: any) {
        console.warn(
          `[standup channel-context] fetch failed for channel=${p.channelId} opp=${p.oppId}:`,
          err?.data?.error ?? err?.message ?? err
        );
        return { ...p, ok: false as const };
      }
    })
  );

  // Merge by oppId — first non-empty transcript wins; if there are multiple,
  // concatenate so the recommender sees all channel chatter. Cap merge at
  // STANDUP_CHANNEL_MAX_CHARS to keep prompt size predictable.
  for (const r of results) {
    if (!r.ok) continue;
    if (r.messageCount === 0) continue;
    const existing = out.get(r.oppId);
    if (!existing) {
      out.set(r.oppId, {
        slackChannelId: r.channelId,
        lookbackDays: STANDUP_CHANNEL_LOOKBACK_DAYS,
        transcript: r.transcript,
        messageCount: r.messageCount,
      });
      continue;
    }
    // Multi-channel merge: append until the total transcript char budget is met.
    const budgetLeft = STANDUP_CHANNEL_MAX_CHARS - existing.transcript.length;
    if (budgetLeft > 100) {
      const addition = `\n\n— from <#${r.channelId}> —\n` + r.transcript.slice(0, budgetLeft - 20);
      out.set(r.oppId, {
        ...existing,
        transcript: existing.transcript + addition,
        messageCount: existing.messageCount + r.messageCount,
      });
    }
  }

  return out;
}

function matchCallsToOpp(calls: GongCall[], opp: SfOpportunity): GongCall[] {
  const acc = opp.accountName.toLowerCase();
  return calls.filter((c) => {
    const title = c.title.toLowerCase();
    if (acc && title.includes(acc)) return true;
    return false;
  });
}
