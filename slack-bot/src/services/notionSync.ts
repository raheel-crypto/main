/**
 * @merlin DM trigger: `sync <notion-url> to <opp ref>`.
 *
 * 1. Parse Notion page id + opp ref from the message.
 * 2. Resolve opp by name (prefer ones the rep owns; fall back to org-wide).
 * 3. Fetch the Notion page text via the org-wide integration.
 * 4. Build single-opp context (no Gong/Usage fetches — the page IS the input).
 * 5. Run the channel recommender.
 * 6. If fields[] is non-empty, insert pending_cards.kind='notion_sync' and
 *    post the standard oppCard so accept/edit/skip/apply_all all work
 *    unchanged.
 */
import type { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getUser,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { oppCard } from "../slack/blocks.js";
import {
  extractPageId,
  fetchPageText,
  getPageMeta,
  NotionApiError,
} from "./notionClient.js";
import { recommendFromDocument } from "./channelRecommender.js";
import { buildContextForSingleOpp } from "./opportunityContext.js";
import {
  findOpportunitiesByName,
  type OppNameMatch,
} from "./sfReads.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { startAuthorization } from "./salesforceAuth.js";
import { connectPrompt } from "../slack/blocks.js";

export interface RunNotionSyncArgs {
  slackUserId: string;
  channelId: string;
  rawText: string;
  slack: WebClient;
}

export interface NotionSyncResult {
  ran: boolean;
  reason?: string;
}

// "sync <url> [to <opp ref>]"
const URL_PATTERN = /https?:\/\/\S+/i;
const TO_SPLIT = /\bto\b/i;

interface ParsedSync {
  url: string;
  oppRef: string | null;
}

function parseSyncMessage(text: string): ParsedSync | null {
  const urlMatch = text.match(URL_PATTERN);
  if (!urlMatch) return null;
  const url = urlMatch[0];
  // Anything after " to " is the opp ref. Don't require it — caller decides
  // how to handle missing refs (channel binding fallback comes later).
  const afterUrl = text.slice(urlMatch.index! + url.length).trim();
  const split = afterUrl.split(TO_SPLIT);
  const oppRef = split.length > 1 ? split.slice(1).join(" to ").trim() : null;
  return { url, oppRef: oppRef || null };
}

export async function runNotionSync(
  args: RunNotionSyncArgs
): Promise<NotionSyncResult> {
  const { slackUserId, channelId, rawText, slack } = args;

  if (!config.notion?.token) {
    await slack.chat.postMessage({
      channel: channelId,
      text:
        ":warning: Notion sync isn't configured. Set `NOTION_TOKEN` on the slack-bot Vercel project " +
        "and share the page with the integration.",
    });
    return { ran: false, reason: "notion_not_configured" };
  }

  const parsed = parseSyncMessage(rawText);
  if (!parsed) {
    await slack.chat.postMessage({
      channel: channelId,
      text:
        "Couldn't find a URL in that message. Usage: `sync <notion-url> to <opportunity name>`.",
    });
    return { ran: false, reason: "no_url" };
  }
  if (!parsed.oppRef) {
    await slack.chat.postMessage({
      channel: channelId,
      text:
        "Tell me which opp this is for. Usage: `sync <notion-url> to <opportunity name>`.",
    });
    return { ran: false, reason: "no_opp_ref" };
  }

  const pageId = extractPageId(parsed.url);
  if (!pageId) {
    await slack.chat.postMessage({
      channel: channelId,
      text: `That doesn't look like a Notion URL: \`${parsed.url}\`.`,
    });
    return { ran: false, reason: "invalid_url" };
  }

  const user = await getUser(slackUserId);
  if (!user) {
    return { ran: false, reason: "user_not_found" };
  }

  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      const url = await startAuthorization(slackUserId);
      await slack.chat.postMessage({
        channel: channelId,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      return { ran: false, reason: "sf_not_connected" };
    }
    throw err;
  }

  const placeholder = await slack.chat.postMessage({
    channel: channelId,
    text: `:hourglass_flowing_sand: Reading Notion page and reconciling with \`${parsed.oppRef}\`…`,
  });
  const ts = placeholder.ts!;

  // Resolve opp by name (prefer rep-owned; fall back org-wide).
  let sfUserId: string | null = null;
  try {
    const ident: any = await conn.identity();
    sfUserId = ident?.user_id ?? null;
  } catch {
    // Fall through; findOpportunitiesByName will just go org-wide.
  }

  const matches = await findOpportunitiesByName(
    conn,
    parsed.oppRef,
    sfUserId ?? undefined
  );
  if (matches.length === 0) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: `:warning: No opportunity matches \`${parsed.oppRef}\`. Try a more exact name or paste the SF Id.`,
    });
    await appendAudit({
      slackUserId,
      action: "notion_sync_dropped",
      metadata: { reason: "no_opp_match", oppRef: parsed.oppRef, pageId },
    });
    return { ran: false, reason: "no_opp_match" };
  }
  if (matches.length > 1) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: renderDisambiguationText(parsed.oppRef, matches),
    });
    await appendAudit({
      slackUserId,
      action: "notion_sync_dropped",
      metadata: {
        reason: "ambiguous_opp",
        oppRef: parsed.oppRef,
        matches: matches.map((m) => ({ id: m.id, name: m.name })),
      },
    });
    return { ran: false, reason: "ambiguous_opp" };
  }
  const opp = matches[0];

  // Fetch the Notion page.
  let pageText: string;
  let pageTitle: string;
  let pageUrl: string | null = null;
  try {
    const [meta, text] = await Promise.all([
      getPageMeta(pageId),
      fetchPageText(pageId),
    ]);
    pageTitle = meta.title;
    pageUrl = meta.url;
    pageText = text.trim();
  } catch (err: any) {
    const isPermission =
      err instanceof NotionApiError &&
      (err.code === "object_not_found" || err.code === "unauthorized");
    const msg = isPermission
      ? `:warning: I can't read that Notion page. Open the page in Notion → *Share* → *Add connections* → pick the *Merlin* integration. Then try again.`
      : `:x: Couldn't fetch the Notion page: ${String(err?.message ?? err).slice(0, 240)}`;
    await slack.chat.update({ channel: channelId, ts, text: msg });
    await appendAudit({
      slackUserId,
      opportunityId: opp.id,
      action: "notion_sync_dropped",
      metadata: {
        reason: isPermission ? "page_not_shared" : "notion_fetch_failed",
        pageId,
        error: String(err?.message ?? err).slice(0, 400),
      },
    });
    return { ran: false, reason: "notion_fetch_failed" };
  }

  if (!pageText) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: `:warning: Notion page \`${pageTitle}\` is empty — nothing to sync.`,
    });
    return { ran: false, reason: "empty_page" };
  }

  // Build opp context and recommend.
  const ctx = await buildContextForSingleOpp(conn, opp.id);
  if (!ctx) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: `:warning: Couldn't load opp \`${opp.name}\` (${opp.id}).`,
    });
    return { ran: false, reason: "opp_load_failed" };
  }

  const recommendation = await recommendFromDocument({
    ctx,
    sourceText: pageText,
    sourceKind: "notion",
    sourceLabel: pageTitle,
  });
  if (!recommendation || recommendation.fields.length === 0) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: `:white_check_mark: Read \`${pageTitle}\` — nothing here that needs to change on *${opp.name}* in Salesforce.`,
    });
    await appendAudit({
      slackUserId,
      opportunityId: opp.id,
      action: "notion_sync_dropped",
      metadata: {
        reason: "no_field_changes",
        pageId,
        pageTitle,
        charCount: pageText.length,
      },
    });
    return { ran: true, reason: "no_changes" };
  }

  // Persist + post card. recommendation carries the field changes; metadata
  // for audit/debugging is appended on the rec object directly so the card
  // builder can still treat it as a standard Recommendation.
  (recommendation as any)._meta = {
    source: "notion",
    pageId,
    pageTitle,
    pageUrl,
    charCount: pageText.length,
  };

  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: ts,
    opportunityId: opp.id,
    recommendation,
    kind: "notion_sync",
  });

  const { blocks, text } = oppCard(cardId, recommendation, {
    name: opp.name,
    accountName: opp.accountName,
    instanceUrl: conn.instanceUrl!,
  });

  await slack.chat.update({
    channel: channelId,
    ts,
    text: `:notebook: Synced \`${pageTitle}\` to *${opp.name}* — ${recommendation.fields.length} suggested field update${recommendation.fields.length === 1 ? "" : "s"}.`,
  });
  const posted = await slack.chat.postMessage({
    channel: channelId,
    unfurl_links: false,
    unfurl_media: false,
    text,
    blocks,
  });
  if (posted.ts) await setCardMessageTs(cardId, posted.ts);

  await appendAudit({
    slackUserId,
    opportunityId: opp.id,
    action: "notion_synced",
    metadata: {
      cardId,
      pageId,
      pageTitle,
      pageUrl,
      charCount: pageText.length,
      fieldCount: recommendation.fields.length,
    },
  });

  return { ran: true };
}

function renderDisambiguationText(query: string, matches: OppNameMatch[]): string {
  const lines = [
    `Multiple opps match \`${query}\`. Re-run with a more specific name:`,
    "",
  ];
  for (const m of matches.slice(0, 5)) {
    const amount = m.amount != null ? ` · $${m.amount.toLocaleString()}` : "";
    const closed = m.isClosed ? " · closed" : "";
    lines.push(
      `• *${m.name}* (${m.accountName})${amount}${closed} — owner ${m.ownerName ?? "?"}`
    );
  }
  return lines.join("\n");
}
