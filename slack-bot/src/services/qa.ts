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
import { bulkRecordCard, connectPrompt, recordCard } from "../slack/blocks.js";
import type {
  BulkRecordUpdateProposal,
  RecordUpdateProposal,
} from "../types.js";
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
  /click\s+\*?(Apply|Accept)\*?|card below|drafted the update/i;

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

  let sfUserId: string | null = null;
  let sfUserName: string | null = null;
  try {
    const ident: any = await conn.identity();
    sfUserId = ident?.user_id ?? null;
    sfUserName = ident?.display_name ?? null;
  } catch (err: any) {
    console.warn("[qa] conn.identity() failed:", err?.message ?? err);
  }

  const agentCtx: AgentToolCtx = {
    conn,
    slackUserId,
    userEmail: user.email,
    userTimezone: user.timezone,
    instanceUrl: conn.instanceUrl!,
    sfUserId,
    sfUserName,
    pendingRecordProposals: [],
    pendingBulkRecordProposals: [],
  };

  const identityLine =
    sfUserId && sfUserName
      ? `You are helping *${sfUserName}* — Salesforce User Id: \`${sfUserId}\` (email: ${user.email}). Default to filtering SOQL by \`OwnerId = '${sfUserId}'\` for any "my", "I", "mine" queries and for any write/bulk-find unless the rep explicitly broadens scope ("all reps", "across the team", "org-wide", etc.).`
      : `You are helping a rep with email ${user.email}. Default to ownership-filtered queries.`;
  try {
    const result = await runAgent({
      system: QA_SYSTEM,
      userMessage: `Today is ${today} (${user.timezone}).\n${identityLine}\n\n${trimmed}`,
      onToolUse: ({ toolNames }) => updateProgress(toolNames),
      ctx: agentCtx,
    });
    const rawAnswer = result.finalText || "_(no response)_";
    const calledProposeTool = result.toolCalls.some(
      (c) =>
        c.name === "sf_propose_record_update" ||
        c.name === "sf_propose_bulk_record_update"
    );
    const claimsDraft = CARD_ACKNOWLEDGMENT_PATTERN.test(rawAnswer);
    const proposalMissing =
      agentCtx.pendingRecordProposals.length === 0 &&
      agentCtx.pendingBulkRecordProposals.length === 0 &&
      (claimsDraft || calledProposeTool);

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
        ":warning: I started to draft that update but couldn't finish — most likely I couldn't pin down the record in Salesforce or the field name was off. Try again with an exact record name / SF link / 18-char Id, and the field's API name (custom fields end in `__c`).";
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

    for (const proposal of agentCtx.pendingRecordProposals) {
      await postRecordProposalCard({
        slack,
        channelId,
        slackUserId,
        placeholderTs: ts,
        proposal,
        instanceUrl: conn.instanceUrl!,
      });
    }

    for (const proposal of agentCtx.pendingBulkRecordProposals) {
      await postBulkRecordProposalCard({
        slack,
        channelId,
        slackUserId,
        placeholderTs: ts,
        proposal,
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

async function postRecordProposalCard(args: {
  slack: WebClient;
  channelId: string;
  slackUserId: string;
  placeholderTs: string;
  proposal: RecordUpdateProposal;
  instanceUrl: string;
}): Promise<void> {
  const {
    slack,
    channelId,
    slackUserId,
    placeholderTs,
    proposal,
    instanceUrl,
  } = args;
  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: placeholderTs,
    opportunityId:
      proposal.sobjectType === "Opportunity" ? proposal.recordId : null,
    recommendation: proposal,
    kind: "record_proposal",
  });
  const blocks = recordCard(cardId, proposal, instanceUrl);
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
      opportunityId:
        proposal.sobjectType === "Opportunity" ? proposal.recordId : null,
      fieldName: f.field,
      action: "record_proposed_update",
      oldValue:
        f.currentDisplay ??
        (f.currentValue == null ? "" : String(f.currentValue)),
      newValue:
        f.recommendedDisplay ??
        (f.recommendedValue == null ? "" : String(f.recommendedValue)),
      metadata: {
        cardId,
        sobjectType: proposal.sobjectType,
        recordId: proposal.recordId,
        rationale: f.rationale,
      },
    });
  }
}

async function postBulkRecordProposalCard(args: {
  slack: WebClient;
  channelId: string;
  slackUserId: string;
  placeholderTs: string;
  proposal: BulkRecordUpdateProposal;
  instanceUrl: string;
}): Promise<void> {
  const {
    slack,
    channelId,
    slackUserId,
    placeholderTs,
    proposal,
    instanceUrl,
  } = args;
  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: placeholderTs,
    opportunityId: null,
    recommendation: proposal,
    kind: "bulk_record_proposal",
  });
  const blocks = bulkRecordCard(cardId, proposal, instanceUrl);
  const cardRes = await slack.chat.postMessage({
    channel: channelId,
    unfurl_links: false,
    unfurl_media: false,
    ...blocks,
  });
  if (cardRes.ts) await setCardMessageTs(cardId, cardRes.ts);

  for (const summary of proposal.recordSummaries) {
    for (const f of proposal.fields) {
      await appendAudit({
        slackUserId,
        opportunityId:
          proposal.sobjectType === "Opportunity" ? summary.recordId : null,
        fieldName: f.field,
        action: "bulk_record_proposed",
        oldValue:
          summary.currentValues[f.field] == null
            ? ""
            : String(summary.currentValues[f.field]),
        newValue:
          f.recommendedDisplay ??
          (f.recommendedValue == null ? "" : String(f.recommendedValue)),
        metadata: {
          cardId,
          sobjectType: proposal.sobjectType,
          recordId: summary.recordId,
          batchSize: proposal.recordSummaries.length,
          rationale: f.rationale,
        },
      });
    }
  }
}
