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
import { getRecentBulkFailures } from "../db/queries.js";
import { getUsageProvider } from "../services/usageDb.js";
import {
  bootstrap as rogoBootstrap,
  lookupRogoCustomer,
  query as rogoQueryRaw,
} from "../services/rogoClient.js";
import { BUY_SIGNAL_SUBJECT_PATTERN } from "../constants.js";
import {
  describeObject,
  findField,
  sobjectFromIdPrefix,
  suggestFields,
  type DescribedField,
  type DescribedObject,
} from "../services/sfDescribe.js";
import {
  fetchUserName,
  isSelfReference,
  resolveCurrentUserId,
  resolveUserByName,
} from "../services/userResolver.js";
import type {
  BulkRecordSummary,
  BulkRecordUpdateProposal,
  ProposedField,
  ProposedFieldType,
  RecordUpdateProposal,
} from "../types.js";

export interface AgentToolCtx {
  conn: Connection;
  slackUserId: string;
  userEmail: string;
  userTimezone: string;
  instanceUrl: string;
  sfUserId?: string | null;
  sfUserName?: string | null;
  pendingRecordProposals: RecordUpdateProposal[];
  pendingBulkRecordProposals: BulkRecordUpdateProposal[];
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
        `SELECT Id, Name, Industry, OwnerId, Owner.Name, Website, Account_Status__c
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
        accountStatus: account.Account_Status__c ?? null,
        isCustomer:
          typeof account.Account_Status__c === "string" &&
          account.Account_Status__c.toLowerCase() === "customer",
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
    try {
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
    } catch (err: any) {
      // Surface the SQL alongside the error so the agent's next iteration
      // can see what it tried and self-correct (rename a column, drop a
      // table reference, etc.).
      const code = err?.code ?? "rogo_query_failed";
      const message = err?.message ?? String(err);
      return {
        status: "error",
        error: { code, message, attempted_sql: sql },
      };
    }
  },
};

const COMMON_SOBJECTS = [
  "Opportunity",
  "Account",
  "Contact",
  "Lead",
  "Task",
  "Event",
  "Case",
];

function fieldTypeForProposed(
  f: DescribedField
): ProposedFieldType {
  switch (f.type) {
    case "textarea":
    case "string":
    case "picklist":
    case "multipicklist":
    case "date":
    case "datetime":
    case "currency":
    case "double":
    case "int":
    case "percent":
    case "boolean":
    case "reference":
    case "id":
    case "email":
    case "phone":
    case "url":
      return f.type;
    default:
      // Map unknown types to a safe text-edit experience.
      return "string";
  }
}

async function normalizeProposedValue(
  ctx: AgentToolCtx,
  desc: DescribedField,
  rawValue: unknown
): Promise<
  | { ok: true; value: string | number | boolean | null; display: string | null }
  | { ok: false; error: string }
> {
  if (rawValue === null || rawValue === undefined || rawValue === "") {
    return { ok: true, value: null, display: null };
  }
  switch (desc.type) {
    case "boolean": {
      if (typeof rawValue === "boolean")
        return { ok: true, value: rawValue, display: rawValue ? "true" : "false" };
      const s = String(rawValue).trim().toLowerCase();
      if (["true", "yes", "1", "checked"].includes(s))
        return { ok: true, value: true, display: "true" };
      if (["false", "no", "0", "unchecked"].includes(s))
        return { ok: true, value: false, display: "false" };
      return {
        ok: false,
        error: `${desc.name} expects a boolean (true/false); got ${JSON.stringify(rawValue)}`,
      };
    }
    case "currency":
    case "double":
    case "int":
    case "percent": {
      const n =
        typeof rawValue === "number"
          ? rawValue
          : Number(String(rawValue).replace(/[^0-9.\-]/g, ""));
      if (!Number.isFinite(n)) {
        return {
          ok: false,
          error: `${desc.name} must be a number; got ${JSON.stringify(rawValue)}`,
        };
      }
      return { ok: true, value: n, display: String(n) };
    }
    case "date": {
      const s = String(rawValue).slice(0, 10);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) {
        return {
          ok: false,
          error: `${desc.name} must be YYYY-MM-DD; got ${JSON.stringify(rawValue)}`,
        };
      }
      return { ok: true, value: s, display: s };
    }
    case "datetime": {
      const s = String(rawValue);
      const d = new Date(s);
      if (Number.isNaN(d.getTime())) {
        return {
          ok: false,
          error: `${desc.name} must be a valid ISO datetime; got ${JSON.stringify(rawValue)}`,
        };
      }
      const iso = d.toISOString();
      return { ok: true, value: iso, display: iso };
    }
    case "picklist": {
      const s = String(rawValue);
      const allowed = desc.picklistValues.map((p) => p.value);
      if (allowed.length > 0 && !allowed.includes(s)) {
        return {
          ok: false,
          error: `${desc.name} value "${s}" is not in the picklist. Valid: ${allowed.join(" | ")}`,
        };
      }
      return { ok: true, value: s, display: s };
    }
    case "multipicklist": {
      const arr = Array.isArray(rawValue)
        ? rawValue.map(String)
        : String(rawValue)
            .split(";")
            .map((x) => x.trim())
            .filter(Boolean);
      const allowed = new Set(desc.picklistValues.map((p) => p.value));
      if (allowed.size > 0) {
        const bad = arr.filter((v) => !allowed.has(v));
        if (bad.length > 0) {
          return {
            ok: false,
            error: `${desc.name} contains invalid picklist values: ${bad.join(", ")}. Valid: ${[...allowed].join(" | ")}`,
          };
        }
      }
      const joined = arr.join(";");
      return { ok: true, value: joined, display: arr.join(", ") };
    }
    case "reference": {
      const refTo = desc.referenceTo[0];
      if (refTo === "User") {
        const raw = String(rawValue).trim();
        if (isSelfReference(raw)) {
          const uid = await resolveCurrentUserId(ctx.conn);
          if (!uid) {
            return {
              ok: false,
              error: `Couldn't resolve the current user for ${desc.name}.`,
            };
          }
          const name = (await fetchUserName(ctx.conn, uid)) ?? raw;
          return { ok: true, value: uid, display: name };
        }
        // Already an Id?
        if (/^005[A-Za-z0-9]{12,15}$/.test(raw)) {
          const name = (await fetchUserName(ctx.conn, raw)) ?? raw;
          return { ok: true, value: raw, display: name };
        }
        const resolved = await resolveUserByName(ctx.conn, raw);
        if (resolved.kind === "ok") {
          return {
            ok: true,
            value: resolved.user.id,
            display: resolved.user.name,
          };
        }
        if (resolved.kind === "ambiguous") {
          return {
            ok: false,
            error: `Multiple active users match "${raw}" for ${desc.name}: ${resolved.candidates.map((c) => `${c.name} (${c.id})`).join("; ")}. Ask the rep which one.`,
          };
        }
        return {
          ok: false,
          error: `No active user matches "${raw}" for ${desc.name}.`,
        };
      }
      const raw = String(rawValue).trim();
      // For non-User lookups, require a real Id; agent should look it up first
      // with sf_find_account / sf_query.
      if (!/^[A-Za-z0-9]{15,18}$/.test(raw)) {
        return {
          ok: false,
          error: `${desc.name} is a Lookup(${refTo}). Pass a Salesforce Id (15 or 18 chars). Use sf_find_account or sf_query to look it up.`,
        };
      }
      return { ok: true, value: raw, display: raw };
    }
    default:
      // string/textarea/email/phone/url/id — accept as string
      return { ok: true, value: String(rawValue), display: String(rawValue) };
  }
}

async function lookupRecord(
  ctx: AgentToolCtx,
  sobjectType: string,
  recordId: string,
  fieldNames: string[]
): Promise<{ row: any; nameField: string } | null> {
  const selectFields = ["Id", "Name", ...fieldNames]
    .filter((v, i, a) => a.indexOf(v) === i)
    .join(", ");
  try {
    const res = await ctx.conn.query(
      `SELECT ${selectFields} FROM ${sobjectType} WHERE Id = '${escapeSoql(recordId)}' LIMIT 1`
    );
    const row = (res.records as any[])[0];
    if (!row) return null;
    return { row, nameField: "Name" };
  } catch {
    // Some sobjects (e.g. Case, Task) don't have a Name field; retry without it.
    try {
      const fallbackFields = ["Id", ...fieldNames]
        .filter((v, i, a) => a.indexOf(v) === i)
        .join(", ");
      const res = await ctx.conn.query(
        `SELECT ${fallbackFields} FROM ${sobjectType} WHERE Id = '${escapeSoql(recordId)}' LIMIT 1`
      );
      const row = (res.records as any[])[0];
      if (!row) return null;
      return { row, nameField: "Id" };
    } catch {
      return null;
    }
  }
}

function buildContextLabel(
  sobjectType: string,
  recordName: string,
  row: any
): string {
  const accountName = row?.Account?.Name;
  if (sobjectType === "Opportunity") {
    return accountName
      ? `Opportunity · ${accountName}`
      : "Opportunity";
  }
  if (sobjectType === "Contact") {
    return accountName ? `Contact · ${accountName}` : "Contact";
  }
  return sobjectType;
}

const sfProposeRecordUpdate: AgentTool = {
  name: "sf_propose_record_update",
  definition: {
    name: "sf_propose_record_update",
    description:
      "Draft an update to ANY Salesforce record (Opportunity, Account, Contact, Lead, Task, custom objects, etc.). Does NOT write to Salesforce — it stages a confirmation card the rep clicks to apply. Use this whenever the rep asks to update / change / set / push a field on a record. The tool calls describe() to validate fields exist, are updateable, and match the expected type (picklist, date, currency, boolean, reference). For Lookup(User) fields, you may pass 'me' (resolves to the rep's own User Id) or a name (resolves via User WHERE Name LIKE). For other Lookup fields, pass a real 15/18-char Salesforce Id — use sf_find_account or sf_query first to look up the Id. **You may call this tool multiple times in one turn** if the rep asks for changes on multiple records — each call stages a separate card. If the tool returns an error (field not found, wrong type, invalid picklist value), read the error and either retry with corrected input or ask the rep to clarify.",
    input_schema: {
      type: "object",
      properties: {
        sobjectType: {
          type: "string",
          description:
            "The Salesforce object API name, e.g. 'Opportunity', 'Account', 'Contact', 'Lead', 'Task', or a custom object like 'Champion__c'. Case-sensitive.",
        },
        recordId: {
          type: "string",
          description:
            "The 15- or 18-character Salesforce record Id. Look it up first via sf_find_account or sf_query if you don't have it.",
        },
        fields: {
          type: "array",
          minItems: 1,
          items: {
            type: "object",
            properties: {
              field: {
                type: "string",
                description:
                  "The API name of the field (e.g. 'StageName', 'Post_Sales_Owner__c'). Custom fields end in __c.",
              },
              newValue: {
                description:
                  "The new value. Strings for text/picklist/email/phone/url, numbers for currency/double/int/percent, YYYY-MM-DD for date, ISO 8601 for datetime, true/false for boolean, a User name or 'me' for Lookup(User), an Id for other references.",
              },
              rationale: {
                type: "string",
                description:
                  "One sentence explaining why this change is being proposed.",
              },
            },
            required: ["field", "newValue", "rationale"],
          },
        },
        recap: {
          type: "string",
          description:
            "One-line summary of what the rep asked for. Shown at the top of the confirmation card.",
        },
      },
      required: ["sobjectType", "recordId", "fields", "recap"],
    },
  },
  async execute(input, ctx) {
    const sobjectType = String((input as any).sobjectType ?? "").trim();
    const recordId = String((input as any).recordId ?? "").trim();
    const recap = String((input as any).recap ?? "").trim();
    const rawFields = ((input as any).fields ?? []) as {
      field: string;
      newValue: unknown;
      rationale: string;
    }[];

    if (!sobjectType) return { status: "error", error: "sobjectType required" };
    if (!recordId) return { status: "error", error: "recordId required" };
    if (!recap) return { status: "error", error: "recap required" };
    if (!Array.isArray(rawFields) || rawFields.length === 0) {
      return { status: "error", error: "fields must be a non-empty array" };
    }

    const prefixSobject = sobjectFromIdPrefix(recordId);
    if (prefixSobject && prefixSobject.toLowerCase() !== sobjectType.toLowerCase()) {
      return {
        status: "error",
        error: `recordId prefix indicates ${prefixSobject}, but sobjectType is ${sobjectType}. They must match.`,
      };
    }

    let describe: DescribedObject;
    try {
      describe = await describeObject(ctx.conn, sobjectType);
    } catch (err: any) {
      return {
        status: "error",
        error: `Unknown SObject "${sobjectType}": ${err?.message ?? String(err)}. Valid examples include: ${COMMON_SOBJECTS.join(", ")}.`,
      };
    }

    // Resolve fields against describe.
    const resolved: { request: typeof rawFields[number]; desc: DescribedField }[] = [];
    for (const f of rawFields) {
      const found = findField(describe, f.field);
      if (!found) {
        const hints = suggestFields(describe, f.field);
        return {
          status: "error",
          error: `Field "${f.field}" not found on ${describe.name}.${hints.length ? ` Did you mean: ${hints.join(", ")}?` : ""}`,
        };
      }
      if (!found.updateable) {
        return {
          status: "error",
          error: `Field "${found.name}" on ${describe.name} is not updateable (calculated/system/read-only).`,
        };
      }
      if (found.calculated || found.autoNumber) {
        return {
          status: "error",
          error: `Field "${found.name}" on ${describe.name} is auto-computed and cannot be written directly.`,
        };
      }
      resolved.push({ request: f, desc: found });
    }

    // Fetch current values + record name + Account context if applicable.
    const fieldNames = resolved.map((r) => r.desc.name);
    const hasAccountId = describe.fields.has("accountid");
    const extraSelects = hasAccountId ? ["AccountId", "Account.Name"] : [];
    const lookup = await lookupRecord(ctx, sobjectType, recordId, [
      ...fieldNames,
      ...extraSelects,
    ]);
    if (!lookup) {
      return {
        status: "error",
        error: `${describe.name} ${recordId} not found, or you don't have access. Look it up with sf_query first.`,
      };
    }
    const row = lookup.row;
    const recordName: string =
      (row.Name as string | undefined) ?? (row.Id as string) ?? recordId;

    // Normalize each proposed value.
    const proposed: ProposedField[] = [];
    for (const { request, desc } of resolved) {
      const rationale =
        String(request.rationale ?? "").trim() || "Requested by rep.";
      const norm = await normalizeProposedValue(ctx, desc, request.newValue);
      if (!norm.ok) return { status: "error", error: norm.error };

      const currentRaw = row[desc.name] ?? null;
      let currentValue: string | number | boolean | null;
      let currentDisplay: string | null = null;
      if (currentRaw === null || currentRaw === undefined) {
        currentValue = null;
      } else if (typeof currentRaw === "boolean" || typeof currentRaw === "number") {
        currentValue = currentRaw;
        currentDisplay = String(currentRaw);
      } else {
        currentValue = String(currentRaw);
        currentDisplay = String(currentRaw);
      }

      // For Lookup(User), display the current user's name not the Id.
      if (desc.type === "reference" && desc.referenceTo[0] === "User" && typeof currentValue === "string" && currentValue) {
        const name = await fetchUserName(ctx.conn, currentValue);
        currentDisplay = name ?? currentValue;
      }

      proposed.push({
        field: desc.name,
        fieldLabel: desc.label,
        fieldType: fieldTypeForProposed(desc),
        currentValue,
        recommendedValue: norm.value,
        currentDisplay,
        recommendedDisplay: norm.display,
        referenceTo: desc.referenceTo[0],
        picklistValues:
          desc.picklistValues.length > 0
            ? desc.picklistValues.map((p) => p.value)
            : undefined,
        rationale,
      });
    }

    const contextLabel = buildContextLabel(describe.name, recordName, row);

    ctx.pendingRecordProposals.push({
      sobjectType: describe.name,
      recordId: row.Id ?? recordId,
      recordName,
      contextLabel,
      recap,
      fields: proposed,
    });

    return {
      status: "proposal_recorded",
      sobjectType: describe.name,
      recordName,
      fields: proposed.map((f) => ({
        field: f.field,
        from: f.currentDisplay ?? f.currentValue,
        to: f.recommendedDisplay ?? f.recommendedValue,
      })),
      next: "A confirmation card will be posted in the DM with Accept / Edit / Skip / Apply-all buttons. If the rep asked for additional record changes in the same message, call this tool again for each — multiple cards can be staged in one turn. Otherwise reply with one short sentence acknowledging the draft (do not restate the field values).",
    };
  },
};

const BULK_MAX_RECORDS = 50;

const sfGetRecentFailedWrites: AgentTool = {
  name: "sf_get_recent_failed_writes",
  definition: {
    name: "sf_get_recent_failed_writes",
    description:
      "Look up the rep's recent bulk-write failures from merlin's audit log. Use this when the rep's message looks like a follow-up after a failed bulk update (e.g. 'set X to Y on them', 'with X = Y', 'try again with Y for X', or a bare value after merlin flagged a missing field). Returns recent failed batches with the failed record Ids, the original proposed fields, and the per-record SF errors (statusCode, message, fields[]). The agent then drafts a new sf_propose_bulk_record_update on just the failed records with the original fields + the new field(s) the rep specified. Returns at most 3 most-recent batches.",
    input_schema: {
      type: "object",
      properties: {
        withinMinutes: {
          type: "number",
          description: "Look-back window. Defaults to 30 minutes.",
        },
      },
    },
  },
  async execute(input, ctx) {
    const minutes = Number((input as any)?.withinMinutes ?? 30);
    const failures = await getRecentBulkFailures(
      ctx.slackUserId,
      Number.isFinite(minutes) && minutes > 0 ? minutes : 30
    );
    return {
      failures: failures.slice(0, 3).map((b) => ({
        cardId: b.cardId,
        sobjectType: b.sobjectType,
        recap: b.recap,
        failedAtIso: b.failedAtIso,
        originalFields: b.originalFields.map((f) => ({
          field: f.field,
          fieldLabel: f.fieldLabel,
          recommendedValue: f.recommendedValue,
        })),
        failedRecords: b.failedRecords.map((r) => ({
          recordId: r.recordId,
          recordName: r.recordName,
          errors: r.errors,
        })),
        missingFieldsSummary: summarizeMissingFields(b.failedRecords),
      })),
    };
  },
};

function summarizeMissingFields(
  failedRecords: { errors: { statusCode: string; fields: string[] }[] }[]
): string[] {
  const set = new Set<string>();
  for (const r of failedRecords) {
    for (const e of r.errors ?? []) {
      for (const f of e.fields ?? []) set.add(f);
    }
  }
  return [...set];
}

const sfProposeBulkRecordUpdate: AgentTool = {
  name: "sf_propose_bulk_record_update",
  definition: {
    name: "sf_propose_bulk_record_update",
    description:
      "Draft the SAME field updates across multiple Salesforce records of the same SObject in one card. Use when the rep names more than one record or describes a filter ('close lost all the opps from Q1 that never made it past Discovery'). Find the record Ids first with sf_query, then call this with the Id list. Same describe-driven field validation as sf_propose_record_update. Hard cap: 50 records per call. Common-fields-across-all-records model (every record gets the same change). **You may call this tool multiple times in one turn** if the rep asks for distinct changes on different record sets (e.g. 'move A,B to stage 2 AND closed lost C,D' = two calls, two cards). One card per distinct (set of records, set of field changes) tuple.",
    input_schema: {
      type: "object",
      properties: {
        sobjectType: {
          type: "string",
          description:
            "The Salesforce object API name, e.g. 'Opportunity', 'Account'. All recordIds must be of this type.",
        },
        recordIds: {
          type: "array",
          minItems: 2,
          maxItems: 50,
          items: { type: "string" },
          description:
            "Array of 15- or 18-character Salesforce record Ids, all of the same SObject. Look them up first via sf_query.",
        },
        fields: {
          type: "array",
          minItems: 1,
          items: {
            type: "object",
            properties: {
              field: { type: "string" },
              newValue: {},
              rationale: { type: "string" },
            },
            required: ["field", "newValue", "rationale"],
          },
        },
        recap: {
          type: "string",
          description:
            "One-line summary of what's being applied to all records, e.g. 'Close lost 5 stalled Q1 opportunities'.",
        },
      },
      required: ["sobjectType", "recordIds", "fields", "recap"],
    },
  },
  async execute(input, ctx) {
    const sobjectType = String((input as any).sobjectType ?? "").trim();
    const rawIds = ((input as any).recordIds ?? []) as string[];
    const rawFields = ((input as any).fields ?? []) as {
      field: string;
      newValue: unknown;
      rationale: string;
    }[];
    const recap = String((input as any).recap ?? "").trim();

    if (!sobjectType) return { status: "error", error: "sobjectType required" };
    if (!Array.isArray(rawIds) || rawIds.length === 0) {
      return { status: "error", error: "recordIds must be a non-empty array" };
    }
    if (rawIds.length < 2) {
      return {
        status: "error",
        error:
          "Use sf_propose_record_update for single-record updates; sf_propose_bulk_record_update requires 2 or more records.",
      };
    }
    if (rawIds.length > BULK_MAX_RECORDS) {
      return {
        status: "error",
        error: `Bulk operations are capped at ${BULK_MAX_RECORDS} records per card. You sent ${rawIds.length}. Narrow the filter or split into multiple turns.`,
      };
    }
    if (!Array.isArray(rawFields) || rawFields.length === 0) {
      return { status: "error", error: "fields must be a non-empty array" };
    }
    if (!recap) return { status: "error", error: "recap required" };

    const uniqueIds = Array.from(
      new Set(rawIds.map((s) => String(s).trim()))
    ).filter(Boolean);
    const otherPrefixSummary: Record<string, number> = {};
    for (const id of uniqueIds) {
      const prefix = sobjectFromIdPrefix(id);
      if (prefix && prefix.toLowerCase() !== sobjectType.toLowerCase()) {
        otherPrefixSummary[prefix] = (otherPrefixSummary[prefix] ?? 0) + 1;
      }
    }
    const otherEntries = Object.entries(otherPrefixSummary);
    if (otherEntries.length > 0) {
      return {
        status: "error",
        error: `Some recordIds don't match sobjectType "${sobjectType}": ${otherEntries
          .map(([t, n]) => `${n} look like ${t}`)
          .join(", ")}. All Ids in a bulk update must be the same SObject.`,
      };
    }

    let describe: DescribedObject;
    try {
      describe = await describeObject(ctx.conn, sobjectType);
    } catch (err: any) {
      return {
        status: "error",
        error: `Unknown SObject "${sobjectType}": ${err?.message ?? String(err)}`,
      };
    }

    const resolved: { request: typeof rawFields[number]; desc: DescribedField }[] = [];
    for (const f of rawFields) {
      const found = findField(describe, f.field);
      if (!found) {
        const hints = suggestFields(describe, f.field);
        return {
          status: "error",
          error: `Field "${f.field}" not found on ${describe.name}.${hints.length ? ` Did you mean: ${hints.join(", ")}?` : ""}`,
        };
      }
      if (!found.updateable || found.calculated || found.autoNumber) {
        return {
          status: "error",
          error: `Field "${found.name}" on ${describe.name} is not writable.`,
        };
      }
      resolved.push({ request: f, desc: found });
    }

    const proposedFields: ProposedField[] = [];
    for (const { request, desc } of resolved) {
      const norm = await normalizeProposedValue(ctx, desc, request.newValue);
      if (!norm.ok) return { status: "error", error: norm.error };
      proposedFields.push({
        field: desc.name,
        fieldLabel: desc.label,
        fieldType: fieldTypeForProposed(desc),
        currentValue: null,
        recommendedValue: norm.value,
        currentDisplay: null,
        recommendedDisplay: norm.display,
        referenceTo: desc.referenceTo[0],
        picklistValues:
          desc.picklistValues.length > 0
            ? desc.picklistValues.map((p) => p.value)
            : undefined,
        rationale:
          String(request.rationale ?? "").trim() || "Requested by rep.",
      });
    }

    const fieldNames = resolved.map((r) => r.desc.name);
    const hasAccountId = describe.fields.has("accountid");
    const selectParts = ["Id", "Name", ...fieldNames];
    if (hasAccountId) selectParts.push("Account.Name");
    const selectClause = Array.from(new Set(selectParts)).join(", ");
    const idList = uniqueIds.map((id) => `'${escapeSoql(id)}'`).join(", ");

    let rows: any[] = [];
    try {
      const res = await ctx.conn.query(
        `SELECT ${selectClause} FROM ${sobjectType} WHERE Id IN (${idList}) LIMIT ${uniqueIds.length}`
      );
      rows = res.records as any[];
    } catch {
      try {
        const fallback = ["Id", ...fieldNames, ...(hasAccountId ? ["Account.Name"] : [])];
        const res = await ctx.conn.query(
          `SELECT ${Array.from(new Set(fallback)).join(", ")} FROM ${sobjectType} WHERE Id IN (${idList}) LIMIT ${uniqueIds.length}`
        );
        rows = res.records as any[];
      } catch (err2: any) {
        return {
          status: "error",
          error: `Salesforce lookup failed: ${err2?.message ?? String(err2)}`,
        };
      }
    }
    if (rows.length === 0) {
      return {
        status: "error",
        error: `None of the ${uniqueIds.length} ${describe.labelPlural} were found or accessible.`,
      };
    }

    const summaries: BulkRecordSummary[] = rows.map((row) => {
      const currentValues: Record<string, string | number | boolean | null> = {};
      for (const desc of resolved) {
        const v = row[desc.desc.name] ?? null;
        currentValues[desc.desc.name] =
          v === null || v === undefined
            ? null
            : typeof v === "boolean" || typeof v === "number"
              ? v
              : String(v);
      }
      const accountName = row?.Account?.Name as string | undefined;
      return {
        recordId: row.Id,
        recordName: (row.Name as string | undefined) ?? row.Id,
        contextLabel: accountName
          ? `${describe.label} · ${accountName}`
          : describe.label,
        currentValues,
      };
    });

    const foundIds = new Set(summaries.map((s) => s.recordId));
    const missing = uniqueIds.filter((id) => !foundIds.has(id));

    ctx.pendingBulkRecordProposals.push({
      sobjectType: describe.name,
      recordSummaries: summaries,
      fields: proposedFields,
      recap,
      excludedRecordIds: [],
      confirmed: false,
      instanceUrl: ctx.instanceUrl,
    });

    return {
      status: "proposal_recorded",
      sobjectType: describe.name,
      recordCount: summaries.length,
      missingCount: missing.length,
      fields: proposedFields.map((f) => ({
        field: f.field,
        to: f.recommendedDisplay ?? f.recommendedValue,
      })),
      next: `A bulk confirmation card will be posted in the DM listing all ${summaries.length} records. If the rep asked for additional bulk changes in the same message, call this tool again for each distinct (record set, field set) tuple — multiple cards can be staged in one turn. Otherwise reply with one short sentence acknowledging the draft including the count (e.g. "Drafted: close lost ${summaries.length} opportunities — review the list and click Apply").${
        missing.length > 0
          ? ` Note: ${missing.length} of the requested Id(s) were not found and are excluded from the card.`
          : ""
      } Do not list the record names; the card shows them.`,
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
  sfProposeRecordUpdate,
  sfProposeBulkRecordUpdate,
  sfGetRecentFailedWrites,
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
