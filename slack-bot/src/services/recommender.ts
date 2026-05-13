import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { MODEL, RECOMMENDER_MAX_TOKENS } from "../constants.js";
import {
  RecommendationSchema,
  type OppContext,
  type Recommendation,
} from "../types.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const SYSTEM_PROMPT = `You are a senior Salesforce account executive's daily assistant. For each Opportunity, you read today's Gong call summaries, recent activities since the last stage change, and product usage data, then produce concrete recommendations to keep the opp record accurate and forward-moving.

Rules:
- Only recommend changes for fields where you have evidence. Skip fields when uncertain.
- Recommended values must use the exact picklist option strings when provided.
- NextStep is a single sentence (<=120 chars) starting with a verb.
- Amount is a number (no currency symbol). CloseDate is YYYY-MM-DD.
- Description is appended notes, not a replacement; keep <=400 chars.
- Recap is 2-3 sentences. Lead with what happened, then what to do.

Output strict JSON ONLY in this shape (no prose, no markdown):
{
  "opportunityId": "string",
  "recap": "string",
  "fields": [
    {
      "field": "StageName" | "NextStep" | "Amount" | "CloseDate" | "Description",
      "currentValue": <string|number|null>,
      "recommendedValue": <string|number|null>,
      "rationale": "string"
    }
  ]
}`;

function buildUserMessage(ctx: OppContext): string {
  const { opp, activities, calls, usage, picklistOptions } = ctx;
  const callBlock = calls.length
    ? calls
        .map(
          (c) =>
            `- (${c.id}) ${c.title} [${c.startedAt}]\n  Brief: ${c.brief ?? "(none)"}`
        )
        .join("\n")
    : "(no calls today)";
  const activityBlock = activities.length
    ? activities
        .slice(0, 20)
        .map(
          (a) =>
            `- [${a.type}] ${a.activityDate ?? ""} ${a.subject}${a.description ? ` — ${a.description.slice(0, 200)}` : ""}`
        )
        .join("\n")
    : "(no activities since last stage change)";
  const usageBlock = usage.length
    ? usage
        .map((u) => `- ${u.metric}: ${u.value} (asOf ${u.asOf})`)
        .join("\n")
    : "(no usage data)";
  const stages = picklistOptions.stage.length
    ? `Allowed StageName values: ${picklistOptions.stage.join(" | ")}`
    : "";

  return `Opportunity: ${opp.name} (${opp.id})
Account: ${opp.accountName} (${opp.accountId})
Current Stage: ${opp.stageName}
Current Amount: ${opp.amount ?? "null"}
Current CloseDate: ${opp.closeDate}
Current NextStep: ${opp.nextStep ?? "null"}
Last Stage Change: ${opp.lastStageChangeDate ?? "unknown"}
${stages}

Today's Calls:
${callBlock}

Recent Activities:
${activityBlock}

Usage:
${usageBlock}

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

export async function recommendForOpp(
  ctx: OppContext
): Promise<Recommendation | null> {
  const response = await client.messages.create({
    model: MODEL,
    max_tokens: RECOMMENDER_MAX_TOKENS,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildUserMessage(ctx) }],
  });
  const text =
    response.content[0]?.type === "text" ? response.content[0].text : "";
  const raw = extractJson(text);
  if (!raw) return null;

  const parsed = RecommendationSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(
      `[recommender] schema validation failed for ${ctx.opp.id}:`,
      parsed.error.issues
    );
    return null;
  }
  const rec = parsed.data;
  rec.opportunityId = ctx.opp.id;
  rec.fields = rec.fields.filter(
    (f) =>
      f.recommendedValue !== null &&
      String(f.recommendedValue).trim() !== "" &&
      String(f.recommendedValue) !== String(f.currentValue ?? "")
  );
  return rec;
}
