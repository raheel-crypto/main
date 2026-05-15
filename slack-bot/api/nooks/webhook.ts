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
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.end("Method Not Allowed");
    return;
  }

  if (!config.nooks.webhookSecret) {
    console.error("[nooks/webhook] NOOKS_WEBHOOK_SECRET not configured");
    res.statusCode = 503;
    res.end("Webhook not configured");
    return;
  }

  const provided = req.headers["x-nooks-secret"];
  if (provided !== config.nooks.webhookSecret) {
    res.statusCode = 401;
    res.end("Unauthorized");
    return;
  }

  let body: NooksWebhookPayload;
  try {
    body = (await readJson(req)) as NooksWebhookPayload;
  } catch (err: any) {
    res.statusCode = 400;
    res.end(`Invalid JSON: ${err.message}`);
    return;
  }

  if (!body || typeof body !== "object" || !body.data?.call_id) {
    res.statusCode = 400;
    res.end("Missing data.call_id");
    return;
  }

  try {
    const result = await handleNooksWebhook(body);
    res.statusCode = 200;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[nooks/webhook] handler error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
