"""
Intel retrieval module — the import path the user's `prompt_assembly/*.py`
expects (`from ..intel import retrieval`).

Most functions delegate to our existing `app/intel_pack.py` (Red-side
retrieval over dead_deals / competitor_quotes / objection_quotes /
cohort_stats). Blue-side adds two new sources read from `intel/`:

- `won_deals.json`
- `win_pattern_quotes.json`

Defensive loading: a missing JSON file logs a warning and falls back to an
empty list/dict so /arbiter still runs (Blue's argument will just be
thinner).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, List, Optional

from .. import intel_pack
from ..schemas import DealContext

# Re-exports — the prompt_assembly files import these names directly.
detect_competitors = intel_pack.detect_competitors_in_context
find_similar_lost_deals = intel_pack.find_similar_dead_deals
find_competitor_quotes = intel_pack.find_competitor_quotes
get_cohort_stats = intel_pack.get_cohort_stats


# Project-root /intel/ (same dir as dead_deals.json, etc.).
_INTEL_DIR = Path(__file__).resolve().parent.parent.parent / "intel"

_WON_DEALS: Optional[list] = None
_WIN_QUOTES: Optional[list] = None


def _safe_load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        print(
            f"[intel/retrieval] WARNING: {path.name} not found in intel/; "
            f"Blue retrieval falls back to empty {type(default).__name__}",
            flush=True,
        )
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(
            f"[intel/retrieval] WARNING: {path.name} is not valid JSON "
            f"({exc}); returning empty",
            flush=True,
        )
        return default


def _load_won() -> list:
    global _WON_DEALS
    if _WON_DEALS is None:
        _WON_DEALS = _safe_load_json(_INTEL_DIR / "won_deals.json", [])
    return _WON_DEALS or []


def _load_win_quotes() -> list:
    global _WIN_QUOTES
    if _WIN_QUOTES is None:
        _WIN_QUOTES = _safe_load_json(_INTEL_DIR / "win_pattern_quotes.json", [])
    return _WIN_QUOTES or []


def find_similar_won_deals(
    context: DealContext, competitors_mentioned: List[str], n: int = 5
) -> List[dict]:
    """
    Same similarity-scoring shape as `find_similar_dead_deals` but reads from
    `won_deals.json`. Segment + business_type match dominates; amount band
    (0.5x..2x of current opp) adds a small boost.
    """
    deals = _load_won()
    if not deals:
        return []

    def score(d: dict) -> float:
        s = 0.0
        if d.get("segment") == context.segment:
            s += 3
        if d.get("business_type") == context.business_type:
            s += 3
        amt = d.get("amount")
        if amt and context.amount and context.amount > 0:
            try:
                ratio = amt / context.amount
                if 0.5 <= ratio <= 2.0:
                    s += 2
            except (TypeError, ZeroDivisionError):
                pass
        # Slight nudge: if the rep faced one of the same competitors as a
        # known won-against-competitor deal, that's a strong precedent.
        if d.get("final_competitor") in (competitors_mentioned or []):
            s += 2
        return s

    return sorted(deals, key=score, reverse=True)[:n]


def find_win_pattern_quotes(themes: List[str], n_per: int = 3) -> List[dict]:
    """Verbatim won-deal quotes by pattern theme (e.g. 'champion_advocacy')."""
    quotes = _load_win_quotes()
    if not quotes:
        return []
    out: List[dict] = []
    for theme in themes:
        matches = [q for q in quotes if q.get("pattern") == theme]
        matches.sort(key=lambda q: -(q.get("amount") or 0))
        out.extend(matches[:n_per])
    return out
