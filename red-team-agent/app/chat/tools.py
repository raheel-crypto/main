"""
Four tool implementations for the Arbiter Moderator agent.

Each tool function returns `(payload_for_agent, summary_for_audit, append_turn)`:
  • `payload_for_agent` is sent back to the moderator as a JSON
    `user.custom_tool_result` content block.
  • `summary_for_audit` is a short string written to `tool_calls[].result_summary`
    for the audit log.
  • `append_turn` is an optional ChatConversationTurn (role='red'|'blue'|'system')
    that Merlin should write to `verdict_conversation_turns` next to the
    moderator's reply — surfaces verbatim Red/Blue text in the audit trail.

The handlers receive a `ToolCtx` holding the verdict + intel pack + a DealContext
so they don't need to reach back into shared state.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from typing import Any, Optional, Tuple

from .. import intel_pack
from ..agents.claude_client import call_agent
from ..arbiter import probability as prob_mod
from ..schemas import (
    ArbiterVerdict,
    ChatConversationTurn,
    DealContext,
    MEDDPICCScores,
    TeamArgument,
    TeamScoring,
)


# ─────────────────────────────────────────────────────────────────────────────
# Tool context
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class ToolCtx:
    verdict: ArbiterVerdict
    intel_pack: dict
    deal_context: DealContext


ToolResult = Tuple[dict, str, Optional[ChatConversationTurn]]


# ─────────────────────────────────────────────────────────────────────────────
# Helpers for summon tools — build a follow-up user message that gives Red/Blue
# the full context they had in Round 1 + the rep's specific follow-up question.
# ─────────────────────────────────────────────────────────────────────────────


def _summon_user_message(
    *,
    team: str,
    ctx: ToolCtx,
    question: str,
) -> str:
    """
    Compose a follow-up user message for the team agent. We don't re-attach the
    full intel pack (the managed-agent system prompt has its own context and
    the original verdict carries Round 1 arguments); we summarize the deal,
    quote our own team's Round 1 argument, quote the opponent's, then hand
    over the rep's follow-up.
    """
    v = ctx.verdict
    our = v.redArgument if team == "red" else v.blueArgument
    other = v.blueArgument if team == "red" else v.redArgument
    other_team = "Blue" if team == "red" else "Red"
    deal = v.opportunityId
    acct_name = ctx.deal_context.account_name or ""
    opp_name = ctx.deal_context.opportunity_name or ""

    sections: list[str] = []
    sections.append(
        f"# Follow-up from the rep on {opp_name} ({acct_name}, opp {deal})"
    )
    sections.append(
        "The Arbiter has run a Red↔Blue debate on this deal. The rep is "
        "responding in the verdict thread and the Moderator routed their "
        "follow-up to you. Stay in role — argue the loss case (Red) or win "
        "case (Blue). You may concede if the rep's information genuinely "
        "weakens your position. Cite evidence the same way you did in Round 1."
    )
    sections.append(f"## Your Round 1 argument (do not repeat verbatim)\n{_dump_arg(our)}")
    sections.append(f"## {other_team} Team's Round 1 argument\n{_dump_arg(other)}")
    sections.append(f"## Rep's follow-up question\n{question.strip()}")
    sections.append(
        "Reply via `submit_argument` with a fresh argument that addresses the "
        "follow-up. Keep claims tight (≤3) and citations specific."
    )
    return "\n\n".join(sections)


def _dump_arg(arg: Optional[TeamArgument]) -> str:
    if arg is None:
        return "(no argument)"
    parts: list[str] = []
    if arg.headline:
        parts.append(f"Headline: {arg.headline}")
    for i, c in enumerate(arg.claims, 1):
        cit = []
        for ci in c.citations[:2]:
            cit.append(f"{ci.kind}: {(ci.excerpt or ci.reference)[:200]}")
        joined = "  \n".join(cit)
        parts.append(f"  {i}. {c.statement}\n     {joined}")
    return "\n".join(parts) or "(empty)"


# ─────────────────────────────────────────────────────────────────────────────
# summon_red_team / summon_blue_team
# ─────────────────────────────────────────────────────────────────────────────


async def _summon(team: str, ctx: ToolCtx, question: str) -> ToolResult:
    if team == "red":
        persona = (ctx.verdict.redArgument.persona_id if ctx.verdict.redArgument else "claude_ae")
    else:
        persona = (ctx.verdict.blueArgument.persona_id if ctx.verdict.blueArgument else "champion_advocate")

    user_message = _summon_user_message(team=team, ctx=ctx, question=question)

    # call_agent dispatches to the right managed agent (Red or Blue).
    team_arg = await call_agent(
        system_prompt="",  # managed agent has its own
        user_message=user_message,
        team=team,  # type: ignore[arg-type]
        persona_id=persona,
    )

    # Build a compact payload for the moderator: headline + claims + actions.
    payload = {
        "team": team,
        "persona_id": team_arg.persona_id,
        "headline": team_arg.headline,
        "claims": [
            {
                "statement": c.statement,
                "pattern_match": c.pattern_match,
                "citations": [
                    {
                        "kind": ci.kind,
                        "reference": ci.reference,
                        "excerpt": (ci.excerpt or "")[:400],
                    }
                    for ci in c.citations
                ],
            }
            for c in team_arg.claims
        ],
        "recommended_actions": [
            {
                "action": ra.action,
                "owner_role": ra.owner_role,
                "by_date": ra.by_date,
                "expected_signal": ra.expected_signal,
            }
            for ra in team_arg.recommended_actions
        ],
    }
    summary = f"{team}: {team_arg.headline[:120]}"
    # Pre-format Slack-ready text for the audit trail — Merlin renders this in
    # the verdict_conversation_turns row so the rep can scroll back through
    # earlier team responses without re-querying.
    appended = ChatConversationTurn(
        role=team,  # type: ignore[arg-type]
        content=_format_team_response_for_slack(team_arg),
        metadata={"persona_id": team_arg.persona_id, "headline": team_arg.headline},
    )
    return payload, summary, appended


async def summon_red_team(tool_input: dict, ctx: ToolCtx) -> ToolResult:
    question = (tool_input.get("question") or "").strip()
    if not question:
        return ({"error": "question is required"}, "missing_question", None)
    return await _summon("red", ctx, question)


async def summon_blue_team(tool_input: dict, ctx: ToolCtx) -> ToolResult:
    question = (tool_input.get("question") or "").strip()
    if not question:
        return ({"error": "question is required"}, "missing_question", None)
    return await _summon("blue", ctx, question)


def _format_team_response_for_slack(arg: TeamArgument) -> str:
    lines: list[str] = [f"*Headline:* {arg.headline}"]
    for i, c in enumerate(arg.claims, 1):
        lines.append(f"{i}. {c.statement}")
        for ci in c.citations[:2]:
            ref = ci.reference or ci.kind
            ex = (ci.excerpt or "").strip()
            if ex:
                lines.append(f"   • {ref} — {ex[:300]}")
            else:
                lines.append(f"   • {ref}")
    if arg.recommended_actions:
        lines.append("*Recommended:*")
        for ra in arg.recommended_actions[:3]:
            lines.append(f"   • {ra.action}")
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# recompute_probability — pure deterministic, no Claude call
# ─────────────────────────────────────────────────────────────────────────────


async def recompute_probability(tool_input: dict, ctx: ToolCtx) -> ToolResult:
    scenario = (tool_input.get("scenario") or "").strip()
    favors_team = (tool_input.get("favors_team") or "neither").strip()
    if favors_team not in ("red", "blue", "neither"):
        favors_team = "neither"

    meddpicc_overrides = tool_input.get("meddpicc_overrides") or {}
    argument_delta_override = tool_input.get("argument_delta_override")

    # Start from the verdict's existing scoring (final round, including any R2)
    red_scoring = ctx.verdict.redScoring
    blue_scoring = ctx.verdict.blueScoring
    if red_scoring is None or blue_scoring is None:
        return ({"error": "no scoring on verdict — cannot recompute"}, "no_scoring", None)

    # Build a fresh DealContext with MEDDPICC overrides applied.
    deal_ctx = ctx.deal_context.model_copy(deep=True)
    if meddpicc_overrides:
        m = deal_ctx.meddpicc.model_dump()
        for k, v in meddpicc_overrides.items():
            if k in m and isinstance(v, (int, float)):
                m[k] = float(v)
        # Recompute `overall` from the per-pillar values so the probability
        # formula reflects the override (probability.py reads overall directly).
        pillars = [
            v for k, v in m.items()
            if k != "overall" and isinstance(v, (int, float))
        ]
        if pillars:
            m["overall"] = float(sum(pillars))
        deal_ctx.meddpicc = MEDDPICCScores(**m)

    # If the rep specified an argument-delta override, shape the team totals to
    # achieve that delta. Otherwise nudge totals by ±15% toward `favors_team`.
    red_total = red_scoring.total_score
    blue_total = blue_scoring.total_score
    if isinstance(argument_delta_override, (int, float)):
        # delta = (blue - red) / max(total, 10). Solve for new totals.
        delta = max(-1.0, min(1.0, float(argument_delta_override)))
        avg = (red_total + blue_total) / 2.0 if (red_total + blue_total) > 0 else 5.0
        # Spread the implied delta around the same total
        spread = delta * max(avg * 2, 10) / 2
        blue_total = avg + spread
        red_total = avg - spread
    elif favors_team == "red":
        red_total = red_total * 1.15 + 1.5
    elif favors_team == "blue":
        blue_total = blue_total * 1.15 + 1.5

    red_shadow = TeamScoring(
        team="red",
        total_score=max(0.0, red_total),
        avg_quality=red_scoring.avg_quality,
        n_claims=red_scoring.n_claims,
        scored_claims=red_scoring.scored_claims,
        addressed_opponents_top_claim=red_scoring.addressed_opponents_top_claim,
    )
    blue_shadow = TeamScoring(
        team="blue",
        total_score=max(0.0, blue_total),
        avg_quality=blue_scoring.avg_quality,
        n_claims=blue_scoring.n_claims,
        scored_claims=blue_scoring.scored_claims,
        addressed_opponents_top_claim=blue_scoring.addressed_opponents_top_claim,
    )

    new_pct, new_conf, base_rate, meddpicc_lift = prob_mod.compute_probability(
        deal_ctx, red_shadow, blue_shadow
    )
    # Compute the baseline using the unchanged scoring + the unchanged deal
    # context so the rep sees the scenario's true effect (rather than drift
    # between the live formula and the snapshotted verdict.probability).
    baseline_pct, _, _, _ = prob_mod.compute_probability(
        ctx.deal_context, red_scoring, blue_scoring
    )
    old_pct = baseline_pct
    delta_pct = new_pct - old_pct
    lean = "uncertain"
    if new_pct >= 60:
        lean = "win"
    elif new_pct <= 40:
        lean = "loss"

    verdict_pct = ctx.verdict.probability
    rationale = (
        f"Baseline {old_pct}% → with scenario `{scenario or '(no description)'}` "
        f"applied (favors_team={favors_team}), new probability {new_pct}% "
        f"({'+' if delta_pct >= 0 else ''}{delta_pct} pts). "
        f"Original verdict was {verdict_pct}%. "
        f"Base rate {round(base_rate * 100)}%, MEDDPICC lift {round(meddpicc_lift * 100, 1)}%."
    )

    payload = {
        "scenario": scenario,
        "favors_team": favors_team,
        "verdict_probability": verdict_pct,
        "baseline_probability": old_pct,
        "new_probability": new_pct,
        "delta_pct": delta_pct,
        "new_lean": lean,
        "confidence": new_conf,
        "base_rate_pct": round(base_rate * 100, 1),
        "meddpicc_lift_pct": round(meddpicc_lift * 100, 1),
        "rationale": rationale,
        "meddpicc_overrides_applied": meddpicc_overrides or None,
    }
    summary = f"{old_pct}% → {new_pct}% ({lean})"
    appended = ChatConversationTurn(
        role="system",
        content=rationale,
        metadata={
            "tool": "recompute_probability",
            "verdict_probability": verdict_pct,
            "baseline_probability": old_pct,
            "new_probability": new_pct,
            "delta_pct": delta_pct,
            "new_lean": lean,
        },
    )
    return payload, summary, appended


# ─────────────────────────────────────────────────────────────────────────────
# lookup_prior_deal — read-only intel pack lookup
# ─────────────────────────────────────────────────────────────────────────────


async def lookup_prior_deal(tool_input: dict, ctx: ToolCtx) -> ToolResult:
    name = (tool_input.get("deal_name") or "").strip()
    if not name:
        return ({"error": "deal_name is required"}, "missing_name", None)
    deal = intel_pack.find_deal_by_name(name)
    if deal is None:
        return (
            {
                "found": False,
                "message": f"No prior deal matched '{name}'. Try a more specific account name.",
            },
            f"not_found: {name[:80]}",
            None,
        )
    # Keep the payload modest — agents don't need the entire record.
    payload = {
        "found": True,
        "name": deal.get("name") or deal.get("deal_name") or deal.get("account"),
        "account": deal.get("account"),
        "segment": deal.get("segment"),
        "business_type": deal.get("business_type"),
        "amount": deal.get("amount"),
        "primary_reason": deal.get("primary_reason"),
        "final_competitor": deal.get("final_competitor"),
        "one_line_takeaway": deal.get("one_line_takeaway"),
        "cl_notes_excerpt": (deal.get("cl_notes_excerpt") or "")[:1200],
        "stage_outcome": deal.get("stage_outcome"),
    }
    summary = f"found: {payload['name']}"
    appended = ChatConversationTurn(
        role="system",
        content=_format_prior_deal_for_slack(payload),
        metadata={"tool": "lookup_prior_deal", "deal_name": payload["name"]},
    )
    return payload, summary, appended


def _format_prior_deal_for_slack(p: dict) -> str:
    lines: list[str] = []
    title = f"*Prior deal — {p.get('name')}*"
    seg = p.get("segment")
    bt = p.get("business_type")
    if seg or bt:
        title += f" ({', '.join(x for x in (seg, bt) if x)})"
    lines.append(title)
    if p.get("primary_reason"):
        lines.append(f"Primary reason: {p['primary_reason']}")
    if p.get("final_competitor"):
        lines.append(f"Final competitor: {p['final_competitor']}")
    if p.get("amount"):
        lines.append(f"Amount: ${p['amount']:,.0f}")
    if p.get("one_line_takeaway"):
        lines.append(f"Takeaway: {p['one_line_takeaway']}")
    if p.get("cl_notes_excerpt"):
        lines.append(f"Notes: {p['cl_notes_excerpt']}")
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# Tool registry — mirrors the JSON schemas registered on the moderator agent
# ─────────────────────────────────────────────────────────────────────────────


TOOL_HANDLERS = {
    "summon_red_team": summon_red_team,
    "summon_blue_team": summon_blue_team,
    "recompute_probability": recompute_probability,
    "lookup_prior_deal": lookup_prior_deal,
}
