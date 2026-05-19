// Friendly progress phrases shown in a Slack placeholder message while the
// agent is working. Lower priority is overridden when a higher-priority tool
// fires in the same iteration (e.g. if the agent runs sf_get_activities AND
// rogo_query in parallel, the rep sees the rogo phase since that's more
// informative). The "__finalizing" sentinel is used by the caller after the
// agent loop exits, right before the final card is rendered.
const TOOL_PROGRESS: Record<string, { priority: number; text: string }> = {
  sf_find_account: {
    priority: 10,
    text: ":mag: Looking up account in Salesforce…",
  },
  sf_get_account_summary: {
    priority: 20,
    text: ":card_index_dividers: Reading account details…",
  },
  sf_get_activities: {
    priority: 30,
    text: ":clipboard: Checking recent activities…",
  },
  sf_query: { priority: 25, text: ":mag: Querying Salesforce…" },
  sf_get_recent_positive_calls: {
    priority: 30,
    text: ":telephone_receiver: Checking dialer history…",
  },
  gong_get_calls: {
    priority: 40,
    text: ":studio_microphone: Pulling recent Gong calls…",
  },
  rogo_check_customer: {
    priority: 50,
    text: ":bar_chart: Looking up customer in Rogo…",
  },
  rogo_describe: {
    priority: 55,
    text: ":books: Discovering usage schema…",
  },
  rogo_get_usage: {
    priority: 60,
    text: ":chart_with_upwards_trend: Calculating usage metrics…",
  },
  rogo_query: {
    priority: 60,
    text: ":chart_with_upwards_trend: Calculating usage metrics…",
  },
  now: { priority: 5, text: ":hourglass_flowing_sand: Working on it…" },
  __finalizing: {
    priority: 100,
    text: ":package: Packaging up the brief…",
  },
};

export function progressMessageForTools(toolNames: string[]): string | null {
  let best: { priority: number; text: string } | null = null;
  for (const name of toolNames) {
    const entry = TOOL_PROGRESS[name];
    if (!entry) continue;
    if (!best || entry.priority > best.priority) best = entry;
  }
  return best?.text ?? null;
}

export interface ProgressUpdater {
  (toolNames: string[]): Promise<void>;
}

/**
 * Build a Slack progress updater bound to a specific placeholder message.
 * Dedupes (won't repost the same phrase twice) and swallows errors so a
 * Slack rate-limit or 404 never derails the agent run.
 */
export function buildSlackProgressUpdater(args: {
  slack: { chat: { update: (req: any) => Promise<unknown> } };
  channel: string;
  ts: string;
  logTag?: string;
}): ProgressUpdater {
  const tag = args.logTag ?? "[agent-progress]";
  let last = "";
  return async (toolNames: string[]) => {
    const text = progressMessageForTools(toolNames);
    if (!text || text === last) return;
    last = text;
    try {
      await args.slack.chat.update({
        channel: args.channel,
        ts: args.ts,
        text,
      });
    } catch (err: any) {
      console.warn(`${tag} progress update failed:`, err?.message ?? err);
    }
  };
}
