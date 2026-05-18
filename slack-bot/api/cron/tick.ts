import type { IncomingMessage, ServerResponse } from "node:http";
import { dispatchDueUsers } from "../../src/scheduler.js";
import { dispatchCalendarEvents } from "../../src/services/meetingScheduler.js";

export default async function handler(
  req: IncomingMessage,
  res: ServerResponse
) {
  try {
    const [standup, calendar] = await Promise.all([
      dispatchDueUsers().catch((err) => {
        console.error("[cron/tick] standup dispatch error:", err);
        return { total: 0, triggered: [] as string[], error: err.message };
      }),
      dispatchCalendarEvents().catch((err) => {
        console.error("[cron/tick] calendar dispatch error:", err);
        return { scanned: 0, triggered: [], error: err.message };
      }),
    ]);
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ standup, calendar }));
  } catch (err: any) {
    console.error("[cron/tick] error:", err);
    res.statusCode = 500;
    res.end(JSON.stringify({ error: err.message }));
  }
}
