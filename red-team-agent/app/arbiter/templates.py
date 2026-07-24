"""
Structured follow-up question templates for the multi-turn Arbiter.

Two categories:
  1. EVIDENCE QUALITY probes — fire when claim quality is low (recency, specificity, etc.)
  2. SUBSTANTIVE CONTRADICTION probes — fire when teams talk past each other

The Arbiter selects from a fixed library to keep question selection mechanical
rather than opinion-injecting.
"""
from __future__ import annotations
from typing import Optional, List
from ..schemas import TeamArgument, TeamScoring, ContradictionPair, ScoredClaim, ProbeFired


# =========================================================================
# EVIDENCE QUALITY PROBES (Round 2 — when claim quality is low)
# =========================================================================

def select_quality_probe(my_scoring: TeamScoring, opponent: TeamScoring) -> Optional[ProbeFired]:
    """
    For when this side's claims are evidentially thin.
    Returns the templated follow-up question, or None.
    """
    # Recency gap
    weak_recency = [c for c in my_scoring.scored_claims if c.recency <= 1]
    if len(weak_recency) >= 2:
        wc = weak_recency[0]
        return ProbeFired(
            probe_type="strengthen_recency",
            target_team=my_scoring.team,
            question=(
                f"Your claim '{wc.claim.statement[:120]}' cited evidence with low recency "
                f"(scored {wc.recency}/3). Provide evidence from the LAST 14 DAYS or revise. "
                "Do not introduce new arguments outside this scope."
            ),
            addressed_topic="recency",
        )

    # Specificity gap
    weak_spec = [c for c in my_scoring.scored_claims if c.specificity <= 1]
    if len(weak_spec) >= 2:
        wc = weak_spec[0]
        return ProbeFired(
            probe_type="strengthen_specificity",
            target_team=my_scoring.team,
            question=(
                f"Your claim '{wc.claim.statement[:120]}' scored {wc.specificity}/3 on Specificity. "
                "Name the specific person (by role), date, and dollar/time amount, or revise."
            ),
            addressed_topic="specificity",
        )

    # Volume gap
    if my_scoring.n_claims < 3:
        return ProbeFired(
            probe_type="respond_to_volume_gap",
            target_team=my_scoring.team,
            question=(
                f"Your argument cited only {my_scoring.n_claims} claims. The threshold for High "
                "Confidence is 4. List 2 additional SPECIFIC evidence items with citations, "
                "or concede that your side is under-supported."
            ),
            addressed_topic="volume",
        )

    return None


# =========================================================================
# SUBSTANTIVE CONTRADICTION PROBES (Round 2 — when teams talk past each other)
# =========================================================================

def select_substantive_probe(
    contradiction: ContradictionPair, opponent: TeamArgument, my_team: str
) -> Optional[ProbeFired]:
    """
    Given a detected contradiction, pick the right probe type for the topic
    and render the question with specifics from the actual claims.
    """
    topic = contradiction.topic
    # The team that needs to respond is the one that didn\'t address the topic
    target_team = contradiction.unaddressed_by

    # Only fire if this side is the target
    if target_team != my_team:
        return None

    # Pick the probe type based on the topic
    if "eb_authority" in topic:
        return _authority_probe(contradiction, opponent, target_team)
    if "timeline_feasibility" in topic:
        return _timeline_probe(contradiction, opponent, target_team)
    if "score_validity" in topic:
        return _score_validity_probe(contradiction, opponent, target_team)
    if "comparable_cohort" in topic:
        return _comparable_cohort_probe(contradiction, opponent, target_team)
    if "champion_strength" in topic:
        return _authority_probe(contradiction, opponent, target_team)  # adjacent topic
    if "competitor" in topic:
        return _comparable_cohort_probe(contradiction, opponent, target_team)
    if "pricing" in topic:
        return _generic_substantive_probe(contradiction, opponent, target_team, "pricing")
    if "security_compliance" in topic:
        return _timeline_probe(contradiction, opponent, target_team)

    return _generic_substantive_probe(contradiction, opponent, target_team, topic)


def _authority_probe(c: ContradictionPair, opponent: TeamArgument, target: str) -> ProbeFired:
    opp_claim = c.blue_claim_text if target == "red" else c.red_claim_text
    return ProbeFired(
        probe_type="authority_probe",
        target_team=target,
        question=(
            f"Your opponent's claim: '{opp_claim[:250]}' rests on the question of WHO has "
            "signature authority and whether they're engaged. "
            f"Address this directly: name the actual Economic Buyer for this deal (by role, "
            "not name), the date they were last in a scheduled meeting, and whether the "
            "champion is the EB or a proxy. If you cannot, concede that EB authority is "
            "unconfirmed and the MEDDPICC EB score is overstated."
        ),
        addressed_topic="eb_authority",
    )


def _timeline_probe(c: ContradictionPair, opponent: TeamArgument, target: str) -> ProbeFired:
    return ProbeFired(
        probe_type="timeline_feasibility_probe",
        target_team=target,
        question=(
            "Address the contract path timeline: name the InfoSec start date, Legal redline "
            "cycle length, Procurement queue position, and signature authority for this "
            "specific account. Project a realistic close date based on that path. If your "
            "projected close exceeds the current SF Close Date by 30+ days, concede the "
            "forecast period is at risk."
        ),
        addressed_topic="timeline_feasibility",
    )


def _score_validity_probe(c: ContradictionPair, opponent: TeamArgument, target: str) -> ProbeFired:
    opp_claim = c.blue_claim_text if target == "red" else c.red_claim_text
    return ProbeFired(
        probe_type="score_validity_probe",
        target_team=target,
        question=(
            f"Your opponent's argument leans on MEDDPICC composite/individual scores: "
            f"'{opp_claim[:250]}'. Address the scoring question directly: are the scores "
            "accurate as-recorded, or are specific pillars inflated? If inflated, name the "
            "pillar most affected, cite the SF evidence field that doesn't support the "
            "score, and provide your re-baselined estimate. If accurate, defend the highest-"
            "scoring pillar with specific evidence."
        ),
        addressed_topic="score_validity",
    )


def _comparable_cohort_probe(c: ContradictionPair, opponent: TeamArgument, target: str) -> ProbeFired:
    opp_claim = c.blue_claim_text if target == "red" else c.red_claim_text
    return ProbeFired(
        probe_type="comparable_cohort_probe",
        target_team=target,
        question=(
            f"Your opponent's argument rests on this precedent claim: '{opp_claim[:250]}'. "
            "Address the precedent question directly: what is the SINGLE distinguishing "
            "variable between the won-cohort and lost-cohort precedents at the time of "
            "forecast, and which side of that variable does today's deal sit on? Name the "
            "variable specifically. If you cannot distinguish, concede the opposing "
            "precedent set is the correct comparable."
        ),
        addressed_topic="comparable_cohort",
    )


def _generic_substantive_probe(c: ContradictionPair, opponent: TeamArgument, target: str, topic: str) -> ProbeFired:
    opp_claim = c.blue_claim_text if target == "red" else c.red_claim_text
    return ProbeFired(
        probe_type=f"generic_probe_{topic}",
        target_team=target,
        question=(
            f"Your opponent made this claim that your argument did not address: "
            f"'{opp_claim[:250]}'. Provide direct evidence that engages this claim — "
            "either confirming, refuting, or explicitly conceding the point. Do not "
            "introduce new arguments outside this topic."
        ),
        addressed_topic=topic,
    )


# =========================================================================
# Combined selector — picks the best probe given all signals
# =========================================================================

def select_probes_for_team(
    my_team: str,
    my_scoring: TeamScoring,
    opponent_scoring: TeamScoring,
    opponent_arg: TeamArgument,
    contradictions: List[ContradictionPair],
) -> Optional[ProbeFired]:
    """
    Pick ONE probe for this team. Priority:
      1. Substantive contradiction on this team\'s side (high-stakes topics first)
      2. Evidence quality gap
      3. None — this side\'s argument is solid and complete
    """
    # 1. Substantive contradictions targeting this team
    high_stakes = ["eb_authority", "timeline_feasibility", "score_validity"]
    for stake in high_stakes:
        for c in contradictions:
            if c.unaddressed_by == my_team and stake in c.topic:
                probe = select_substantive_probe(c, opponent_arg, my_team)
                if probe:
                    return probe

    # Then any other substantive contradiction
    for c in contradictions:
        if c.unaddressed_by == my_team:
            probe = select_substantive_probe(c, opponent_arg, my_team)
            if probe:
                return probe

    # 2. Evidence quality
    return select_quality_probe(my_scoring, opponent_scoring)


# =========================================================================
# Round 2 system-prompt constraint
# =========================================================================

ROUND_2_CONSTRAINT = """
This is ROUND 2 of the debate. Your previous argument is shown above. You may ONLY respond to
the specific question asked. Either:
(a) Cite NEW evidence not in your Round 1 argument that addresses the question, OR
(b) Explicitly concede the gap with a one-line acknowledgment.

Do NOT expand your Round 1 argument beyond the scope of the question.
Use the submit_argument tool. Your response should contain 1-3 claims focused entirely on the
follow-up question. Restraint is rewarded — fabricated coverage is penalized.
"""
