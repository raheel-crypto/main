import type { KnownBlock, View } from "@slack/types";
import { TZ_OPTIONS } from "../constants.js";
import type {
  BriefPayload,
  BriefSuggestion,
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
  | "brief_pick_account";

const VALID_VERBS: ActionVerb[] = [
  "accept",
  "edit",
  "skip",
  "apply_all",
  "brief_apply",
  "brief_skip",
  "brief_apply_all",
  "brief_pick_account",
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
