"""
Intel pack retrieval: pull the most-relevant prior dead deals + competitor
quotes + objection quotes from the JSON corpora in `intel/`. Results get
embedded in the user message sent to the managed agent.

Loading is defensive — missing JSON files log a warning and degrade to empty
data rather than crashing the eval. The card will still render with whatever
evidence is available from the intel pack request itself (Gong moments,
SF fields).
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import List, Optional

from .schemas import DealContext, GongMention


_INTEL_DIR = Path(__file__).parent.parent / "intel"

_DEAD_DEALS: Optional[list] = None
_WON_DEALS: Optional[list] = None
_COMP_QUOTES: Optional[list] = None
_OBJ_QUOTES: Optional[list] = None
_COMP_PROFILES: Optional[dict] = None
_COHORT_STATS: Optional[dict] = None


def _safe_load_json(path: Path, default):
    if not path.exists():
        print(
            f"[intel_pack] WARNING: {path.name} not found in intel/; "
            f"returning empty {type(default).__name__}",
            flush=True,
        )
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(
            f"[intel_pack] WARNING: {path.name} is not valid JSON ({exc}); "
            "returning empty",
            flush=True,
        )
        return default


def _load() -> None:
    global _DEAD_DEALS, _WON_DEALS, _COMP_QUOTES, _OBJ_QUOTES, _COMP_PROFILES, _COHORT_STATS
    if _DEAD_DEALS is None:
        _DEAD_DEALS = _safe_load_json(_INTEL_DIR / "dead_deals.json", [])
        _WON_DEALS = _safe_load_json(_INTEL_DIR / "won_deals.json", [])
        _COMP_QUOTES = _safe_load_json(_INTEL_DIR / "competitor_quotes.json", [])
        _OBJ_QUOTES = _safe_load_json(_INTEL_DIR / "objection_quotes.json", [])
        _COMP_PROFILES = _safe_load_json(_INTEL_DIR / "competitor_profiles.json", {})
        _COHORT_STATS = _safe_load_json(_INTEL_DIR / "cohort_stats.json", {})


def find_deal_by_name(name: str) -> Optional[dict]:
    """Look up a prior deal by name (case-insensitive substring match). Scans
    won_deals first, then dead_deals. Returns the first hit or None."""
    _load()
    if not name or not name.strip():
        return None
    q = name.strip().lower()
    for pool in ((_WON_DEALS or []), (_DEAD_DEALS or [])):
        for d in pool:
            n = (d.get("name") or d.get("deal_name") or d.get("account") or "").lower()
            if q == n:
                return d
        for d in pool:
            n = (d.get("name") or d.get("deal_name") or d.get("account") or "").lower()
            if q in n or n in q:
                return d
    return None


def find_similar_dead_deals(
    context: DealContext,
    competitors_mentioned: List[str],
    n: int = 5,
) -> List[dict]:
    """Return the n most similar prior dead deals for context-stuffing."""
    _load()
    deals = _DEAD_DEALS or []
    if not deals:
        return []

    def score(d: dict) -> float:
        s = 0.0
        if d.get("segment") == context.segment:
            s += 3
        if d.get("business_type") == context.business_type:
            s += 3
        if d.get("amount") and context.amount:
            try:
                ratio = d["amount"] / context.amount if context.amount > 0 else 0
                if 0.5 <= ratio <= 2.0:
                    s += 2
            except (TypeError, ZeroDivisionError):
                pass
        if d.get("final_competitor") in competitors_mentioned:
            s += 4
        if competitors_mentioned and d.get("primary_reason") == "Competitive Loss":
            s += 2
        return s

    scored = sorted(deals, key=score, reverse=True)
    return scored[:n]


def find_competitor_quotes(competitors: List[str], n_per_competitor: int = 5) -> List[dict]:
    _load()
    quotes = _COMP_QUOTES or []
    out: List[dict] = []
    for comp in competitors:
        matches = [q for q in quotes if q.get("competitor") == comp]
        matches.sort(key=lambda q: -(q.get("amount") or 0))
        out.extend(matches[:n_per_competitor])
    return out


def find_objection_quotes(themes: List[str], n_per_theme: int = 4) -> List[dict]:
    _load()
    quotes = _OBJ_QUOTES or []
    out: List[dict] = []
    for theme in themes:
        matches = [q for q in quotes if q.get("theme") == theme]
        matches.sort(key=lambda q: -(q.get("amount") or 0))
        out.extend(matches[:n_per_theme])
    return out


def get_competitor_profile(competitor: str) -> Optional[dict]:
    _load()
    return (_COMP_PROFILES or {}).get(competitor)


def get_cohort_stats() -> dict:
    _load()
    return _COHORT_STATS or {}


_COMPETITOR_PATTERNS = {
    "Claude": r"\b(claude|anthropic)\b",
    "ChatGPT": r"\b(chat\s*gpt|openai)\b",
    "Hebbia": r"\bhebbia\b",
    "AlphaSense": r"\balphasense\b|\balpha\s*sense\b",
    "BlueFlame": r"\bblueflame\b|\bblue\s*flame\b",
    "Copilot": r"\bcopilot\b",
    "Gemini": r"\bgemini\b",
    "Internal_Build": r"build (it )?(internally|ourselves|our own)|in-?house",
}


def detect_competitors_in_context(context: DealContext) -> List[str]:
    """Extract competitor names from Gong mentions in the context."""
    found: List[str] = []
    for mention in context.gong_competitor_mentions + context.gong_objection_mentions:
        text = mention.excerpt or ""
        for comp, pat in _COMPETITOR_PATTERNS.items():
            if re.search(pat, text, flags=re.IGNORECASE):
                if comp not in found:
                    found.append(comp)
    return found
