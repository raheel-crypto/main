import type { WebClient } from "@slack/web-api";
import { DateTime } from "luxon";
import { runAgent } from "../agent/runner.js";
import { extractJsonObject } from "../agent/jsonParse.js";
import { BRIEF_SYSTEM } from "../agent/prompts.js";
import { appendAudit, getUser, insertPendingCard, setCardMessageTs } from "../db/queries.js";
import {
  briefCard,
  disambiguationBlocks,
  briefErrorBlocks,
} from "../slack/blocks.js";
import {
  BriefDisambiguateSchema,
  BriefPayloadSchema,
  type BriefDisambiguate,
  type BriefPayload,
} from "../types.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "./salesforceClient.js";
import { connectPrompt } from "../slack/blocks.js";
import { startAuthorization } from "./salesforceAuth.js";

export interface BriefRunResult {
  ran: boolean;
  reason?: string;
}

export async function runBriefForUser(args: {
  slackUserId: string;
  channelId: string;
  accountQuery: string;
  slack: WebClient;
}): Promise<BriefRunResult> {
  const { slackUserId, channelId, accountQuery, slack } = args;
  const query = accountQuery.trim();
  if (!query) {
    await slack.chat.postMessage({
      channel: channelId,
      text: "Tell me which account to brief — e.g. `brief Acme Corp`.",
    });
    return { ran: false, reason: "empty_query" };
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

  const placeholderRes = await slack.chat.postMessage({
    channel: channelId,
    text: `Researching ${query}…`,
  });
  const placeholderTs = placeholderRes.ts!;

  const today = DateTime.now().setZone(user.timezone).toISODate();
  const result = await runAgent({
    system: BRIEF_SYSTEM,
    userMessage: `Generate a pre-meeting brief for the Salesforce account whose name matches: "${query}". Today is ${today} (${user.timezone}).`,
    maxTokens: 8192,
    maxIterations: 20,
    ctx: {
      conn,
      slackUserId,
      userEmail: user.email,
      userTimezone: user.timezone,
      instanceUrl: conn.instanceUrl!,
    },
  });

  const raw = extractJsonObject(result.finalText);
  if (!raw) {
    await appendAudit({
      slackUserId,
      action: "brief_failed",
      metadata: { query, reason: "no_json", finalText: result.finalText.slice(0, 1000) },
    });
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(`I couldn't generate a brief for "${query}".`),
    });
    return { ran: false, reason: "no_json" };
  }

  if ((raw as any)?.kind === "disambiguate") {
    const parsed = BriefDisambiguateSchema.safeParse(raw);
    if (!parsed.success) {
      await slack.chat.update({
        channel: channelId,
        ts: placeholderTs,
        ...briefErrorBlocks(`I couldn't parse the disambiguation list for "${query}".`),
      });
      return { ran: false, reason: "disambiguation_parse_failed" };
    }
    return await postDisambiguation(slack, channelId, placeholderTs, query, parsed.data);
  }

  const parsed = BriefPayloadSchema.safeParse(raw);
  if (!parsed.success) {
    await appendAudit({
      slackUserId,
      action: "brief_failed",
      metadata: { query, reason: "schema_invalid", issues: parsed.error.issues },
    });
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(`I couldn't structure the brief for "${query}".`),
    });
    return { ran: false, reason: "schema_invalid" };
  }

  const payload = parsed.data;
  if (!payload.accountId) {
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(payload.snapshot || `I couldn't find an account matching "${query}".`),
    });
    return { ran: false, reason: "no_account" };
  }

  const cardId = await insertPendingCard({
    slackUserId,
    slackChannel: channelId,
    slackThreadTs: placeholderTs,
    slackMessageTs: placeholderTs,
    opportunityId: null,
    recommendation: payload,
    kind: "brief",
  });

  const blocks = briefCard(cardId, payload, conn.instanceUrl!);
  await slack.chat.update({
    channel: channelId,
    ts: placeholderTs,
    ...blocks,
  });
  await setCardMessageTs(cardId, placeholderTs);

  for (const opp of payload.openOpportunities) {
    await appendAudit({
      slackUserId,
      opportunityId: opp.id,
      action: "briefed",
      metadata: { accountId: payload.accountId, query },
    });
  }
  return { ran: true };
}

async function postDisambiguation(
  slack: WebClient,
  channelId: string,
  placeholderTs: string,
  query: string,
  data: BriefDisambiguate
): Promise<BriefRunResult> {
  if (data.candidates.length === 0) {
    await slack.chat.update({
      channel: channelId,
      ts: placeholderTs,
      ...briefErrorBlocks(`No accounts matched "${query}".`),
    });
    return { ran: false, reason: "no_match" };
  }
  await slack.chat.update({
    channel: channelId,
    ts: placeholderTs,
    ...disambiguationBlocks(query, data.candidates),
  });
  return { ran: true, reason: "disambiguation" };
}

// Used by the disambiguation button — call runBriefForUser with the account's
// exact name so the agent's sf_find_account returns a single match.
export async function runBriefForAccountId(args: {
  slackUserId: string;
  channelId: string;
  accountId: string;
  accountName: string;
  slack: WebClient;
  replaceTs?: string;
}): Promise<BriefRunResult> {
  // For v1 we re-run the agent with the exact name. Simpler than adding a
  // second agent path; the name is unique enough after the user picked.
  return await runBriefForUser({
    slackUserId: args.slackUserId,
    channelId: args.channelId,
    accountQuery: args.accountName,
    slack: args.slack,
  });
}

export type { BriefPayload };
