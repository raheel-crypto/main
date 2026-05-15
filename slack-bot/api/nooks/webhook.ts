import type { IncomingMessage, ServerResponse } from "node:http";
import crypto from "node:crypto";
import { config } from "../../src/config.js";
import { handleNooksWebhook } from "../../src/services/nooksHandler.js";
import type { NooksWebhookPayload } from "../../src/types.js";

async function readRawBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

const SIGNATURE_TOLERANCE_MS = 5 * 60 * 1000;

interface ParsedSignature {
  timestamp: string;
  signatureB64: string;
}

function parseSignatureHeader(header: string | undefined): ParsedSignature | null {
  if (typeof header !== "string" || !header) return null;
  let t: string | undefined;
  let s: string | undefined;
  for (const part of header.split(",")) {
    const [k, v] = part.split("=");
    if (!k || v === undefined) continue;
    if (k.trim() === "t") t = v.trim();
    else if (k.trim() === "s") s = v.trim();
  }
  if (!t || !s) return null;
  return { timestamp: t, signatureB64: s };
}

function verifySignature(
  signingKey: string,
  rawBody: string,
  parsed: ParsedSignature
): { ok: boolean; reason?: string } {
  const ts = Number(parsed.timestamp);
  if (!Number.isFinite(ts)) return { ok: false, reason: "bad_timestamp" };
  const drift = Math.abs(Date.now() - ts);
  if (drift > SIGNATURE_TOLERANCE_MS) {
    return { ok: false, reason: `timestamp_out_of_tolerance:${drift}ms` };
  }
  const signedPayload = `${parsed.timestamp}.${rawBody}`;
  const expected = crypto
    .createHmac("sha256", signingKey)
    .update(signedPayload)
    .digest("base64");

  let provided: Buffer;
  try {
    provided = Buffer.from(parsed.signatureB64, "base64");
  } catch {
    return { ok: false, reason: "bad_signature_b64" };
  }
  const expectedBuf = Buffer.from(expected, "base64");
  if (provided.length !== expectedBuf.length) {
    return { ok: false, reason: "length_mismatch" };
  }
  if (!crypto.timingSafeEqual(provided, expectedBuf)) {
    return { ok: false, reason: "signature_mismatch" };
  }
  return { ok: true };
}

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  if (req.method === "GET" || req.method === "HEAD") {
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(
      req.method === "HEAD"
        ? ""
        : JSON.stringify({ status: "ok", endpoint: "nooks/webhook" })
    );
    return;
  }
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.end("Method Not Allowed");
    return;
  }

  const rawBody = await readRawBody(req);

  if (config.nooks.signingKey) {
    const parsed = parseSignatureHeader(
      req.headers["x-webhook-signature"] as string | undefined
    );
    if (!parsed) {
      console.warn("[nooks/webhook] missing/unparseable x-webhook-signature");
      res.statusCode = 401;
      res.end("Unauthorized: missing signature");
      return;
    }
    const check = verifySignature(config.nooks.signingKey, rawBody, parsed);
    if (!check.ok) {
      console.warn("[nooks/webhook] signature rejected:", check.reason);
      res.statusCode = 401;
      res.end(`Unauthorized: ${check.reason}`);
      return;
    }
  } else if (config.nooks.webhookSecret) {
    const headerToken = req.headers["x-nooks-secret"];
    let queryToken: string | null = null;
    try {
      const url = new URL(req.url || "", "http://localhost");
      queryToken = url.searchParams.get("token");
    } catch {}
    const provided =
      typeof headerToken === "string" && headerToken
        ? headerToken
        : queryToken ?? "";
    if (provided !== config.nooks.webhookSecret) {
      res.statusCode = 401;
      res.end("Unauthorized");
      return;
    }
  } else {
    console.warn(
      "[nooks/webhook] no NOOKS_SIGNING_KEY or NOOKS_WEBHOOK_SECRET set — accepting unauthenticated POST"
    );
  }

  let body: any;
  try {
    body = rawBody ? JSON.parse(rawBody) : {};
  } catch (err: any) {
    console.warn("[nooks/webhook] non-JSON body, treating as preflight:", err.message);
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ ok: true, kind: "preflight_non_json" }));
    return;
  }

  console.log(
    "[nooks/webhook] incoming",
    JSON.stringify({
      method: req.method,
      bodyKeys: body && typeof body === "object" ? Object.keys(body) : null,
    })
  );

  if (!body || typeof body !== "object" || !body.callData?.callId) {
    console.log("[nooks/webhook] preflight-shaped body, returning 200:", JSON.stringify(body));
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ ok: true, kind: "preflight" }));
    return;
  }

  try {
    const result = await handleNooksWebhook(body as NooksWebhookPayload);
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[nooks/webhook] handler error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
