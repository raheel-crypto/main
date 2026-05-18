import { createHmac, timingSafeEqual } from "node:crypto";
import { WebClient } from "@slack/web-api";

const slack = new WebClient(process.env.SLACK_BOT_TOKEN);

/**
 * Verify the request actually came from Slack.
 * https://api.slack.com/authentication/verifying-requests-from-slack
 *
 * `rawBody` must be the raw, unparsed request body string — NOT the parsed
 * object. The handler reads the body manually before parsing for this reason.
 */
export function verifySlackSignature(
  rawBody: string,
  timestamp: string | undefined,
  signature: string | undefined,
): boolean {
  if (process.env.SKIP_SIG_VERIFY === "1") return true;
  if (!timestamp || !signature) return false;

  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp, 10)) > 60 * 5) return false;

  const signingSecret = process.env.SLACK_SIGNING_SECRET;
  if (!signingSecret) {
    console.error("SLACK_SIGNING_SECRET is not set");
    return false;
  }

  const baseString = `v0:${timestamp}:${rawBody}`;
  const expected = `v0=${createHmac("sha256", signingSecret).update(baseString).digest("hex")}`;

  const a = Buffer.from(expected);
  const b = Buffer.from(signature);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export async function postMessage(args: {
  channel: string;
  text: string;
  thread_ts?: string;
  blocks?: unknown[];
}): Promise<{ ok: boolean; ts?: string }> {
  const res = await slack.chat.postMessage({
    channel: args.channel,
    text: args.text,
    thread_ts: args.thread_ts,
    blocks: args.blocks as never,
  });
  return { ok: !!res.ok, ts: res.ts };
}

export async function updateMessage(args: {
  channel: string;
  ts: string;
  text: string;
  blocks?: unknown[];
}): Promise<void> {
  await slack.chat.update({
    channel: args.channel,
    ts: args.ts,
    text: args.text,
    blocks: args.blocks as never,
  });
}

export async function updateViaResponseUrl(
  responseUrl: string,
  body: { text: string; blocks?: unknown[]; replace_original?: boolean; response_type?: "in_channel" | "ephemeral" },
): Promise<void> {
  await fetch(responseUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

export async function openModal(triggerId: string, view: unknown): Promise<{ view_id: string | null }> {
  const res = await slack.views.open({ trigger_id: triggerId, view: view as never });
  return { view_id: res.view?.id ?? null };
}

export async function pushModal(triggerId: string, view: unknown): Promise<void> {
  await slack.views.push({ trigger_id: triggerId, view: view as never });
}

export async function dmUser(userId: string, text: string, blocks?: unknown[]) {
  const im = await slack.conversations.open({ users: userId });
  if (!im.channel?.id) throw new Error("Could not open IM with " + userId);
  return postMessage({ channel: im.channel.id, text, blocks });
}

export async function dmFileToUser(args: {
  userId: string;
  file: Buffer;
  filename: string;
  initialComment?: string;
}): Promise<void> {
  const im = await slack.conversations.open({ users: args.userId });
  if (!im.channel?.id) throw new Error("Could not open IM with " + args.userId);
  await slack.files.uploadV2({
    channel_id: im.channel.id,
    file: args.file,
    filename: args.filename,
    initial_comment: args.initialComment,
  });
}
