import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "../../src/config.js";
import { dispatchRedTeamSweep } from "../../src/services/redTeamSweep.js";

/**
 * Vercel cron entry: enumerate every red_team_enabled user and trigger
 * `/api/red-team/run-for-user` for each. Mirrors the standup dispatcher.
 *
 * Auth: accepts Vercel cron's automatic `x-vercel-cron` invocation OR the
 * shared internal secret header so the endpoint can be invoked manually
 * during incident response.
 */
export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  const isVercelCron = req.headers["x-vercel-cron"] !== undefined;
  const internalOk = req.headers["x-internal-secret"] === config.internalSecret;
  if (!isVercelCron && !internalOk) {
    res.statusCode = 401;
    res.end("Unauthorized");
    return;
  }

  try {
    const result = await dispatchRedTeamSweep();
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[red-team/sweep] error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
