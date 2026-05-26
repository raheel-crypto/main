"""
Translate Merlin's wire-format `IntelPackRequest` into the internal
`DealContext` that triggers / personas / runner work with.

Wire JSON is camelCase; internal models are snake_case. MEDDPICC scores and
evidence text live in `opportunity.customFields` — we pull them out into
typed slots so triggers.py can reason about them cleanly.

Gong transcripts arrive as raw speaker segments. We promote external-affiliated
segments into `GongMention`s and put the same list in both
`gong_competitor_mentions` and `gong_objection_mentions` — the regex triggers
filter them by pattern, so it's fine for the same segment to be a candidate for
both buckets.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from .schemas import (
    DealContext,
    GongCall,
    GongMention,
    IntelPackRequest,
    MEDDPICCScores,
    TranscriptSegment,
)


# Maps Salesforce API name → DealContext.meddpicc field. Mirror the table in
# triggers.py:_get_meddpicc_value so the two stay in lockstep.
MEDDPICC_FIELD_MAP: Dict[str, str] = {
    "Overall_Score__c": "overall",
    "Champion_Score__c": "champion",
    "Competition_Score__c": "competition",
    "Decision_Process_Score__c": "decision_process",
    "Decision_Criteria_Score__c": "decision_criteria",
    "Economic_Buyer_Score__c": "economic_buyer",
    "Paper_Process_Score__c": "paper_process",
    "Implicate_Pain_Score__c": "pain",
    "Metrics_Score__c": "metrics",
}

# Per-MEDDPICC dim, the SF long-text field that holds the rep's evidence.
MEDDPICC_EVIDENCE_FIELD_MAP: Dict[str, str] = {
    "champion": "Champion__c",
    "economic_buyer": "Economic_Buyer__c",
    "decision_criteria": "Decision_Criteria__c",
    "decision_process": "Decision_Process__c",
    "paper_process": "Paper_Process__c",
    "pain": "Pain__c",
    "metrics": "Metrics__c",
    "competition": "Competition__c",
}


def pack_to_context(pack: IntelPackRequest) -> DealContext:
    cf = pack.opportunity.customFields or {}

    meddpicc = MEDDPICCScores(
        **{
            internal: _to_float(cf.get(sf_name))
            for sf_name, internal in MEDDPICC_FIELD_MAP.items()
        }
    )
    evidence: Dict[str, Optional[str]] = {
        dim: _to_optional_str(cf.get(sf_name))
        for dim, sf_name in MEDDPICC_EVIDENCE_FIELD_MAP.items()
    }

    competitor_mentions, objection_mentions = _extract_gong_mentions(pack.gongCalls)
    gong_recent_summary = pack.gongCalls[0].brief if pack.gongCalls else None

    sf_field_changes = [
        {
            "field": fc.field,
            "old_value": fc.oldValue,
            "new_value": fc.newValue,
            "changed_at": fc.changedAt,
            "source": fc.source,
            "is_forward": _is_forward_change(fc.field, fc.oldValue, fc.newValue),
        }
        for fc in pack.recentFieldChanges
    ]

    age_in_days = _days_since(cf.get("CreatedDate"))
    last_dm_touch_days = _days_since(cf.get("Last_Touch_With_Decision_Maker__c"))

    return DealContext(
        opportunity_id=pack.opportunity.id,
        opportunity_name=pack.opportunity.name,
        account_name=pack.opportunity.accountName,
        amount=float(pack.opportunity.amount or 0.0),
        stage_name=pack.opportunity.stageName,
        segment=_to_optional_str(cf.get("Segment__c") or cf.get("Segment")),
        business_type=_to_optional_str(
            cf.get("Business_Type__c") or cf.get("Business_Type")
        ),
        deal_type=pack.opportunity.type,
        age_in_days=age_in_days or 0,
        days_since_decision_maker_touch=last_dm_touch_days,
        close_date=pack.opportunity.closeDate,
        forecast_category=_to_optional_str(cf.get("ForecastCategoryName")),
        assigned_ae=pack.owner.name,
        owner_id=pack.opportunity.ownerId,
        meddpicc=meddpicc,
        meddpicc_evidence=evidence,
        recent_gong_calls=len(pack.gongCalls),
        gong_competitor_mentions=competitor_mentions,
        gong_objection_mentions=objection_mentions,
        gong_recent_summary=gong_recent_summary,
        sf_recent_field_changes=sf_field_changes,
    )


def _extract_gong_mentions(
    calls: List[GongCall],
) -> tuple[List[GongMention], List[GongMention]]:
    """
    Promote external-affiliated transcript segments to GongMention objects so
    triggers.py's regex evaluation can iterate over them.

    Returns the same list for both buckets — the regex patterns filter what
    actually counts as a competitor mention vs objection mention.
    """
    mentions: List[GongMention] = []
    for call in calls:
        if not call.transcript:
            continue
        started = _parse_iso(call.startedAt) or datetime.now(timezone.utc)
        for seg in call.transcript.speakerSegments:
            if not seg.text:
                continue
            # Only prospect-side speech is "evidence" of risk. Skip internal
            # speakers (Rogo) and unknowns.
            aff = (seg.speakerAffiliation or "").lower()
            if aff and aff != "external":
                continue
            mentions.append(
                GongMention(
                    call_id=call.callId,
                    call_date=started,
                    speaker_role=_role_label(seg),
                    timestamp_seconds=int(seg.startSec) if seg.startSec else None,
                    excerpt=seg.text.strip(),
                )
            )
    # Same list, both buckets. Trigger regex narrows them.
    return (mentions, mentions)


def _role_label(seg: TranscriptSegment) -> Optional[str]:
    name = seg.speakerName or seg.speakerId
    aff = seg.speakerAffiliation
    if not name and not aff:
        return None
    if name and aff:
        return f"{aff}:{name}"
    return name or aff


def _to_float(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_optional_str(value: Any) -> Optional[str]:
    if value is None:
        return None
    s = str(value).strip()
    return s or None


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _days_since(value: Any) -> Optional[int]:
    dt = _parse_iso(_to_optional_str(value))
    if not dt:
        return None
    now = datetime.now(timezone.utc)
    delta = now - dt
    return max(0, delta.days)


# Hardcoded stage-forward ordering for the SF stage-advance trigger. Add custom
# stages here as Rogo's pipeline evolves.
_STAGE_ORDER = [
    "Stage 0 - Inbound",
    "Stage 1 - Discovery",
    "Stage 2 - Qualified",
    "Stage 3 - POV",
    "Stage 4 - Demo",
    "Stage 5 - Proposal",
    "Stage 6 - Negotiation",
    "Stage 7 - Closed Won",
    "Closed Lost",
]


def _is_forward_change(field: str, old: Any, new: Any) -> bool:
    if field != "StageName" or not isinstance(old, str) or not isinstance(new, str):
        return False
    try:
        return _STAGE_ORDER.index(new) > _STAGE_ORDER.index(old)
    except ValueError:
        # Stage name we don't know — fall back to lexical
        return new > old
