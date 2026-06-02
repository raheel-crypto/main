import type { KnownBlock } from "@slack/web-api";
import type { GapResult } from "@/lib/arr/recompute";

function usd(n: number): string {
  const sign = n < 0 ? "-" : "";
  return `${sign}$${Math.abs(n).toLocaleString("en-US", { maximumFractionDigits: 0 })}`;
}

export function issueBlocks(gap: GapResult, narrative: string): KnownBlock[] {
  return [
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
    {
      type: "context",
      elements: [
        { type: "mrkdwn", text: `Account: \`${gap.account.Id}\` • @Hook in-thread for detail` },
      ],
    },
  ];
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
