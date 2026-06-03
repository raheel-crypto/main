import { NextResponse, after } from "next/server";
import { verifySlackSignature } from "@/lib/hmac";
import { sql } from "@/lib/db/client";
import { executeAction, loadAction } from "@/lib/actions/execute";
import { slack } from "@/lib/slack/client";
import { appliedActionBlocks } from "@/lib/slack/blocks";
import type { KnownBlock } from "@slack/web-api";

export const runtime = "nodejs";

interface SlackInteractionPayload {
  type: "block_actions";
  user: { id: string; name: string; username?: string };
  channel: { id: string };
  message: {
    ts: string;
    blocks?: KnownBlock[];
  };
  actions: Array<{
    action_id: string;
    value: string;
    text?: { text?: string };
  }>;
  response_url: string;
}

export async function POST(req: Request) {
  const body = await req.text();
  const sig = req.headers.get("x-slack-signature") ?? "";
  const ts = req.headers.get("x-slack-request-timestamp") ?? "";

  if (!verifySlackSignature(body, sig, ts, process.env.SLACK_SIGNING_SECRET ?? "")) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  // Slack interaction payloads arrive form-encoded with a `payload` field
  // containing the JSON.
  const params = new URLSearchParams(body);
  const rawPayload = params.get("payload");
  if (!rawPayload) {
    return NextResponse.json({ error: "missing payload" }, { status: 400 });
  }

  const payload = JSON.parse(rawPayload) as SlackInteractionPayload;

  if (payload.type !== "block_actions" || payload.actions.length === 0) {
    return NextResponse.json({ ok: true });
  }

  const action = payload.actions[0]!;
  if (!action.action_id.startsWith("apply_action:")) {
    return NextResponse.json({ ok: true });
  }

  const actionId = Number(action.value);
  if (!Number.isFinite(actionId)) {
    return NextResponse.json({ ok: true });
  }

  // Defer the actual work — Slack expects a 200 within 3s.
  after(async () => {
    try {
      await handleAction({
        actionId,
        slackUserId: payload.user.id,
        slackUserName: payload.user.name ?? payload.user.username ?? payload.user.id,
        channelId: payload.channel.id,
        messageTs: payload.message.ts,
        existingBlocks: payload.message.blocks ?? [],
        responseUrl: payload.response_url,
        buttonText: action.text?.text ?? "Action",
      });
    } catch (err) {
      console.error("interaction handler", err);
    }
  });

  return NextResponse.json({ ok: true });
}

async function handleAction(args: {
  actionId: number;
  slackUserId: string;
  slackUserName: string;
  channelId: string;
  messageTs: string;
  existingBlocks: KnownBlock[];
  responseUrl: string;
  buttonText: string;
}) {
  const row = await loadAction(args.actionId);
  if (!row) {
    await fetch(args.responseUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        text: `Hook couldn't find action #${args.actionId}. It may have already been applied.`,
        response_type: "ephemeral",
        replace_original: false,
      }),
    });
    return;
  }

  // Idempotency guard — if already applied, surface that and bail.
  if (row.applied_at) {
    await fetch(args.responseUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        text: `Action #${args.actionId} was already applied by ${row.applied_by_slack_user_id ?? "unknown"}.`,
        response_type: "ephemeral",
        replace_original: false,
      }),
    });
    return;
  }

  const result = await executeAction(row, args.slackUserId, args.slackUserName);

  const userMention = `<@${args.slackUserId}>`;
  const newBlocks = appliedActionBlocks(
    args.existingBlocks,
    userMention,
    args.buttonText,
    args.actionId,
    result,
  );

  await slack.chat.update({
    channel: args.channelId,
    ts: args.messageTs,
    blocks: newBlocks,
    text: result.ok
      ? `${args.buttonText} applied by ${args.slackUserName}`
      : `${args.buttonText} failed`,
  });
}
