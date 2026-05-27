"""
Build the user message that gets sent to the Red Team Claude conversation.
Composed from: deal context + retrieved prior LOST deals + competitor quotes.
"""
from __future__ import annotations
from typing import List
from ..schemas import DealContext
from ..intel import retrieval


def build_red_user_message(ctx: DealContext, persona_id: str, fired_triggers: List[dict]) -> str:
    competitors = retrieval.detect_competitors(ctx)
    similar = retrieval.find_similar_lost_deals(ctx, competitors, n=5)
    quotes = retrieval.find_competitor_quotes(competitors, n_per=4)
    cohort = retrieval.get_cohort_stats()

    parts = []
    parts.append("# DEAL UNDER EVALUATION\n")
    parts.append(_render_sf_state(ctx))
    parts.append(_render_meddpicc(ctx, cohort))
    parts.append(_render_triggers(fired_triggers))
    parts.append(_render_gong_signals(ctx))
    parts.append(_render_meddpicc_evidence(ctx))
    parts.append(_render_similar_dead_deals(similar))
    parts.append(_render_competitor_quotes(quotes))
    parts.append(_render_task(persona_id, team="red"))
    return "\n".join(parts)


def _render_sf_state(ctx: DealContext) -> str:
    lines = ["## Salesforce State"]
    lines.append(f"- Opportunity: {ctx.opportunity_name}")
    lines.append(f"- Account: {ctx.account_name}")
    lines.append(f"- Amount: ${ctx.amount:,.0f}")
    lines.append(f"- Stage: {ctx.stage_name}")
    lines.append(f"- Segment: {ctx.segment} | Business Type: {ctx.business_type}")
    lines.append(f"- Age: {ctx.age_in_days} days")
    lines.append(f"- Days since decision-maker touch: {ctx.days_since_decision_maker_touch or 'unknown'}")
    lines.append(f"- Forecast Category: {ctx.forecast_category}")
    lines.append(f"- Close Date: {ctx.close_date}")
    lines.append(f"- Assigned AE: {ctx.assigned_ae}")
    return "\n".join(lines)


def _render_meddpicc(ctx: DealContext, cohort: dict) -> str:
    avgs = cohort.get("meddpicc_lost_vs_won_avg", {})
    def fmt(label, key):
        a = avgs.get(key, {})
        cur = getattr(ctx.meddpicc, key) if hasattr(ctx.meddpicc, key) else None
        return f"- {label}: {cur} (lost-avg {a.get('lost')} / won-avg {a.get('won')})"
    lines = ["\n## MEDDPICC Scores"]
    lines.append(fmt("Overall", "overall"))
    lines.append(fmt("Champion", "champion"))
    lines.append(fmt("Competition", "competition"))
    lines.append(fmt("Decision Process", "decision_process"))
    lines.append(fmt("Decision Criteria", "decision_criteria"))
    lines.append(fmt("Economic Buyer", "economic_buyer"))
    lines.append(fmt("Paper Process", "paper_process"))
    lines.append(fmt("Pain", "pain"))
    lines.append(fmt("Metrics", "metrics"))
    return "\n".join(lines)


def _render_triggers(triggers: List[dict]) -> str:
    if not triggers:
        return ""
    lines = [f"\n## TRIGGERS THAT FIRED ({len(triggers)})"]
    for t in triggers:
        lines.append(f"- [{t.get('trigger_id')}] weight={t.get('weight')} → {t.get('evidence')}")
    return "\n".join(lines)


def _render_gong_signals(ctx: DealContext) -> str:
    lines = ["\n## RECENT GONG SIGNALS"]
    lines.append(f"- {ctx.recent_gong_calls} calls in last 30 days")
    lines.append(f"- {len(ctx.gong_competitor_mentions)} competitor mentions, {len(ctx.gong_objection_mentions)} objection mentions")

    if ctx.gong_competitor_mentions:
        lines.append("\n### Competitor mentions (verbatim from prospect)")
        for m in ctx.gong_competitor_mentions[:8]:
            ts = m.timestamp_seconds or 0
            lines.append(f'- {m.call_date.date()} @ {ts}s [{m.matched_pattern}]: "{m.excerpt[:300]}"')

    if ctx.gong_objection_mentions:
        lines.append("\n### Objection mentions (verbatim from prospect)")
        for m in ctx.gong_objection_mentions[:8]:
            ts = m.timestamp_seconds or 0
            lines.append(f'- {m.call_date.date()} @ {ts}s [{m.matched_pattern}]: "{m.excerpt[:300]}"')
    return "\n".join(lines)


def _render_meddpicc_evidence(ctx: DealContext) -> str:
    if not ctx.meddpicc_evidence:
        return ""
    lines = ["\n## MEDDPICC EVIDENCE FIELDS"]
    for dim, text in ctx.meddpicc_evidence.items():
        if text:
            lines.append(f"\n**{dim.upper()}**")
            lines.append(text[:500])
    return "\n".join(lines)


def _render_similar_dead_deals(deals: list) -> str:
    if not deals:
        return ""
    lines = [f"\n## SIMILAR PRIOR LOST DEALS ({len(deals)} closest matches — cite these by name)"]
    for d in deals:
        lines.append(f"\n### {d.get('name')} (${d.get('amount') or 0:,.0f} | {d.get('segment')} | {d.get('business_type')})")
        lines.append(f"- Primary loss reason: {d.get('primary_reason')}")
        lines.append(f"- Secondary: {d.get('secondary_reason')}")
        lines.append(f"- Final competitor: {d.get('final_competitor')}")
        if d.get('overall_summary'):
            lines.append(f"- Summary excerpt: {d['overall_summary'][:400]}")
        if d.get('cl_notes'):
            lines.append(f"- CL Notes: {d['cl_notes']}")
    return "\n".join(lines)


def _render_competitor_quotes(quotes: list) -> str:
    if not quotes:
        return ""
    lines = ["\n## VERBATIM COMPETITOR QUOTES (from prior lost deals)"]
    for q in quotes:
        lines.append(f'- [{q.get("competitor")}] {q.get("deal_name")} (${q.get("amount") or 0:,.0f}): "{q.get("quote", "")[:300]}"')
    return "\n".join(lines)


def _render_task(persona_id: str, team: str) -> str:
    return f"""\n---\n
# YOUR TASK

You are firing as the **{persona_id}** persona for the **{team.upper()} TEAM**.

Produce a structured argument using the `submit_argument` tool. Every claim must cite at least one of:
- A Gong moment listed above
- A Salesforce field referenced above
- A specific prior dead deal named above
- A specific intel pack pattern

Do NOT fabricate evidence. If you cannot cite a claim, drop it.
"""
