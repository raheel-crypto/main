"""
FastAPI entry point.

Run locally:
    uvicorn app.main:app --reload --port 3003
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, status

from .auth import verify_signature
from .cooldowns import is_cooled_down, mark_evaluated
from .personas import select_personas
from .runner import render_audit_entry, run_personas
from .schemas import IntelPackRequest, RunResult
from .triggers import evaluate_triggers

app = FastAPI(title="Red Team Agent", version="0.1.0")


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

    # Cooldown short-circuit — same opp, recent eval → drop with a reason
    # Merlin will audit.
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

    fired = evaluate_triggers(pack)
    if not fired:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=[],
            personasInvoked=[],
            auditLogEntry="",
            dropReason="no_triggers_fired",
        )

    persona_ids = select_personas(fired)
    if not persona_ids:
        return RunResult(
            evaluatedAt=evaluated_at,
            shadowMode=pack.shadowMode,
            firedTriggers=fired,
            personasInvoked=[],
            auditLogEntry="",
            dropReason="no_personas_for_triggers",
        )

    personas = await run_personas(pack, persona_ids)
    cooldown_iso = mark_evaluated(pack.opportunity.id)

    return RunResult(
        evaluatedAt=evaluated_at,
        shadowMode=pack.shadowMode,
        firedTriggers=fired,
        personasInvoked=personas,
        auditLogEntry=render_audit_entry(pack, fired, personas),
        cooldownUntilIso=cooldown_iso,
    )


# Convenience for `python -m app.main` — not needed under uvicorn.
if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "3003")),
        reload=False,
    )
