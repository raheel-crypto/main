"""
End-to-end tests for POST /evaluate.

These exercise the HMAC layer + Pydantic validation + the stub runner. They
don't call Anthropic — the stub `invoke_persona` returns deterministic
placeholders. Once you wire up the real persona logic, add tests that mock
the Anthropic client.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

TEST_SECRET = "test-secret-do-not-use-in-prod"
FIXTURE = Path(__file__).parent / "fixtures" / "sample_pack.json"


@pytest.fixture(autouse=True)
def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("RED_TEAM_AGENT_SECRET", TEST_SECRET)
    monkeypatch.setenv("RED_TEAM_STATE_DIR", str(tmp_path / "state"))
    # Re-import so the env var is picked up.
    import importlib

    import app.cooldowns as cd
    import app.main as m

    importlib.reload(cd)
    importlib.reload(m)
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
