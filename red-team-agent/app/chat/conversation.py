"""
The conversational Arbiter — answers follow-up questions in-thread.

Uses the Anthropic SDK directly (not a managed agent) so we can assemble the
moderator's system prompt per-turn with the full verdict baked in. The
moderator decides:
  • Answer directly from the verdict / synthesis on record, OR
  • Call one of the four tools (summon_red/blue, recompute_probability,
    lookup_prior_deal).

When it calls a tool we dispatch:
  • summon_* re-invoke the existing Red/Blue managed agents.
  • recompute/lookup run deterministically in-process.

Result is a `ChatResponse` with the moderator's final reply plus structured
`appendedTurns` (verbatim Red/Blue or system rows) that Merlin persists to
`verdict_conversation_turns` alongside the moderator's reply.
"""
from __future__ import annotations

import json
import os
from typing import List, Optional

from anthropic import AsyncAnthropic

from ..context import pack_to_context
from ..schemas import (
    ChatConversationTurn,
    ChatRequest,
    ChatResponse,
    ChatToolCallTrace,
    IntelPackRequest,
)
from . import tools as chat_tools

# Bumped together with `slack-bot/src/constants.ts:MODEL` and the other
# arbiter-side model ids.
MODEL = os.environ.get("ARBITER_CHAT_MODEL", "claude-sonnet-4-5-20250929")


def _max_hops() -> int:
    try:
        return int(os.environ.get("ARBITER_CHAT_MAX_HOPS", "4"))
    except (ValueError, TypeError):
        return 4


# ─────────────────────────────────────────────────────────────────────────────
# System prompt — assembled fresh each turn with the verdict on record
# ─────────────────────────────────────────────────────────────────────────────


def _build_system_prompt(req: ChatRequest) -> str:
    v = req.verdict
    syn = v.synthesis

    red_claims = "\n".join(
        f"  - {c.statement}" for c in (v.redArgument.claims if v.redArgument else [])
    ) or "  (none)"
    blue_claims = "\n".join(
        f"  - {c.statement}" for c in (v.blueArgument.claims if v.blueArgument else [])
    ) or "  (none)"

    disc = ""
    if syn and syn.discriminating_variable:
        dv = syn.discriminating_variable
        disc = (
            f"\nDISCRIMINATING VARIABLE: \"{dv.variable}\" — "
            f"won cohort {dv.won_cohort_pct}%, lost cohort {dv.lost_cohort_pct}%, "
            f"this deal: {dv.this_deal_status}."
        )

    diagnostics = ""
    if syn and syn.if_then_diagnostic:
        diagnostics = "\nIF/THEN DIAGNOSTICS ALREADY ON RECORD:\n" + "\n".join(
            f"  - IF {b.condition} -> ~{b.new_probability}% ({b.new_lean})"
            for b in syn.if_then_diagnostic
        )

    concessions = ""
    if syn and syn.resolved_contradictions:
        concessions = "\nCONCESSIONS FROM THE DEBATE:\n" + "\n".join(
            f"  - {c.conceding_team.upper()} conceded on {c.on_topic}: {c.summary}"
            for c in syn.resolved_contradictions
        )

    # Surface basic deal context from the intel pack so the moderator can ground
    # references without needing a tool call. Defensive: the intel_pack dict
    # carries the same shape as IntelPackRequest, just JSON-stringified.
    pack = req.intelPack or {}
    opp = pack.get("opportunity") or {}
    account = pack.get("account") or {}
    opp_name = opp.get("name") or "(unknown)"
    acct_name = account.get("name") or "(unknown)"
    amount = opp.get("amount")
    amount_str = f"${amount:,.0f}" if isinstance(amount, (int, float)) else "(amount unknown)"
    stage = opp.get("stageName") or "(unknown stage)"

    lean = "WIN" if v.probability >= 50 else "LOSS" if v.probability < 30 else "UNCERTAIN"

    return f"""You are the Arbiter for a Red Team / Blue Team deal-review system, now in
interactive mode answering a rep's follow-up in a Slack thread.

CRITICAL ROLE BOUNDARY — you do NOT invent opinions:
- You explain the verdict and the evidence already on record.
- When the rep asks you to push back AS a team, or "what would Blue/Red say",
  you MUST call summon_blue_team / summon_red_team. Do not impersonate a team
  from memory.
- When the rep asks a what-if ("would your view change if..."), you MUST call
  recompute_probability. Do not guess a new number.
- When the rep asks about a prior deal by name, call lookup_prior_deal.
- You MAY answer directly ONLY for questions about what the verdict already
  says (e.g. "why is the probability {v.probability}%", "what was the biggest
  gap", "summarize the synthesis").
- Ground every claim in the stored evidence or a tool result. Never fabricate
  a citation.

THE DEAL: {opp_name} — {acct_name}, {amount_str}, stage {stage}.

THE VERDICT ON RECORD:
- Win probability: {v.probability}% ({v.confidence} confidence)
- Red Team total score: {v.redScoring.total_score if v.redScoring else 0:.0f}
- Blue Team total score: {v.blueScoring.total_score if v.blueScoring else 0:.0f}
- Lean: {lean}
- Rounds completed: {v.roundsCompleted}
- Disagreement: {v.disagreement:.2f}

RED TEAM'S CLAIMS (loss case):
{red_claims}

BLUE TEAM'S CLAIMS (win case):
{blue_claims}
{concessions}{disc}{diagnostics}

STYLE: concise, direct, Slack-ready (mrkdwn — *bold* not **bold**). Lead with
the answer. Cite specific scores, deal names, and evidence. No preamble. When
you summoned a team, attribute it ("Red's pushback:" / "Blue's response:").
When recompute_probability returns, lead with the new % and lean, then the
rationale. Keep replies under ~250 words unless the rep explicitly asks for
more.
"""


# ─────────────────────────────────────────────────────────────────────────────
# Prior-turn history → Anthropic SDK messages
# ─────────────────────────────────────────────────────────────────────────────


def _history_to_messages(
    prior_turns: List[ChatConversationTurn],
    new_user_message: str,
) -> list[dict]:
    """
    Render the prior turns as alternating user/assistant messages. Tool roles
    (red/blue/system) collapse into the assistant turn that surfaced them so
    the SDK doesn't choke on an unknown role; the moderator's prompt already
    instructs it to attribute team responses.
    """
    msgs: list[dict] = []
    pending_assistant: list[str] = []
    for t in prior_turns:
        role = t.role
        body = (t.content or "").strip()
        if not body:
            continue
        if role == "user":
            if pending_assistant:
                msgs.append({"role": "assistant", "content": "\n\n".join(pending_assistant)})
                pending_assistant = []
            msgs.append({"role": "user", "content": body})
        elif role == "moderator":
            pending_assistant.append(body)
        elif role in ("red", "blue", "system"):
            # Surface verbatim team / system responses inside the preceding
            # assistant turn so the moderator can quote them on follow-ups.
            tag = {"red": "Red Team", "blue": "Blue Team", "system": "System"}[role]
            pending_assistant.append(f"_{tag} response:_\n{body}")
    if pending_assistant:
        msgs.append({"role": "assistant", "content": "\n\n".join(pending_assistant)})
    msgs.append({"role": "user", "content": new_user_message.strip() or "(empty)"})
    return msgs


# ─────────────────────────────────────────────────────────────────────────────
# Tool dispatch
# ─────────────────────────────────────────────────────────────────────────────


async def _dispatch_tool(
    name: str,
    args: dict,
    *,
    req: ChatRequest,
    deal_context,
    appended_turns: list[ChatConversationTurn],
) -> tuple[dict, dict]:
    """Run one tool. Returns (result_for_model, side_effects_for_response)."""
    side: dict = {}

    if name == "summon_red_team":
        payload, appended = await chat_tools.summon_red_team(
            deal_context, req.verdict, args.get("focused_question") or ""
        )
    elif name == "summon_blue_team":
        payload, appended = await chat_tools.summon_blue_team(
            deal_context, req.verdict, args.get("focused_question") or ""
        )
    elif name == "recompute_probability":
        payload, appended = chat_tools.recompute_probability(
            deal_context,
            req.verdict,
            args.get("hypothetical") or "",
            args.get("meddpicc_changes") or {},
        )
        if payload.get("new_probability") is not None:
            side = {
                "recomputed_probability": payload["new_probability"],
                "recomputed_lean": payload.get("new_lean"),
                "scenario_rationale": payload.get("rationale"),
            }
    elif name == "lookup_prior_deal":
        payload, appended = chat_tools.lookup_prior_deal(args.get("deal_name") or "")
    else:
        payload = {"error": f"unknown tool {name}"}
        appended = None

    if appended is not None:
        appended_turns.append(appended)
    return payload, side


# ─────────────────────────────────────────────────────────────────────────────
# Public entry point
# ─────────────────────────────────────────────────────────────────────────────


async def run_arbiter_chat(req: ChatRequest) -> ChatResponse:
    """Drive one moderator turn end-to-end."""
    if "ANTHROPIC_API_KEY" not in os.environ:
        return ChatResponse(
            reply="Moderator isn't configured (ANTHROPIC_API_KEY missing).",
            toolCalls=[],
            hopsUsed=0,
            appendedTurns=[],
        )

    pack = IntelPackRequest.model_validate(req.intelPack)
    deal_context = pack_to_context(pack)

    client = AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    system = _build_system_prompt(req)
    messages = _history_to_messages(req.priorTurns, req.userMessage)

    tool_traces: list[ChatToolCallTrace] = []
    appended_turns: list[ChatConversationTurn] = []
    side_effects: dict = {}
    hops_used = 0
    max_hops = _max_hops()

    for _ in range(max_hops):
        resp = await client.messages.create(
            model=MODEL,
            max_tokens=1500,
            system=system,
            tools=chat_tools.CHAT_TOOLS,
            messages=messages,
        )

        if resp.stop_reason == "tool_use":
            messages.append({"role": "assistant", "content": resp.content})
            tool_results: list[dict] = []
            for block in resp.content:
                if getattr(block, "type", None) != "tool_use":
                    continue
                hops_used += 1
                result, side = await _dispatch_tool(
                    block.name,
                    block.input,
                    req=req,
                    deal_context=deal_context,
                    appended_turns=appended_turns,
                )
                side_effects.update(side)
                tool_traces.append(
                    ChatToolCallTrace(
                        tool=block.name,
                        input=block.input or {},
                        resultSummary=_summarize_tool_result(block.name, result),
                    )
                )
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": json.dumps(result, default=str),
                    }
                )
            messages.append({"role": "user", "content": tool_results})
            continue

        reply = "".join(
            getattr(b, "text", "") for b in resp.content if getattr(b, "type", None) == "text"
        ).strip()
        return ChatResponse(
            reply=reply or "(no reply)",
            toolCalls=tool_traces,
            recomputedProbability=side_effects.get("recomputed_probability"),
            recomputedLean=side_effects.get("recomputed_lean"),
            scenarioRationale=side_effects.get("scenario_rationale"),
            hopsUsed=hops_used,
            appendedTurns=appended_turns,
        )

    # Hop budget exhausted — best-effort fallback
    fallback = (
        "I gathered the inputs but need you to narrow the question — try "
        "asking about one team or one what-if at a time."
    )
    return ChatResponse(
        reply=fallback,
        toolCalls=tool_traces,
        recomputedProbability=side_effects.get("recomputed_probability"),
        recomputedLean=side_effects.get("recomputed_lean"),
        scenarioRationale=side_effects.get("scenario_rationale"),
        hopsUsed=hops_used,
        appendedTurns=appended_turns,
    )


def _summarize_tool_result(name: str, result: dict) -> str:
    if name in ("summon_red_team", "summon_blue_team"):
        return f"{result.get('team', name)}: {(result.get('headline') or '')[:120]}"
    if name == "recompute_probability":
        base = result.get("baseline_probability")
        new = result.get("new_probability")
        lean = result.get("new_lean")
        return f"{base}% → {new}% ({lean})"
    if name == "lookup_prior_deal":
        if result.get("found"):
            return f"found: {result.get('name')}"
        return f"not_found: {(result.get('searched_for') or '')[:80]}"
    if "error" in result:
        return f"error: {str(result['error'])[:120]}"
    return ""
