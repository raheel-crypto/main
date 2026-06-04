"""
Build the user message for Blue's post-call "next moves" mode.

This is a deliberately lighter prompt than the debate version. We're not
asking Blue to argue a deal; we're asking it for 2-4 concrete next moves the
rep should take based on the call that just happened. No persona library
overhead, no won-deal precedent loading. Just: here's the call, here's the
deal, here are the people — what's the next move.

The managed agent still calls `submit_argument` (that's how Blue is wired
server-side), but we instruct it to put the actions in `recommended_actions[]`
and use the `headline` field as a one-line "why these actions." Claims get
collapsed to a single rationale claim. /blue/next-moves's response handler
extracts what it needs and drops the rest.
"""
from __future__ import annotations
from typing import List, Optional

from ..schemas import (
    NextMovesAttendee,
    NextMovesCallInsight,
    NextMovesCallMetadata,
    NextMovesContact,
    NextMovesActivity,
    NextMovesOpportunity,
)


def build_next_moves_user_message(
    opp: NextMovesOpportunity,
    insight: Optional[NextMovesCallInsight],
    metadata: Optional[NextMovesCallMetadata],
    matched: List[NextMovesContact],
    unmatched: List[NextMovesAttendee],
    activities: List[NextMovesActivity],
) -> str:
    parts: List[str] = []
    parts.append("# POST-CALL NEXT MOVES (BLUE TEAM)")
    parts.append(
        "A Gong call just wrapped on this deal. The rep needs 2-4 concrete "
        "forward-looking actions to take today / this week to advance the "
        "opportunity. You are the win-case advocate — propose moves that "
        "advance the deal, not just hygiene like 'update Salesforce.' "
        "Ground each action in something specific from the call, the deal "
        "state, or the people involved."
    )

    parts.append(_render_deal(opp))
    parts.append(_render_call(insight, metadata))
    parts.append(_render_people(matched, unmatched))
    parts.append(_render_recent(activities))
    parts.append(_render_task())

    return "\n\n".join(p for p in parts if p)


def _render_deal(opp: NextMovesOpportunity) -> str:
    lines = ["## Deal"]
    lines.append(f"- Opportunity: {opp.name}  (id {opp.id})")
    lines.append(f"- Account: {opp.accountName}")
    lines.append(f"- Stage: {opp.stageName}")
    if opp.type:
        lines.append(f"- Type: {opp.type}")
    if opp.amount is not None:
        lines.append(f"- Amount: ${opp.amount:,.0f}")
    if opp.closeDate:
        lines.append(f"- Close date: {opp.closeDate}")
    return "\n".join(lines)


def _render_call(
    insight: Optional[NextMovesCallInsight],
    metadata: Optional[NextMovesCallMetadata],
) -> str:
    if insight is None and metadata is None:
        return ""
    lines = ["## The call that just wrapped"]
    if metadata:
        if metadata.title:
            lines.append(f"- Title: {metadata.title}")
        if metadata.durationSec:
            lines.append(f"- Duration: ~{int(metadata.durationSec // 60)} min")
        if metadata.startedAt:
            lines.append(f"- Started: {metadata.startedAt}")
    if insight:
        if insight.summary:
            lines.append("")
            lines.append("### Summary")
            lines.append(insight.summary[:1500])
        if insight.positives:
            lines.append("")
            lines.append("### Positive signals from the call")
            for p in insight.positives[:8]:
                lines.append(f"- {p}")
        if insight.negatives:
            lines.append("")
            lines.append("### Concerns / friction from the call")
            for n in insight.negatives[:8]:
                lines.append(f"- {n}")
        if insight.nextSteps:
            lines.append("")
            lines.append("### Next steps the call participants discussed")
            for s in insight.nextSteps[:8]:
                lines.append(f"- {s}")
    return "\n".join(lines)


def _render_people(
    matched: List[NextMovesContact],
    unmatched: List[NextMovesAttendee],
) -> str:
    if not matched and not unmatched:
        return ""
    lines = ["## People"]
    if matched:
        lines.append("### Existing Salesforce contacts who joined")
        for c in matched[:10]:
            extras = ", ".join(x for x in (c.title, c.email) if x)
            lines.append(f"- {c.name or '(no name)'}{(' — ' + extras) if extras else ''}")
    if unmatched:
        lines.append("")
        lines.append(
            "### External attendees NOT YET in Salesforce "
            "(opportunity for 'add to SF' next move)"
        )
        for u in unmatched[:10]:
            lines.append(f"- {u.displayName or u.email}  <{u.email}>")
    return "\n".join(lines)


def _render_recent(activities: List[NextMovesActivity]) -> str:
    if not activities:
        return ""
    lines = ["## Recent SF activity on this opp (last 30d)"]
    for a in activities[:8]:
        when = a.activityDate or "(no date)"
        desc = (a.description or "")[:200]
        lines.append(f"- [{when}] {a.type}: {a.subject}{' — ' + desc if desc else ''}")
    return "\n".join(lines)


def _render_task() -> str:
    return """## Your task

Use `submit_argument` to return:

- `headline`: one sentence — "why these actions, in this order"
- `claims`: one claim summarizing the deal state + post-call signal that drives the actions
- `recommended_actions`: 2-4 concrete next moves, ordered by priority. Each action MUST include:
  - `action`: the specific move (e.g. "Draft email to CFO Sarah Chen with ROI summary and ask for 30 min next week", NOT "follow up with CFO")
  - `owner_role`: who does it ("AE", "CSM", "Manager", "Internal SE", etc.)
  - `by_date`: a calendar date or relative window ("by Friday", "before next call", "today")
  - `expected_signal`: what success looks like ("CFO confirms attendance", "MSA redlines back within 5 days")

Bias toward forward-looking moves that advance the deal:
- Drafts (emails, decks, ROI memos) the rep can send today
- Stakeholders to bring in (champion intros, internal escalation, technical SE)
- Meetings to book (working sessions, executive 1:1s)
- Specific Salesforce updates that unblock the funnel (NextStep, MEDDPICC fields, contacts)

AVOID:
- Generic "follow up" or "check in" — be specific about with whom and about what
- Vague "discovery" — name the topic
- Pure hygiene (e.g. "log the call notes") unless it's actually the most important next move
"""
