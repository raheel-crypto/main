import { NextResponse } from "next/server";
import { verifySlackSignature } from "@/lib/hmac";
import { askHook } from "@/lib/claude/agent";
import { slack } from "@/lib/slack/client";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const body = await req.text();
  const sig = req.headers.get("x-slack-signature") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";

  if (!verifySlackSignature(body, sig, ts, process.env.SLACK_SIGNING_SECRET ?? "")) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  const params = new URLSearchParams(body);
  const command = params.get("command") ?? "";
  const text = params.get("text") ?? "";
  const responseUrl = params.get("response_url") ?? "";
  const channelId = params.get("channel_id") ?? "";
  const userId = params.get("user_id") ?? "";

  void runCommandAsync({ command, text, responseUrl, channelId, userId }).catch((err) => {
    console.error("command handler", err);
    void fetch(responseUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: `Hook hit an error: ${String(err)}`, response_type: "ephemeral" }),
    });
  });

  return NextResponse.json({ response_type: "ephemeral", text: "Checking…" });
}

interface CommandCtx {
  command: string;
  text: string;
  responseUrl: string;
  channelId: string;
  userId: string;
}

async function runCommandAsync(ctx: CommandCtx) {
  let prompt: string;
  const trimmed = ctx.text.trim();
  const [sub, ...rest] = trimmed.split(/\s+/);
  const arg = rest.join(" ");

  switch (sub) {
    case "recheck":
      prompt = `Re-run the recompute for ${arg}. Use diff_vs_stored and report the current state.`;
      break;
    case "explain":
      prompt = `Explain the incremental ARR calculation for opportunity ${arg}. Show the running total before and after, and identify the rule applied (Renewal rebase, Upsell, Pilot, Restructure absorbed, etc).`;
      break;
    case "audit":
      prompt = `Summarize this week's reconciliation. Use last_audit on any flagged accounts as needed.`;
      break;
    case "help":
    case "":
      await fetch(ctx.responseUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          response_type: "ephemeral",
          text: "Hook commands:\n• `/hook recheck <account-name-or-id>` — fresh recompute\n• `/hook explain <opp-id>` — opp incremental ARR\n• `/hook audit` — this week's summary\n• `/hook help` — this message\nOr @Hook in a thread for ad-hoc questions.",
        }),
      });
      return;
    default:
      prompt = `User invoked an unknown subcommand: ${ctx.text}. Reply with a short helpful response.`;
  }

  const { text } = await askHook(prompt);

  await slack.chat.postMessage({ channel: ctx.channelId, text });
}
