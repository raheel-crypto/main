import type { App } from "@slack/bolt";
import { WebClient } from "@slack/web-api";
import { config } from "../config.js";
import {
  appendAudit,
  getGcTokens,
  getPendingCard,
  getUser,
  setCardStatus,
  updateSubscriptionPrefs,
  upsertUser,
} from "../db/queries.js";
import {
  CALENDAR_BLOCK_ID,
  CALENDAR_POST_VALUE,
  CALENDAR_PRE_VALUE,
  GONG_BLOCK_ID,
  GONG_FIREHOSE_VALUE,
  GONG_HOST_VALUE,
  NOOKS_BLOCK_ID,
  NOOKS_FIREHOSE_VALUE,
  NOOKS_HOST_VALUE,
  SUBSCRIPTIONS_CALLBACK_ID,
} from "./subscriptionsModal.js";
import {
  getConnectionForUser,
  SfNotConnectedError,
} from "../services/salesforceClient.js";
import {
  applyFields,
  applyRecordFields,
  createContact,
  createOpportunity,
  createTask,
} from "../services/sfWriter.js";
import { runBriefForUser } from "../services/brief.js";
import { runPreMeeting } from "../services/preMeeting.js";
import { fetchOpportunityStagePicklist } from "../services/sfReads.js";
import {
  briefSuggestionField,
  briefSuggestionResolved,
  buySignalCardResolved,
  buySignalCreateOppModal,
  buySignalLogTaskModal,
  cardWithFieldResolved,
  editFieldModal,
  editProposedFieldModal,
  parseActionId,
  postMeetingAddContactModal,
  postMeetingLogTaskModal,
  postMeetingUpdateOppModal,
} from "./blocks.js";
import type {
  BriefPendingCard,
  BriefSuggestion,
  BuySignalPendingCard,
  PendingCard,
  PostMeetingPendingCard,
  MeetingPickerPendingCard,
  ProposedField,
  RecommendedField,
  RecordProposalPendingCard,
} from "../types.js";

export function registerInteractivity(app: App): void {
  // URL-only buttons that link out to Salesforce/Gong/Nooks etc. still need
  // an action_id (or Slack auto-fills one) AND a 200 ack, otherwise the user
  // sees a "we couldn't process this action" grey warning even though the
  // browser tab opens fine. All such buttons use the `linkout:` prefix; this
  // handler just acks them.
  app.action(/^linkout:/, async ({ ack }) => {
    await ack();
  });

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
    if (card.kind === "record_proposal") {
      const field = card.recommendation.fields.find(
        (f) => f.field === parsed.field
      );
      if (!field) return;
      await client.views.open({
        trigger_id: (body as any).trigger_id,
        view: editProposedFieldModal({
          cardId: parsed.cardId,
          field,
        }),
      });
      return;
    }
    if (card.kind !== "standup" && card.kind !== "qa_proposal") return;
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

  app.view(/^edit_record_field:.+/, async ({ ack, body, view, client }) => {
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

  app.action(/^add_contact:.+/, async ({ ack, body, client }) => {
    await ack();
    const action = (body as any).actions?.[0];
    const parsed = parseActionId(action?.action_id ?? "");
    if (!parsed || !parsed.field) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "post_meeting") return;
    const idx = Number(parsed.field);
    const attendee = card.recommendation.unmatchedAttendees[idx];
    if (!attendee) return;
    const { firstName, lastName } = splitName(
      attendee.displayName ?? "",
      attendee.email
    );
    await client.views.open({
      trigger_id: (body as any).trigger_id,
      view: postMeetingAddContactModal(parsed.cardId, idx, {
        accountName: card.recommendation.accountName,
        email: attendee.email,
        firstName,
        lastName,
      }),
    });
  });

  app.action(/^update_meeting_opp:.+/, async ({ ack, body, client }) => {
    await ack();
    const action = (body as any).actions?.[0];
    const parsed = parseActionId(action?.action_id ?? "");
    if (!parsed || !parsed.field) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "post_meeting") return;
    const oppId = parsed.field;
    const opp = card.recommendation.openOpportunities.find((o) => o.id === oppId);
    if (!opp) return;
    let stageOptions: string[] = [];
    try {
      const conn = await getConnectionForUser(card.slackUserId);
      stageOptions = await fetchOpportunityStagePicklist(conn);
    } catch (err) {
      console.error("[post-meeting] stage picklist fetch failed:", err);
    }
    await client.views.open({
      trigger_id: (body as any).trigger_id,
      view: postMeetingUpdateOppModal(parsed.cardId, {
        opportunityId: opp.id,
        opportunityName: opp.name,
        currentStage: opp.stage,
        currentNextStep: opp.nextStep,
        currentCloseDate: opp.closeDate,
        stageOptions,
      }),
    });
  });

  app.action(/^log_meeting_task:.+/, async ({ ack, body, client }) => {
    await ack();
    const action = (body as any).actions?.[0];
    const parsed = parseActionId(action?.action_id ?? "");
    if (!parsed) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "post_meeting") return;
    const attendeeSummary = [
      card.recommendation.matchedContacts.length > 0
        ? "Attendees in SF: " +
          card.recommendation.matchedContacts
            .map((c) => c.name ?? c.email)
            .join(", ")
        : null,
      card.recommendation.unmatchedAttendees.length > 0
        ? "New attendees: " +
          card.recommendation.unmatchedAttendees
            .map((a) => `${a.displayName ?? a.email}`)
            .join(", ")
        : null,
    ]
      .filter(Boolean)
      .join("\n");
    const todayIso = new Date().toISOString().slice(0, 10);
    await client.views.open({
      trigger_id: (body as any).trigger_id,
      view: postMeetingLogTaskModal(parsed.cardId, {
        accountName: card.recommendation.accountName,
        eventTitle: card.recommendation.eventTitle,
        attendeeSummary,
        todayIso,
      }),
    });
  });

  app.action(/^post_meeting_skip:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "post_meeting") return;
    await setCardStatus(parsed.cardId, "skipped");
    await appendAudit({
      slackUserId: card.slackUserId,
      action: "skipped",
      metadata: { kind: "post_meeting", cardId: parsed.cardId },
    });
    await app.client.chat.update({
      channel: card.slackChannel,
      ts: card.slackMessageTs,
      text: `Post-meeting · ${card.recommendation.eventTitle} (dismissed)`,
      blocks: [
        {
          type: "context",
          elements: [
            {
              type: "mrkdwn",
              text: `:wastebasket: Dismissed post-meeting card for *${card.recommendation.accountName}*.`,
            },
          ],
        },
      ],
    });
  });

  app.action(/^meeting_pick_account:.+/, async ({ ack, body, action }) => {
    await ack();
    const parsed = parseActionId((action as any).action_id);
    if (!parsed || !parsed.field) return;
    const card = await getPendingCard(parsed.cardId);
    if (!card || card.kind !== "meeting_picker") return;
    const accountId = parsed.field;
    const candidate = card.recommendation.candidates.find((c) => c.id === accountId);
    if (!candidate) return;
    await setCardStatus(parsed.cardId, "applied");
    await app.client.chat.update({
      channel: card.slackChannel,
      ts: card.slackMessageTs,
      text: `Picked ${candidate.name} — researching brief…`,
      blocks: [
        {
          type: "context",
          elements: [
            {
              type: "mrkdwn",
              text: `:hourglass_flowing_sand: Researching brief for *${candidate.name}*…`,
            },
          ],
        },
      ],
    });
    try {
      await runPreMeeting({
        slackUserId: card.slackUserId,
        eventId: card.recommendation.gcalEventId,
        overrideAccount: { id: candidate.id, name: candidate.name },
      });
    } catch (err: any) {
      console.error("[meeting-pick-account] runPreMeeting failed:", err);
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        text: `:warning: I couldn't generate the brief for *${candidate.name}*: ${err.message}`,
      });
    }
  });

  app.view(/^add_contact:.+/, async ({ ack, body, view }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
      attendeeIndex: number;
    };
    const card = await getPendingCard(meta.cardId);
    if (!card || card.kind !== "post_meeting") return;
    const values = view.state.values;
    const firstName = (values["first_name_block"]?.["value"]?.value ?? "").trim();
    const lastName = (values["last_name_block"]?.["value"]?.value ?? "").trim();
    const email = (values["email_block"]?.["value"]?.value ?? "").trim();
    const title = (values["title_block"]?.["value"]?.value ?? "").trim() || null;
    if (!lastName || !email) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: `:warning: Couldn't add contact — last name and email are required.`,
      });
      return;
    }
    let conn;
    try {
      conn = await getConnectionForUser(card.slackUserId);
    } catch (err) {
      if (err instanceof SfNotConnectedError) {
        await app.client.chat.postMessage({
          channel: card.slackChannel,
          thread_ts: card.slackMessageTs,
          text: "Salesforce isn't connected. Run `/standup connect`.",
        });
        return;
      }
      throw err;
    }
    const result = await createContact({
      conn,
      slackUserId: card.slackUserId,
      accountId: card.recommendation.accountId,
      firstName,
      lastName,
      email,
      title,
    });
    if (result.ok) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: result.dryRun
          ? `:test_tube: (dry-run) Would have added *${firstName} ${lastName}* <${email}> to *${card.recommendation.accountName}*.`
          : `:white_check_mark: Added *${firstName} ${lastName}* <${email}> to *${card.recommendation.accountName}*.`,
      });
    } else {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: `:warning: Failed to add contact: ${result.error ?? "unknown error"}`,
      });
    }
  });

  app.view(/^update_meeting_opp:.+/, async ({ ack, body, view }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
      opportunityId: string;
      currentStage: string;
      currentNextStep: string | null;
      currentCloseDate: string | null;
    };
    const card = await getPendingCard(meta.cardId);
    if (!card || card.kind !== "post_meeting") return;

    const values = view.state.values;
    const stage =
      values["stage_block"]?.["value"]?.selected_option?.value ?? null;
    const nextStep = values["next_step_block"]?.["value"]?.value ?? null;
    const closeDate =
      values["close_date_block"]?.["value"]?.selected_date ?? null;

    const fields: { field: string; newValue: unknown; oldValue: unknown }[] = [];
    if (stage && stage !== meta.currentStage) {
      fields.push({ field: "StageName", newValue: stage, oldValue: meta.currentStage });
    }
    if (
      nextStep != null &&
      (nextStep || "").trim() !== (meta.currentNextStep ?? "").trim()
    ) {
      fields.push({
        field: "NextStep",
        newValue: nextStep || null,
        oldValue: meta.currentNextStep,
      });
    }
    if (
      closeDate &&
      closeDate.slice(0, 10) !== (meta.currentCloseDate ?? "").slice(0, 10)
    ) {
      fields.push({
        field: "CloseDate",
        newValue: closeDate,
        oldValue: meta.currentCloseDate,
      });
    }

    if (fields.length === 0) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: ":information_source: No changes to apply.",
      });
      return;
    }

    let conn;
    try {
      conn = await getConnectionForUser(card.slackUserId);
    } catch (err) {
      if (err instanceof SfNotConnectedError) {
        await app.client.chat.postMessage({
          channel: card.slackChannel,
          thread_ts: card.slackMessageTs,
          text: "Salesforce isn't connected. Run `/standup connect`.",
        });
        return;
      }
      throw err;
    }

    const results = await applyFields({
      conn,
      slackUserId: card.slackUserId,
      opportunityId: meta.opportunityId,
      fields,
    });
    const okFields = results.filter((r) => r.ok).map((r) => r.field);
    const failFields = results.filter((r) => !r.ok);
    const lines: string[] = [];
    if (okFields.length > 0) {
      lines.push(
        `:white_check_mark: Updated ${okFields.join(", ")} on *${
          card.recommendation.openOpportunities.find(
            (o) => o.id === meta.opportunityId
          )?.name ?? "opportunity"
        }*.`
      );
    }
    for (const f of failFields) {
      lines.push(`:warning: Failed to update ${f.field}: ${f.error ?? "unknown"}`);
    }
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackMessageTs,
      text: lines.join("\n"),
    });
  });

  app.view(/^log_meeting_task:.+/, async ({ ack, body, view }) => {
    await ack();
    const meta = JSON.parse(view.private_metadata || "{}") as {
      cardId: string;
    };
    const card = await getPendingCard(meta.cardId);
    if (!card || card.kind !== "post_meeting") return;
    const values = view.state.values;
    const subject = (values["subject_block"]?.["value"]?.value ?? "").trim();
    const dueDate = values["due_date_block"]?.["value"]?.selected_date ?? "";
    const description =
      (values["description_block"]?.["value"]?.value ?? null) || null;
    if (!subject || !dueDate) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: ":warning: Subject and date are required.",
      });
      return;
    }
    let conn;
    try {
      conn = await getConnectionForUser(card.slackUserId);
    } catch (err) {
      if (err instanceof SfNotConnectedError) {
        await app.client.chat.postMessage({
          channel: card.slackChannel,
          thread_ts: card.slackMessageTs,
          text: "Salesforce isn't connected. Run `/standup connect`.",
        });
        return;
      }
      throw err;
    }
    const ident = await conn.identity();
    const ownerId = (ident as any).user_id as string;
    const result = await createTask({
      conn,
      slackUserId: card.slackUserId,
      whatId: card.recommendation.accountId,
      ownerId,
      subject,
      dueDate,
      description,
    });
    if (result.ok) {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: result.dryRun
          ? `:test_tube: (dry-run) Would have logged task *${subject}* on *${card.recommendation.accountName}*.`
          : `:white_check_mark: Logged task *${subject}* on *${card.recommendation.accountName}* (due ${dueDate}).`,
      });
    } else {
      await app.client.chat.postMessage({
        channel: card.slackChannel,
        thread_ts: card.slackMessageTs,
        text: `:warning: Failed to log task: ${result.error ?? "unknown error"}`,
      });
    }
  });
}

function splitName(
  displayName: string,
  email: string
): { firstName: string; lastName: string } {
  const trimmed = displayName.trim();
  if (trimmed) {
    const parts = trimmed.split(/\s+/);
    if (parts.length === 1) return { firstName: "", lastName: parts[0] };
    return {
      firstName: parts[0],
      lastName: parts.slice(1).join(" "),
    };
  }
  const localPart = email.split("@")[0] ?? email;
  return { firstName: "", lastName: localPart };
}

async function handleAccept(
  app: App,
  body: any,
  cardId: string,
  field: string
): Promise<void> {
  const card = await getPendingCard(cardId);
  if (!card) return;
  if (card.kind === "record_proposal") {
    await handleAcceptRecord(app, body, card, field);
    return;
  }
  if (card.kind !== "standup" && card.kind !== "qa_proposal") return;
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
  if (card.kind === "record_proposal") {
    await handleSkipRecord(app, body, card, field);
    return;
  }
  if (card.kind !== "standup" && card.kind !== "qa_proposal") return;
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
  if (card.kind === "record_proposal") {
    await handleApplyAllRecord(app, body, card);
    return;
  }
  if (card.kind !== "standup" && card.kind !== "qa_proposal") return;
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
  if (card.kind === "record_proposal") {
    await handleEditRecordSubmit(app, body, card, field, newValue);
    return;
  }
  if (card.kind !== "standup" && card.kind !== "qa_proposal") return;
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

async function handleAcceptRecord(
  app: App,
  body: any,
  card: RecordProposalPendingCard,
  field: string
): Promise<void> {
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
    metadata: {
      cardKind: "record_proposal",
      sobjectType: card.recommendation.sobjectType,
      recordId: card.recommendation.recordId,
    },
  });
  await writeAndReplyRecord(app, body, card, [fieldRec], "accepted");
}

async function handleSkipRecord(
  app: App,
  body: any,
  card: RecordProposalPendingCard,
  field: string
): Promise<void> {
  const slackUserId = body.user.id as string;
  const fieldRec = card.recommendation.fields.find((f) => f.field === field);
  await appendAudit({
    slackUserId,
    opportunityId: card.opportunityId,
    fieldName: field,
    action: "skipped",
    oldValue: String(fieldRec?.currentValue ?? ""),
    newValue: String(fieldRec?.recommendedValue ?? ""),
    metadata: {
      cardKind: "record_proposal",
      sobjectType: card.recommendation.sobjectType,
      recordId: card.recommendation.recordId,
    },
  });
  const newBlocks = cardWithFieldResolved(body.message.blocks, field, "skipped");
  await app.client.chat.update({
    channel: body.channel.id,
    ts: body.message.ts,
    blocks: newBlocks,
    text: body.message.text || "Updated",
  });
}

async function handleApplyAllRecord(
  app: App,
  body: any,
  card: RecordProposalPendingCard
): Promise<void> {
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
      metadata: {
        cardKind: "record_proposal",
        sobjectType: card.recommendation.sobjectType,
        recordId: card.recommendation.recordId,
      },
    });
  }
  await writeAndReplyRecord(app, body, card, fields, "accepted");
}

async function handleEditRecordSubmit(
  app: App,
  body: any,
  card: RecordProposalPendingCard,
  field: string,
  newValue: unknown
): Promise<void> {
  const slackUserId = body.user.id as string;
  const fieldRec = card.recommendation.fields.find((f) => f.field === field);
  if (!fieldRec) return;

  const overridden: ProposedField = {
    ...fieldRec,
    recommendedValue: newValue as any,
    recommendedDisplay: newValue == null ? null : String(newValue),
  };

  await appendAudit({
    slackUserId,
    opportunityId: card.opportunityId,
    fieldName: field,
    action: "edited",
    oldValue: String(fieldRec.currentValue ?? ""),
    newValue: String(newValue ?? ""),
    metadata: {
      cardKind: "record_proposal",
      sobjectType: card.recommendation.sobjectType,
      recordId: card.recommendation.recordId,
    },
  });
  await writeAndReplyRecord(
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

async function writeAndReplyRecord(
  app: App,
  body: any,
  card: RecordProposalPendingCard,
  fields: ProposedField[],
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
  const results = await applyRecordFields({
    conn,
    slackUserId: card.slackUserId,
    sobjectType: card.recommendation.sobjectType,
    recordId: card.recommendation.recordId,
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
      f.recommendedDisplay ?? f.recommendedValue
    );
  }
  await app.client.chat.update({
    channel: card.slackChannel,
    ts: card.slackMessageTs,
    blocks,
    text: body.message.text || "Updated",
  });

  const failed = results.filter((r) => !r.ok);
  if (failed.length > 0) {
    await app.client.chat.postMessage({
      channel: card.slackChannel,
      thread_ts: card.slackMessageTs,
      text: failed
        .map((f) => `:warning: ${f.field}: ${f.error ?? "unknown error"}`)
        .join("\n"),
    });
  }
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

export function registerSubscriptionsSubmit(app: App): void {
  app.view(SUBSCRIPTIONS_CALLBACK_ID, async ({ ack, body, view }) => {
    await ack();
    const gongSelected =
      view.state.values[GONG_BLOCK_ID]?.["value"]?.selected_options ?? [];
    const nooksSelected =
      view.state.values[NOOKS_BLOCK_ID]?.["value"]?.selected_options ?? [];
    const calendarSelected =
      view.state.values[CALENDAR_BLOCK_ID]?.["value"]?.selected_options ?? [];
    const has = (
      arr: Array<{ value?: string }>,
      v: string
    ): boolean => arr.some((o) => o.value === v);
    const prefs = {
      gongRealtimeEnabled: has(gongSelected, GONG_HOST_VALUE),
      gongFirehoseEnabled: has(gongSelected, GONG_FIREHOSE_VALUE),
      nooksRealtimeEnabled: has(nooksSelected, NOOKS_HOST_VALUE),
      nooksFirehoseEnabled: has(nooksSelected, NOOKS_FIREHOSE_VALUE),
      calendarPreEnabled: has(calendarSelected, CALENDAR_PRE_VALUE),
      calendarPostEnabled: has(calendarSelected, CALENDAR_POST_VALUE),
    };
    await updateSubscriptionPrefs(body.user.id, prefs);

    const onOff = (b: boolean) => (b ? "on" : "off");
    const summary = `Saved.  Gong host: *${onOff(prefs.gongRealtimeEnabled)}* · Gong firehose: *${onOff(
      prefs.gongFirehoseEnabled
    )}* · Nooks host: *${onOff(prefs.nooksRealtimeEnabled)}* · Nooks firehose: *${onOff(
      prefs.nooksFirehoseEnabled
    )}* · Calendar pre: *${onOff(prefs.calendarPreEnabled)}* · Calendar post: *${onOff(
      prefs.calendarPostEnabled
    )}*.`;

    let text = summary;
    if (prefs.calendarPreEnabled || prefs.calendarPostEnabled) {
      const gc = await getGcTokens(body.user.id);
      if (!gc) {
        const connectUrl = `${config.publicUrl}/api/oauth/google/start?slack_user_id=${encodeURIComponent(
          body.user.id
        )}`;
        text += `\n\n:warning: Calendar briefs require Google Calendar access. <${connectUrl}|Connect Google Calendar> (one tap).`;
      }
    }
    await app.client.chat.postEphemeral({
      channel: body.user.id,
      user: body.user.id,
      text,
    });
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
