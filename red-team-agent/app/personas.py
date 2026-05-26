"""
Persona selection: given fired triggers, pick the 1-2 personas to fire on this
cycle.

Aggregates weights per `target_persona`, applies the configured fire threshold
+ max-personas cap, and computes the action level (`dm_rep` vs
`dm_rep_cc_manager`).

Per-persona cooldowns are tracked in-memory inside a single Vercel function
invocation only. On Vercel the filesystem is read-only and each invocation is
a fresh container, so persistent persona-level cooldown isn't possible without
a separate Postgres table. Per-opp cooldown (in `red_team_cooldowns`) already
prevents spam at the broader granularity; per-persona persistence is a
follow-up.
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import List, Tuple

import yaml

from .schemas import DealContext, FiredTrigger


_CONFIG_PATH = Path(__file__).parent.parent / "config" / "triggers.yaml"


def select_personas(
    context: DealContext,
    fired_triggers: List[FiredTrigger],
) -> Tuple[List[str], str, List[FiredTrigger]]:
    """
    Returns:
        selected_persona_ids: list of 1-2 persona ids to fire
        action: 'dm_rep' | 'dm_rep_cc_manager' | 'log_only'
                | 'below_threshold' | 'no_triggers'
        triggers_supporting: subset of fired_triggers backing the selected personas
    """
    with open(_CONFIG_PATH) as f:
        config = yaml.safe_load(f)
    settings = config["settings"]

    if not fired_triggers:
        return ([], "no_triggers", [])

    # Gate: minimum amount
    if context.amount < settings["min_amount_to_fire_usd"]:
        return ([], "below_threshold", [])

    # Aggregate weights per persona
    persona_scores: dict[str, float] = defaultdict(float)
    persona_evidence: dict[str, List[FiredTrigger]] = defaultdict(list)
    for trig in fired_triggers:
        persona_scores[trig.target_persona] += trig.weight
        persona_evidence[trig.target_persona].append(trig)

    # Filter below fire threshold
    threshold = settings["fire_threshold"]
    eligible = {p: s for p, s in persona_scores.items() if s >= threshold}
    if not eligible:
        return ([], "below_threshold", [])

    # Top N personas, sorted by score
    top = sorted(eligible.items(), key=lambda x: -x[1])[
        : settings["max_personas_per_cycle"]
    ]
    selected_ids = [p for p, _ in top]

    top_score = top[0][1]
    action = (
        "dm_rep_cc_manager"
        if top_score >= settings["manager_cc_threshold"]
        else "dm_rep"
    )

    supporting: List[FiredTrigger] = []
    for p in selected_ids:
        supporting.extend(persona_evidence[p])

    return (selected_ids, action, supporting)
