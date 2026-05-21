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
    console.warn("[signed] auth failed", {
      hasExpected: !!expected,
      hasProvided: !!provided,
      contentType: req.headers["content-type"],
    });
    return res.status(401).send("Unauthorized");
  }

  // Vercel's body parser only auto-parses JSON when Content-Type is
  // application/json. Salesforce External Services callouts sometimes ship
  // with text/plain or no content-type at all — fall back to parsing the
  // raw string ourselves so the flow side doesn't have to fight headers.
  // Also accept the opportunity_id as a query parameter, since SFDC External
  // Services surfaces query params as clean Flow inputs but treats JSON
  // bodies as opaque Apex-defined objects.
  const fromBody = coercePayload(req.body)?.opportunity_id;
  const fromQuery =
    typeof req.query.opportunity_id === "string" ? req.query.opportunity_id : undefined;
  const opportunityId = fromQuery ?? fromBody;

  console.log("[signed] received", {
    contentType: req.headers["content-type"],
    rawBodyType: typeof req.body,
    parsedOpportunityId: opportunityId ?? null,
    source: fromQuery ? "query" : fromBody ? "body" : "none",
  });

  if (!opportunityId) {
    return res.status(400).json({
      error: "Missing opportunity_id (accepted as query param or JSON body field)",
      bodyType: typeof req.body,
    });
  }

  const opp = await getOpportunityById(opportunityId);
  if (!opp) return res.status(404).json({ error: "Opportunity not found" });

  // Idempotency: if the Opp is already Closed Won, the click side has nothing
  // to do. Skip the ping rather than nag RevOps.
  if (opp.StageName === "Closed Won") {
    return res.status(200).json({ ok: true, skipped: "already_closed_won" });
  }

  const audit = await getLatestApprovedQuoteApproval(opportunityId);
  if (!audit) {
    return res.status(404).json({
      error:
        "No approved Quote_Approval__c with a Slack message URL found for this Opportunity",
    });
  }

  const ref = parseSlackArchiveUrl(audit.slackMessageUrl);
  console.log("[signed] resolved approval", {
    requestId: audit.requestId,
    slackMessageUrl: audit.slackMessageUrl,
    parsed: ref,
  });
  if (!ref) {
    return res.status(422).json({
      error: "Slack message URL on the approval does not match expected format",
      requestId: audit.requestId,
      slackMessageUrl: audit.slackMessageUrl ?? null,
      slackMessageUrlType: typeof audit.slackMessageUrl,
      slackMessageUrlLength:
        typeof audit.slackMessageUrl === "string" ? audit.slackMessageUrl.length : null,
      // Echo the raw SFDC record so we can see exact field names if the
      // lookup is missing keys due to canonical case differences.
      rawRecordKeys: Object.keys(audit.raw),
    });
  }

  const blocks = buildMarkClosedWonPromptBlocks({
    accountName: opp.Account?.Name ?? "this account",
    opportunityId,
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

/** Accept body as parsed object, JSON string, or Buffer. */
function coercePayload(body: unknown): SignedPayload | undefined {
  if (!body) return undefined;
  if (typeof body === "object" && !Buffer.isBuffer(body)) {
    return body as SignedPayload;
  }
  const text = Buffer.isBuffer(body) ? body.toString("utf-8") : String(body);
  try {
    return JSON.parse(text) as SignedPayload;
  } catch {
    return undefined;
  }
}
