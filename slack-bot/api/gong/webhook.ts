import type { IncomingMessage, ServerResponse } from "node:http";
import { verifyGongWebhookAuth } from "../../src/services/gongWebhookAuth.js";
import { handleGongWebhook } from "../../src/services/gongWebhookHandler.js";
import type { GongWebhookPayload } from "../../src/types.js";

async function readRawBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function safeHeaderDigest(req: IncomingMessage): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (Array.isArray(v)) out[k] = v.join(",");
    else if (typeof v === "string") out[k] = v;
  }
  if (out["authorization"]) {
    out["authorization"] = out["authorization"].slice(0, 24) + "…(redacted)";
  }
  return out;
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
        : JSON.stringify({ status: "ok", endpoint: "gong/webhook" })
    );
    return;
  }
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.end("Method Not Allowed");
    return;
  }

  const rawBody = await readRawBody(req);
  const headerDigest = safeHeaderDigest(req);
  console.log("[gong/webhook] headers:", JSON.stringify(headerDigest));

  const auth = verifyGongWebhookAuth(req);
  if (!auth.ok) {
    console.warn(
      `[gong/webhook] auth rejected (${auth.mode}): ${auth.reason ?? "unknown"}`
    );
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ ok: false, reason: `unauthorized:${auth.reason}` }));
    return;
  }
  if (auth.mode === "open") {
    console.warn(
      "[gong/webhook] no GONG_JWT_*/GONG_WEBHOOK_TOKEN configured — accepting unauthenticated POST"
    );
  }

  let body: unknown;
  try {
    body = rawBody ? JSON.parse(rawBody) : {};
  } catch (err: any) {
    console.warn(
      "[gong/webhook] non-JSON body, treating as preflight:",
      err.message
    );
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ ok: true, kind: "preflight_non_json" }));
    return;
  }

  if (
    !body ||
    typeof body !== "object" ||
    !(body as GongWebhookPayload).callId
  ) {
    console.log(
      "[gong/webhook] preflight-shaped body, returning 200:",
      JSON.stringify(body)
    );
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ ok: true, kind: "preflight" }));
    return;
  }

  try {
    const result = await handleGongWebhook(
      body as GongWebhookPayload,
      headerDigest
    );
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[gong/webhook] handler error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
