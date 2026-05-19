import type { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import { runAgent } from "../agent/runner.js";
import { QA_SYSTEM } from "../agent/prompts.js";
import { buildSlackProgressUpdater } from "../agent/progress.js";
import { appendAudit, getUser } from "../db/queries.js";
import { connectPrompt } from "../slack/blocks.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { startAuthorization } from "./salesforceAuth.js";

export interface QaRunResult {
  ran: boolean;
  reason?: string;
}

export async function runQaForUser(args: {
  slackUserId: string;
  channelId: string;
  question: string;
  slack: WebClient;
}): Promise<QaRunResult> {
  const { slackUserId, channelId, question, slack } = args;
  const trimmed = question.trim();
  if (!trimmed) {
    return { ran: false, reason: "empty" };
  }

  const user = await getUser(slackUserId);
  if (!user) return { ran: false, reason: "user_not_found" };

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
    text: ":hourglass_flowing_sand: Thinking…",
  });
  const ts = placeholder.ts!;

  const updateProgress = buildSlackProgressUpdater({
    slack,
    channel: channelId,
    ts,
    logTag: "[qa]",
  });

  const today = DateTime.now().setZone(user.timezone).toISODate();
  try {
    const result = await runAgent({
      system: QA_SYSTEM,
      userMessage: `Today is ${today} (${user.timezone}).\n\n${trimmed}`,
      onToolUse: ({ toolNames }) => updateProgress(toolNames),
      ctx: {
        conn,
        slackUserId,
        userEmail: user.email,
        userTimezone: user.timezone,
        instanceUrl: conn.instanceUrl!,
      },
    });
    const answer = result.finalText || "_(no response)_";
    await slack.chat.update({
      channel: channelId,
      ts,
      text: answer,
    });
    await appendAudit({
      slackUserId,
      action: "qa_answered",
      metadata: {
        question: trimmed,
        finalText: answer.slice(0, 2000),
        toolCalls: result.toolCalls.map((c) => c.name),
        stopReason: result.stopReason,
      },
    });
    return { ran: true };
  } catch (err: any) {
    await slack.chat.update({
      channel: channelId,
      ts,
      text: `Something went wrong: ${err.message ?? err}`,
    });
    await appendAudit({
      slackUserId,
      action: "qa_failed",
      metadata: { question: trimmed, error: err.message ?? String(err) },
    });
    return { ran: false, reason: "error" };
  }
}
