"""
Orchestrator for the Arbiter Moderator session.

Given a ChatRequest (verdict + intel pack + prior turns + rep's new message),
this builds the moderator's user message, runs the multi-hop tool loop against
the moderator managed agent, and returns the ChatResponse.

Key contracts:
  • The moderator agent has four tools registered server-side (summon_red_team,
    summon_blue_team, recompute_probability, lookup_prior_deal). Its system
    prompt forbids first-person opinion — it routes the rep's question to one
    of those tools and presents the result verbatim.
  • `prior_turns` includes the original verdict (as a 'system' framing line),
    any earlier rep questions, prior moderator replies, and verbatim Red/Blue
    responses from earlier hops. We surface the recent ones in the user
    message so the moderator has linear context.
  • Tool handlers return verbatim Red/Blue text as `appendedTurns` so Merlin
    can write them to verdict_conversation_turns alongside the moderator's
    final reply.
"""
from __future__ import annotations

import os
from typing import Any, List

from ..context import pack_to_context
from ..agent_client import run_tool_loop, ManagedAgentError
from ..schemas import (
    ArbiterChatRole,
    ChatConversationTurn,
    ChatRequest,
    ChatResponse,
    ChatToolCallTrace,
    IntelPackRequest,
)
from .tools import TOOL_HANDLERS, ToolCtx


def _moderator_env_triplet() -> tuple[str, str, str]:
    return (
        "ARBITER_MODERATOR_AGENT_ID",
        "ARBITER_MODERATOR_ENVIRONMENT_ID",
        "ARBITER_MODERATOR_VAULT_IDS",
    )


def _max_hops() -> int:
    try:
        return int(os.environ.get("ARBITER_CHAT_MAX_HOPS", "4"))
    except (ValueError, TypeError):
        return 4


def _format_prior_turns(turns: List[ChatConversationTurn], n: int = 12) -> str:
    """
    Render the last N turns oldest→newest for the moderator's user message.
    Skip the very last turn if it's the same as the rep's current message
    (sometimes appended by the caller before sending).
    """
    if not turns:
        return "(no prior turns)"
    tail = turns[-n:]
    lines: list[str] = []
    for t in tail:
        role = t.role
        # Indent multi-line content for readability
        body = (t.content or "").strip()
        if not body:
            continue
        lines.append(f"[{role}] {body}")
    return "\n\n".join(lines) if lines else "(no prior turns)"


def _build_moderator_user_message(req: ChatRequest) -> str:
    v = req.verdict
    opp_id = v.opportunityId
    prob = v.probability
    conf = v.confidence
    base = v.baseRate
    red_head = v.redArgument.headline if v.redArgument else "(none)"
    blue_head = v.blueArgument.headline if v.blueArgument else "(none)"

    sections: list[str] = []
    sections.append(f"# Verdict snapshot (opp {opp_id})")
    sections.append(
        f"- Probability: {prob}% (confidence {conf}, base rate {round(base * 100)}%)\n"
        f"- Red Team headline: {red_head}\n"
        f"- Blue Team headline: {blue_head}\n"
        f"- Disagreement: {v.disagreement}\n"
        f"- Rounds completed: {v.roundsCompleted}"
    )
    if v.synthesis and v.synthesis.narrative:
        sections.append(f"## Arbiter narrative\n{v.synthesis.narrative[:1200]}")
    sections.append("## Conversation so far")
    sections.append(_format_prior_turns(req.priorTurns))
    sections.append("## Rep's new message")
    sections.append(req.userMessage.strip() or "(empty message)")
    sections.append(
        "## Your job\n"
        "Route the rep's message to exactly one of your four tools "
        "(summon_red_team / summon_blue_team / recompute_probability / lookup_prior_deal). "
        "If the question is genuinely ambiguous you MAY ask one short clarifying "
        "question instead. After receiving the tool result(s), reply with minimal framing — "
        "present the team/system response verbatim with attribution. Do NOT add "
        "your own opinion or analysis."
    )
    return "\n\n".join(sections)


async def run_arbiter_chat(req: ChatRequest) -> ChatResponse:
    """
    Drive one Moderator turn: build user message → run tool loop → collect
    appended turns → return ChatResponse.

    Raises ManagedAgentError if the managed-agent call fails outright.
    """
    # Build a DealContext so the tool handlers can reuse the same context the
    # arbiter built at debate time. pack_to_context expects an IntelPackRequest.
    pack = IntelPackRequest.model_validate(req.intelPack)
    deal_context = pack_to_context(pack)

    ctx = ToolCtx(verdict=req.verdict, intel_pack=req.intelPack, deal_context=deal_context)

    # Wrap each handler so we can capture its appended turn cleanly.
    appended_turns: list[ChatConversationTurn] = []

    def make_handler(name: str):
        async def _wrapped(tool_input: dict):
            payload, summary, appended = await TOOL_HANDLERS[name](tool_input, ctx)
            if appended is not None:
                appended_turns.append(appended)
            return payload, summary

        return _wrapped

    handlers = {name: make_handler(name) for name in TOOL_HANDLERS.keys()}

    agent_env, env_env, vault_env = _moderator_env_triplet()
    title = f"Arbiter Moderator — opp {req.verdict.opportunityId}"

    user_message = _build_moderator_user_message(req)

    try:
        loop = await run_tool_loop(
            title=title,
            user_message=user_message,
            tool_handlers=handlers,
            agent_env_name=agent_env,
            environment_env_name=env_env,
            vault_env_name=vault_env,
            max_hops=_max_hops(),
        )
    except ManagedAgentError as exc:
        # Surface as a graceful fallback so Merlin can DM something useful.
        return ChatResponse(
            reply=(
                "I couldn't reach the moderator agent for that follow-up "
                f"({str(exc)[:160]}). Try again in a moment, or run `arbiter "
                f"{req.verdict.opportunityId}` to re-evaluate the deal."
            ),
            toolCalls=[],
            hopsUsed=0,
            appendedTurns=[],
        )

    final_text = (loop["text"] or "").strip()
    if not final_text:
        # The moderator finished without text — fall back to the last
        # appended-turn content so the rep sees *something* useful.
        if appended_turns:
            final_text = appended_turns[-1].content
        else:
            final_text = "I didn't have anything new to add. Try rephrasing the question."

    # If recompute_probability fired, pull the structured outputs onto the
    # top-level fields so Merlin's Slack card can render the probability
    # badge inline instead of digging through tool_calls.
    recomputed_prob = None
    recomputed_lean = None
    scenario_rationale = None
    for call in loop["tool_calls"]:
        if call["tool"] == "recompute_probability":
            # The summary embeds the new pct; the appended turn has the rationale.
            # Find the matching appended turn by metadata.
            for t in appended_turns:
                meta = (t.metadata or {})
                if meta.get("tool") == "recompute_probability":
                    recomputed_prob = meta.get("new_probability")
                    recomputed_lean = meta.get("new_lean")
                    scenario_rationale = t.content
                    break
            break

    tool_call_traces = [
        ChatToolCallTrace(
            tool=c["tool"],
            input=c["input"],
            resultSummary=c["result_summary"],
        )
        for c in loop["tool_calls"]
        # only include known tools; unknown ones are still useful for audit
        # but the wire schema constrains tool name to the four-tool literal.
        if c["tool"] in TOOL_HANDLERS
    ]

    return ChatResponse(
        reply=final_text,
        toolCalls=tool_call_traces,
        recomputedProbability=recomputed_prob,
        recomputedLean=recomputed_lean,
        scenarioRationale=scenario_rationale,
        hopsUsed=loop["hops_used"],
        appendedTurns=appended_turns,
    )
