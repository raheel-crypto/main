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
