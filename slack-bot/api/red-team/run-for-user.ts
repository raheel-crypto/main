import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "../../src/config.js";
import { runRedTeamSweepForUser } from "../../src/services/redTeamSweep.js";

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

/**
 * Run the Red Team sweep for one rep (gated by the internal secret). Fanned
 * out from `/api/red-team/sweep`; gets its own 300s function budget so a slow
 * rep doesn't starve the others.
 */
export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.end("Method Not Allowed");
    return;
  }
  if (req.headers["x-internal-secret"] !== config.internalSecret) {
    res.statusCode = 401;
    res.end("Unauthorized");
    return;
  }
  try {
    const body = await readJson(req);
    const slackUserId = body?.slackUserId;
    if (!slackUserId) {
      res.statusCode = 400;
      res.end("slackUserId required");
      return;
    }
    const result = await runRedTeamSweepForUser(slackUserId);
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[red-team/run-for-user] error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
