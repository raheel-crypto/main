import type { IncomingMessage, ServerResponse } from "node:http";
import { dispatchDueUsers } from "../../src/scheduler.js";

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  try {
    const result = await dispatchDueUsers();
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(result));
  } catch (err: any) {
    console.error("[cron/tick] error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
