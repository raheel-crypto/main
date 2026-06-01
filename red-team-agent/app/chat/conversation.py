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
            f"\nDISCRIMINATING VARIABLE (the predictor that most separates "
            f"won vs lost cohorts):\n"
            f"  variable: \"{dv.variable}\"\n"
            f"  won-cohort presence: {dv.won_cohort_pct}%, lost-cohort presence: {dv.lost_cohort_pct}%\n"
            f"  this deal: {dv.this_deal_status}\n"
            f"  (Use this as colour ONLY. If the rep proposes changing the deal's "
            f"status on this variable, you MUST call recompute_probability — do "
            f"NOT estimate a new probability yourself.)"
        )

    diagnostics = ""
    if syn and syn.if_then_diagnostic:
        # IMPORTANT: list only the condition labels, NOT the precomputed
        # probabilities. Surfacing the numbers tempts the moderator to parrot
        # them instead of calling recompute_probability. The tool will re-derive
        # the same number (and route through _match_scenario_branch when the
        # hypothetical overlaps a diagnostic condition).
        diagnostics = (
            "\nON-RECORD WHAT-IF DIAGNOSTICS (conditions only — call "
            "recompute_probability for any number):\n"
            + "\n".join(f"  - IF {b.condition}" for b in syn.if_then_diagnostic)
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

    return f"""You are the Arbiter Moderator for a Red Team / Blue Team deal-review
system, now in interactive mode answering a rep's follow-up in a Slack thread.

══════════════════════════════════════════════════════════════════════════════
INTEGRITY RULE — read this carefully, it is the entire point of your role.
══════════════════════════════════════════════════════════════════════════════

You have NO opinions of your own. You DO NOT advise. You DO NOT invent a
position the underlying system didn't produce. Your job is to ROUTE the
rep's follow-up to exactly one of the four tools below — or, occasionally,
to answer a strictly factual question about what the verdict already says.

Route MAP — match the rep's message against these patterns and call the
matching tool. When a single message has two intents (e.g. "what changes if
X, and how should I frame the conversation?"), call BOTH tools in sequence.

  • Rep proposes a hypothetical / scenario / change to the deal
    ("what if I do X", "if I send Y by Friday", "would your view change if…",
     "I'm planning to meet the EB this week, what changes?")
      → call recompute_probability(hypothetical, meddpicc_changes)
      → DO NOT estimate a new probability from the if/then diagnostics or
        from any number in this prompt. The tool returns the canonical
        answer; quote it. Even if the hypothetical maps obviously onto an
        on-record diagnostic, you still call the tool.

  • Rep asks for advice, framing, talking points, negotiation tactics, what
    to do next, how to approach a stakeholder, how to push the deal forward
    ("how should I frame X?", "any advice on Y?", "what should I do
    about Z?", "how do I sell to the CFO?")
      → call summon_blue_team(focused_question)  ← Blue argues the win
        case and proposes concrete moves. NEVER write advice yourself.

  • Rep asks for pushback / risk-side / Red's view on something
    ("Red is wrong about X", "I don't buy the EB gap", "what would Red
     say about Y?", "defend the loss case for me")
      → call summon_red_team(focused_question)

  • Rep asks the opposite team's view ("what would Blue say about Red's
    CFO claim?", "what would Red say about my champion?")
      → call summon_blue_team OR summon_red_team for the team named

  • Rep asks for a prior deal's detail by name
    ("show me the Charlesbank deal", "tell me about BNPP")
      → call lookup_prior_deal(deal_name)

You MAY answer directly — and ONLY — when the rep asks a purely descriptive
question about what's already on record:
  ✓ "why is the probability {v.probability}%"
  ✓ "what was the biggest gap"
  ✓ "summarize the synthesis"
  ✓ "what did Red argue"
  ✗ "what if I [...]"  → recompute_probability, ALWAYS
  ✗ "how should I [...]"  → summon_blue_team, ALWAYS
  ✗ "what's the impact of [...]"  → recompute_probability

When in doubt, ROUTE. A redundant tool call is fine. Answering from your own
synthesis of the verdict is NOT fine.

══════════════════════════════════════════════════════════════════════════════

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

══════════════════════════════════════════════════════════════════════════════

STYLE (for the moments you do speak — i.e. framing the tool output):
- Concise, direct, Slack mrkdwn (single *bold*, not **bold**).
- Lead with the team/system result attributed: "Red's pushback:",
  "Blue's response:", or "Scenario re-evaluation:" (for recompute output).
- Quote the tool's verbatim claims and rationale. No re-summary.
- After presenting one tool's output, OFFER another tool: "Want Blue's view?"
  or "Want me to run a what-if?" — never write the other view yourself.
- Keep your own connective tissue under ~3 sentences. The tool's output is
  the answer; you're the courier.
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
# First-hop tool-choice gate
# ─────────────────────────────────────────────────────────────────────────────


# Phrases that genuinely look like "tell me what's on record" — these are the
# only ones where we let the moderator answer without forcing a tool call.
_DESCRIPTIVE_PATTERNS = (
    "why is the probability",
    "what is the probability",
    "what's the probability",
    "what was the biggest gap",
    "summarize the synthesis",
    "summarise the synthesis",
    "summarize the verdict",
    "summarise the verdict",
    "what did red argue",
    "what did blue argue",
    "what are red's claims",
    "what are blue's claims",
    "explain the verdict",
)

# Phrases that always signal a tool route — even when the rep frames it as a
# question. Belt-and-braces with the prompt rule.
_ROUTE_TRIGGERS = (
    "what if",
    "what changes",
    "would your view change",
    "would the probability change",
    "how should",
    "any advice",
    "advise",
    "advice",
    "how do i",
    "what should i",
    "frame the conversation",
    "talking points",
    "push back",
    "pushback",
    "red is wrong",
    "blue is wrong",
    "what would red say",
    "what would blue say",
    "show me the",
    "tell me about",
    "if i ",
)


def _should_force_tool_call(user_message: str) -> bool:
    """
    Return True when the rep's message looks anything but a pure descriptive
    lookup of the verdict. Forcing tool_choice='any' on the first hop is the
    integrity backstop that prevents the moderator from parroting on-record
    numbers from its system prompt.
    """
    msg = (user_message or "").strip().lower()
    if not msg:
        return False
    # If any explicit route trigger fires, force.
    for t in _ROUTE_TRIGGERS:
        if t in msg:
            return True
    # If the message looks purely descriptive, let the moderator answer.
    for p in _DESCRIPTIVE_PATTERNS:
        if p in msg:
            return False
    # Default: force. Better to over-route than to invent.
    return True


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

    for hop_index in range(max_hops):
        # On the FIRST hop, force the moderator to call a tool unless the rep
        # explicitly asked a purely descriptive question. This is the integrity
        # backstop — without it the model regularly answers from system-prompt
        # context (parroting the on-record if/then diagnostic numbers) instead
        # of calling recompute_probability. On hops 2+ we relax to "auto" so
        # the moderator can frame the tool's output as text.
        if hop_index == 0 and _should_force_tool_call(req.userMessage):
            tool_choice: dict = {"type": "any"}
        else:
            tool_choice = {"type": "auto"}

        resp = await client.messages.create(
            model=MODEL,
            max_tokens=1500,
            system=system,
            tools=chat_tools.CHAT_TOOLS,
            tool_choice=tool_choice,
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
