import type { VercelRequest, VercelResponse } from "@vercel/node";
import { stash } from "../../lib/state.js";
import { openModal, verifySlackSignature } from "../../lib/slack.js";
import type { SlashCommandPayload } from "../../lib/types.js";

export const config = { api: { bodyParser: false } };

export const QUOTE_MANUAL_MODAL_CALLBACK = "quote_manual_modal_submit";

/**
 * /quote-manual <opp> -- RevOps-only escape hatch. Opens the same modal as
 * /quote, but submitting it bypasses routing/agent/approval entirely and
 * generates the order form directly. Used when something in the regular
 * flow has gone sideways (agent failure, routing oddity, stuck deal) and
 * RevOps needs to push a quote through manually.
 *
 * Gated to DEAL_DESK_APPROVER_IDS -- same list that can override approvals
 * by clicking buttons. Anyone else gets an ephemeral "not authorized".
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).send("Method not allowed");

  const rawBody = await readRawBody(req);
  const ok = verifySlackSignature(
    rawBody,
    headerString(req.headers["x-slack-request-timestamp"]),
    headerString(req.headers["x-slack-signature"]),
  );
  if (!ok) return res.status(401).send("Invalid Slack signature");

  const body = parseFormUrlEncoded(rawBody);
  const payload: SlashCommandPayload = {
    command: body.command ?? "",
    text: body.text ?? "",
    user_id: body.user_id ?? "",
    user_name: body.user_name ?? "",
    channel_id: body.channel_id ?? "",
    response_url: body.response_url ?? "",
    team_id: body.team_id ?? "",
    trigger_id: body.trigger_id ?? "",
  };

  const revops = parseCsvEnv(process.env.DEAL_DESK_APPROVER_IDS);
  if (!revops.includes(payload.user_id)) {
    return res.status(200).json({
      response_type: "ephemeral",
      text:
        `:lock: \`/quote-manual\` is RevOps-only. You (<@${payload.user_id}>) ` +
        `are not in \`DEAL_DESK_APPROVER_IDS\`.`,
    });
  }

  const intakeId = await stash({
    requester: {
      source: "slack" as const,
      slack_user_id: payload.user_id,
      slack_user_name: payload.user_name,
      confirmation_channel: payload.channel_id,
    },
  });

  try {
    await openModal(payload.trigger_id, buildManualQuoteModalView(intakeId, payload.text.trim()));
  } catch (e) {
    console.error("Failed to open manual quote modal:", e);
    return res.status(200).json({
      response_type: "ephemeral",
      text: "Couldn't open the manual quote modal. Try again in a moment.",
    });
  }

  return res.status(200).send("");
}

/**
 * Same blocks as the regular /quote modal -- intentionally a near-clone, not
 * a shared builder. Two reasons: (1) the manual modal needs a distinct
 * callback_id so interactivity.ts can branch to the bypass handler, and (2)
 * keeping it separate lets the title/submit/help text diverge if RevOps
 * needs a different surface later without disturbing the rep-facing modal.
 */
function buildManualQuoteModalView(intakeId: string, prefill: string) {
  return {
    type: "modal",
    callback_id: QUOTE_MANUAL_MODAL_CALLBACK,
    private_metadata: intakeId,
    title: { type: "plain_text", text: "Manual Quote (RevOps)" },
    submit: { type: "plain_text", text: "Generate" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text:
              ":warning: *Bypasses approvals.* Doc will be generated and DM'd to you. " +
              "A short audit note will post in #deal-desk.",
          },
        ],
      },
      {
        type: "input",
        block_id: "opportunity",
        label: { type: "plain_text", text: "Opportunity (name or 18-char ID)" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: prefill || undefined,
        },
      },
      {
        type: "input",
        block_id: "package",
        label: { type: "plain_text", text: "Package" },
        element: {
          type: "static_select",
          action_id: "value",
          options: [
            { text: { type: "plain_text", text: "Rogo Standard ($7,500 list/user)" }, value: "Standard" },
            { text: { type: "plain_text", text: "Rogo Premium ($10,000 list/user)" }, value: "Premium" },
            { text: { type: "plain_text", text: "Enterprise (custom pricing)" }, value: "Enterprise" },
          ],
        },
      },
      {
        type: "input",
        block_id: "users",
        label: { type: "plain_text", text: "Users (#)" },
        element: { type: "number_input", action_id: "value", is_decimal_allowed: false },
      },
      {
        type: "input",
        block_id: "price_per_user",
        label: { type: "plain_text", text: "Price per user ($USD, all-in including hosting)" },
        element: { type: "number_input", action_id: "value", is_decimal_allowed: true },
      },
      {
        type: "input",
        block_id: "total_credits",
        label: { type: "plain_text", text: "Total credits (#, includes any free credits)" },
        element: { type: "number_input", action_id: "value", is_decimal_allowed: false },
      },
      {
        type: "input",
        block_id: "free_credits",
        optional: true,
        label: { type: "plain_text", text: "Free credits given (#, subset of total)" },
        element: { type: "number_input", action_id: "value", is_decimal_allowed: false },
      },
      {
        type: "input",
        block_id: "hosting_fee",
        label: { type: "plain_text", text: "Hosting fee ($USD/year)" },
        element: { type: "number_input", action_id: "value", is_decimal_allowed: true },
      },
      {
        type: "input",
        block_id: "contract_start_date",
        label: { type: "plain_text", text: "Contract start date" },
        element: { type: "datepicker", action_id: "value" },
      },
      {
        type: "input",
        block_id: "contract_end_date",
        label: { type: "plain_text", text: "Contract end date" },
        element: { type: "datepicker", action_id: "value" },
      },
      {
        type: "input",
        block_id: "pricing_discussed",
        label: { type: "plain_text", text: "Pricing already discussed with customer?" },
        element: {
          type: "static_select",
          action_id: "value",
          options: [
            { text: { type: "plain_text", text: "Yes" }, value: "yes" },
            { text: { type: "plain_text", text: "No" }, value: "no" },
          ],
        },
      },
      {
        type: "input",
        block_id: "notes",
        optional: true,
        label: { type: "plain_text", text: "Notes (audit context)" },
        element: { type: "plain_text_input", action_id: "value", multiline: true },
      },
    ],
  };
}

function parseCsvEnv(v: string | undefined): string[] {
  if (!v) return [];
  return v.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
}

async function readRawBody(req: VercelRequest): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req as unknown as AsyncIterable<Buffer | string>) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
}

function parseFormUrlEncoded(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  const params = new URLSearchParams(body);
  for (const [k, v] of params.entries()) out[k] = v;
  return out;
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}
