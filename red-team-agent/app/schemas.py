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


class WireClaim(_Wire):
    statement: str
    patternMatch: Optional[str] = None
    citations: List[WireCitation] = Field(default_factory=list)


class WireRecommendedAction(_Wire):
    action: str
    ownerRole: str = ""
    byDate: str = ""
    expectedSignal: str = ""


class PersonaArgument(_Wire):
    """Wire shape Merlin's `RedTeamPersonaArgument` Zod expects."""

    persona: str
    headline: str
    riskScore: float = Field(default=0.0, ge=0.0, le=1.0)
    claims: List[WireClaim] = Field(default_factory=list)
    recommendedActions: List[WireRecommendedAction] = Field(default_factory=list)


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
    # Blue Team evidence bucket — same external-speaker segments as the
    # competitor/objection lists; Blue's prompt narrows them via win-pattern
    # keywords.
    gong_positive_mentions: List[GongMention] = Field(default_factory=list)
    gong_recent_summary: Optional[str] = None

    sf_recent_field_changes: List[Dict[str, Any]] = Field(default_factory=list)

    # Routing hints from the trigger evaluation. Populated by the arbiter
    # entry point so `personas.routing.route_personas` can pick the right
    # Red+Blue pair without re-running the rules engine.
    fired_triggers: List[Dict[str, Any]] = Field(default_factory=list)

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


# ─────────────────────────────────────────────────────────────────────────────
# ARBITER TYPES — added for Phase 2 (Blue Team) + Phase 3 (Arbiter)
# ─────────────────────────────────────────────────────────────────────────────


class TeamArgument(BaseModel):
    """
    Arbiter-side view of an agent argument: `AgentArgument` plus the `team`
    discriminator the scorer + multi_turn code reads. Built from the raw
    managed-agent output via `from_agent_argument(arg, team)`.
    """

    team: Literal["red", "blue"]
    persona_id: str
    deal_name: str
    headline: str
    claims: List[Claim] = Field(default_factory=list)
    recommended_actions: List[RecommendedAction] = Field(default_factory=list)

    @classmethod
    def from_agent_argument(
        cls, arg: "AgentArgument", team: Literal["red", "blue"]
    ) -> "TeamArgument":
        return cls(team=team, **arg.model_dump())


class ScoredClaim(BaseModel):
    """One claim plus its 5-dimension evidence-quality breakdown."""

    claim: Claim
    specificity: int  # 0-3
    recency: int  # 0-3
    source_quality: int  # 0-3
    counter_response: int  # 0-2 (filled in Round 2)
    quality: int = 0  # sum, 0-13


class TeamScoring(BaseModel):
    team: Literal["red", "blue"]
    total_score: float
    avg_quality: float
    n_claims: int
    scored_claims: List[ScoredClaim] = Field(default_factory=list)
    addressed_opponents_top_claim: bool = False


class RouteResult(BaseModel):
    red_persona_id: str
    blue_persona_id: str
    reason: str


class ArbiterRequest(_Wire):
    """Optional /arbiter override knobs. /arbiter still accepts the standard
    IntelPackRequest as its primary input — this is the in-body toggle for
    multi-turn behavior."""

    enable_followup: bool = True


class ArbiterVerdict(_Wire):
    """Response body for `POST /arbiter`. Merlin's Zod parses this exactly."""

    evaluatedAt: str
    shadowMode: bool = False
    opportunityId: str
    probability: int = Field(ge=0, le=100)
    confidence: Literal["High", "Medium", "Low"]
    disagreement: float = Field(ge=0.0, le=1.0)
    baseRate: float
    meddpiccLift: float
    redArgument: Optional[TeamArgument] = None
    blueArgument: Optional[TeamArgument] = None
    redScoring: Optional[TeamScoring] = None
    blueScoring: Optional[TeamScoring] = None
    topActions: List[str] = Field(default_factory=list)
    explanation: str = ""
    roundsCompleted: int = 1
    firedTriggers: List[str] = Field(default_factory=list)
    routeReason: str = ""
    cooldownUntilIso: Optional[str] = None
    dropReason: Optional[str] = None

    # ─── Upgraded arbiter (v2.1) — all OPTIONAL for backward compat ─────────
    # Populated when Round 2 fires; otherwise null/empty.
    probabilityRound1: Optional[int] = None
    probabilityRound2: Optional[int] = None
    disagreementRound1: Optional[float] = None
    disagreementRound2: Optional[float] = None
    contradictionsDetected: List["ContradictionPair"] = Field(default_factory=list)
    probesFired: List["ProbeFired"] = Field(default_factory=list)
    synthesis: Optional["ArbiterSynthesis"] = None


# ─────────────────────────────────────────────────────────────────────────────
# Upgraded arbiter (v2.1) — substantive-contradiction detection + synthesis
# Nested types stay snake_case to match the design-agent contract; the top-
# level ArbiterVerdict fields are camelCase to match our existing wire shape.
# ─────────────────────────────────────────────────────────────────────────────


class Concession(BaseModel):
    """Something one side gave up in Round 2."""

    conceding_team: Literal["red", "blue"]
    on_topic: str  # short label: "comparable_cohort", "eb_authority", etc.
    summary: str   # 1-2 sentences describing what was conceded
    impact: str    # how this changes the analysis


class ScenarioBranch(BaseModel):
    """If/then diagnostic — what to look for in the next 7 days."""

    condition: str
    new_probability: int = Field(ge=0, le=100)
    new_lean: Literal["win", "loss", "uncertain"]
    rationale: str


class DiscriminatingVariable(BaseModel):
    """The single most predictive variable separating won and lost cohorts."""

    variable: str
    won_cohort_pct: int
    lost_cohort_pct: int
    this_deal_status: Literal["present", "absent", "ambiguous"]
    implication: str


class ContradictionPair(BaseModel):
    """One pair of opposing claims that the Arbiter detected as unaddressed."""

    red_claim_text: str
    blue_claim_text: str
    topic: str
    unaddressed_by: Literal["red", "blue", "both"]


class ProbeFired(BaseModel):
    """Record of one Arbiter probe in Round 2."""

    probe_type: str
    target_team: Literal["red", "blue"]
    question: str
    addressed_topic: str


class ArbiterSynthesis(BaseModel):
    """Output of the post-debate synthesizer — extracts structured insight from the transcript."""

    resolved_contradictions: List[Concession] = Field(default_factory=list)
    discriminating_variable: Optional[DiscriminatingVariable] = None
    if_then_diagnostic: List[ScenarioBranch] = Field(default_factory=list)
    narrative: str = ""


# ─────────────────────────────────────────────────────────────────────────────
# CONVERSATIONAL ARBITER MODERATOR (Phase 4) — /arbiter/chat wire types
# ─────────────────────────────────────────────────────────────────────────────


ArbiterChatRole = Literal["user", "moderator", "red", "blue", "system"]

ArbiterChatToolName = Literal[
    "summon_red_team",
    "summon_blue_team",
    "recompute_probability",
    "lookup_prior_deal",
]

ArbiterChatScenarioLean = Literal["win", "loss", "uncertain"]


class ChatConversationTurn(_Wire):
    role: ArbiterChatRole
    content: str
    metadata: Optional[Dict[str, Any]] = None


class ChatToolCallTrace(_Wire):
    tool: ArbiterChatToolName
    input: Dict[str, Any] = Field(default_factory=dict)
    resultSummary: str = ""


class ChatRequest(_Wire):
    """POST /arbiter/chat — rep's follow-up in a verdict thread.

    `verdict` is the original ArbiterVerdict snapshot; `intelPack` is the full
    IntelPackRequest used at debate time. Both carried in the body so the
    Python service stays stateless (cooldown table aside)."""

    conversationId: str
    verdict: ArbiterVerdict
    intelPack: Dict[str, Any]
    priorTurns: List[ChatConversationTurn] = Field(default_factory=list)
    userMessage: str


class ChatResponse(_Wire):
    """Response from the moderator. `appendedTurns` are turns Merlin should
    write to verdict_conversation_turns alongside the moderator's reply — one
    per summoned team / recomputation / lookup."""

    reply: str
    toolCalls: List[ChatToolCallTrace] = Field(default_factory=list)
    recomputedProbability: Optional[int] = None
    recomputedLean: Optional[ArbiterChatScenarioLean] = None
    scenarioRationale: Optional[str] = None
    hopsUsed: int = 0
    appendedTurns: List[ChatConversationTurn] = Field(default_factory=list)


ArbiterVerdict.model_rebuild()
