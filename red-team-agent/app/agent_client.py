"""
Thin async client for Anthropic's Managed Agents API.

We don't manage agent versions here — the agent ID is a string shorthand that
Anthropic resolves to the latest published version.

Session lifecycle for a single Red Team eval:
  1. create_session(title)
  2. send_user_message(session_id, text)         # the deal package
  3. stream_events(session_id)                    # SSE; watch for agent.custom_tool_use
  4. on submit_argument tool use: capture input, send_custom_tool_result
  5. break on session.status_idle

`run_one_shot_with_custom_tool` wraps the whole flow and returns the tool input.

Auth headers come from env (ANTHROPIC_API_KEY, *_AGENT_ID, *_ENVIRONMENT_ID,
*_VAULT_IDS). Currently configured for the Red Team agent — Blue and Arbiter
will read their own env vars and call into this same client.
"""
from __future__ import annotations

import json
import os
from typing import Any, AsyncIterator

import httpx

API_BASE = "https://api.anthropic.com"
API_VERSION = "2023-06-01"
BETA_HEADER = "managed-agents-2026-04-01"

# Sessions auto-time-out on Anthropic's side; we just need our client to outlive
# the longest persona eval. 90s matches Merlin's outbound timeout.
STREAM_TIMEOUT_SECONDS = 90.0
REQUEST_TIMEOUT_SECONDS = 30.0


class ManagedAgentError(Exception):
    pass


def _headers() -> dict[str, str]:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise ManagedAgentError("ANTHROPIC_API_KEY not set")
    return {
        "x-api-key": key,
        "anthropic-version": API_VERSION,
        "anthropic-beta": BETA_HEADER,
        "Content-Type": "application/json",
    }


def _parse_vault_ids(env_name: str) -> list[str]:
    raw = os.getenv(env_name, "")
    return [v.strip() for v in raw.split(",") if v.strip()]


async def create_session(
    title: str,
    *,
    agent_env_name: str = "RED_TEAM_AGENT_ID",
    environment_env_name: str = "RED_TEAM_ENVIRONMENT_ID",
    vault_env_name: str = "RED_TEAM_VAULT_IDS",
) -> str:
    agent_id = os.environ.get(agent_env_name)
    environment_id = os.environ.get(environment_env_name)
    if not agent_id:
        raise ManagedAgentError(f"{agent_env_name} not set")
    if not environment_id:
        raise ManagedAgentError(f"{environment_env_name} not set")

    body: dict[str, Any] = {
        "agent": agent_id,
        "environment_id": environment_id,
        "title": title,
    }
    vault_ids = _parse_vault_ids(vault_env_name)
    if vault_ids:
        body["vault_ids"] = vault_ids

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        r = await client.post(f"{API_BASE}/v1/sessions", headers=_headers(), json=body)
    if r.status_code >= 400:
        raise ManagedAgentError(
            f"create_session {r.status_code}: {r.text[:400]}"
        )
    data = r.json()
    sid = data.get("id")
    if not sid:
        raise ManagedAgentError(f"create_session returned no id: {data}")
    return sid


async def send_user_message(session_id: str, text: str) -> None:
    body = {
        "events": [
            {
                "type": "user.message",
                "content": [{"type": "text", "text": text}],
            }
        ]
    }
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        r = await client.post(
            f"{API_BASE}/v1/sessions/{session_id}/events",
            headers=_headers(),
            json=body,
        )
    if r.status_code >= 400:
        raise ManagedAgentError(
            f"send_user_message {r.status_code}: {r.text[:400]}"
        )


async def send_custom_tool_result(
    session_id: str,
    custom_tool_use_id: str,
    result: dict[str, Any],
    *,
    is_error: bool = False,
) -> None:
    body = {
        "events": [
            {
                "type": "user.custom_tool_result",
                "custom_tool_use_id": custom_tool_use_id,
                "content": [{"type": "text", "text": json.dumps(result)}],
                "is_error": is_error,
            }
        ]
    }
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
        r = await client.post(
            f"{API_BASE}/v1/sessions/{session_id}/events",
            headers=_headers(),
            json=body,
        )
    if r.status_code >= 400:
        raise ManagedAgentError(
            f"send_custom_tool_result {r.status_code}: {r.text[:400]}"
        )


async def stream_events(session_id: str) -> AsyncIterator[dict[str, Any]]:
    """
    Yields `{"event": <event_type>, "data": <parsed_json>}` for each SSE message.
    Closes the stream when the upstream closes or the consumer breaks.
    """
    timeout = httpx.Timeout(STREAM_TIMEOUT_SECONDS, connect=10.0, read=STREAM_TIMEOUT_SECONDS)
    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "GET",
            f"{API_BASE}/v1/sessions/{session_id}/events/stream",
            headers=_headers(),
        ) as r:
            if r.status_code >= 400:
                body = await r.aread()
                raise ManagedAgentError(
                    f"stream {r.status_code}: {body.decode('utf-8', 'replace')[:400]}"
                )
            event_type: str | None = None
            data_lines: list[str] = []
            async for line in r.aiter_lines():
                if line == "":
                    if data_lines:
                        joined = "\n".join(data_lines)
                        try:
                            parsed = json.loads(joined)
                        except json.JSONDecodeError:
                            parsed = {"_raw": joined}
                        yield {"event": event_type, "data": parsed}
                    event_type = None
                    data_lines = []
                    continue
                if line.startswith(":"):
                    # SSE comment / keepalive
                    continue
                if line.startswith("event:"):
                    event_type = line[len("event:") :].strip()
                elif line.startswith("data:"):
                    data_lines.append(line[len("data:") :].lstrip())


def _event_type_of(event_envelope: dict[str, Any]) -> str:
    """
    Anthropic's managed-agent SSE emits every line as `event: message` and puts
    the actual event-type discriminator inside `data.type`. Prefer the data
    type; fall back to the SSE event name only if data has no type.
    """
    data = event_envelope.get("data") or {}
    type_in_data = data.get("type")
    if type_in_data:
        return type_in_data
    return event_envelope.get("event") or ""


def _extract_custom_tool_use(
    event_envelope: dict[str, Any], tool_name: str
) -> tuple[str | None, dict[str, Any] | None]:
    """
    Pull the (custom_tool_use_id, input) from a custom_tool_use event.

    Anthropic's managed-agent payload doesn't include a `tool_name` field on
    the event itself — the tool is identified at the session level. We accept
    any custom_tool_use event and trust that our agent only has one custom
    tool registered (the caller filters by name if multiple tools exist).
    `tool_name` is retained for the parameter signature; we still surface
    keys on mismatch when needed.
    """
    data = event_envelope.get("data") or {}
    tool_use_id = (
        data.get("custom_tool_use_id")
        or data.get("id")
        or data.get("tool_use_id")
    )
    tool_input = (
        data.get("input")
        or data.get("arguments")
        or data.get("payload")
    )
    if tool_input is None:
        # No input payload present — surface the keys for debugging.
        return (None, None)
    name_field = data.get("tool_name") or data.get("name")
    if name_field and name_field != tool_name:
        # Different named tool — skip; let the agent continue.
        return (None, None)
    return (tool_use_id, tool_input)


async def run_one_shot_with_custom_tool(
    title: str,
    user_message: str,
    *,
    tool_name: str = "submit_argument",
    agent_env_name: str = "RED_TEAM_AGENT_ID",
    environment_env_name: str = "RED_TEAM_ENVIRONMENT_ID",
    vault_env_name: str = "RED_TEAM_VAULT_IDS",
) -> dict[str, Any]:
    """
    End-to-end one-shot: create session → send message → wait for the named
    custom tool use → ack → return the tool's input payload.

    Raises ManagedAgentError if the agent never calls the tool, or if any API
    call fails.
    """
    session_id = await create_session(
        title=title,
        agent_env_name=agent_env_name,
        environment_env_name=environment_env_name,
        vault_env_name=vault_env_name,
    )
    print(f"[agent_client] session={session_id} title={title!r}", flush=True)
    await send_user_message(session_id, user_message)

    tool_input: dict[str, Any] | None = None
    seen_idle = False
    event_count = 0

    async for event in stream_events(session_id):
        event_count += 1
        et = _event_type_of(event)
        # Truncated preview helps diagnose shape mismatches without flooding
        # logs.  For high-volume sessions, drop to print only certain events.
        data_preview = json.dumps(event.get("data") or {})[:600]
        print(
            f"[agent_client] event#{event_count} type={et!r} data={data_preview}",
            flush=True,
        )

        if et == "agent.custom_tool_use":
            tool_use_id, tool_input_candidate = _extract_custom_tool_use(
                event, tool_name
            )
            if tool_input_candidate is None:
                print(
                    f"[agent_client] custom_tool_use didn't match {tool_name!r}; "
                    f"keys={list((event.get('data') or {}).keys())}",
                    flush=True,
                )
                continue
            tool_input = tool_input_candidate
            print(
                f"[agent_client] captured {tool_name} input "
                f"keys={list(tool_input.keys())} use_id={tool_use_id}",
                flush=True,
            )
            if tool_use_id:
                await send_custom_tool_result(
                    session_id, tool_use_id, {"status": "received"}
                )
                print(f"[agent_client] acked {tool_name}", flush=True)
            else:
                print(
                    f"[agent_client] missing custom_tool_use_id in event: {event}",
                    flush=True,
                )
        elif et in ("session.status_idle", "session.completed"):
            seen_idle = True
            break
        elif et == "session.error":
            data = event.get("data") or {}
            raise ManagedAgentError(f"session error: {data}")

    print(
        f"[agent_client] stream ended events={event_count} idle={seen_idle} "
        f"tool_input_captured={tool_input is not None}",
        flush=True,
    )

    if tool_input is None:
        raise ManagedAgentError(
            f"agent never called {tool_name} (session={session_id}, idle_seen={seen_idle})"
        )
    return tool_input
