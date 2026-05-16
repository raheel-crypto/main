import type { View } from "@slack/types";
import type { UserPrefs } from "../types.js";

export const SUBSCRIPTIONS_CALLBACK_ID = "subscriptions_config";
export const GONG_REALTIME_OPTION_VALUE = "gong_realtime";

const GONG_OPTION = {
  value: GONG_REALTIME_OPTION_VALUE,
  text: {
    type: "plain_text" as const,
    text: "DM me a digest after every Gong call I host",
  },
  description: {
    type: "plain_text" as const,
    text: "Card lands seconds after the call wraps.",
  },
};

export function subscriptionsModalView(
  prefs: Pick<UserPrefs, "gongRealtimeEnabled"> | null
): View {
  const gongOn = prefs?.gongRealtimeEnabled ?? false;
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
        block_id: "gong_block",
        optional: true,
        label: { type: "plain_text", text: "Gong" },
        element: {
          type: "checkboxes",
          action_id: "value",
          initial_options: gongOn ? [GONG_OPTION] : undefined,
          options: [GONG_OPTION],
        },
      },
    ],
  };
}
