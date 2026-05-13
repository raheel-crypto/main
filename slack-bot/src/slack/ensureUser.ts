import type { App } from "@slack/bolt";
import { config } from "../config.js";
import { getUser, upsertUser } from "../db/queries.js";

export async function ensureUserRow(
  slackUserId: string,
  slackTeamId: string,
  app: App
): Promise<void> {
  const existing = await getUser(slackUserId);
  if (existing) return;
  let email = "";
  try {
    const info = await app.client.users.info({ user: slackUserId });
    email = (info.user?.profile as any)?.email ?? "";
  } catch {}
  await upsertUser({
    slackUserId,
    slackTeamId,
    email,
    timezone: config.defaultTimezone,
    preferredHour: config.defaultHour,
    preferredMinute: 0,
  });
}
