import type { VercelRequest, VercelResponse } from "@vercel/node";
import { isAuthorizedApprover } from "../../lib/approval.js";
import { postDecisionUpdate } from "../../lib/revops.js";
import { drop, retrieve, stashAt } from "../../lib/state.js";
import { updateViaResponseUrl, verifySlackSignature } from "../../lib/slack.js";
import { resolveOpportunity, toDealContext } from "../../lib/sfdc-client.js";
import type { ApprovalRequest, Package, ProcessQuoteJob, QuoteForm, Requester } from "../../lib/types.js";

export const config = { api: { bodyParser: false } };

const QUOTE_MODAL_CALLBACK = "quote_modal_submit";
const APPROVE_ACTION_ID = "quote_approve";
const REJECT_ACTION_ID = "quote_reject";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return res.status(405).send("Method not allowed");
  }

  const rawBody = await readRawBody(req);
  const ok = verifySlackSignature(
    rawBody,
    headerString(req.headers["x-slack-request-timestamp"]),
    headerString(req.headers["x-slack-signature"]),
  );
  if (!ok) return res.status(401).send("Invalid Slack signature");

  const params = new URLSearchParams(rawBody);
  const payloadStr = params.get("payload");
  if (!payloadStr) return res.status(400).send("Missing payload");

  let payload: SlackInteractivityPayload;
  try {
    payload = JSON.parse(payloadStr);
  } catch {
    return res.status(400).send("Bad payload");
  }

  if (payload.type === "view_submission" && payload.view?.callback_id === QUOTE_MODAL_CALLBACK) {
    return handleQuoteModalSubmit(payload, res);
  }

  if (payload.type === "block_actions") {
    const action = payload.actions?.[0];
    if (!action) return res.status(200).send("");
    if (action.action_id === APPROVE_ACTION_ID || action.action_id === REJECT_ACTION_ID) {
      return handleApproveReject(payload, action, res);
    }
  }

  return res.status(200).send("");
}

async function handleQuoteModalSubmit(payload: SlackInteractivityPayload, res: VercelResponse) {
  const view = payload.view!;
  const values = view.state?.values ?? {};

  const oppInput = (values.opportunity?.value?.value ?? "").trim();
  const pkg = values.package?.value?.selected_option?.value as Package | undefined;
  const usersRaw = values.users?.value?.value ?? "";
  const ppuRaw = values.price_per_user?.value?.value ?? "";
  const creditsRaw = values.total_credits?.value?.value ?? "";
  const freeCreditsRaw = values.free_credits?.value?.value ?? "0";
  const hostingRaw = values.hosting_fee?.value?.value ?? "";
  const discussedRaw = values.pricing_discussed?.value?.selected_option?.value ?? "";
  const notes = values.notes?.value?.value ?? "";

  const errors: Record<string, string> = {};
  if (!oppInput) errors.opportunity = "Required";
  if (!pkg) errors.package = "Required";
  const users = Number(usersRaw);
  if (!Number.isFinite(users) || users <= 0) errors.users = "Must be a positive number";
  const price_per_user = Number(ppuRaw);
  if (!Number.isFinite(price_per_user) || price_per_user < 0) errors.price_per_user = "Must be ≥ 0";
  const total_credits = Number(creditsRaw);
  if (!Number.isFinite(total_credits) || total_credits < 0) errors.total_credits = "Must be ≥ 0";
  const free_credits = Number(freeCreditsRaw);
  if (!Number.isFinite(free_credits) || free_credits < 0) errors.free_credits = "Must be ≥ 0";
  const hosting_fee = Number(hostingRaw);
  if (!Number.isFinite(hosting_fee) || hosting_fee < 0) errors.hosting_fee = "Must be ≥ 0";
  if (!discussedRaw) errors.pricing_discussed = "Required";

  if (Object.keys(errors).length > 0) {
    return res.status(200).json({ response_action: "errors", errors });
  }

  const resolved = await resolveOpportunity(oppInput);
  if (resolved.status === "not_found") {
    return res.status(200).json({
      response_action: "errors",
      errors: { opportunity: "No open opportunity matched. Try the 18-char SFDC ID." },
    });
  }
  if (resolved.status === "ambiguous") {
    const top = (resolved.matches ?? []).slice(0, 3).map((m) => m.Name).join(", ");
    return res.status(200).json({
      response_action: "errors",
      errors: {
        opportunity: `Multiple matches (${top}…). Paste the 18-char SFDC ID instead.`,
      },
    });
  }

  const context = toDealContext(resolved.opportunity!);
  const form: QuoteForm = {
    package: pkg!,
    users,
    price_per_user,
    total_credits,
    free_credits,
    hosting_fee,
    pricing_discussed: discussedRaw === "yes",
    notes,
  };

  const intakeId = view.private_metadata;
  const intake = intakeId ? await retrieve<{ requester: Requester }>(intakeId) : null;
  const requester: Requester = intake?.requester ?? {
    source: "slack",
    slack_user_id: payload.user?.id ?? "",
    slack_user_name: payload.user?.username ?? null,
    confirmation_channel: null,
  };

  const job: ProcessQuoteJob = { context, form, requester };
  await fireProcessor(job);

  return res.status(200).json({ response_action: "clear" });
}

async function handleApproveReject(
  payload: SlackInteractivityPayload,
  action: { action_id: string; value?: string },
  res: VercelResponse,
) {
  const requestId = action.value;
  if (!requestId) return res.status(200).send("");

  const request = await retrieve<ApprovalRequest>(`approval:${requestId}`);
  if (!request) {
    if (payload.response_url) {
      await updateViaResponseUrl(payload.response_url, {
        response_type: "ephemeral",
        text: "This request is no longer available (it may have expired).",
        replace_original: false,
      });
    }
    return res.status(200).send("");
  }

  const userId = payload.user?.id ?? "";

  if (request.state !== "pending") {
    if (payload.response_url) {
      await updateViaResponseUrl(payload.response_url, {
        response_type: "ephemeral",
        text: `Already ${request.state} by ${request.decided_by_name ?? "—"}.`,
        replace_original: false,
      });
    }
    return res.status(200).send("");
  }

  if (!isAuthorizedApprover(request.routing, userId)) {
    const names = request.routing.allowed_approver_ids.map((id) => `<@${id}>`).join(" or ");
    if (payload.response_url) {
      await updateViaResponseUrl(payload.response_url, {
        response_type: "ephemeral",
        text: `Only ${names || "the assigned approver"} can act on this request.`,
        replace_original: false,
      });
    }
    return res.status(200).send("");
  }

  request.state = action.action_id === APPROVE_ACTION_ID ? "approved" : "rejected";
  request.decided_at = new Date().toISOString();
  request.decided_by_slack_user_id = userId;
  request.decided_by_name = payload.user?.username ?? payload.user?.name ?? userId;

  await stashAt(`approval:${requestId}`, request, 60 * 60 * 24 * 30);
  await postDecisionUpdate(request);

  return res.status(200).send("");
}

async function fireProcessor(job: ProcessQuoteJob): Promise<void> {
  const url = process.env.RUNNER_URL;
  const secret = process.env.RUNNER_SECRET;
  if (!url || !secret) {
    console.error("RUNNER_URL or RUNNER_SECRET not set — cannot fire processor");
    return;
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  try {
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-runner-secret": secret },
      body: JSON.stringify(job),
      signal: controller.signal,
    });
  } catch (e) {
    // AbortError is expected — request has left the function by then.
    if (!(e instanceof Error && e.name === "AbortError")) {
      console.error("Processor fire failed:", e);
    }
  } finally {
    clearTimeout(timeout);
  }
}

async function readRawBody(req: VercelRequest): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req as unknown as AsyncIterable<Buffer | string>) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}

// ----- Slack interactivity payload (minimal shape we care about) -----
interface SlackInteractivityPayload {
  type: "view_submission" | "block_actions" | string;
  user?: { id: string; username?: string; name?: string };
  response_url?: string;
  trigger_id?: string;
  actions?: Array<{ action_id: string; value?: string; block_id?: string }>;
  view?: {
    id: string;
    callback_id?: string;
    private_metadata?: string;
    state?: { values?: Record<string, Record<string, ViewStateValue>> };
  };
}

interface ViewStateValue {
  type?: string;
  value?: string;
  selected_option?: { value: string };
}
