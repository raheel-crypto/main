import type { App } from "@slack/bolt";
import {
  appendAudit,
  getPendingCard,
  getUser,
  upsertUser,
} from "../db/queries.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "../services/salesforceClient.js";
import { applyFields } from "../services/sfWriter.js";
import {
  cardWithFieldResolved,
  editFieldModal,
  parseActionId,
} from "./blocks.js";
import type { RecommendedField } from "../types.js";

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
    if (!card) return;
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
}

async function handleAccept(
  app: App,
  body: any,
  cardId: string,
  field: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card) return;
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
  if (!card) return;
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
  if (!card) return;
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
  if (!card) return;
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
