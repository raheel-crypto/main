import { Router } from "express";
import multer from "multer";
import os from "os";
import { getConnection } from "../services/salesforce.js";
import {
  parseAndStoreCSV,
  getJob,
  startMatchJob,
  startUpdateJob,
  getWritableFields,
} from "../services/bulkMatcher.js";

const router = Router();
const upload = multer({ dest: os.tmpdir() });

// POST /api/bulk/upload — upload and parse CSV
router.post("/upload", upload.single("file"), (req, res) => {
  try {
    if (!req.file) {
      res.status(400).json({ message: "No file uploaded" });
      return;
    }
    const job = parseAndStoreCSV(req.file.path);
    res.json({
      jobId: job.id,
      headers: job.csvHeaders,
      preview: job.csvPreview,
      rowCount: job.total,
    });
  } catch (err: any) {
    console.error("[bulk] Upload error:", err.message);
    res.status(500).json({ message: err.message });
  }
});

// GET /api/bulk/objects — list queryable objects for matching
router.get("/objects", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const desc = await conn.describeGlobal();
    const objects = desc.sobjects
      .filter((o) => o.queryable && !o.name.includes("__mdt") && !o.name.includes("__e"))
      .map((o) => ({ name: o.name, label: o.label, custom: o.custom }))
      .sort((a, b) => a.label.localeCompare(b.label));
    res.json(objects);
  } catch (err: any) {
    res.status(500).json({ message: err.message });
  }
});

// GET /api/bulk/fields/:object — list fields for matching or updating
router.get("/fields/:object", async (req, res) => {
  try {
    const conn = getConnection(req.session.sf!);
    const desc = await conn.describe(req.params.object);
    const matchFields = desc.fields
      .filter((f) => ["string", "email", "id"].includes(f.type))
      .map((f) => ({ name: f.name, label: f.label, type: f.type }));
    const writableFields = getWritableFields(desc.fields);
    res.json({ matchFields, writableFields });
  } catch (err: any) {
    res.status(500).json({ message: err.message });
  }
});

// POST /api/bulk/match — start matching job
router.post("/match", async (req, res) => {
  try {
    const { jobId, objectName, csvColumn, sfField } = req.body;
    if (!jobId || !objectName || !csvColumn || !sfField) {
      res.status(400).json({ message: "Missing required fields" });
      return;
    }
    const job = getJob(jobId);
    if (!job) {
      res.status(404).json({ message: "Job not found" });
      return;
    }

    // Start matching in the background
    const conn = getConnection(req.session.sf!);
    startMatchJob(conn, jobId, objectName, csvColumn, sfField).catch((err) => {
      const j = getJob(jobId);
      if (j) {
        j.status = "error";
        j.error = err.message;
      }
    });

    res.json({ status: "started" });
  } catch (err: any) {
    res.status(500).json({ message: err.message });
  }
});

// GET /api/bulk/jobs/:id/status — poll job status
router.get("/jobs/:id/status", (req, res) => {
  const job = getJob(req.params.id);
  if (!job) {
    res.status(404).json({ message: "Job not found" });
    return;
  }
  res.json({
    status: job.status,
    progress: job.progress,
    total: job.total,
    matched: job.matched,
    unmatched: job.unmatched,
    duplicates: job.duplicates,
    updateSuccessCount: job.updateSuccessCount,
    updateFailedCount: job.updateFailedCount,
    error: job.error,
  });
});

// GET /api/bulk/jobs/:id/results — get full results
router.get("/jobs/:id/results", (req, res) => {
  const job = getJob(req.params.id);
  if (!job) {
    res.status(404).json({ message: "Job not found" });
    return;
  }
  res.json({
    status: job.status,
    matched: job.matchResults.map((m) => ({
      csvRow: job.csvRows[m.csvIndex],
      sfId: m.sfId,
      sfName: m.sfName,
    })),
    unmatched: job.unmatchedIndices.map((idx) => job.csvRows[idx]),
    duplicates: job.duplicateEntries.map((d) => ({
      csvRow: job.csvRows[d.csvIndex],
      sfIds: d.sfIds,
      sfNames: d.sfNames,
    })),
    updateFailures: job.updateFailures,
  });
});

// POST /api/bulk/update — start bulk update
router.post("/update", async (req, res) => {
  try {
    const { jobId, objectName, fieldMapping } = req.body;
    if (!jobId || !objectName || !fieldMapping) {
      res.status(400).json({ message: "Missing required fields" });
      return;
    }

    const job = getJob(jobId);
    if (!job) {
      res.status(404).json({ message: "Job not found" });
      return;
    }

    const conn = getConnection(req.session.sf!);
    startUpdateJob(conn, jobId, objectName, fieldMapping).catch((err) => {
      const j = getJob(jobId);
      if (j) {
        j.status = "error";
        j.error = err.message;
      }
    });

    res.json({ status: "started" });
  } catch (err: any) {
    res.status(500).json({ message: err.message });
  }
});

// GET /api/bulk/jobs/:id/unmatched — download unmatched rows as CSV
router.get("/jobs/:id/unmatched", (req, res) => {
  const job = getJob(req.params.id);
  if (!job) {
    res.status(404).json({ message: "Job not found" });
    return;
  }

  const unmatchedRows = job.unmatchedIndices.map((idx) => job.csvRows[idx]);
  if (unmatchedRows.length === 0) {
    res.status(404).json({ message: "No unmatched records" });
    return;
  }

  const headers = job.csvHeaders;
  const csvLines = [
    headers.join(","),
    ...unmatchedRows.map((row) =>
      headers.map((h) => `"${(row[h] || "").replace(/"/g, '""')}"`).join(",")
    ),
  ];

  res.setHeader("Content-Type", "text/csv");
  res.setHeader("Content-Disposition", "attachment; filename=unmatched.csv");
  res.send(csvLines.join("\n"));
});

export default router;
