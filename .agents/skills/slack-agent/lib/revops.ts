import { buildApprovalBlocks, buildStatusInThreadText, buildTopLineText } from "./blocks.js";
import { postChatterFeed } from "./sfdc-client.js";
import { postMessage, updateMessage } from "./slack.js";
import type { ApprovalRequest } from "./types.js";

/**
 * Audit-log a decision to the related Opportunity's Chatter feed.
 * Best-effort — Chatter failures are logged but never thrown.
 */
export async function postAuditLog(request: ApprovalRequest): Promise<void> {
  const fmtMoney = (n: number | null) => (n == null ? "—" : `$${n.toLocaleString()}`);
  const fmtPct = (n: number | null) => (n == null ? "—" : `${(n * 100).toFixed(1)}%`);
  const verb =
    request.state === "approved"
      ? "APPROVED"
      : request.state === "rejected"
        ? "REJECTED"
        : "PENDING";
  const by =
    request.state === "approved" && request.decided_by_slack_user_id === "auto"
      ? "auto (no approval required)"
      : request.decided_by_name ?? "—";
  const lines = [
    `Quote Bot — Quote \`${request.request_id}\` ${verb}`,
    `Decided by: ${by}`,
    `Package: ${request.form.package} · Users: ${request.form.users.toLocaleString()}`,
    `Price/user: ${fmtMoney(request.form.price_per_user)} · Discount: ${fmtPct(request.pricing.discount_pct)}`,
    `Total: ${fmtMoney(request.pricing.total_amount)}`,
  ];
  if (request.routing.tier !== "auto") {
    lines.push(`Tier: ${request.routing.tier_label}`);
  }
  try {
    await postChatterFeed(request.context.opportunity.id, lines.join("\n"));
  } catch (e) {
    console.error("Chatter audit log failed:", e);
  }
}

/**
 * Post a fresh approval request to the deal-desk channel. Returns the message
 * ts so the caller can persist it for later updates on button clicks.
 */
export async function postApprovalRequest(request: ApprovalRequest): Promise<{
  channel: string;
  ts: string | null;
}> {
  const channel = required("REVOPS_CHANNEL");
  const text = buildTopLineText(request);
  const blocks = buildApprovalBlocks({
    request_id: request.request_id,
    state: request.state,
    context: request.context,
    form: request.form,
    pricing: request.pricing,
    routing: request.routing,
    agent: request.agent,
    requester_slack_user_id: request.requester.slack_user_id,
    sfdc_instance_url: process.env.SFDC_LOGIN_URL ?? null,
  });

  const res = await postMessage({ channel, text, blocks });
  return { channel, ts: res.ts ?? null };
}

/**
 * Update the original message to reflect the decided state, AND post a status
 * note in the same message's thread so reviewers see a timeline.
 */
export async function postDecisionUpdate(request: ApprovalRequest): Promise<void> {
  if (!request.slack_message) {
    throw new Error("Cannot post decision update — request has no slack_message reference");
  }
  if (!request.decided_at || !request.decided_by_slack_user_id) {
    throw new Error("Cannot post decision update — missing decided_at / decided_by_slack_user_id");
  }

  const blocks = buildApprovalBlocks({
    request_id: request.request_id,
    state: request.state,
    context: request.context,
    form: request.form,
    pricing: request.pricing,
    routing: request.routing,
    agent: request.agent,
    requester_slack_user_id: request.requester.slack_user_id,
    decided_by_name: request.decided_by_name,
    decided_at: request.decided_at,
    sfdc_instance_url: process.env.SFDC_LOGIN_URL ?? null,
  });

  const topText = buildTopLineText(request);

  await updateMessage({
    channel: request.slack_message.channel,
    ts: request.slack_message.ts,
    text: topText,
    blocks,
  });

  await postMessage({
    channel: request.slack_message.channel,
    thread_ts: request.slack_message.ts,
    text: buildStatusInThreadText({
      state: request.state,
      by_slack_user_id: request.decided_by_slack_user_id,
      at_iso: request.decided_at,
    }),
  });

  await postAuditLog(request);
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}
