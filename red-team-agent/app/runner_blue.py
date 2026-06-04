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
from .prompt_assembly.next_moves_prompt import build_next_moves_user_message
from .schemas import (
    AgentArgument,
    DealContext,
    FiredTrigger,
    NextMovesAction,
    NextMovesRequest,
    NextMovesResponse,
    TeamArgument,
)


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
    # BlueHat Merlin's submit_argument schema doesn't always include
    # persona_id / deal_name; inject them from call context so validation
    # succeeds. We already know which persona we asked for and which
    # account/opp the eval is on.
    tool_input.setdefault("persona_id", persona_id)
    tool_input.setdefault("deal_name", context.account_name)
    try:
        raw = AgentArgument.model_validate(tool_input)
    except Exception as exc:
        raise ManagedAgentError(
            f"BlueHat submit_argument payload failed schema for persona "
            f"{persona_id}: {exc}; raw input keys={list(tool_input.keys())}"
        )
    return TeamArgument.from_agent_argument(raw, "blue")


async def run_next_moves(req: NextMovesRequest) -> NextMovesResponse:
    """
    Lightweight post-call call into BlueHat Merlin for forward-looking actions.

    Same managed agent, same submit_argument tool — but the user message asks
    for 2-4 concrete next moves grounded in the call insight, not a full
    debate-shaped argument. We project the agent's structured output down to
    `recommendedActions` for Merlin to render as a card.
    """
    from datetime import datetime, timezone

    evaluated_at = datetime.now(timezone.utc).isoformat()

    title = f"BlueHat Merlin — next moves on {req.opportunity.name}"
    user_message = build_next_moves_user_message(
        opp=req.opportunity,
        insight=req.callInsight,
        metadata=req.callMetadata,
        matched=req.matchedContacts,
        unmatched=req.unmatchedAttendees,
        activities=req.recentActivities,
    )

    try:
        tool_input = await run_one_shot_with_custom_tool(
            title=title,
            user_message=user_message,
            tool_name="submit_argument",
            agent_env_name="BLUE_TEAM_AGENT_ID",
            environment_env_name="BLUE_TEAM_ENVIRONMENT_ID",
            vault_env_name="BLUE_TEAM_VAULT_IDS",
        )
    except ManagedAgentError as exc:
        return NextMovesResponse(
            evaluatedAt=evaluated_at,
            shadowMode=req.shadowMode,
            dropReason=f"agent_failed: {str(exc)[:240]}",
        )

    # BlueHat's submit_argument schema requires persona_id + deal_name;
    # backfill them so validation succeeds even though we don't render them.
    tool_input.setdefault("persona_id", "next_moves")
    tool_input.setdefault("deal_name", req.opportunity.name)

    headline = (tool_input.get("headline") or "").strip()
    claims = tool_input.get("claims") or []
    # The agent puts its reasoning in claims[0] when prompted for next-moves
    # mode; surface it as a single rationale paragraph for the card.
    rationale = ""
    if claims and isinstance(claims, list) and isinstance(claims[0], dict):
        rationale = (claims[0].get("statement") or "").strip()

    raw_actions = tool_input.get("recommended_actions") or []
    actions: List[NextMovesAction] = []
    for ra in raw_actions:
        if not isinstance(ra, dict):
            continue
        actions.append(
            NextMovesAction(
                action=str(ra.get("action") or "").strip(),
                ownerRole=str(ra.get("owner_role") or "").strip(),
                byDate=str(ra.get("by_date") or "").strip(),
                expectedSignal=str(ra.get("expected_signal") or "").strip(),
            )
        )
    actions = [a for a in actions if a.action]

    if not actions:
        return NextMovesResponse(
            evaluatedAt=evaluated_at,
            shadowMode=req.shadowMode,
            headline=headline,
            rationale=rationale,
            recommendedActions=[],
            dropReason="no_actions",
        )

    return NextMovesResponse(
        evaluatedAt=evaluated_at,
        shadowMode=req.shadowMode,
        headline=headline,
        rationale=rationale,
        recommendedActions=actions,
    )
