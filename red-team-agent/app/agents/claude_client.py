"""
Shim that exposes the `call_agent(system_prompt, user_message, team, persona_id)`
function the user-authored `arbiter/multi_turn.py` expects, on top of our
existing managed-agent SDK (`app/agent_client.py`).

Why a shim?
- The README's design has the bot call `messages.create()` directly with a
  fully-built system prompt (red/blue base + persona content concatenated).
- Our deployed service uses Anthropic's Managed Agents API. Each agent has a
  fixed system prompt registered on the Anthropic side; we can't override it
  per call. The persona content + Round 2 constraint flow inline in the
  user message instead.

This shim accepts the user's signature, ignores the (server-side-controlled)
system prompt, dispatches to the correct managed-agent env-var triplet based
on `team`, and returns a `TeamArgument` parsed from `submit_argument`.
"""
from __future__ import annotations

from typing import Literal

from ..agent_client import run_one_shot_with_custom_tool
from ..schemas import AgentArgument, TeamArgument


async def call_agent(
    system_prompt: str,  # noqa: ARG001 - managed agent has its own system prompt
    user_message: str,
    *,
    team: Literal["red", "blue"],
    persona_id: str,
) -> TeamArgument:
    """
    Invoke the right managed agent (RedHat or BlueHat Merlin) for a
    single-shot tool-use response. The `system_prompt` argument is accepted
    for compatibility with the user's arbiter code but is not transmitted —
    the agent's system prompt is fixed server-side.
    """
    title = f"Arbiter {team} — {persona_id}"
    if team == "red":
        env_prefix = ("RED_TEAM_AGENT_ID", "RED_TEAM_ENVIRONMENT_ID", "RED_TEAM_VAULT_IDS")
    else:
        env_prefix = ("BLUE_TEAM_AGENT_ID", "BLUE_TEAM_ENVIRONMENT_ID", "BLUE_TEAM_VAULT_IDS")
    tool_input = await run_one_shot_with_custom_tool(
        title=title,
        user_message=user_message,
        tool_name="submit_argument",
        agent_env_name=env_prefix[0],
        environment_env_name=env_prefix[1],
        vault_env_name=env_prefix[2],
    )
    # Managed agents don't always include persona_id / deal_name in the
    # submit_argument output; inject them so validation succeeds.
    tool_input.setdefault("persona_id", persona_id)
    raw = AgentArgument.model_validate(tool_input)
    return TeamArgument.from_agent_argument(raw, team)
