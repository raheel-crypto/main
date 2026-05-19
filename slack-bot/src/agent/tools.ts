import type Anthropic from "@anthropic-ai/sdk";
import { Connection } from "jsforce";
import { DateTime } from "luxon";
import { getCallsForUserToday } from "../services/gong.js";
import {
  AccountSearchResult,
  escapeSoql,
  fetchActivities,
  fetchLastStageChangesForOpps,
  fetchOpportunitiesForAccount,
  findAccountsByName,
} from "../services/sfReads.js";
import { getUsageProvider } from "../services/usageDb.js";
import {
  bootstrap as rogoBootstrap,
  lookupRogoCustomer,
  query as rogoQueryRaw,
} from "../services/rogoClient.js";
import { BUY_SIGNAL_SUBJECT_PATTERN } from "../constants.js";

export interface AgentToolCtx {
  conn: Connection;
  slackUserId: string;
  userEmail: string;
  userTimezone: string;
  instanceUrl: string;
}

export interface AgentTool {
  name: string;
  definition: Anthropic.Tool;
  execute(input: any, ctx: AgentToolCtx): Promise<unknown>;
}

const REJECT_DML = /\b(INSERT|UPDATE|DELETE|UPSERT|MERGE)\b/i;

function safeStringifyTruncated(value: unknown, max = 30_000): string {
  const s = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  if (s.length <= max) return s;
  return s.slice(0, max) + `\n...[truncated ${s.length - max} chars]`;
}

const now: AgentTool = {
  name: "now",
  definition: {
    name: "now",
    description:
      "Return the current date/time, both UTC and in the rep's local timezone. Always call this when you need 'today' or to reason about relative dates.",
    input_schema: { type: "object", properties: {} },
  },
  async execute(_input, ctx) {
    const utc = DateTime.utc();
    const local = utc.setZone(ctx.userTimezone);
    return {
      utc_iso: utc.toISO(),
      local_iso: local.toISO(),
      local_date: local.toISODate(),
      timezone: ctx.userTimezone,
    };
  },
};

const sfFindAccount: AgentTool = {
  name: "sf_find_account",
  definition: {
    name: "sf_find_account",
    description:
      "Fuzzy search Salesforce Accounts by name (LIKE %name%). Returns up to 10 matches with id, name, industry, ownerName.",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Account name fragment" },
      },
      required: ["name"],
    },
  },
  async execute(input, ctx) {
    const name = String((input as any).name ?? "").trim();
    if (!name) return { matches: [] };
    const matches = await findAccountsByName(ctx.conn, name);
    return { matches } satisfies { matches: AccountSearchResult[] };
  },
};

const sfGetAccountSummary: AgentTool = {
  name: "sf_get_account_summary",
  definition: {
    name: "sf_get_account_summary",
    description:
      "For one Account, return the account record, allowed Opportunity stage picklist values, open opportunities (with last-stage-change dates), and the 5 most-recently closed opportunities.",
    input_schema: {
      type: "object",
      properties: {
        accountId: { type: "string" },
      },
      required: ["accountId"],
    },
  },
  async execute(input, ctx) {
    const accountId = String((input as any).accountId ?? "");
    if (!accountId) throw new Error("accountId required");

    const [accountRes, openOpps, closedOpps] = await Promise.all([
      ctx.conn.query(
        `SELECT Id, Name, Industry, OwnerId, Owner.Name, Website
           FROM Account WHERE Id = '${escapeSoql(accountId)}' LIMIT 1`
      ),
      fetchOpportunitiesForAccount(ctx.conn, accountId, true, 50),
      fetchOpportunitiesForAccount(ctx.conn, accountId, false, 5),
    ]);

    const stagePicklist: string[] = await (async () => {
      try {
        const desc = await ctx.conn.describe("Opportunity");
        const f = desc.fields.find((x) => x.name === "StageName");
        return (f?.picklistValues ?? [])
          .filter((p) => p.active)
          .map((p) => p.value);
      } catch {
        return [];
      }
    })();

    const stageChanges = await fetchLastStageChangesForOpps(
      ctx.conn,
      openOpps.map((o) => o.id)
    );

    const account =
      (accountRes.records[0] as any) ?? { Id: accountId, Name: "(unknown)" };

    return {
      account: {
        id: account.Id,
        name: account.Name,
        industry: account.Industry ?? null,
        website: account.Website ?? null,
        ownerName: account.Owner?.Name ?? null,
      },
      stagePicklist,
      openOpportunities: openOpps.map((o) => ({
        ...o,
        lastStageChangeDate: stageChanges.get(o.id) ?? null,
      })),
      recentClosedOpportunities: closedOpps.filter((o) => o.isClosed),
    };
  },
};

const sfGetActivities: AgentTool = {
  name: "sf_get_activities",
  definition: {
    name: "sf_get_activities",
    description:
      "Fetch Tasks and Events related to the given Salesforce record IDs (typically Opportunity IDs or Account IDs) since the given ISO date.",
    input_schema: {
      type: "object",
      properties: {
        whatIds: {
          type: "array",
          items: { type: "string" },
          description: "Opportunity or Account IDs",
        },
        sinceIso: {
          type: "string",
          description: "Start date in YYYY-MM-DD or full ISO format",
        },
      },
      required: ["whatIds", "sinceIso"],
    },
  },
  async execute(input, ctx) {
    const whatIds = ((input as any).whatIds ?? []) as string[];
    const sinceIso = String((input as any).sinceIso ?? "");
    if (!sinceIso) throw new Error("sinceIso required");
    const map = await fetchActivities(ctx.conn, whatIds, sinceIso);
    const out: Record<string, unknown[]> = {};
    for (const [k, v] of map) out[k] = v;
    return out;
  },
};

const sfQuery: AgentTool = {
  name: "sf_query",
  definition: {
    name: "sf_query",
    description:
      "Run an arbitrary read-only SOQL SELECT against Salesforce. Rejects any DML. Use sparingly — prefer the targeted tools.",
    input_schema: {
      type: "object",
      properties: {
        soql: { type: "string" },
      },
      required: ["soql"],
    },
  },
  async execute(input, ctx) {
    const soql = String((input as any).soql ?? "").trim();
    if (!/^\s*SELECT\b/i.test(soql)) {
      throw new Error("Only SELECT queries are allowed");
    }
    if (REJECT_DML.test(soql)) {
      throw new Error("DML keywords are not allowed");
    }
    const result = await ctx.conn.query(soql);
    return {
      totalSize: result.totalSize,
      done: result.done,
      records: result.records,
    };
  },
};

const gongGetCalls: AgentTool = {
  name: "gong_get_calls",
  definition: {
    name: "gong_get_calls",
    description:
      "Fetch Gong call summaries for the rep within a date range, optionally filtered by accountName substring match against the call title.",
    input_schema: {
      type: "object",
      properties: {
        fromIso: { type: "string", description: "Start datetime ISO" },
        toIso: { type: "string", description: "End datetime ISO" },
        accountName: {
          type: "string",
          description:
            "Optional account name substring to filter call titles (case-insensitive).",
        },
      },
      required: ["fromIso", "toIso"],
    },
  },
  async execute(input, ctx) {
    const fromIso = String((input as any).fromIso ?? "");
    const toIso = String((input as any).toIso ?? "");
    const accountName = (input as any).accountName as string | undefined;
    if (!fromIso || !toIso) throw new Error("fromIso and toIso required");
    if (!ctx.userEmail) return { calls: [] };
    const calls = await getCallsForUserToday(ctx.userEmail, fromIso, toIso);
    const filtered = accountName
      ? calls.filter((c) =>
          c.title.toLowerCase().includes(accountName.toLowerCase())
        )
      : calls;
    return { calls: filtered.slice(0, 20) };
  },
};

const rogoCheckCustomer: AgentTool = {
  name: "rogo_check_customer",
  definition: {
    name: "rogo_check_customer",
    description:
      "Deterministic check: is this Salesforce Account a paying Rogo customer? Looks up the account in the Rogo customer_directory (the source of truth, not a heuristic on Salesforce fields). Returns {is_customer, customer_row}. If is_customer is true, `customer_row` contains all the directory columns for that customer — inspect it to find the Rogo customer key column to use in subsequent rogo_query calls. If is_customer is false, the account isn't billed by Rogo (yet); treat as prospect.",
    input_schema: {
      type: "object",
      properties: {
        salesforceAccountId: {
          type: "string",
          description: "The 18- or 15-character Salesforce Account.Id.",
        },
      },
      required: ["salesforceAccountId"],
    },
  },
  async execute(input, _ctx) {
    const accountId = (input as any).salesforceAccountId as string;
    if (!accountId) {
      return { is_customer: false, reason: "missing_accountId" };
    }
    try {
      const row = await lookupRogoCustomer(accountId);
      if (!row) {
        return { is_customer: false, accountId };
      }
      return { is_customer: true, accountId, customer_row: row };
    } catch (err: any) {
      return {
        is_customer: false,
        accountId,
        error: err?.message ?? String(err),
      };
    }
  },
};

const rogoGetUsage: AgentTool = {
  name: "rogo_get_usage",
  definition: {
    name: "rogo_get_usage",
    description:
      "Fetch product usage metrics for one or more Salesforce Account IDs. Returns an array of {accountId, metric, value, asOf} rows.",
    input_schema: {
      type: "object",
      properties: {
        accountIds: {
          type: "array",
          items: { type: "string" },
        },
      },
      required: ["accountIds"],
    },
  },
  async execute(input, _ctx) {
    const ids = ((input as any).accountIds ?? []) as string[];
    if (ids.length === 0) return { usage: [] };
    const rows = await getUsageProvider().getUsageForAccounts(
      ids,
      DateTime.now().toISODate()!
    );
    return { usage: rows };
  },
};

const sfGetRecentPositiveCalls: AgentTool = {
  name: "sf_get_recent_positive_calls",
  definition: {
    name: "sf_get_recent_positive_calls",
    description:
      "Fetch recent 'Connected - Positive' Apollo/Nooks dialer Tasks. Filter by ownerId (GTMA) and/or accountId. Returns Task records with subject, ActivityDate, owner, and description (the call summary).",
    input_schema: {
      type: "object",
      properties: {
        ownerId: {
          type: "string",
          description: "Filter to tasks owned by this Salesforce user (e.g. a specific GTMA). Optional.",
        },
        accountId: {
          type: "string",
          description: "Filter to tasks on this Account (WhatId). Optional.",
        },
        sinceIso: {
          type: "string",
          description: "Start date (YYYY-MM-DD or ISO). Defaults to 7 days ago.",
        },
        limit: {
          type: "number",
          description: "Max records to return (default 50, max 200).",
        },
      },
    },
  },
  async execute(input, ctx) {
    const ownerId = (input as any).ownerId as string | undefined;
    const accountId = (input as any).accountId as string | undefined;
    const sinceIso =
      ((input as any).sinceIso as string | undefined) ??
      DateTime.utc().minus({ days: 7 }).toISODate()!;
    const limit = Math.min(Math.max(Number((input as any).limit) || 50, 1), 200);
    const sinceDate = sinceIso.slice(0, 10);
    const filters: string[] = [
      `Subject LIKE '${escapeSoql(BUY_SIGNAL_SUBJECT_PATTERN)}'`,
      `ActivityDate >= ${sinceDate}`,
    ];
    if (ownerId) filters.push(`OwnerId = '${escapeSoql(ownerId)}'`);
    if (accountId) filters.push(`WhatId = '${escapeSoql(accountId)}'`);
    const soql = `
      SELECT Id, WhatId, OwnerId, Owner.Name, Subject, ActivityDate, CreatedDate, Description
        FROM Task
       WHERE ${filters.join(" AND ")}
       ORDER BY ActivityDate DESC, CreatedDate DESC
       LIMIT ${limit}`;
    const result = await ctx.conn.query(soql);
    return {
      totalSize: result.totalSize,
      records: (result.records as any[]).map((r) => ({
        id: r.Id,
        accountId: r.WhatId,
        ownerId: r.OwnerId,
        ownerName: r.Owner?.Name ?? null,
        subject: r.Subject ?? "",
        activityDate: r.ActivityDate ?? null,
        createdDate: r.CreatedDate ?? null,
        description: r.Description ?? null,
      })),
    };
  },
};

const rogoDescribe: AgentTool = {
  name: "rogo_describe",
  definition: {
    name: "rogo_describe",
    description:
      "Get the Rogo Analytics warehouse schema and a sample of the customer directory. Returns available_schemas, the data_model_doc markdown (full description of tables/columns/segments), and N sample customer_directory rows so you can see what columns exist and how Salesforce account IDs map to Rogo customers. **Call this FIRST** before using rogo_query, especially for cross-account questions about usage, segments, or rankings.",
    input_schema: {
      type: "object",
      properties: {
        sampleDirectoryRows: {
          type: "number",
          description: "How many customer_directory rows to include in the sample (default 5, max 20).",
        },
      },
    },
  },
  async execute(input, _ctx) {
    const sampleN = Math.min(
      Math.max(Number((input as any).sampleDirectoryRows) || 5, 0),
      20
    );
    const boot = await rogoBootstrap();
    const directory = boot.customer_directory;
    return {
      contract_version: boot.contract_version,
      database: boot.database,
      available_schemas: boot.available_schemas,
      guardrails: boot.guardrails,
      data_model_doc: boot.data_model_doc?.content_md ?? null,
      customer_directory_row_count:
        directory?.row_count ?? directory?.rows?.length ?? 0,
      customer_directory_sample: (directory?.rows ?? []).slice(0, sampleN),
    };
  },
};

const rogoQuery: AgentTool = {
  name: "rogo_query",
  definition: {
    name: "rogo_query",
    description:
      "Run a read-only SELECT SQL query against the Rogo Analytics warehouse. Use this for ANY cross-customer analytics: ranking accounts by a metric, segment aggregations, joins between tables. Only SELECT is allowed (rejects INSERT/UPDATE/DELETE/UPSERT/MERGE). Rogo enforces its own row count and timeout guardrails. Call rogo_describe FIRST to learn the actual table and column names before constructing SQL.",
    input_schema: {
      type: "object",
      properties: {
        sql: {
          type: "string",
          description:
            "A SELECT SQL statement against the Rogo warehouse (Snowflake-flavored SQL).",
        },
      },
      required: ["sql"],
    },
  },
  async execute(input, _ctx) {
    const sql = String((input as any).sql ?? "").trim();
    if (!/^\s*SELECT\b/i.test(sql)) {
      throw new Error("Only SELECT queries are allowed");
    }
    if (REJECT_DML.test(sql)) {
      throw new Error("DML keywords are not allowed");
    }
    const result = await rogoQueryRaw(sql);
    return {
      status: result.status,
      columns: result.columns,
      column_types: result.column_types,
      rows: result.rows,
      row_count: result.row_count,
      truncated: result.truncated,
      warnings: result.warnings,
    };
  },
};

export const ALL_TOOLS: AgentTool[] = [
  now,
  sfFindAccount,
  sfGetAccountSummary,
  sfGetActivities,
  sfQuery,
  gongGetCalls,
  rogoGetUsage,
  rogoCheckCustomer,
  sfGetRecentPositiveCalls,
  rogoDescribe,
  rogoQuery,
];

export const TOOL_DEFINITIONS = ALL_TOOLS.map((t) => t.definition);

export async function dispatchToolCall(
  name: string,
  input: unknown,
  ctx: AgentToolCtx
): Promise<string> {
  const tool = ALL_TOOLS.find((t) => t.name === name);
  if (!tool) return JSON.stringify({ error: `Unknown tool: ${name}` });
  try {
    const result = await tool.execute(input, ctx);
    return safeStringifyTruncated(result);
  } catch (err: any) {
    return JSON.stringify({ error: err?.message ?? String(err) });
  }
}
