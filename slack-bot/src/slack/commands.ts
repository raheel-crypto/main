import type { App } from "@slack/bolt";
import { WebClient } from "@slack/web-api";
import { waitUntil } from "@vercel/functions";
import { config } from "../config.js";
import {
  appendAudit,
  deleteChannelBinding,
  getChannelBinding,
  getUser,
  upsertChannelBinding,
} from "../db/queries.js";
import { findOpportunitiesByName } from "../services/sfReads.js";
import { runChannelSync } from "../services/channelSync.js";
import { startAuthorization } from "../services/salesforceAuth.js";
import {
  bindDisambiguationBlocks,
  channelBindStatusBlocks,
  configModal,
  connectPrompt,
  postBindPromptBlocks,
} from "./blocks.js";
import { ensureUserRow } from "./ensureUser.js";
import { subscriptionsModalView } from "./subscriptionsModal.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "../services/salesforceClient.js";

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

  registerMerlinDealCommand(app);
}

// ─── /merlin-deal — bind / unbind / status / sync ─────────────────────────

function registerMerlinDealCommand(app: App): void {
  app.command(/\/(merlin-deal)(?:_dev)?/, async ({ command, ack, respond }) => {
    await ack();
    const text = (command.text || "").trim();
    const parts = text.split(/\s+/).filter(Boolean);
    const sub = (parts[0] || "").toLowerCase();
    const arg = parts.slice(1).join(" ").trim();

    await ensureUserRow(command.user_id, command.team_id, app);

    if (sub === "bind") {
      await handleBind(app, command, respond, arg);
      return;
    }
    if (sub === "unbind") {
      await handleUnbind(command, respond);
      return;
    }
    if (sub === "status") {
      await handleStatus(command, respond);
      return;
    }
    if (sub === "sync") {
      await handleSync(app, command, respond);
      return;
    }

    await respond({
      response_type: "ephemeral",
      text:
        ":wave: `/merlin-deal` binds a Slack channel to a Salesforce Opportunity, then syncs channel chatter into SF.\n\n" +
        "*Subcommands:*\n" +
        "• `bind <opp name or 18-char id>` — link this channel to an opportunity\n" +
        "• `status` — show what this channel is bound to\n" +
        "• `sync` — pull recent history → DM the binder suggested SF updates\n" +
        "• `unbind` — remove the binding",
    });
  });
}

const SF_OPP_ID_PATTERN = /^006[a-zA-Z0-9]{12}([a-zA-Z0-9]{3})?$/;

async function handleBind(
  app: App,
  command: { user_id: string; team_id: string; channel_id: string },
  respond: (msg: any) => Promise<unknown>,
  oppRef: string
): Promise<void> {
  if (!oppRef) {
    await respond({
      response_type: "ephemeral",
      text: "Usage: `/merlin-deal bind <opportunity name>` (or paste an 18-char SF Id).",
    });
    return;
  }

  // SF connection from the binder's tokens.
  let conn;
  try {
    conn = await getConnectionForUser(command.user_id);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      const url = await startAuthorization(command.user_id);
      await app.client.chat.postMessage({
        channel: command.user_id,
        unfurl_links: false,
        unfurl_media: false,
        ...connectPrompt(url),
      });
      await respond({
        response_type: "ephemeral",
        text: ":lock: Connect Salesforce first — I just DM'd you the link.",
      });
      return;
    }
    throw err;
  }

  // Resolve the opp ref.
  let sfUserId: string | undefined;
  try {
    const ident: any = await conn.identity();
    sfUserId = ident?.user_id ?? undefined;
  } catch {
    // Fall through; org-wide search still works.
  }

  let matches: Awaited<ReturnType<typeof findOpportunitiesByName>>;
  if (SF_OPP_ID_PATTERN.test(oppRef)) {
    // Direct ID — fetch by name LIKE the ID since `findOpportunitiesByName`
    // uses `Name LIKE` rather than `Id = `. Easier: query by id directly.
    try {
      const q = await conn.query(
        `SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate, IsClosed, OwnerId, Owner.Name FROM Opportunity WHERE Id = '${oppRef}' LIMIT 1`
      );
      matches = (q.records as any[]).map((r) => ({
        id: r.Id,
        name: r.Name,
        accountId: r.AccountId,
        accountName: r.Account?.Name ?? "",
        stage: r.StageName,
        amount: r.Amount ?? null,
        closeDate: r.CloseDate ?? null,
        isClosed: !!r.IsClosed,
        ownerId: r.OwnerId,
        ownerName: r.Owner?.Name ?? null,
      }));
    } catch {
      matches = [];
    }
  } else {
    matches = await findOpportunitiesByName(conn, oppRef, sfUserId);
  }

  if (matches.length === 0) {
    await respond({
      response_type: "ephemeral",
      text: `:warning: No opportunity matches \`${oppRef}\`. Try a more specific name or paste the 18-char SF Id.`,
    });
    return;
  }

  if (matches.length > 1) {
    const card = bindDisambiguationBlocks(oppRef, matches, command.channel_id);
    await respond({
      response_type: "ephemeral",
      blocks: card.blocks,
      text: card.text,
    });
    return;
  }

  await completeBind(app, command, respond, matches[0]);
}

export async function completeBind(
  app: App,
  command: { user_id: string; team_id: string; channel_id: string },
  respond: (msg: any) => Promise<unknown>,
  match: {
    id: string;
    name: string;
    accountId: string | null;
    accountName: string;
  }
): Promise<void> {
  await upsertChannelBinding({
    slackChannelId: command.channel_id,
    slackTeamId: command.team_id,
    opportunityId: match.id,
    accountId: match.accountId,
    opportunityName: match.name,
    accountName: match.accountName,
    boundBySlackUserId: command.user_id,
  });
  await appendAudit({
    slackUserId: command.user_id,
    opportunityId: match.id,
    action: "channel_bound",
    metadata: {
      slackChannelId: command.channel_id,
      opportunityName: match.name,
      accountName: match.accountName,
    },
  });
  const card = postBindPromptBlocks(command.channel_id, match.name);
  await respond({
    response_type: "ephemeral",
    blocks: card.blocks,
    text: card.text,
  });
}

async function handleUnbind(
  command: { user_id: string; channel_id: string },
  respond: (msg: any) => Promise<unknown>
): Promise<void> {
  const binding = await getChannelBinding(command.channel_id);
  if (!binding) {
    await respond({
      response_type: "ephemeral",
      text: "This channel isn't bound to any opportunity.",
    });
    return;
  }
  await deleteChannelBinding(command.channel_id);
  await appendAudit({
    slackUserId: command.user_id,
    opportunityId: binding.opportunityId,
    action: "channel_unbound",
    metadata: { slackChannelId: command.channel_id },
  });
  await respond({
    response_type: "ephemeral",
    text: `:white_check_mark: Unbound from *${binding.opportunityName}*.`,
  });
}

async function handleStatus(
  command: { user_id: string; channel_id: string },
  respond: (msg: any) => Promise<unknown>
): Promise<void> {
  const binding = await getChannelBinding(command.channel_id);
  if (!binding) {
    await respond({
      response_type: "ephemeral",
      text: "This channel isn't bound to any opportunity. Use `/merlin-deal bind <opp name>` to link it.",
    });
    return;
  }
  // Best-effort instanceUrl for the SF link — pull from the binder's token row.
  let instanceUrl = "https://salesforce.com";
  try {
    const conn = await getConnectionForUser(binding.boundBySlackUserId);
    instanceUrl = conn.instanceUrl ?? instanceUrl;
  } catch {
    // Status works even without SF; we just lose the deep link.
  }
  const card = channelBindStatusBlocks({
    opportunityName: binding.opportunityName,
    accountName: binding.accountName,
    boundBySlackUserId: binding.boundBySlackUserId,
    lastSyncedAt: binding.lastSyncedAt,
    instanceUrl,
    opportunityId: binding.opportunityId,
  });
  await respond({
    response_type: "ephemeral",
    blocks: card.blocks,
    text: card.text,
  });
}

async function handleSync(
  app: App,
  command: { user_id: string; channel_id: string },
  respond: (msg: any) => Promise<unknown>
): Promise<void> {
  const binding = await getChannelBinding(command.channel_id);
  if (!binding) {
    await respond({
      response_type: "ephemeral",
      text: "This channel isn't bound yet. Run `/merlin-deal bind <opp name>` first.",
    });
    return;
  }
  await respond({
    response_type: "ephemeral",
    text: `:hourglass_flowing_sand: Pulling channel history and reconciling with *${binding.opportunityName}*. <@${binding.boundBySlackUserId}> will get a DM in 30-60s.`,
  });
  const slack = new WebClient(config.slack.botToken);
  const work = runChannelSync({
    slackChannelId: command.channel_id,
    triggeredBySlackUserId: command.user_id,
    slack,
  }).catch((err) => {
    console.error("[merlin-deal sync] failed:", err);
  });
  waitUntil(work);
}
