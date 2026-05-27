"""
Structured follow-up question templates for multi-turn Arbiter (Phase 4).

These are NOT free-form. The Arbiter selects from a fixed library to prevent
question selection from becoming opinion injection.
"""
from __future__ import annotations
from typing import Optional
from ..schemas import TeamScoring


def select_followup_template(my_scoring: TeamScoring, opponent: TeamScoring) -> Optional[str]:
    """
    Returns the templated follow-up question to send to this side, or None if no follow-up needed.
    """
    # If this side has weak Recency on multiple claims
    weak_recency = [c for c in my_scoring.scored_claims if c.recency <= 1]
    if len(weak_recency) >= 2:
        return _strengthen_recency(weak_recency[0])

    # If this side has weak Specificity on multiple claims
    weak_specificity = [c for c in my_scoring.scored_claims if c.specificity <= 1]
    if len(weak_specificity) >= 2:
        return _strengthen_specificity(weak_specificity[0])

    # If this side has too few claims
    if my_scoring.n_claims < 3:
        return _respond_to_volume_gap(my_scoring.n_claims)

    # If this side did not address opponent's top claim
    if not my_scoring.addressed_opponents_top_claim and opponent.scored_claims:
        return _address_strongest_counter(opponent)

    # No follow-up needed
    return None


def _strengthen_recency(weak_claim) -> str:
    return (
        f"Your claim '{weak_claim.claim.statement[:120]}' cited evidence with low recency (scored "
        f"{weak_claim.recency}/3). Provide evidence from the LAST 14 DAYS or revise the claim. "
        "Do not introduce new arguments outside this scope."
    )


def _strengthen_specificity(weak_claim) -> str:
    return (
        f"Your claim '{weak_claim.claim.statement[:120]}' scored {weak_claim.specificity}/3 on "
        "Specificity. Name the specific person (by role), date, and dollar/time amount, or revise. "
        "Do not expand your argument beyond this question."
    )


def _respond_to_volume_gap(n: int) -> str:
    return (
        f"Your argument cited only {n} claims. The threshold for High Confidence is 4. "
        "List 2 additional SPECIFIC evidence items with citations, or explicitly concede that your "
        "side is under-supported on this deal."
    )


def _address_strongest_counter(opponent: TeamScoring) -> str:
    top = opponent.scored_claims[0]
    return (
        f"Your opponent's strongest claim was: '{top.claim.statement[:200]}' "
        f"(quality score {top.quality}/13). Provide evidence that DIRECTLY addresses this claim, "
        "or explicitly concede the point. Do not introduce new arguments outside this scope."
    )


ROUND_2_CONSTRAINT = """
This is ROUND 2 of the debate. Your previous argument is shown above. You may ONLY respond to the
specific question asked. Either:
(a) Cite NEW evidence not in your Round 1 argument that addresses the question, OR
(b) Explicitly concede the gap.

Do NOT expand your Round 1 argument beyond the scope of the question above.
Use the submit_argument tool to return your Round 2 response.
"""
