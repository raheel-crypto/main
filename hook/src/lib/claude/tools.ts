import type Anthropic from "@anthropic-ai/sdk";
import { getAccountWithOpps, rawSoql } from "@/lib/salesforce/soql";
import { recomputeAccount, diffVsStored } from "@/lib/arr/recompute";
import { crossValidate } from "@/lib/arr/cross_validate";
import { sql } from "@/lib/db/client";

export type ToolExecutor = (input: Record<string, unknown>) => Promise<string>;

export const TOOL_DEFINITIONS: Anthropic.Tool[] = [
  {
    name: "soql_query",
    description:
      "Run a read-only SOQL query against Salesforce. Use this when you need raw facts about Opportunity, Account, ARR_Event__c, or ARR_Audit_Log__c. The query MUST be a SELECT — anything else is rejected.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "A valid SOQL SELECT statement" },
      },
      required: ["query"],
    },
  },
  {
    name: "recompute_account",
    description:
      "Run the deterministic §2 ARR algorithm on a single account. Returns the expected ARR, the full event ledger, and account status. Use this whenever you need to know what an account's ARR SHOULD be — never compute it yourself.",
    input_schema: {
      type: "object",
      properties: {
        accountId: { type: "string", description: "Salesforce 18-character Account ID" },
      },
      required: ["accountId"],
    },
  },
  {
    name: "diff_vs_stored",
    description:
      "Convenience: recompute an account's ARR, read the stored value, return the gap. Use this when investigating a specific account's discrepancy.",
    input_schema: {
      type: "object",
      properties: {
        accountId: { type: "string", description: "Salesforce 18-character Account ID" },
        thresholdUsd: { type: "number", description: "Gap threshold in USD; default $1" },
      },
      required: ["accountId"],
    },
  },
  {
    name: "last_audit",
    description:
      "Fetch the most recent Hook runs and any gaps recorded for a given account. Use this to see prior context — was this gap reported before, has it been changing, has it been resolved.",
    input_schema: {
      type: "object",
      properties: {
        accountId: { type: "string" },
        limit: { type: "number", description: "Max rows; default 10" },
      },
      required: ["accountId"],
    },
  },
  {
    name: "validate_contracts",
    description:
      "Cross-validate every won opp for an account against its Order Form Extraction (OFE) row. Returns the list of contract-vs-opp disagreements across three categories: Contract-ARR mismatch, Type mismatch vs contract, Mistyped amendment. Use this whenever a §2 gap is unexplained or when investigating Type/ARR data quality on a specific account.",
    input_schema: {
      type: "object",
      properties: {
        accountId: { type: "string", description: "Salesforce 18-character Account ID" },
      },
      required: ["accountId"],
    },
  },
  {
    name: "run_full_sweep",
    description:
      "Kick off a full ARR reconciliation across every Customer and Former Customer account. Returns immediately with a 'started' status; the actual sweep runs asynchronously and posts a complete digest to #revops in roughly 90 seconds. Use this when the user asks for a full ARR check, a fresh sweep, or 'which accounts have wrong ARR'. Do NOT use last_audit for this — last_audit only returns historical data from prior runs. This tool produces fresh results.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
];

export const TOOL_EXECUTORS: Record<string, ToolExecutor> = {
  async soql_query(input) {
    const query = String(input.query ?? "").trim();
    if (!/^select\s/i.test(query)) {
      return JSON.stringify({ error: "Only SELECT queries are permitted in read-only mode." });
    }
    try {
      const records = await rawSoql(query);
      return JSON.stringify({ recordCount: records.length, records: records.slice(0, 100) });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },

  async recompute_account(input) {
    const accountId = String(input.accountId ?? "");
    try {
      const { account, opps } = await getAccountWithOpps(accountId);
      const result = recomputeAccount(account, opps);
      return JSON.stringify({
        accountId: account.Id,
        accountName: account.Name,
        status: account.Account_Status__c,
        expectedArr: result.expectedArr,
        eventCount: result.events.length,
        events: result.events,
      });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },

  async diff_vs_stored(input) {
    const accountId = String(input.accountId ?? "");
    const thresholdUsd = typeof input.thresholdUsd === "number" ? input.thresholdUsd : 1;
    try {
      const { account, opps } = await getAccountWithOpps(accountId);
      const result = diffVsStored(account, opps, thresholdUsd);
      return JSON.stringify({
        accountId: account.Id,
        accountName: account.Name,
        status: account.Account_Status__c,
        storedArr: result.storedArr,
        expectedArr: result.result.expectedArr,
        gap: result.gap,
        matches: result.matches,
        events: result.result.events,
      });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },

  async last_audit(input) {
    const accountId = String(input.accountId ?? "");
    const limit = typeof input.limit === "number" ? input.limit : 10;
    try {
      const rows = await sql`
        SELECT g.created_at, g.stored_arr, g.expected_arr, g.gap_usd, g.category, g.rule_applied,
               r.trigger_kind, r.started_at
        FROM gaps g
        LEFT JOIN runs r ON r.id = g.run_id
        WHERE g.account_id = ${accountId}
        ORDER BY g.created_at DESC
        LIMIT ${limit}
      `;
      return JSON.stringify({ accountId, history: rows });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },

  async validate_contracts(input) {
    const accountId = String(input.accountId ?? "");
    try {
      const { opps, ofes } = await getAccountWithOpps(accountId);
      const gaps = crossValidate(opps, ofes);
      const oppsWithoutOfe = opps
        .filter((o) => !ofes.some((f) => f.Opportunity__c === o.Id))
        .map((o) => ({ id: o.Id, name: o.Name, type: o.Type, closeDate: o.CloseDate }));
      return JSON.stringify({
        accountId,
        oppsChecked: opps.length,
        ofeRowsFound: ofes.length,
        gapCount: gaps.length,
        gaps,
        oppsWithoutOfe,
      });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },

  async run_full_sweep() {
    const baseUrl =
      process.env.HOOK_BASE_URL ||
      (process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : "");
    if (!baseUrl) {
      return JSON.stringify({
        error: "HOOK_BASE_URL or VERCEL_URL not set; cannot self-call /api/cron/weekly",
      });
    }
    const cronSecret = process.env.CRON_SECRET;
    if (!cronSecret) {
      return JSON.stringify({ error: "CRON_SECRET not set" });
    }

    try {
      const res = await fetch(`${baseUrl}/api/cron/weekly`, {
        method: "GET",
        headers: { Authorization: `Bearer ${cronSecret}` },
      });
      if (!res.ok) {
        return JSON.stringify({
          error: `Sweep kick-off failed: ${res.status} ${await res.text()}`,
        });
      }
      const body = (await res.json()) as {
        runId: number;
        accountsToCheck: number;
        estimatedSeconds: number;
      };
      return JSON.stringify({
        status: "started",
        runId: body.runId,
        accountsToCheck: body.accountsToCheck,
        estimatedSeconds: body.estimatedSeconds,
        message: `Full ARR sweep kicked off across ${body.accountsToCheck} accounts. Digest will post to #revops in ~${body.estimatedSeconds}s.`,
      });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },
};
