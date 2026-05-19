import type { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import { runAgent } from "../agent/runner.js";
import { QA_SYSTEM } from "../agent/prompts.js";
import { buildSlackProgressUpdater } from "../agent/progress.js";
import type { AgentToolCtx } from "../agent/tools.js";
import {
  appendAudit,
  getUser,
  insertPendingCard,
  setCardMessageTs,
} from "../db/queries.js";
import { connectPrompt, oppCard } from "../slack/blocks.js";
import type { Recommendation } from "../types.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { startAuthorization } from "./salesforceAuth.js";

export interface QaRunResult {
  ran: boolean;
  reason?: string;
}

const CARD_ACKNOWLEDGMENT_PATTERN =
  /click\s+\*?Apply\*?|card below|drafted the update/i;

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
  const agentCtx: AgentToolCtx = {
    conn,
    slackUserId,
    userEmail: user.email,
    userTimezone: user.timezone,
    instanceUrl: conn.instanceUrl!,
  };
  try {
    const result = await runAgent({
      system: QA_SYSTEM,
      userMessage: `Today is ${today} (${user.timezone}).\n\n${trimmed}`,
      onToolUse: ({ toolNames }) => updateProgress(toolNames),
      ctx: agentCtx,
    });
    const rawAnswer = result.finalText || "_(no response)_";
    const calledProposeTool = result.toolCalls.some(
      (c) => c.name === "sf_propose_opportunity_update"
    );
    const claimsDraft = CARD_ACKNOWLEDGMENT_PATTERN.test(rawAnswer);
    const proposalMissing =
      !agentCtx.pendingWriteProposal && (claimsDraft || calledProposeTool);

    let answer = rawAnswer;
    if (proposalMissing) {
      console.warn(
        "[qa] agent claimed to draft an update but no proposal was staged",
        {
          slackUserId,
          calledProposeTool,
          claimsDraft,
          toolCalls: result.toolCalls.map((c) => c.name),
          finalText: rawAnswer.slice(0, 500),
        }
      );
      answer =
        ":warning: I started to draft that update but couldn't finish — most likely I couldn't pin down the opportunity in Salesforce. Try again with the exact opportunity name, or send the SF link / 18-char Id.";
    }

    await slack.chat.update({
      channel: channelId,
      ts,
      text: answer,
    });
    await appendAudit({
      slackUserId,
      action: proposalMissing ? "qa_propose_failed" : "qa_answered",
      metadata: {
        question: trimmed,
        finalText: rawAnswer.slice(0, 2000),
        toolCalls: result.toolCalls.map((c) => c.name),
        stopReason: result.stopReason,
        ...(proposalMissing
          ? { reason: "agent_claimed_card_without_staged_proposal" }
          : {}),
      },
    });

    if (agentCtx.pendingWriteProposal) {
      await postWriteProposalCard({
        slack,
        channelId,
        slackUserId,
        placeholderTs: ts,
        proposal: agentCtx.pendingWriteProposal,
        instanceUrl: conn.instanceUrl!,
      });
    }

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

async function postWriteProposalCard(args: {
  slack: WebClient;
  channelId: string;
  slackUserId: string;
  placeholderTs: string;
  proposal: NonNullable<AgentToolCtx["pendingWriteProposal"]>;
  instanceUrl: string;
}): Promise<void> {
  const { slack, channelId, slackUserId, placeholderTs, proposal, instanceUrl } =
    args;
  const recommendation: Recommendation = {
    opportunityId: proposal.opportunityId,
    recap: proposal.recap,
    fields: proposal.fields,
  };
  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: placeholderTs,
    opportunityId: proposal.opportunityId,
    recommendation,
    kind: "qa_proposal",
  });
  const blocks = oppCard(cardId, recommendation, {
    name: proposal.opportunityName,
    accountName: proposal.accountName,
    instanceUrl,
  });
  const cardRes = await slack.chat.postMessage({
    channel: channelId,
    unfurl_links: false,
    unfurl_media: false,
    ...blocks,
  });
  if (cardRes.ts) await setCardMessageTs(cardId, cardRes.ts);

  for (const f of proposal.fields) {
    await appendAudit({
      slackUserId,
      opportunityId: proposal.opportunityId,
      fieldName: f.field,
      action: "qa_proposed_update",
      oldValue: String(f.currentValue ?? ""),
      newValue: String(f.recommendedValue ?? ""),
      metadata: { cardId, rationale: f.rationale },
    });
  }
}
