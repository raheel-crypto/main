import type { VercelRequest, VercelResponse } from "@vercel/node";
import { postDecisionUpdate } from "../../lib/revops.js";
import { verifySlackSignature } from "../../lib/slack.js";
import { retrieve, stashAt } from "../../lib/state.js";
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
  const userId = body.user_id ?? "";
  const userName = body.user_name ?? userId;
  const text = (body.text ?? "").trim();
  const [requestId, action] = text.split(/\s+/);

  if (!requestId || !action || !["approve", "reject"].includes(action.toLowerCase())) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: "Usage: `/quote-override <request-id> approve|reject` — admin-only override of the approval routing.",
    });
  }

  const admins = parseCsvEnv(process.env.ADMIN_SLACK_USER_IDS);
  if (!admins.includes(userId)) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: `:lock: Override is admin-only. You (<@${userId}>) are not in \`ADMIN_SLACK_USER_IDS\`.`,
    });
  }

  const request = await retrieve<ApprovalRequest>(`approval:${requestId}`);
  if (!request) {
    return res.status(200).json({
      response_type: "ephemeral",
      text: `No quote found for request ID \`${requestId}\`.`,
    });
  }

  if (request.state !== "pending") {
    return res.status(200).json({
      response_type: "ephemeral",
      text: `Quote \`${requestId}\` is already *${request.state}* by ${request.decided_by_name ?? "—"}. Nothing to override.`,
    });
  }

  // Do the work synchronously — Vercel Fluid Compute would kill us if we
  // responded first. The work is 2 Slack API calls + Chatter post, fits
  // well under Slack's 3-second slash command timeout.
  try {
    request.state = action.toLowerCase() === "approve" ? "approved" : "rejected";
    request.decided_at = new Date().toISOString();
    request.decided_by_slack_user_id = userId;
    request.decided_by_name = `${userName} (override)`;

    await stashAt(`approval:${requestId}`, request, 60 * 60 * 24 * 30);
    await postDecisionUpdate(request);

    return res.status(200).json({
      response_type: "ephemeral",
      text: `:white_check_mark: Force-${action.toLowerCase()} applied to \`${requestId}\`. #deal-desk post updated.`,
    });
  } catch (e) {
    console.error("quote-override failed:", e);
    return res.status(200).json({
      response_type: "ephemeral",
      text: `:warning: Override partially failed: ${(e as Error).message}. Check Vercel logs.`,
    });
  }
}

function parseCsvEnv(v: string | undefined): string[] {
  if (!v) return [];
  return v
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
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
