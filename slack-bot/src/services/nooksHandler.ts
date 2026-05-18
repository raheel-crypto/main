import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  NOOKS_FILTER_DIRECTION,
  NOOKS_FILTER_DISPOSITION,
} from "../constants.js";
import {
  appendAudit,
  getFirehoseSubscribers,
  getUserByEmail,
} from "../db/queries.js";
import { nooksCallDigestCard } from "../slack/blocks.js";
import type { NooksWebhookPayload } from "../types.js";

export interface NooksHandleResult {
  ok: boolean;
  reason?: string;
  dmTo?: string[];
}

export async function handleNooksWebhook(
  payload: NooksWebhookPayload
): Promise<NooksHandleResult> {
  const direction = payload.callData?.callDirection ?? "";
  const dispositionName = payload.callData?.disposition?.name ?? "";
  const agentEmail = payload.callData?.userData?.email ?? null;

  console.log(
    "[nooks] received",
    JSON.stringify({
      event: payload.event,
      eventId: payload.eventId,
      callId: payload.callData?.callId,
      direction,
      disposition: dispositionName,
      agentEmail,
      accountId: payload.callData?.accountData?.accountId,
      accountName: payload.callData?.accountData?.name,
    })
  );
  console.log("[nooks] full payload:", JSON.stringify(payload));

  if (direction.toLowerCase() !== NOOKS_FILTER_DIRECTION.toLowerCase()) {
    console.log(
      `[nooks] filtered: direction='${direction}' (want '${NOOKS_FILTER_DIRECTION}')`
    );
    return { ok: true, reason: `filtered_direction:${direction}` };
  }
  if (dispositionName.toLowerCase() !== NOOKS_FILTER_DISPOSITION.toLowerCase()) {
    console.log(
      `[nooks] filtered: disposition='${dispositionName}' (want '${NOOKS_FILTER_DISPOSITION}')`
    );
    return { ok: true, reason: `filtered_disposition:${dispositionName}` };
  }

  const targets = new Map<string, "host" | "firehose" | "legacy_env">();

  if (agentEmail) {
    const agent = await getUserByEmail(agentEmail);
    if (agent?.nooksRealtimeEnabled) {
      targets.set(agent.slackUserId, "host");
    }
  }

  const firehoseSubs = await getFirehoseSubscribers("nooks");
  for (const sub of firehoseSubs) {
    if (!targets.has(sub.slackUserId)) {
      targets.set(sub.slackUserId, "firehose");
    }
  }

  if (targets.size === 0 && config.nooks.testDmUserId) {
    targets.set(config.nooks.testDmUserId, "legacy_env");
  }

  if (targets.size === 0) {
    return { ok: true, reason: "no_subscribers" };
  }
  if (!config.slack.botToken) {
    return { ok: true, reason: "no_slack_bot_token" };
  }

  for (const [slackUserId, routing] of targets) {
    await appendAudit({
      slackUserId,
      action: "nooks_realtime_surfaced",
      metadata: {
        callId: payload.callData?.callId ?? null,
        agentEmail,
        disposition: dispositionName,
        routing,
      },
    });
  }

  if (config.dryRun) {
    console.log(
      `[nooks] dry-run: would DM ${[...targets.keys()].join(", ")}`
    );
    return { ok: true, dmTo: [...targets.keys()], reason: "dry_run" };
  }

  const slack = new WebClient(config.slack.botToken);
  const card = nooksCallDigestCard(payload);
  const sent: string[] = [];
  for (const [slackUserId, routing] of targets) {
    try {
      await slack.chat.postMessage({
        channel: slackUserId,
        unfurl_links: false,
        unfurl_media: false,
        ...card,
      });
      sent.push(slackUserId);
    } catch (err: any) {
      console.error(
        `[nooks] DM to ${slackUserId} (${routing}) failed:`,
        err?.message ?? err
      );
    }
  }
  return { ok: true, dmTo: sent };
}
