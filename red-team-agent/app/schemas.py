"""
Schemas for the Red Team service.

Two layers:

1. **Wire types** — match Merlin's `RedTeamIntelPackRequest` / `RedTeamRunResult`
   JSON contract exactly. Field names are camelCase to mirror TypeScript.
   These are the source of truth for /evaluate's HTTP boundary.

2. **Internal types** — the agent's own data model (DealContext, FiredTrigger,
   AgentArgument with multiple Claims + RecommendedActions). These live behind
   the wire and are owned by `triggers.py` / `personas.py` / `runner.py`.

`app/context.py` translates wire → internal. `app/main.py` translates the
agent's `AgentArgument` output back into wire `PersonaArgument`s.
"""
from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


# ─────────────────────────────────────────────────────────────────────────────
# WIRE TYPES (Merlin contract)
# ─────────────────────────────────────────────────────────────────────────────


class _Wire(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


class Opportunity(_Wire):
    id: str
    name: str
    stageName: str
    type: Optional[str] = None
    amount: Optional[float] = None
    closeDate: Optional[str] = None
    nextStep: Optional[str] = None
    ownerId: str
    accountId: str
    accountName: str
    isRenewal: bool = False
    customFields: Dict[str, Any] = Field(default_factory=dict)


class Owner(_Wire):
    sfUserId: Optional[str] = None
    name: Optional[str] = None
    email: Optional[str] = None
    slackUserId: str


class Account(_Wire):
    id: str
    name: str
    industry: Optional[str] = None
    website: Optional[str] = None


class FieldChange(_Wire):
    field: str
    oldValue: Any = None
    newValue: Any = None
    changedAt: str
    source: Literal["field_history", "snapshot_diff"]


class GongParty(_Wire):
    name: Optional[str] = None
    email: Optional[str] = None
    affiliation: Optional[str] = None
    title: Optional[str] = None


class TranscriptSegment(_Wire):
    speakerId: Optional[str] = None
    speakerName: Optional[str] = None
    speakerAffiliation: Optional[str] = None
    text: str
    startSec: Optional[float] = None
    endSec: Optional[float] = None


class GongTranscript(_Wire):
    speakerSegments: List[TranscriptSegment] = Field(default_factory=list)


class GongCall(_Wire):
    callId: str
    title: Optional[str] = None
    startedAt: Optional[str] = None
    durationSec: Optional[float] = None
    url: Optional[str] = None
    brief: Optional[str] = None
    parties: List[GongParty] = Field(default_factory=list)
    transcript: Optional[GongTranscript] = None


class Activity(_Wire):
    type: Literal["Task", "Event"]
    subject: str
    activityDate: Optional[str] = None
    description: Optional[str] = None


TriggerEvent = Literal["gong_call", "daily_sweep", "stage_advance", "manual"]


class TriggerMetadata(_Wire):
    callId: Optional[str] = None
    previousStage: Optional[str] = None


class IntelPackRequest(_Wire):
    schemaVersion: Literal["1"] = "1"
    opportunity: Opportunity
    owner: Owner
    account: Account
    recentFieldChanges: List[FieldChange] = Field(default_factory=list)
    gongCalls: List[GongCall] = Field(default_factory=list)
    activities: List[Activity] = Field(default_factory=list)
    triggerEvent: TriggerEvent
    triggerMetadata: TriggerMetadata = Field(default_factory=TriggerMetadata)
    shadowMode: bool = False


# Response wire types — Merlin's Zod parses these by JSON field name.

WireCitationSourceType = Literal[
    "dead_deal",
    "gong_quote",
    "objection_quote",
    "competitor_profile",
    "field_change",
    "other",
]


class WireCitation(_Wire):
    sourceType: WireCitationSourceType = "other"
    quote: str
    sourceLabel: str
    sourceUrl: Optional[str] = None


class PersonaArgument(_Wire):
    """Flat wire shape Merlin's `RedTeamPersonaArgument` Zod expects."""

    persona: str
    headline: str
    claim: str
    citations: List[WireCitation] = Field(default_factory=list)
    riskScore: float = Field(default=0.0, ge=0.0, le=1.0)


class RunResult(_Wire):
    """Response body for `POST /evaluate` — matches `RedTeamRunResultSchema`."""

    evaluatedAt: str
    shadowMode: bool = False
    firedTriggers: List[str] = Field(default_factory=list)
    personasInvoked: List[PersonaArgument] = Field(default_factory=list)
    auditLogEntry: str = ""
    cooldownUntilIso: Optional[str] = None
    dropReason: Optional[str] = None


# ─────────────────────────────────────────────────────────────────────────────
# INTERNAL TYPES (used by triggers / personas / runner / intel_pack)
# ─────────────────────────────────────────────────────────────────────────────


class MEDDPICCScores(BaseModel):
    overall: Optional[float] = None
    champion: Optional[float] = None
    competition: Optional[float] = None
    decision_process: Optional[float] = None
    decision_criteria: Optional[float] = None
    economic_buyer: Optional[float] = None
    paper_process: Optional[float] = None
    pain: Optional[float] = None
    metrics: Optional[float] = None


class GongMention(BaseModel):
    """A specific moment in a Gong call worth referencing."""

    call_id: str
    call_date: datetime
    speaker_role: Optional[str] = None
    timestamp_seconds: Optional[int] = None
    excerpt: str
    matched_pattern: Optional[str] = None


class DealContext(BaseModel):
    """
    The full context payload triggers/personas/runner work with. The
    orchestrator translates the wire IntelPackRequest into this shape.
    """

    opportunity_id: str
    opportunity_name: str
    account_name: str
    amount: float
    stage_name: str
    segment: Optional[str] = None
    business_type: Optional[str] = None
    deal_type: Optional[str] = None
    age_in_days: int = 0
    days_since_decision_maker_touch: Optional[int] = None
    close_date: Optional[str] = None
    forecast_category: Optional[str] = None
    assigned_ae: Optional[str] = None
    owner_id: str

    meddpicc: MEDDPICCScores = Field(default_factory=MEDDPICCScores)
    meddpicc_evidence: Dict[str, Optional[str]] = Field(default_factory=dict)

    recent_gong_calls: int = 0
    gong_competitor_mentions: List[GongMention] = Field(default_factory=list)
    gong_objection_mentions: List[GongMention] = Field(default_factory=list)
    gong_recent_summary: Optional[str] = None

    sf_recent_field_changes: List[Dict[str, Any]] = Field(default_factory=list)

    last_inbound_email_date: Optional[datetime] = None
    last_outbound_email_date: Optional[datetime] = None

    dealroom_channel: Optional[str] = None
    dealroom_last_activity: Optional[datetime] = None


class FiredTrigger(BaseModel):
    trigger_id: str
    weight: float
    evidence: str
    target_persona: str


class DeadDealMatch(BaseModel):
    deal_name: str
    account: str
    amount: float
    primary_reason: Optional[str] = None
    final_competitor: Optional[str] = None
    one_line_takeaway: str
    cl_notes_excerpt: Optional[str] = None


class Citation(BaseModel):
    """Agent-side citation (matches the managed agent's submit_argument schema)."""

    kind: Literal["gong", "salesforce", "prior_deal", "intel_pack", "public_source"]
    reference: str
    excerpt: Optional[str] = None


class Claim(BaseModel):
    statement: str
    citations: List[Citation] = Field(default_factory=list)
    pattern_match: Optional[str] = None


class RecommendedAction(BaseModel):
    action: str
    owner_role: str
    by_date: str
    expected_signal: str


class AgentArgument(BaseModel):
    """What the managed agent returns via `submit_argument`."""

    persona_id: str
    deal_name: str
    headline: str
    claims: List[Claim] = Field(default_factory=list)
    recommended_actions: List[RecommendedAction] = Field(default_factory=list)


AgentArgument.model_rebuild()
Claim.model_rebuild()
