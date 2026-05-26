"""
Persona selection + prompt loading.

`select_personas(fired_triggers)` returns the list of persona ids to invoke
for this eval. Cap is 2 per the v1 spec — too many adversaries on one card
turns into noise.

`load_prompt(persona_id)` reads the Markdown system prompt from prompts/.
"""
from __future__ import annotations

from pathlib import Path

PROMPTS_DIR = Path(__file__).parent.parent / "prompts"

# Trigger id → ranked list of personas it can invoke. Drop in your real
# mapping; the runner takes the top-N distinct personas across all fired
# triggers.
TRIGGER_TO_PERSONAS: dict[str, list[str]] = {
    "stage_aging": ["cfo_procurement", "internal_build_advocate"],
    "competitor_mentioned": ["claude_ae", "openai_ae"],
    "champion_silent": ["internal_build_advocate", "cfo_procurement"],
    "security_question_unanswered": ["ciso_persona"],
    "discount_pressure": ["cfo_procurement"],
    # Used by the placeholder always-on trigger so smoke tests have something
    # to render.
    "smoke_test": ["claude_ae"],
}

MAX_PERSONAS_PER_EVAL = 2


def select_personas(fired_triggers: list[str]) -> list[str]:
    """
    Deduplicate by first appearance, cap at MAX_PERSONAS_PER_EVAL. Order
    matters — the first persona renders at the top of the card.
    """
    seen: list[str] = []
    for t in fired_triggers:
        for p in TRIGGER_TO_PERSONAS.get(t, []):
            if p not in seen:
                seen.append(p)
            if len(seen) >= MAX_PERSONAS_PER_EVAL:
                return seen
    return seen


def load_prompt(persona_id: str) -> str:
    path = PROMPTS_DIR / f"{persona_id}.md"
    if not path.exists():
        raise FileNotFoundError(f"missing persona prompt: {path}")
    return path.read_text(encoding="utf-8")
