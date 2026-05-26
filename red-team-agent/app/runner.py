"""
The Claude tool-use loop.

Given an intel pack + the personas selected for this eval, invoke each persona
with the appropriate system prompt and return `PersonaArgument` objects with
citations.

This file is intentionally a stub — drop in your existing logic (likely an
Anthropic SDK `messages.create` call per persona, plus your retrieval over
intel/dead_deals.json + intel/competitor_quotes.json + the pack's gongCalls).

When wiring it up:
- Pass the pack as JSON in the user message so the persona can reason over
  the full context (custom fields, transcripts, field changes).
- The persona's job is to produce {headline, claim, citations[]}. Citations
  must point to real records (a dead-deal id from intel/, a Gong call+timestamp
  from the pack, etc.) — don't let the model invent sources.
- riskScore is 0..1; calibrate per-persona so the card's color badge stays
  meaningful.
"""
from __future__ import annotations

import os
from typing import Any

from .personas import load_prompt
from .schemas import Citation, IntelPackRequest, PersonaArgument

MODEL = os.getenv("RED_TEAM_MODEL", "claude-sonnet-4-20250514")
MAX_TOKENS = int(os.getenv("RED_TEAM_MAX_TOKENS", "2048"))


async def invoke_persona(
    persona_id: str, pack: IntelPackRequest
) -> PersonaArgument | None:
    """
    Run a single persona against the intel pack. Return None when the persona
    has nothing to say (the runner will drop it from the card).
    """
    try:
        system_prompt = load_prompt(persona_id)
    except FileNotFoundError:
        # Stub mode: prompts not authored yet — produce a placeholder so the
        # end-to-end smoke test stays green until prompts land.
        return PersonaArgument(
            persona=persona_id,
            headline=f"[stub] {persona_id} would weigh in here.",
            claim=(
                "Replace app/runner.py:invoke_persona with the real Anthropic "
                "SDK call. Prompts go in prompts/<persona_id>.md."
            ),
            citations=[],
            riskScore=0.0,
        )

    # TODO: real implementation.
    # async with anthropic.AsyncAnthropic() as client:
    #     msg = await client.messages.create(
    #         model=MODEL,
    #         max_tokens=MAX_TOKENS,
    #         system=system_prompt,
    #         messages=[{"role": "user", "content": _render_pack(pack)}],
    #     )
    #     return _parse_persona_response(persona_id, msg)
    _ = system_prompt  # silence unused-var lint until real impl lands
    return PersonaArgument(
        persona=persona_id,
        headline="[stub] persona logic not yet implemented",
        claim="Wire up app/runner.py:invoke_persona to your Anthropic call.",
        citations=[],
        riskScore=0.0,
    )


async def run_personas(
    pack: IntelPackRequest, persona_ids: list[str]
) -> list[PersonaArgument]:
    """
    Run the selected personas. Concurrency is intentionally serial in the
    stub; switch to `asyncio.gather` once the real Claude calls land if
    latency demands it.
    """
    out: list[PersonaArgument] = []
    for pid in persona_ids:
        arg = await invoke_persona(pid, pack)
        if arg is not None:
            out.append(arg)
    return out


def render_audit_entry(
    pack: IntelPackRequest,
    fired_triggers: list[str],
    personas: list[PersonaArgument],
) -> str:
    """Free-text audit-log entry. Format however your downstream wants it."""
    lines = [
        f"Red Team eval — {pack.opportunity.name} ({pack.opportunity.id})",
        f"Trigger: {pack.triggerEvent}; fired={','.join(fired_triggers) or 'none'}",
    ]
    for p in personas:
        lines.append(f"  · {p.persona} (risk {p.riskScore:.2f}): {p.headline}")
    return "\n".join(lines)


def _silence(_: Any) -> None:
    """Internal placeholder so future imports stay tidy."""
