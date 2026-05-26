"""
Pydantic mirrors of the contract defined in `slack-bot/src/types.ts`.

Source of truth for the shape is the TypeScript file — when Merlin's
intel-pack changes, update both sides together. The fields here intentionally
match the JSON wire format (camelCase) rather than Python style, so we don't
need any alias config to talk to Merlin.
"""
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class _Base(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)


# ── Request: RedTeamIntelPackRequest ─────────────────────────────────────────


class Opportunity(_Base):
    id: str
    name: str
    stageName: str
    type: str | None = None
    amount: float | None = None
    closeDate: str | None = None
    nextStep: str | None = None
    ownerId: str
    accountId: str
    accountName: str
    isRenewal: bool = False
    customFields: dict[str, Any] = Field(default_factory=dict)


class Owner(_Base):
    sfUserId: str | None = None
    name: str | None = None
    email: str | None = None
    slackUserId: str


class Account(_Base):
    id: str
    name: str
    industry: str | None = None
    website: str | None = None


class FieldChange(_Base):
    field: str
    oldValue: str | float | bool | None = None
    newValue: str | float | bool | None = None
    changedAt: str
    source: Literal["field_history", "snapshot_diff"]


class GongParty(_Base):
    name: str | None = None
    email: str | None = None
    affiliation: str | None = None
    title: str | None = None


class TranscriptSegment(_Base):
    speakerId: str | None = None
    speakerName: str | None = None
    speakerAffiliation: str | None = None
    text: str
    startSec: float | None = None
    endSec: float | None = None


class GongTranscript(_Base):
    speakerSegments: list[TranscriptSegment] = Field(default_factory=list)


class GongCall(_Base):
    callId: str
    title: str | None = None
    startedAt: str | None = None
    durationSec: float | None = None
    url: str | None = None
    brief: str | None = None
    parties: list[GongParty] = Field(default_factory=list)
    transcript: GongTranscript | None = None


class Activity(_Base):
    type: Literal["Task", "Event"]
    subject: str
    activityDate: str | None = None
    description: str | None = None


TriggerEvent = Literal["gong_call", "daily_sweep", "stage_advance", "manual"]


class TriggerMetadata(_Base):
    callId: str | None = None
    previousStage: str | None = None


class IntelPackRequest(_Base):
    schemaVersion: Literal["1"] = "1"
    opportunity: Opportunity
    owner: Owner
    account: Account
    recentFieldChanges: list[FieldChange] = Field(default_factory=list)
    gongCalls: list[GongCall] = Field(default_factory=list)
    activities: list[Activity] = Field(default_factory=list)
    triggerEvent: TriggerEvent
    triggerMetadata: TriggerMetadata = Field(default_factory=TriggerMetadata)
    shadowMode: bool = False


# ── Response: RedTeamRunResult ───────────────────────────────────────────────


CitationSourceType = Literal[
    "dead_deal",
    "gong_quote",
    "objection_quote",
    "competitor_profile",
    "field_change",
    "other",
]


class Citation(_Base):
    sourceType: CitationSourceType = "other"
    quote: str
    sourceLabel: str
    sourceUrl: str | None = None


class PersonaArgument(_Base):
    persona: str
    headline: str
    claim: str
    citations: list[Citation] = Field(default_factory=list)
    riskScore: float = Field(default=0.0, ge=0.0, le=1.0)


class RunResult(_Base):
    """
    Response body for `POST /evaluate`. Matches Merlin's
    `RedTeamRunResultSchema` (Zod).
    """

    evaluatedAt: str
    shadowMode: bool = False
    firedTriggers: list[str] = Field(default_factory=list)
    personasInvoked: list[PersonaArgument] = Field(default_factory=list)
    auditLogEntry: str = ""
    cooldownUntilIso: str | None = None
    dropReason: str | None = None
