import Anthropic from "@anthropic-ai/sdk";
import { loadSystemPrompt } from "./prompt.js";
import type { AgentOutput, ApprovalRouting, DealContext, PricingBreakdown, QuoteForm } from "./types.js";

const anthropic = new Anthropic();

export interface AgentRunResult {
  output: AgentOutput;
  rawText: string;
  usage: unknown;
}

export async function runQuoteAgent(args: {
  context: DealContext;
  form: QuoteForm;
  pricing: PricingBreakdown;
  routing: ApprovalRouting;
}): Promise<AgentRunResult> {
  const systemPrompt = loadSystemPrompt();
  const userPrompt = buildUserPrompt(args);

  const response = await anthropic.messages.create({
    model: "claude-opus-4-7",
    max_tokens: 1024,
    system: systemPrompt,
    messages: [{ role: "user", content: userPrompt }],
  });

  const textBlocks = response.content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text);
  const rawText = textBlocks.join("\n");

  return {
    output: parseAgentOutput(rawText),
    rawText,
    usage: response.usage,
  };
}

function buildUserPrompt(args: {
  context: DealContext;
  form: QuoteForm;
  pricing: PricingBreakdown;
  routing: ApprovalRouting;
}): string {
  const { context, form, pricing, routing } = args;
  const fmtMoney = (n: number | null) => (n == null ? "n/a" : `$${n.toLocaleString()}`);
  const fmtPct = (n: number | null) => (n == null ? "n/a" : `${(n * 100).toFixed(1)}%`);

  return [
    "Generate the JSON object for this quote request.",
    "",
    "## Opportunity",
    `- Account: ${context.account.name} (${context.account.id})`,
    `- Segment: ${context.account.segment ?? "n/a"}`,
    `- Opportunity: ${context.opportunity.name} (${context.opportunity.id})`,
    `- Stage: ${context.opportunity.stage}`,
    `- Close date: ${context.opportunity.close_date}`,
    `- Owner: ${context.opportunity.owner_name}`,
    `- Pod Leader (Owner.Manager): ${context.opportunity.manager_name ?? "n/a"}`,
    "",
    "## Quote form (rep-entered)",
    `- Package: ${form.package}`,
    `- Users: ${form.users}`,
    `- Price per user: ${fmtMoney(form.price_per_user)}`,
    `- Total credits: ${form.total_credits}`,
    `- Hosting fee: ${fmtMoney(form.hosting_fee)}/yr`,
    `- Pricing discussed with customer: ${form.pricing_discussed ? "Yes" : "No"}`,
    `- Rep notes: ${form.notes || "(none)"}`,
    "",
    "## Calculated (deterministic — do not recompute)",
    `- List price/user: ${fmtMoney(pricing.list_price_per_user)}`,
    `- Discount/user: ${fmtMoney(pricing.discount_per_user)}`,
    `- Discount %: ${fmtPct(pricing.discount_pct)}`,
    `- Platform fee: ${fmtMoney(pricing.platform_fee_total)}`,
    `- Credits commit: ${fmtMoney(pricing.credits_commit_total)}`,
    `- Hosting fee total: ${fmtMoney(pricing.hosting_fee_total)}`,
    `- Total contract value: ${fmtMoney(pricing.total_amount)}`,
    "",
    "## Approval routing (decided)",
    `- Tier: ${routing.tier}`,
    `- Reason: ${routing.reason}`,
    "",
    "Return only the JSON block.",
  ].join("\n");
}

function parseAgentOutput(text: string): AgentOutput {
  const fenced = text.match(/```json\s*([\s\S]*?)```/);
  const candidate = fenced ? fenced[1] : null;

  if (candidate) {
    try {
      const obj = JSON.parse(candidate) as Partial<AgentOutput>;
      return {
        summary: typeof obj.summary === "string" ? obj.summary : "",
        flags: Array.isArray(obj.flags) ? obj.flags.filter((f): f is string => typeof f === "string") : [],
      };
    } catch {
      // fall through
    }
  }

  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start >= 0 && end > start) {
    try {
      const obj = JSON.parse(text.slice(start, end + 1)) as Partial<AgentOutput>;
      return {
        summary: typeof obj.summary === "string" ? obj.summary : "",
        flags: Array.isArray(obj.flags) ? obj.flags.filter((f): f is string => typeof f === "string") : [],
      };
    } catch {
      // fall through
    }
  }
  return { summary: "", flags: [] };
}
