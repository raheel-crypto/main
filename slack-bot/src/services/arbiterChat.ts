/**
 * Handler for thread-reply follow-ups on Arbiter verdict cards.
 *
 * Triggered by `slack/mentions.ts` when a rep replies in a DM thread that
 * matches a `verdict_conversations` row. Loads the conversation, captures
 * the rep's message, calls the Python `/arbiter/chat` endpoint, persists
 * the moderator's reply + any verbatim Red/Blue turns, and posts the reply
 * back into the same thread.
 *
 * The Python service is stateless: we pass the verdict + intel pack
 * snapshot + all prior turns every call. State lives in Postgres on this
 * side (`verdict_conversations`, `verdict_conversation_turns`).
 */
import type { WebClient } from "@slack/web-api";
import {
  appendAudit,
  appendVerdictConversationTurn,
  getVerdictConversationTurns,
  touchVerdictConversationActivity,
} from "../db/queries.js";
import { ArbiterChatClientError, callArbiterChat } from "./arbiterChatClient.js";
import type {
  ArbiterChatConversationTurn,
  VerdictConversation,
} from "../types.js";

export interface RunArbiterChatArgs {
  conversation: VerdictConversation;
  slackUserId: string;
  channelId: string;
  threadTs: string;
  userMessage: string;
  slack: WebClient;
}

export async function runArbiterChat(
  args: RunArbiterChatArgs
): Promise<{ ok: boolean; reason?: string }> {
  const { conversation, slackUserId, channelId, threadTs, userMessage, slack } =
    args;

  // 1. Record the rep's message as a 'user' turn FIRST so the audit reflects
  //    it even if the moderator call fails.
  await appendVerdictConversationTurn({
    conversationId: conversation.id,
    role: "user",
    content: userMessage,
  });

  // 2. Load prior turns oldest→newest. We exclude the turn we just inserted
  //    because it's already part of `userMessage` going into the Python call.
  const allTurns = await getVerdictConversationTurns(conversation.id);
  const priorTurns: ArbiterChatConversationTurn[] = allTurns
    // The just-inserted user turn is always last; drop it.
    .slice(0, -1)
    .map((t) => ({ role: t.role, content: t.content, metadata: t.metadata }));

  // 3. Call the Python moderator. Surface a graceful error in-thread if the
  //    upstream chokes — the rep should always see something.
  let placeholder;
  try {
    placeholder = await slack.chat.postMessage({
      channel: channelId,
      thread_ts: threadTs,
      text: "_Thinking…_",
      unfurl_links: false,
      unfurl_media: false,
    });
  } catch (err: any) {
    console.error("[arbiter_chat] placeholder post failed:", err?.message ?? err);
    return { ok: false, reason: "placeholder_failed" };
  }
  const placeholderTs = placeholder.ts;

  let response;
  try {
    response = await callArbiterChat({
      conversationId: conversation.id,
      verdict: conversation.verdict,
      intelPack: conversation.intelPack,
      priorTurns,
      userMessage,
    });
  } catch (err: any) {
    const reason =
      err instanceof ArbiterChatClientError ? err.message : String(err);
    console.error("[arbiter_chat] moderator call failed:", reason);
    const fallback =
      "I couldn't reach the moderator. Try again in a moment, or " +
      `re-run the verdict (\`arbiter ${conversation.opportunityId}\`).`;
    if (placeholderTs) {
      try {
        await slack.chat.update({
          channel: channelId,
          ts: placeholderTs,
          text: fallback,
        });
      } catch {
        // ignore — primary failure already logged
      }
    }
    await appendAudit({
      slackUserId,
      opportunityId: conversation.opportunityId,
      action: "arbiter_chat_failed",
      metadata: {
        conversationId: conversation.id,
        reason: reason.slice(0, 400),
      },
    });
    return { ok: false, reason: "moderator_failed" };
  }

  // 4. Persist the moderator's reply + each summon/lookup/recompute that
  //    produced a verbatim payload, so future turns have full linear context.
  await appendVerdictConversationTurn({
    conversationId: conversation.id,
    role: "moderator",
    content: response.reply,
    metadata: {
      toolCalls: response.toolCalls,
      hopsUsed: response.hopsUsed,
      recomputedProbability: response.recomputedProbability ?? null,
      recomputedLean: response.recomputedLean ?? null,
    },
  });
  for (const t of response.appendedTurns) {
    await appendVerdictConversationTurn({
      conversationId: conversation.id,
      role: t.role,
      content: t.content,
      metadata: t.metadata ?? null,
    });
  }
  await touchVerdictConversationActivity(conversation.id);

  // 5. Render the moderator's reply into the placeholder. We post each
  //    verbatim team/system response as a separate thread reply below so the
  //    rep sees them as standalone chunks they can quote later.
  try {
    if (placeholderTs) {
      await slack.chat.update({
        channel: channelId,
        ts: placeholderTs,
        text: response.reply,
      });
    } else {
      await slack.chat.postMessage({
        channel: channelId,
        thread_ts: threadTs,
        text: response.reply,
        unfurl_links: false,
        unfurl_media: false,
      });
    }
  } catch (err: any) {
    console.error("[arbiter_chat] reply post failed:", err?.message ?? err);
  }

  // Audit
  await appendAudit({
    slackUserId,
    opportunityId: conversation.opportunityId,
    action: "arbiter_chat",
    metadata: {
      conversationId: conversation.id,
      toolsUsed: response.toolCalls.map((c) => c.tool),
      hopsUsed: response.hopsUsed,
      recomputedProbability: response.recomputedProbability ?? null,
      recomputedLean: response.recomputedLean ?? null,
      messagePreview: userMessage.slice(0, 200),
      replyPreview: response.reply.slice(0, 200),
    },
  });

  return { ok: true };
}
