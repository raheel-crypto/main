"""
Multi-turn arbiter logic — when to fire Round 2 and how to run it.

Upgraded from v1: now fires Round 2 on substantive contradictions even when
surface disagreement is low.
"""
from __future__ import annotations
import asyncio
from typing import Tuple, List
from ..schemas import DealContext, TeamArgument, TeamScoring, ContradictionPair, ProbeFired
from ..personas.loader import build_red_system_prompt, build_blue_system_prompt
from ..agents.claude_client import call_agent
from .contradiction_detector import needs_substantive_followup
from .templates import select_probes_for_team, ROUND_2_CONSTRAINT
from .scorer import score_team_argument


def evaluate_followup_need(
    red: TeamArgument, blue: TeamArgument,
    red_scoring: TeamScoring, blue_scoring: TeamScoring,
    disagreement: float,
) -> Tuple[bool, List[ContradictionPair]]:
    """
    Returns (should_fire_round_2, list_of_contradictions_detected).

    Fires Round 2 when ANY of:
      - Surface disagreement > 0.5
      - 2+ substantive contradictions where teams talked past each other
      - 1+ contradiction on a high-stakes topic (EB authority, timeline, score validity)
      - Either side\'s avg evidence quality < 6/13
    """
    # Check substantive contradictions first
    should_fire_substantive, contradictions = needs_substantive_followup(red, blue, disagreement)
    if should_fire_substantive:
        return True, contradictions

    # Fall back to evidence-quality trigger
    if red_scoring.avg_quality < 6 or blue_scoring.avg_quality < 6:
        return True, contradictions

    return False, contradictions


async def run_round_2(
    ctx: DealContext,
    red_arg: TeamArgument,
    blue_arg: TeamArgument,
    red_scoring: TeamScoring,
    blue_scoring: TeamScoring,
    contradictions: List[ContradictionPair],
) -> Tuple[TeamArgument, TeamArgument, List[ProbeFired]]:
    """
    Run a single follow-up round in parallel. Each team sees ONLY its own follow-up
    question — never the opponent\'s. Returns updated arguments + probes fired.
    """
    # Select probes for each team
    red_probe = select_probes_for_team(
        my_team="red",
        my_scoring=red_scoring,
        opponent_scoring=blue_scoring,
        opponent_arg=blue_arg,
        contradictions=contradictions,
    )
    blue_probe = select_probes_for_team(
        my_team="blue",
        my_scoring=blue_scoring,
        opponent_scoring=red_scoring,
        opponent_arg=red_arg,
        contradictions=contradictions,
    )

    probes_fired: List[ProbeFired] = []
    tasks = []

    if red_probe:
        probes_fired.append(red_probe)
        tasks.append(_run_followup_red(ctx, red_arg, red_probe.question))
    else:
        async def keep_red(): return red_arg
        tasks.append(keep_red())

    if blue_probe:
        probes_fired.append(blue_probe)
        tasks.append(_run_followup_blue(ctx, blue_arg, blue_probe.question))
    else:
        async def keep_blue(): return blue_arg
        tasks.append(keep_blue())

    new_red, new_blue = await asyncio.gather(*tasks)
    return new_red, new_blue, probes_fired


async def _run_followup_red(ctx: DealContext, prev_arg: TeamArgument, question: str) -> TeamArgument:
    base_prompt = build_red_system_prompt(prev_arg.persona_id) + "\n\n" + ROUND_2_CONSTRAINT
    user = _build_followup_user(prev_arg, question)
    return await call_agent(base_prompt, user, team="red", persona_id=prev_arg.persona_id)


async def _run_followup_blue(ctx: DealContext, prev_arg: TeamArgument, question: str) -> TeamArgument:
    base_prompt = build_blue_system_prompt(prev_arg.persona_id) + "\n\n" + ROUND_2_CONSTRAINT
    user = _build_followup_user(prev_arg, question)
    return await call_agent(base_prompt, user, team="blue", persona_id=prev_arg.persona_id)


def _build_followup_user(prev_arg: TeamArgument, question: str) -> str:
    """Round 2 user message — your prior argument + the Arbiter\'s targeted question."""
    lines = ["# YOUR ROUND 1 ARGUMENT (your previous output)\n"]
    lines.append(f"Headline: {prev_arg.headline}\n")
    lines.append("Claims:")
    for i, c in enumerate(prev_arg.claims, 1):
        lines.append(f"{i}. {c.statement}")
        for cit in c.citations:
            ref = cit.reference or ""
            lines.append(f"   - [{cit.kind}] {ref}")
    lines.append("\nActions:")
    for a in prev_arg.recommended_actions:
        lines.append(f"- {a.action} ({a.owner_role}, by {a.by_date})")
    lines.append("\n# ARBITER FOLLOW-UP QUESTION\n")
    lines.append(question)
    lines.append(
        "\nReturn your Round 2 response via the submit_argument tool. Stay narrowly within "
        "the question. Restraint and honest concession are rewarded; spin is penalized."
    )
    return "\n".join(lines)
