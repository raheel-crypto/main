import type { View } from "@slack/types";
import type { UserPrefs } from "../types.js";

export const SUBSCRIPTIONS_CALLBACK_ID = "subscriptions_config";

export const GONG_HOST_VALUE = "gong_realtime";
export const GONG_FIREHOSE_VALUE = "gong_firehose";
export const NOOKS_HOST_POSITIVE_VALUE = "nooks_host_positive";
export const NOOKS_HOST_NEUTRAL_VALUE = "nooks_host_neutral";
export const NOOKS_HOST_NEGATIVE_VALUE = "nooks_host_negative";
export const NOOKS_FIREHOSE_POSITIVE_VALUE = "nooks_firehose_positive";
export const NOOKS_FIREHOSE_NEUTRAL_VALUE = "nooks_firehose_neutral";
export const NOOKS_FIREHOSE_NEGATIVE_VALUE = "nooks_firehose_negative";
export const CALENDAR_PRE_VALUE = "calendar_pre";
export const CALENDAR_POST_VALUE = "calendar_post";
export const RED_TEAM_VALUE = "red_team_enabled";

export const GONG_BLOCK_ID = "gong_block";
export const NOOKS_HOST_BLOCK_ID = "nooks_host_block";
export const NOOKS_FIREHOSE_BLOCK_ID = "nooks_firehose_block";
export const CALENDAR_BLOCK_ID = "calendar_block";
export const RED_TEAM_BLOCK_ID = "red_team_block";

const GONG_HOST_OPTION = {
  value: GONG_HOST_VALUE,
  text: { type: "plain_text" as const, text: "DM me a digest after every Gong call I host" },
  description: { type: "plain_text" as const, text: "Card lands seconds after the call wraps." },
};
const GONG_FIREHOSE_OPTION = {
  value: GONG_FIREHOSE_VALUE,
  text: { type: "plain_text" as const, text: "(Admin) DM me every Gong call across the org" },
  description: { type: "plain_text" as const, text: "Firehose. Use for live monitoring." },
};

const NOOKS_HOST_POSITIVE_OPTION = {
  value: NOOKS_HOST_POSITIVE_VALUE,
  text: { type: "plain_text" as const, text: "Positive — outbound calls I marked Connected - Positive" },
  description: { type: "plain_text" as const, text: "The good ones — buying signals, expansion, validation." },
};
const NOOKS_HOST_NEUTRAL_OPTION = {
  value: NOOKS_HOST_NEUTRAL_VALUE,
  text: { type: "plain_text" as const, text: "Neutral — Connected - Neutral" },
  description: { type: "plain_text" as const, text: "Conversations that didn't push the deal either way." },
};
const NOOKS_HOST_NEGATIVE_OPTION = {
  value: NOOKS_HOST_NEGATIVE_VALUE,
  text: { type: "plain_text" as const, text: "Negative — Connected - Negative" },
  description: { type: "plain_text" as const, text: "Objections, churn signals, deals at risk." },
};
const NOOKS_FIREHOSE_POSITIVE_OPTION = {
  value: NOOKS_FIREHOSE_POSITIVE_VALUE,
  text: { type: "plain_text" as const, text: "Positive — every org-wide Connected - Positive" },
  description: { type: "plain_text" as const, text: "Admin firehose for positive dialer calls." },
};
const NOOKS_FIREHOSE_NEUTRAL_OPTION = {
  value: NOOKS_FIREHOSE_NEUTRAL_VALUE,
  text: { type: "plain_text" as const, text: "Neutral — every org-wide Connected - Neutral" },
  description: { type: "plain_text" as const, text: "Admin firehose for neutral dialer calls." },
};
const NOOKS_FIREHOSE_NEGATIVE_OPTION = {
  value: NOOKS_FIREHOSE_NEGATIVE_VALUE,
  text: { type: "plain_text" as const, text: "Negative — every org-wide Connected - Negative" },
  description: { type: "plain_text" as const, text: "Admin firehose for negative dialer calls." },
};

const CALENDAR_PRE_OPTION = {
  value: CALENDAR_PRE_VALUE,
  text: { type: "plain_text" as const, text: "DM me a brief 5-10 min before each customer meeting" },
  description: { type: "plain_text" as const, text: "Only fires when an external attendee is on the invite." },
};
const CALENDAR_POST_OPTION = {
  value: CALENDAR_POST_VALUE,
  text: { type: "plain_text" as const, text: "DM me a SF-update card ~5 min after each customer meeting ends" },
  description: { type: "plain_text" as const, text: "Surfaces missing contacts + quick opp updates." },
};

const RED_TEAM_OPTION = {
  value: RED_TEAM_VALUE,
  text: {
    type: "plain_text" as const,
    text: "Send me adversary intel on my advanced-stage deals",
  },
  description: {
    type: "plain_text" as const,
    text:
      "Triggers after new Gong calls and once daily. Personas (competitor AE, CFO, CISO) call out risks with quotes from prior dead deals.",
  },
};

type Prefs = Pick<
  UserPrefs,
  | "gongRealtimeEnabled"
  | "gongFirehoseEnabled"
  | "nooksHostPositive"
  | "nooksHostNeutral"
  | "nooksHostNegative"
  | "nooksFirehosePositive"
  | "nooksFirehoseNeutral"
  | "nooksFirehoseNegative"
  | "calendarPreEnabled"
  | "calendarPostEnabled"
  | "redTeamEnabled"
>;

export function subscriptionsModalView(prefs: Prefs | null): View {
  const p =
    prefs ?? {
      gongRealtimeEnabled: false,
      gongFirehoseEnabled: false,
      nooksHostPositive: false,
      nooksHostNeutral: false,
      nooksHostNegative: false,
      nooksFirehosePositive: false,
      nooksFirehoseNeutral: false,
      nooksFirehoseNegative: false,
      calendarPreEnabled: false,
      calendarPostEnabled: false,
      redTeamEnabled: false,
    };

  const gongInitial = [
    p.gongRealtimeEnabled ? GONG_HOST_OPTION : null,
    p.gongFirehoseEnabled ? GONG_FIREHOSE_OPTION : null,
  ].filter(Boolean) as Array<typeof GONG_HOST_OPTION>;

  const nooksHostInitial = [
    p.nooksHostPositive ? NOOKS_HOST_POSITIVE_OPTION : null,
    p.nooksHostNeutral ? NOOKS_HOST_NEUTRAL_OPTION : null,
    p.nooksHostNegative ? NOOKS_HOST_NEGATIVE_OPTION : null,
  ].filter(Boolean) as Array<typeof NOOKS_HOST_POSITIVE_OPTION>;

  const nooksFirehoseInitial = [
    p.nooksFirehosePositive ? NOOKS_FIREHOSE_POSITIVE_OPTION : null,
    p.nooksFirehoseNeutral ? NOOKS_FIREHOSE_NEUTRAL_OPTION : null,
    p.nooksFirehoseNegative ? NOOKS_FIREHOSE_NEGATIVE_OPTION : null,
  ].filter(Boolean) as Array<typeof NOOKS_FIREHOSE_POSITIVE_OPTION>;

  const calendarInitial = [
    p.calendarPreEnabled ? CALENDAR_PRE_OPTION : null,
    p.calendarPostEnabled ? CALENDAR_POST_OPTION : null,
  ].filter(Boolean) as Array<typeof CALENDAR_PRE_OPTION>;

  const redTeamInitial = [p.redTeamEnabled ? RED_TEAM_OPTION : null].filter(
    Boolean
  ) as Array<typeof RED_TEAM_OPTION>;

  return {
    type: "modal",
    callback_id: SUBSCRIPTIONS_CALLBACK_ID,
    title: { type: "plain_text", text: "Real-time subscriptions" },
    submit: { type: "plain_text", text: "Save" },
    close: { type: "plain_text", text: "Cancel" },
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: "Choose which real-time DMs you want. These fire when an event happens, separate from your daily standup digest.",
        },
      },
      {
        type: "input",
        block_id: GONG_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "Gong" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options: gongInitial.length > 0 ? gongInitial : undefined,
          options: [GONG_HOST_OPTION, GONG_FIREHOSE_OPTION],
        },
      },
      {
        type: "input",
        block_id: NOOKS_HOST_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "Nooks — my dialer calls" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options:
            nooksHostInitial.length > 0 ? nooksHostInitial : undefined,
          options: [
            NOOKS_HOST_POSITIVE_OPTION,
            NOOKS_HOST_NEUTRAL_OPTION,
            NOOKS_HOST_NEGATIVE_OPTION,
          ],
        },
      },
      {
        type: "input",
        block_id: NOOKS_FIREHOSE_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "(Admin) Nooks firehose" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options:
            nooksFirehoseInitial.length > 0 ? nooksFirehoseInitial : undefined,
          options: [
            NOOKS_FIREHOSE_POSITIVE_OPTION,
            NOOKS_FIREHOSE_NEUTRAL_OPTION,
            NOOKS_FIREHOSE_NEGATIVE_OPTION,
          ],
        },
      },
      {
        type: "input",
        block_id: CALENDAR_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "Calendar" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options:
            calendarInitial.length > 0 ? calendarInitial : undefined,
          options: [CALENDAR_PRE_OPTION, CALENDAR_POST_OPTION],
        },
      },
      {
        type: "input",
        block_id: RED_TEAM_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "Red Team" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options:
            redTeamInitial.length > 0 ? redTeamInitial : undefined,
          options: [RED_TEAM_OPTION],
        },
      },
    ],
  };
}
