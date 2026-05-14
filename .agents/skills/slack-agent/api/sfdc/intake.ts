import type { VercelRequest, VercelResponse } from "@vercel/node";
import { getOpportunityById, toDealContext } from "../../lib/sfdc-client.js";
import type { Package, ProcessQuoteJob, QuoteForm, Requester } from "../../lib/types.js";

interface IntakePayload {
  opportunity_id: string;
  form: {
    package: string;
    users: number;
    price_per_user: number;
    total_credits: number;
    free_credits?: number;
    hosting_fee: number;
    pricing_discussed: boolean;
    contract_start_date?: string;
    contract_end_date?: string;
    notes?: string;
  };
  requester: {
    slack_user_id: string;
    slack_user_name?: string | null;
  };
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).send("Method not allowed");

  // Accept the secret in any of the headers v1 setups have used in the
  // wild. Node lowercases incoming header names.
  const provided =
    headerString(req.headers["x-intake-secret"]) ??
    headerString(req.headers["x-sfdc-secret"]) ??
    stripBearer(headerString(req.headers["authorization"]));
  const expected = process.env.SFDC_INTAKE_SECRET;
  if (!expected || !provided || provided !== expected) {
    return res.status(401).send("Unauthorized");
  }

  const payload = req.body as IntakePayload | undefined;
  if (!payload?.opportunity_id || !payload?.form || !payload?.requester) {
    return res.status(400).json({ error: "Missing opportunity_id, form, or requester" });
  }

  const opp = await getOpportunityById(payload.opportunity_id);
  if (!opp) {
    return res.status(404).json({ error: "Opportunity not found" });
  }

  const context = toDealContext(opp);
  const form: QuoteForm = {
    package: payload.form.package as Package,
    users: Number(payload.form.users),
    price_per_user: Number(payload.form.price_per_user),
    total_credits: Number(payload.form.total_credits),
    free_credits: Number(payload.form.free_credits ?? 0),
    hosting_fee: Number(payload.form.hosting_fee),
    pricing_discussed: !!payload.form.pricing_discussed,
    contract_start_date: String(payload.form.contract_start_date ?? ""),
    contract_end_date: String(payload.form.contract_end_date ?? ""),
    notes: String(payload.form.notes ?? ""),
  };
  const requester: Requester = {
    source: "salesforce",
    slack_user_id: payload.requester.slack_user_id,
    slack_user_name: payload.requester.slack_user_name ?? null,
    confirmation_channel: null,
  };

  const job: ProcessQuoteJob = { context, form, requester };

  // Fire-and-forget the processor. Apex callout returns quickly so the
  // LWC can show a success toast while the agent + Slack post happen async.
  await fireProcessor(job);

  return res.status(200).json({ ok: true });
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
    if (!(e instanceof Error && e.name === "AbortError")) {
      console.error("Processor fire failed:", e);
    }
  } finally {
    clearTimeout(timeout);
  }
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}

function stripBearer(v: string | undefined): string | undefined {
  if (!v) return v;
  return v.replace(/^Bearer\s+/i, "");
}
