import { NextResponse, after } from "next/server";
import { verifySlackSignature } from "@/lib/hmac";
import { askHook } from "@/lib/claude/agent";
import { slack } from "@/lib/slack/client";
import { sql } from "@/lib/db/client";

export const runtime = "nodejs";

const HELP_TEXT = `Hook commands — ARR for ye crew:
• \`/hook recheck <account>\` — fresh recompute against §2
• \`/hook explain <opp-id>\` — walk through one opp's ARR delta
• \`/hook audit\` — summary of this week's reconciliation
• \`/hook help\` — this message

Follow-ups: start a thread off any Hook reply and \`@Hook\` your question — Hook loads the original context automatically.`;

interface ParsedCommand {
  sub: string;
  arg: string;
}

function parseCommand(text: string): ParsedCommand {
  const trimmed = text.trim();
  const [sub = "", ...rest] = trimmed.split(/\s+/);
  return { sub, arg: rest.join(" ") };
}

interface Ack {
  text: string;
  prompt?: string;
}

function buildAck({ sub, arg }: ParsedCommand): Ack {
  switch (sub) {
    case "":
    case "help":
      return { text: HELP_TEXT };

    case "recheck":
      if (!arg) {
        return { text: "Aye, but which account? Try `/hook recheck <account-name-or-id>`." };
      }
      return {
        text: `Diving for treasure on *${arg}*…`,
        prompt: `Re-run the recompute for ${arg}. Use diff_vs_stored and report the current state.`,
      };

    case "explain":
      if (!arg) {
        return { text: "Aye, but which opp? Try `/hook explain <opp-id>`." };
      }
      return {
        text: `Pulling the ship's log on *${arg}*…`,
        prompt: `Explain the incremental ARR calculation for opportunity ${arg}. Show the running total before and after, and identify the rule applied (Renewal rebase, Upsell, Pilot, Restructure absorbed, etc).`,
      };

    case "audit":
      return {
        text: "Hoisting this week's ledger…",
        prompt: `Summarize this week's reconciliation. Use last_audit on any flagged accounts as needed.`,
      };

    default:
      return { text: `ARR? I don't know \`${sub}\`. Try \`/hook help\`.` };
  }
}

export async function POST(req: Request) {
  const body = await req.text();
  const sig = req.headers.get("x-slack-signature") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";

  if (!verifySlackSignature(body, sig, ts, process.env.SLACK_SIGNING_SECRET ?? "")) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  const params = new URLSearchParams(body);
  const text = params.get("text") ?? "";
  const responseUrl = params.get("response_url") ?? "";
  const channelId = params.get("channel_id") ?? "";

  const parsed = parseCommand(text);
  const ack = buildAck(parsed);

  if (ack.prompt) {
    const prompt = ack.prompt;
    after(async () => {
      try {
        const { text: reply } = await askHook(prompt);
        const post = await slack.chat.postMessage({ channel: channelId, text: reply });

        // Persist thread context so @Hook follow-ups can load the prior turn.
        if (post.ts) {
          await sql`
            INSERT INTO slack_threads (thread_ts, channel_id, account_id, context)
            VALUES (${post.ts}, ${channelId}, NULL, ${JSON.stringify({
              kind: "slash_command",
              sub: parsed.sub,
              arg: parsed.arg,
              prompt,
              reply,
            })})
            ON CONFLICT (thread_ts) DO UPDATE SET context = EXCLUDED.context
          `;
        }
      } catch (err) {
        console.error("command handler", err);
        await fetch(responseUrl, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            text: `Hook ran aground: ${err instanceof Error ? err.message : String(err)}`,
            response_type: "ephemeral",
          }),
        });
      }
    });
  }

  return NextResponse.json({ response_type: "ephemeral", text: ack.text });
}
