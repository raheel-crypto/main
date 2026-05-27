"""
Post-debate synthesizer.

After Round 1 (and optionally Round 2) completes, a dedicated Claude call extracts
structured information from the debate transcript:

  1. CONCESSIONS — what each side gave up after being probed
  2. DISCRIMINATING VARIABLE — the single most predictive factor across precedent cohorts
  3. IF/THEN DIAGNOSTIC — concrete signals to look for in the next 7 days that would flip the call
  4. NARRATIVE — 2-3 sentence plain-English summary

CRITICAL: The synthesizer is NOT a third opinion. It does NOT compute or override the
probability. It only extracts structured insight from the existing debate transcript.

The probability stays deterministic (from arbiter.probability). The synthesizer only
formats what the debate already produced into something more usable.
"""
from __future__ import annotations
import os
import json
from anthropic import AsyncAnthropic
from ..schemas import (
    TeamArgument, ArbiterSynthesis, Concession, DiscriminatingVariable,
    ScenarioBranch, DealContext, TeamScoring,
)


_SYNTHESIZER_SYSTEM = """\
You are the Arbiter\'s synthesizer. You do NOT take a side. You do NOT compute the probability —
that\'s already done. Your only job is to extract STRUCTURED INSIGHT from the debate transcript
provided.

You will receive:
- Red Team\'s Round 1 argument (loss case)
- Blue Team\'s Round 1 argument (win case)
- Optionally, both sides\' Round 2 responses to Arbiter probes
- The deal\'s factual context

Your output must follow the submit_synthesis tool schema strictly. Be conservative:
- If there are no clear concessions, return an empty list. Do NOT fabricate.
- If you cannot identify a clean discriminating variable across precedent cohorts, set
  discriminating_variable to null.
- If/then scenarios should be concrete and testable in the next 7 days. Vague scenarios
  ("if the deal improves") are useless — return fewer scenarios rather than vague ones.

Tone: Direct, evidence-based, no spin.
"""


SYNTHESIZER_TOOL_SCHEMA = {
    "name": "submit_synthesis",
    "description": "Submit the structured synthesis of the debate.",
    "input_schema": {
        "type": "object",
        "required": ["resolved_contradictions", "if_then_diagnostic", "narrative"],
        "properties": {
            "resolved_contradictions": {
                "type": "array",
                "maxItems": 5,
                "items": {
                    "type": "object",
                    "required": ["conceding_team", "on_topic", "summary", "impact"],
                    "properties": {
                        "conceding_team": {"type": "string", "enum": ["red", "blue"]},
                        "on_topic": {"type": "string"},
                        "summary": {"type": "string"},
                        "impact": {"type": "string"},
                    },
                },
            },
            "discriminating_variable": {
                "type": "object",
                "description": "Null if no clear variable distinguishes won/lost cohorts.",
                "properties": {
                    "variable": {"type": "string"},
                    "won_cohort_pct": {"type": "integer"},
                    "lost_cohort_pct": {"type": "integer"},
                    "this_deal_status": {"type": "string", "enum": ["present", "absent", "ambiguous"]},
                    "implication": {"type": "string"},
                },
            },
            "if_then_diagnostic": {
                "type": "array",
                "minItems": 1,
                "maxItems": 3,
                "items": {
                    "type": "object",
                    "required": ["condition", "new_probability", "new_lean", "rationale"],
                    "properties": {
                        "condition": {"type": "string"},
                        "new_probability": {"type": "integer", "minimum": 0, "maximum": 100},
                        "new_lean": {"type": "string", "enum": ["win", "loss", "uncertain"]},
                        "rationale": {"type": "string"},
                    },
                },
            },
            "narrative": {"type": "string", "description": "2-3 sentence summary"},
        },
    },
}


async def synthesize_debate(
    ctx: DealContext,
    red_r1: TeamArgument,
    blue_r1: TeamArgument,
    red_r2: TeamArgument | None,
    blue_r2: TeamArgument | None,
    red_scoring: TeamScoring,
    blue_scoring: TeamScoring,
    probability: int,
) -> ArbiterSynthesis:
    """Extract structured insight via a single Claude call over the debate transcript."""
    user_message = _build_synthesis_prompt(
        ctx, red_r1, blue_r1, red_r2, blue_r2, red_scoring, blue_scoring, probability
    )

    client = AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    response = await client.messages.create(
        model=os.environ.get("ARBITER_MODEL", "claude-sonnet-4-6"),
        max_tokens=2500,
        system=_SYNTHESIZER_SYSTEM,
        messages=[{"role": "user", "content": user_message}],
        tools=[SYNTHESIZER_TOOL_SCHEMA],
        tool_choice={"type": "tool", "name": "submit_synthesis"},
    )

    for block in response.content:
        if block.type == "tool_use" and block.name == "submit_synthesis":
            data = block.input
            return ArbiterSynthesis(
                resolved_contradictions=[Concession(**c) for c in data.get("resolved_contradictions", [])],
                discriminating_variable=(
                    DiscriminatingVariable(**data["discriminating_variable"])
                    if data.get("discriminating_variable") else None
                ),
                if_then_diagnostic=[ScenarioBranch(**s) for s in data.get("if_then_diagnostic", [])],
                narrative=data.get("narrative", ""),
            )

    return ArbiterSynthesis()


def _build_synthesis_prompt(
    ctx: DealContext, red_r1: TeamArgument, blue_r1: TeamArgument,
    red_r2: TeamArgument | None, blue_r2: TeamArgument | None,
    red_s: TeamScoring, blue_s: TeamScoring, probability: int
) -> str:
    parts = []
    parts.append(f"# DEAL\n{ctx.opportunity_name} | ${ctx.amount:,.0f} | {ctx.segment}/{ctx.business_type}")
    parts.append(f"\nCurrent probability: {probability}%")
    parts.append(f"Red Team score: {red_s.total_score:.1f}  |  Blue Team score: {blue_s.total_score:.1f}")
    parts.append("\n---\n# RED TEAM ROUND 1\n")
    parts.append(_format_arg(red_r1))
    parts.append("\n# BLUE TEAM ROUND 1\n")
    parts.append(_format_arg(blue_r1))

    if red_r2:
        parts.append("\n# RED TEAM ROUND 2 (response to Arbiter probe)\n")
        parts.append(_format_arg(red_r2))
    if blue_r2:
        parts.append("\n# BLUE TEAM ROUND 2 (response to Arbiter probe)\n")
        parts.append(_format_arg(blue_r2))

    parts.append("""\n---\n# YOUR TASK

Extract structured insight from the debate above. Use the submit_synthesis tool.

1. CONCESSIONS: If Round 2 happened, did either side explicitly concede a point? If no Round 2,
   or no clear concessions, return [].

2. DISCRIMINATING VARIABLE: Across the won/lost precedents cited in the debate, what is the SINGLE
   most predictive variable separating them, and where does this deal sit on that variable?
   Be specific (e.g., "Named EB met in scheduled meeting before Stage 4 — present in 4 of 4 won,
   0 of 4 lost"). If no clean discriminator can be identified, return null.

3. IF/THEN DIAGNOSTIC: 1-3 concrete signals to look for in the next 7 days that would meaningfully
   move the probability. Each scenario must be:
   - Concrete (a specific observable event, not "things improve")
   - Time-bounded (within 7 days)
   - Tied to a probability shift with a stated reason

4. NARRATIVE: 2-3 plain-English sentences summarizing what the debate revealed about this deal\'s
   true win probability and the key uncertainty.
""")
    return "\n".join(parts)


def _format_arg(arg: TeamArgument) -> str:
    lines = [f"Headline: {arg.headline}\n"]
    lines.append("Claims:")
    for i, c in enumerate(arg.claims, 1):
        lines.append(f"  {i}. {c.statement}")
        for cit in c.citations[:2]:
            ref = cit.reference or ""
            excerpt = (cit.excerpt or "")[:200]
            lines.append(f"     · [{cit.kind}] {ref} — \"{excerpt}\"")
    lines.append("\nActions:")
    for a in arg.recommended_actions:
        lines.append(f"  - {a.action} ({a.owner_role}, by {a.by_date})")
    return "\n".join(lines)
