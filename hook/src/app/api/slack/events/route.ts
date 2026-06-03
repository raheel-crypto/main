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

  if (envelope.type === "event_callback" && envelope.event?.type === "app_mention") {
    const event = envelope.event;
    after(async () => {
      try {
        await handleMention(event);
      } catch (err) {
        console.error("mention handler", err);
      }
    });
    return NextResponse.json({ ok: true });
  }

  return NextResponse.json({ ok: true });
}

async function handleMention(event: NonNullable<SlackEventEnvelope["event"]>) {
  if (!event.channel || !event.text) return;
  const userText = event.text.replace(/<@[^>]+>/g, "").trim();
  const threadTs = event.thread_ts ?? event.ts;

  let priorContext: ThreadContext | null = null;
  let priorAccountId: string | null = null;
  if (threadTs) {
    const rows = (await sql`
      SELECT account_id, context FROM slack_threads WHERE thread_ts = ${threadTs} LIMIT 1
    `) as { account_id: string | null; context: ThreadContext | null }[];
    if (rows[0]) {
      priorAccountId = rows[0].account_id;
      priorContext = rows[0].context;
    }
  }

  // Build conversation history from prior turn if we have it.
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

  const { text } = await askHook(userText, history);

  await slack.chat.postMessage({
    channel: event.channel,
    thread_ts: threadTs,
    text,
  });
}
