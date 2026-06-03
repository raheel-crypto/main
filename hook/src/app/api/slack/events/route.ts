import Anthropic from "@anthropic-ai/sdk";
import { NextResponse, after } from "next/server";
import { verifySlackSignature } from "@/lib/hmac";
import { askHook } from "@/lib/claude/agent";
import { slack } from "@/lib/slack/client";
import { sql } from "@/lib/db/client";

export const runtime = "nodejs";

interface SlackEventEnvelope {
  type: "url_verification" | "event_callback";
  challenge?: string;
  event?: {
    type: string;
    user?: string;
    text?: string;
    channel?: string;
    ts?: string;
    thread_ts?: string;
    bot_id?: string;
    subtype?: string;
  };
}

interface ThreadContext {
  kind?: "slash_command" | "issue" | string;
  sub?: string;
  arg?: string;
  prompt?: string;
  reply?: string;
  accountId?: string;
}

export async function POST(req: Request) {
  const body = await req.text();
  const sig = req.headers.get("x-slack-signature") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";

  if (!verifySlackSignature(body, sig, ts, process.env.SLACK_SIGNING_SECRET ?? "")) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  const envelope = JSON.parse(body) as SlackEventEnvelope;

  if (envelope.type === "url_verification") {
    return NextResponse.json({ challenge: envelope.challenge });
  }

  if (envelope.type === "event_callback") {
    const event = envelope.event;

    if (event?.type === "app_mention") {
      after(async () => {
        try {
          await handleMention(event);
        } catch (err) {
          console.error("mention handler", err);
        }
      });
    } else if (event?.type === "message") {
      after(async () => {
        try {
          await handleThreadMessage(event);
        } catch (err) {
          console.error("thread message handler", err);
        }
      });
    }
  }

  return NextResponse.json({ ok: true });
}

async function handleMention(event: NonNullable<SlackEventEnvelope["event"]>) {
  if (!event.channel || !event.text) return;
  const userText = event.text.replace(/<@[^>]+>/g, "").trim();
  const threadTs = event.thread_ts ?? event.ts;
  if (!threadTs) return;
  await respondInThread({ channel: event.channel, threadTs, userText });
}

async function handleThreadMessage(event: NonNullable<SlackEventEnvelope["event"]>) {
  // Skip bot-authored messages (this is how we avoid responding to ourselves).
  if (event.bot_id) return;

  // Skip system / edited / deleted events.
  if (event.subtype) return;

  // Must be a reply in a thread (top-level messages are not auto-watched).
  if (!event.thread_ts) return;

  // Skip messages that contain any @-mention — those are handled by the
  // app_mention event, which Slack delivers for the same message.
  if (event.text?.includes("<@")) return;

  if (!event.channel || !event.text) return;

  // Only respond in threads Hook has participated in.
  const rows = (await sql`
    SELECT 1 AS hit FROM slack_threads WHERE thread_ts = ${event.thread_ts} LIMIT 1
  `) as { hit: number }[];
  if (rows.length === 0) return;

  await respondInThread({
    channel: event.channel,
    threadTs: event.thread_ts,
    userText: event.text.trim(),
  });
}

async function respondInThread(opts: {
  channel: string;
  threadTs: string;
  userText: string;
}) {
  let priorContext: ThreadContext | null = null;
  let priorAccountId: string | null = null;

  const rows = (await sql`
    SELECT account_id, context FROM slack_threads WHERE thread_ts = ${opts.threadTs} LIMIT 1
  `) as { account_id: string | null; context: ThreadContext | null }[];
  if (rows[0]) {
    priorAccountId = rows[0].account_id;
    priorContext = rows[0].context;
  }

  const history: Anthropic.MessageParam[] = [];
  if (priorContext?.prompt && priorContext?.reply) {
    history.push({ role: "user", content: priorContext.prompt });
    history.push({ role: "assistant", content: priorContext.reply });
  } else if (priorAccountId) {
    history.push({
      role: "user",
      content: `(Earlier in this thread, Hook reported on account ${priorAccountId}.)`,
    });
    history.push({
      role: "assistant",
      content: "Acknowledged — I have that account in context.",
    });
  }

  const { text } = await askHook(opts.userText, history);

  await slack.chat.postMessage({
    channel: opts.channel,
    thread_ts: opts.threadTs,
    text,
  });
}
