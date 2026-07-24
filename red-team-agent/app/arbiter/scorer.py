"""
Evidence quality scorer. Pure-Python, deterministic, calibratable via Brier score.

Scores each claim on 5 dimensions:
  - Specificity (0-3): named role/date/dollar vs. vague generality
  - Recency (0-3): last 7d / 30d / 90d / older
  - Source quality (0-3): verbatim Gong > email > rep note > inferred
  - Counter-response (0-2): did this side address opponent's strongest claim?
  - Volume (0-2): 1-2 claims = 0; 3-4 = 1; 5+ = 2 (applied to team, not per-claim)
"""
from __future__ import annotations
import re
from datetime import datetime, timezone, timedelta
from typing import Optional
from ..schemas import Claim, TeamArgument, ScoredClaim, TeamScoring


SPECIFIC_PATTERNS = [
    r"\$[\d,]+",                  # dollar amounts
    r"\d{4}-\d{2}-\d{2}",        # ISO dates
    r"@\s*\d+m\d+s",             # Gong timestamps
    r"\d+\s*(hours?|weeks?|days?)",  # time quantities
    r"\d+%",                       # percentages
]


def score_team_argument(arg: TeamArgument, opponent: Optional[TeamArgument] = None, now: Optional[datetime] = None) -> TeamScoring:
    """Score every claim in the argument. Optionally factor in opponent for counter-response."""
    now = now or datetime.now(timezone.utc)
    scored_claims = []
    addressed_opp = False
    if opponent:
        addressed_opp = _did_address_opponent(arg, opponent)

    for claim in arg.claims:
        sc = ScoredClaim(
            claim=claim,
            specificity=_score_specificity(claim),
            recency=_score_recency(claim, now),
            source_quality=_score_source_quality(claim),
            counter_response=2 if addressed_opp else 0,
            quality=0,  # filled below
        )
        sc.quality = sc.specificity + sc.recency + sc.source_quality + sc.counter_response
        scored_claims.append(sc)

    n = len(scored_claims)
    total = sum(c.quality for c in scored_claims)
    # Volume dimension: applied as a per-team bonus, capped at 2
    volume_bonus = 0 if n < 3 else (1 if n < 5 else 2)
    total += volume_bonus
    avg = total / n if n > 0 else 0

    return TeamScoring(
        team=arg.team,
        total_score=total,
        avg_quality=avg,
        n_claims=n,
        scored_claims=scored_claims,
        addressed_opponents_top_claim=addressed_opp,
    )


def _score_specificity(claim: Claim) -> int:
    """0-3 based on how concrete the claim is."""
    text = claim.statement + " " + " ".join((c.reference or "") + " " + (c.excerpt or "") for c in claim.citations)
    matches = sum(1 for pat in SPECIFIC_PATTERNS if re.search(pat, text))
    # Plus: named role mentioned (champion, EB, CFO, CISO)
    if re.search(r"\b(champion|economic buyer|EB|CFO|CISO|head of|managing partner|VP)\b", text, re.IGNORECASE):
        matches += 1
    return min(3, matches)


def _score_recency(claim: Claim, now: datetime) -> int:
    """Try to extract a date from citations and score based on recency."""
    for cit in claim.citations:
        ref = cit.reference or ""
        m = re.search(r"(\d{4})-(\d{2})-(\d{2})", ref)
        if m:
            try:
                d = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), tzinfo=timezone.utc)
                age_days = (now - d).days
                if age_days <= 7: return 3
                if age_days <= 30: return 2
                if age_days <= 90: return 1
                return 0
            except Exception:
                pass
    # No date found — default to neutral
    return 1


def _score_source_quality(claim: Claim) -> int:
    """Higher score for verbatim Gong/SF citations vs inferred."""
    best = 0
    for cit in claim.citations:
        if cit.kind == "gong":
            best = max(best, 3 if cit.excerpt else 2)
        elif cit.kind == "salesforce":
            best = max(best, 3 if cit.excerpt else 2)
        elif cit.kind == "prior_deal":
            best = max(best, 2)
        elif cit.kind == "intel_pack":
            best = max(best, 2)
        elif cit.kind == "public_source":
            best = max(best, 1)
    return best


def _did_address_opponent(arg: TeamArgument, opponent: TeamArgument) -> bool:
    """Did this side reference the opponent's strongest claim in any of their claims?"""
    if not opponent.claims:
        return False
    # Use first 50 chars of opponent's first claim as a fingerprint
    opp_fingerprint = opponent.claims[0].statement[:50].lower()
    own_text = " ".join(c.statement.lower() for c in arg.claims)
    # Crude heuristic — Phase 2 can improve with embeddings
    common_keywords = set(re.findall(r"\w{6,}", opp_fingerprint))
    own_keywords = set(re.findall(r"\w{6,}", own_text))
    overlap = common_keywords & own_keywords
    return len(overlap) >= 2
