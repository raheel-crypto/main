"""
Persona-selection + prompt-loading + Red/Blue routing.

Submodules:
  - selection.py: Red-only top-N persona picker (used by /evaluate).
  - loader.py:    .md prompt loader (used by arbiter's Round 2).
  - routing.py:   paired Red+Blue picker (used by /arbiter).
"""
from .selection import select_personas  # re-exported for backward compat

__all__ = ["select_personas"]
