import type { VercelRequest, VercelResponse } from "@vercel/node";
import { buildMarkClosedWonPromptBlocks } from "../../lib/blocks.js";
import {
  getLatestApprovedQuoteApproval,
  getOpportunityById,
  parseSlackArchiveUrl,
} from "../../lib/sfdc-client.js";
import { postMessage } from "../../lib/slack.js";

/**
 * Triggered when a rep finishes the "upload signed order form" screen flow in
 * Salesforce. Posts a threaded reply to the original approval message in
 * #deal-desk with a "Mark Closed Won" button for RevOps to click.
 *
 * Same auth pattern as `/api/sfdc/intake` — accepts the shared secret via
 * `X-SFDC-Secret`, `X-Intake-Secret`, or `Authorization: Bearer`.
 */
interface SignedPayload {
  opportunity_id: string;
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).send("Method not allowed");

  const provided =
    headerString(req.headers["x-intake-secret"]) ??
    headerString(req.headers["x-sfdc-secret"]) ??
    stripBearer(headerString(req.headers["authorization"]));
  const expected = process.env.SFDC_INTAKE_SECRET;
  if (!expected || !provided || provided !== expected) {
    return res.status(401).send("Unauthorized");
  }

  const payload = req.body as SignedPayload | undefined;
  if (!payload?.opportunity_id) {
    return res.status(400).json({ error: "Missing opportunity_id" });
  }

  const opp = await getOpportunityById(payload.opportunity_id);
  if (!opp) return res.status(404).json({ error: "Opportunity not found" });

  // Idempotency: if the Opp is already Closed Won, the click side has nothing
  // to do. Skip the ping rather than nag RevOps.
  if (opp.StageName === "Closed Won") {
    return res.status(200).json({ ok: true, skipped: "already_closed_won" });
  }

  const audit = await getLatestApprovedQuoteApproval(payload.opportunity_id);
  if (!audit) {
    return res
      .status(404)
      .json({ error: "No approved Quote_Approval__c found for this Opportunity" });
  }

  const ref = parseSlackArchiveUrl(audit.slackMessageUrl);
  if (!ref) {
    return res
      .status(422)
      .json({ error: "Approved quote has no parseable Slack message URL" });
  }

  const blocks = buildMarkClosedWonPromptBlocks({
    accountName: opp.Account?.Name ?? "this account",
    opportunityId: payload.opportunity_id,
  });

  await postMessage({
    channel: ref.channel,
    thread_ts: ref.ts,
    text: `Signed order form received for ${opp.Account?.Name ?? "this account"} — ready to mark Closed Won?`,
    blocks,
  });

  return res.status(200).json({ ok: true });
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}

function stripBearer(v: string | undefined): string | undefined {
  if (!v) return v;
  return v.replace(/^Bearer\s+/i, "");
}
