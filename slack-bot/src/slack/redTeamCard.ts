import type { KnownBlock } from "@slack/types";
import type {
  RedTeamCitation,
  RedTeamClaim,
  RedTeamPersonaArgument,
  RedTeamRecommendedAction,
  RedTeamRunResult,
  RedTeamTriggerEvent,
} from "../types.js";

const PERSONA_LABELS: Record<string, string> = {
  claude_ae: "Anthropic (Claude) AE",
  competitor_ae: "Competitor AE",
  openai_ae: "OpenAI AE",
  cfo_procurement: "Their CFO / Procurement",
  ciso_persona: "Their CISO",
  internal_build_advocate: "Their internal-build advocate",
  procurement: "Procurement",
  legal: "Legal",
};

const TRIGGER_LABELS: Record<RedTeamTriggerEvent, string> = {
  gong_call: "New Gong call landed",
  daily_sweep: "Daily sweep",
  stage_advance: "Stage advanced",
  manual: "Manual trigger",
};

function personaLabel(persona: string): string {
  return (
    PERSONA_LABELS[persona] ??
    persona
      .replace(/_/g, " ")
      .replace(/\b\w/g, (c) => c.toUpperCase())
  );
}

function riskBadge(score: number): string {
  if (score >= 0.7) return "🔴 High";
  if (score >= 0.4) return "🟠 Medium";
  return "🟡 Low";
}

function fmtAmount(amount: number | null): string {
  if (amount == null) return "—";
  return `$${amount.toLocaleString()}`;
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1).trimEnd() + "…";
}

export interface RedTeamCardOpportunity {
  id: string;
  name: string;
  stageName: string;
  amount: number | null;
  accountName: string;
}

export interface RedTeamCardArgs {
  cardId: string;
  opportunity: RedTeamCardOpportunity;
  ownerSlackUserId: string;
  triggerEvent: RedTeamTriggerEvent;
  result: RedTeamRunResult;
  instanceUrl: string;
}

function citationLine(c: RedTeamCitation): string {
  const quote = truncate(c.quote.replace(/\s+/g, " "), 220);
  const label = truncate(c.sourceLabel, 100);
  const labelPart = c.sourceUrl ? `<${c.sourceUrl}|${label}>` : label;
  return `• "${quote}" — ${labelPart}`;
}

function claimBlocks(claim: RedTeamClaim, index: number): KnownBlock[] {
  const blocks: KnownBlock[] = [];
  const statementLines = [`*${index}.* ${truncate(claim.statement, 1500)}`];
  if (claim.patternMatch) {
    statementLines.push(`   _Pattern: ${truncate(claim.patternMatch, 200)}_`);
  }
  blocks.push({
    type: "section",
    text: { type: "mrkdwn", text: statementLines.join("\n") },
  });
  const citationLines = claim.citations.slice(0, 4).map(citationLine);
  if (citationLines.length > 0) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: citationLines.join("\n") }],
    });
  }
  return blocks;
}

function recommendedActionLine(a: RedTeamRecommendedAction): string {
  const meta = [a.ownerRole, a.byDate, a.expectedSignal && `signal: ${a.expectedSignal}`]
    .filter(Boolean)
    .join(" · ");
  return meta
    ? `• ${truncate(a.action, 220)}\n   _${truncate(meta, 240)}_`
    : `• ${truncate(a.action, 220)}`;
}

function personaSection(arg: RedTeamPersonaArgument): KnownBlock[] {
  const blocks: KnownBlock[] = [];
  blocks.push({
    type: "section",
    text: {
      type: "mrkdwn",
      text:
        `*${personaLabel(arg.persona)}* — ${riskBadge(arg.riskScore)}\n` +
        `_${truncate(arg.headline, 200)}_`,
    },
  });
  for (let i = 0; i < arg.claims.length; i++) {
    blocks.push(...claimBlocks(arg.claims[i], i + 1));
  }
  if (arg.recommendedActions.length > 0) {
    const lines = ["*Recommended actions this week:*"];
    for (const a of arg.recommendedActions) {
      lines.push(recommendedActionLine(a));
    }
    blocks.push({
      type: "section",
      text: { type: "mrkdwn", text: lines.join("\n") },
    });
  }
  return blocks;
}

export function redTeamCard(args: RedTeamCardArgs): {
  blocks: KnownBlock[];
  text: string;
} {
  const { opportunity, ownerSlackUserId, triggerEvent, result, cardId, instanceUrl } =
    args;
  const triggerLabel = TRIGGER_LABELS[triggerEvent] ?? triggerEvent;
  const text = `Red Team · ${opportunity.name}`;

  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `🟥 Red Team · ${truncate(opportunity.name, 120)}`,
      },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: [
            opportunity.stageName,
            fmtAmount(opportunity.amount),
            `Owner: <@${ownerSlackUserId}>`,
            `Triggered: ${triggerLabel}`,
          ].join(" · "),
        },
      ],
    },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "*Why we might lose this deal:*",
      },
    },
    { type: "divider" },
  ];

  const personas = result.personasInvoked.slice(0, 2);
  if (personas.length === 0) {
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: "_No persona arguments fired. Triggers: " +
          (result.firedTriggers.length > 0
            ? result.firedTriggers.join(", ")
            : "none") +
          "_",
      },
    });
  } else {
    for (let i = 0; i < personas.length; i++) {
      blocks.push(...personaSection(personas[i]));
      if (i < personas.length - 1) blocks.push({ type: "divider" });
    }
  }

  const sfUrl = `${instanceUrl.replace(/\/+$/, "")}/${opportunity.id}`;
  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        action_id: `linkout:sf:${opportunity.id}`,
        text: { type: "plain_text", text: "Open in Salesforce" },
        url: sfUrl,
      },
      {
        type: "button",
        action_id: `red_team_mute:${cardId}:${opportunity.id}`,
        text: { type: "plain_text", text: "Mute this opp for 7 days" },
        style: "danger",
      },
    ],
  });

  if (result.firedTriggers.length > 0) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `Triggers: ${result.firedTriggers.join(", ")}`,
        },
      ],
    });
  }

  return { blocks, text };
}
