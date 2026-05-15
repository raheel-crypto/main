import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "../../src/config.js";
import { handleNooksWebhook } from "../../src/services/nooksHandler.js";
import type { NooksWebhookPayload } from "../../src/types.js";

async function readJson(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
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

  if (config.nooks.webhookSecret) {
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
      "[nooks/webhook] NOOKS_WEBHOOK_SECRET not set — accepting unauthenticated POST"
    );
  }

  let body: any;
  try {
    body = await readJson(req);
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
      headers: req.headers,
      bodyKeys: body && typeof body === "object" ? Object.keys(body) : null,
    })
  );

  if (!body || typeof body !== "object" || !body.data?.call_id) {
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
