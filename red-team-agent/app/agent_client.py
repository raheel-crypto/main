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


def _extract_assistant_text(event_envelope: dict[str, Any]) -> str | None:
    """
    Best-effort extraction of plain assistant text from an SSE event. Managed
    agents emit text in several shapes depending on the event type; we sniff
    the common ones rather than assume one. Returns None if no text-like
    content is present.
    """
    data = event_envelope.get("data") or {}
    # Direct text field
    text = data.get("text")
    if isinstance(text, str) and text.strip():
        return text
    # delta.text shape
    delta = data.get("delta") or {}
    if isinstance(delta, dict):
        dt = delta.get("text")
        if isinstance(dt, str) and dt.strip():
            return dt
    # content blocks shape: [{type:"text", text:"..."}]
    content = data.get("content")
    if isinstance(content, list):
        out: list[str] = []
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                t = blk.get("text")
                if isinstance(t, str):
                    out.append(t)
        if out:
            return "".join(out)
    # message.content shape
    msg = data.get("message") or {}
    if isinstance(msg, dict):
        mc = msg.get("content")
        if isinstance(mc, list):
            out = []
            for blk in mc:
                if isinstance(blk, dict) and blk.get("type") == "text":
                    t = blk.get("text")
                    if isinstance(t, str):
                        out.append(t)
            if out:
                return "".join(out)
    return None


async def run_tool_loop(
    title: str,
    user_message: str,
    *,
    tool_handlers: dict[str, Any],
    agent_env_name: str,
    environment_env_name: str,
    vault_env_name: str,
    max_hops: int = 4,
) -> dict[str, Any]:
    """
    Multi-hop tool-use loop for the Arbiter Moderator.

    `tool_handlers` maps tool name → `async def(tool_input) -> tuple[dict, str]`
    where the returned tuple is `(result_payload_for_agent, summary_for_audit)`.
    The result_payload is JSON-serialized and sent back as the
    `user.custom_tool_result`; the summary is recorded in `tool_calls[].result_summary`
    for downstream audit / Slack rendering.

    Stops on:
      • `session.status_idle` / `session.completed` (clean finish)
      • `max_hops` exceeded (the agent's prompt forbids further calls after this)
      • Tool handler raises (recorded as `is_error: true`, agent may recover)

    Returns `{"text": str, "tool_calls": list[{tool, input, result_summary}], "hops_used": int}`.
    """
    session_id = await create_session(
        title=title,
        agent_env_name=agent_env_name,
        environment_env_name=environment_env_name,
        vault_env_name=vault_env_name,
    )
    print(f"[moderator_client] session={session_id} title={title!r}", flush=True)
    await send_user_message(session_id, user_message)

    text_buf: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    hops_used = 0
    event_count = 0
    seen_idle = False

    async for event in stream_events(session_id):
        event_count += 1
        et = _event_type_of(event)
        data = event.get("data") or {}
        data_preview = json.dumps(data)[:600]
        print(
            f"[moderator_client] event#{event_count} type={et!r} data={data_preview}",
            flush=True,
        )

        # 1. Text capture
        chunk = _extract_assistant_text(event)
        if chunk:
            text_buf.append(chunk)

        # 2. Tool-use detection (structural — see notes on run_one_shot)
        has_tool_use_shape = (
            isinstance(data.get("input"), dict) and isinstance(data.get("id"), str)
        )
        looks_like_tool_use = (
            et == "agent.custom_tool_use"
            or "custom_tool_use" in et
            or has_tool_use_shape
        )

        if looks_like_tool_use:
            tool_use_id = (
                data.get("custom_tool_use_id")
                or data.get("id")
                or data.get("tool_use_id")
            )
            tool_input = (
                data.get("input")
                or data.get("arguments")
                or data.get("payload")
                or {}
            )
            tool_name = data.get("tool_name") or data.get("name") or ""

            handler = tool_handlers.get(tool_name)
            if handler is None:
                # Unknown tool — fail soft so the agent can pivot.
                err_payload = {
                    "error": f"unknown_tool: {tool_name}",
                    "available": sorted(tool_handlers.keys()),
                }
                if tool_use_id:
                    await send_custom_tool_result(
                        session_id, tool_use_id, err_payload, is_error=True
                    )
                tool_calls.append({
                    "tool": tool_name,
                    "input": tool_input,
                    "result_summary": f"unknown_tool: {tool_name}",
                })
                continue

            if hops_used >= max_hops:
                # Tell the agent to wrap up.
                err_payload = {
                    "error": "max_hops_exceeded",
                    "message": "Finalize your reply now without further tool calls.",
                }
                if tool_use_id:
                    await send_custom_tool_result(
                        session_id, tool_use_id, err_payload, is_error=True
                    )
                tool_calls.append({
                    "tool": tool_name,
                    "input": tool_input,
                    "result_summary": "max_hops_exceeded",
                })
                continue

            hops_used += 1
            try:
                payload, summary = await handler(tool_input)
            except Exception as exc:  # noqa: BLE001 — surface to agent
                payload = {"error": str(exc)[:300]}
                summary = f"handler_error: {str(exc)[:120]}"
                if tool_use_id:
                    await send_custom_tool_result(
                        session_id, tool_use_id, payload, is_error=True
                    )
                tool_calls.append({
                    "tool": tool_name,
                    "input": tool_input,
                    "result_summary": summary,
                })
                continue

            if tool_use_id:
                await send_custom_tool_result(session_id, tool_use_id, payload)
            tool_calls.append({
                "tool": tool_name,
                "input": tool_input,
                "result_summary": summary,
            })
            print(
                f"[moderator_client] hop {hops_used}/{max_hops} tool={tool_name} ok",
                flush=True,
            )

        elif et in ("session.status_idle", "session.completed"):
            seen_idle = True
            break
        elif et == "session.error":
            raise ManagedAgentError(f"session error: {data}")

    final_text = "".join(text_buf).strip()
    print(
        f"[moderator_client] stream end events={event_count} idle={seen_idle} "
        f"hops={hops_used} text_len={len(final_text)} tools_called={len(tool_calls)}",
        flush=True,
    )
    return {
        "text": final_text,
        "tool_calls": tool_calls,
        "hops_used": hops_used,
    }


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

        # Structural match for the tool use: any event whose data carries
        # both an event id and a structured `input` payload. We don't rely
        # solely on the `type` field because Anthropic's stream sometimes
        # carries the discriminator outside our expected key.
        data = event.get("data") or {}
        has_tool_use_shape = (
            isinstance(data.get("input"), dict) and isinstance(data.get("id"), str)
        )
        looks_like_tool_use = (
            et == "agent.custom_tool_use"
            or "custom_tool_use" in et
            or has_tool_use_shape
        )

        if tool_input is None and looks_like_tool_use:
            tool_use_id, tool_input_candidate = _extract_custom_tool_use(
                event, tool_name
            )
            if tool_input_candidate is None:
                print(
                    f"[agent_client] looks like tool use but extract failed; "
                    f"keys={list(data.keys())}",
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
