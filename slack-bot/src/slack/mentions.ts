import type { App } from "@slack/bolt";
import { WebClient } from "@slack/web-api";
import { waitUntil } from "@vercel/functions";
import { config } from "../config.js";
import { runBriefForUser } from "../services/brief.js";
import { runNotionSync } from "../services/notionSync.js";
import { runQaForUser } from "../services/qa.js";
import { runRedTeamFromDm } from "../services/redTeamDm.js";
import { ensureUserRow } from "./ensureUser.js";
import { channelMentionReply } from "./blocks.js";

const BRIEF_PREFIX = /^\s*brief\b\s*/i;
// Both `red team <opp>` and `arbiter <opp>` trigger the deal-evaluation
// pipeline (Red Team + Blue Team + Arbiter). Two verbs because reps mix them
// up — same underlying handler.
const RED_TEAM_PREFIX = /^\s*red[\s-]?team\b\s*/i;
const ARBITER_PREFIX = /^\s*arbiter\b\s*/i;
// `sync <notion-url> to <opp>` — match only when a URL follows; the bare word
// "sync" is too easy to type accidentally.
const NOTION_SYNC_PREFIX = /^\s*sync\b\s+https?:\/\//i;
const MENTION_TAG = /<@[A-Z0-9]+>/g;

export function registerMentions(app: App): void {
  app.event("app_mention", async ({ event, client }) => {
    try {
      await client.chat.postEphemeral({
        channel: event.channel,
        user: event.user!,
        ...channelMentionReply(),
      });
    } catch (err) {
      console.error("[mentions] app_mention reply failed:", err);
    }
  });

  app.message(async ({ message, client }) => {
    const m = message as any;
    if (m.channel_type !== "im") return;
    if (m.bot_id) return;
    if (m.subtype) return;
    const userId = m.user as string | undefined;
    const channel = m.channel as string | undefined;
    if (!userId || !channel) return;
    const text = stripMentions(String(m.text ?? ""));
    if (!text) return;
    await ensureUserRow(userId, m.team || "", app);
    const slack = new WebClient(config.slack.botToken);
    const work = dispatch(slack, userId, channel, text);
    waitUntil(work.catch((err) => console.error("[mentions] dispatch failed:", err)));
  });
}

function stripMentions(text: string): string {
  return text.replace(MENTION_TAG, "").trim();
}

async function dispatch(
  slack: WebClient,
  slackUserId: string,
  channelId: string,
  text: string
): Promise<void> {
  if (NOTION_SYNC_PREFIX.test(text)) {
    const rest = text.replace(/^\s*sync\b\s*/i, "").trim();
    await runNotionSync({ slackUserId, channelId, rawText: rest, slack });
    return;
  }
  if (RED_TEAM_PREFIX.test(text) || ARBITER_PREFIX.test(text)) {
    const oppRef = text
      .replace(RED_TEAM_PREFIX, "")
      .replace(ARBITER_PREFIX, "")
      .trim();
    await runRedTeamFromDm({ slackUserId, channelId, oppRef, slack });
    return;
  }
  if (BRIEF_PREFIX.test(text)) {
    const accountQuery = text.replace(BRIEF_PREFIX, "").trim();
    await runBriefForUser({ slackUserId, channelId, accountQuery, slack });
    return;
  }
  await runQaForUser({ slackUserId, channelId, question: text, slack });
}
