import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import { nooksCallDigestCard } from "../slack/blocks.js";
import type { NooksWebhookPayload } from "../types.js";

export interface NooksHandleResult {
  ok: boolean;
  reason?: string;
  dmTo?: string;
}

export async function handleNooksWebhook(
  payload: NooksWebhookPayload
): Promise<NooksHandleResult> {
  console.log(
    "[nooks] received",
    JSON.stringify({
      event: payload.event,
      eventId: payload.eventId,
      callId: payload.callData?.callId,
      disposition: payload.callData?.disposition?.name,
      agentEmail: payload.callData?.userData?.email,
      accountId: payload.callData?.accountData?.accountId,
      accountName: payload.callData?.accountData?.name,
    })
  );
  console.log("[nooks] full payload:", JSON.stringify(payload));

  const dmTo = config.nooks.testDmUserId;
  if (!dmTo) {
    return { ok: true, reason: "no_test_dm_user_configured" };
  }
  if (!config.slack.botToken) {
    return { ok: true, reason: "no_slack_bot_token" };
  }

  const slack = new WebClient(config.slack.botToken);
  const card = nooksCallDigestCard(payload);
  try {
    await slack.chat.postMessage({
      channel: dmTo,
      unfurl_links: false,
      unfurl_media: false,
      ...card,
    });
    return { ok: true, dmTo };
  } catch (err: any) {
    console.error("[nooks] DM failed:", err?.message ?? err);
    return { ok: false, reason: `dm_failed: ${err?.message ?? String(err)}` };
  }
}
