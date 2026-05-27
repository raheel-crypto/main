"""
Multi-turn arbiter logic — when to fire Round 2 and how to run it.
"""
from __future__ import annotations
import asyncio
from typing import Tuple
from ..schemas import DealContext, TeamArgument, TeamScoring
from ..personas.loader import build_red_system_prompt, build_blue_system_prompt
from ..agents.claude_client import call_agent
from .templates import select_followup_template, ROUND_2_CONSTRAINT
from .scorer import score_team_argument


def needs_followup(red: TeamScoring, blue: TeamScoring, disagreement: float) -> bool:
    """
    Trigger Round 2 if:
      - Disagreement > 0.5 (probability hinges on resolving the gap), OR
      - Either side's avg quality < 6/13 (one side may be reachably weak)
    """
    if disagreement > 0.5:
        return True
    if red.avg_quality < 6 or blue.avg_quality < 6:
        return True
    return False


async def run_round_2(
    ctx: DealContext,
    red_arg: TeamArgument,
    blue_arg: TeamArgument,
    red_scoring: TeamScoring,
    blue_scoring: TeamScoring,
) -> Tuple[TeamArgument, TeamArgument]:
    """
    Run a single follow-up round, in parallel for both teams.
    Each team only sees its own follow-up question — not the opponent's.
    """
    red_question = select_followup_template(red_scoring, blue_scoring)
    blue_question = select_followup_template(blue_scoring, red_scoring)

    tasks = []
    if red_question:
        tasks.append(_run_followup_red(ctx, red_arg, red_question))
    else:
        async def keep_red(): return red_arg
        tasks.append(keep_red())

    if blue_question:
        tasks.append(_run_followup_blue(ctx, blue_arg, blue_question))
    else:
        async def keep_blue(): return blue_arg
        tasks.append(keep_blue())

    new_red, new_blue = await asyncio.gather(*tasks)
    return new_red, new_blue


async def _run_followup_red(ctx: DealContext, prev_arg: TeamArgument, question: str) -> TeamArgument:
    base_prompt = build_red_system_prompt(prev_arg.persona_id) + "\n\n" + ROUND_2_CONSTRAINT
    user = _build_followup_user(prev_arg, question)
    return await call_agent(base_prompt, user, team="red", persona_id=prev_arg.persona_id)


async def _run_followup_blue(ctx: DealContext, prev_arg: TeamArgument, question: str) -> TeamArgument:
    base_prompt = build_blue_system_prompt(prev_arg.persona_id) + "\n\n" + ROUND_2_CONSTRAINT
    user = _build_followup_user(prev_arg, question)
    return await call_agent(base_prompt, user, team="blue", persona_id=prev_arg.persona_id)


def _build_followup_user(prev_arg: TeamArgument, question: str) -> str:
    """Render the Round 2 user message — shows your own previous argument + the question."""
    lines = ["# YOUR ROUND 1 ARGUMENT (your previous output)\n"]
    lines.append(f"Headline: {prev_arg.headline}\n")
    lines.append("Claims:")
    for i, c in enumerate(prev_arg.claims, 1):
        lines.append(f"{i}. {c.statement}")
        for cit in c.citations:
            lines.append(f"   - [{cit.kind}] {cit.reference}")
    lines.append("\nActions:")
    for a in prev_arg.recommended_actions:
        lines.append(f"- {a.action} ({a.owner_role}, by {a.by_date})")
    lines.append("\n# ARBITER FOLLOW-UP QUESTION\n")
    lines.append(question)
    lines.append("\nReturn your Round 2 response via the submit_argument tool, respecting the constraint.")
    return "\n".join(lines)
