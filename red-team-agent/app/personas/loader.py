"""
Persona prompt loader. Reads markdown files from /personas/red and /personas/blue
and caches them per-process.
"""
from __future__ import annotations
from pathlib import Path
from functools import lru_cache

_BASE_DIR = Path(__file__).parent


@lru_cache(maxsize=1)
def _red_prompts() -> dict[str, str]:
    return _load_dir(_BASE_DIR / "red")


@lru_cache(maxsize=1)
def _blue_prompts() -> dict[str, str]:
    return _load_dir(_BASE_DIR / "blue")


def _load_dir(d: Path) -> dict[str, str]:
    out = {}
    if not d.exists():
        return out
    for f in d.glob("*.md"):
        out[f.stem] = f.read_text()
    return out


def build_red_system_prompt(persona_id: str) -> str:
    """Concatenate red_team_base.md + the persona-specific prompt."""
    prompts = _red_prompts()
    base = prompts.get("red_team_base", "")
    persona = prompts.get(persona_id, prompts.get("default_cro_challenger", ""))
    return base + "\n\n---\n\n# YOUR PERSONA\n\n" + persona


def build_blue_system_prompt(persona_id: str) -> str:
    """Concatenate blue_team_base.md + the persona-specific prompt."""
    prompts = _blue_prompts()
    base = prompts.get("blue_team_base", "")
    persona = prompts.get(persona_id, prompts.get("default_bull_case", ""))
    return base + "\n\n---\n\n# YOUR PERSONA\n\n" + persona
