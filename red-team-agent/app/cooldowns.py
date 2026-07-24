"""
Per-opportunity eval cooldowns, backed by the shared Postgres database the
slack-bot also uses.

Public interface (`is_cooled_down`, `mark_evaluated`, `clear`) is unchanged
from the file-backed v1, so app/main.py needs no edits when swapping
backends. The slack-bot owns the `red_team_cooldowns` table migration in
slack-bot/src/db/schema.sql — this module only reads and writes.

The connection pool is lazy: import-time failure to find `POSTGRES_URL`
raises only when a route actually touches a cooldown, so `/health` stays
green even if the DB is unreachable.
"""
from __future__ import annotations

import os
import threading
from datetime import datetime, timedelta, timezone

import psycopg
from psycopg_pool import ConnectionPool

DEFAULT_COOLDOWN_MINUTES = int(os.getenv("RED_TEAM_COOLDOWN_MINUTES", "60"))

_pool: ConnectionPool | None = None
_pool_lock = threading.Lock()


def _get_pool() -> ConnectionPool:
    global _pool
    if _pool is not None:
        return _pool
    with _pool_lock:
        if _pool is not None:
            return _pool
        url = os.getenv("POSTGRES_URL") or os.getenv("DATABASE_URL")
        if not url:
            raise RuntimeError(
                "POSTGRES_URL (or DATABASE_URL) must be set for cooldown storage"
            )
        # min_size=0 so cold starts don't block on a warm pool; small max for
        # Vercel functions where concurrency per instance is low.
        _pool = ConnectionPool(
            conninfo=url,
            min_size=0,
            max_size=int(os.getenv("RED_TEAM_PG_MAX_CONNS", "4")),
            kwargs={"autocommit": True},
        )
        return _pool


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def is_cooled_down(opportunity_id: str) -> str | None:
    """
    Returns the cooldown expiry ISO timestamp if the opp is currently cooled
    down. Returns None if a new eval is allowed.
    """
    pool = _get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT cooled_until FROM red_team_cooldowns WHERE opportunity_id = %s",
            (opportunity_id,),
        ).fetchone()
    if not row:
        return None
    cooled_until: datetime = row[0]
    if cooled_until.tzinfo is None:
        cooled_until = cooled_until.replace(tzinfo=timezone.utc)
    if cooled_until <= _now_utc():
        return None
    return cooled_until.isoformat()


def mark_evaluated(
    opportunity_id: str, minutes: int = DEFAULT_COOLDOWN_MINUTES
) -> str:
    """
    Record an eval for this opp. Future calls within the cooldown window
    return the expiry from `is_cooled_down`. Returns the new expiry ISO.
    """
    until = _now_utc() + timedelta(minutes=minutes)
    pool = _get_pool()
    with pool.connection() as conn:
        conn.execute(
            """
            INSERT INTO red_team_cooldowns (opportunity_id, cooled_until, updated_at)
            VALUES (%s, %s, now())
            ON CONFLICT (opportunity_id) DO UPDATE SET
              cooled_until = EXCLUDED.cooled_until,
              updated_at = now()
            """,
            (opportunity_id, until),
        )
    return until.isoformat()


def clear(opportunity_id: str) -> None:
    """Manual override for ops / debugging."""
    pool = _get_pool()
    with pool.connection() as conn:
        conn.execute(
            "DELETE FROM red_team_cooldowns WHERE opportunity_id = %s",
            (opportunity_id,),
        )


# Re-export so tests can swap the pool getter with an in-memory fake.
__all__ = [
    "DEFAULT_COOLDOWN_MINUTES",
    "clear",
    "is_cooled_down",
    "mark_evaluated",
]

# `psycopg` is referenced via the pool; keep an explicit import so static
# analyzers don't strip it from the requirements set.
_ = psycopg.__name__
