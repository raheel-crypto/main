"""
Build the user message for Blue Team. Same deal context as Red, but pulls WON
deal precedents and win-pattern quotes instead of lost-deal evidence.
"""
from __future__ import annotations
from typing import List
from ..schemas import DealContext
from ..intel import retrieval


def build_blue_user_message(ctx: DealContext, persona_id: str, fired_triggers: List[dict]) -> str:
    competitors = retrieval.detect_competitors(ctx)
    similar = retrieval.find_similar_won_deals(ctx, competitors, n=5)
    win_quotes = retrieval.find_win_pattern_quotes(
        ["champion_advocacy", "incumbent_pain", "quantified_pain", "buying_questions"], n_per=3
    )
    cohort = retrieval.get_cohort_stats()

    parts = []
    parts.append("# DEAL UNDER EVALUATION (BLUE TEAM)\n")
    parts.append(_render_sf_state(ctx))
    parts.append(_render_meddpicc(ctx, cohort))
    parts.append(_render_strengths(ctx))
    parts.append(_render_triggers(fired_triggers))
    parts.append(_render_gong_positives(ctx))
    parts.append(_render_meddpicc_evidence(ctx))
    parts.append(_render_similar_won_deals(similar))
    parts.append(_render_win_pattern_quotes(win_quotes))
    parts.append(_render_task(persona_id))
    return "\n".join(parts)


def _render_sf_state(ctx: DealContext) -> str:
    lines = ["## Salesforce State"]
    lines.append(f"- Opportunity: {ctx.opportunity_name}")
    lines.append(f"- Account: {ctx.account_name}")
    lines.append(f"- Amount: ${ctx.amount:,.0f}")
    lines.append(f"- Stage: {ctx.stage_name}")
    lines.append(f"- Segment: {ctx.segment} | Business Type: {ctx.business_type}")
    lines.append(f"- Forecast Category: {ctx.forecast_category}")
    return "\n".join(lines)


def _render_meddpicc(ctx: DealContext, cohort: dict) -> str:
    avgs = cohort.get("meddpicc_lost_vs_won_avg", {})
    def fmt(label, key):
        a = avgs.get(key, {})
        cur = getattr(ctx.meddpicc, key) if hasattr(ctx.meddpicc, key) else None
        return f"- {label}: {cur} (won-avg {a.get('won')})"
    lines = ["\n## MEDDPICC Scores (vs won-deal average — your benchmark)"]
    lines.append(fmt("Overall", "overall"))
    lines.append(fmt("Champion", "champion"))
    lines.append(fmt("Decision Process", "decision_process"))
    lines.append(fmt("Economic Buyer", "economic_buyer"))
    lines.append(fmt("Paper Process", "paper_process"))
    lines.append(fmt("Metrics", "metrics"))
    return "\n".join(lines)


def _render_strengths(ctx: DealContext) -> str:
    """Identify dimensions where this deal is strong."""
    strengths = []
    m = ctx.meddpicc
    if m.champion and m.champion >= 5:
        strengths.append(f"Champion score {m.champion} — at or above won-deal avg")
    if m.economic_buyer and m.economic_buyer >= 4:
        strengths.append(f"Economic Buyer score {m.economic_buyer} — engaged")
    if m.paper_process and m.paper_process >= 3:
        strengths.append(f"Paper Process score {m.paper_process} — process mapped")
    if m.decision_process and m.decision_process >= 4:
        strengths.append(f"Decision Process score {m.decision_process} — clear path")
    if not strengths:
        return "\n## NOTE: No MEDDPICC dimension is currently above won-deal average. Be honest about this in your argument."
    return "\n## STRENGTHS IDENTIFIED\n" + "\n".join(f"- {s}" for s in strengths)


def _render_triggers(triggers: List[dict]) -> str:
    if not triggers:
        return ""
    lines = [f"\n## TRIGGERS THAT FIRED ({len(triggers)})"]
    for t in triggers:
        lines.append(f"- [{t.get('trigger_id')}] {t.get('evidence')}")
    return "\n".join(lines)


def _render_gong_positives(ctx: DealContext) -> str:
    if not ctx.gong_positive_mentions and not ctx.gong_competitor_mentions:
        return ""
    lines = ["\n## GONG SIGNALS"]
    if ctx.gong_positive_mentions:
        lines.append("\n### Positive engagement signals (champion advocacy, buying questions, etc.)")
        for m in ctx.gong_positive_mentions[:6]:
            ts = m.timestamp_seconds or 0
            lines.append(f'- {m.call_date.date()} @ {ts}s [{m.matched_pattern}]: "{m.excerpt[:300]}"')
    if ctx.gong_competitor_mentions:
        lines.append("\n### Incumbent/competitor pain (where prospect articulated frustration with current tools)")
        for m in ctx.gong_competitor_mentions[:6]:
            ts = m.timestamp_seconds or 0
            lines.append(f'- {m.call_date.date()} @ {ts}s [{m.matched_pattern}]: "{m.excerpt[:300]}"')
    return "\n".join(lines)


def _render_meddpicc_evidence(ctx: DealContext) -> str:
    if not ctx.meddpicc_evidence:
        return ""
    lines = ["\n## MEDDPICC EVIDENCE FIELDS (look for win signals)"]
    for dim, text in ctx.meddpicc_evidence.items():
        if text:
            lines.append(f"\n**{dim.upper()}**")
            lines.append(text[:500])
    return "\n".join(lines)


def _render_similar_won_deals(deals: list) -> str:
    if not deals:
        return "\n## SIMILAR PRIOR WON DEALS\n(No comparable won deals in current intel pack — be honest about this.)"
    lines = [f"\n## SIMILAR PRIOR WON DEALS ({len(deals)} closest matches — cite these by name)"]
    for d in deals:
        lines.append(f"\n### {d.get('name')} (${d.get('amount') or 0:,.0f} | {d.get('segment')} | {d.get('business_type')})")
        if d.get('overall_summary'):
            lines.append(f"- Summary: {d['overall_summary'][:400]}")
        if d.get('champion_evidence'):
            lines.append(f"- Champion evidence: {d['champion_evidence'][:300]}")
        if d.get('purchase_driver'):
            lines.append(f"- Purchase driver: {d['purchase_driver'][:300]}")
    return "\n".join(lines)


def _render_win_pattern_quotes(quotes: list) -> str:
    if not quotes:
        return ""
    lines = ["\n## VERBATIM WIN-PATTERN QUOTES (from prior won deals)"]
    for q in quotes:
        lines.append(f'- [{q.get("pattern")}] {q.get("deal_name")}: "{q.get("quote", "")[:300]}"')
    return "\n".join(lines)


def _render_task(persona_id: str) -> str:
    return f"""\n---\n
# YOUR TASK

You are firing as the **{persona_id}** persona for the **BLUE TEAM**.

Produce a structured argument using the `submit_argument` tool that makes the win case for this deal.

Every claim must cite at least one of:
- A Gong moment listed above
- A Salesforce field / MEDDPICC evidence referenced above
- A specific prior WON deal named above
- A specific win-pattern quote provided

If a claim cannot be evidenced from this material, DROP IT. Better to make 2 strong claims than 5 weak ones.
If win signals are genuinely thin, say so honestly — the Arbiter rewards restraint and penalizes spin.
"""
