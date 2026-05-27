import type { KnownBlock } from "@slack/types";
import type {
  RedTeamPersonaArgument,
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

function personaSection(arg: RedTeamPersonaArgument): KnownBlock[] {
  const blocks: KnownBlock[] = [];
  const header = `*${personaLabel(arg.persona)}* — ${riskBadge(arg.riskScore)}`;
  // Slack section mrkdwn cap is 3000 chars. Leave headroom for the header
  // + italic-marker formatting, then give the claim body as much room as
  // possible. 600 was leaving 80%+ of the available space empty.
  const claim = `_${truncate(arg.headline, 140)}_\n${truncate(arg.claim, 2700)}`;
  blocks.push({
    type: "section",
    text: { type: "mrkdwn", text: `${header}\n${claim}` },
  });
  const citationLines: string[] = [];
  for (const c of arg.citations.slice(0, 4)) {
    const quote = truncate(c.quote.replace(/\s+/g, " "), 200);
    const labelPart = c.sourceUrl
      ? `<${c.sourceUrl}|${truncate(c.sourceLabel, 80)}>`
      : truncate(c.sourceLabel, 80);
    citationLines.push(`• "${quote}" — ${labelPart}`);
  }
  if (citationLines.length > 0) {
    blocks.push({
      type: "context",
      elements: [
        { type: "mrkdwn", text: citationLines.join("\n") },
      ],
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
