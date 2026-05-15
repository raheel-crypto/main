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
