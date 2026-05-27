"""
Blue Team runner — mirror of `app/runner.py` but targets the BlueHat Merlin
managed agent. Same one-shot-per-persona shape; user message is built via
the user-authored `prompt_assembly.blue_prompt.build_blue_user_message`.

Like Red, this stays sequential per-persona inside a single /blue/evaluate
call. For /arbiter we only ever fire one Blue persona (paired with one
Red), so concurrency lives at the /arbiter level (asyncio.gather of red +
blue), not here.
"""
from __future__ import annotations

from typing import List, Optional

from .agent_client import ManagedAgentError, run_one_shot_with_custom_tool
from .prompt_assembly.blue_prompt import build_blue_user_message
from .schemas import AgentArgument, DealContext, FiredTrigger, TeamArgument


async def run_blue_team(
    context: DealContext,
    persona_id: str,
    supporting_triggers: List[FiredTrigger],
) -> Optional[TeamArgument]:
    """
    Invoke BlueHat Merlin for one persona. Returns None if the agent didn't
    produce a valid submit_argument payload; transport errors propagate so
    main.py can audit them.
    """
    title = f"BlueHat Merlin — {context.account_name} ({persona_id})"
    fired_triggers_serializable = [
        {
            "trigger_id": t.trigger_id,
            "weight": t.weight,
            "evidence": t.evidence,
            "target_persona": t.target_persona,
        }
        for t in supporting_triggers
    ]
    user_message = build_blue_user_message(
        context, persona_id, fired_triggers_serializable
    )
    tool_input = await run_one_shot_with_custom_tool(
        title=title,
        user_message=user_message,
        tool_name="submit_argument",
        agent_env_name="BLUE_TEAM_AGENT_ID",
        environment_env_name="BLUE_TEAM_ENVIRONMENT_ID",
        vault_env_name="BLUE_TEAM_VAULT_IDS",
    )
    try:
        raw = AgentArgument.model_validate(tool_input)
    except Exception as exc:
        raise ManagedAgentError(
            f"BlueHat submit_argument payload failed schema for persona "
            f"{persona_id}: {exc}; raw input keys={list(tool_input.keys())}"
        )
    return TeamArgument.from_agent_argument(raw, "blue")
