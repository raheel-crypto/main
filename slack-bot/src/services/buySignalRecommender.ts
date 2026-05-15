import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { MODEL, RECOMMENDER_MAX_TOKENS } from "../constants.js";
import {
  BuySignalRecommendationSchema,
  type BuySignalRecommendation,
  type PositiveApolloCall,
} from "../types.js";

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

const SYSTEM_PROMPT = `You help a Salesforce AE turn a positive sales-dev (Apollo/Nooks) call into pipeline.

You will be given:
- An account the AE owns
- One or more recent calls logged on that account where the GTMA marked the disposition as "Connected - Positive"
- The fact that this account currently has NO open Opportunity

Decide which action the AE should take first, but **always provide BOTH a suggestedOpp AND a suggestedTask** so the AE has the choice. suggestedAction indicates your recommendation:
- "create_opportunity" — the call summary suggests real buying interest, a champion, a defined use case, or a specific next step that warrants a new Opp.
- "log_task" — there is interest but it's too early for an Opp; a follow-up task is the right next move.
- "no_action" — the call summary doesn't contain a real buying signal (vague, polite brush-off, irrelevant). Return this and the card will be dropped. When "no_action", both suggestedOpp and suggestedTask MAY be null.

For "create_opportunity" or "log_task" you MUST provide both:
- suggestedOpp: a concrete Opp with a name, an early-funnel stage (e.g. "Discovery", "Qualified", "Stage 1 - Identified" — pick the closest standard label), an optional amount if hinted, and a realistic closeDate 60-120 days out.
- suggestedTask: a concrete follow-up task with a subject (verb-led, <80 chars) and a dueDate within the next 7 days. Even if you recommend create_opportunity, provide a reasonable task the AE could fall back to (e.g. "Schedule discovery call with VP Sales").

Rules:
- Be honest about "no_action". A "positive" disposition from a GTMA is noisy.
- headline is one line, <=100 chars, lead with the strongest signal from the call.
- rationale is 2-3 sentences. Explain to the AE WHY this is the right next step (focused on your recommended action).
- closeDate / dueDate are YYYY-MM-DD. Stage strings should look like standard SF picklist labels.
- Output strict JSON ONLY (no prose, no markdown):
{
  "headline": "string",
  "suggestedAction": "create_opportunity" | "log_task" | "no_action",
  "suggestedOpp": { "name": "string", "stage": "string", "amount": number|null, "closeDate": "YYYY-MM-DD" } | null,
  "suggestedTask": { "subject": "string", "dueDate": "YYYY-MM-DD", "description": "string"|null } | null,
  "rationale": "string"
}`;

export interface BuySignalRecommenderInput {
  accountId: string;
  accountName: string;
  industry: string | null;
  calls: PositiveApolloCall[];
  todayIso: string;
}

function buildUserMessage(input: BuySignalRecommenderInput): string {
  const callBlock = input.calls
    .slice(0, 5)
    .map((c) => {
      const who = c.ownerName ? ` by ${c.ownerName}` : "";
      const when = c.activityDate ?? c.createdDate ?? "(unknown date)";
      const summary = c.description
        ? c.description.slice(0, 1200)
        : "(no summary recorded)";
      return `- [${when}]${who}\n  Subject: ${c.subject}\n  Summary: ${summary}`;
    })
    .join("\n\n");

  return `Today: ${input.todayIso}
Account: ${input.accountName} (${input.accountId})
Industry: ${input.industry ?? "(unknown)"}
Open opportunities on this account right now: 0
Positive Apollo calls in the last 7 days: ${input.calls.length}

Positive calls (newest first):
${callBlock}

Generate the buy-signal recommendation now. JSON only.`;
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

export async function recommendBuySignal(
  input: BuySignalRecommenderInput
): Promise<BuySignalRecommendation | null> {
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

  const parsed = BuySignalRecommendationSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(
      `[buySignalRecommender] schema validation failed for ${input.accountId}:`,
      parsed.error.issues
    );
    return null;
  }
  const rec = parsed.data;
  if (rec.suggestedAction !== "no_action") {
    if (!rec.suggestedOpp || !rec.suggestedTask) {
      console.error(
        `[buySignalRecommender] action=${rec.suggestedAction} missing both suggestions for ${input.accountId}`
      );
      return null;
    }
  }
  return rec;
}
