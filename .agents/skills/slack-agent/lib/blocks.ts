import type {
  AgentOutput,
  ApprovalRequest,
  ApprovalRouting,
  ApprovalState,
  DealContext,
  PricingBreakdown,
  QuoteForm,
} from "./types.js";

const APPROVE_ACTION_ID = "quote_approve";
const REJECT_ACTION_ID = "quote_reject";

interface BuildArgs {
  request_id: string;
  state: ApprovalState;
  context: DealContext;
  form: QuoteForm;
  pricing: PricingBreakdown;
  routing: ApprovalRouting;
  agent: AgentOutput;
  requester_slack_user_id: string;
  decided_by_name?: string | null;
  decided_at?: string | null;
  sfdc_instance_url?: string | null;
}

export function buildApprovalBlocks(args: BuildArgs): unknown[] {
  const { context, form, pricing, routing, agent, state } = args;
  const isEnterprise = form.package === "Enterprise";
  const headerStatus =
    state === "approved"
      ? "Approved"
      : state === "rejected"
        ? "Rejected"
        : routing.tier === "auto"
          ? "Auto-approved"
          : "Approval Required";

  const blocks: unknown[] = [
    {
      type: "header",
      text: { type: "plain_text", text: `${context.account.name} — ${headerStatus}` },
    },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: statusIcon(state, routing) + " " + routing.tier_label }],
    },
    { type: "divider" },
    {
      type: "section",
      fields: [
        { type: "mrkdwn", text: `*Opportunity*\n${context.opportunity.name}` },
        { type: "mrkdwn", text: `*Account*\n${context.account.name}` },
        { type: "mrkdwn", text: `*Segment*\n${context.account.segment ?? "—"}` },
        { type: "mrkdwn", text: `*Owner*\n${context.opportunity.owner_name}` },
        { type: "mrkdwn", text: `*Close date*\n${context.opportunity.close_date}` },
        { type: "mrkdwn", text: `*Package*\n${form.package}` },
      ],
    },
    {
      type: "section",
      fields: [
        { type: "mrkdwn", text: `*Users*\n${fmtNum(form.users)}` },
        { type: "mrkdwn", text: `*Price per user*\n${fmtMoney(form.price_per_user)}` },
        ...(isEnterprise
          ? []
          : [
              {
                type: "mrkdwn",
                text: `*Discount*\n${pricing.discount_pct != null ? fmtPct(pricing.discount_pct) : "—"} (${pricing.discount_per_user != null ? fmtMoney(pricing.discount_per_user) : "—"}/user)`,
              },
            ]),
        { type: "mrkdwn", text: `*Total credits*\n${fmtNum(form.total_credits)}` },
        { type: "mrkdwn", text: `*Hosting fee*\n${fmtMoney(form.hosting_fee)}/yr` },
        { type: "mrkdwn", text: `*Pricing discussed*\n${form.pricing_discussed ? "Yes" : "No"}` },
      ],
    },
    { type: "divider" },
    {
      type: "section",
      text: { type: "mrkdwn", text: "*Calculated totals*" },
    },
    {
      type: "section",
      fields: [
        { type: "mrkdwn", text: `*Platform fee*\n${fmtMoney(pricing.platform_fee_total)}` },
        { type: "mrkdwn", text: `*Credits commit*\n${fmtMoney(pricing.credits_commit_total)}` },
        { type: "mrkdwn", text: `*Hosting*\n${fmtMoney(pricing.hosting_fee_total)}` },
        { type: "mrkdwn", text: `*Total contract value*\n*${fmtMoney(pricing.total_amount)}*` },
      ],
    },
  ];

  if (form.notes.trim()) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Notes for Deal Desk*\n${form.notes}` },
    });
  }

  blocks.push({ type: "divider" });
  blocks.push({
    type: "section",
    text: { type: "mrkdwn", text: `*Agent summary*\n${agent.summary || "_(no summary)_"}` },
  });
  if (agent.flags.length > 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: "*Flags*\n" + agent.flags.map((f) => `• ${f}`).join("\n"),
      },
    });
  }

  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text: `Requested by <@${args.requester_slack_user_id}> · Request ID \`${args.request_id}\``,
      },
    ],
  });

  if (state === "pending" && routing.tier !== "auto") {
    blocks.push({
      type: "actions",
      block_id: `quote_actions_${args.request_id}`,
      elements: [
        {
          type: "button",
          action_id: APPROVE_ACTION_ID,
          text: { type: "plain_text", text: "Approve" },
          style: "primary",
          value: args.request_id,
        },
        {
          type: "button",
          action_id: REJECT_ACTION_ID,
          text: { type: "plain_text", text: "Reject" },
          style: "danger",
          value: args.request_id,
        },
        ...(args.sfdc_instance_url
          ? [
              {
                type: "button",
                action_id: "quote_view_sfdc",
                text: { type: "plain_text", text: "View in Salesforce" },
                url: `${args.sfdc_instance_url}/${context.opportunity.id}`,
              },
            ]
          : []),
      ],
    });
  } else if (state !== "pending") {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `${state === "approved" ? "✅" : "❌"} ${state === "approved" ? "Approved" : "Rejected"} by ${args.decided_by_name ?? "—"}${args.decided_at ? ` at ${args.decided_at}` : ""}`,
        },
      ],
    });
  }

  return blocks;
}

/** Top-line text for the channel post (includes approver @-mentions). */
export function buildTopLineText(request: Pick<ApprovalRequest, "routing" | "context" | "pricing" | "form">): string {
  const { routing, context, form, pricing } = request;
  const mentions = routing.allowed_approver_ids.map((id) => `<@${id}>`).join(" ");
  const discountFragment =
    pricing.discount_pct != null ? ` · ${fmtPct(pricing.discount_pct)} discount` : "";
  const head = `*Quote: ${context.account.name}* · ${form.package} · ${fmtNum(form.users)} users${discountFragment}`;
  if (routing.tier === "auto") return `${head} — auto-approved`;
  return `${head}\n${mentions} — ${routing.tier_label}`;
}

export function buildStatusInThreadText(args: {
  state: ApprovalState;
  by_slack_user_id: string;
  at_iso: string;
}): string {
  const icon = args.state === "approved" ? "✅" : "❌";
  const verb = args.state === "approved" ? "Approved" : "Rejected";
  return `${icon} ${verb} by <@${args.by_slack_user_id}> at ${args.at_iso}`;
}

function statusIcon(state: ApprovalState, routing: ApprovalRouting): string {
  if (state === "approved") return "✅";
  if (state === "rejected") return "❌";
  if (routing.tier === "auto") return "✅";
  return "⚠️";
}

function fmtMoney(n: number | null | undefined): string {
  if (n == null) return "—";
  return `$${n.toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
}

function fmtNum(n: number | null | undefined): string {
  if (n == null) return "—";
  return n.toLocaleString();
}

function fmtPct(n: number): string {
  return `${(n * 100).toFixed(1)}%`;
}
