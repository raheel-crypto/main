import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.js";
import { INSIGHTS_MAX_TOKENS, INSIGHTS_MODEL } from "../constants.js";
import { GongCallInsightSchema } from "../types.js";
import type { GongCallInsight, GongWebhookPayload } from "../types.js";

const SYSTEM_PROMPT = `You are summarizing a sales call for a Slack DM the rep sees seconds after the call wraps. The input comes from Gong: call metadata, party list, topics, tracker counts, and AI-generated scorecard answers (these are already condensed observations from Gong's own AI).

Return ONLY valid JSON matching this schema:
{
  "summary": "1-2 sentence overview. Mention the account, the deal context if known, and the dominant theme of the call.",
  "positives": ["bullets of customer-positive signals: engagement, interest, aha moments, expansion intent, validation. Quote specifics."],
  "negatives": ["bullets of risks, blockers, objections, concerns, churn signals. Quote specifics."],
  "nextSteps": ["concrete commitments: who does what by when. Empty array if no clear next step."]
}

Rules:
- Each bullet ≤ 110 chars. Quote names, dates, amounts where they appear.
- Don't invent facts. If a field has no signal in the input, return an empty array.
- Skip filler ("the rep was professional", "the call was productive"). Only call out deal-relevant signals.
- Output the JSON object only. No prose, no markdown fence, no commentary.`;

interface Tracker {
  name?: string;
  count?: number;
  type?: string;
}

interface ScorecardAnswer {
  questionText?: string;
  answerText?: string;
  answerNote?: string | null;
  fullAnswerText?: string | null;
  scorecardName?: string;
}

function curateInput(payload: GongWebhookPayload): string {
  const callData = payload.callData;
  const meta = callData?.metaData;
  const parties = callData?.parties ?? [];

  const partyLines = parties
    .map((p) => {
      const name = p.name ?? p.emailAddress ?? "(unknown)";
      const aff = p.affiliation ?? "unknown";
      const title = p.title ? `, ${p.title}` : "";
      return `- ${name} (${aff}${title})`;
    })
    .join("\n");

  const sfContext = callData?.context?.find(
    (c) => String(c?.system ?? "").toLowerCase() === "salesforce"
  );
  const sfLines: string[] = [];
  for (const obj of sfContext?.objects ?? []) {
    const fields = (obj.fields ?? [])
      .map((f) => `${f.name}=${JSON.stringify(f.value)}`)
      .join(", ");
    sfLines.push(`- ${obj.objectType}: ${fields}`);
  }

  const topics = callData?.content?.topics ?? [];
  const topicLines = topics
    .filter((t) => (t?.duration ?? 0) > 0)
    .sort((a, b) => (b.duration ?? 0) - (a.duration ?? 0))
    .map((t) => `- ${t.name}: ${Math.round((t.duration ?? 0) / 60)}m`)
    .join("\n");

  const content = callData?.content as
    | {
        trackers?: Tracker[];
        scorecardsAnswers?: ScorecardAnswer[];
      }
    | undefined;

  const trackerLines = (content?.trackers ?? [])
    .filter((t) => (t.count ?? 0) > 0)
    .sort((a, b) => (b.count ?? 0) - (a.count ?? 0))
    .map((t) => `- ${t.name}: ${t.count}`)
    .join("\n");

  const scorecardLines = (content?.scorecardsAnswers ?? [])
    .filter((s) => s.answerNote || s.fullAnswerText)
    .map((s) => {
      const body = (s.fullAnswerText || s.answerNote || "").slice(0, 600);
      const verdict = s.answerText ? ` (${s.answerText})` : "";
      return `Q: ${s.questionText ?? ""}${verdict}\nA: ${body}`;
    })
    .join("\n\n");

  const durationMin = meta?.duration
    ? `${Math.round((meta.duration as number) / 60)}m`
    : "unknown";

  const sections: string[] = [
    `# Call`,
    `Title: ${meta?.title ?? "Untitled"}`,
    `Duration: ${durationMin}`,
    meta?.direction ? `Direction: ${meta.direction}` : "",
  ].filter(Boolean);

  if (partyLines) sections.push(`\n# Parties\n${partyLines}`);
  if (sfLines.length) sections.push(`\n# Salesforce context\n${sfLines.join("\n")}`);
  if (topicLines) sections.push(`\n# Topics by talk time\n${topicLines}`);
  if (trackerLines) sections.push(`\n# Tracker counts (>0)\n${trackerLines}`);
  if (scorecardLines) sections.push(`\n# Scorecard insights\n${scorecardLines}`);

  return sections.join("\n");
}

function extractJson(text: string): unknown {
  const trimmed = text.trim();
  try {
    return JSON.parse(trimmed);
  } catch {}
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]+?)\s*```/);
  if (fenced) {
    try {
      return JSON.parse(fenced[1]);
    } catch {}
  }
  const match = trimmed.match(/\{[\s\S]+\}/);
  if (match) {
    try {
      return JSON.parse(match[0]);
    } catch {}
  }
  throw new Error("No valid JSON in summarizer response");
}

export async function summarizeGongCall(
  payload: GongWebhookPayload
): Promise<GongCallInsight | null> {
  if (!config.anthropic.apiKey) {
    console.warn(
      "[gong-insights] ANTHROPIC_API_KEY not set, skipping summarization"
    );
    return null;
  }
  const input = curateInput(payload);
  const client = new Anthropic({ apiKey: config.anthropic.apiKey });
  const start = Date.now();
  try {
    const res = await client.messages.create({
      model: INSIGHTS_MODEL,
      max_tokens: INSIGHTS_MAX_TOKENS,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: input }],
    });
    const textBlock = res.content.find((b) => b.type === "text");
    const text =
      textBlock && "text" in textBlock ? (textBlock.text as string) : "";
    const json = extractJson(text);
    const insights = GongCallInsightSchema.parse(json);
    console.log(
      `[gong-insights] summarized in ${Date.now() - start}ms (${insights.positives.length}+/${insights.negatives.length}-/${insights.nextSteps.length} next)`
    );
    return insights;
  } catch (err: any) {
    console.error(
      `[gong-insights] summarization failed after ${Date.now() - start}ms:`,
      err?.message ?? err
    );
    return null;
  }
}
