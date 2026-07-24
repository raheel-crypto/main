import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { MODEL, RECOMMENDER_MAX_TOKENS } from "../constants.js";
import {
  RecommendationSchema,
  type GongCallInsight,
  type Recommendation,
} from "../types.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const SYSTEM_PROMPT = `You are an AE's post-meeting assistant. A sales call just wrapped. You're given the AI-generated call insights (summary + positives + negatives + next steps) and the current state of ONE open Salesforce Opportunity on the matched Account. Recommend concrete field updates to keep the opp record accurate and forward-moving.

Rules:
- Only recommend changes when the call gives clear evidence. Skip fields with no signal (return an empty fields array if nothing actionable).
- StageName values must match the allowed picklist exactly.
- NextStep is a single sentence (<=120 chars) starting with a verb. Capture the concrete next commitment from the call.
- Amount is a number (no currency symbol). CloseDate is YYYY-MM-DD.
- Notes__c is for short free-form notes capturing call context — 1-3 sentences. Quote names, dates, amounts where they appear in the call.
- Deal_Description__c is for the structured deal write-up (problem, decision criteria, stakeholders, etc.). Update ONLY when the call meaningfully changes how the deal is understood; do NOT propose updates for routine status calls.
- Recap is 1-2 sentences summarizing the call's impact on this opp.
- Do not recommend a CloseDate in the past unless you are also moving StageName to a Closed stage in the same recommendation.

Output strict JSON ONLY (no prose, no markdown):
{
  "opportunityId": "string",
  "recap": "string",
  "fields": [
    {
      "field": "StageName" | "NextStep" | "Amount" | "CloseDate" | "Notes__c" | "Deal_Description__c",
      "currentValue": <string|number|null>,
      "recommendedValue": <string|number|null>,
      "rationale": "string"
    }
  ]
}`;

export interface PostMeetingRecommendInput {
  opp: {
    id: string;
    name: string;
    accountName: string;
    stage: string;
    nextStep: string | null;
    amount: number | null;
    closeDate: string | null;
  };
  picklistStages: string[];
  insights: GongCallInsight;
  callTitle: string;
  todayIso: string;
}

function buildUserMessage(input: PostMeetingRecommendInput): string {
  const { opp, picklistStages, insights, callTitle, todayIso } = input;
  const stages = picklistStages.length
    ? `Allowed StageName values: ${picklistStages.join(" | ")}`
    : "";
  const positives = insights.positives.length
    ? insights.positives.map((p) => `- ${p}`).join("\n")
    : "(none flagged)";
  const negatives = insights.negatives.length
    ? insights.negatives.map((n) => `- ${n}`).join("\n")
    : "(none flagged)";
  const nextSteps = insights.nextSteps.length
    ? insights.nextSteps.map((s) => `- ${s}`).join("\n")
    : "(none committed)";

  return `Opportunity: ${opp.name} (${opp.id})
Account: ${opp.accountName}
Current Stage: ${opp.stage}
Current Amount: ${opp.amount ?? "null"}
Current CloseDate: ${opp.closeDate ?? "null"}
Current NextStep: ${opp.nextStep ?? "null"}
${stages}

Call: ${callTitle}
Call summary: ${insights.summary}

Positives:
${positives}

Negatives:
${negatives}

Next steps committed:
${nextSteps}

Today is ${todayIso}.

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

export async function recommendForPostMeeting(
  input: PostMeetingRecommendInput
): Promise<Recommendation | null> {
  if (!config.anthropic.apiKey) return null;
  let response;
  try {
    response = await client.messages.create({
      model: MODEL,
      max_tokens: RECOMMENDER_MAX_TOKENS,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: buildUserMessage(input) }],
    });
  } catch (err: any) {
    console.error(
      `[post-meeting-rec] Claude call failed for ${input.opp.id}:`,
      err?.message ?? err
    );
    return null;
  }
  const text =
    response.content[0]?.type === "text" ? response.content[0].text : "";
  const raw = extractJson(text);
  if (!raw) return null;

  const parsed = RecommendationSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(
      `[post-meeting-rec] schema validation failed for ${input.opp.id}:`,
      parsed.error.issues
    );
    return null;
  }
  const rec = parsed.data;
  rec.opportunityId = input.opp.id;
  rec.fields = rec.fields.filter(
    (f) =>
      f.recommendedValue !== null &&
      String(f.recommendedValue).trim() !== "" &&
      String(f.recommendedValue) !== String(f.currentValue ?? "")
  );
  return rec;
}
