import { WebClient } from "@slack/web-api";
import { config } from "../config.js";

let client: WebClient | null = null;

function getClient(): WebClient | null {
  if (!config.slack.botToken) return null;
  if (!client) client = new WebClient(config.slack.botToken);
  return client;
}

export async function postAudit(text: string): Promise<void> {
  const c = getClient();
  if (!c || !config.slack.auditChannelId) return;
  try {
    await c.chat.postMessage({
      channel: config.slack.auditChannelId,
      text,
    });
  } catch (err: any) {
    console.error("[audit] failed:", err.message);
  }
}
