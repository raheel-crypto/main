import type { App } from "@slack/bolt";
import { waitUntil } from "@vercel/functions";
import { config } from "../config.js";
import { getUser } from "../db/queries.js";
import { startAuthorization } from "../services/salesforceAuth.js";
import { configModal, connectPrompt } from "./blocks.js";
import { ensureUserRow } from "./ensureUser.js";
import { subscriptionsModalView } from "./subscriptionsModal.js";

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

async function openSubscriptionsModal(
  app: App,
  command: { user_id: string; team_id: string; trigger_id: string }
) {
  await ensureUserRow(command.user_id, command.team_id, app);
  const user = await getUser(command.user_id);
  await app.client.views.open({
    trigger_id: command.trigger_id,
    view: subscriptionsModalView(user),
  });
}

export function registerCommands(app: App): void {
  app.command(
    /\/(subscriptions)(?:_dev)?/,
    async ({ command, ack }) => {
      await ack();
      await openSubscriptionsModal(app, command);
    }
  );

  app.command(/\/(standup|merlin)(?:_dev)?/, async ({ command, ack, respond, client }) => {
    await ack();
    const sub = (command.text || "").trim().split(/\s+/)[0];

    if (sub === "config") {
      await openConfigModal(app, command);
      return;
    }
    if (sub === "subscriptions") {
      await openSubscriptionsModal(app, command);
      return;
    }
    if (sub === "connect") {
      await ensureUserRow(command.user_id, command.team_id, app);
      const url = await startAuthorization(command.user_id);
      await client.chat.postMessage({
        channel: command.user_id,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      await respond({
        response_type: "ephemeral",
        text: "Sent you a DM with the connection link.",
      });
      return;
    }

    await ensureUserRow(command.user_id, command.team_id, app);

    const runPromise = fetch(`${config.publicUrl}/api/standup/run`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-internal-secret": config.internalSecret,
      },
      body: JSON.stringify({ slackUserId: command.user_id }),
    })
      .then(async (res) => {
        if (!res.ok) {
          const text = await res.text();
          console.error(`[slash] standup/run failed: ${res.status} ${text}`);
        }
      })
      .catch((err) => {
        console.error("[slash] standup/run fetch error:", err);
      });

    waitUntil(runPromise);

    await respond({
      response_type: "ephemeral",
      text: "Running your standup. You'll get a DM in 30-60 seconds.",
    });
  });
}
