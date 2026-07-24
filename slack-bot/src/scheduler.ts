import { DateTime } from "luxon";
import { config } from "./config.js";
import { getDueUsers } from "./db/queries.js";
import type { UserPrefs } from "./types.js";

const WINDOW_MINUTES = 5;

export function isDueNow(user: UserPrefs, now = DateTime.now()): boolean {
  if (!user.active) return false;
  const local = now.setZone(user.timezone);
  const todayIso = local.toISODate();
  if (user.lastRunDate && user.lastRunDate === todayIso) return false;
  const preferred = local.set({
    hour: user.preferredHour,
    minute: user.preferredMinute,
    second: 0,
    millisecond: 0,
  });
  const diffMin = local.diff(preferred, "minutes").minutes;
  return diffMin >= 0 && diffMin < WINDOW_MINUTES;
}

export async function dispatchDueUsers(): Promise<{
  total: number;
  triggered: string[];
}> {
  const users = await getDueUsers();
  const now = DateTime.now();
  const due = users.filter((u) => isDueNow(u, now));
  const triggered: string[] = [];

  for (const u of due) {
    try {
      const res = await fetch(`${config.publicUrl}/api/standup/run`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-internal-secret": config.internalSecret,
        },
        body: JSON.stringify({ slackUserId: u.slackUserId }),
      });
      if (res.ok) triggered.push(u.slackUserId);
      else console.error(`[cron] standup/run failed for ${u.slackUserId}: ${res.status}`);
    } catch (err: any) {
      console.error(`[cron] dispatch error for ${u.slackUserId}:`, err.message);
    }
  }

  return { total: users.length, triggered };
}
