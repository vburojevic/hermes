"""Shared fixtures: the plugin installed in a throwaway HERMES_HOME and loaded through Hermes's own
plugin manager. Nothing touches ~/.hermes.

    HERMES_SOURCE=~/.hermes/hermes-agent ~/.hermes/hermes-agent/.venv/bin/python -m pytest \
        Tools/hermes-app-widgets/tests --import-mode=importlib
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent")).expanduser()
HOME = Path(tempfile.mkdtemp(prefix="hermes-app-widgets-test-"))
WORKSPACE = HOME / "workspace"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
REAL_WIDGETS = Path.home() / ".hermes" / "widgets"


def _snapshot(folder: Path) -> dict[str, float]:
    return {str(p): p.stat().st_mtime for p in folder.rglob("*") if p.is_file()} if folder.exists() else {}


REAL_BEFORE = _snapshot(REAL_WIDGETS)
os.environ["HERMES_HOME"] = str(HOME)
os.environ.pop("TERMINAL_CWD", None)
sys.path.insert(0, str(SOURCE))


@pytest.fixture(scope="session")
def hermes():
    """Install into the throwaway home and load through the plugin manager; returns (plugins module, the
    plugin's package)."""
    target = HOME / "plugins" / "hermes-app-widgets"
    shutil.copytree(PLUGIN_DIR, target, ignore=shutil.ignore_patterns("tests", "__pycache__", "sync-spec.py"))
    # No lazy installs: a test must never reach the network.
    (HOME / "config.yaml").write_text("plugins:\n  enabled: [hermes-app-widgets]\nsecurity:\n  allow_lazy_installs: false\n")
    WORKSPACE.mkdir(exist_ok=True)
    from hermes_cli import plugins
    plugins.discover_plugins(force=True)
    assert plugins.get_plugin_command_handler("app-widgets") is not None, "the /app-widgets command wasn't registered"
    yield plugins, plugin_module("core")
    assert _snapshot(REAL_WIDGETS) == REAL_BEFORE, "the tests changed the real ~/.hermes/widgets"


def plugin_module(name: str):
    """A module of the plugin as Hermes loaded it (``hermes_plugins.hermes_app_widgets.<name>``)."""
    import importlib
    return importlib.import_module(f"hermes_plugins.hermes_app_widgets.{name}" if name else "hermes_plugins.hermes_app_widgets")


class Clock:
    def __init__(self):
        self.now = datetime(2026, 10, 16, 11, 12, 30, tzinfo=timezone(timedelta(hours=-4)))

    def __call__(self):
        return self.now

    def advance(self, **kwargs):
        self.now += timedelta(**kwargs)


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def widgets(hermes, clock, tmp_path):
    """A fresh Widgets with its own store and clock, through the loaded plugin's own modules."""
    core = plugin_module("core")
    store = plugin_module("store")
    instance = core.Widgets(store=store.Store(tmp_path / "widgets"), clock=clock, cron_execution=lambda: None)
    return instance


@contextmanager
def session(**values):
    """Bind HERMES_SESSION_* the way the gateway does for a turn."""
    from gateway.session_context import clear_session_vars, set_session_vars
    tokens = set_session_vars(**values)
    try:
        yield
    finally:
        clear_session_vars(tokens)


def call(widgets, args, session_id="sess-app"):
    return json.loads(widgets.handle(args, session_id=session_id))


def as_input(example: dict) -> dict:
    """An example payload as the agent sends it (gen.py's ``_as_input``, keeping fallback_text)."""
    core = plugin_module("core")
    return core._as_input(example)
