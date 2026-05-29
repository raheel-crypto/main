/**
 * Deal-channel sync: pull recent Slack channel history from a bound channel,
 * run the channel recommender, DM the binder the standard oppCard with the
 * recommendation.
 *
 * Pattern mirrors notionSync — same recommender (`recommendFromDocument`),
 * same single-opp context builder, same wire card. Only the source-text
 * builder is channel-specific.
 *
 * DM lands with the *binder*, not the user who ran sync. That way SF writes
 * always audit as the rep who owns the channel binding, and a teammate
 * running `/merlin-deal sync` doesn't accidentally take ownership of writes.
 */
import type { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import {
  appendAudit,
  getChannelBinding,
  getUser,
  insertPendingCard,
  setCardMessageTs,
  setChannelLastSyncedAt,
  type ChannelBinding,
} from "../db/queries.js";
import { connectPrompt, oppCard } from "../slack/blocks.js";
import { recommendFromDocument } from "./channelRecommender.js";
import { buildContextForSingleOpp } from "./opportunityContext.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { startAuthorization } from "./salesforceAuth.js";

// First-read default window when `last_synced_at` is null.
const DEFAULT_FIRST_READ_DAYS = 14;
// Hard cap on messages pulled per sync — keeps recommender prompt bounded.
const MAX_MESSAGES = 400;
// Hard cap on transcript chars sent to the recommender.
const MAX_TRANSCRIPT_CHARS = 60_000;

export interface RunChannelSyncArgs {
  slackChannelId: string;
  /** Who initiated the sync. Used to ack the trigger; the DM still goes to the binder. */
  triggeredBySlackUserId: string;
  /** Optional explicit lookback window override (days). Used by the post-bind prompts. */
  windowDays?: number | "all";
  slack: WebClient;
}

export interface ChannelSyncResult {
  ran: boolean;
  reason?: string;
  cardId?: string;
}

export async function runChannelSync(
  args: RunChannelSyncArgs
): Promise<ChannelSyncResult> {
  const { slackChannelId, triggeredBySlackUserId, windowDays, slack } = args;

  const binding = await getChannelBinding(slackChannelId);
  if (!binding) {
    return { ran: false, reason: "not_bound" };
  }

  // The binder owns the DM + the SF write context. The triggerer is just
  // who clicked sync — they could be anyone in the channel.
  const binderSlackUserId = binding.boundBySlackUserId;
  const binder = await getUser(binderSlackUserId);
  if (!binder) {
    await appendAudit({
      slackUserId: triggeredBySlackUserId,
      opportunityId: binding.opportunityId,
      action: "channel_sync_dropped",
      metadata: {
        reason: "binder_not_enrolled",
        slackChannelId,
        binderSlackUserId,
      },
    });
    return { ran: false, reason: "binder_not_enrolled" };
  }

  let conn;
  try {
    conn = await getConnectionForUser(binderSlackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      // DM the binder a connect prompt (not the triggerer — they don't own
      // the binding).
      const url = await startAuthorization(binderSlackUserId);
      await slack.chat.postMessage({
        channel: binderSlackUserId,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      await appendAudit({
        slackUserId: binderSlackUserId,
        opportunityId: binding.opportunityId,
        action: "channel_sync_dropped",
        metadata: { reason: "sf_not_connected", slackChannelId },
      });
      return { ran: false, reason: "sf_not_connected" };
    }
    throw err;
  }

  // Compute the sync window.
  const sinceIso = computeSinceIso(binding, windowDays);

  let transcript: string;
  let messageCount = 0;
  try {
    const result = await fetchChannelTranscript(
      slack,
      slackChannelId,
      sinceIso
    );
    transcript = result.transcript;
    messageCount = result.messageCount;
  } catch (err: any) {
    const message = String(err?.data?.error ?? err?.message ?? err);
    const isScopeError =
      message.includes("missing_scope") ||
      message.includes("not_in_channel") ||
      message.includes("channel_not_found");
    const reason = isScopeError ? "missing_scope_or_not_in_channel" : "history_fetch_failed";
    await appendAudit({
      slackUserId: binderSlackUserId,
      opportunityId: binding.opportunityId,
      action: "channel_sync_dropped",
      metadata: { reason, slackChannelId, error: message.slice(0, 400) },
    });
    return { ran: false, reason };
  }

  if (messageCount === 0 || !transcript.trim()) {
    await appendAudit({
      slackUserId: binderSlackUserId,
      opportunityId: binding.opportunityId,
      action: "channel_sync_dropped",
      metadata: {
        reason: "no_messages_in_window",
        slackChannelId,
        sinceIso,
      },
    });
    return { ran: true, reason: "no_messages" };
  }

  const ctx = await buildContextForSingleOpp(conn, binding.opportunityId);
  if (!ctx) {
    await appendAudit({
      slackUserId: binderSlackUserId,
      opportunityId: binding.opportunityId,
      action: "channel_sync_dropped",
      metadata: { reason: "opp_not_found", slackChannelId },
    });
    return { ran: false, reason: "opp_not_found" };
  }

  const recommendation = await recommendFromDocument({
    ctx,
    sourceText: transcript,
    sourceKind: "channel",
    sourceLabel: `#${slackChannelId} — ${binding.opportunityName}`,
  });
  if (!recommendation || recommendation.fields.length === 0) {
    await setChannelLastSyncedAt(
      slackChannelId,
      DateTime.utc().toISO()!
    );
    await appendAudit({
      slackUserId: binderSlackUserId,
      opportunityId: binding.opportunityId,
      action: "channel_sync_dropped",
      metadata: {
        reason: "no_field_changes",
        slackChannelId,
        messageCount,
        sinceIso,
      },
    });
    // Tell the binder we read it but found nothing worth updating.
    await slack.chat.postMessage({
      channel: binderSlackUserId,
      text:
        `:white_check_mark: Read ${messageCount} message${
          messageCount === 1 ? "" : "s"
        } from <#${slackChannelId}> — nothing here that needs to change on *${
          binding.opportunityName
        }* in Salesforce.`,
    });
    return { ran: true, reason: "no_changes" };
  }

  (recommendation as any)._meta = {
    source: "channel",
    slackChannelId,
    messageCount,
    sinceIso,
  };

  const cardId = await insertPendingCard({
    slackUserId: binderSlackUserId,
    slackChannel: binderSlackUserId, // DM channel = the binder's user id; Slack opens IM automatically
    slackThreadTs: "",
    opportunityId: binding.opportunityId,
    recommendation,
    kind: "channel_sync",
  });

  const { blocks, text } = oppCard(cardId, recommendation, {
    name: binding.opportunityName,
    accountName: binding.accountName ?? "",
    instanceUrl: conn.instanceUrl!,
  });

  // Header DM the binder so it's clear which channel this came from.
  await slack.chat.postMessage({
    channel: binderSlackUserId,
    text: `:speech_balloon: Synced <#${slackChannelId}> to *${binding.opportunityName}* — ${recommendation.fields.length} suggested field update${recommendation.fields.length === 1 ? "" : "s"} from ${messageCount} message${messageCount === 1 ? "" : "s"}.`,
  });
  const posted = await slack.chat.postMessage({
    channel: binderSlackUserId,
    unfurl_links: false,
    unfurl_media: false,
    text,
    blocks,
  });
  if (posted.ts) await setCardMessageTs(cardId, posted.ts);

  await setChannelLastSyncedAt(slackChannelId, DateTime.utc().toISO()!);

  await appendAudit({
    slackUserId: binderSlackUserId,
    opportunityId: binding.opportunityId,
    action: "channel_synced",
    metadata: {
      cardId,
      slackChannelId,
      messageCount,
      sinceIso,
      fieldCount: recommendation.fields.length,
      triggeredBy: triggeredBySlackUserId,
    },
  });

  return { ran: true, cardId };
}

function computeSinceIso(
  binding: ChannelBinding,
  windowDays: number | "all" | undefined
): string {
  if (windowDays === "all") {
    // Slack history goes back to channel creation; we cap at 1 year to bound
    // the prompt size and the loop iterations.
    return DateTime.utc().minus({ years: 1 }).toISO()!;
  }
  if (typeof windowDays === "number" && windowDays > 0) {
    return DateTime.utc().minus({ days: windowDays }).toISO()!;
  }
  // Default: since last_synced_at, or DEFAULT_FIRST_READ_DAYS if never synced.
  if (binding.lastSyncedAt) return binding.lastSyncedAt;
  return DateTime.utc()
    .minus({ days: DEFAULT_FIRST_READ_DAYS })
    .toISO()!;
}

/**
 * Pulls channel history since `sinceIso`, including replies for threaded
 * messages, resolves @<userId> mentions to display names, returns a flat
 * transcript sorted oldest → newest. Bounded by MAX_MESSAGES + MAX_TRANSCRIPT_CHARS.
 */
async function fetchChannelTranscript(
  slack: WebClient,
  channel: string,
  sinceIso: string
): Promise<{ transcript: string; messageCount: number }> {
  const oldestTs = String(DateTime.fromISO(sinceIso).toSeconds());
  type Msg = {
    ts: string;
    user?: string;
    text?: string;
    bot_id?: string;
    subtype?: string;
    thread_ts?: string;
    reply_count?: number;
  };
  const collected: Msg[] = [];
  let cursor: string | undefined;
  while (collected.length < MAX_MESSAGES) {
    const page: any = await slack.conversations.history({
      channel,
      limit: 100,
      oldest: oldestTs,
      cursor,
    });
    const msgs: Msg[] = page.messages ?? [];
    collected.push(...msgs);
    if (!page.has_more || !page.response_metadata?.next_cursor) break;
    cursor = page.response_metadata.next_cursor;
  }

  // Pull replies for parents with reply_count > 0.
  const withReplies: Msg[] = [];
  for (const m of collected) {
    withReplies.push(m);
    if ((m.reply_count ?? 0) > 0 && m.ts) {
      try {
        const r: any = await slack.conversations.replies({
          channel,
          ts: m.ts,
          limit: 100,
        });
        // First message in replies is the parent; skip it to avoid dup.
        const replies = (r.messages ?? []).slice(1);
        withReplies.push(...replies);
      } catch (err) {
        console.warn(
          `[channelSync] replies fetch failed for ts=${m.ts}:`,
          (err as any)?.message ?? err
        );
      }
    }
  }

  // Sort oldest → newest (parents/replies interleaved).
  withReplies.sort((a, b) => Number(a.ts ?? 0) - Number(b.ts ?? 0));

  // Resolve user mentions to display names. Cache per call.
  const userCache = new Map<string, string>();
  async function resolveUser(uid: string): Promise<string> {
    if (userCache.has(uid)) return userCache.get(uid)!;
    try {
      const r: any = await slack.users.info({ user: uid });
      const name =
        r.user?.profile?.display_name ||
        r.user?.profile?.real_name ||
        r.user?.name ||
        uid;
      userCache.set(uid, name);
      return name;
    } catch {
      userCache.set(uid, uid);
      return uid;
    }
  }

  const mentionRe = /<@([A-Z0-9]+)>/g;

  const lines: string[] = [];
  let charCount = 0;
  let truncated = false;
  for (const m of withReplies) {
    if (m.bot_id) continue;
    if (m.subtype && !["thread_broadcast"].includes(m.subtype)) continue;
    if (!m.text) continue;

    // Replace user mentions with display names.
    let text = m.text;
    const ids = Array.from(text.matchAll(mentionRe), (mm) => mm[1]);
    for (const id of ids) {
      const name = await resolveUser(id);
      text = text.replace(new RegExp(`<@${id}>`, "g"), `@${name}`);
    }

    const author = m.user ? await resolveUser(m.user) : "unknown";
    const dt = DateTime.fromSeconds(Number(m.ts));
    const stamp = dt.toFormat("yyyy-LL-dd HH:mm");
    const isReply = !!m.thread_ts && m.thread_ts !== m.ts;
    const prefix = isReply ? "    ↳" : "•";
    const line = `${prefix} [${stamp}] ${author}: ${text}`;
    if (charCount + line.length + 1 > MAX_TRANSCRIPT_CHARS) {
      lines.push("[transcript truncated — exceeded recommender prompt cap]");
      truncated = true;
      break;
    }
    lines.push(line);
    charCount += line.length + 1;
  }

  return {
    transcript: lines.join("\n"),
    messageCount: lines.length - (truncated ? 1 : 0),
  };
}
