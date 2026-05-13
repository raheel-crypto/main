import type { App } from "@slack/bolt";
import { config } from "../config.js";
import { getUser, upsertUser } from "../db/queries.js";
import { startAuthorization } from "../services/salesforceAuth.js";
import { configModal, connectPrompt } from "./blocks.js";

export function registerCommands(app: App): void {
  app.command(/\/(standup|merlin)(?:_dev)?/, async ({ command, ack, respond, client }) => {
    await ack();
    const sub = (command.text || "").trim().split(/\s+/)[0];

    if (sub === "config") {
      await openConfigModal(app, command);
      return;
    }
    if (sub === "connect") {
      await ensureUserRow(command.user_id, command.team_id, app);
      const url = await startAuthorization(command.user_id);
      await client.chat.postMessage({
        channel: command.user_id,
        ...connectPrompt(url),
      });
      await respond({
        response_type: "ephemeral",
        text: "Sent you a DM with the connection link.",
      });
      return;
    }

    await ensureUserRow(command.user_id, command.team_id, app);

    await respond({
      response_type: "ephemeral",
      text: "Running your standup now…",
    });

    const res = await fetch(`${config.publicUrl}/api/standup/run`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-internal-secret": config.internalSecret,
      },
      body: JSON.stringify({ slackUserId: command.user_id }),
    });
    if (!res.ok) {
      const text = await res.text();
      await respond({
        response_type: "ephemeral",
        text: `Standup failed: ${text.slice(0, 200)}`,
      });
    }
  });
}

async function openConfigModal(app: App, command: { user_id: string; team_id: string; trigger_id: string }) {
  await ensureUserRow(command.user_id, command.team_id, app);
  const user = await getUser(command.user_id);
  await app.client.views.open({
    trigger_id: command.trigger_id,
    view: configModal({
      timezone: user?.timezone ?? config.defaultTimezone,
      hour: user?.preferredHour ?? config.defaultHour,
      minute: user?.preferredMinute ?? 0,
    }),
  });
}

async function ensureUserRow(
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
