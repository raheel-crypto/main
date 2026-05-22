import { Connection } from "jsforce";
import { config } from "../config.js";
import { appendAudit } from "../db/queries.js";
import type { RecommendedField } from "../types.js";

export interface ApplyResult {
  field: string;
  ok: boolean;
  error?: string;
}

function coerce(field: string, value: unknown): unknown {
  if (field === "Amount" && typeof value === "string") {
    const n = Number(value.replace(/[^0-9.\-]/g, ""));
    return Number.isFinite(n) ? n : value;
  }
  if (field === "CloseDate" && typeof value === "string") {
    return value.slice(0, 10);
  }
  return value;
}

export async function applyFields(args: {
  conn: Connection;
  slackUserId: string;
  opportunityId: string;
  fields: { field: string; newValue: unknown; oldValue: unknown }[];
}): Promise<ApplyResult[]> {
  const { conn, slackUserId, opportunityId, fields } = args;
  if (fields.length === 0) return [];

  const payload: Record<string, unknown> = { Id: opportunityId };
  for (const f of fields) {
    payload[f.field] = coerce(f.field, f.newValue);
  }

  const results: ApplyResult[] = [];

  if (config.dryRun) {
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId,
        fieldName: f.field,
        action: "applied",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
        metadata: { dryRun: true },
      });
      results.push({ field: f.field, ok: true });
    }
    return results;
  }

  try {
    await conn.sobject("Opportunity").update(payload as any);
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId,
        fieldName: f.field,
        action: "applied",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
      });
      results.push({ field: f.field, ok: true });
    }
  } catch (err: any) {
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId,
        fieldName: f.field,
        action: "apply_failed",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
        metadata: { error: err.message },
      });
      results.push({ field: f.field, ok: false, error: err.message });
    }
  }
  return results;
}

export function fieldsFromRecommendation(
  fields: RecommendedField[]
): { field: string; newValue: unknown; oldValue: unknown }[] {
  return fields.map((f) => ({
    field: f.field,
    newValue: f.recommendedValue,
    oldValue: f.currentValue,
  }));
}

function coerceForSobject(
  sobjectType: string,
  field: string,
  value: unknown
): unknown {
  // Generic best-effort coercion; the propose tool already normalized values,
  // so this is mainly for late-stage edits via the modal.
  if (value === null || value === undefined || value === "") return null;
  if (
    typeof value === "string" &&
    /^-?\d+(\.\d+)?$/.test(value) &&
    /amount|arr|mrr|revenue|quantity|count|percent/i.test(field)
  ) {
    const n = Number(value);
    return Number.isFinite(n) ? n : value;
  }
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}/.test(value)) {
    return value.slice(0, 10);
  }
  if (value === "true") return true;
  if (value === "false") return false;
  return value;
}

export interface ApplyRecordResult {
  field: string;
  ok: boolean;
  error?: string;
}

export interface BulkApplyResult {
  recordId: string;
  ok: boolean;
  error?: string;
}

export async function applyRecordFields(args: {
  conn: Connection;
  slackUserId: string;
  sobjectType: string;
  recordId: string;
  fields: { field: string; newValue: unknown; oldValue: unknown }[];
}): Promise<ApplyRecordResult[]> {
  const { conn, slackUserId, sobjectType, recordId, fields } = args;
  if (fields.length === 0) return [];

  const payload: Record<string, unknown> = { Id: recordId };
  for (const f of fields) {
    payload[f.field] = coerceForSobject(sobjectType, f.field, f.newValue);
  }

  const results: ApplyRecordResult[] = [];
  const auditOppId = sobjectType === "Opportunity" ? recordId : null;

  if (config.dryRun) {
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId: auditOppId,
        fieldName: f.field,
        action: "record_applied",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
        metadata: { dryRun: true, sobjectType, recordId },
      });
      results.push({ field: f.field, ok: true });
    }
    return results;
  }

  try {
    await conn.sobject(sobjectType).update(payload as any);
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId: auditOppId,
        fieldName: f.field,
        action: "record_applied",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
        metadata: { sobjectType, recordId },
      });
      results.push({ field: f.field, ok: true });
    }
  } catch (err: any) {
    for (const f of fields) {
      await appendAudit({
        slackUserId,
        opportunityId: auditOppId,
        fieldName: f.field,
        action: "record_apply_failed",
        oldValue: String(f.oldValue ?? ""),
        newValue: String(f.newValue ?? ""),
        metadata: { sobjectType, recordId, error: err.message },
      });
      results.push({ field: f.field, ok: false, error: err.message });
    }
  }
  return results;
}

export async function applyBulkRecordFields(args: {
  conn: Connection;
  slackUserId: string;
  sobjectType: string;
  recordIds: string[];
  fields: { field: string; newValue: unknown }[];
  batchId: string;
}): Promise<BulkApplyResult[]> {
  const { conn, slackUserId, sobjectType, recordIds, fields, batchId } = args;
  if (recordIds.length === 0 || fields.length === 0) return [];

  const fieldPayload: Record<string, unknown> = {};
  for (const f of fields) {
    fieldPayload[f.field] = coerceForSobject(sobjectType, f.field, f.newValue);
  }

  const results: BulkApplyResult[] = [];

  if (config.dryRun) {
    for (const id of recordIds) {
      for (const f of fields) {
        await appendAudit({
          slackUserId,
          opportunityId: sobjectType === "Opportunity" ? id : null,
          fieldName: f.field,
          action: "bulk_record_applied",
          newValue: String(f.newValue ?? ""),
          metadata: { dryRun: true, sobjectType, recordId: id, batchId },
        });
      }
      results.push({ recordId: id, ok: true });
    }
    return results;
  }

  // Salesforce Composite API: up to 200 records per PATCH, partial-success via
  // allOrNone=false. Chunk to be safe; we cap upstream at 50 but keep the
  // chunker future-proof.
  const chunks: string[][] = [];
  for (let i = 0; i < recordIds.length; i += 200) {
    chunks.push(recordIds.slice(i, i + 200));
  }

  for (const chunk of chunks) {
    const body = {
      allOrNone: false,
      records: chunk.map((id) => ({
        attributes: { type: sobjectType },
        Id: id,
        ...fieldPayload,
      })),
    };
    const apiVersion =
      (conn as any).version ?? (conn as any)._defaultVersion ?? "59.0";
    const path = `/services/data/v${apiVersion}/composite/sobjects`;
    let responseRecords: { id?: string; success?: boolean; errors?: any[] }[] = [];
    try {
      const res: any = await (conn as any).request({
        method: "PATCH",
        url: path,
        body: JSON.stringify(body),
        headers: { "Content-Type": "application/json" },
      });
      responseRecords = Array.isArray(res) ? res : (res?.records ?? []);
    } catch (err: any) {
      console.error(
        `[bulk] composite PATCH failed: ${err?.message ?? err}; falling back to per-record updates.`
      );
      for (const id of chunk) {
        try {
          await conn.sobject(sobjectType).update({ Id: id, ...fieldPayload } as any);
          for (const f of fields) {
            await appendAudit({
              slackUserId,
              opportunityId: sobjectType === "Opportunity" ? id : null,
              fieldName: f.field,
              action: "bulk_record_applied",
              newValue: String(f.newValue ?? ""),
              metadata: { sobjectType, recordId: id, batchId, fallback: true },
            });
          }
          results.push({ recordId: id, ok: true });
        } catch (e: any) {
          for (const f of fields) {
            await appendAudit({
              slackUserId,
              opportunityId: sobjectType === "Opportunity" ? id : null,
              fieldName: f.field,
              action: "bulk_record_apply_failed",
              newValue: String(f.newValue ?? ""),
              metadata: { sobjectType, recordId: id, batchId, error: e.message, fallback: true },
            });
          }
          results.push({ recordId: id, ok: false, error: e.message });
        }
      }
      continue;
    }

    for (let i = 0; i < chunk.length; i++) {
      const id = chunk[i];
      const r = responseRecords[i];
      const ok = !!r?.success;
      const errMsg = ok
        ? undefined
        : (r?.errors ?? []).map((e: any) => e.message).join("; ") ||
          "Unknown Salesforce error";
      for (const f of fields) {
        await appendAudit({
          slackUserId,
          opportunityId: sobjectType === "Opportunity" ? id : null,
          fieldName: f.field,
          action: ok ? "bulk_record_applied" : "bulk_record_apply_failed",
          newValue: String(f.newValue ?? ""),
          metadata: {
            sobjectType,
            recordId: id,
            batchId,
            ...(ok ? {} : { error: errMsg }),
          },
        });
      }
      results.push({ recordId: id, ok, error: errMsg });
    }
  }
  return results;
}

export interface CreateOpportunityInput {
  conn: Connection;
  slackUserId: string;
  accountId: string;
  name: string;
  stage: string;
  amount: number | null;
  closeDate: string;
}

export interface CreateOpportunityResult {
  ok: boolean;
  opportunityId?: string;
  error?: string;
  dryRun?: boolean;
}

export async function createOpportunity(
  input: CreateOpportunityInput
): Promise<CreateOpportunityResult> {
  const { conn, slackUserId, accountId, name, stage, amount, closeDate } = input;
  const payload: Record<string, unknown> = {
    AccountId: accountId,
    Name: name,
    StageName: stage,
    CloseDate: closeDate.slice(0, 10),
  };
  if (amount != null && Number.isFinite(amount)) payload.Amount = amount;

  if (config.dryRun) {
    await appendAudit({
      slackUserId,
      action: "opportunity_created",
      newValue: name,
      metadata: { dryRun: true, accountId, stage, amount, closeDate },
    });
    return { ok: true, dryRun: true };
  }

  try {
    const result = await conn.sobject("Opportunity").create(payload as any);
    const created = Array.isArray(result) ? result[0] : result;
    if (!created.success) {
      const errMsg = (created.errors ?? []).map((e: any) => e.message).join("; ");
      await appendAudit({
        slackUserId,
        action: "opportunity_create_failed",
        newValue: name,
        metadata: { accountId, error: errMsg },
      });
      return { ok: false, error: errMsg || "create_failed" };
    }
    await appendAudit({
      slackUserId,
      opportunityId: created.id,
      action: "opportunity_created",
      newValue: name,
      metadata: { accountId, stage, amount, closeDate },
    });
    return { ok: true, opportunityId: created.id };
  } catch (err: any) {
    await appendAudit({
      slackUserId,
      action: "opportunity_create_failed",
      newValue: name,
      metadata: { accountId, error: err.message },
    });
    return { ok: false, error: err.message };
  }
}

export interface CreateTaskInput {
  conn: Connection;
  slackUserId: string;
  whatId: string;
  ownerId: string;
  subject: string;
  dueDate: string;
  description: string | null;
}

export interface CreateTaskResult {
  ok: boolean;
  taskId?: string;
  error?: string;
  dryRun?: boolean;
}

export interface CreateContactInput {
  conn: Connection;
  slackUserId: string;
  accountId: string;
  firstName: string;
  lastName: string;
  email: string;
  title?: string | null;
}

export interface CreateContactResult {
  ok: boolean;
  contactId?: string;
  error?: string;
  dryRun?: boolean;
}

export async function createContact(
  input: CreateContactInput
): Promise<CreateContactResult> {
  const { conn, slackUserId, accountId, firstName, lastName, email, title } =
    input;
  const payload: Record<string, unknown> = {
    AccountId: accountId,
    FirstName: firstName || "",
    LastName: lastName || "(unknown)",
    Email: email,
  };
  if (title && title.trim()) payload.Title = title.trim();

  if (config.dryRun) {
    await appendAudit({
      slackUserId,
      action: "contact_created",
      newValue: `${firstName} ${lastName} <${email}>`,
      metadata: { dryRun: true, accountId, title: title ?? null },
    });
    return { ok: true, dryRun: true };
  }

  try {
    const result = await conn.sobject("Contact").create(payload as any);
    const created = Array.isArray(result) ? result[0] : result;
    if (!created.success) {
      const errMsg = (created.errors ?? []).map((e: any) => e.message).join("; ");
      await appendAudit({
        slackUserId,
        action: "contact_create_failed",
        newValue: email,
        metadata: { accountId, error: errMsg },
      });
      return { ok: false, error: errMsg || "create_failed" };
    }
    await appendAudit({
      slackUserId,
      action: "contact_created",
      newValue: `${firstName} ${lastName} <${email}>`,
      metadata: { accountId, contactId: created.id, title: title ?? null },
    });
    return { ok: true, contactId: created.id };
  } catch (err: any) {
    await appendAudit({
      slackUserId,
      action: "contact_create_failed",
      newValue: email,
      metadata: { accountId, error: err.message },
    });
    return { ok: false, error: err.message };
  }
}

export async function createTask(
  input: CreateTaskInput
): Promise<CreateTaskResult> {
  const { conn, slackUserId, whatId, ownerId, subject, dueDate, description } =
    input;
  const payload: Record<string, unknown> = {
    WhatId: whatId,
    OwnerId: ownerId,
    Subject: subject,
    ActivityDate: dueDate.slice(0, 10),
    Status: "Open",
  };
  if (description) payload.Description = description;

  if (config.dryRun) {
    await appendAudit({
      slackUserId,
      action: "task_created",
      newValue: subject,
      metadata: { dryRun: true, whatId, dueDate },
    });
    return { ok: true, dryRun: true };
  }

  try {
    const result = await conn.sobject("Task").create(payload as any);
    const created = Array.isArray(result) ? result[0] : result;
    if (!created.success) {
      const errMsg = (created.errors ?? []).map((e: any) => e.message).join("; ");
      await appendAudit({
        slackUserId,
        action: "task_create_failed",
        newValue: subject,
        metadata: { whatId, error: errMsg },
      });
      return { ok: false, error: errMsg || "create_failed" };
    }
    await appendAudit({
      slackUserId,
      action: "task_created",
      newValue: subject,
      metadata: { whatId, dueDate, taskId: created.id },
    });
    return { ok: true, taskId: created.id };
  } catch (err: any) {
    await appendAudit({
      slackUserId,
      action: "task_create_failed",
      newValue: subject,
      metadata: { whatId, error: err.message },
    });
    return { ok: false, error: err.message };
  }
}
