"""
Trigger evaluation: given an intel pack, decide which named triggers fire.

Replace the stub with your YAML-driven logic. The expected shape is:

    triggers:
      - id: stage_aging
        when:
          stage_in: ["Stage 4 - Demo", "Stage 5 - Proposal"]
          days_in_stage_gte: 14
      - id: competitor_mentioned
        when:
          transcript_contains_any: ["openai", "gpt", "homegrown"]
      - id: champion_silent
        when:
          last_activity_days_gte: 10

Each trigger id maps to a set of personas to invoke (see personas.py).
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from .schemas import IntelPackRequest

TRIGGERS_PATH = Path(__file__).parent.parent / "config" / "triggers.yaml"


def _load_triggers() -> list[dict[str, Any]]:
    if not TRIGGERS_PATH.exists():
        return []
    raw = yaml.safe_load(TRIGGERS_PATH.read_text(encoding="utf-8")) or {}
    return raw.get("triggers", [])


def evaluate_triggers(pack: IntelPackRequest) -> list[str]:
    """
    Return the list of trigger ids that fire for this intel pack. v1 is a
    placeholder — drop your YAML-rule evaluator in here.
    """
    triggers = _load_triggers()
    # TODO: wire up real evaluation. For now: return everything labeled
    # `always_on` so end-to-end testing has something to fire on.
    fired: list[str] = []
    for t in triggers:
        when = t.get("when") or {}
        if when.get("always_on") is True:
            fired.append(t["id"])
    return fired
