import { Router } from "express";
import multer from "multer";
import path from "path";
import { getConnection } from "../services/salesforce.js";

/**
 * Signed order form upload for the agent close tools.
 *
 * The HXL cards in Claude cannot upload files (an MCP tool call carries no
 * binary), so the "Upload signed order form" button deep-links to the
 * visualizer's /upload page, which posts the file here. The file becomes a
 * ContentVersion whose FirstPublishLocationId is the opportunity, which makes
 * Salesforce create the ContentDocumentLink for us. The title is forced to the
 * "__signed" prefix the close tools and the screen flow look for.
 */
const router = Router();
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024 },
});

const OPP_ID = /^006[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/;
const SIGNED_PREFIX = "__signed";

export interface SignedDocument {
  contentDocumentId: string;
  title: string;
  fileExtension: string | null;
  createdDate: string;
}

export interface CloseDocOpportunity {
  id: string;
  name: string;
  accountName: string | null;
  stageName: string;
  isClosed: boolean;
  signedDocuments: SignedDocument[];
}

function isSignedTitle(title: string): boolean {
  const t = title.toLowerCase();
  return t.startsWith("__signed") || t.startsWith("signed__");
}

function escapeSoql(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}

async function loadOpportunity(conn: any, id: string): Promise<CloseDocOpportunity | null> {
  const opps = await conn.query(
    `SELECT Id, Name, StageName, IsClosed, Account.Name FROM Opportunity WHERE Id = '${escapeSoql(id)}' LIMIT 1`
  );
  if (!opps.records.length) return null;
  const opp = opps.records[0];

  const links = await conn.query(
    `SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.CreatedDate
     FROM ContentDocumentLink WHERE LinkedEntityId = '${escapeSoql(id)}'
     ORDER BY ContentDocument.CreatedDate DESC`
  );
  const signedDocuments: SignedDocument[] = links.records
    .filter((l: any) => l.ContentDocument && isSignedTitle(l.ContentDocument.Title || ""))
    .map((l: any) => ({
      contentDocumentId: l.ContentDocumentId,
      title: l.ContentDocument.Title,
      fileExtension: l.ContentDocument.FileExtension ?? null,
      createdDate: l.ContentDocument.CreatedDate,
    }));

  return {
    id: opp.Id,
    name: opp.Name,
    accountName: opp.Account?.Name ?? null,
    stageName: opp.StageName,
    isClosed: !!opp.IsClosed,
    signedDocuments,
  };
}

// GET /api/close-docs/opportunity/:id — header info plus the signed documents already attached
router.get("/opportunity/:id", async (req, res) => {
  const id = String(req.params.id);
  if (!OPP_ID.test(id)) {
    res.status(400).json({ message: "That is not an Opportunity Id (it should start with 006)." });
    return;
  }
  try {
    const conn = getConnection(req.session.sf!);
    const opp = await loadOpportunity(conn, id);
    if (!opp) {
      res.status(404).json({ message: "No opportunity with that Id, or you do not have access to it." });
      return;
    }
    res.json(opp);
  } catch (err: any) {
    console.error("[close-docs] load error:", err.message);
    res.status(500).json({ message: err.message });
  }
});

// POST /api/close-docs/opportunity/:id/signed-order-form — multipart field "file"
router.post("/opportunity/:id/signed-order-form", upload.single("file"), async (req, res) => {
  const id = String(req.params.id);
  if (!OPP_ID.test(id)) {
    res.status(400).json({ message: "That is not an Opportunity Id (it should start with 006)." });
    return;
  }
  if (!req.file) {
    res.status(400).json({ message: "No file was uploaded." });
    return;
  }
  try {
    const conn = getConnection(req.session.sf!);
    const before = await loadOpportunity(conn, id);
    if (!before) {
      res.status(404).json({ message: "No opportunity with that Id, or you do not have access to it." });
      return;
    }

    const original = req.file.originalname || "Order Form";
    const ext = path.extname(original);
    const stem = path.basename(original, ext).trim() || "Order Form";
    const title = isSignedTitle(stem) ? stem : `${SIGNED_PREFIX} ${stem}`;

    const result: any = await conn.sobject("ContentVersion").create({
      Title: title,
      PathOnClient: `${title}${ext}`,
      VersionData: req.file.buffer.toString("base64"),
      FirstPublishLocationId: id, // links the file to the opportunity
    });
    if (!result.success) {
      const detail = Array.isArray(result.errors) ? result.errors.map((e: any) => e.message || e).join("; ") : "";
      res.status(500).json({ message: `Salesforce rejected the file. ${detail}`.trim() });
      return;
    }

    const after = await loadOpportunity(conn, id);
    res.json({ ok: true, title, contentVersionId: result.id, opportunity: after });
  } catch (err: any) {
    console.error("[close-docs] upload error:", err.message);
    res.status(500).json({ message: err.message });
  }
});

export default router;
