"""
Persona routing — given fired triggers + deal context, pick which Red persona
fires AND which Blue persona pairs with it.

When Red fires (e.g., Claude AE), Blue fires the paired counter (Anti-Claude Counsel).
This pairing keeps the debate symmetric.
"""
from __future__ import annotations
from typing import List, Tuple
from ..schemas import DealContext, RouteResult


# Pairing: red_persona -> blue_persona
PAIRINGS = {
    "claude_ae": "anti_claude_counsel",
    "openai_microsoft_ae": "anti_openai_microsoft_counsel",
    "hebbia_ae": "anti_hebbia_counsel",
    "alphasense_ae": "anti_alphasense_counsel",
    "internal_build_advocate": "anti_internal_build_counsel",
    "cfo_procurement": "pricing_justification_counsel",
    "ciso_persona": "compliance_closer",
    "silent_buyer": "champion_power_advocate",  # Blue argues champion strength
    "default_cro_challenger": "default_bull_case",
}


def route_personas(ctx: DealContext) -> RouteResult:
    """
    Pick the Red persona based on signals, then pick the paired Blue persona.

    Priority order (top trigger wins):
      1. Competitor mentioned in Gong → competitor-specific persona
      2. Pricing friction → CFO persona
      3. Security concern → CISO persona
      4. Internal build signal → Internal Build Advocate
      5. Decision-maker silence > 10d → Silent Buyer
      6. None → Default CRO Challenger
    """
    red_persona = _route_red(ctx)
    blue_persona = PAIRINGS.get(red_persona, "default_bull_case")
    reason = _explain(red_persona, ctx)
    return RouteResult(red_persona_id=red_persona, blue_persona_id=blue_persona, reason=reason)


def _route_red(ctx: DealContext) -> str:
    import re

    # 1. Competitor mention has highest priority — check trigger evidence first
    mention_text = " ".join(m.excerpt for m in (ctx.gong_competitor_mentions + ctx.gong_objection_mentions))
    lower = mention_text.lower()

    if re.search(r"\bhebbia\b", lower):
        return "hebbia_ae"  # vertical competitors get highest weight
    if re.search(r"\b(blue\s*flame|blueflame)\b", lower):
        return "hebbia_ae"  # routes to same playbook
    if re.search(r"\b(alpha\s*sense|tegus)\b", lower):
        return "alphasense_ae"
    if re.search(r"\b(microsoft\s*copilot|m365\s*copilot|copilot\s*for\s*m365)\b", lower):
        return "openai_microsoft_ae"
    if re.search(r"\b(chat\s*gpt|openai)\b", lower):
        return "openai_microsoft_ae"
    if re.search(r"\b(claude|anthropic)\b", lower):
        return "claude_ae"

    # 2. Internal build signal
    if re.search(r"\b(build (it )?(internally|ourselves|our own)|in-?house|prefer to build)\b", lower):
        return "internal_build_advocate"

    # 3. Pricing friction (only if no competitor)
    if re.search(r"\b(too expensive|sticker shock|minimum seat|cannot justify|cheaper alternative)\b", lower):
        return "cfo_procurement"

    # 4. Security concern
    if re.search(r"\b(soc ?2|infosec|security review|data residency|dpa)\b", lower):
        return "ciso_persona"

    # 5. Silence
    if ctx.days_since_decision_maker_touch is not None and ctx.days_since_decision_maker_touch > 10:
        return "silent_buyer"

    # 6. Weak MEDDPICC defaults to CRO challenger
    return "default_cro_challenger"


def _explain(red_persona: str, ctx: DealContext) -> str:
    """One-line reason why this persona fired."""
    explanations = {
        "claude_ae": "Claude mentioned in Gong calls",
        "openai_microsoft_ae": "ChatGPT/Copilot mentioned in Gong calls",
        "hebbia_ae": "Hebbia or BlueFlame in head-to-head",
        "alphasense_ae": "AlphaSense in evaluation",
        "internal_build_advocate": "Internal build signal in conversations",
        "cfo_procurement": "Pricing friction surfaced",
        "ciso_persona": "Security/compliance review came up",
        "silent_buyer": f"Decision maker silent {ctx.days_since_decision_maker_touch} days",
        "default_cro_challenger": "Default skeptical review",
    }
    return explanations.get(red_persona, "Default routing")
