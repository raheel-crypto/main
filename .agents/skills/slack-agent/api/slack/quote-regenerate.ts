import type { VercelRequest, VercelResponse } from "@vercel/node";
import { deliverOrderForm } from "../../lib/orderForm.js";
import { verifySlackSignature } from "../../lib/slack.js";
import { retrieve } from "../../lib/state.js";
import type { ApprovalRequest } from "../../lib/types.js";

export const config = { api: { bodyParser: false } };

/**
 * /quote-regenerate <request-id> -- RevOps-only. Re-runs order form
 * generation for an already-approved deal and re-DMs it to the original
 * requester. Use when the doc generation failed silently the first time
 * (Vercel cache, transient SFDC error, missing template, etc.) and the
 * deal is sitting in state=approved with no doc delivered.
 *
 * Only works on state=approved requests. For pending deals use the
 * buttons or /quote-override; for rejected deals nothing happens here.
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
  const userId = body.user_id ?? "";
  const text = (body.text ?? "").trim();
  const requestId = text.split(/\s+/)[0];

  if (!requestId) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: "Usage: `/quote-regenerate <request-id>` — regenerate the order form for an already-approved deal.",
    });
  }

  const revops = parseCsvEnv(process.env.DEAL_DESK_APPROVER_IDS);
  if (!revops.includes(userId)) {
    return res.status(200).json({
      response_type: "ephemeral",
      text:
        `:lock: \`/quote-regenerate\` is RevOps-only. You (<@${userId}>) ` +
        `are not in \`DEAL_DESK_APPROVER_IDS\`.`,
    });
  }

  const request = await retrieve<ApprovalRequest>(`approval:${requestId}`);
  if (!request) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: `No quote found for request ID \`${requestId}\`.`,
    });
  }

  if (request.state !== "approved") {
    return res.status(200).json({
      response_type: "ephemeral",
      text:
        `Quote \`${requestId}\` is *${request.state}*, not approved. ` +
        `Approve it first (buttons or \`/quote-override\`), then re-run \`/quote-regenerate\`.`,
    });
  }

  // Synchronous so Vercel keeps the function alive through Slack uploads.
  // deliverOrderForm swallows its own errors -- if generation fails we'll
  // see it in Vercel logs and the user sees the ephemeral below regardless.
  try {
    await deliverOrderForm(request);
    return res.status(200).json({
      response_type: "ephemeral",
      text:
        `:arrows_counterclockwise: Re-ran doc generation for \`${requestId}\` ` +
        `(${request.context.account.name}). DM'd to <@${request.requester.slack_user_id}>.`,
    });
  } catch (e) {
    console.error("quote-regenerate failed:", e);
    return res.status(200).json({
      response_type: "ephemeral",
      text: `:warning: Regeneration failed: ${(e as Error).message}. Check Vercel logs.`,
    });
  }
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
