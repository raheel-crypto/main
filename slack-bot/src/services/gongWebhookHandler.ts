import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getFirehoseSubscribers,
  getUserByEmail,
} from "../db/queries.js";
import { gongCallDigestCard } from "../slack/blocks.js";
import { summarizeGongCall } from "./gongCallInsights.js";
import { runGongPostCallSfUpdate } from "./gongPostCallSfUpdate.js";
import { triggerRedTeamForGongCall } from "./redTeamGongTrigger.js";
import type { GongWebhookPayload, GongWebhookParty } from "../types.js";

export interface GongHandleResult {
  ok: boolean;
  reason?: string;
  dmTo?: string[];
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

  const targets = new Map<string, "host" | "firehose">();

  if (hostEmail) {
    const host = await getUserByEmail(hostEmail);
    if (host?.gongRealtimeEnabled) {
      targets.set(host.slackUserId, "host");
    } else if (!host) {
      console.log(`[gong] no enrolled user for hostEmail=${hostEmail}`);
    }
  }

  const firehoseSubs = await getFirehoseSubscribers("gong");
  for (const sub of firehoseSubs) {
    if (!targets.has(sub.slackUserId)) {
      targets.set(sub.slackUserId, "firehose");
    }
  }

  if (targets.size === 0) {
    return {
      ok: true,
      reason: hostEmail ? "no_subscribers" : "no_host_email_no_firehose",
    };
  }

  if (!config.slack.botToken) {
    return { ok: true, reason: "no_slack_bot_token" };
  }

  for (const [slackUserId, routing] of targets) {
    await appendAudit({
      slackUserId,
      action: "gong_realtime_surfaced",
      metadata: {
        callId,
        hostEmail,
        title: callData?.metaData?.title ?? null,
        routing,
      },
    });
  }

  const insights = await summarizeGongCall(payload);

  if (config.dryRun) {
    console.log(
      `[gong] dry-run: would DM ${[...targets.keys()].join(", ")} for call ${callId}`
    );
    return {
      ok: true,
      dmTo: [...targets.keys()],
      reason: "dry_run",
    };
  }

  const slack = new WebClient(config.slack.botToken);
  const card = gongCallDigestCard(payload, { hostName, insights });
  const sent: string[] = [];
  for (const [slackUserId, routing] of targets) {
    try {
      const posted = await slack.chat.postMessage({
        channel: slackUserId,
        unfurl_links: false,
        unfurl_media: false,
        ...card,
      });
      sent.push(slackUserId);

      if (posted.ts && posted.channel) {
        try {
          await runGongPostCallSfUpdate({
            slackUserId,
            payload,
            insights,
            slack,
            digestChannelId: posted.channel,
            digestTs: posted.ts,
          });
        } catch (err: any) {
          console.error(
            `[gong] post-call SF-update for ${slackUserId} (${routing}) failed:`,
            err?.message ?? err
          );
        }

        if (routing === "host") {
          try {
            await triggerRedTeamForGongCall({
              slackUserId,
              payload,
            });
          } catch (err: any) {
            console.error(
              `[gong] red-team trigger for ${slackUserId} (${routing}) failed:`,
              err?.message ?? err
            );
          }
        }
      }
    } catch (err: any) {
      console.error(
        `[gong] DM to ${slackUserId} (${routing}) failed:`,
        err?.message ?? err
      );
    }
  }
  return { ok: true, dmTo: sent };
}
