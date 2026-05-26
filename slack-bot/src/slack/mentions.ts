import type { App } from "@slack/bolt";
import { WebClient } from "@slack/web-api";
import { waitUntil } from "@vercel/functions";
import { config } from "../config.js";
import { runBriefForUser } from "../services/brief.js";
import { runQaForUser } from "../services/qa.js";
import { runRedTeamFromDm } from "../services/redTeamDm.js";
import { ensureUserRow } from "./ensureUser.js";
import { channelMentionReply } from "./blocks.js";

const BRIEF_PREFIX = /^\s*brief\b\s*/i;
const RED_TEAM_PREFIX = /^\s*red[\s-]?team\b\s*/i;
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
  if (RED_TEAM_PREFIX.test(text)) {
    const oppRef = text.replace(RED_TEAM_PREFIX, "").trim();
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
