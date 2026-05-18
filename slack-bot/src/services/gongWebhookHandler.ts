import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import { appendAudit, getUserByEmail } from "../db/queries.js";
import { gongCallDigestCard } from "../slack/blocks.js";
import type { GongWebhookPayload, GongWebhookParty } from "../types.js";

export interface GongHandleResult {
  ok: boolean;
  reason?: string;
  dmTo?: string;
}

export function pickHost(payload: GongWebhookPayload): {
  email: string | null;
  name: string | null;
  userId: string | null;
} {
  const callData = payload.callData;
  if (!callData) return { email: null, name: null, userId: null };
  const parties: GongWebhookParty[] = callData.parties ?? [];
  const primaryUserId = callData.metaData?.primaryUserId ?? null;
  if (primaryUserId) {
    const host = parties.find((p) => p?.userId === primaryUserId);
    if (host?.emailAddress) {
      return {
        email: host.emailAddress,
        name: host.name ?? null,
        userId: primaryUserId,
      };
    }
  }
  const internal = parties.find(
    (p) =>
      String(p?.affiliation ?? "").toLowerCase() === "internal" &&
      typeof p.emailAddress === "string" &&
      p.emailAddress.length > 0
  );
  if (internal?.emailAddress) {
    return {
      email: internal.emailAddress,
      name: internal.name ?? null,
      userId: internal.userId ?? null,
    };
  }
  return { email: null, name: null, userId: primaryUserId };
}

export async function handleGongWebhook(
  payload: GongWebhookPayload,
  headers?: Record<string, unknown>
): Promise<GongHandleResult> {
  const callData = payload.callData;
  const callId = callData?.metaData?.id ?? null;
  const { email: hostEmail, name: hostName, userId: hostUserId } =
    pickHost(payload);

  console.log(
    "[gong] received",
    JSON.stringify({
      callId,
      title: callData?.metaData?.title ?? null,
      started: callData?.metaData?.started ?? null,
      duration: callData?.metaData?.duration ?? null,
      hostEmail,
      hostName,
      hostUserId,
      partiesCount: callData?.parties?.length ?? 0,
      isTest: payload.isTest ?? null,
    })
  );
  console.log("[gong] full payload:", JSON.stringify(payload));
  if (headers) console.log("[gong] headers:", JSON.stringify(headers));

  if (!callId) {
    return { ok: true, reason: "no_call_id" };
  }
  if (!hostEmail) {
    return { ok: true, reason: "no_host_email" };
  }

  const user = await getUserByEmail(hostEmail);
  if (!user) {
    console.log(`[gong] no enrolled user for hostEmail=${hostEmail}`);
    return { ok: true, reason: "user_not_enrolled" };
  }
  if (!user.gongRealtimeEnabled) {
    return { ok: true, reason: "opted_out" };
  }

  if (!config.slack.botToken) {
    return { ok: true, reason: "no_slack_bot_token" };
  }

  await appendAudit({
    slackUserId: user.slackUserId,
    action: "gong_realtime_surfaced",
    metadata: {
      callId,
      hostEmail,
      title: callData?.metaData?.title ?? null,
    },
  });

  if (config.dryRun) {
    console.log(
      `[gong] dry-run: would DM ${user.slackUserId} for call ${callId}`
    );
    return { ok: true, dmTo: user.slackUserId, reason: "dry_run" };
  }

  const slack = new WebClient(config.slack.botToken);
  const card = gongCallDigestCard(payload, { hostName });
  try {
    await slack.chat.postMessage({
      channel: user.slackUserId,
      unfurl_links: false,
      unfurl_media: false,
      ...card,
    });
    return { ok: true, dmTo: user.slackUserId };
  } catch (err: any) {
    console.error("[gong] DM failed:", err?.message ?? err);
    return { ok: false, reason: `dm_failed: ${err?.message ?? String(err)}` };
  }
}
