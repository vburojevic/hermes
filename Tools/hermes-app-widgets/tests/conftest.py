"""Fixtures live in harness.py (importable from the tests: pytest's importlib mode doesn't put this
folder on sys.path, so it's added here)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import clock, hermes, widgets  # noqa: E402,F401
