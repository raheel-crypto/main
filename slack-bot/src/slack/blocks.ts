import type { KnownBlock, View } from "@slack/types";
import { TZ_OPTIONS } from "../constants.js";
import type {
  BriefPayload,
  BriefSuggestion,
  BulkRecordUpdateProposal,
  BuySignalPayload,
  FeedbackSurface,
  GongCallInsight,
  GongWebhookPayload,
  MeetingPickerCandidate,
  NextMovesPayload,
  NooksWebhookPayload,
  PostMeetingPayload,
  ProposedField,
  Recommendation,
  RecommendedField,
  RecordUpdateProposal,
  SfApplyError,
} from "../types.js";

export type ActionVerb =
  | "accept"
  | "edit"
  | "skip"
  | "apply_all"
  | "brief_apply"
  | "brief_skip"
  | "brief_apply_all"
  | "brief_pick_account"
  | "buy_signal_create_opp"
  | "buy_signal_log_task"
  | "buy_signal_skip"
  | "add_contact"
  | "update_meeting_opp"
  | "log_meeting_task"
  | "post_meeting_skip"
  | "meeting_pick_account"
  | "bulk_exclude"
  | "bulk_apply"
  | "bulk_confirm"
  | "bulk_cancel"
  | "next_moves_accept"
  | "next_moves_skip"
  | "feedback_helpful"
  | "feedback_not_helpful";

const VALID_VERBS: ActionVerb[] = [
  "accept",
  "edit",
  "skip",
  "apply_all",
  "brief_apply",
  "brief_skip",
  "brief_apply_all",
  "brief_pick_account",
  "buy_signal_create_opp",
  "buy_signal_log_task",
  "buy_signal_skip",
  "add_contact",
  "update_meeting_opp",
  "log_meeting_task",
  "post_meeting_skip",
  "meeting_pick_account",
  "bulk_exclude",
  "bulk_apply",
  "bulk_confirm",
  "bulk_cancel",
  "next_moves_accept",
  "next_moves_skip",
  "feedback_helpful",
  "feedback_not_helpful",
];

export function actionId(
  verb: ActionVerb,
  cardId: string,
  field?: string
): string {
  return field ? `${verb}:${cardId}:${field}` : `${verb}:${cardId}`;
}

export function parseActionId(id: string): {
  verb: ActionVerb;
  cardId: string;
  field?: string;
} | null {
  const parts = id.split(":");
  if (parts.length < 2) return null;
  const verb = parts[0] as ActionVerb;
  if (!VALID_VERBS.includes(verb)) return null;
  return { verb, cardId: parts[1], field: parts.slice(2).join(":") || undefined };
}

export function threadParent(args: {
  oppCount: number;
  callCount: number;
  activityCount: number;
}): { blocks: KnownBlock[]; text: string } {
  const summary = `*Daily standup* — ${args.oppCount} opps to review (${args.callCount} calls, ${args.activityCount} recent activities).`;
  const blocks: KnownBlock[] = [
    { type: "section", text: { type: "mrkdwn", text: summary } },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: "Each card below shows recommended field updates. Accept, Edit, or Skip each one.",
        },
      ],
    },
  ];
  return { blocks, text: summary };
}

export function oppCard(
  cardId: string,
  rec: Recommendation,
  opp: { name: string; accountName: string; instanceUrl: string }
): { blocks: KnownBlock[]; text: string } {
  const oppUrl = `${opp.instanceUrl}/${rec.opportunityId}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: { type: "plain_text", text: opp.name.slice(0, 150) },
    },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: opp.accountName }],
    },
    { type: "section", text: { type: "mrkdwn", text: rec.recap } },
    {
      type: "actions",
      elements: [
        {
          type: "button",
          action_id: `linkout:open_in_sf:${rec.opportunityId}`,
          text: { type: "plain_text", text: "Open in Salesforce" },
          url: oppUrl,
        },
      ],
    },
  ];

  if (rec.fields.length === 0) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: "_No field changes recommended._" }],
    });
    return { blocks, text: `${opp.name} — ${rec.recap}` };
  }

  for (const f of rec.fields) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `*${f.field}*\n` +
          `Current: \`${formatValue(f.currentValue)}\`\n` +
          `Recommended: \`${formatValue(f.recommendedValue)}\`\n` +
          `_${f.rationale}_`,
      },
    });
    blocks.push({
      type: "actions",
      block_id: `field:${f.field}`,
      elements: [
        {
          type: "button",
          style: "primary",
          text: { type: "plain_text", text: "Accept" },
          action_id: actionId("accept", cardId, f.field),
          value: f.field,
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Edit" },
          action_id: actionId("edit", cardId, f.field),
          value: f.field,
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Skip" },
          action_id: actionId("skip", cardId, f.field),
          value: f.field,
        },
      ],
    });
  }

  blocks.push({ type: "divider" });
  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        style: "primary",
        text: { type: "plain_text", text: "Apply all recommended" },
        action_id: actionId("apply_all", cardId),
      },
    ],
  });

  return { blocks, text: `${opp.name} — ${rec.recap}` };
}

function formatProposedValue(f: ProposedField, side: "current" | "recommended"): string {
  const display =
    side === "current" ? f.currentDisplay : f.recommendedDisplay;
  const value = side === "current" ? f.currentValue : f.recommendedValue;
  if (display != null) return display.length > 80 ? display.slice(0, 77) + "…" : display;
  if (value === null || value === undefined) return "(none)";
  const s = typeof value === "boolean" ? (value ? "true" : "false") : String(value);
  return s.length > 80 ? s.slice(0, 77) + "…" : s;
}

export function recordCard(
  cardId: string,
  proposal: RecordUpdateProposal,
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const recordUrl = `${instanceUrl}/${proposal.recordId}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: { type: "plain_text", text: proposal.recordName.slice(0, 150) },
    },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: proposal.contextLabel }],
    },
    { type: "section", text: { type: "mrkdwn", text: proposal.recap } },
    {
      type: "actions",
      elements: [
        {
          type: "button",
          action_id: `linkout:open_in_sf:${proposal.recordId}`,
          text: { type: "plain_text", text: "Open in Salesforce" },
          url: recordUrl,
        },
      ],
    },
  ];

  if (proposal.fields.length === 0) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: "_No field changes proposed._" }],
    });
    return {
      blocks,
      text: `${proposal.recordName} — ${proposal.recap}`,
    };
  }

  for (const f of proposal.fields) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `*${f.fieldLabel}* (\`${f.field}\`)\n` +
          `Current: \`${formatProposedValue(f, "current")}\`\n` +
          `Recommended: \`${formatProposedValue(f, "recommended")}\`\n` +
          `_${f.rationale}_`,
      },
    });
    blocks.push({
      type: "actions",
      block_id: `field:${f.field}`,
      elements: [
        {
          type: "button",
          style: "primary",
          text: { type: "plain_text", text: "Accept" },
          action_id: actionId("accept", cardId, f.field),
          value: f.field,
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Edit" },
          action_id: actionId("edit", cardId, f.field),
          value: f.field,
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Skip" },
          action_id: actionId("skip", cardId, f.field),
          value: f.field,
        },
      ],
    });
  }

  blocks.push({ type: "divider" });
  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        style: "primary",
        text: { type: "plain_text", text: "Apply all recommended" },
        action_id: actionId("apply_all", cardId),
      },
    ],
  });

  return {
    blocks,
    text: `${proposal.recordName} — ${proposal.recap}`,
  };
}

export function editProposedFieldModal(args: {
  cardId: string;
  field: ProposedField;
}): View {
  const { cardId, field } = args;
  const initial =
    field.recommendedDisplay ??
    (field.recommendedValue == null
      ? ""
      : typeof field.recommendedValue === "boolean"
        ? field.recommendedValue
          ? "true"
          : "false"
        : String(field.recommendedValue));

  let input: any;
  if (
    field.fieldType === "picklist" &&
    field.picklistValues &&
    field.picklistValues.length > 0
  ) {
    input = {
      type: "static_select",
      action_id: "value",
      initial_option: field.picklistValues.includes(initial)
        ? { text: { type: "plain_text", text: initial.slice(0, 75) }, value: initial }
        : undefined,
      options: field.picklistValues.map((p) => ({
        text: { type: "plain_text", text: p.slice(0, 75) },
        value: p,
      })),
    };
  } else if (field.fieldType === "date") {
    input = {
      type: "datepicker",
      action_id: "value",
      initial_date: /^\d{4}-\d{2}-\d{2}/.test(initial)
        ? initial.slice(0, 10)
        : undefined,
    };
  } else if (
    field.fieldType === "currency" ||
    field.fieldType === "double" ||
    field.fieldType === "int" ||
    field.fieldType === "percent"
  ) {
    input = {
      type: "number_input",
      action_id: "value",
      is_decimal_allowed: field.fieldType !== "int",
      initial_value: initial,
    };
  } else if (field.fieldType === "boolean") {
    input = {
      type: "static_select",
      action_id: "value",
      initial_option:
        initial === "true" || initial === "false"
          ? { text: { type: "plain_text", text: initial }, value: initial }
          : undefined,
      options: [
        { text: { type: "plain_text", text: "true" }, value: "true" },
        { text: { type: "plain_text", text: "false" }, value: "false" },
      ],
    };
  } else if (
    field.fieldType === "textarea" ||
    (typeof initial === "string" && initial.length > 60)
  ) {
    input = {
      type: "plain_text_input",
      action_id: "value",
      multiline: true,
      initial_value: initial.slice(0, 3000),
    };
  } else {
    input = {
      type: "plain_text_input",
      action_id: "value",
      initial_value: initial.slice(0, 3000),
    };
  }

  return {
    type: "modal",
    callback_id: `edit_record_field:${cardId}:${field.field}`,
    private_metadata: JSON.stringify({ cardId, field: field.field }),
    title: {
      type: "plain_text",
      text: `Edit ${field.fieldLabel}`.slice(0, 24),
    },
    submit: { type: "plain_text", text: "Apply" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "input",
        block_id: "value_block",
        label: {
          type: "plain_text",
          text: `${field.fieldLabel} (${field.field})`.slice(0, 75),
        },
        element: input,
      },
    ],
  };
}

function summarizeProposedFieldChange(f: ProposedField): string {
  const to =
    f.recommendedDisplay ??
    (f.recommendedValue === null || f.recommendedValue === undefined
      ? "(none)"
      : String(f.recommendedValue));
  return `*${f.fieldLabel}* (\`${f.field}\`) → \`${to.length > 60 ? to.slice(0, 57) + "…" : to}\``;
}

export function bulkRecordCard(
  cardId: string,
  proposal: BulkRecordUpdateProposal,
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const excluded = new Set(proposal.excludedRecordIds);
  const included = proposal.recordSummaries.filter(
    (r) => !excluded.has(r.recordId)
  );
  const total = proposal.recordSummaries.length;
  const remaining = included.length;
  const needsConfirm = remaining >= 10;

  const header = `Bulk update · ${remaining} of ${total} ${proposal.sobjectType}${total === 1 ? "" : "s"}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: { type: "plain_text", text: header.slice(0, 150) },
    },
    { type: "section", text: { type: "mrkdwn", text: proposal.recap } },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Proposed changes (applied to every record below):*\n" +
          proposal.fields
            .map((f) => "• " + summarizeProposedFieldChange(f))
            .join("\n"),
      },
    },
    { type: "divider" },
  ];

  // Record rows. Show the first ~15 active ones; if more, render a summary
  // line at the bottom.
  const ROW_CAP = 15;
  const renderedRows = proposal.recordSummaries.slice(0, ROW_CAP);
  const overflow = proposal.recordSummaries.length - renderedRows.length;

  for (const row of renderedRows) {
    const isExcluded = excluded.has(row.recordId);
    const oppUrl = `${instanceUrl}/${row.recordId}`;
    const currentSnippets = proposal.fields
      .map((f) => {
        const cur = row.currentValues[f.field];
        const curStr =
          cur === null || cur === undefined
            ? "(none)"
            : String(cur).length > 30
              ? String(cur).slice(0, 27) + "…"
              : String(cur);
        return `${f.fieldLabel}: \`${curStr}\``;
      })
      .join(" · ");
    const namePart = `<${oppUrl}|*${row.recordName.length > 80 ? row.recordName.slice(0, 77) + "…" : row.recordName}*>`;
    const label = isExcluded
      ? `~${namePart}~ _(excluded)_`
      : `${namePart}\n_${currentSnippets || row.contextLabel || ""}_`;

    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: label },
      accessory: {
        type: "button",
        text: {
          type: "plain_text",
          text: isExcluded ? "Already excluded" : "Exclude",
        },
        action_id: actionId("bulk_exclude", cardId, row.recordId),
        value: row.recordId,
        ...(isExcluded ? { style: "danger" as const } : {}),
      },
    });
  }

  if (overflow > 0) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `_+${overflow} more record${overflow === 1 ? "" : "s"} not shown; they're included in the apply._`,
        },
      ],
    });
  }

  blocks.push({ type: "divider" });

  if (remaining === 0) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: ":no_entry_sign: All records excluded — nothing will be applied.",
        },
      ],
    });
    blocks.push({
      type: "actions",
      elements: [
        {
          type: "button",
          text: { type: "plain_text", text: "Cancel" },
          action_id: actionId("bulk_cancel", cardId),
        },
      ],
    });
  } else if (needsConfirm && !proposal.confirmed) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `:warning: *${remaining} records.* Click *Confirm* to proceed; then *Apply* to write to Salesforce.`,
        },
      ],
    });
    blocks.push({
      type: "actions",
      elements: [
        {
          type: "button",
          style: "danger",
          text: { type: "plain_text", text: `Confirm ${remaining} records` },
          action_id: actionId("bulk_confirm", cardId),
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Cancel" },
          action_id: actionId("bulk_cancel", cardId),
        },
      ],
    });
  } else {
    blocks.push({
      type: "actions",
      elements: [
        {
          type: "button",
          style: "primary",
          text: {
            type: "plain_text",
            text: `Apply to ${remaining} record${remaining === 1 ? "" : "s"}`,
          },
          action_id: actionId("bulk_apply", cardId),
        },
        {
          type: "button",
          text: { type: "plain_text", text: "Cancel" },
          action_id: actionId("bulk_cancel", cardId),
        },
      ],
    });
  }

  return {
    blocks,
    text: `${header} — ${proposal.recap}`,
  };
}

function renderErrorDetail(errors: SfApplyError[] | undefined, fallback: string): string {
  if (!errors || errors.length === 0) {
    return `\n_${fallback}_`;
  }
  const lines = errors.map((e) => {
    const fieldHint =
      e.fields && e.fields.length > 0
        ? `\n  └ *Missing/invalid field${e.fields.length === 1 ? "" : "s"}:* ${e.fields.map((f) => `\`${f}\``).join(", ")}`
        : "";
    return `_${e.message}_${fieldHint}`;
  });
  return "\n" + lines.join("\n");
}

function buildFailureSummary(
  results: {
    ok: boolean;
    errors?: SfApplyError[];
  }[]
): string | null {
  const failures = results.filter((r) => !r.ok && r.errors && r.errors.length > 0);
  if (failures.length === 0) return null;
  // Bucket by (statusCode + sorted fields signature). If 2+ records share a
  // bucket, hint the rep that they likely need to set those fields and retry.
  const buckets = new Map<string, { count: number; statusCode: string; fields: string[]; sample: string }>();
  for (const r of failures) {
    for (const e of r.errors!) {
      const sig = `${e.statusCode}::${[...e.fields].sort().join(",")}`;
      const existing = buckets.get(sig);
      if (existing) {
        existing.count++;
      } else {
        buckets.set(sig, {
          count: 1,
          statusCode: e.statusCode,
          fields: e.fields,
          sample: e.message,
        });
      }
    }
  }
  const interesting = [...buckets.values()].filter(
    (b) => b.count >= 2 && b.fields.length > 0
  );
  if (interesting.length === 0) return null;
  return interesting
    .map((b) => {
      const fieldList = b.fields.map((f) => `\`${f}\``).join(", ");
      const exampleField = b.fields[0];
      return `• *${b.count}* records failed with ${b.statusCode} — need ${fieldList}.\n  _Reply to me with a value (e.g._ \`set ${exampleField} = "..."\`_) and I'll retry just the failed records._`;
    })
    .join("\n");
}

export function bulkRecordCardResolved(
  proposal: BulkRecordUpdateProposal,
  results: {
    recordId: string;
    ok: boolean;
    error?: string;
    errors?: SfApplyError[];
  }[],
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const okCount = results.filter((r) => r.ok).length;
  const failCount = results.filter((r) => !r.ok).length;
  const header = `Bulk update applied — ${okCount} succeeded${failCount > 0 ? `, ${failCount} failed` : ""}`;
  const blocks: KnownBlock[] = [
    { type: "header", text: { type: "plain_text", text: header.slice(0, 150) } },
    { type: "section", text: { type: "mrkdwn", text: proposal.recap } },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Applied:*\n" +
          proposal.fields
            .map((f) => "• " + summarizeProposedFieldChange(f))
            .join("\n"),
      },
    },
    { type: "divider" },
  ];

  const failureSummary = buildFailureSummary(results);
  if (failureSummary) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `:bulb: *Likely fix:*\n${failureSummary}`,
      },
    });
    blocks.push({ type: "divider" });
  }

  const byId = new Map(results.map((r) => [r.recordId, r]));
  const ROW_CAP = 20;
  const rows = proposal.recordSummaries.slice(0, ROW_CAP);
  for (const row of rows) {
    const r = byId.get(row.recordId);
    if (!r) continue;
    const oppUrl = `${instanceUrl}/${row.recordId}`;
    const icon = r.ok ? ":white_check_mark:" : ":warning:";
    const namePart = `<${oppUrl}|*${row.recordName.length > 80 ? row.recordName.slice(0, 77) + "…" : row.recordName}*>`;
    const detail = r.ok
      ? ""
      : renderErrorDetail(r.errors, r.error ?? "Unknown error");
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `${icon} ${namePart}${detail}` },
    });
  }
  const overflow = proposal.recordSummaries.length - rows.length;
  if (overflow > 0) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `_+${overflow} more record${overflow === 1 ? "" : "s"} processed; see the audit log for details._`,
        },
      ],
    });
  }
  return { blocks, text: header };
}

export function cardWithFieldResolved(
  prevBlocks: KnownBlock[],
  field: string,
  status: "accepted" | "skipped" | "edited",
  appliedValue?: unknown
): KnownBlock[] {
  return prevBlocks.map((block) => {
    if (block.type !== "actions") return block;
    if ((block as any).block_id !== `field:${field}`) return block;
    return {
      type: "context",
      block_id: (block as any).block_id,
      elements: [
        {
          type: "mrkdwn",
          text:
            status === "accepted"
              ? `:white_check_mark: *${field}* accepted${appliedValue !== undefined ? ` → \`${formatValue(appliedValue)}\`` : ""}`
              : status === "edited"
                ? `:pencil2: *${field}* edited → \`${formatValue(appliedValue)}\``
                : `:no_entry_sign: *${field}* skipped`,
        },
      ],
    } as KnownBlock;
  });
}

export function editFieldModal(args: {
  cardId: string;
  field: string;
  recommendedValue: unknown;
  picklistOptions?: string[];
}): View {
  const { cardId, field, recommendedValue, picklistOptions } = args;
  const initial = recommendedValue == null ? "" : String(recommendedValue);

  let input: any;
  if (field === "StageName" && picklistOptions && picklistOptions.length > 0) {
    input = {
      type: "static_select",
      action_id: "value",
      initial_option:
        picklistOptions.includes(initial)
          ? { text: { type: "plain_text", text: initial }, value: initial }
          : undefined,
      options: picklistOptions.map((p) => ({
        text: { type: "plain_text", text: p.slice(0, 75) },
        value: p,
      })),
    };
  } else if (field === "CloseDate") {
    input = {
      type: "datepicker",
      action_id: "value",
      initial_date: /^\d{4}-\d{2}-\d{2}/.test(initial) ? initial.slice(0, 10) : undefined,
    };
  } else if (field === "Amount") {
    input = {
      type: "number_input",
      action_id: "value",
      is_decimal_allowed: true,
      initial_value: initial,
    };
  } else if (field === "Notes__c" || field === "Deal_Description__c") {
    input = {
      type: "plain_text_input",
      action_id: "value",
      multiline: true,
      initial_value: initial.slice(0, 3000),
    };
  } else {
    input = {
      type: "plain_text_input",
      action_id: "value",
      initial_value: initial,
    };
  }

  return {
    type: "modal",
    callback_id: `edit_field:${cardId}:${field}`,
    private_metadata: JSON.stringify({ cardId, field }),
    title: { type: "plain_text", text: `Edit ${field}`.slice(0, 24) },
    submit: { type: "plain_text", text: "Apply" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "input",
        block_id: "value_block",
        label: { type: "plain_text", text: field },
        element: input,
      },
    ],
  };
}

export function configModal(args: {
  timezone: string;
  hour: number;
  minute: number;
}): View {
  const timeStr = `${String(args.hour).padStart(2, "0")}:${String(args.minute).padStart(2, "0")}`;
  return {
    type: "modal",
    callback_id: "standup_config",
    title: { type: "plain_text", text: "Standup settings" },
    submit: { type: "plain_text", text: "Save" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "input",
        block_id: "timezone_block",
        label: { type: "plain_text", text: "Timezone" },
        element: {
          type: "static_select",
          action_id: "value",
          initial_option: {
            text: { type: "plain_text", text: args.timezone },
            value: args.timezone,
          },
          options: TZ_OPTIONS.map((tz) => ({
            text: { type: "plain_text", text: tz },
            value: tz,
          })),
        },
      },
      {
        type: "input",
        block_id: "time_block",
        label: { type: "plain_text", text: "Preferred send time" },
        element: {
          type: "timepicker",
          action_id: "value",
          initial_time: timeStr,
        },
      },
    ],
  };
}

export function connectPrompt(authUrl: string): {
  blocks: KnownBlock[];
  text: string;
} {
  const text = `Connect Salesforce to enable your daily standup.`;
  return {
    text,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text } },
      {
        type: "actions",
        elements: [
          {
            type: "button",
            action_id: "linkout:connect_sf",
            style: "primary",
            text: { type: "plain_text", text: "Connect Salesforce" },
            url: authUrl,
          },
        ],
      },
    ],
  };
}

function formatValue(v: unknown): string {
  if (v === null || v === undefined) return "(none)";
  if (typeof v === "string") return v.length > 60 ? v.slice(0, 57) + "…" : v;
  return String(v);
}

const SUGGESTION_FIELD: Record<BriefSuggestion["kind"], string> = {
  update_next_step: "NextStep",
  update_close_date: "CloseDate",
  update_stage: "StageName",
  update_amount: "Amount",
};

export function briefSuggestionField(kind: BriefSuggestion["kind"]): string {
  return SUGGESTION_FIELD[kind];
}

function suggestionLabel(s: BriefSuggestion): string {
  switch (s.kind) {
    case "update_next_step":
      return `Set NextStep → \`${formatValue(s.value)}\``;
    case "update_close_date":
      return `Push CloseDate → \`${formatValue(s.value)}\``;
    case "update_stage":
      return `Move StageName → \`${formatValue(s.value)}\``;
    case "update_amount":
      return `Update Amount → \`${formatValue(s.value)}\``;
  }
}

function formatPctMetric(v: string | number): string {
  if (typeof v === "string") {
    const trimmed = v.trim();
    if (trimmed.endsWith("%")) return trimmed;
    const n = Number(trimmed);
    if (Number.isFinite(n)) return formatPctMetric(n);
    return trimmed;
  }
  if (!Number.isFinite(v)) return "—";
  if (Math.abs(v) <= 1) return `${(v * 100).toFixed(1)}%`;
  return `${v.toFixed(1)}%`;
}

function formatNumMetric(v: string | number): string {
  if (typeof v === "string") {
    const n = Number(v.replace(/[, ]/g, ""));
    if (Number.isFinite(n)) return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
    return v;
  }
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

type RawMetric =
  | string
  | number
  | null
  | undefined
  | {
      mean?: string | number | null;
      min?: string | number | null;
      max?: string | number | null;
      trajectory?: string | null;
    };

function metricSummary(
  v: RawMetric,
  kind: "pct" | "num"
): { display: string; trajectory: string | null } | null {
  if (v == null) return null;
  const fmt = kind === "pct" ? formatPctMetric : formatNumMetric;
  if (typeof v === "string" || typeof v === "number") {
    return { display: fmt(v), trajectory: null };
  }
  const meanRaw = v.mean ?? null;
  const minRaw = v.min ?? null;
  const maxRaw = v.max ?? null;
  if (meanRaw == null && minRaw == null && maxRaw == null) {
    return v.trajectory ? { display: "—", trajectory: v.trajectory } : null;
  }
  const mean = meanRaw != null ? fmt(meanRaw) : "—";
  const min = minRaw != null ? fmt(minRaw) : null;
  const max = maxRaw != null ? fmt(maxRaw) : null;
  const display =
    min && max ? `${mean}  (${min}–${max})` : mean;
  return { display, trajectory: v.trajectory ?? null };
}

function renderBriefUsage(brief: BriefPayload): KnownBlock[] {
  const usage = brief.usage;
  const out: KnownBlock[] = [];

  if (!usage && brief.usageTrend) {
    out.push({ type: "divider" });
    out.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Usage*\n${brief.usageTrend}` },
    });
    return out;
  }
  if (!usage) return out;

  if (usage.status === "customer" && usage.metrics) {
    const m = usage.metrics as Record<string, RawMetric> & {
      enrolledUsers?: string | number | null;
    };
    const rows: Array<[string, string]> = [];
    const trajectories: Array<[string, string]> = [];

    const dauWauRaw = (m.dauWau ?? m.wauMau ?? m.dauWauL28d) as RawMetric;
    const summaries: Array<[string, RawMetric, "pct" | "num"]> = [
      ["DAU / WAU", dauWauRaw, "pct"],
      ["WAU / Enrolled", m.wauEnrolled, "pct"],
      ["Queries / User", m.queriesPerUser, "num"],
    ];
    for (const [label, raw, kind] of summaries) {
      const s = metricSummary(raw, kind);
      if (!s) continue;
      rows.push([label, s.display]);
      if (s.trajectory) trajectories.push([label, s.trajectory]);
    }

    const enrolled =
      m.enrolledUsers != null ? formatNumMetric(m.enrolledUsers) : null;

    if (rows.length > 0) {
      const labelWidth = Math.max(...rows.map((r) => r[0].length));
      const valueWidth = Math.max(...rows.map((r) => r[1].length));
      const table = rows
        .map(
          ([label, value]) =>
            `${label.padEnd(labelWidth)}   ${value.padStart(valueWidth)}`
        )
        .join("\n");
      const heading = enrolled
        ? `*Customer health · last 28 days · ${enrolled} enrolled*`
        : `*Customer health · last 28 days*`;
      out.push({ type: "divider" });
      out.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `${heading}\n\`\`\`\n${table}\n\`\`\``,
        },
      });
    }
    if (trajectories.length > 0) {
      out.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: trajectories
            .map(([label, traj]) => `*${label}*: ${traj}`)
            .join("\n"),
        },
      });
    }
    if (usage.commentary) {
      out.push({
        type: "section",
        text: { type: "mrkdwn", text: usage.commentary },
      });
    }
    return out;
  }

  if (usage.commentary) {
    out.push({ type: "divider" });
    out.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Usage*\n${usage.commentary}` },
    });
  }
  return out;
}

export function briefCard(
  cardId: string,
  brief: BriefPayload,
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const accountUrl = `${instanceUrl}/${brief.accountId}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: { type: "plain_text", text: brief.accountName.slice(0, 150) },
    },
  ];

  const ctxParts: string[] = [];
  if (brief.accountOwner) ctxParts.push(`Owner: *${brief.accountOwner}*`);
  if (brief.accountWebsite) {
    const w = brief.accountWebsite.trim();
    const url = /^https?:\/\//i.test(w) ? w : `https://${w}`;
    ctxParts.push(`Website: <${url}|${w}>`);
  }
  if (ctxParts.length > 0) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: ctxParts.join(" · ") }],
    });
  }

  blocks.push({
    type: "section",
    text: { type: "mrkdwn", text: brief.snapshot },
  });
  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        action_id: `linkout:open_account_brief:${cardId}`,
        text: { type: "plain_text", text: "Open Account" },
        url: accountUrl,
      },
    ],
  });

  if (brief.openOpportunities.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Open opportunities*\n" +
          brief.openOpportunities
            .slice(0, 8)
            .map(
              (o) =>
                `• <${instanceUrl}/${o.id}|${o.name}> — _${o.stage}_${
                  o.amount != null ? ` · ${formatValue(o.amount)}` : ""
                }${o.closeDate ? ` · close ${o.closeDate}` : ""}`
            )
            .join("\n"),
      },
    });
  }

  if (brief.recentWins.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Recent wins*\n" +
          brief.recentWins
            .slice(0, 4)
            .map((w) => {
              const amt = w.amount != null ? formatValue(w.amount) : null;
              const parts = [`<${instanceUrl}/${w.id}|${w.name}>`];
              if (amt) parts.push(amt);
              if (w.closedDate) parts.push(`closed ${w.closedDate}`);
              if (w.type) parts.push(w.type);
              return `• ${parts.join(" · ")}`;
            })
            .join("\n"),
      },
    });
  }

  if (brief.recentCalls.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Recent calls*\n" +
          brief.recentCalls
            .slice(0, 5)
            .map((c) => {
              const link = c.callUrl ? `<${c.callUrl}|${c.title}>` : c.title;
              const when = c.startedAt ? ` _(${c.startedAt.slice(0, 10)})_` : "";
              const briefLine = c.brief ? `\n    ${c.brief.slice(0, 200)}` : "";
              return `• ${link}${when}${briefLine}`;
            })
            .join("\n"),
      },
    });
  }

  if (brief.recentActivities.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Recent activities*\n" +
          brief.recentActivities
            .slice(0, 8)
            .map(
              (a) =>
                `• [${a.type}] ${a.subject}${a.when ? ` _(${a.when})_` : ""}${
                  a.who ? ` — ${a.who}` : ""
                }`
            )
            .join("\n"),
      },
    });
  }

  const usageBlocks = renderBriefUsage(brief);
  for (const b of usageBlocks) blocks.push(b);

  if (brief.talkingPoints.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          "*Talking points*\n" +
          brief.talkingPoints.map((p) => `• ${p}`).join("\n"),
      },
    });
  }

  if (brief.suggestedActions.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: "*Suggested actions*" },
    });
    brief.suggestedActions.forEach((s, idx) => {
      const opp = brief.openOpportunities.find((o) => o.id === s.opportunityId);
      const oppLabel = opp ? opp.name : s.opportunityId;
      blocks.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `*${oppLabel}* — ${suggestionLabel(s)}\n_${s.reasoning}_`,
        },
      });
      blocks.push({
        type: "actions",
        block_id: `brief_suggestion:${idx}`,
        elements: [
          {
            type: "button",
            style: "primary",
            text: { type: "plain_text", text: "Apply" },
            action_id: actionId("brief_apply", cardId, String(idx)),
            value: String(idx),
          },
          {
            type: "button",
            text: { type: "plain_text", text: "Skip" },
            action_id: actionId("brief_skip", cardId, String(idx)),
            value: String(idx),
          },
        ],
      });
    });
    blocks.push({ type: "divider" });
    blocks.push({
      type: "actions",
      elements: [
        {
          type: "button",
          style: "primary",
          text: { type: "plain_text", text: "Apply all" },
          action_id: actionId("brief_apply_all", cardId),
        },
      ],
    });
  }

  return {
    blocks,
    text: `Brief for ${brief.accountName} — ${brief.snapshot}`,
  };
}

export function briefSuggestionResolved(
  prevBlocks: KnownBlock[] | undefined,
  index: number,
  status: "applied" | "skipped",
  failure?: string
): KnownBlock[] {
  if (!prevBlocks) return [];
  const blockId = `brief_suggestion:${index}`;
  return prevBlocks.map((block) => {
    if (block.type !== "actions") return block;
    if ((block as any).block_id !== blockId) return block;
    return {
      type: "context",
      block_id: blockId,
      elements: [
        {
          type: "mrkdwn",
          text:
            failure
              ? `:warning: failed — ${failure}`
              : status === "applied"
                ? ":white_check_mark: applied"
                : ":no_entry_sign: skipped",
        },
      ],
    } as KnownBlock;
  });
}

export function disambiguationBlocks(
  query: string,
  candidates: { id: string; name: string; industry?: string | null; ownerName?: string | null }[]
): { blocks: KnownBlock[]; text: string } {
  const text = `Multiple accounts matched "${query}". Pick one.`;
  const blocks: KnownBlock[] = [
    { type: "section", text: { type: "mrkdwn", text } },
  ];
  for (const c of candidates.slice(0, 10)) {
    const meta = [c.industry, c.ownerName].filter(Boolean).join(" · ");
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*${c.name}*${meta ? `\n_${meta}_` : ""}`,
      },
      accessory: {
        type: "button",
        text: { type: "plain_text", text: "Brief" },
        action_id: actionId("brief_pick_account", c.id),
        value: c.name,
      },
    });
  }
  return { blocks, text };
}

export function briefErrorBlocks(message: string): {
  blocks: KnownBlock[];
  text: string;
} {
  return {
    blocks: [{ type: "section", text: { type: "mrkdwn", text: message } }],
    text: message,
  };
}

export function channelMentionReply(): { blocks: KnownBlock[]; text: string } {
  const text =
    "Hi! DM me to chat — channel access isn't enabled yet. Try `brief <account>` or just ask a question.";
  return {
    text,
    blocks: [{ type: "section", text: { type: "mrkdwn", text } }],
  };
}

export function buySignalThreadParent(args: {
  cardCount: number;
}): { blocks: KnownBlock[]; text: string } {
  const summary = `*Buy signals* — ${args.cardCount} account${args.cardCount === 1 ? "" : "s"} with recent positive calls and no open opp.`;
  return {
    text: summary,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text: summary } },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: "Create an opportunity, log a follow-up task, or skip.",
          },
        ],
      },
    ],
  };
}

function actionLabel(payload: BuySignalPayload): string {
  if (payload.suggestedAction === "create_opportunity" && payload.suggestedOpp) {
    const amt =
      payload.suggestedOpp.amount != null
        ? ` · ${formatValue(payload.suggestedOpp.amount)}`
        : "";
    return `*Suggested: create opportunity*\n\`${payload.suggestedOpp.name}\` — _${payload.suggestedOpp.stage}_${amt} · close ${payload.suggestedOpp.closeDate}`;
  }
  if (payload.suggestedAction === "log_task" && payload.suggestedTask) {
    return `*Suggested: log follow-up task*\n\`${payload.suggestedTask.subject}\` — due ${payload.suggestedTask.dueDate}`;
  }
  return "*Suggested: review the call*";
}

export function buySignalCard(
  cardId: string,
  payload: BuySignalPayload,
  opts: { instanceUrl: string }
): { blocks: KnownBlock[]; text: string } {
  const accountUrl = `${opts.instanceUrl}/${payload.accountId}`;
  const mostRecent = payload.calls[0];
  const who = mostRecent?.ownerName ? `GTMA ${mostRecent.ownerName}` : "GTMA";
  const when = payload.mostRecentCallDate ?? "recently";
  const countLine =
    payload.callCount > 1
      ? ` · ${payload.callCount} positive calls in last 7 days`
      : "";
  const callSummary = mostRecent?.description
    ? mostRecent.description.slice(0, 600)
    : "(no summary recorded)";

  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `[Buy signal] ${payload.accountName}`.slice(0, 150),
      },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `${who} · ${when}${countLine}`,
        },
      ],
    },
    { type: "section", text: { type: "mrkdwn", text: `*${payload.headline}*` } },
    { type: "section", text: { type: "mrkdwn", text: `> ${callSummary}` } },
    { type: "section", text: { type: "mrkdwn", text: actionLabel(payload) } },
    { type: "section", text: { type: "mrkdwn", text: `_${payload.rationale}_` } },
  ];

  const oppIsPrimary = payload.suggestedAction === "create_opportunity";
  const taskIsPrimary = payload.suggestedAction === "log_task";

  const buttons: any[] = [];
  if (payload.suggestedOpp) {
    const b: any = {
      type: "button",
      text: { type: "plain_text", text: "Create opportunity" },
      action_id: actionId("buy_signal_create_opp", cardId),
    };
    if (oppIsPrimary) b.style = "primary";
    buttons.push(b);
  }
  if (payload.suggestedTask) {
    const b: any = {
      type: "button",
      text: { type: "plain_text", text: "Log follow-up task" },
      action_id: actionId("buy_signal_log_task", cardId),
    };
    if (taskIsPrimary) b.style = "primary";
    buttons.push(b);
  }
  buttons.push({
    type: "button",
    text: { type: "plain_text", text: "Skip" },
    action_id: actionId("buy_signal_skip", cardId),
  });
  buttons.push({
    type: "button",
    action_id: `linkout:open_account_bs:${cardId}`,
    text: { type: "plain_text", text: "Open Account" },
    url: accountUrl,
  });

  blocks.push({
    type: "actions",
    block_id: "buy_signal_actions",
    elements: buttons,
  });

  return {
    blocks,
    text: `[Buy signal] ${payload.accountName} — ${payload.headline}`,
  };
}

export function buySignalCardResolved(
  prevBlocks: KnownBlock[] | undefined,
  status: "applied_opp" | "applied_task" | "skipped",
  detail?: string
): KnownBlock[] {
  if (!prevBlocks) return [];
  const replacement: KnownBlock = {
    type: "context",
    block_id: "buy_signal_actions",
    elements: [
      {
        type: "mrkdwn",
        text:
          status === "applied_opp"
            ? `:white_check_mark: Opportunity created${detail ? ` — ${detail}` : ""}`
            : status === "applied_task"
              ? `:white_check_mark: Task logged${detail ? ` — ${detail}` : ""}`
              : ":no_entry_sign: Skipped",
      },
    ],
  };
  return prevBlocks.map((block) => {
    if (block.type !== "actions") return block;
    if ((block as any).block_id !== "buy_signal_actions") return block;
    return replacement;
  });
}

export function buySignalCreateOppModal(
  cardId: string,
  payload: BuySignalPayload
): View {
  const opp = payload.suggestedOpp!;
  return {
    type: "modal",
    callback_id: `buy_signal_create_opp:${cardId}`,
    private_metadata: JSON.stringify({ cardId }),
    title: { type: "plain_text", text: "New opportunity" },
    submit: { type: "plain_text", text: "Create" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `For *${payload.accountName}* — based on ${payload.callCount} positive call${payload.callCount === 1 ? "" : "s"}.`,
          },
        ],
      },
      {
        type: "input",
        block_id: "name_block",
        label: { type: "plain_text", text: "Name" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: opp.name.slice(0, 120),
        },
      },
      {
        type: "input",
        block_id: "stage_block",
        label: { type: "plain_text", text: "Stage" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: opp.stage,
        },
      },
      {
        type: "input",
        block_id: "amount_block",
        optional: true,
        label: { type: "plain_text", text: "Amount" },
        element: {
          type: "number_input",
          action_id: "value",
          is_decimal_allowed: true,
          initial_value:
            opp.amount != null && Number.isFinite(opp.amount)
              ? String(opp.amount)
              : undefined,
        },
      },
      {
        type: "input",
        block_id: "close_date_block",
        label: { type: "plain_text", text: "Close date" },
        element: {
          type: "datepicker",
          action_id: "value",
          initial_date: /^\d{4}-\d{2}-\d{2}/.test(opp.closeDate)
            ? opp.closeDate
            : undefined,
        },
      },
    ],
  };
}

export function nooksCallDigestCard(
  payload: NooksWebhookPayload
): { blocks: KnownBlock[]; text: string } {
  const d = payload.callData;
  const dispositionLabel = d.disposition?.name ?? "(no disposition)";
  const accountName = d.accountData?.name ?? null;
  const prospectName = d.prospectData?.name ?? null;
  const rogoCaller =
    d.userData?.name ?? d.userData?.email ?? null;

  const isValidHttpUrl = (u: string | undefined): u is string =>
    typeof u === "string" && /^https?:\/\//i.test(u);

  const headerText =
    prospectName && accountName
      ? `${prospectName} · ${accountName}`
      : prospectName
        ? prospectName
        : accountName
          ? accountName
          : "Nooks call";

  const text = `Nooks · ${headerText} · ${dispositionLabel}`;

  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: headerText.slice(0, 150),
      },
    },
  ];

  const contextParts: string[] = [`*${dispositionLabel}*`];
  if (rogoCaller) contextParts.push(`called by ${rogoCaller}`);
  blocks.push({
    type: "context",
    elements: [{ type: "mrkdwn", text: contextParts.join(" · ") }],
  });

  const prospectLines: string[] = [];
  if (d.prospectData?.email && d.prospectData.email.includes("@"))
    prospectLines.push(`*Email*: ${d.prospectData.email}`);
  if (
    d.prospectData?.phoneNumber &&
    /\d/.test(d.prospectData.phoneNumber)
  )
    prospectLines.push(`*Phone*: ${d.prospectData.phoneNumber}`);
  if (isValidHttpUrl(d.prospectData?.linkedInUrl))
    prospectLines.push(`*LinkedIn*: <${d.prospectData!.linkedInUrl}|profile>`);
  if (prospectLines.length > 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Prospect*\n${prospectLines.join("\n")}`,
      },
    });
  }

  if (d.accountData?.accountId) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Salesforce Account*\n\`${d.accountData.accountId}\``,
      },
    });
  }

  if (d.notes) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Notes*\n> ${d.notes.slice(0, 2000)}`,
      },
    });
  }

  const linkButtons: any[] = [];
  if (isValidHttpUrl(d.recordingUrl)) {
    linkButtons.push({
      type: "button",
      action_id: `linkout:nooks_recording:${d.callId}`,
      text: { type: "plain_text", text: "Recording" },
      url: d.recordingUrl,
    });
  }
  if (isValidHttpUrl(d.transcriptUrl)) {
    linkButtons.push({
      type: "button",
      action_id: `linkout:nooks_transcript:${d.callId}`,
      text: { type: "plain_text", text: "Transcript" },
      url: d.transcriptUrl,
    });
  }
  if (linkButtons.length > 0) {
    blocks.push({ type: "actions", elements: linkButtons });
  }

  return { blocks, text };
}

function gongFieldValue(
  obj: { fields?: { name: string; value: unknown }[] | null } | undefined,
  name: string
): string | null {
  const v = obj?.fields?.find((f) => f.name === name)?.value;
  if (v == null) return null;
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  if (Array.isArray(v) && v.length === 3 && v.every((n) => typeof n === "number")) {
    const [y, m, d] = v as number[];
    return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
  }
  return String(v);
}

export function gongCallDigestCard(
  payload: GongWebhookPayload,
  opts: {
    hostName?: string | null;
    insights?: GongCallInsight | null;
  } = {}
): { blocks: KnownBlock[]; text: string } {
  const isValidHttpUrl = (u: string | null | undefined): u is string =>
    typeof u === "string" && /^https?:\/\//i.test(u);

  const callData = payload.callData;
  const meta = callData?.metaData;
  const callId = meta?.id ?? "";
  const title =
    typeof meta?.title === "string" && meta.title.trim()
      ? meta.title.trim()
      : "Gong call";

  const parties = callData?.parties ?? [];
  const primaryUserId = meta?.primaryUserId ?? null;
  const hostParty =
    parties.find((p) => primaryUserId && p?.userId === primaryUserId) ?? null;
  const hostLabel =
    opts.hostName ||
    hostParty?.name ||
    hostParty?.emailAddress ||
    "(unknown host)";

  const durationMin =
    typeof meta?.duration === "number" && meta.duration > 0
      ? Math.round(meta.duration / 60)
      : null;

  const internal = parties.filter(
    (p) => String(p?.affiliation ?? "").toLowerCase() === "internal"
  ).length;
  const external = parties.filter(
    (p) => String(p?.affiliation ?? "").toLowerCase() === "external"
  ).length;
  const partySummary =
    parties.length > 0
      ? `${parties.length} on call (${internal} internal, ${external} external)`
      : null;

  const contextParts: string[] = [hostLabel];
  if (durationMin) contextParts.push(`${durationMin} min`);
  if (partySummary) contextParts.push(partySummary);

  const text = `Gong · ${title}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `Gong · ${title}`.slice(0, 150),
      },
    },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: contextParts.join(" · ") }],
    },
  ];

  const sfContext = callData?.context?.find(
    (c) => String(c?.system ?? "").toLowerCase() === "salesforce"
  );
  const sfAccount = sfContext?.objects?.find(
    (o) => o.objectType === "Account"
  );
  const sfOpp = sfContext?.objects?.find(
    (o) => o.objectType === "Opportunity"
  );

  const sfLines: string[] = [];
  if (sfAccount) {
    const name = gongFieldValue(sfAccount, "Name") ?? sfAccount.objectId;
    sfLines.push(`*Account*: ${name}`);
  }
  if (sfOpp) {
    const oppName = gongFieldValue(sfOpp, "Name") ?? sfOpp.objectId;
    const stage = gongFieldValue(sfOpp, "StageName");
    const amount = gongFieldValue(sfOpp, "Amount");
    const closeDate = gongFieldValue(sfOpp, "CloseDate");
    const oppBits = [oppName];
    if (stage) oppBits.push(stage);
    if (amount) oppBits.push(`$${Number(amount).toLocaleString()}`);
    if (closeDate) oppBits.push(`closes ${closeDate}`);
    sfLines.push(`*Opportunity*: ${oppBits.join(" · ")}`);
  }
  if (sfLines.length > 0) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: sfLines.join("\n") },
    });
  }

  const insights = opts.insights;
  if (insights?.summary) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Summary*\n${insights.summary}` },
    });
  }
  const bulletList = (items: string[]): string =>
    items.map((s) => `• ${s}`).join("\n");
  if (insights?.positives?.length) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Positives*\n${bulletList(insights.positives)}`,
      },
    });
  }
  if (insights?.negatives?.length) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Concerns*\n${bulletList(insights.negatives)}`,
      },
    });
  }
  if (insights?.nextSteps?.length) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Next steps*\n${bulletList(insights.nextSteps)}`,
      },
    });
  }

  const topics = callData?.content?.topics ?? [];
  const topicLine = topics
    .filter((t) => typeof t?.duration === "number" && (t.duration ?? 0) > 0)
    .sort((a, b) => (b.duration ?? 0) - (a.duration ?? 0))
    .slice(0, 4)
    .map((t) => `${t.name} (${Math.round((t.duration ?? 0) / 60)}m)`)
    .join(" · ");
  if (topicLine) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Topics*: ${topicLine}` },
    });
  }

  if (isValidHttpUrl(meta?.url)) {
    blocks.push({
      type: "actions",
      elements: [
        {
          type: "button",
          action_id: `linkout:gong:${callId}`,
          text: { type: "plain_text", text: "Open in Gong" },
          url: meta!.url!,
        },
      ],
    });
  }

  if (callId) {
    blocks.push({
      type: "context",
      elements: [
        { type: "mrkdwn", text: `Call ID: \`${callId}\`` },
      ],
    });
  }

  return { blocks, text };
}

export function buySignalLogTaskModal(
  cardId: string,
  payload: BuySignalPayload
): View {
  const task = payload.suggestedTask!;
  return {
    type: "modal",
    callback_id: `buy_signal_log_task:${cardId}`,
    private_metadata: JSON.stringify({ cardId }),
    title: { type: "plain_text", text: "Log follow-up task" },
    submit: { type: "plain_text", text: "Create" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `On *${payload.accountName}*.`,
          },
        ],
      },
      {
        type: "input",
        block_id: "subject_block",
        label: { type: "plain_text", text: "Subject" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: task.subject.slice(0, 200),
        },
      },
      {
        type: "input",
        block_id: "due_date_block",
        label: { type: "plain_text", text: "Due date" },
        element: {
          type: "datepicker",
          action_id: "value",
          initial_date: /^\d{4}-\d{2}-\d{2}/.test(task.dueDate)
            ? task.dueDate
            : undefined,
        },
      },
      {
        type: "input",
        block_id: "description_block",
        optional: true,
        label: { type: "plain_text", text: "Notes" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          multiline: true,
          initial_value: task.description ?? payload.rationale ?? "",
        },
      },
    ],
  };
}

export function meetingPickerCard(
  cardId: string,
  args: {
    eventTitle: string;
    startLabel: string;
    externalEmails: string[];
    candidates: MeetingPickerCandidate[];
  }
): { blocks: KnownBlock[]; text: string } {
  const text = `Pick an account for "${args.eventTitle}"`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `Pick an account · ${args.eventTitle}`.slice(0, 150),
      },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `Meeting at ${args.startLabel} · external attendees: ${args.externalEmails.join(", ")}`,
        },
      ],
    },
  ];

  if (args.candidates.length === 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: "I couldn't find a Salesforce account from the attendee list. No brief will fire for this meeting.",
      },
    });
    return { blocks, text };
  }

  blocks.push({
    type: "section",
    text: {
      type: "mrkdwn",
      text: "I couldn't auto-resolve a single Salesforce account. Pick one to brief:",
    },
  });

  for (const c of args.candidates) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*${c.name}*\n_${c.reason}_`,
      },
      accessory: {
        type: "button",
        text: { type: "plain_text", text: "Brief this account" },
        action_id: actionId("meeting_pick_account", cardId, c.id),
        value: c.id,
      },
    });
  }

  return { blocks, text };
}

export function postMeetingCard(
  cardId: string,
  payload: PostMeetingPayload,
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const accountUrl = `${instanceUrl}/${payload.accountId}`;
  const text = `Post-meeting · ${payload.eventTitle}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `Post-meeting · ${payload.eventTitle}`.slice(0, 150),
      },
    },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Account:* <${accountUrl}|${payload.accountName}>`,
      },
    },
  ];

  if (payload.matchedContacts.length > 0) {
    const lines = payload.matchedContacts
      .map((c) => `• ${c.name ?? c.email}${c.title ? ` — _${c.title}_` : ""}`)
      .join("\n");
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Attendees already in Salesforce*\n${lines}`,
      },
    });
  }

  if (payload.unmatchedAttendees.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Attendees not yet in Salesforce* — click to add under *${payload.accountName}*`,
      },
    });
    for (let i = 0; i < payload.unmatchedAttendees.length; i++) {
      const a = payload.unmatchedAttendees[i];
      blocks.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `• ${a.displayName ?? "(no name)"} — ${a.email}`,
        },
        accessory: {
          type: "button",
          text: { type: "plain_text", text: "Add to Salesforce" },
          action_id: actionId("add_contact", cardId, String(i)),
          value: a.email,
        },
      });
    }
  }

  if (payload.openOpportunities.length > 0) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Open opportunities on ${payload.accountName}*`,
      },
    });
    for (const opp of payload.openOpportunities) {
      const oppUrl = `${instanceUrl}/${opp.id}`;
      const lines: string[] = [`*<${oppUrl}|${opp.name}>* — ${opp.stage}`];
      if (opp.amount != null)
        lines.push(`Amount: $${Number(opp.amount).toLocaleString()}`);
      if (opp.closeDate) lines.push(`Close date: ${opp.closeDate}`);
      if (opp.nextStep) lines.push(`Next step: ${opp.nextStep}`);
      blocks.push({
        type: "section",
        text: { type: "mrkdwn", text: lines.join("\n") },
        accessory: {
          type: "button",
          text: { type: "plain_text", text: "Update Opp" },
          action_id: actionId("update_meeting_opp", cardId, opp.id),
          value: opp.id,
        },
      });
    }
  }

  blocks.push({ type: "divider" });
  blocks.push({
    type: "actions",
    block_id: "post_meeting_actions",
    elements: [
      {
        type: "button",
        text: { type: "plain_text", text: "Log meeting as task" },
        action_id: actionId("log_meeting_task", cardId),
        value: cardId,
      },
      {
        type: "button",
        text: { type: "plain_text", text: "Dismiss" },
        action_id: actionId("post_meeting_skip", cardId),
        value: cardId,
        style: "danger",
      },
    ],
  });
  return { blocks, text };
}

export function postMeetingAddContactModal(
  cardId: string,
  attendeeIndex: number,
  args: {
    accountName: string;
    email: string;
    firstName: string;
    lastName: string;
  }
): View {
  return {
    type: "modal",
    callback_id: actionId("add_contact", cardId, String(attendeeIndex)),
    private_metadata: JSON.stringify({ cardId, attendeeIndex }),
    title: { type: "plain_text", text: "Add Contact" },
    submit: { type: "plain_text", text: "Add to Salesforce" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `Adding under account *${args.accountName}*.`,
        },
      },
      {
        type: "input",
        block_id: "first_name_block",
        label: { type: "plain_text", text: "First name" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: args.firstName.slice(0, 40),
        },
      },
      {
        type: "input",
        block_id: "last_name_block",
        label: { type: "plain_text", text: "Last name" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: args.lastName.slice(0, 80),
        },
      },
      {
        type: "input",
        block_id: "email_block",
        label: { type: "plain_text", text: "Email" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: args.email.slice(0, 80),
        },
      },
      {
        type: "input",
        block_id: "title_block",
        optional: true,
        label: { type: "plain_text", text: "Title" },
        element: {
          type: "plain_text_input",
          action_id: "value",
        },
      },
    ],
  };
}

export function postMeetingUpdateOppModal(
  cardId: string,
  args: {
    opportunityId: string;
    opportunityName: string;
    currentStage: string;
    currentNextStep: string | null;
    currentCloseDate: string | null;
    stageOptions: string[];
  }
): View {
  const stages = args.stageOptions.length > 0
    ? args.stageOptions
    : [args.currentStage];
  const stageOpts = stages.map((s) => ({
    text: { type: "plain_text" as const, text: s.slice(0, 75) },
    value: s,
  }));
  return {
    type: "modal",
    callback_id: actionId("update_meeting_opp", cardId, args.opportunityId),
    private_metadata: JSON.stringify({
      cardId,
      opportunityId: args.opportunityId,
      currentStage: args.currentStage,
      currentNextStep: args.currentNextStep,
      currentCloseDate: args.currentCloseDate,
    }),
    title: { type: "plain_text", text: "Update Opportunity" },
    submit: { type: "plain_text", text: "Save" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `*${args.opportunityName}*`,
        },
      },
      {
        type: "input",
        block_id: "stage_block",
        optional: true,
        label: { type: "plain_text", text: "Stage" },
        element: {
          type: "static_select",
          action_id: "value",
          initial_option: {
            text: { type: "plain_text", text: args.currentStage.slice(0, 75) },
            value: args.currentStage,
          },
          options: stageOpts,
        },
      },
      {
        type: "input",
        block_id: "next_step_block",
        optional: true,
        label: { type: "plain_text", text: "Next step" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          multiline: true,
          initial_value: (args.currentNextStep ?? "").slice(0, 1000),
        },
      },
      {
        type: "input",
        block_id: "close_date_block",
        optional: true,
        label: { type: "plain_text", text: "Close date" },
        element: {
          type: "datepicker",
          action_id: "value",
          initial_date: args.currentCloseDate
            ? args.currentCloseDate.slice(0, 10)
            : undefined,
        },
      },
    ],
  };
}

export function postMeetingLogTaskModal(
  cardId: string,
  args: {
    accountName: string;
    eventTitle: string;
    attendeeSummary: string;
    todayIso: string;
  }
): View {
  return {
    type: "modal",
    callback_id: actionId("log_meeting_task", cardId),
    private_metadata: JSON.stringify({ cardId }),
    title: { type: "plain_text", text: "Log meeting" },
    submit: { type: "plain_text", text: "Log task" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `Logging on account *${args.accountName}*.`,
        },
      },
      {
        type: "input",
        block_id: "subject_block",
        label: { type: "plain_text", text: "Subject" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          initial_value: `Meeting: ${args.eventTitle}`.slice(0, 200),
        },
      },
      {
        type: "input",
        block_id: "due_date_block",
        label: { type: "plain_text", text: "Date" },
        element: {
          type: "datepicker",
          action_id: "value",
          initial_date: args.todayIso.slice(0, 10),
        },
      },
      {
        type: "input",
        block_id: "description_block",
        optional: true,
        label: { type: "plain_text", text: "Notes" },
        element: {
          type: "plain_text_input",
          action_id: "value",
          multiline: true,
          initial_value: args.attendeeSummary.slice(0, 2000),
        },
      },
    ],
  };
}

// ─── Deal-channel sync ─────────────────────────────────────────────────────

export interface OppDisambiguationCandidate {
  id: string;
  name: string;
  accountName: string;
  stage: string;
  amount: number | null;
  isClosed: boolean;
  ownerName: string | null;
}

/**
 * Ephemeral disambiguation card shown when `/merlin-deal bind <query>` matches
 * more than one Opportunity. Each candidate gets a Bind button.
 */
export function bindDisambiguationBlocks(
  query: string,
  candidates: OppDisambiguationCandidate[],
  slackChannelId: string
): { blocks: KnownBlock[]; text: string } {
  const blocks: KnownBlock[] = [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: `:mag: Multiple opps match \`${query}\`. Pick one to bind this channel to:`,
      },
    },
  ];
  for (const c of candidates.slice(0, 5)) {
    const amount =
      c.amount != null ? ` · $${Math.round(c.amount).toLocaleString()}` : "";
    const closed = c.isClosed ? " · _closed_" : "";
    const owner = c.ownerName ? ` · ${c.ownerName}` : "";
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*${c.name}*\n_${c.accountName} · ${c.stage}${amount}${closed}${owner}_`,
      },
      accessory: {
        type: "button",
        action_id: `bind_pick_opp:${slackChannelId}:${c.id}`,
        text: { type: "plain_text", text: "Bind to this opp" },
        value: c.id,
      },
    });
  }
  return {
    blocks,
    text: `Multiple opps match "${query}" — pick one to bind`,
  };
}

/**
 * Ephemeral message that fires immediately after a successful bind. Offers
 * four "first read" options; each button triggers a channel sync against
 * the chosen window.
 */
export function postBindPromptBlocks(
  slackChannelId: string,
  opportunityName: string
): { blocks: KnownBlock[]; text: string } {
  const blocks: KnownBlock[] = [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `:link: Bound this channel to *${opportunityName}*.\n` +
          `Want me to read recent channel history now and DM you the suggested updates?`,
      },
    },
    {
      type: "actions",
      elements: [
        {
          type: "button",
          action_id: `channel_sync_window:${slackChannelId}:7`,
          text: { type: "plain_text", text: "Last 7 days" },
        },
        {
          type: "button",
          action_id: `channel_sync_window:${slackChannelId}:30`,
          text: { type: "plain_text", text: "Last 30 days" },
        },
        {
          type: "button",
          action_id: `channel_sync_window:${slackChannelId}:all`,
          text: { type: "plain_text", text: "Entire channel history" },
        },
        {
          type: "button",
          action_id: `channel_sync_skip:${slackChannelId}`,
          text: { type: "plain_text", text: "Skip — I'll sync later" },
          style: "danger",
        },
      ],
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text:
            `Tip: \`/merlin-deal sync\` re-runs the sync any time; ` +
            `\`/merlin-deal status\` shows the current binding; ` +
            `\`/merlin-deal unbind\` removes it.`,
        },
      ],
    },
  ];
  return {
    blocks,
    text: `Bound this channel to ${opportunityName} — read recent history now?`,
  };
}

export function channelBindStatusBlocks(args: {
  opportunityName: string;
  accountName: string | null;
  boundBySlackUserId: string;
  lastSyncedAt: string | null;
  instanceUrl: string;
  opportunityId: string;
}): { blocks: KnownBlock[]; text: string } {
  const sfUrl = `${args.instanceUrl.replace(/\/+$/, "")}/${args.opportunityId}`;
  const lastSynced = args.lastSyncedAt
    ? `last synced ${args.lastSyncedAt}`
    : "_never synced — run `/merlin-deal sync` to pull history_";
  return {
    text: `Bound to ${args.opportunityName}`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text:
            `:link: This channel is bound to <${sfUrl}|*${args.opportunityName}*>` +
            (args.accountName ? ` (${args.accountName})` : "") +
            `\n` +
            `Bound by <@${args.boundBySlackUserId}> · ${lastSynced}`,
        },
      },
    ],
  };
}

// ─── At-risk opp watch ─────────────────────────────────────────────────────

export type OppWatchReason = "renewal_approaching" | "stalled" | "both";

export interface OppWatchCardOpts {
  reason: OppWatchReason;
  daysToClose: number | null;
  daysSinceActivity: number | null;
}

/**
 * Wraps the standard oppCard with a header context block explaining WHY this
 * opp surfaced ("⚠️ Renewal closes in 14d · last activity 23d ago"). Keeps
 * the recommendation card identical to the standup version so all existing
 * accept/edit/skip/apply_all handlers work unchanged.
 */
export function oppWatchCard(
  cardId: string,
  rec: Recommendation,
  oppOpts: { name: string; accountName: string; instanceUrl: string },
  watch: OppWatchCardOpts
): { blocks: KnownBlock[]; text: string } {
  const base = oppCard(cardId, rec, oppOpts);
  const badge = oppWatchBadge(watch);
  // Prepend the warning badge as a context block so it reads above the
  // existing header section.
  const blocks: KnownBlock[] = [
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: badge }],
    },
    ...base.blocks,
  ];
  return { blocks, text: `⚠️ ${watch.reason}: ${base.text}` };
}

export function oppWatchBadge(watch: OppWatchCardOpts): string {
  const parts: string[] = [];
  if (
    watch.reason === "renewal_approaching" ||
    watch.reason === "both"
  ) {
    const d = watch.daysToClose;
    parts.push(
      d != null
        ? `:warning: *Renewal closes in ${d} day${d === 1 ? "" : "s"}*`
        : `:warning: *Renewal approaching*`
    );
  }
  if (watch.reason === "stalled" || watch.reason === "both") {
    const d = watch.daysSinceActivity;
    parts.push(
      d != null
        ? `:hourglass_flowing_sand: *Last activity ${d} day${d === 1 ? "" : "s"} ago*`
        : `:hourglass_flowing_sand: *No logged activity*`
    );
  }
  return parts.join(" · ");
}

// ─── Universal feedback row (helpful / not helpful) ──────────────────────
// Action ids encode the surface so the handler can audit/aggregate by source
// without needing to look up the pending_cards row first.
//   feedback_helpful:<surface>:<cardId?>
//   feedback_not_helpful:<surface>:<cardId?>
// When card_id is absent (e.g. moderator thread reply), pass surface only.

export function feedbackButtonsRow(
  surface: FeedbackSurface,
  cardId?: string | null
): KnownBlock {
  const suffix = cardId ? `:${cardId}` : "";
  return {
    type: "actions",
    block_id: `feedback:${surface}${suffix}`,
    elements: [
      {
        type: "button",
        action_id: `feedback_helpful:${surface}${suffix}`,
        text: { type: "plain_text", text: ":+1: Helpful", emoji: true },
        value: surface,
      },
      {
        type: "button",
        action_id: `feedback_not_helpful:${surface}${suffix}`,
        text: { type: "plain_text", text: ":-1: Not helpful", emoji: true },
        value: surface,
        style: "danger",
      },
    ],
  };
}

// ─── Blue post-call next-moves card ──────────────────────────────────────

export function nextMovesCard(
  cardId: string,
  payload: NextMovesPayload,
  instanceUrl: string
): { blocks: KnownBlock[]; text: string } {
  const oppUrl = `${instanceUrl.replace(/\/+$/, "")}/${payload.opportunityId}`;
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `:dart: Next moves — ${payload.opportunityName}`.slice(0, 150),
      },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `${payload.accountName}${
            payload.callTitle ? ` · after Gong call _${payload.callTitle.slice(0, 80)}_` : ""
          }`,
        },
      ],
    },
  ];

  if (payload.headline) {
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*${payload.headline}*` },
    });
  }
  if (payload.rationale) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: `_${payload.rationale.slice(0, 600)}_` }],
    });
  }

  payload.actions.forEach((a, i) => {
    const state = payload.actionStates[i] ?? "open";
    blocks.push({ type: "divider" });
    const stateLabel =
      state === "accepted"
        ? " :white_check_mark: _accepted_"
        : state === "skipped"
        ? " :black_square_for_stop: _skipped_"
        : "";
    const meta: string[] = [];
    if (a.ownerRole) meta.push(`*Owner:* ${a.ownerRole}`);
    if (a.byDate) meta.push(`*By:* ${a.byDate}`);
    if (a.expectedSignal) meta.push(`*Signal:* ${a.expectedSignal}`);
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*${i + 1}. ${a.action}*${stateLabel}\n${meta.join(" · ")}`,
      },
    });
    if (state === "open") {
      blocks.push({
        type: "actions",
        block_id: `next_move:${i}`,
        elements: [
          {
            type: "button",
            style: "primary",
            text: { type: "plain_text", text: "Mark done" },
            action_id: `next_moves_accept:${cardId}:${i}`,
            value: String(i),
          },
          {
            type: "button",
            text: { type: "plain_text", text: "Skip" },
            action_id: `next_moves_skip:${cardId}:${i}`,
            value: String(i),
          },
        ],
      });
    }
  });

  blocks.push({ type: "divider" });
  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        action_id: `linkout:open_in_sf:${payload.opportunityId}`,
        text: { type: "plain_text", text: "Open in Salesforce" },
        url: oppUrl,
      },
    ],
  });
  blocks.push(feedbackButtonsRow("next_moves", cardId));

  const fallbackText =
    payload.headline || `Next moves on ${payload.opportunityName}`;
  return { blocks, text: fallbackText };
}
