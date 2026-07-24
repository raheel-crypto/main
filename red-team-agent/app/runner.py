"""
Red Team runner.

Calls the Anthropic-managed `RedHat Merlin` agent once per persona via the
Managed Agents API (see `agent_client.py`). The agent has the red-team base
prompt and `submit_argument` custom tool pre-configured; this module just
sends the deal package + persona instructions and parses the structured
output.

Per-persona prompts in `prompts/personas/<persona_id>.md` are passed inline in
the user message — that way the agent's system prompt stays fixed (the base
red-team prompt) and persona switching happens at the message layer.
"""
from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional

from .agent_client import ManagedAgentError, run_one_shot_with_custom_tool
from .prompt_assembly.red_prompt import build_red_user_message
from .schemas import AgentArgument, DealContext, FiredTrigger, TeamArgument
from . import intel_pack


# ─────────────────────────────────────────────────────────────────────────────
# Arbiter-side wrapper (uses prompt_assembly so Red + Blue stay symmetric)
# ─────────────────────────────────────────────────────────────────────────────


async def run_red_team_for_arbiter(
    context: DealContext,
    persona_id: str,
    supporting_triggers: List[FiredTrigger],
) -> Optional[TeamArgument]:
    """Same as run_red_team below but builds the user message via the shared
    prompt_assembly module (the one Blue also uses) and returns a TeamArgument
    so the scorer can consume it directly."""
    title = f"RedHat Merlin — {context.account_name} ({persona_id})"
    fired = [
        {
            "trigger_id": t.trigger_id,
            "weight": t.weight,
            "evidence": t.evidence,
            "target_persona": t.target_persona,
        }
        for t in supporting_triggers
    ]
    user_message = build_red_user_message(context, persona_id, fired)
    tool_input = await run_one_shot_with_custom_tool(
        title=title,
        user_message=user_message,
        tool_name="submit_argument",
    )
    tool_input.setdefault("persona_id", persona_id)
    tool_input.setdefault("deal_name", context.account_name)
    raw = AgentArgument.model_validate(tool_input)
    return TeamArgument.from_agent_argument(raw, "red")


_PROMPTS_DIR = Path(__file__).parent.parent / "prompts"


async def run_red_team(
    context: DealContext,
    persona_id: str,
    supporting_triggers: List[FiredTrigger],
) -> Optional[AgentArgument]:
    """
    Invoke the managed agent for one persona. Returns None if the agent
    didn't produce a valid `submit_argument` payload (errors propagate so
    main.py can audit them).
    """
    title = f"RedHat Merlin — {context.account_name} ({persona_id})"
    user_message = _build_user_message(context, persona_id, supporting_triggers)

    tool_input = await run_one_shot_with_custom_tool(
        title=title,
        user_message=user_message,
        tool_name="submit_argument",
    )
    tool_input.setdefault("persona_id", persona_id)
    tool_input.setdefault("deal_name", context.account_name)
    try:
        return AgentArgument.model_validate(tool_input)
    except Exception as exc:
        raise ManagedAgentError(
            f"submit_argument payload failed schema for persona {persona_id}: "
            f"{exc}; raw input keys={list(tool_input.keys())}"
        )


async def run_personas(
    context: DealContext,
    persona_ids: List[str],
    supporting_by_persona: Dict[str, List[FiredTrigger]],
) -> List[AgentArgument]:
    """
    Run personas sequentially (each managed-agent session is ~10-30s; running
    sequentially keeps us under Vercel's 60s default).
    """
    out: List[AgentArgument] = []
    for pid in persona_ids:
        try:
            arg = await run_red_team(
                context, pid, supporting_by_persona.get(pid, [])
            )
            if arg is not None:
                out.append(arg)
        except Exception as exc:
            print(
                f"[runner] persona {pid} failed: {type(exc).__name__}: {exc}",
                flush=True,
            )
            # Continue with other personas; main.py audits the partial result.
    return out


def render_audit_entry(
    context: DealContext,
    fired_triggers: List[FiredTrigger],
    arguments: List[AgentArgument],
) -> str:
    """Free-text audit-log entry. Merlin stores it on the audit row."""
    lines = [
        f"Red Team eval — {context.opportunity_name} ({context.opportunity_id})",
        "Fired triggers: "
        + (", ".join(t.trigger_id for t in fired_triggers) or "(none)"),
    ]
    for arg in arguments:
        lines.append(
            f"  · {arg.persona_id} — {arg.headline} "
            f"({len(arg.claims)} claims, {len(arg.recommended_actions)} actions)"
        )
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# User-message construction
# ─────────────────────────────────────────────────────────────────────────────


def _build_user_message(
    context: DealContext,
    persona_id: str,
    triggers: List[FiredTrigger],
) -> str:
    """
    Assemble the user message: persona instructions + deal package + intel-pack
    precedents. The agent's system prompt (red_team_base.md) is fixed; per-
    persona content goes here.
    """
    competitors = intel_pack.detect_competitors_in_context(context)
    similar_dead = intel_pack.find_similar_dead_deals(context, competitors, n=5)
    comp_quotes = intel_pack.find_competitor_quotes(competitors, n_per_competitor=4)
    cohort = intel_pack.get_cohort_stats()

    sections: List[str] = []
    sections.append(_persona_section(persona_id))
    sections.append(_deal_block(context, cohort))
    sections.append(_triggers_block(triggers))
    sections.append(_gong_block(context))
    sections.append(_meddpicc_evidence_block(context))
    sections.append(_prior_deals_block(similar_dead))
    if comp_quotes:
        sections.append(_competitor_quotes_block(comp_quotes))
    sections.append(_task_block())

    return "\n\n".join(s for s in sections if s)


def _persona_section(persona_id: str) -> str:
    header = f"# PERSONA\nYou are firing as the **{persona_id}** persona."
    detail = _load_persona_detail(persona_id)
    if not detail:
        return header
    return f"{header}\n\n{detail}"


def _load_persona_detail(persona_id: str) -> str:
    p = _PROMPTS_DIR / "personas" / f"{persona_id}.md"
    if not p.exists():
        fallback = _PROMPTS_DIR / "personas" / "default_cro_challenger.md"
        if not fallback.exists():
            return ""
        p = fallback
    try:
        return p.read_text(encoding="utf-8")
    except OSError:
        return ""


def _deal_block(context: DealContext, cohort: dict) -> str:
    md = cohort.get("meddpicc_lost_vs_won_avg") or {}

    def cohort_part(dim: str) -> str:
        row = md.get(dim) or {}
        lost = row.get("lost")
        won = row.get("won")
        if lost is None and won is None:
            return ""
        return f" (lost {lost} / won {won})"

    parts = [
        "# DEAL UNDER EVALUATION",
        "",
        "## Salesforce State",
        f"- Opportunity: {context.opportunity_name}",
        f"- Account: {context.account_name}",
        f"- Amount: ${context.amount:,.0f}",
        f"- Stage: {context.stage_name}",
        f"- Segment: {context.segment} | Business Type: {context.business_type}",
        f"- Age: {context.age_in_days} days",
        f"- Days since decision-maker touch: {context.days_since_decision_maker_touch or 'unknown'}",
        f"- Forecast Category: {context.forecast_category}",
        f"- Close Date: {context.close_date}",
        f"- Assigned AE: {context.assigned_ae}",
        "",
        "## MEDDPICC Scores",
        f"- Overall: {context.meddpicc.overall}{cohort_part('overall')}",
        f"- Champion: {context.meddpicc.champion}{cohort_part('champion')}",
        f"- Competition: {context.meddpicc.competition}{cohort_part('competition')}",
        f"- Decision Process: {context.meddpicc.decision_process}{cohort_part('decision_process')}",
        f"- Decision Criteria: {context.meddpicc.decision_criteria}{cohort_part('decision_criteria')}",
        f"- Economic Buyer: {context.meddpicc.economic_buyer}{cohort_part('economic_buyer')}",
        f"- Paper Process: {context.meddpicc.paper_process}{cohort_part('paper_process')}",
        f"- Pain: {context.meddpicc.pain}{cohort_part('pain')}",
        f"- Metrics: {context.meddpicc.metrics}{cohort_part('metrics')}",
    ]
    return "\n".join(parts)


def _triggers_block(triggers: List[FiredTrigger]) -> str:
    if not triggers:
        return "## TRIGGERS THAT FIRED ON THIS DEAL\n_(none — manually invoked)_"
    lines = [f"## TRIGGERS THAT FIRED ON THIS DEAL ({len(triggers)} total)"]
    for t in triggers:
        lines.append(
            f"- [{t.trigger_id}] weight={t.weight:.1f} → {t.evidence}"
        )
    return "\n".join(lines)


def _gong_block(context: DealContext) -> str:
    lines = ["## RECENT GONG SIGNALS"]
    lines.append(f"- {context.recent_gong_calls} calls in the recent window")
    lines.append(
        f"- {len(context.gong_competitor_mentions)} competitor mentions"
    )
    lines.append(
        f"- {len(context.gong_objection_mentions)} objection mentions"
    )
    if context.gong_recent_summary:
        lines.append("")
        lines.append("### Latest call summary")
        lines.append(context.gong_recent_summary[:1000])

    if context.gong_competitor_mentions:
        lines.append("")
        lines.append("### Competitor mentions (verbatim from prospect)")
        for m in context.gong_competitor_mentions[:10]:
            date = m.call_date.date() if m.call_date else ""
            ts = m.timestamp_seconds or 0
            lines.append(
                f'- {date} @ {ts}s: "{m.excerpt[:300]}"'
            )
    return "\n".join(lines)


def _meddpicc_evidence_block(context: DealContext) -> str:
    items = [(k, v) for k, v in context.meddpicc_evidence.items() if v]
    if not items:
        return ""
    lines = ["## MEDDPICC EVIDENCE FIELDS (current state, from Salesforce)"]
    for dim, text in items:
        lines.append("")
        lines.append(f"**{dim.upper()}**")
        lines.append(text[:500])
    return "\n".join(lines)


def _prior_deals_block(deals: List[dict]) -> str:
    if not deals:
        return ""
    lines = [
        f"## SIMILAR PRIOR DEAD DEALS (from intel pack — {len(deals)} closest matches)",
        "Cite these by name in your argument. These are real prior losses.",
        "",
    ]
    for d in deals:
        amount = d.get("amount") or 0
        lines.append(
            f"### {d.get('name', 'Unknown')} (${amount:,.0f} | "
            f"{d.get('segment') or '?'} | {d.get('business_type') or '?'})"
        )
        lines.append(f"- Primary loss reason: {d.get('primary_reason')}")
        lines.append(f"- Secondary: {d.get('secondary_reason')}")
        lines.append(
            f"- Final competitor: {d.get('final_competitor') or 'not set'}"
        )
        m = d.get("meddpicc") or {}
        lines.append(
            f"- Champion score: {m.get('champion')} | "
            f"Paper Process: {m.get('paper_process')}"
        )
        summary = (d.get("overall_summary") or "")[:400]
        if summary:
            lines.append(f"- Summary excerpt: {summary}")
        cl = d.get("cl_notes")
        if cl:
            lines.append(f"- CL Notes: {cl[:300]}")
        lines.append("")
    return "\n".join(lines)


def _competitor_quotes_block(quotes: List[dict]) -> str:
    lines = [
        "## VERBATIM CUSTOMER QUOTES — COMPETITORS MENTIONED IN THIS DEAL",
        "",
    ]
    for q in quotes:
        amount = q.get("amount") or 0
        lines.append(
            f"- [{q.get('competitor')}] {q.get('deal_name', '?')} "
            f"(${amount:,.0f}): \"{(q.get('quote') or '')[:300]}\""
        )
    return "\n".join(lines)


def _task_block() -> str:
    return (
        "# YOUR TASK\n\n"
        "Use the `submit_argument` tool to return a structured red-team argument. "
        "Every claim must cite at least one of: Gong moment (with date + "
        "timestamp), Salesforce field (with value), or a named prior dead deal. "
        "Do not fabricate evidence — work only from what's above.\n\n"
        "Do NOT call any other tools to re-fetch context. The full deal package "
        "above is the complete picture."
    )
