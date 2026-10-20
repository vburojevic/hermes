"""What the plugin registers, as Hermes sees it: the tools and their toolset on both servers' tool
lists, the pinned result size, the skill, the command, and the spec copy the app bundles."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from harness import plugin_module

PLUGIN = Path(__file__).resolve().parents[1]
REPO = PLUGIN.parents[1]


def test_the_widgets_toolset_is_on_both_tool_lists(hermes):
    # API server: GET /v1/toolsets (gateway/platforms/api_server.py _handle_toolsets).
    from hermes_cli.config import load_config
    from hermes_cli.tools_config import _get_effective_configurable_toolsets, _get_platform_tools
    from toolsets import resolve_toolset
    names = [name for name, _label, _desc in _get_effective_configurable_toolsets()]
    assert "widgets" in names
    assert set(resolve_toolset("widgets")) == {"widget", "widget_examples"}
    assert "widgets" in _get_platform_tools(load_config(), "api_server", include_default_mcp_servers=False)
    # Backend socket: tools.list (tui_gateway/methods_tools.py _toolset_rows).
    import toolsets
    info = toolsets.get_toolset_info("widgets")
    assert info and set(info["resolved_tools"]) == {"widget", "widget_examples"}


def test_widget_results_are_never_spilled_to_a_file(hermes):
    from tools.budget_config import DEFAULT_BUDGET, budget_for_context_window
    assert DEFAULT_BUDGET.resolve_threshold("widget") == float("inf")
    assert budget_for_context_window(16_000).resolve_threshold("widget") == float("inf")  # a small model too


def test_the_skill_and_the_command(hermes):
    plugins, _core = hermes
    from hermes_cli.plugins import get_plugin_manager
    skills = get_plugin_manager()._plugin_skills
    assert "hermes-app-widgets:widgets" in skills
    assert "widget-or-prose" not in skills["hermes-app-widgets:widgets"]["description"]
    assert skills["hermes-app-widgets:widgets"]["description"].startswith("Show structured")
    handler = plugins.get_plugin_command_handler("app-widgets")
    status = json.loads(handler("status {}"))
    assert status["ok"] and status["version"] == plugin_module("core").VERSION and status["validator"] is True
    assert json.loads(handler("nope {}"))["ok"] is False
    assert json.loads(handler("get not-json"))["ok"] is False


def test_the_manifest_matches_the_code(hermes):
    import yaml
    manifest = yaml.safe_load((PLUGIN / "plugin.yaml").read_text())
    assert manifest["version"] == plugin_module("core").VERSION
    assert set(manifest["provides_tools"]) == {"widget", "widget_examples"}


def test_the_spec_is_the_one_the_app_bundles():
    """The plugin's spec/ and HermesKit's Widgets/Spec/ are copies of the same design-project
    output. When both exist, every shared file must be identical."""
    app = REPO / "Packages" / "HermesKit" / "Sources" / "HermesKit" / "Widgets" / "Spec"
    if not app.exists():
        pytest.skip("the app's widget spec isn't on this branch")
    mine = PLUGIN / "spec"
    shared = [p.relative_to(app) for p in app.rglob("*.json")]
    assert shared
    for relative in shared:
        assert (mine / relative).read_bytes() == (app / relative).read_bytes(), f"{relative} differs from the app's copy"


def test_registering_imports_nothing_heavy():
    """Hermes gives register() 10 s while a busy gateway reloads every profile: the plugin's import
    and register() load neither the engine nor the validator."""
    import subprocess
    import sys as _sys
    code = (
        "import sys, types, importlib.util\n"
        f"sys.path.insert(0, {str(PLUGIN.parent)!r})\n"
        f"spec = importlib.util.spec_from_file_location('w_light', {str(PLUGIN / '__init__.py')!r}, "
        f"submodule_search_locations=[{str(PLUGIN)!r}])\n"
        "m = importlib.util.module_from_spec(spec); sys.modules['w_light'] = m; spec.loader.exec_module(m)\n"
        "ctx = types.SimpleNamespace(register_tool=lambda *a, **k: None, register_system_prompt_section=lambda *a, **k: None,\n"
        "    register_skill=lambda *a, **k: None, register_hook=lambda *a, **k: None, register_command=lambda *a, **k: None)\n"
        "m.register(ctx)\n"
        "heavy = [n for n in sys.modules if n.startswith('w_light.') or n.split('.')[0] in ('jsonschema', 'referencing')]\n"
        "print(heavy)\n")
    out = subprocess.run([_sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "[]", out.stdout
