"""
HMAC verification for Merlin → Red Team requests.

Merlin signs `<timestamp>.<body>` with HMAC-SHA256 using
`RED_TEAM_AGENT_SECRET`. See `slack-bot/src/services/redTeamClient.ts:signBody`.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import time

from fastapi import HTTPException, Request, status

# 5 minutes — same skew window Gong uses for its JWT-signed webhooks.
TIMESTAMP_SKEW_SECONDS = 5 * 60


class AuthError(HTTPException):
    def __init__(self, detail: str) -> None:
        super().__init__(status_code=status.HTTP_401_UNAUTHORIZED, detail=detail)


def _secret() -> bytes:
    raw = os.getenv("RED_TEAM_AGENT_SECRET", "")
    if not raw:
        raise RuntimeError(
            "RED_TEAM_AGENT_SECRET not configured — Merlin requests will fail to verify."
        )
    return raw.encode("utf-8")


def _expected_signature(timestamp: str, body: bytes) -> str:
    payload = f"{timestamp}.".encode("utf-8") + body
    return hmac.new(_secret(), payload, hashlib.sha256).hexdigest()


async def verify_signature(request: Request) -> bytes:
    """
    FastAPI dependency: enforce a valid Merlin signature and return the raw
    request body (so the route handler can `json.loads` it without consuming
    the body twice).
    """
    body = await request.body()

    timestamp = request.headers.get("X-RedTeam-Timestamp", "")
    signature = request.headers.get("X-RedTeam-Signature", "")
    if not timestamp or not signature:
        raise AuthError("missing X-RedTeam-Signature or X-RedTeam-Timestamp")

    try:
        ts = int(timestamp)
    except ValueError as exc:
        raise AuthError("X-RedTeam-Timestamp must be a unix integer") from exc

    if abs(time.time() - ts) > TIMESTAMP_SKEW_SECONDS:
        raise AuthError("timestamp skew too large")

    expected = _expected_signature(timestamp, body)
    if not hmac.compare_digest(expected, signature):
        raise AuthError("signature mismatch")

    return body
