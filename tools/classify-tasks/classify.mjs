#!/usr/bin/env node
/**
 * classify-tasks-prototype
 *
 * One-off prototype that classifies Salesforce Task records into pipe-gen-
 * relevant categories using Claude Haiku 4.5. Outputs a CSV that can be
 * hand-graded to validate accuracy before we wire LLM classification into
 * Apex on the PG Insights dashboard.
 *
 * Usage:
 *   ANTHROPIC_API_KEY=sk-... node classify.mjs <input.csv> [output.csv]
 *
 * Input CSV must include: Id, Subject, Description (other columns pass through).
 */

import { readFile, writeFile } from "node:fs/promises";
import Anthropic from "@anthropic-ai/sdk";
import { parse } from "csv-parse/sync";
import { stringify } from "csv-stringify/sync";

const MODEL = "claude-haiku-4-5-20251001";
const CONCURRENCY = 5;

const SYSTEM = [
  {
    type: "text",
    text: `You classify Salesforce CRM Task records (emails, calls, LinkedIn touches)
at a B2B SaaS sales org. Pick exactly one category from the Subject and Description:

- Prospecting: Outbound message intended to start a conversation with someone
  at an account that has no active deal. Cold or warm outreach referencing
  a trigger, intro, value prop, or asking to connect.
- Meeting Followup: Sent after a meeting/demo/call. Phrases like "thanks for
  meeting", "as discussed", recap, sending requested materials, scheduling
  the next step.
- In-Deal Reply: Message in the middle of an active deal — pricing,
  contract redlines, MSA, security review, technical questions during POV,
  procurement.
- Inbound Response: Reply to an inbound inquiry or marketing-sourced
  request (demo request, pricing question, content download, "Re: Demo
  request").
- Internal: Communication with internal teammates about an account or
  deal (handoffs, escalations, internal coordination).
- Other: Doesn't fit any of the above.

Respond with ONLY a JSON object (no markdown fences, no prose around it):
{"classification": "<one of the six categories>", "confidence": <0-1 number>, "reason": "<one short sentence>"}

Examples:

Subject: "Quick question on Acme's data architecture"
Description: "Hi Sarah, saw the team announcement about your new data warehouse — wanted to share how Rogo handles..."
=> {"classification":"Prospecting","confidence":0.92,"reason":"Cold outbound referencing a public trigger; no existing deal signal."}

Subject: "Re: Discovery follow-up"
Description: "Thanks again for the time today. Here's the deck we walked through. Aligning internally on next steps."
=> {"classification":"Meeting Followup","confidence":0.95,"reason":"Explicit post-meeting recap and next-step coordination."}

Subject: "Re: MSA v3 — legal questions"
Description: "Our legal team has comments on section 4.2 around indemnification..."
=> {"classification":"In-Deal Reply","confidence":0.93,"reason":"Active contract negotiation language."}

Subject: "Re: Demo request"
Description: "Hi Sarah, thanks for reaching out about Rogo. Happy to schedule a 30-min demo this week."
=> {"classification":"Inbound Response","confidence":0.94,"reason":"Replying to an inbound demo request."}

Subject: "Acme handoff to Mark"
Description: "Hey team, I'm transitioning the Acme account to Mark effective Monday..."
=> {"classification":"Internal","confidence":0.97,"reason":"Internal account handoff coordination."}`,
    cache_control: { type: "ephemeral" }
  }
];

const VALID_CATEGORIES = new Set([
  "Prospecting",
  "Meeting Followup",
  "In-Deal Reply",
  "Inbound Response",
  "Internal",
  "Other"
]);

async function classify(client, subject, description) {
  const userMessage = `Subject: ${subject || "(empty)"}\n\nDescription: ${description || "(empty)"}`;

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await client.messages.create({
        model: MODEL,
        max_tokens: 200,
        system: SYSTEM,
        messages: [{ role: "user", content: userMessage }]
      });
      const text = response.content[0].text.trim();
      const match = text.match(/\{[\s\S]*\}/);
      if (!match) throw new Error("No JSON object in response");
      const parsed = JSON.parse(match[0]);
      if (!VALID_CATEGORIES.has(parsed.classification)) {
        throw new Error(`Unknown category: ${parsed.classification}`);
      }
      return parsed;
    } catch (err) {
      if (attempt === 1) {
        return {
          classification: "Other",
          confidence: 0,
          reason: `LLM call failed: ${err.message}`
        };
      }
    }
  }
}

async function pool(items, concurrency, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (true) {
        const i = next++;
        if (i >= items.length) return;
        results[i] = await worker(items[i], i);
      }
    })
  );
  return results;
}

async function main() {
  const inputPath = process.argv[2];
  const outputPath = process.argv[3] || "tasks-classified.csv";
  if (!inputPath) {
    console.error("Usage: node classify.mjs <input.csv> [output.csv]");
    process.exit(1);
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    console.error("Set ANTHROPIC_API_KEY environment variable");
    process.exit(1);
  }

  const csvText = await readFile(inputPath, "utf-8");
  const rows = parse(csvText, { columns: true, skip_empty_lines: true });
  if (rows.length === 0) {
    console.error("Input CSV had no data rows");
    process.exit(1);
  }
  for (const required of ["Subject", "Description"]) {
    if (!(required in rows[0])) {
      console.error(`Input CSV missing required column: ${required}`);
      process.exit(1);
    }
  }
  console.error(`Loaded ${rows.length} rows from ${inputPath}`);

  const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

  let done = 0;
  const startedAt = Date.now();
  const classifications = await pool(rows, CONCURRENCY, async (row) => {
    const result = await classify(client, row.Subject, row.Description);
    done++;
    if (done % 10 === 0 || done === rows.length) {
      const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
      console.error(`  ${done}/${rows.length} classified (${elapsed}s)`);
    }
    return result;
  });

  const output = rows.map((row, i) => ({
    ...row,
    Classification: classifications[i].classification,
    Confidence: classifications[i].confidence,
    Reason: classifications[i].reason
  }));

  const counts = {};
  for (const c of classifications) {
    counts[c.classification] = (counts[c.classification] || 0) + 1;
  }
  console.error("\nClassification breakdown:");
  for (const [cat, n] of Object.entries(counts).sort((a, b) => b[1] - a[1])) {
    const pct = ((n / classifications.length) * 100).toFixed(1);
    console.error(`  ${cat.padEnd(20)} ${String(n).padStart(4)}  (${pct}%)`);
  }

  await writeFile(outputPath, stringify(output, { header: true }));
  console.error(`\nWrote ${output.length} rows to ${outputPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
