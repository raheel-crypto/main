import { randomUUID } from "node:crypto";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { runQuoteAgent } from "../../lib/agent.js";
import { routeApproval } from "../../lib/approval.js";
import { fillOrderForm, orderFormFilename } from "../../lib/orderForm.js";
import { calculatePricing } from "../../lib/pricing.js";
import { postApprovalRequest, postAuditLog } from "../../lib/revops.js";
import { fetchTermsByCodes } from "../../lib/sfdc-client.js";
import { dmFileToUser, dmUser, uploadFileToThread } from "../../lib/slack.js";
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
  const { context, requester } = job;
  const form = job.form;

  // Hydrate selected legal terms before pricing/routing so the snapshot
  // freezes the term bodies at submit time. fetchTermsByCodes returns [] for
  // missing codes (logged) and an empty array if no codes were sent.
  form.selected_terms = await fetchTermsByCodes(job.selected_term_codes ?? []);

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

  // Write the Quote_Approval__c record for every submission — pending ones
  // get state=Pending, auto-approved get state=Approved. Manual decisions
  // upsert this same record (matched by Request_Id__c) when the buttons
  // are clicked, so we always have one row per quote.
  await postAuditLog(request);

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

    if (isAuto) {
      try {
        const file = await fillOrderForm(request);
        const filename = orderFormFilename(request);
        await dmFileToUser({
          userId: requester.slack_user_id,
          file,
          filename,
          initialComment:
            `Your order form for *${context.account.name}* ` +
            `(${context.opportunity.name}) is approved and ready for signature. ` +
            `Request ID: \`${request_id}\``,
        });

        // Also drop the generated doc into the approval thread so RevOps can
        // see what went out. Best-effort -- the rep DM is the primary path.
        if (request.slack_message) {
          try {
            await uploadFileToThread({
              channel: request.slack_message.channel,
              thread_ts: request.slack_message.ts,
              file,
              filename,
              initialComment: "Order form generated and sent to the rep.",
            });
          } catch (e) {
            console.error("order form thread mirror failed:", e);
          }
        }
      } catch (e) {
        console.error("order form delivery failed:", e);
      }
    }
  }
}

function headerString(v: string | string[] | undefined): string | undefined {
  if (Array.isArray(v)) return v[0];
  return v;
}
