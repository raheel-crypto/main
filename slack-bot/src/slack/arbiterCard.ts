/**
 * Combined arbiter card: probability badge, Red + Blue arguments side by
 * side (numbered claims + per-claim citations), top actions block, and the
 * one-paragraph explanation. Buttons: Open in Salesforce + Mute 7 days
 * (reuses the existing red_team_mute action verb).
 */
import type { KnownBlock } from "@slack/types";
import { feedbackButtonsRow } from "./blocks.js";
import type {
  ArbiterClaim,
  ArbiterConcession,
  ArbiterContradictionPair,
  ArbiterDiscriminatingVariable,
  ArbiterProbeFired,
  ArbiterRecommendedAction,
  ArbiterScenarioBranch,
  ArbiterSynthesis,
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

// ─── v2.1 synthesis renderers ────────────────────────────────────────────────

function discriminatingVariableBlocks(
  dv: ArbiterDiscriminatingVariable
): KnownBlock[] {
  const statusEmoji =
    dv.this_deal_status === "present"
      ? "✅"
      : dv.this_deal_status === "absent"
        ? "❌"
        : "❔";
  return [
    { type: "divider" },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `🎯 *The discriminating variable*\n` +
          `*${truncate(dv.variable, 400)}*\n` +
          `Won cohort: *${dv.won_cohort_pct}%* · Lost cohort: *${dv.lost_cohort_pct}%* · ` +
          `This deal: ${statusEmoji} *${dv.this_deal_status}*`,
      },
    },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `_${truncate(dv.implication, 900)}_`,
        },
      ],
    },
  ];
}

function ifThenDiagnosticBlocks(
  scenarios: ArbiterScenarioBranch[]
): KnownBlock[] {
  if (scenarios.length === 0) return [];
  const leanEmoji = (lean: string): string =>
    lean === "win" ? "🟢" : lean === "loss" ? "🔴" : "🟡";

  const blocks: KnownBlock[] = [
    { type: "divider" },
    {
      type: "section",
      text: { type: "mrkdwn", text: "📅 *Watch for this week*" },
    },
  ];
  for (let i = 0; i < scenarios.length && i < 3; i++) {
    const s = scenarios[i];
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `*${i + 1}.* ${truncate(s.condition, 600)}\n` +
          `   → ${leanEmoji(s.new_lean)} *${s.new_probability}%* (${s.new_lean})`,
      },
    });
    if (s.rationale) {
      blocks.push({
        type: "context",
        elements: [
          { type: "mrkdwn", text: `_${truncate(s.rationale, 900)}_` },
        ],
      });
    }
  }
  return blocks;
}

function resolvedContradictionsBlocks(
  concessions: ArbiterConcession[]
): KnownBlock[] {
  if (concessions.length === 0) return [];
  const blocks: KnownBlock[] = [
    { type: "divider" },
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "*⚖️ What each side gave up in Round 2*",
      },
    },
  ];
  // One section + one context block per concession. Per-item blocks keep
  // each concession well under Slack's 3000-char section limit so the
  // impact line doesn't get cut mid-sentence.
  for (const c of concessions.slice(0, 4)) {
    const sideLabel = c.conceding_team === "red" ? "🔴 Red" : "🔵 Blue";
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text:
          `${sideLabel} conceded on *${c.on_topic}*\n` +
          truncate(c.summary, 1200),
      },
    });
    if (c.impact) {
      blocks.push({
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `_Impact: ${truncate(c.impact, 800)}_`,
          },
        ],
      });
    }
  }
  return blocks;
}

function synthesisNarrativeBlock(narrative: string): KnownBlock[] {
  if (!narrative) return [];
  return [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        // 2800 leaves headroom under Slack's 3000-char section limit so a
        // long synthesizer narrative doesn't get cut mid-sentence.
        text: `> ${truncate(narrative, 2800)}`,
      },
    },
  ];
}

function debateMechanicsContext(verdict: ArbiterVerdict): KnownBlock | null {
  const parts: string[] = [];
  if (verdict.firedTriggers.length > 0) {
    parts.push(`Triggers: ${verdict.firedTriggers.join(", ")}`);
  }
  if (verdict.routeReason) {
    parts.push(`Route: ${verdict.routeReason}`);
  }
  if (verdict.probesFired.length > 0) {
    const probeNames = verdict.probesFired.map((p) => p.probe_type).join(", ");
    parts.push(`Probes: ${probeNames}`);
  }
  if (verdict.contradictionsDetected.length > 0) {
    parts.push(
      `Unaddressed contradictions: ${verdict.contradictionsDetected.length}`
    );
  }
  if (parts.length === 0) return null;
  return {
    type: "context",
    elements: [{ type: "mrkdwn", text: parts.join(" · ") }],
  };
}

function probabilityHeaderText(verdict: ArbiterVerdict): string {
  const lines = [probabilityBadge(verdict.probability, verdict.confidence)];
  // Mechanics line — base rate, MEDDPICC lift, disagreement, round indicator.
  const mech: string[] = [
    `Base rate ${Math.round(verdict.baseRate * 100)}%`,
    `MEDDPICC lift ${(verdict.meddpiccLift * 100).toFixed(1)}pts`,
    `disagreement *${disagreementLabel(verdict.disagreement)}*`,
  ];
  if (verdict.roundsCompleted > 1) {
    const probeCount = verdict.probesFired.length;
    mech.push(
      probeCount > 0
        ? `Round 2 fired (${probeCount} probe${probeCount === 1 ? "" : "s"})`
        : "Round 2 fired"
    );
  }
  lines.push(mech.join(" · "));
  // Show R1 → R2 probability movement when both are present and differ.
  if (
    verdict.probabilityRound1 != null &&
    verdict.probabilityRound2 != null &&
    verdict.probabilityRound1 !== verdict.probabilityRound2
  ) {
    lines.push(
      `_R1: ${verdict.probabilityRound1}% → R2: ${verdict.probabilityRound2}%_`
    );
  }
  return lines.join("\n");
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

  const synthesis: ArbiterSynthesis | null = verdict.synthesis ?? null;

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
        text: probabilityHeaderText(verdict),
      },
    },
  ];

  // Synthesizer narrative — italicized blockquote right under the probability
  // so the rep sees the "what did the debate reveal" line before any team
  // arguments. Falls back to the deterministic explanation if synthesis is
  // unavailable.
  if (synthesis?.narrative) {
    blocks.push(...synthesisNarrativeBlock(synthesis.narrative));
  } else if (verdict.explanation) {
    blocks.push(...synthesisNarrativeBlock(verdict.explanation));
  }

  // Discriminating variable — the single most predictive factor. Skipped if
  // the synthesizer didn't identify one.
  if (synthesis?.discriminating_variable) {
    blocks.push(
      ...discriminatingVariableBlocks(synthesis.discriminating_variable)
    );
  }

  if (verdict.redArgument) {
    blocks.push(...teamBlocks(verdict.redArgument, "🔴 Red Team — Why this loses"));
  }
  if (verdict.blueArgument) {
    blocks.push(...teamBlocks(verdict.blueArgument, "🔵 Blue Team — Why this wins"));
  }

  // Resolved contradictions (Round 2 concessions). Surfaces what each side
  // gave up under probing — the most evidence-of-rigor signal on the card.
  if (synthesis?.resolved_contradictions?.length) {
    blocks.push(...resolvedContradictionsBlocks(synthesis.resolved_contradictions));
  }

  // If/then diagnostic block REPLACES the old topActions when synthesis is
  // available. Without synthesis, fall back to topActions so we don't ship
  // an empty action area.
  if (synthesis?.if_then_diagnostic?.length) {
    blocks.push(...ifThenDiagnosticBlocks(synthesis.if_then_diagnostic));
  } else {
    blocks.push(...topActionsBlocks(verdict.topActions));
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

  const mechanics = debateMechanicsContext(verdict);
  if (mechanics) blocks.push(mechanics);

  // Phase 4 footer: invite reps to keep talking in-thread. The mentions.ts
  // dispatcher detects thread replies in a verdict_conversations row and
  // routes them to the Arbiter Moderator.
  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text:
          "💬 Reply in thread to push back, ask for evidence, or test what-if scenarios.",
      },
    ],
  });

  // Feedback row — captures whether reps actually find the verdict useful.
  blocks.push(feedbackButtonsRow("arbiter", cardId));

  return { blocks, text };
}
