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
from typing import Annotated, Iterable, List

from fastapi import Depends, FastAPI, HTTPException, status

from . import personas as personas_mod
from . import runner
from . import triggers as triggers_mod
from .auth import verify_signature
from .context import pack_to_context
from .cooldowns import is_cooled_down, mark_evaluated
from .schemas import (
    AgentArgument,
    Claim,
    Citation as AgentCitation,
    DealContext,
    FiredTrigger,
    IntelPackRequest,
    PersonaArgument,
    RunResult,
    WireCitation,
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
    Squash the agent's richer AgentArgument (multiple claims + recommended
    actions) into Merlin's flat PersonaArgument. The Slack card renders
    `headline`, `claim` (free-text), and up to 4 citations.

    The richer shape will land in a follow-up that expands Merlin's
    `RedTeamPersonaArgument` schema + card; for now we surface everything as
    a single composed `claim` string so reps see the full content.
    """
    claim_lines: list[str] = []
    for idx, c in enumerate(arg.claims, 1):
        line = f"{idx}. {c.statement}"
        if c.pattern_match:
            line += f"  _Pattern: {c.pattern_match}_"
        claim_lines.append(line)

    if arg.recommended_actions:
        claim_lines.append("")
        claim_lines.append("*Recommended actions this week:*")
        for ra in arg.recommended_actions:
            claim_lines.append(
                f"• {ra.action} — _owner: {ra.owner_role}; by {ra.by_date}; "
                f"signal: {ra.expected_signal}_"
            )

    claim = "\n".join(claim_lines) if claim_lines else "(no claims)"

    citations = list(_flatten_citations(arg.claims))[:4]

    return PersonaArgument(
        persona=arg.persona_id,
        headline=arg.headline,
        claim=claim,
        citations=citations,
        riskScore=_risk_score(action, supporting),
    )


def _flatten_citations(claims: List[Claim]) -> Iterable[WireCitation]:
    for claim in claims:
        for c in claim.citations:
            yield _agent_citation_to_wire(c)


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


# Convenience for `python -m app.main` — not needed under uvicorn / Vercel.
if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "3003")),
        reload=False,
    )
