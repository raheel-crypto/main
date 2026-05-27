"""
Contradiction detector — finds when Red and Blue Team have built strong cases on
DIFFERENT premises that never met. Fires Round 2 even when surface disagreement
score is low.

This is the most important Round 2 trigger: two confident teams arguing past
each other on a deal where the right answer hinges on resolving the contradiction.
"""
from __future__ import annotations
import re
from typing import List, Tuple
from ..schemas import TeamArgument, Claim, ContradictionPair, TeamScoring


# Topic categories — used to classify each claim
TOPIC_PATTERNS = {
    "comparable_cohort": [
        r"\b(prior|previous|comparable|precedent|pattern|cohort|similar deals?|like .{0,30}deal)\b",
        r"\b(BNPP|Wells Fargo|Daiwa|Jefferies|Nomura|Carlyle)\b",  # named won-deal references
        r"\b(Briarwood|Sideline|AltaView|Citizens|Piper Sandler|TA Associates)\b",  # named lost-deal references
        r"\bclosed[- ](won|lost)\b",
    ],
    "eb_authority": [
        r"\b(economic buyer|EB|signature authority|approves?|signs?|budget holder)\b",
        r"\b(CFO|CIO|managing partner|head of|signatory)\b",
        r"\b(no power|wrong authority|champion[- ]?as[- ]?EB)\b",
    ],
    "score_validity": [
        r"\bMEDDPICC\b.{0,40}(score|composite|above|below|inflated|accurate)",
        r"\b(score|composite)\s*(of|=)?\s*\d+\b",
        r"\b(inflated|accurate|reliable|overstated|unreliable)\b.{0,30}\b(score|MEDDPICC)\b",
    ],
    "timeline_feasibility": [
        r"\b(close date|9/30|by Q\d|by (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec))\b",
        r"\b(InfoSec|Procurement|Legal|paper process|MSA|DPA|redline)\b",
        r"\b(runway|burn|timeline|slipp(age|ed)|push out)\b",
    ],
    "champion_strength": [
        r"\b(champion|advoc(ate|acy)|fight for|push for|escalat|driving (the )?process)\b",
        r"\b(in-the-moment|written escalation|introduced.{0,15}EB)\b",
    ],
    "competitor": [
        r"\b(Claude|Anthropic|ChatGPT|OpenAI|Copilot|Hebbia|AlphaSense|BlueFlame|internal build)\b",
        r"\b(incumbent|head[- ]?to[- ]?head|bake[- ]?off|RFP)\b",
    ],
    "pricing": [
        r"\b(price|pricing|sticker shock|justify|expensive|seat|per[- ]seat|budget)\b",
        r"\b\$\d+[Kk]?\b",
    ],
    "security_compliance": [
        r"\b(security|InfoSec|SOC 2|ISO 27001|compliance|data residency|DPA|SIG)\b",
    ],
}


def classify_claim(claim: Claim) -> List[str]:
    """Return all topics this claim touches on."""
    blob = claim.statement + " " + " ".join(
        (c.reference or "") + " " + (c.excerpt or "") for c in claim.citations
    )
    topics = []
    for topic, patterns in TOPIC_PATTERNS.items():
        for pat in patterns:
            if re.search(pat, blob, flags=re.IGNORECASE):
                topics.append(topic)
                break
    return topics or ["general"]


def find_unaddressed_contradictions(
    red: TeamArgument, blue: TeamArgument
) -> List[ContradictionPair]:
    """
    For each TOP red claim, check if any blue claim addresses the same topic.
    For each TOP blue claim, check if any red claim addresses the same topic.
    A claim is "top" if it's in the first 3 claims (which the agents order by strength).
    """
    contradictions = []
    red_top = red.claims[:3] if red.claims else []
    blue_top = blue.claims[:3] if blue.claims else []

    # Classify all claims
    red_topics = [(c, classify_claim(c)) for c in red.claims]
    blue_topics = [(c, classify_claim(c)) for c in blue.claims]

    # For each Red top claim, find topics not addressed by any Blue claim
    for red_claim in red_top:
        r_topics = set(classify_claim(red_claim))
        blue_addresses = False
        for _, b_topics in blue_topics:
            if r_topics & set(b_topics):
                blue_addresses = True
                break
        if not blue_addresses and r_topics != {"general"}:
            contradictions.append(ContradictionPair(
                red_claim_text=red_claim.statement[:200],
                blue_claim_text="(Blue did not address this topic)",
                topic=",".join(sorted(r_topics)),
                unaddressed_by="blue",
            ))

    # Same for Blue top claims
    for blue_claim in blue_top:
        b_topics = set(classify_claim(blue_claim))
        red_addresses = False
        for _, r_topics in red_topics:
            if b_topics & set(r_topics):
                red_addresses = True
                break
        if not red_addresses and b_topics != {"general"}:
            contradictions.append(ContradictionPair(
                red_claim_text="(Red did not address this topic)",
                blue_claim_text=blue_claim.statement[:200],
                topic=",".join(sorted(b_topics)),
                unaddressed_by="red",
            ))

    return contradictions


def needs_substantive_followup(
    red: TeamArgument, blue: TeamArgument, surface_disagreement: float
) -> Tuple[bool, List[ContradictionPair]]:
    """
    Returns (should_fire_round_2, list_of_contradictions).
    Fires if EITHER:
      - Surface disagreement is high (> 0.5) — existing trigger
      - 2+ substantive contradictions detected even at low surface disagreement
      - At least 1 contradiction on a high-stakes topic (eb_authority, timeline_feasibility)
    """
    contradictions = find_unaddressed_contradictions(red, blue)

    if surface_disagreement > 0.5:
        return True, contradictions

    if len(contradictions) >= 2:
        return True, contradictions

    high_stakes_topics = {"eb_authority", "timeline_feasibility", "score_validity"}
    for c in contradictions:
        topics = set(c.topic.split(","))
        if topics & high_stakes_topics:
            return True, contradictions

    return False, contradictions
