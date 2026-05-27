"""
Probability calculation — from team scores to probability-to-buy.

Uses base rate by segment + business type, adjusted by:
  - Argument strength delta (Blue score - Red score, normalized)
  - MEDDPICC structural lift (vs lost-deal average)

Parameters alpha/beta tune via Brier score against historical outcomes.
"""
from __future__ import annotations
import math
from typing import Tuple
from ..schemas import DealContext, TeamScoring, ArbiterVerdict


# Default base rates for advanced-stage New Business deals.
# Tune these quarterly as data grows.
BASE_RATES = {
    ("Enterprise", "investment_bank"): 0.35,
    ("Enterprise", "private_equity"): 0.15,
    ("Enterprise", "hedge_fund"): 0.20,
    ("Enterprise", None): 0.20,
    ("Mid-Market", "investment_bank"): 0.18,
    ("Mid-Market", "private_equity"): 0.10,
    ("Mid-Market", "hedge_fund"): 0.12,
    ("Mid-Market", None): 0.10,
    ("SMB", None): 0.05,
    (None, None): 0.10,
}

# Tunable parameters — calibrate via Brier score
ALPHA = 1.5  # argument strength weight
BETA = 1.0   # MEDDPICC structural weight

# MEDDPICC reference averages (from cohort_stats)
LOST_AVG_OVERALL = 43.2
WON_AVG_OVERALL = 48.9


def get_base_rate(segment: str | None, business_type: str | None) -> float:
    if (segment, business_type) in BASE_RATES:
        return BASE_RATES[(segment, business_type)]
    if (segment, None) in BASE_RATES:
        return BASE_RATES[(segment, None)]
    return BASE_RATES[(None, None)]


def compute_probability(
    ctx: DealContext,
    red: TeamScoring,
    blue: TeamScoring,
    alpha: float = ALPHA,
    beta: float = BETA,
) -> Tuple[int, str, float, float]:
    """
    Returns (probability_pct, confidence_band, base_rate, meddpicc_lift).
    """
    base_rate = get_base_rate(ctx.segment, ctx.business_type)

    # Argument strength delta
    total_score = red.total_score + blue.total_score
    if total_score > 0:
        delta = (blue.total_score - red.total_score) / max(total_score, 10)
    else:
        delta = 0.0
    delta = max(-1.0, min(1.0, delta))

    # MEDDPICC structural lift
    overall = ctx.meddpicc.overall or LOST_AVG_OVERALL
    meddpicc_lift = (overall - LOST_AVG_OVERALL) / 100.0

    # Posterior in logit space
    base_logit = _logit(base_rate)
    posterior_logit = base_logit + (alpha * delta) + (beta * meddpicc_lift)
    p = _sigmoid(posterior_logit)

    # Round to nearest 5%
    prob_pct = int(round(p * 100 / 5) * 5)
    prob_pct = max(0, min(100, prob_pct))

    confidence = compute_confidence(red, blue)
    return prob_pct, confidence, base_rate, meddpicc_lift


def compute_confidence(red: TeamScoring, blue: TeamScoring) -> str:
    high_both = red.n_claims >= 4 and blue.n_claims >= 4 and red.avg_quality >= 8 and blue.avg_quality >= 8
    low_either = (red.n_claims < 3 or blue.n_claims < 3) or (red.avg_quality < 5 or blue.avg_quality < 5)
    if high_both:
        return "High"
    if low_either:
        return "Low"
    return "Medium"


def compute_disagreement(red: TeamScoring, blue: TeamScoring) -> float:
    total = red.total_score + blue.total_score
    if total == 0:
        return 0.0
    return abs(red.total_score - blue.total_score) / total


def _logit(p: float) -> float:
    p = max(0.001, min(0.999, p))
    return math.log(p / (1 - p))


def _sigmoid(x: float) -> float:
    return 1 / (1 + math.exp(-x))
