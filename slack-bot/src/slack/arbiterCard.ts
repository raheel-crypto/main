/**
 * Combined arbiter card: probability badge, Red + Blue arguments side by
 * side (numbered claims + per-claim citations), top actions block, and the
 * one-paragraph explanation. Buttons: Open in Salesforce + Mute 7 days
 * (reuses the existing red_team_mute action verb).
 */
import type { KnownBlock } from "@slack/types";
import type {
  ArbiterClaim,
  ArbiterRecommendedAction,
  ArbiterTeamArgument,
  ArbiterVerdict,
  RedTeamTriggerEvent,
} from "../types.js";

const TRIGGER_LABELS: Record<RedTeamTriggerEvent, string> = {
  gong_call: "New Gong call landed",
  daily_sweep: "Daily sweep",
  stage_advance: "Stage advanced",
  manual: "Manual trigger",
};

const PERSONA_LABELS: Record<string, string> = {
  claude_ae: "Anthropic (Claude) AE",
  openai_microsoft_ae: "OpenAI / Microsoft AE",
  hebbia_ae: "Hebbia AE",
  alphasense_ae: "AlphaSense AE",
  internal_build_advocate: "Internal-build advocate",
  cfo_procurement: "CFO / Procurement",
  ciso_persona: "CISO",
  silent_buyer: "Silent buyer",
  default_cro_challenger: "CRO challenger",
  // Blue
  anti_claude_counsel: "Anti-Claude counsel",
  anti_openai_microsoft_counsel: "Anti-OpenAI/Microsoft counsel",
  anti_hebbia_counsel: "Anti-Hebbia counsel",
  anti_alphasense_counsel: "Anti-AlphaSense counsel",
  anti_internal_build_counsel: "Anti-internal-build counsel",
  pricing_justification_counsel: "Pricing-justification counsel",
  compliance_closer: "Compliance closer",
  champion_power_advocate: "Champion-power advocate",
  default_bull_case: "Default bull case",
};

function personaLabel(p: string): string {
  return PERSONA_LABELS[p] ?? p.replace(/_/g, " ");
}

function fmtAmount(amount: number | null): string {
  if (amount == null) return "—";
  return `$${amount.toLocaleString()}`;
}

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1).trimEnd() + "…";
}

function probabilityBadge(p: number, confidence: string): string {
  // Color cue based on probability tertile, NOT win/loss framing.
  const emoji = p >= 60 ? "🟢" : p >= 30 ? "🟡" : "🔴";
  return `${emoji} *${p}%* (${confidence} confidence)`;
}

function disagreementLabel(d: number): string {
  if (d >= 0.6) return "high";
  if (d >= 0.3) return "moderate";
  return "low";
}

function citationLine(c: ArbiterClaim["citations"][number]): string {
  const quote = c.excerpt
    ? truncate(c.excerpt.replace(/\s+/g, " "), 200)
    : "";
  const ref = truncate(c.reference, 100);
  return quote ? `• "${quote}" — ${ref}` : `• ${ref}`;
}

function claimBlocks(claim: ArbiterClaim, index: number): KnownBlock[] {
  const blocks: KnownBlock[] = [];
  const lines = [`*${index}.* ${truncate(claim.statement, 1500)}`];
  if (claim.pattern_match) {
    lines.push(`   _Pattern: ${truncate(claim.pattern_match, 200)}_`);
  }
  blocks.push({
    type: "section",
    text: { type: "mrkdwn", text: lines.join("\n") },
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

function teamBlocks(
  arg: ArbiterTeamArgument,
  heading: string
): KnownBlock[] {
  const blocks: KnownBlock[] = [
    { type: "divider" },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `*${heading} — ${personaLabel(arg.persona_id)}*\n` +
          `_${truncate(arg.headline, 200)}_`,
      },
    },
  ];
  for (let i = 0; i < arg.claims.length; i++) {
    blocks.push(...claimBlocks(arg.claims[i], i + 1));
  }
  return blocks;
}

function topActionsBlocks(actions: string[]): KnownBlock[] {
  if (actions.length === 0) return [];
  const lines = ["*Top actions this week:*"];
  for (const a of actions) {
    lines.push(`• ${truncate(a, 300)}`);
  }
  return [
    { type: "divider" },
    { type: "section", text: { type: "mrkdwn", text: lines.join("\n") } },
  ];
}

export interface ArbiterCardOpportunity {
  id: string;
  name: string;
  stageName: string;
  amount: number | null;
  accountName: string;
}

export interface ArbiterCardArgs {
  cardId: string;
  opportunity: ArbiterCardOpportunity;
  ownerSlackUserId: string;
  triggerEvent: RedTeamTriggerEvent;
  verdict: ArbiterVerdict;
  instanceUrl: string;
}

export function arbiterCard(args: ArbiterCardArgs): {
  blocks: KnownBlock[];
  text: string;
} {
  const { opportunity, ownerSlackUserId, triggerEvent, verdict, cardId, instanceUrl } = args;
  const triggerLabel = TRIGGER_LABELS[triggerEvent] ?? triggerEvent;
  const text = `Deal review · ${opportunity.name} · ${verdict.probability}%`;

  const blocks: KnownBlock[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `⚖️ Deal review · ${truncate(opportunity.name, 120)}`,
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
        text:
          `${probabilityBadge(verdict.probability, verdict.confidence)}\n` +
          `Base rate ${Math.round(verdict.baseRate * 100)}% · MEDDPICC lift ${(verdict.meddpiccLift * 100).toFixed(1)}pts · ` +
          `Red↔Blue disagreement: *${disagreementLabel(verdict.disagreement)}*` +
          (verdict.roundsCompleted > 1 ? ` · Round 2 fired` : ""),
      },
    },
  ];

  if (verdict.redArgument) {
    blocks.push(...teamBlocks(verdict.redArgument, "🔴 Red Team — Why this loses"));
  }
  if (verdict.blueArgument) {
    blocks.push(...teamBlocks(verdict.blueArgument, "🔵 Blue Team — Why this wins"));
  }

  blocks.push(...topActionsBlocks(verdict.topActions));

  if (verdict.explanation) {
    blocks.push({ type: "divider" });
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `> ${truncate(verdict.explanation, 800)}`,
      },
    });
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

  if (verdict.firedTriggers.length > 0) {
    blocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `Triggers: ${verdict.firedTriggers.join(", ")} · Route: ${verdict.routeReason || "default"}`,
        },
      ],
    });
  }

  return { blocks, text };
}
