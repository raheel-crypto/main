import type { KnownBlock, ActionsBlock, Button } from "@slack/web-api";
import type { GapResult } from "@/lib/arr/recompute";

function usd(n: number): string {
  const sign = n < 0 ? "-" : "";
  return `${sign}$${Math.abs(n).toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

export interface IssueButton {
  actionId: number;
  buttonText: string;
  buttonStyle?: "primary" | "danger";
  confirmText: string;
}

export function issueBlocks(
  gap: GapResult,
  narrative: string,
  buttons: IssueButton[] = [],
): KnownBlock[] {
  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: { type: "plain_text", text: `ARR gap: ${gap.account.Name}` },
    },
    {
      type: "section",
      fields: [
        { type: "mrkdwn", text: `*Stored*\n${usd(gap.storedArr)}` },
        { type: "mrkdwn", text: `*Expected*\n${usd(gap.result.expectedArr)}` },
        { type: "mrkdwn", text: `*Gap*\n${usd(gap.gap)}` },
        { type: "mrkdwn", text: `*Status*\n${gap.account.Account_Status__c}` },
      ],
    },
    { type: "section", text: { type: "mrkdwn", text: narrative } },
  ];

  if (buttons.length > 0) {
    const actionsBlock: ActionsBlock = {
      type: "actions",
      block_id: "hook_actions",
      elements: buttons.map<Button>((b) => ({
        type: "button",
        action_id: `apply_action:${b.actionId}`,
        text: { type: "plain_text", text: b.buttonText },
        ...(b.buttonStyle ? { style: b.buttonStyle } : {}),
        value: String(b.actionId),
        confirm: {
          title: { type: "plain_text", text: "Confirm" },
          text: { type: "mrkdwn", text: b.confirmText },
          confirm: { type: "plain_text", text: "Apply" },
          deny: { type: "plain_text", text: "Cancel" },
        },
      })),
    };
    blocks.push(actionsBlock);
  }

  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text: `Account: \`${gap.account.Id}\` • @Hook in-thread for detail`,
      },
    ],
  });

  return blocks;
}

export function appliedActionBlocks(
  originalBlocks: KnownBlock[],
  appliedBy: string,
  buttonText: string,
  actionId: number,
  result: { ok: boolean; error?: string },
): KnownBlock[] {
  // Strip the actions block and replace with a context line.
  const withoutActions = originalBlocks.filter(
    (b) => b.type !== "actions",
  ) as KnownBlock[];

  const stamp = new Date().toLocaleString("en-US", {
    timeZone: "America/New_York",
    hour: "numeric",
    minute: "2-digit",
    month: "short",
    day: "numeric",
  });

  const summary = result.ok
    ? `✓ *${buttonText}* applied by ${appliedBy} at ${stamp} ET (action #${actionId})`
    : `⚠ *${buttonText}* attempted by ${appliedBy} at ${stamp} ET — failed: ${result.error ?? "unknown error"} (action #${actionId})`;

  withoutActions.push({
    type: "section",
    text: { type: "mrkdwn", text: summary },
  });

  return withoutActions;
}

export interface WeeklyDigestInput {
  totalAccounts: number;
  matchCount: number;
  gaps: GapResult[];
  newSinceLastWeek: number;
  resolvedSinceLastWeek: number;
}

export function weeklyDigestBlocks(input: WeeklyDigestInput): KnownBlock[] {
  const headerText =
    input.gaps.length === 0
      ? `All clear — ${input.matchCount}/${input.totalAccounts} accounts reconcile`
      : `${input.gaps.length} issue(s) found — ${input.matchCount}/${input.totalAccounts} reconcile`;

  const blocks: KnownBlock[] = [
    { type: "header", text: { type: "plain_text", text: "Hook weekly ARR run" } },
    { type: "section", text: { type: "mrkdwn", text: `*${headerText}*` } },
  ];

  if (input.gaps.length > 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: input.gaps
          .map((g) => `• *${g.account.Name}* — stored ${usd(g.storedArr)} / expected ${usd(g.result.expectedArr)} (gap ${usd(g.gap)})`)
          .join("\n"),
      },
    });
  }

  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text: `Δ vs last week: +${input.newSinceLastWeek} new, -${input.resolvedSinceLastWeek} resolved`,
      },
    ],
  });

  return blocks;
}
