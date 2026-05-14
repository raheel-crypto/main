import { randomUUID } from "node:crypto";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { runQuoteAgent } from "../../lib/agent.js";
import { routeApproval } from "../../lib/approval.js";
import { calculatePricing } from "../../lib/pricing.js";
import { postApprovalRequest } from "../../lib/revops.js";
import { dmUser } from "../../lib/slack.js";
import { stashAt } from "../../lib/state.js";
import type { AgentOutput, ApprovalRequest, ProcessQuoteJob } from "../../lib/types.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).send("Method not allowed");

  const provided = headerString(req.headers["x-runner-secret"]);
  if (!provided || provided !== process.env.RUNNER_SECRET) {
    return res.status(401).send("Unauthorized");
  }

  const job = req.body as ProcessQuoteJob;
  if (!job?.form || !job?.context || !job?.requester) {
    return res.status(400).send("Bad job payload");
  }

  // Do the work BEFORE responding. Vercel Fluid Compute suspends the function
  // once res.send() runs, even if there's pending async work. The caller
  // (interactivity.ts) uses AbortController with a 2s timeout, so it doesn't
  // wait for us anyway — but the function itself must stay alive.
  try {
    await processJob(job);
    return res.status(200).send("");
  } catch (e) {
    console.error("process-quote failed:", e);
    if (job.requester.slack_user_id) {
      try {
        await dmUser(
          job.requester.slack_user_id,
          `:warning: Your quote request hit an error: ${(e as Error).message}`,
        );
      } catch {
        // best-effort
      }
    }
    return res.status(500).send("Processing error");
  }
}

async function processJob(job: ProcessQuoteJob): Promise<void> {
  const { context, form, requester } = job;

  const pricing = calculatePricing(form);
  const routing = routeApproval(form, pricing, context);

  let agent: AgentOutput;
  try {
    const result = await runQuoteAgent({ context, form, pricing, routing });
    agent = result.output;
  } catch (e) {
    console.error("agent run failed:", e);
    agent = { summary: "", flags: [`Agent run failed: ${(e as Error).message}`] };
  }

  // If we routed to pod_leader / james / deal_desk but ended up with no allowed
  // approvers (manager not resolved, env var unset), surface that loudly.
  if (routing.tier !== "auto" && routing.allowed_approver_ids.length === 0) {
    agent = {
      ...agent,
      flags: [
        `:rotating_light: Could not resolve any Slack approver for tier "${routing.tier}". Check Opp Owner's Manager has Slack_User_Id__c set, or the relevant env var is configured.`,
        ...agent.flags,
      ],
    };
  }

  const request_id = randomUUID().slice(0, 8);
  const isAuto = routing.tier === "auto";

  const request: ApprovalRequest = {
    request_id,
    state: isAuto ? "approved" : "pending",
    created_at: new Date().toISOString(),
    decided_at: isAuto ? new Date().toISOString() : null,
    decided_by_slack_user_id: isAuto ? "auto" : null,
    decided_by_name: isAuto ? "auto-approved" : null,
    routing,
    context,
    form,
    pricing,
    agent,
    requester,
    slack_message: null,
  };

  const posted = await postApprovalRequest(request);
  request.slack_message = posted.ts ? { channel: posted.channel, ts: posted.ts } : null;

  await stashAt(`approval:${request_id}`, request, 60 * 60 * 24 * 30);

  if (requester.slack_user_id) {
    const verb = isAuto ? "auto-approved and posted" : "posted for approval";
    try {
      await dmUser(
        requester.slack_user_id,
        `Your quote request for *${context.account.name}* (${context.opportunity.name}) has been ${verb} in #deal-desk. Request ID: \`${request_id}\``,
      );
    } catch (e) {
      console.error("requester DM failed:", e);
    }
  }
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}
