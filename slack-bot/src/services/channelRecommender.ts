/**
 * Recommender for "free-text deal context" sources — Notion pages, Slack
 * deal-channel transcripts, etc. Same output shape as the standup recommender
 * so the existing oppCard renders identically; different prompt because the
 * input is a free-form document instead of Gong calls + activities.
 */
import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { MODEL, RECOMMENDER_MAX_TOKENS } from "../constants.js";
import {
  RecommendationSchema,
  type OppContext,
  type Recommendation,
} from "../types.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const SYSTEM_PROMPT = `You read free-form deal documents (Notion pages, Slack deal-channel transcripts) and reconcile them with the current state of the Salesforce Opportunity. Your job is to surface the field updates the rep needs to make so SF reflects what the document already says.

Rules:
- Only recommend changes for fields where the document provides clear evidence. Skip fields when the document is silent or ambiguous.
- Recommended values must use the exact picklist option strings when provided.
- NextStep is a single sentence (<=120 chars) starting with a verb.
- Amount is a number (no currency symbol). CloseDate is YYYY-MM-DD.
- Recap is 2-3 sentences. Lead with what the document says, then what to update.
- Do not invent updates. If the document doesn't address a field, leave it out.

Output strict JSON ONLY in this shape (no prose, no markdown):
{
  "opportunityId": "string",
  "recap": "string",
  "fields": [
    {
      "field": "StageName" | "NextStep" | "Amount" | "CloseDate",
      "currentValue": <string|number|null>,
      "recommendedValue": <string|number|null>,
      "rationale": "string"
    }
  ]
}`;

export interface ChannelRecommenderInput {
  ctx: OppContext;
  sourceText: string;
  sourceKind: "notion" | "channel";
  sourceLabel: string;
}

function buildUserMessage(input: ChannelRecommenderInput): string {
  const { opp, picklistOptions } = input.ctx;
  const stages = picklistOptions.stage.length
    ? `Allowed StageName values: ${picklistOptions.stage.join(" | ")}`
    : "";
  const kindHuman = input.sourceKind === "notion" ? "Notion page" : "Slack deal channel";
  return `Opportunity: ${opp.name} (${opp.id})
Account: ${opp.accountName} (${opp.accountId})
Current Stage: ${opp.stageName}
Current Amount: ${opp.amount ?? "null"}
Current CloseDate: ${opp.closeDate}
Current NextStep: ${opp.nextStep ?? "null"}
${stages}

Source: ${kindHuman} — ${input.sourceLabel}
------- BEGIN DOCUMENT -------
${input.sourceText}
------- END DOCUMENT -------

Generate recommendations now. JSON only.`;
}

function extractJson(text: string): unknown | null {
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    return JSON.parse(match[0]);
  } catch {
    return null;
  }
}

export async function recommendFromDocument(
  input: ChannelRecommenderInput
): Promise<Recommendation | null> {
  const response = await client.messages.create({
    model: MODEL,
    max_tokens: RECOMMENDER_MAX_TOKENS,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildUserMessage(input) }],
  });
  const text =
    response.content[0]?.type === "text" ? response.content[0].text : "";
  const raw = extractJson(text);
  if (!raw) return null;

  const parsed = RecommendationSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(
      `[channel-rec] schema validation failed for ${input.ctx.opp.id}:`,
      parsed.error.issues
    );
    return null;
  }
  const rec = parsed.data;
  rec.opportunityId = input.ctx.opp.id;
  rec.fields = rec.fields.filter(
    (f) =>
      f.recommendedValue !== null &&
      String(f.recommendedValue).trim() !== "" &&
      String(f.recommendedValue) !== String(f.currentValue ?? "")
  );
  return rec;
}
