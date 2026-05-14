import { buildApprovalBlocks, buildStatusInThreadText, buildTopLineText } from "./blocks.js";
import { upsertByExternalId } from "./sfdc-client.js";
import { postMessage, updateMessage } from "./slack.js";
import type { ApprovalRequest } from "./types.js";

/**
 * Upsert a Quote_Approval__c record matching this request. Called twice in
 * the lifecycle:
 *   1) From process-quote.ts right after the channel post — creates the
 *      record with state = Pending (or Approved for auto-approved).
 *   2) From postDecisionUpdate below when a button click flips state, OR
 *      from /quote-override when an admin force-decides.
 *
 * Best-effort — SFDC failures are logged but never thrown, so a bad SFDC
 * write can't break the Slack approval flow.
 */
export async function postAuditLog(request: ApprovalRequest): Promise<void> {
  try {
    await upsertByExternalId(
      "Quote_Approval__c",
      "Request_Id__c",
      request.request_id,
      toQuoteApprovalFields(request),
    );
  } catch (e) {
    console.error("Quote_Approval__c upsert failed:", e);
  }
}

function toQuoteApprovalFields(r: ApprovalRequest): Record<string, unknown> {
  const state =
    r.state === "approved" ? "Approved" : r.state === "rejected" ? "Rejected" : "Pending";
  const wasOverride =
    typeof r.decided_by_name === "string" && r.decided_by_name.includes("(override)");
  const slackUrl = r.slack_message
    ? `https://slack.com/archives/${r.slack_message.channel}/p${r.slack_message.ts.replace(".", "")}`
    : null;

  return {
    Opportunity__c: r.context.opportunity.id,
    State__c: state,
    Approval_Tier__c: r.routing.tier_label,
    Decided_By_Name__c: r.decided_by_name,
    Decision_Made_At__c: r.decided_at,
    Was_Override__c: wasOverride,
    Package__c: r.form.package,
    Users__c: r.form.users,
    Price_Per_User__c: r.form.price_per_user,
    Total_Amount__c: r.pricing.total_amount,
    Discount_Pct__c: r.pricing.discount_pct,
    ARR__c: r.pricing.arr,
    TCV__c: r.pricing.tcv,
    Contract_Start_Date__c: r.form.contract_start_date || null,
    Contract_End_Date__c: r.form.contract_end_date || null,
    Pricing_Discussed__c: r.form.pricing_discussed,
    Notes__c: r.form.notes,
    Submitted_By_Name__c: r.requester.slack_user_name,
    Source__c: r.requester.source === "salesforce" ? "Salesforce" : "Slack",
    Slack_Message_Url__c: slackUrl,
  };
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
