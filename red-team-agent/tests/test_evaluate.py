"""
End-to-end tests for POST /evaluate.

The HMAC layer + Pydantic validation + the stub runner are exercised; the
real Anthropic client isn't (the stub `invoke_persona` returns deterministic
placeholders). Once you wire up persona logic, add tests that mock the
Anthropic client.

Cooldowns are backed by Postgres in prod but stubbed with an in-memory dict
here so the suite stays self-contained — no Docker postgres required.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

TEST_SECRET = "test-secret-do-not-use-in-prod"
FIXTURE = Path(__file__).parent / "fixtures" / "sample_pack.json"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("RED_TEAM_AGENT_SECRET", TEST_SECRET)

    import app.cooldowns as cd
    import app.main as m

    store: dict[str, datetime] = {}

    def fake_is_cooled_down(opp_id: str) -> str | None:
        until = store.get(opp_id)
        if not until:
            return None
        if until <= datetime.now(timezone.utc):
            return None
        return until.isoformat()

    def fake_mark_evaluated(
        opp_id: str, minutes: int = cd.DEFAULT_COOLDOWN_MINUTES
    ) -> str:
        until = datetime.now(timezone.utc) + timedelta(minutes=minutes)
        store[opp_id] = until
        return until.isoformat()

    def fake_clear(opp_id: str) -> None:
        store.pop(opp_id, None)

    # main.py imports the names directly, so patch both modules to be safe.
    monkeypatch.setattr(cd, "is_cooled_down", fake_is_cooled_down)
    monkeypatch.setattr(cd, "mark_evaluated", fake_mark_evaluated)
    monkeypatch.setattr(cd, "clear", fake_clear)
    monkeypatch.setattr(m, "is_cooled_down", fake_is_cooled_down)
    monkeypatch.setattr(m, "mark_evaluated", fake_mark_evaluated)

    return m


@pytest.fixture
def client(_env):
    return TestClient(_env.app)


def _sign(body: bytes, ts: str) -> str:
    return hmac.new(
        TEST_SECRET.encode(), f"{ts}.".encode() + body, hashlib.sha256
    ).hexdigest()


def _post(client, body: bytes, *, ts: str | None = None, sig: str | None = None):
    timestamp = ts or str(int(time.time()))
    signature = sig or _sign(body, timestamp)
    return client.post(
        "/evaluate",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-RedTeam-Timestamp": timestamp,
            "X-RedTeam-Signature": signature,
        },
    )


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["ok"] == "true"


def test_evaluate_happy_path(client):
    body = FIXTURE.read_bytes()
    r = _post(client, body)
    assert r.status_code == 200, r.text
    data = r.json()
    assert "evaluatedAt" in data
    assert data["shadowMode"] is True
    # Smoke trigger always fires → at least one persona invoked.
    assert data["firedTriggers"] == ["smoke_test"]
    assert len(data["personasInvoked"]) >= 1
    assert data["cooldownUntilIso"]
    assert data["dropReason"] is None


def test_evaluate_cooldown_blocks_second_call(client):
    body = FIXTURE.read_bytes()
    first = _post(client, body)
    assert first.status_code == 200

    second = _post(client, body)
    assert second.status_code == 200
    data = second.json()
    assert data["dropReason"] == "cooldown"
    assert data["personasInvoked"] == []


def test_missing_signature_rejected(client):
    body = FIXTURE.read_bytes()
    r = client.post(
        "/evaluate",
        content=body,
        headers={"Content-Type": "application/json"},
    )
    assert r.status_code == 401


def test_wrong_signature_rejected(client):
    body = FIXTURE.read_bytes()
    r = _post(client, body, sig="0" * 64)
    assert r.status_code == 401


def test_stale_timestamp_rejected(client):
    body = FIXTURE.read_bytes()
    stale = str(int(time.time()) - 3600)  # 1 hour old
    r = _post(client, body, ts=stale)
    assert r.status_code == 401


def test_bad_json_rejected(client):
    r = _post(client, b"not json at all")
    assert r.status_code == 400


def test_invalid_pack_rejected(client):
    # Missing required `opportunity` field.
    body = json.dumps({"schemaVersion": "1"}).encode()
    r = _post(client, body)
    assert r.status_code == 400
