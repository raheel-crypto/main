"""
FastAPI entry point.

Run locally:
    uvicorn app.main:app --reload --port 3003
"""
from __future__ import annotations

import json
import os
from collections import defaultdict
from datetime import datetime, timezone
from typing import Annotated, List

from fastapi import Depends, FastAPI, HTTPException, status

import asyncio

from . import personas as personas_mod
from . import runner
from . import runner_blue
from . import triggers as triggers_mod
from .arbiter import multi_turn, probability, scorer
from .auth import verify_signature
from .context import pack_to_context
from .cooldowns import is_cooled_down, mark_evaluated
from .personas.routing import route_personas
from .schemas import (
    AgentArgument,
    ArbiterRequest,
    ArbiterVerdict,
    Claim,
    Citation as AgentCitation,
    DealContext,
    FiredTrigger,
    IntelPackRequest,
    PersonaArgument,
    RunResult,
    TeamArgument,
    WireCitation,
    WireClaim,
    WireRecommendedAction,
)

app = FastAPI(title="Red Team Agent", version="0.2.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"ok": "true", "service": "red-team-agent"}


@app.post("/evaluate", response_model=RunResult)
async def evaluate(
    raw_body: Annotated[bytes, Depends(verify_signature)],
) -> RunResult:
    """
    Merlin → Red Team eval. Body is `RedTeamIntelPackRequest`; response is
    `RedTeamRunResult`. Auth is HMAC-SHA256 over `<timestamp>.<body>`.
    """
    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid JSON: {exc}",
        ) from exc

    try:
        pack = IntelPackRequest.model_validate(payload)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid intel pack: {exc}",
        ) from exc

    evaluated_at = datetime.now(timezone.utc).isoformat()

    # Per-opp cooldown — Merlin's audit will record the drop reason.
    cooled = is_cooled_down(pack.opportunity.id)
    if cooled:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[],
            personasInvoked=[],
            auditLogEntry="",
            cooldownUntilIso=cooled,
            dropReason="cooldown",
        )

    context = pack_to_context(pack)

    fired = triggers_mod.evaluate(context)
    if not fired:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[],
            personasInvoked=[],
            auditLogEntry="",
            dropReason="no_triggers_fired",
        )

    selected, action, supporting = personas_mod.select_personas(
        context, fired, manual=(pack.triggerEvent == "manual")
    )
    if not selected:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[t.trigger_id for t in fired],
            personasInvoked=[],
            auditLogEntry="",
            dropReason=action or "no_personas_selected",
        )

    supporting_by_persona: dict[str, List[FiredTrigger]] = defaultdict(list)
    for t in supporting:
        supporting_by_persona[t.target_persona].append(t)

    arguments = await runner.run_personas(
        context, selected, supporting_by_persona
    )

    cooldown_iso = mark_evaluated(pack.opportunity.id)

    wire_personas = [
        _agent_arg_to_wire(arg, supporting_by_persona.get(arg.persona_id, []), action)
        for arg in arguments
    ]

    return RunResult(
        evaluatedAt=evaluated_at,
        shadowMode=pack.shadowMode,
        firedTriggers=[t.trigger_id for t in fired],
        personasInvoked=wire_personas,
        auditLogEntry=runner.render_audit_entry(context, fired, arguments),
        cooldownUntilIso=cooldown_iso,
    )


# ─────────────────────────────────────────────────────────────────────────────
# AgentArgument → wire PersonaArgument
# ─────────────────────────────────────────────────────────────────────────────


_KIND_TO_SOURCE_TYPE = {
    "gong": "gong_quote",
    "salesforce": "field_change",
    "prior_deal": "dead_deal",
    "intel_pack": "competitor_profile",
    "public_source": "other",
}


def _agent_arg_to_wire(
    arg: AgentArgument,
    supporting: List[FiredTrigger],
    action: str,
) -> PersonaArgument:
    """
    Translate the agent's AgentArgument (snake_case, internal types) into the
    wire PersonaArgument (camelCase, Merlin's contract). Per-claim citations
    and recommended-actions structure survive end-to-end so the Slack card
    can render them as separate blocks rather than squashed text.
    """
    return PersonaArgument(
        persona=arg.persona_id,
        headline=arg.headline,
        riskScore=_risk_score(action, supporting),
        claims=[_claim_to_wire(c) for c in arg.claims],
        recommendedActions=[
            WireRecommendedAction(
                action=ra.action,
                ownerRole=ra.owner_role or "",
                byDate=ra.by_date or "",
                expectedSignal=ra.expected_signal or "",
            )
            for ra in arg.recommended_actions
        ],
    )


def _claim_to_wire(c: Claim) -> WireClaim:
    return WireClaim(
        statement=c.statement,
        patternMatch=c.pattern_match,
        citations=[_agent_citation_to_wire(cit) for cit in c.citations],
    )


def _agent_citation_to_wire(c: AgentCitation) -> WireCitation:
    return WireCitation(
        sourceType=_KIND_TO_SOURCE_TYPE.get(c.kind, "other"),
        quote=(c.excerpt or c.reference)[:400],
        sourceLabel=c.reference[:120],
        sourceUrl=None,
    )


def _risk_score(action: str, supporting: List[FiredTrigger]) -> float:
    """
    Map persona-selector action level → 0..1 score for Merlin's color badge.
    Boost slightly by the strongest supporting trigger weight so the score
    isn't fully bimodal.
    """
    base = 0.7 if action == "dm_rep_cc_manager" else 0.5 if action == "dm_rep" else 0.3
    if supporting:
        max_w = max(t.weight for t in supporting)
        boost = min(0.2, max_w / 100.0)
        return min(1.0, base + boost)
    return base


# ─────────────────────────────────────────────────────────────────────────────
# /blue/evaluate — Blue Team standalone (mirrors /evaluate)
# ─────────────────────────────────────────────────────────────────────────────


@app.post("/blue/evaluate", response_model=RunResult)
async def blue_evaluate(
    raw_body: Annotated[bytes, Depends(verify_signature)],
) -> RunResult:
    """
    Standalone Blue Team eval — same IntelPackRequest in, RunResult-shaped
    response out. Used by /arbiter internally and exposed as a debug surface.
    """
    pack = _parse_intel_pack(raw_body)
    evaluated_at = datetime.now(timezone.utc).isoformat()

    context = pack_to_context(pack)
    fired = triggers_mod.evaluate(context)
    context.fired_triggers = [
        {
            "trigger_id": t.trigger_id,
            "weight": t.weight,
            "evidence": t.evidence,
            "target_persona": t.target_persona,
        }
        for t in fired
    ]

    route = route_personas(context)
    blue_persona_id = route.blue_persona_id

    try:
        team_arg = await runner_blue.run_blue_team(
            context, blue_persona_id, fired
        )
    except Exception as exc:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[t.trigger_id for t in fired],
            personasInvoked=[],
            dropReason=f"blue_failed: {str(exc)[:200]}",
        )
    if team_arg is None:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[t.trigger_id for t in fired],
            personasInvoked=[],
            dropReason="no_blue_argument",
        )

    wire_persona = _team_arg_to_wire(team_arg, fired)
    return RunResult(
        evaluatedAt=evaluated_at,
        shadowMode=pack.shadowMode,
        firedTriggers=[t.trigger_id for t in fired],
        personasInvoked=[wire_persona],
    )


# ─────────────────────────────────────────────────────────────────────────────
# /arbiter — Red + Blue in parallel + deterministic scoring + probability
# ─────────────────────────────────────────────────────────────────────────────


@app.post("/arbiter", response_model=ArbiterVerdict)
async def arbiter(
    raw_body: Annotated[bytes, Depends(verify_signature)],
) -> ArbiterVerdict:
    """
    The full debate. Fires Red + Blue in parallel against their respective
    managed agents, scores both arguments via app/arbiter/scorer.py,
    optionally runs Round 2 if disagreement / weak evidence triggers it,
    then computes the calibrated probability + confidence band.
    """
    pack = _parse_intel_pack(raw_body)
    evaluated_at = datetime.now(timezone.utc).isoformat()

    # Optional knob in the request body.
    try:
        body_extras = ArbiterRequest.model_validate_json(raw_body)
        enable_followup = body_extras.enable_followup
    except Exception:
        enable_followup = True

    # Per-opp cooldown gates the entire debate.
    cooled = is_cooled_down(pack.opportunity.id)
    if cooled:
        return ArbiterVerdict(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            opportunityId=pack.opportunity.id,
            probability=0,
            confidence="Low",
            disagreement=0.0,
            baseRate=0.0,
            meddpiccLift=0.0,
            cooldownUntilIso=cooled,
            dropReason="cooldown",
        )

    context = pack_to_context(pack)
    fired = triggers_mod.evaluate(context)
    context.fired_triggers = [
        {
            "trigger_id": t.trigger_id,
            "weight": t.weight,
            "evidence": t.evidence,
            "target_persona": t.target_persona,
        }
        for t in fired
    ]

    route = route_personas(context)

    # Fire Red and Blue in parallel.
    try:
        red_arg, blue_arg = await asyncio.gather(
            runner.run_red_team_for_arbiter(
                context, route.red_persona_id, fired
            ),
            runner_blue.run_blue_team(
                context, route.blue_persona_id, fired
            ),
        )
    except Exception as exc:
        return ArbiterVerdict(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            opportunityId=pack.opportunity.id,
            probability=0,
            confidence="Low",
            disagreement=0.0,
            baseRate=0.0,
            meddpiccLift=0.0,
            firedTriggers=[t.trigger_id for t in fired],
            routeReason=route.reason,
            dropReason=f"agent_failed: {str(exc)[:240]}",
        )

    if red_arg is None or blue_arg is None:
        return ArbiterVerdict(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            opportunityId=pack.opportunity.id,
            probability=0,
            confidence="Low",
            disagreement=0.0,
            baseRate=0.0,
            meddpiccLift=0.0,
            firedTriggers=[t.trigger_id for t in fired],
            routeReason=route.reason,
            dropReason="missing_argument",
        )

    # Score both arguments (counter-response factored in by passing opponent).
    red_scoring = scorer.score_team_argument(red_arg, opponent=blue_arg)
    blue_scoring = scorer.score_team_argument(blue_arg, opponent=red_arg)
    disagreement = probability.compute_disagreement(red_scoring, blue_scoring)

    rounds_completed = 1
    if enable_followup and multi_turn.needs_followup(
        red_scoring, blue_scoring, disagreement
    ):
        try:
            red_arg, blue_arg = await multi_turn.run_round_2(
                context, red_arg, blue_arg, red_scoring, blue_scoring
            )
            red_scoring = scorer.score_team_argument(red_arg, opponent=blue_arg)
            blue_scoring = scorer.score_team_argument(blue_arg, opponent=red_arg)
            disagreement = probability.compute_disagreement(red_scoring, blue_scoring)
            rounds_completed = 2
        except Exception as exc:
            print(f"[arbiter] round 2 failed: {exc}", flush=True)

    prob_pct, confidence, base_rate, meddpicc_lift = probability.compute_probability(
        context, red_scoring, blue_scoring
    )

    top_actions = _select_top_actions(red_arg, blue_arg, max_actions=3)
    explanation = _build_explanation(
        prob_pct, confidence, base_rate, meddpicc_lift, red_scoring, blue_scoring, route.reason
    )

    mark_evaluated(pack.opportunity.id)

    return ArbiterVerdict(
        evaluatedAt=evaluated_at,
        shadowMode=pack.shadowMode,
        opportunityId=pack.opportunity.id,
        probability=prob_pct,
        confidence=confidence,
        disagreement=disagreement,
        baseRate=base_rate,
        meddpiccLift=meddpicc_lift,
        redArgument=red_arg,
        blueArgument=blue_arg,
        redScoring=red_scoring,
        blueScoring=blue_scoring,
        topActions=top_actions,
        explanation=explanation,
        roundsCompleted=rounds_completed,
        firedTriggers=[t.trigger_id for t in fired],
        routeReason=route.reason,
    )


def _parse_intel_pack(raw_body: bytes) -> IntelPackRequest:
    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid JSON: {exc}",
        ) from exc
    try:
        return IntelPackRequest.model_validate(payload)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"invalid intel pack: {exc}",
        ) from exc


def _team_arg_to_wire(arg: TeamArgument, fired: List[FiredTrigger]) -> PersonaArgument:
    """Convert TeamArgument → wire PersonaArgument for /blue/evaluate's RunResult."""
    return PersonaArgument(
        persona=arg.persona_id,
        headline=arg.headline,
        riskScore=0.5,
        claims=[_claim_to_wire(c) for c in arg.claims],
        recommendedActions=[
            WireRecommendedAction(
                action=ra.action,
                ownerRole=ra.owner_role or "",
                byDate=ra.by_date or "",
                expectedSignal=ra.expected_signal or "",
            )
            for ra in arg.recommended_actions
        ],
    )


def _select_top_actions(
    red: TeamArgument, blue: TeamArgument, max_actions: int = 3
) -> List[str]:
    """Pick the top N actions across both teams as a flat list of strings.

    Order: Blue's first action (the bull case's most-important next step),
    then Red's first (the risk-mitigation move), then alternating until cap.
    Each action string carries the owner role + by-date for the rep to scan.
    """
    out: List[str] = []
    red_actions = list(red.recommended_actions)
    blue_actions = list(blue.recommended_actions)

    def fmt(a) -> str:
        meta_parts = [a.owner_role, a.by_date]
        meta = " · ".join(p for p in meta_parts if p)
        return f"{a.action}" + (f" ({meta})" if meta else "")

    while len(out) < max_actions and (blue_actions or red_actions):
        if blue_actions:
            out.append(fmt(blue_actions.pop(0)))
            if len(out) >= max_actions:
                break
        if red_actions:
            out.append(fmt(red_actions.pop(0)))
    return out


def _build_explanation(
    prob_pct: int,
    confidence: str,
    base_rate: float,
    meddpicc_lift: float,
    red: "scorer.TeamScoring",
    blue: "scorer.TeamScoring",
    route_reason: str,
) -> str:
    """One-paragraph human-readable synthesis the rep reads on the card."""
    delta = blue.total_score - red.total_score
    direction = (
        "Blue made the stronger case"
        if delta > 0
        else "Red made the stronger case"
        if delta < 0
        else "Red and Blue scored evenly"
    )
    lift_pct = meddpicc_lift * 100
    return (
        f"Win probability: {prob_pct}% ({confidence} confidence). "
        f"Base rate for this segment is {int(base_rate * 100)}%; MEDDPICC "
        f"adjusts that by {lift_pct:+.1f} points. Routing fired the "
        f"{route_reason.lower()}. {direction} "
        f"(Red {red.total_score:.0f} pts, Blue {blue.total_score:.0f} pts "
        f"across {red.n_claims}+{blue.n_claims} claims)."
    )


# Convenience for `python -m app.main` — not needed under uvicorn / Vercel.
if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "3003")),
        reload=False,
    )
