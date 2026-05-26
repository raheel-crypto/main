"""
Per-opportunity eval cooldowns.

v1 is file-backed and assumes single-instance deployment. If you deploy to
Vercel functions (stateless) or scale horizontally, move this to Postgres /
Redis — the interface (`get` / `set` / `clear`) is the only thing other
modules depend on.
"""
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

STATE_DIR = Path(os.getenv("RED_TEAM_STATE_DIR", str(Path(__file__).parent.parent / "state")))
STATE_PATH = STATE_DIR / "cooldowns.json"

DEFAULT_COOLDOWN_MINUTES = int(os.getenv("RED_TEAM_COOLDOWN_MINUTES", "60"))

_lock = threading.Lock()


def _read() -> dict[str, str]:
    if not STATE_PATH.exists():
        return {}
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _write(state: dict[str, str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")


def is_cooled_down(opportunity_id: str) -> str | None:
    """
    Returns the cooldown expiry ISO timestamp if the opp is currently cooled
    down. Returns None if a new eval is allowed.
    """
    with _lock:
        state = _read()
        iso = state.get(opportunity_id)
    if not iso:
        return None
    try:
        until = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    if until > datetime.now(timezone.utc):
        return iso
    return None


def mark_evaluated(
    opportunity_id: str, minutes: int = DEFAULT_COOLDOWN_MINUTES
) -> str:
    """
    Record an eval for this opp; future calls before the cooldown expires
    return the expiry ISO from `is_cooled_down`. Returns the new expiry.
    """
    until = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    iso = until.isoformat()
    with _lock:
        state = _read()
        state[opportunity_id] = iso
        _write(state)
    return iso


def clear(opportunity_id: str) -> None:
    """Manual override for ops / debugging."""
    with _lock:
        state = _read()
        if opportunity_id in state:
            del state[opportunity_id]
            _write(state)
