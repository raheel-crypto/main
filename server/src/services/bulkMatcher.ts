import crypto from "crypto";
import { Connection } from "jsforce";
import { parse } from "csv-parse/sync";
import fs from "fs";

export interface BulkJob {
  id: string;
  status: "uploaded" | "matching" | "matched" | "updating" | "complete" | "error";
  progress: number;
  total: number;
  matched: number;
  unmatched: number;
  duplicates: number;
  csvHeaders: string[];
  csvRows: Record<string, string>[];
  csvPreview: Record<string, string>[];
  matchResults: { csvIndex: number; sfId: string; sfName: string }[];
  unmatchedIndices: number[];
  duplicateEntries: { csvIndex: number; sfIds: string[]; sfNames: string[] }[];
  updateSuccessCount: number;
  updateFailedCount: number;
  updateFailures: { id: string; error: string }[];
  error: string | null;
}

const jobs = new Map<string, BulkJob>();

export function getJob(id: string): BulkJob | undefined {
  return jobs.get(id);
}

export function parseAndStoreCSV(filePath: string): BulkJob {
  const raw = fs.readFileSync(filePath, "utf-8");
  const rows: Record<string, string>[] = parse(raw, {
    columns: true,
    skip_empty_lines: true,
    trim: true,
    bom: true,
  });

  const headers = rows.length > 0 ? Object.keys(rows[0]) : [];
  const id = crypto.randomUUID();

  const job: BulkJob = {
    id,
    status: "uploaded",
    progress: 0,
    total: rows.length,
    matched: 0,
    unmatched: 0,
    duplicates: 0,
    csvHeaders: headers,
    csvRows: rows,
    csvPreview: rows.slice(0, 5),
    matchResults: [],
    unmatchedIndices: [],
    duplicateEntries: [],
    updateSuccessCount: 0,
    updateFailedCount: 0,
    updateFailures: [],
    error: null,
  };

  jobs.set(id, job);

  // Clean up temp file
  fs.unlink(filePath, () => {});

  return job;
}

function escapeSOQL(val: string): string {
  return val.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}

function buildBatches(values: string[], batchSize = 300): string[][] {
  const batches: string[][] = [];
  for (let i = 0; i < values.length; i += batchSize) {
    batches.push(values.slice(i, i + batchSize));
  }
  return batches;
}

export async function startMatchJob(
  conn: Connection,
  jobId: string,
  objectName: string,
  csvColumn: string,
  sfField: string
): Promise<void> {
  const job = jobs.get(jobId);
  if (!job) throw new Error("Job not found");

  job.status = "matching";
  job.progress = 0;
  job.matchResults = [];
  job.unmatchedIndices = [];
  job.duplicateEntries = [];
  job.matched = 0;
  job.unmatched = 0;
  job.duplicates = 0;

  const values = job.csvRows.map((row) => row[csvColumn]?.trim()).filter(Boolean);
  const uniqueValues = [...new Set(values)];
  const batches = buildBatches(uniqueValues);
  const totalBatches = batches.length;

  // Map: matchValue → list of SF records
  const sfMap = new Map<string, { id: string; name: string }[]>();

  for (let i = 0; i < batches.length; i++) {
    try {
      const batch = batches[i];
      const inClause = batch.map((v) => `'${escapeSOQL(v)}'`).join(",");
      const nameField = sfField === "Name" ? "Id" : "Name";
      const soql = `SELECT Id, ${sfField}, ${nameField} FROM ${objectName} WHERE ${sfField} IN (${inClause})`;

      const result = await conn.query<Record<string, any>>(soql);
      for (const rec of result.records || []) {
        const key = String(rec[sfField] || "").toLowerCase();
        if (!sfMap.has(key)) sfMap.set(key, []);
        sfMap.get(key)!.push({
          id: rec.Id,
          name: rec.Name || rec.Id,
        });
      }
    } catch (err: any) {
      console.error(`[bulk] Batch ${i + 1} error: ${err.message}`);
    }

    job.progress = Math.round(((i + 1) / totalBatches) * 100);
  }

  // Map CSV rows to results
  for (let idx = 0; idx < job.csvRows.length; idx++) {
    const val = (job.csvRows[idx][csvColumn] || "").trim().toLowerCase();
    const matches = sfMap.get(val);

    if (!matches || matches.length === 0) {
      job.unmatchedIndices.push(idx);
    } else if (matches.length === 1) {
      job.matchResults.push({ csvIndex: idx, sfId: matches[0].id, sfName: matches[0].name });
    } else {
      job.duplicateEntries.push({
        csvIndex: idx,
        sfIds: matches.map((m) => m.id),
        sfNames: matches.map((m) => m.name),
      });
    }
  }

  job.matched = job.matchResults.length;
  job.unmatched = job.unmatchedIndices.length;
  job.duplicates = job.duplicateEntries.length;
  job.status = "matched";
  job.progress = 100;
}

export async function startUpdateJob(
  conn: Connection,
  jobId: string,
  objectName: string,
  fieldMapping: { csvColumn: string; sfField: string }[]
): Promise<void> {
  const job = jobs.get(jobId);
  if (!job) throw new Error("Job not found");
  if (job.matchResults.length === 0) throw new Error("No matched records to update");

  job.status = "updating";
  job.progress = 0;
  job.updateSuccessCount = 0;
  job.updateFailedCount = 0;
  job.updateFailures = [];

  // Build records for update
  const records = job.matchResults.map((match) => {
    const csvRow = job.csvRows[match.csvIndex];
    const rec: Record<string, string> = { Id: match.sfId };
    for (const mapping of fieldMapping) {
      const val = csvRow[mapping.csvColumn];
      if (val !== undefined && val !== "") {
        rec[mapping.sfField] = val;
      }
    }
    return rec;
  });

  // Use Bulk API 2.0
  try {
    const bulkJob = conn.bulk2.createJob({
      object: objectName,
      operation: "update",
    });

    const results = await bulkJob.open();
    job.progress = 10;

    await bulkJob.uploadData(records);
    job.progress = 30;

    await bulkJob.close();
    job.progress = 40;

    // Poll until complete
    let info = await bulkJob.check();
    while (info.state === "UploadComplete" || info.state === "InProgress") {
      await new Promise((r) => setTimeout(r, 2000));
      info = await bulkJob.check();
      if (info.numberRecordsProcessed && job.total > 0) {
        const pct = Math.min(
          95,
          40 + Math.round((info.numberRecordsProcessed / records.length) * 55)
        );
        job.progress = pct;
      }
    }

    // Get results
    const successResults = await bulkJob.getAllResults();
    let successes = 0;
    let failures = 0;
    const failureDetails: { id: string; error: string }[] = [];

    if (successResults) {
      for (const batch of [
        successResults.successfulResults || [],
        successResults.failedResults || [],
        successResults.unprocessedRecords || [],
      ]) {
        for (const rec of batch as any[]) {
          if (rec.sf__Created === "true" || rec.sf__Id) {
            successes++;
          } else if (rec.sf__Error) {
            failures++;
            failureDetails.push({ id: rec.sf__Id || "unknown", error: rec.sf__Error });
          }
        }
      }
    }

    job.updateSuccessCount = successes || records.length - failures;
    job.updateFailedCount = failures;
    job.updateFailures = failureDetails;
    job.status = "complete";
    job.progress = 100;
  } catch (err: any) {
    // Fallback: batched REST update for orgs where Bulk 2.0 has issues
    console.log(`[bulk] Bulk API 2.0 failed (${err.message}), falling back to batched update`);
    await batchedRestUpdate(conn, job, objectName, records);
  }
}

async function batchedRestUpdate(
  conn: Connection,
  job: BulkJob,
  objectName: string,
  records: Record<string, string>[]
): Promise<void> {
  const BATCH_SIZE = 200;
  let successes = 0;
  let failures = 0;
  const failureDetails: { id: string; error: string }[] = [];

  for (let i = 0; i < records.length; i += BATCH_SIZE) {
    const batch = records.slice(i, i + BATCH_SIZE);
    try {
      const results = await conn.sobject(objectName).update(batch as any);
      const resultArr = Array.isArray(results) ? results : [results];
      for (const r of resultArr) {
        if ((r as any).success) {
          successes++;
        } else {
          failures++;
          const errors = (r as any).errors || [];
          failureDetails.push({
            id: (r as any).id || "unknown",
            error: errors.map((e: any) => e.message).join("; "),
          });
        }
      }
    } catch (err: any) {
      failures += batch.length;
      failureDetails.push({ id: "batch", error: err.message });
    }

    job.progress = Math.min(95, Math.round(((i + BATCH_SIZE) / records.length) * 100));
  }

  job.updateSuccessCount = successes;
  job.updateFailedCount = failures;
  job.updateFailures = failureDetails;
  job.status = "complete";
  job.progress = 100;
}

export function getWritableFields(
  fields: any[]
): { name: string; label: string; type: string }[] {
  return fields
    .filter(
      (f: any) =>
        f.updateable &&
        !f.autoNumber &&
        !f.calculated &&
        f.name !== "Id"
    )
    .map((f: any) => ({ name: f.name, label: f.label, type: f.type }));
}
