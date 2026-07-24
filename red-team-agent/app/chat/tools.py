"""
Four tools the conversational Arbiter can call.

Design principle (the integrity rule the moderator MUST follow):
  • The moderator does NOT have its own opinion.
  • When asked to push back AS a team → call summon_red_team / summon_blue_team.
  • When asked a what-if → call recompute_probability (deterministic).
  • When asked about a prior deal → call lookup_prior_deal.
  • Plain "why is the probability 35%" can be answered directly from the
    verdict already in the moderator's system prompt — no tool call needed.

Tool schemas here match the Anthropic SDK `tool_use` shape and are passed to
`messages.create(tools=CHAT_TOOLS)` from `chat/conversation.py`.
"""
from __future__ import annotations

import copy
from typing import Optional

from .. import intel_pack
from ..agents.claude_client import call_agent
from ..arbiter.probability import compute_probability
from ..schemas import (
    ArbiterVerdict,
    ChatConversationTurn,
    DealContext,
    MEDDPICCScores,
    TeamArgument,
)


# ─────────────────────────────────────────────────────────────────────────────
# Tool schemas — registered inline on the Anthropic SDK call
# ─────────────────────────────────────────────────────────────────────────────


CHAT_TOOLS = [
    {
        "name": "summon_red_team",
        "description": (
            "Re-invoke the Red Team (loss-case advocate) on a specific topic. "
            "Use when the rep asks Red to defend a claim, push back on new "
            "information, or elaborate a risk. Returns Red's fresh argument."
        ),
        "input_schema": {
            "type": "object",
            "required": ["focused_question"],
            "properties": {
                "focused_question": {
                    "type": "string",
                    "description": "The specific question or pushback Red should address.",
                },
            },
        },
    },
    {
        "name": "summon_blue_team",
        "description": (
            "Re-invoke the Blue Team (win-case advocate) on a specific topic. "
            "Use when the rep asks Blue to defend a claim, address Red's point, "
            "or expand on a positive signal."
        ),
        "input_schema": {
            "type": "object",
            "required": ["focused_question"],
            "properties": {
                "focused_question": {
                    "type": "string",
                    "description": "The specific question or pushback Blue should address.",
                },
            },
        },
    },
    {
        "name": "recompute_probability",
        "description": (
            "Recompute win probability under a hypothetical MEDDPICC change. Use "
            "for what-ifs ('what if I send the EB intro by Friday'). This is a "
            "deterministic recompute that re-uses the existing debate scores; "
            "frame the result as a directional estimate, not a re-evaluation."
        ),
        "input_schema": {
            "type": "object",
            "required": ["hypothetical", "meddpicc_changes"],
            "properties": {
                "hypothetical": {
                    "type": "string",
                    "description": "Plain-language description of the what-if.",
                },
                "meddpicc_changes": {
                    "type": "object",
                    "description": (
                        "Which MEDDPICC pillars change and their new values, "
                        "e.g. {economic_buyer: 6, paper_process: 6}. Each value "
                        "is a 0-8 pillar score."
                    ),
                    "properties": {
                        "overall": {"type": "number"},
                        "champion": {"type": "number"},
                        "competition": {"type": "number"},
                        "decision_process": {"type": "number"},
                        "decision_criteria": {"type": "number"},
                        "economic_buyer": {"type": "number"},
                        "paper_process": {"type": "number"},
                        "pain": {"type": "number"},
                        "metrics": {"type": "number"},
                    },
                },
            },
        },
    },
    {
        "name": "lookup_prior_deal",
        "description": (
            "Pull the full record of a prior won or lost deal cited in the "
            "verdict, e.g. 'show me the Charlesbank comparison in detail'."
        ),
        "input_schema": {
            "type": "object",
            "required": ["deal_name"],
            "properties": {
                "deal_name": {
                    "type": "string",
                    "description": "Name (or partial substring) of the prior deal.",
                },
            },
        },
    },
]


# ─────────────────────────────────────────────────────────────────────────────
# Tool implementations
# ─────────────────────────────────────────────────────────────────────────────


async def summon_red_team(
    deal_context: DealContext,
    verdict: ArbiterVerdict,
    focused_question: str,
) -> tuple[dict, Optional[ChatConversationTurn]]:
    """Call the existing Red managed agent with a follow-up framed around the
    rep's focused question. Returns `(payload_for_model, appended_turn)`."""
    if not focused_question.strip():
        return ({"error": "focused_question is required"}, None)

    persona = (
        verdict.redArgument.persona_id if verdict.redArgument else "claude_ae"
    )
    user_message = _summon_user_message(
        team="red",
        verdict=verdict,
        deal_context=deal_context,
        question=focused_question,
    )
    team_arg = await call_agent(
        system_prompt="",
        user_message=user_message,
        team="red",
        persona_id=persona,
    )
    payload = _team_arg_to_payload(team_arg)
    appended = ChatConversationTurn(
        role="red",
        content=_format_team_response_for_slack(team_arg),
        metadata={
            "persona_id": team_arg.persona_id,
            "headline": team_arg.headline,
            "focused_question": focused_question,
        },
    )
    return payload, appended


async def summon_blue_team(
    deal_context: DealContext,
    verdict: ArbiterVerdict,
    focused_question: str,
) -> tuple[dict, Optional[ChatConversationTurn]]:
    if not focused_question.strip():
        return ({"error": "focused_question is required"}, None)

    persona = (
        verdict.blueArgument.persona_id
        if verdict.blueArgument
        else "champion_advocate"
    )
    user_message = _summon_user_message(
        team="blue",
        verdict=verdict,
        deal_context=deal_context,
        question=focused_question,
    )
    team_arg = await call_agent(
        system_prompt="",
        user_message=user_message,
        team="blue",
        persona_id=persona,
    )
    payload = _team_arg_to_payload(team_arg)
    appended = ChatConversationTurn(
        role="blue",
        content=_format_team_response_for_slack(team_arg),
        metadata={
            "persona_id": team_arg.persona_id,
            "headline": team_arg.headline,
            "focused_question": focused_question,
        },
    )
    return payload, appended


def recompute_probability(
    deal_context: DealContext,
    verdict: ArbiterVerdict,
    hypothetical: str,
    meddpicc_changes: dict,
) -> tuple[dict, Optional[ChatConversationTurn]]:
    """
    Apply MEDDPICC pillar overrides and recompute the probability deterministically.
    Reports baseline (current state) vs new (hypothetical) so the delta reflects
    only the scenario, not snapshot drift.
    """
    if verdict.redScoring is None or verdict.blueScoring is None:
        return (
            {"error": "no scoring on verdict — cannot recompute"},
            None,
        )

    new_ctx = copy.deepcopy(deal_context)
    current = new_ctx.meddpicc.model_dump()
    old = deal_context.meddpicc.model_dump()

    # Apply pillar overrides; nudge `overall` by the delta unless the caller
    # explicitly set it. `overall` is on a different scale than the pillar sum,
    # so we keep the existing convention and adjust by the net change.
    overall_delta = 0.0
    for dim, val in (meddpicc_changes or {}).items():
        if dim == "overall":
            continue
        if dim in current and isinstance(val, (int, float)):
            prev = old.get(dim) or 0
            overall_delta += float(val) - float(prev)
            current[dim] = float(val)

    if isinstance(meddpicc_changes, dict) and "overall" in meddpicc_changes:
        current["overall"] = float(meddpicc_changes["overall"])
    elif current.get("overall") is not None:
        current["overall"] = float(current["overall"]) + overall_delta
    new_ctx.meddpicc = MEDDPICCScores(**current)

    base_prob, _, base_rate, _ = compute_probability(
        deal_context, verdict.redScoring, verdict.blueScoring
    )
    new_prob, _, _, new_lift = compute_probability(
        new_ctx, verdict.redScoring, verdict.blueScoring
    )
    delta = new_prob - base_prob
    lean = (
        "win" if new_prob >= 50 else "loss" if new_prob < 30 else "uncertain"
    )

    matched_branch = _match_scenario_branch(verdict, hypothetical, meddpicc_changes or {})

    rationale_parts: list[str] = []
    rationale_parts.append(
        f"Baseline {base_prob}% → with `{hypothetical or '(unspecified)'}` "
        f"applied, new probability {new_prob}% "
        f"({'+' if delta >= 0 else ''}{delta} pts). "
        f"Original verdict was {verdict.probability}%. "
        f"Base rate {round(base_rate * 100)}%, MEDDPICC lift {round(new_lift * 100, 1)}%."
    )
    if matched_branch:
        rationale_parts.append(
            f"Matches synthesizer diagnostic — "
            f"IF *{matched_branch['condition']}* THEN ~{matched_branch['new_probability']}% "
            f"({matched_branch['new_lean']}). {matched_branch['rationale']}"
        )
    rationale = " ".join(rationale_parts)

    payload = {
        "hypothetical": hypothetical,
        "verdict_probability": verdict.probability,
        "baseline_probability": base_prob,
        "new_probability": new_prob,
        "delta": delta,
        "new_lean": lean,
        "old_meddpicc_overall": deal_context.meddpicc.overall,
        "new_meddpicc_overall": new_ctx.meddpicc.overall,
        "matched_if_then_branch": matched_branch,
        "rationale": rationale,
        "note": (
            "Deterministic MEDDPICC-lift recompute holds the debate fixed. "
            "If `matched_if_then_branch` is present, it accounts for the "
            "discriminating variable and is the more meaningful signal."
        ),
    }
    appended = ChatConversationTurn(
        role="system",
        content=rationale,
        metadata={
            "tool": "recompute_probability",
            "verdict_probability": verdict.probability,
            "baseline_probability": base_prob,
            "new_probability": new_prob,
            "delta": delta,
            "new_lean": lean,
            "matched_if_then": matched_branch is not None,
        },
    )
    return payload, appended


def lookup_prior_deal(deal_name: str) -> tuple[dict, Optional[ChatConversationTurn]]:
    if not deal_name or not deal_name.strip():
        return ({"error": "deal_name is required"}, None)
    deal = intel_pack.find_deal_by_name(deal_name)
    if deal is None:
        return (
            {
                "found": False,
                "searched_for": deal_name,
                "message": (
                    f"No prior deal matched '{deal_name}'. Try the account "
                    f"name (e.g. 'Charlesbank' or 'BNPP')."
                ),
            },
            None,
        )
    payload = {
        "found": True,
        "name": deal.get("name") or deal.get("deal_name") or deal.get("account"),
        "account": deal.get("account"),
        "outcome": deal.get("outcome") or deal.get("stage_outcome"),
        "segment": deal.get("segment"),
        "business_type": deal.get("business_type"),
        "amount": deal.get("amount"),
        "primary_reason": deal.get("primary_reason"),
        "final_competitor": deal.get("final_competitor"),
        "overall_summary": deal.get("overall_summary") or deal.get("one_line_takeaway"),
        "competition_evidence": (deal.get("competition_evidence") or "")[:1200],
        "champion_evidence": (deal.get("champion_evidence") or "")[:1200],
        "cl_notes": (deal.get("cl_notes") or deal.get("cl_notes_excerpt") or "")[:1200],
        "purchase_driver": deal.get("purchase_driver"),
    }
    appended = ChatConversationTurn(
        role="system",
        content=_format_prior_deal_for_slack(payload),
        metadata={"tool": "lookup_prior_deal", "deal_name": payload["name"]},
    )
    return payload, appended


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _summon_user_message(
    *,
    team: str,
    verdict: ArbiterVerdict,
    deal_context: DealContext,
    question: str,
) -> str:
    our = verdict.redArgument if team == "red" else verdict.blueArgument
    other = verdict.blueArgument if team == "red" else verdict.redArgument
    other_team = "Blue" if team == "red" else "Red"
    sections: list[str] = []
    sections.append(
        f"# Follow-up on {deal_context.opportunity_name} "
        f"({deal_context.account_name}, opp {verdict.opportunityId})"
    )
    sections.append(
        "The Arbiter has already run a Red↔Blue debate on this deal and posted "
        "a verdict to Slack. The rep is responding in the verdict thread and "
        "the Moderator routed their follow-up to you. Stay in role — argue "
        "the loss case (Red) or win case (Blue). Concede if the rep's "
        "information genuinely weakens your position. Cite evidence the same "
        "way you did in Round 1."
    )
    sections.append(f"## Your Round 1 argument\n{_dump_arg(our)}")
    sections.append(f"## {other_team} Team's Round 1 argument\n{_dump_arg(other)}")
    sections.append(f"## Rep's follow-up\n{question.strip()}")
    sections.append(
        "Reply via `submit_argument` with a fresh argument that addresses the "
        "follow-up. Keep claims tight (≤3), citations specific."
    )
    return "\n\n".join(sections)


def _dump_arg(arg: Optional[TeamArgument]) -> str:
    if arg is None:
        return "(no argument)"
    parts: list[str] = [f"Headline: {arg.headline}"]
    for i, c in enumerate(arg.claims, 1):
        citations = "; ".join(
            (ci.excerpt or ci.reference or ci.kind)[:200] for ci in c.citations[:2]
        )
        parts.append(f"  {i}. {c.statement} — {citations}")
    return "\n".join(parts)


def _team_arg_to_payload(arg: TeamArgument) -> dict:
    return {
        "team": arg.team,
        "persona_id": arg.persona_id,
        "headline": arg.headline,
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
            for c in arg.claims
        ],
        "recommended_actions": [
            {
                "action": ra.action,
                "owner_role": ra.owner_role,
                "by_date": ra.by_date,
                "expected_signal": ra.expected_signal,
            }
            for ra in arg.recommended_actions
        ],
    }


def _format_team_response_for_slack(arg: TeamArgument) -> str:
    lines: list[str] = [f"*Headline:* {arg.headline}"]
    for i, c in enumerate(arg.claims, 1):
        lines.append(f"{i}. {c.statement}")
        for ci in c.citations[:2]:
            ref = ci.reference or ci.kind
            ex = (ci.excerpt or "").strip()
            lines.append(f"   • {ref}{f' — {ex[:300]}' if ex else ''}")
    if arg.recommended_actions:
        lines.append("*Recommended:*")
        for ra in arg.recommended_actions[:3]:
            lines.append(f"   • {ra.action}")
    return "\n".join(lines)


def _format_prior_deal_for_slack(p: dict) -> str:
    title = f"*Prior deal — {p.get('name')}*"
    extras = [p.get("segment"), p.get("business_type"), p.get("outcome")]
    extras = [e for e in extras if e]
    if extras:
        title += f" ({', '.join(extras)})"
    lines: list[str] = [title]
    if p.get("primary_reason"):
        lines.append(f"Primary reason: {p['primary_reason']}")
    if p.get("final_competitor"):
        lines.append(f"Final competitor: {p['final_competitor']}")
    if p.get("amount"):
        try:
            lines.append(f"Amount: ${float(p['amount']):,.0f}")
        except (TypeError, ValueError):
            pass
    if p.get("overall_summary"):
        lines.append(f"Summary: {p['overall_summary']}")
    if p.get("cl_notes"):
        lines.append(f"Notes: {p['cl_notes']}")
    return "\n".join(lines)


def _match_scenario_branch(
    verdict: ArbiterVerdict,
    hypothetical: str,
    meddpicc_changes: dict,
) -> Optional[dict]:
    """Find an if/then diagnostic branch whose condition overlaps the scenario.

    The synthesizer's diagnostics account for the discriminating variable
    (e.g. 'EB met before Stage 4'), so they're a more meaningful signal than
    the deterministic MEDDPICC-lift recompute on its own.
    """
    syn = verdict.synthesis
    if not syn or not syn.if_then_diagnostic:
        return None
    hyp_words = {
        w for w in (hypothetical or "").lower().replace("/", " ").split() if len(w) > 3
    }
    changed_dims = set(meddpicc_changes.keys())
    dim_words = {
        "economic_buyer": {"eb", "buyer", "economic", "authority", "signature"},
        "paper_process": {"paper", "procurement", "legal", "redline", "infosec", "security"},
        "champion": {"champion", "sponsor"},
        "decision_process": {"decision", "process", "timeline"},
        "metrics": {"metrics", "roi", "business", "case"},
        "pain": {"pain", "problem"},
        "decision_criteria": {"criteria", "requirements"},
        "competition": {"competitor", "competition", "vs"},
    }
    best, best_score = None, 0
    for b in syn.if_then_diagnostic:
        cond_words = {
            w for w in b.condition.lower().replace("/", " ").split() if len(w) > 3
        }
        overlap = len(hyp_words & cond_words)
        for dim in changed_dims:
            if dim_words.get(dim, set()) & cond_words:
                overlap += 2
        if overlap > best_score:
            best, best_score = b, overlap
    if best and best_score >= 1:
        return {
            "condition": best.condition,
            "new_probability": best.new_probability,
            "new_lean": best.new_lean,
            "rationale": best.rationale,
        }
    return None
