import type { KnownBlock, View } from "@slack/types";
import { TZ_OPTIONS } from "../constants.js";
import type {
  BriefPayload,
  BriefSuggestion,
  BuySignalPayload,
  GongCallInsight,
  GongWebhookPayload,
  NooksWebhookPayload,
  Recommendation,
  RecommendedField,
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
  | "buy_signal_skip";

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
    {
      type: "section",
      text: { type: "mrkdwn", text: brief.snapshot },
    },
    {
      type: "actions",
      elements: [
        {
          type: "button",
          text: { type: "plain_text", text: "Open Account" },
          url: accountUrl,
        },
      ],
    },
  ];

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

  if (brief.usageTrend) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: `*Usage*\n${brief.usageTrend}` },
    });
  }

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
  const companyLabel = d.accountData?.name ?? "(unknown account)";

  const isValidHttpUrl = (u: string | undefined): u is string =>
    typeof u === "string" && /^https?:\/\//i.test(u);

  const text = `Nooks · ${companyLabel} · ${dispositionLabel}`;

  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `${companyLabel} · ${dispositionLabel}`.slice(0, 150),
      },
    },
  ];

  const prospectLines: string[] = [];
  if (d.prospectData?.name) prospectLines.push(`*Name*: ${d.prospectData.name}`);
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

  const accountLines: string[] = [];
  if (d.accountData?.name) accountLines.push(`*Name*: ${d.accountData.name}`);
  if (d.accountData?.accountId)
    accountLines.push(`*Id*: \`${d.accountData.accountId}\``);
  if (accountLines.length > 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*Account*\n${accountLines.join("\n")}`,
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
      text: { type: "plain_text", text: "Recording" },
      url: d.recordingUrl,
    });
  }
  if (isValidHttpUrl(d.transcriptUrl)) {
    linkButtons.push({
      type: "button",
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
