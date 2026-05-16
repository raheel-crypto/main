import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import { appendAudit, getUserByEmail } from "../db/queries.js";
import { gongCallDigestCard } from "../slack/blocks.js";
import type { GongWebhookPayload } from "../types.js";

export interface GongHandleResult {
  ok: boolean;
  reason?: string;
  dmTo?: string;
}

function pickHostEmail(payload: GongWebhookPayload): {
  email: string | null;
  name: string | null;
} {
  if (payload.hostEmail) {
    return { email: payload.hostEmail, name: payload.hostName ?? null };
  }
  const parties = payload.parties ?? [];
  const flaggedHost = parties.find(
    (p) =>
      p?.isHost === true &&
      typeof p.emailAddress === "string" &&
      (p.affiliation == null || p.affiliation === "internal")
  );
  if (flaggedHost?.emailAddress) {
    return {
      email: flaggedHost.emailAddress,
      name: flaggedHost.name ?? null,
    };
  }
  return { email: null, name: null };
}

export async function handleGongWebhook(
  payload: GongWebhookPayload,
  headers?: Record<string, unknown>
): Promise<GongHandleResult> {
  const { email: hostEmail, name: hostName } = pickHostEmail(payload);
  console.log(
    "[gong] received",
    JSON.stringify({
      callId: payload.callId,
      title: payload.title,
      hostEmail,
      hostName,
      partiesCount: payload.parties?.length ?? 0,
      hasBrief: typeof payload.brief === "string" && payload.brief.length > 0,
    })
  );
  console.log("[gong] full payload:", JSON.stringify(payload));
  if (headers) console.log("[gong] headers:", JSON.stringify(headers));

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
      callId: payload.callId,
      hostEmail,
      title: payload.title ?? null,
    },
  });

  if (config.dryRun) {
    console.log(
      `[gong] dry-run: would DM ${user.slackUserId} for call ${payload.callId}`
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
