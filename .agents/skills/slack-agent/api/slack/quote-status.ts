import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifySlackSignature } from "../../lib/slack.js";
import { retrieve } from "../../lib/state.js";
import type { ApprovalRequest } from "../../lib/types.js";

export const config = { api: { bodyParser: false } };

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
  const text = (body.text ?? "").trim();
  const requestId = text.split(/\s+/)[0] ?? "";

  if (!requestId) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: "Usage: `/quote-status <request-id>` — find the ID in the original #deal-desk post or your bot DM.",
    });
  }

  const request = await retrieve<ApprovalRequest>(`approval:${requestId}`);
  if (!request) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: `No quote found for request ID \`${requestId}\`. It may have expired (30-day TTL) or the ID is wrong.`,
    });
  }

  return res.status(200).json({
    response_type: "ephemeral",
    blocks: buildStatusBlocks(request),
    text: `Quote ${requestId} — ${request.state}`,
  });
}

function buildStatusBlocks(r: ApprovalRequest): unknown[] {
  const fmtMoney = (n: number | null) => (n == null ? "—" : `$${n.toLocaleString()}`);
  const fmtPct = (n: number | null) => (n == null ? "—" : `${(n * 100).toFixed(1)}%`);
  const stateIcon =
    r.state === "approved" ? "✅" : r.state === "rejected" ? "❌" : "⏳";

  const blocks: unknown[] = [
    {
      type: "header",
      text: { type: "plain_text", text: `${stateIcon} Quote ${r.request_id} — ${r.state}` },
    },
    {
      type: "section",
      fields: [
        { type: "mrkdwn", text: `*Account*\n${r.context.account.name}` },
        { type: "mrkdwn", text: `*Opportunity*\n${r.context.opportunity.name}` },
        { type: "mrkdwn", text: `*Package*\n${r.form.package}` },
        { type: "mrkdwn", text: `*Total*\n${fmtMoney(r.pricing.total_amount)}` },
        { type: "mrkdwn", text: `*Discount*\n${fmtPct(r.pricing.discount_pct)}` },
        { type: "mrkdwn", text: `*Tier*\n${r.routing.tier}` },
      ],
    },
    {
      type: "section",
      text: { type: "mrkdwn", text: `*Submitted by*\n<@${r.requester.slack_user_id}> · ${r.created_at}` },
    },
  ];

  if (r.state !== "pending") {
    const by =
      r.decided_by_slack_user_id === "auto"
        ? "_auto-approved_"
        : r.decided_by_slack_user_id
          ? `<@${r.decided_by_slack_user_id}>`
          : r.decided_by_name ?? "—";
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Decided*\n${by} · ${r.decided_at ?? "—"}`,
      },
    });
  } else {
    const mentions = r.routing.allowed_approver_ids.map((id) => `<@${id}>`).join(" ");
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Awaiting approval from*\n${mentions || "_(no approvers resolved — needs admin override)_"}`,
      },
    });
  }

  if (r.slack_message) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `<https://slack.com/archives/${r.slack_message.channel}/p${r.slack_message.ts.replace(".", "")}|Open original #deal-desk post>`,
        },
      ],
    });
  }

  return blocks;
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
