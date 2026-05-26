"""
Trigger detection: given a DealContext, return the list of FiredTriggers.

Triggers are defined declaratively in `config/triggers.yaml`. This module
loads them and evaluates each against the context. The fired-trigger list
flows into `personas.select_personas` which decides who speaks this cycle.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import List

import yaml

from .schemas import DealContext, FiredTrigger


_CONFIG_PATH = Path(__file__).parent.parent / "config" / "triggers.yaml"


def load_config() -> dict:
    with open(_CONFIG_PATH) as f:
        return yaml.safe_load(f)


def evaluate(context: DealContext) -> List[FiredTrigger]:
    """Evaluate every configured trigger against the deal context."""
    config = load_config()
    fired: List[FiredTrigger] = []
    aggression = config["settings"]["segment_aggression"].get(context.segment, 1.0)

    for trig in config["triggers"]:
        result = _evaluate_one(trig, context)
        if result is None:
            continue
        evidence_excerpt, weight_override = result
        weight = (weight_override if weight_override else trig["weight"]) * aggression
        fired.append(
            FiredTrigger(
                trigger_id=trig["id"],
                weight=weight,
                evidence=evidence_excerpt,
                target_persona=_resolve_persona(trig, evidence_excerpt),
            )
        )
    return fired


# Back-compat alias for the older /evaluate orchestrator path.
def evaluate_triggers(context: DealContext) -> List[FiredTrigger]:
    return evaluate(context)


def _evaluate_one(trig: dict, ctx: DealContext):
    """Return (evidence_excerpt, weight_override) or None if trigger didn't fire."""
    det = trig["detection"]

    if det["type"] == "regex_on_transcript":
        flags = re.IGNORECASE if det.get("case_insensitive") else 0
        pat = re.compile(det["pattern"], flags)
        seen_ids: set[tuple[str, int | None]] = set()
        for mention in ctx.gong_competitor_mentions + ctx.gong_objection_mentions:
            key = (mention.call_id, mention.timestamp_seconds)
            if key in seen_ids:
                continue
            seen_ids.add(key)
            if pat.search(mention.excerpt):
                ts = mention.timestamp_seconds or 0
                date = mention.call_date.date() if mention.call_date else ""
                return (
                    f'Gong call {date} @ {ts}s: "{mention.excerpt[:200]}"',
                    None,
                )
        return None

    if det["type"] == "meeting_participant_check":
        # Phase 3 — orchestrator-side enrichment, not implemented yet.
        return None

    if det["type"] == "field_change":
        for change in ctx.sf_recent_field_changes:
            if change.get("field") != det["field"]:
                continue
            if det.get("direction") == "forward" and not change.get("is_forward"):
                continue
            if det.get("direction") == "increase":
                old = change.get("old_value") or 0
                new = change.get("new_value") or 0
                try:
                    if not (new > old * (1 + det.get("threshold_pct", 0) / 100)):
                        continue
                except TypeError:
                    continue
            if det.get("new_value_in"):
                if change.get("new_value") not in det["new_value_in"]:
                    continue
            if det.get("threshold_stage") and ctx.stage_name in (
                "Closed Won",
                "Closed Lost",
            ):
                continue
            return (
                f"SF field change: {change.get('field')} "
                f"{change.get('old_value')} -> {change.get('new_value')}",
                None,
            )
        return None

    if det["type"] == "field_populated":
        field = det["field"]
        for change in ctx.sf_recent_field_changes:
            if (
                change.get("field") == field
                and change.get("old_value") is None
                and change.get("new_value") is not None
            ):
                return (
                    f"SF field populated: {field} = {change.get('new_value')}",
                    None,
                )
        return None

    if det["type"] == "field_threshold":
        field = det["field"]
        score = _get_meddpicc_value(ctx, field)
        if score is None:
            return None
        op = det["operator"]
        val = det["value"]
        if op == "less_than" and score < val:
            min_stage = det.get("and_stage_at_least", 0)
            stage_num = _stage_number(ctx.stage_name)
            if stage_num >= min_stage:
                return (
                    f"SF: {field} = {score} (below threshold {val}) at stage {ctx.stage_name}",
                    None,
                )
        return None

    if det["type"] == "scheduled_check":
        # Handled by `evaluate_scheduled` on the daily cron path.
        return None

    return None


def _stage_number(stage_name: str) -> int:
    if not stage_name:
        return 0
    m = re.match(r"^\s*(\d+)", stage_name)
    return int(m.group(1)) if m else 0


def _get_meddpicc_value(ctx: DealContext, field_api: str):
    mapping = {
        "Overall_Score__c": ctx.meddpicc.overall,
        "Champion_Score__c": ctx.meddpicc.champion,
        "Competition_Score__c": ctx.meddpicc.competition,
        "Decision_Process_Score__c": ctx.meddpicc.decision_process,
        "Decision_Criteria_Score__c": ctx.meddpicc.decision_criteria,
        "Economic_Buyer_Score__c": ctx.meddpicc.economic_buyer,
        "Paper_Process_Score__c": ctx.meddpicc.paper_process,
        "Implicate_Pain_Score__c": ctx.meddpicc.pain,
        "Metrics_Score__c": ctx.meddpicc.metrics,
    }
    return mapping.get(field_api)


def _resolve_persona(trig: dict, evidence: str) -> str:
    """Handle 'dynamic' persona resolution by competitor name in the evidence."""
    persona = trig.get("maps_to_persona", "default_cro_challenger")
    if persona != "dynamic":
        return persona
    evidence_lower = evidence.lower()
    routing = {
        "claude": "claude_ae",
        "anthropic": "claude_ae",
        "chatgpt": "openai_microsoft_ae",
        "openai": "openai_microsoft_ae",
        "copilot": "openai_microsoft_ae",
        "hebbia": "hebbia_ae",
        "alphasense": "alphasense_ae",
        "blueflame": "hebbia_ae",
        "modelml": "hebbia_ae",
        "internal build": "internal_build_advocate",
    }
    for keyword, persona_id in routing.items():
        if keyword in evidence_lower:
            return persona_id
    return "default_cro_challenger"


def evaluate_scheduled(context: DealContext) -> List[FiredTrigger]:
    """Daily-cron path: evaluates time-based triggers (silence, aging, post-POV stall)."""
    config = load_config()
    fired: List[FiredTrigger] = []
    aggression = config["settings"]["segment_aggression"].get(context.segment, 1.0)

    for trig in config["triggers"]:
        det = trig["detection"]
        if det["type"] != "scheduled_check":
            continue

        rule = det.get("rule", "")
        if "Last_Touch_With_Decision_Maker__c" in rule:
            if (
                context.days_since_decision_maker_touch is not None
                and context.days_since_decision_maker_touch > 10
            ):
                fired.append(
                    FiredTrigger(
                        trigger_id=trig["id"],
                        weight=trig["weight"] * aggression,
                        evidence=(
                            f"Decision maker silent for "
                            f"{context.days_since_decision_maker_touch} days"
                        ),
                        target_persona=trig.get("maps_to_persona", "silent_buyer"),
                    )
                )

        if "LastStageChangeInDays" in rule:
            if context.age_in_days > 60:
                fired.append(
                    FiredTrigger(
                        trigger_id=trig["id"],
                        weight=trig["weight"] * aggression,
                        evidence=(
                            f"Deal age {context.age_in_days} days at stage "
                            f"{context.stage_name}"
                        ),
                        target_persona=trig.get("maps_to_persona", "silent_buyer"),
                    )
                )

    return fired
