import type { View } from "@slack/types";
import type { UserPrefs } from "../types.js";

export const SUBSCRIPTIONS_CALLBACK_ID = "subscriptions_config";

export const GONG_HOST_VALUE = "gong_realtime";
export const GONG_FIREHOSE_VALUE = "gong_firehose";
export const NOOKS_HOST_VALUE = "nooks_realtime";
export const NOOKS_FIREHOSE_VALUE = "nooks_firehose";
export const CALENDAR_PRE_VALUE = "calendar_pre";
export const CALENDAR_POST_VALUE = "calendar_post";

export const GONG_BLOCK_ID = "gong_block";
export const NOOKS_BLOCK_ID = "nooks_block";
export const CALENDAR_BLOCK_ID = "calendar_block";

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
const NOOKS_HOST_OPTION = {
  value: NOOKS_HOST_VALUE,
  text: { type: "plain_text" as const, text: "DM me after every Nooks call I make" },
  description: { type: "plain_text" as const, text: "Filtered to Connected - Positive outbound calls." },
};
const NOOKS_FIREHOSE_OPTION = {
  value: NOOKS_FIREHOSE_VALUE,
  text: { type: "plain_text" as const, text: "(Admin) DM me every Nooks call across the org" },
  description: { type: "plain_text" as const, text: "Firehose, same filter as above." },
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

type Prefs = Pick<
  UserPrefs,
  | "gongRealtimeEnabled"
  | "gongFirehoseEnabled"
  | "nooksRealtimeEnabled"
  | "nooksFirehoseEnabled"
  | "calendarPreEnabled"
  | "calendarPostEnabled"
>;

export function subscriptionsModalView(prefs: Prefs | null): View {
  const p = prefs ?? {
    gongRealtimeEnabled: false,
    gongFirehoseEnabled: false,
    nooksRealtimeEnabled: false,
    nooksFirehoseEnabled: false,
    calendarPreEnabled: false,
    calendarPostEnabled: false,
  };

  const gongInitial = [
    p.gongRealtimeEnabled ? GONG_HOST_OPTION : null,
    p.gongFirehoseEnabled ? GONG_FIREHOSE_OPTION : null,
  ].filter(Boolean) as Array<typeof GONG_HOST_OPTION>;

  const nooksInitial = [
    p.nooksRealtimeEnabled ? NOOKS_HOST_OPTION : null,
    p.nooksFirehoseEnabled ? NOOKS_FIREHOSE_OPTION : null,
  ].filter(Boolean) as Array<typeof NOOKS_HOST_OPTION>;

  const calendarInitial = [
    p.calendarPreEnabled ? CALENDAR_PRE_OPTION : null,
    p.calendarPostEnabled ? CALENDAR_POST_OPTION : null,
  ].filter(Boolean) as Array<typeof CALENDAR_PRE_OPTION>;

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
        block_id: NOOKS_BLOCK_ID,
        optional: true,
        label: { type: "plain_text", text: "Nooks" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options: nooksInitial.length > 0 ? nooksInitial : undefined,
          options: [NOOKS_HOST_OPTION, NOOKS_FIREHOSE_OPTION],
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
    ],
  };
}
