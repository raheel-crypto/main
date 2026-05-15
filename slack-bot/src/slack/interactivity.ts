import type { App } from "@slack/bolt";
import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getPendingCard,
  getUser,
  setCardStatus,
  upsertUser,
} from "../db/queries.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "../services/salesforceClient.js";
import {
  applyFields,
  createOpportunity,
  createTask,
} from "../services/sfWriter.js";
import { runBriefForUser } from "../services/brief.js";
import {
  briefSuggestionField,
  briefSuggestionResolved,
  buySignalCardResolved,
  buySignalCreateOppModal,
  buySignalLogTaskModal,
  cardWithFieldResolved,
  editFieldModal,
  parseActionId,
} from "./blocks.js";
import type {
  BriefPendingCard,
  BriefSuggestion,
  BuySignalPendingCard,
  PendingCard,
  RecommendedField,
} from "../types.js";

export function registerInteractivity(app: App): void {
  app.action(/^accept:.+/, async ({ ack, body, action, client }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    await handleAccept(app, body, parsed.cardId, parsed.field);
  });

  app.action(/^skip:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    await handleSkip(app, body, parsed.cardId, parsed.field);
  });

  app.action(/^edit:.+/, async ({ ack, body, action, client }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "standup") return;
    const fieldRec = card.recommendation.fields.find(
      (f) => f.field === parsed.field
    );
    if (!fieldRec) return;
    const triggerId = (body as any).trigger_id;
    await client.views.open({
      trigger_id: triggerId,
      view: editFieldModal({
        cardId: parsed.cardId,
        field: parsed.field,
        recommendedValue: fieldRec.recommendedValue,
      }),
    });
  });

  app.action(/^apply_all:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed) return;
    await handleApplyAll(app, body, parsed.cardId);
  });

  app.action(/^brief_apply:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    const idx = parseInt(parsed.field, 10);
    if (!Number.isFinite(idx)) return;
    await handleBriefApply(app, body, parsed.cardId, idx);
  });

  app.action(/^brief_skip:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    const idx = parseInt(parsed.field, 10);
    if (!Number.isFinite(idx)) return;
    await handleBriefSkip(app, body, parsed.cardId, idx);
  });

  app.action(/^brief_apply_all:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed) return;
    await handleBriefApplyAll(app, body, parsed.cardId);
  });

  app.action(/^brief_pick_account:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed) return;
    const accountName = ((action as any).value as string | undefined) ?? "";
    if (!accountName) return;
    await handleBriefPickAccount(body, accountName);
  });

  app.view(/^edit_field:.+/, async ({ ack, body, view, client }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
      field: string;
    };
    const valueState =
      view.state.values["value_block"]?.["value"] ?? ({} as any);
    const newValue =
      valueState.value ??
      valueState.selected_option?.value ??
      valueState.selected_date ??
      valueState.selected_time ??
      "";
    await handleEditSubmit(app, body, meta.cardId, meta.field, newValue);
  });

  app.action(/^buy_signal_create_opp:.+/, async ({ ack, body, client }) => {
    await ack();
    const action = (body as any).actions?.[0];
    const parsed = parseActionId(action?.action_id ?? "");
    if (!parsed) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "buy_signal") return;
    if (!card.recommendation.suggestedOpp) return;
    await client.views.open({
      trigger_id: (body as any).trigger_id,
      view: buySignalCreateOppModal(parsed.cardId, card.recommendation),
    });
  });

  app.action(/^buy_signal_log_task:.+/, async ({ ack, body, client }) => {
    await ack();
    const action = (body as any).actions?.[0];
    const parsed = parseActionId(action?.action_id ?? "");
    if (!parsed) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "buy_signal") return;
    if (!card.recommendation.suggestedTask) return;
    await client.views.open({
      trigger_id: (body as any).trigger_id,
      view: buySignalLogTaskModal(parsed.cardId, card.recommendation),
    });
  });

  app.action(/^buy_signal_skip:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed) return;
    await handleBuySignalSkip(app, body, parsed.cardId);
  });

  app.view(/^buy_signal_create_opp:.+/, async ({ ack, body, view }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
    };
    const values = view.state.values;
    const name = values["name_block"]?.["value"]?.value ?? "";
    const stage = values["stage_block"]?.["value"]?.value ?? "";
    const amountStr = values["amount_block"]?.["value"]?.value ?? "";
    const closeDate = values["close_date_block"]?.["value"]?.selected_date ?? "";
    const amount = amountStr ? Number(amountStr) : null;
    await handleBuySignalCreateOppSubmit(app, body, meta.cardId, {
      name,
      stage,
      amount: amount != null && Number.isFinite(amount) ? amount : null,
      closeDate,
    });
  });

  app.view(/^buy_signal_log_task:.+/, async ({ ack, body, view }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
    };
    const values = view.state.values;
    const subject = values["subject_block"]?.["value"]?.value ?? "";
    const dueDate = values["due_date_block"]?.["value"]?.selected_date ?? "";
    const description =
      values["description_block"]?.["value"]?.value ?? null;
    await handleBuySignalLogTaskSubmit(app, body, meta.cardId, {
      subject,
      dueDate,
      description: description || null,
    });
  });
}

async function handleAccept(
  app: App,
  body: any,
  cardId: string,
  field: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "standup") return;
  const slackUserId = body.user.id as string;
  const fieldRec = card.recommendation.fields.find((f) => f.field === field);
  if (!fieldRec) return;

  await appendAudit({
    slackUserId,
    opportunityId: card.opportunityId,
    fieldName: field,
    action: "accepted",
    oldValue: String(fieldRec.currentValue ?? ""),
    newValue: String(fieldRec.recommendedValue ?? ""),
  });

  await writeAndReply(app, body, card, [fieldRec], "accepted");
}

async function handleSkip(
  app: App,
  body: any,
  cardId: string,
  field: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "standup") return;
  const slackUserId = body.user.id as string;
  const fieldRec = card.recommendation.fields.find((f) => f.field === field);
  await appendAudit({
    slackUserId,
    opportunityId: card.opportunityId,
    fieldName: field,
    action: "skipped",
    oldValue: String(fieldRec?.currentValue ?? ""),
    newValue: String(fieldRec?.recommendedValue ?? ""),
  });

  const newBlocks = cardWithFieldResolved(body.message.blocks, field, "skipped");
  await app.client.chat.update({
    channel: body.channel.id,
    ts: body.message.ts,
    blocks: newBlocks,
    text: body.message.text || "Updated",
  });
}

async function handleApplyAll(app: App, body: any, cardId: string): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "standup") return;
  const slackUserId = body.user.id as string;
  const fields = card.recommendation.fields;
  if (fields.length === 0) return;
  for (const f of fields) {
    await appendAudit({
      slackUserId,
      opportunityId: card.opportunityId,
      fieldName: f.field,
      action: "accepted",
      oldValue: String(f.currentValue ?? ""),
      newValue: String(f.recommendedValue ?? ""),
    });
  }
  await writeAndReply(app, body, card, fields, "accepted");
}

async function handleEditSubmit(
  app: App,
  body: any,
  cardId: string,
  field: string,
  newValue: unknown
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "standup") return;
  const slackUserId = body.user.id as string;
  const fieldRec = card.recommendation.fields.find((f) => f.field === field);
  if (!fieldRec) return;

  const overridden: RecommendedField = {
    ...fieldRec,
    recommendedValue: newValue as any,
  };

  await appendAudit({
    slackUserId,
    opportunityId: card.opportunityId,
    fieldName: field,
    action: "edited",
    oldValue: String(fieldRec.currentValue ?? ""),
    newValue: String(newValue ?? ""),
  });

  await writeAndReply(
    app,
    {
      user: body.user,
      channel: { id: card.slackChannel },
      message: { ts: card.slackMessageTs, blocks: undefined, text: "Updated" },
    },
    card,
    [overridden],
    "edited"
  );
}

async function writeAndReply(
  app: App,
  body: any,
  card: { id: string; opportunityId: string; slackChannel: string; slackMessageTs: string; slackUserId: string },
  fields: RecommendedField[],
  uiStatus: "accepted" | "edited" | "skipped"
): Promise<void> {
  let conn;
  try {
    conn = await getConnectionForUser(card.slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await app.client.chat.postEphemeral({
        channel: body.channel.id,
        user: body.user.id,
        text: "Salesforce isn't connected. Run `/standup connect`.",
      });
    }
    return;
  }
  const results = await applyFields({
    conn,
    slackUserId: card.slackUserId,
    opportunityId: card.opportunityId,
    fields: fields.map((f) => ({
      field: f.field,
      newValue: f.recommendedValue,
      oldValue: f.currentValue,
    })),
  });

  let blocks = body.message.blocks;
  if (!blocks) {
    const fresh = await app.client.conversations.history({
      channel: card.slackChannel,
      latest: card.slackMessageTs,
      inclusive: true,
      limit: 1,
    });
    blocks = (fresh.messages as any[])?.[0]?.blocks ?? [];
  }
  for (const f of fields) {
    const ok = results.find((r) => r.field === f.field)?.ok;
    blocks = cardWithFieldResolved(
      blocks,
      f.field,
      ok ? uiStatus : "skipped",
      ok ? f.recommendedValue : undefined
    );
  }

  await app.client.chat.update({
    channel: card.slackChannel,
    ts: card.slackMessageTs,
    blocks,
    text: "Updated",
  });

}

async function handleBriefApply(
  app: App,
  body: any,
  cardId: string,
  index: number
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "brief") return;
  const suggestion = card.recommendation.suggestedActions[index];
  if (!suggestion) return;
  await applyBriefSuggestion(app, body, card, [index], [suggestion]);
}

async function handleBriefSkip(
  app: App,
  body: any,
  cardId: string,
  index: number
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "brief") return;
  const suggestion = card.recommendation.suggestedActions[index];
  const slackUserId = body.user.id as string;
  await appendAudit({
    slackUserId,
    opportunityId: suggestion?.opportunityId,
    fieldName: suggestion ? briefSuggestionField(suggestion.kind) : undefined,
    action: "skipped",
    newValue: suggestion ? String(suggestion.value ?? "") : null,
    metadata: { briefCardId: cardId, suggestionIndex: index },
  });
  const blocks = briefSuggestionResolved(body.message?.blocks, index, "skipped");
  await app.client.chat.update({
    channel: body.channel.id,
    ts: body.message.ts,
    blocks,
    text: body.message.text || "Updated",
  });
}

async function handleBriefApplyAll(
  app: App,
  body: any,
  cardId: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "brief") return;
  const suggestions = card.recommendation.suggestedActions;
  if (suggestions.length === 0) return;
  const indexes = suggestions.map((_, i) => i);
  await applyBriefSuggestion(app, body, card, indexes, suggestions);
}

async function applyBriefSuggestion(
  app: App,
  body: any,
  card: BriefPendingCard,
  indexes: number[],
  suggestions: BriefSuggestion[]
): Promise<void> {
  const slackUserId = body.user.id as string;
  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await app.client.chat.postEphemeral({
        channel: body.channel.id,
        user: slackUserId,
        text: "Salesforce isn't connected. Run `/merlin connect`.",
      });
    }
    return;
  }

  const byOpp = new Map<
    string,
    { field: string; newValue: unknown; oldValue: unknown }[]
  >();
  const indexByField = new Map<string, number>();
  for (let i = 0; i < indexes.length; i++) {
    const idx = indexes[i];
    const s = suggestions[i];
    const field = briefSuggestionField(s.kind);
    const opp = card.recommendation.openOpportunities.find(
      (o) => o.id === s.opportunityId
    );
    const oldValue =
      field === "StageName"
        ? opp?.stage
        : field === "CloseDate"
          ? opp?.closeDate
          : field === "Amount"
            ? opp?.amount
            : null;
    const arr = byOpp.get(s.opportunityId) ?? [];
    arr.push({ field, newValue: s.value, oldValue: oldValue ?? null });
    byOpp.set(s.opportunityId, arr);
    indexByField.set(`${s.opportunityId}:${field}`, idx);
  }

  let blocks = body.message?.blocks;
  if (!blocks) {
    const fresh = await app.client.conversations.history({
      channel: card.slackChannel,
      latest: card.slackMessageTs,
      inclusive: true,
      limit: 1,
    });
    blocks = (fresh.messages as any[])?.[0]?.blocks ?? [];
  }

  for (const [oppId, fields] of byOpp) {
    const results = await applyFields({
      conn,
      slackUserId,
      opportunityId: oppId,
      fields,
    });
    for (const r of results) {
      const idx = indexByField.get(`${oppId}:${r.field}`);
      if (idx === undefined) continue;
      blocks = briefSuggestionResolved(
        blocks,
        idx,
        r.ok ? "applied" : "skipped",
        r.ok ? undefined : r.error
      );
    }
  }

  await app.client.chat.update({
    channel: card.slackChannel,
    ts: card.slackMessageTs,
    blocks,
    text: "Brief updated",
  });
}

async function handleBriefPickAccount(
  body: any,
  accountName: string
): Promise<void> {
  const slackUserId = body.user.id as string;
  const channelId = body.channel?.id as string;
  if (!channelId) return;
  const slack = new WebClient(config.slack.botToken);
  await runBriefForUser({
    slackUserId,
    channelId,
    accountQuery: accountName,
    slack,
  });
}

async function getBuySignalCardBlocks(
  app: App,
  card: BuySignalPendingCard,
  body: any
): Promise<any[]> {
  let blocks = body.message?.blocks;
  if (!blocks) {
    const fresh = await app.client.conversations.history({
      channel: card.slackChannel,
      latest: card.slackMessageTs,
      inclusive: true,
      limit: 1,
    });
    blocks = (fresh.messages as any[])?.[0]?.blocks ?? [];
  }
  return blocks ?? [];
}

async function handleBuySignalSkip(
  app: App,
  body: any,
  cardId: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "buy_signal") return;
  const slackUserId = body.user.id as string;
  await appendAudit({
    slackUserId,
    action: "skipped",
    metadata: {
      cardKind: "buy_signal",
      cardId,
      accountId: card.recommendation.accountId,
    },
  });
  await setCardStatus(cardId, "skipped");
  const newBlocks = buySignalCardResolved(
    body.message?.blocks,
    "skipped"
  );
  await app.client.chat.update({
    channel: body.channel.id,
    ts: body.message.ts,
    blocks: newBlocks,
    text: body.message.text || "Skipped",
  });
}

async function handleBuySignalCreateOppSubmit(
  app: App,
  body: any,
  cardId: string,
  input: { name: string; stage: string; amount: number | null; closeDate: string }
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "buy_signal") return;
  const slackUserId = body.user.id as string;
  if (!input.name || !input.stage || !input.closeDate) return;

  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackThreadTs,
        text: "Salesforce isn't connected. Run `/standup connect`.",
      });
    }
    return;
  }

  const result = await createOpportunity({
    conn,
    slackUserId,
    accountId: card.recommendation.accountId,
    name: input.name,
    stage: input.stage,
    amount: input.amount,
    closeDate: input.closeDate,
  });

  const blocks = await getBuySignalCardBlocks(app, card, body);
  if (result.ok) {
    const url = result.opportunityId
      ? `${conn.instanceUrl}/${result.opportunityId}`
      : null;
    const detail = url ? `<${url}|${input.name}>` : input.name;
    const updated = buySignalCardResolved(blocks, "applied_opp", detail);
    await app.client.chat.update({
      channel: card.slackChannel,
      ts: card.slackMessageTs,
      blocks: updated,
      text: `Opportunity created: ${input.name}`,
    });
    await setCardStatus(cardId, "applied");
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackThreadTs,
      text: result.dryRun
        ? `:test_tube: (dry-run) Would have created Opp *${input.name}* on *${card.recommendation.accountName}*.`
        : `:white_check_mark: Opportunity created → ${detail}`,
    });
  } else {
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackThreadTs,
      text: `:warning: Failed to create opportunity: ${result.error ?? "unknown error"}`,
    });
  }
}

async function handleBuySignalLogTaskSubmit(
  app: App,
  body: any,
  cardId: string,
  input: { subject: string; dueDate: string; description: string | null }
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card || card.kind !== "buy_signal") return;
  const slackUserId = body.user.id as string;
  if (!input.subject || !input.dueDate) return;

  let conn;
  try {
    conn = await getConnectionForUser(slackUserId);
  } catch (err) {
    if (err instanceof SfNotConnectedError) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackThreadTs,
        text: "Salesforce isn't connected. Run `/standup connect`.",
      });
    }
    return;
  }

  let ownerId: string | null = null;
  try {
    const ident = await conn.identity();
    ownerId = (ident as any).user_id ?? null;
  } catch {}
  if (!ownerId) {
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackThreadTs,
      text: ":warning: Could not resolve your Salesforce user — task not created.",
    });
    return;
  }

  const result = await createTask({
    conn,
    slackUserId,
    whatId: card.recommendation.accountId,
    ownerId,
    subject: input.subject,
    dueDate: input.dueDate,
    description: input.description,
  });

  const blocks = await getBuySignalCardBlocks(app, card, body);
  if (result.ok) {
    const updated = buySignalCardResolved(
      blocks,
      "applied_task",
      `\`${input.subject}\` due ${input.dueDate}`
    );
    await app.client.chat.update({
      channel: card.slackChannel,
      ts: card.slackMessageTs,
      blocks: updated,
      text: `Task logged: ${input.subject}`,
    });
    await setCardStatus(cardId, "applied");
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackThreadTs,
      text: result.dryRun
        ? `:test_tube: (dry-run) Would have logged task *${input.subject}* on *${card.recommendation.accountName}*.`
        : `:white_check_mark: Task logged: *${input.subject}* (due ${input.dueDate}).`,
    });
  } else {
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackThreadTs,
      text: `:warning: Failed to log task: ${result.error ?? "unknown error"}`,
    });
  }
}

export async function saveUserPrefs(args: {
  slackUserId: string;
  slackTeamId: string;
  email: string;
  timezone: string;
  hour: number;
  minute: number;
}): Promise<void> {
  await upsertUser({
    slackUserId: args.slackUserId,
    slackTeamId: args.slackTeamId,
    email: args.email,
    timezone: args.timezone,
    preferredHour: args.hour,
    preferredMinute: args.minute,
  });
}

export function registerConfigSubmit(app: App): void {
  app.view("standup_config", async ({ ack, body, view }) => {
    await ack();
    const tz =
      view.state.values["timezone_block"]?.["value"]?.selected_option?.value ??
      "America/Los_Angeles";
    const time =
      view.state.values["time_block"]?.["value"]?.selected_time ?? "16:00";
    const [hStr, mStr] = time.split(":");
    const user = await getUser(body.user.id);
    let email = user?.email ?? "";
    if (!email) {
      try {
        const info = await app.client.users.info({ user: body.user.id });
        email = (info.user?.profile as any)?.email ?? "";
      } catch {}
    }
    await saveUserPrefs({
      slackUserId: body.user.id,
      slackTeamId: body.team?.id ?? "",
      email,
      timezone: tz,
      hour: parseInt(hStr, 10),
      minute: parseInt(mStr, 10),
    });
    await app.client.chat.postEphemeral({
      channel: body.user.id,
      user: body.user.id,
      text: `Saved. Daily standup will arrive at ~${time} ${tz}.`,
    });
  });
}
