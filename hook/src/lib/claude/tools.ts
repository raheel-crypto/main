import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { betaZodTool } from "@anthropic-ai/sdk/helpers/beta/zod";
import { getAccountWithOpps, rawSoql } from "@/lib/salesforce/soql";
import { recomputeAccount, diffVsStored } from "@/lib/arr/recompute";
import { sql } from "@/lib/db/client";

export const soqlQuery = betaZodTool({
  name: "soql_query",
  description:
    "Run a read-only SOQL query against Salesforce. Use this when you need raw facts about Opportunity, Account, ARR_Event__c, or ARR_Audit_Log__c. The query MUST be a SELECT — anything else is rejected.",
  inputSchema: z.object({
    query: z.string().describe("A valid SOQL SELECT statement"),
  }),
  run: async ({ query }) => {
    const trimmed = query.trim();
    if (!/^select\s/i.test(trimmed)) {
      return JSON.stringify({ error: "Only SELECT queries are permitted in read-only mode." });
    }
    try {
      const records = await rawSoql(trimmed);
      return JSON.stringify({ recordCount: records.length, records: records.slice(0, 100) });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },
});

export const recomputeAccountTool = betaZodTool({
  name: "recompute_account",
  description:
    "Run the deterministic §2 ARR algorithm on a single account. Returns the expected ARR, the full event ledger, and account status. Use this whenever you need to know what an account's ARR SHOULD be — never compute it yourself.",
  inputSchema: z.object({
    accountId: z.string().describe("Salesforce 18-character Account ID"),
  }),
  run: async ({ accountId }) => {
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
});

export const diffVsStoredTool = betaZodTool({
  name: "diff_vs_stored",
  description:
    "Convenience: recompute an account's ARR, read the stored value, return the gap. Use this when investigating a specific account's discrepancy.",
  inputSchema: z.object({
    accountId: z.string().describe("Salesforce 18-character Account ID"),
    thresholdUsd: z.number().optional().describe("Gap threshold in USD; default $1"),
  }),
  run: async ({ accountId, thresholdUsd }) => {
    try {
      const { account, opps } = await getAccountWithOpps(accountId);
      const result = diffVsStored(account, opps, thresholdUsd ?? 1);
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
});

export const lastAuditTool = betaZodTool({
  name: "last_audit",
  description:
    "Fetch the most recent Hook runs and any gaps recorded for a given account. Use this to see prior context — was this gap reported before, has it been changing, has it been resolved.",
  inputSchema: z.object({
    accountId: z.string(),
    limit: z.number().optional().describe("Max rows; default 10"),
  }),
  run: async ({ accountId, limit }) => {
    try {
      const rows = await sql`
        SELECT g.created_at, g.stored_arr, g.expected_arr, g.gap_usd, g.category, g.rule_applied,
               r.trigger_kind, r.started_at
        FROM gaps g
        LEFT JOIN runs r ON r.id = g.run_id
        WHERE g.account_id = ${accountId}
        ORDER BY g.created_at DESC
        LIMIT ${limit ?? 10}
      `;
      return JSON.stringify({ accountId, history: rows });
    } catch (err) {
      return JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
    }
  },
});

export const HOOK_TOOLS: Anthropic.Beta.Messages.BetaToolUnion[] = [
  soqlQuery,
  recomputeAccountTool,
  diffVsStoredTool,
  lastAuditTool,
];
