#!/usr/bin/env python3
"""Checks that refuse-cua-acting.py refuses cua-driver's acting calls in fleet roles only.

The hook runs as a subprocess with a throwaway HOME and a PATH that holds no cua-driver and no real
vstack, so nothing here runs cua-driver or touches the desktop.
Run: python3 -I .claude/hooks/test_refuse_cua_acting.py -v
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "refuse-cua-acting.py")

ACTING = [
    "click", "double_click", "right_click", "invoke_menu", "hotkey", "press_key", "type_text",
    "set_value", "scroll", "drag", "move_cursor", "bring_to_front", "run_steps", "run_script",
]
OTHER_REFUSED = ["replay_trajectory", "set_window_frame", "clipboard_write"]
READ_TOOLS = [
    "list_windows", "get_window_state", "get_accessibility_tree", "get_config", "get_guide",
    "zoom", "launch_app",
]

REFUSED_BASH = [
    ("cua-driver call click '{\"pid\":1}'", "click"),
    ("/usr/local/bin/cua-driver call press_key '{}'", "press_key"),
    ("echo '{}' | cua-driver call hotkey", "hotkey"),
    ("some-remote-run -- sh -c 'cua-driver call invoke_menu {}'", "invoke_menu"),
    ("cua-driver call \"$TOOL\" '{}'", "$TOOL"),
    ("cua-driver mcp", "mcp"),
    ("echo cua-driver call bring_to_front", "bring_to_front"),
    ("cua-driver permissions grant", "permissions grant"),
    # The CLI also runs a tool named directly, the form cua-driver's own docs use.
    ("cua-driver click '{}'", "click"),
    ("cua-driver invoke_menu '{}'", "invoke_menu"),
    ("cua-driver run_steps '{}'", "run_steps"),
    ("cua-driver start_session '{}'", "start_session"),
    ("cua-driver --json hotkey '{}'", "hotkey"),
    ("cua-driver \"$TOOL\" '{}'", "$TOOL"),
    ("cua-driver serve", "serve"),
    # The program from a substitution.
    ("$(which cua-driver) call click '{}'", "click"),
    ("\"$(command -v cua-driver)\" invoke_menu '{}'", "invoke_menu"),
    ("`which cua-driver` call drag '{}'", "drag"),
    # Refused by default: a lowercase word after cua-driver could be a tool, even in prose.
    ("git commit -m 'refuse cua-driver calls'", "calls"),
]
PASSING_BASH = [
    "cua-driver call list_windows '{}'",
    "cua-driver list-tools",
    "cua-driver get_window_state '{}'",
    "cua-driver describe click",
    "cua-driver permissions status",
    "cua-driver --version",
    "cua-driver -h",
    "git status",
    "echo hello",
    # A word that cannot name a tool (a path) passes.
    "grep -rn cua-driver .",
]


def mcp_event(tool, server="cua-driver"):
    return {"tool_name": "mcp__" + server + "__" + tool, "tool_input": {}}


def bash_event(command):
    return {"tool_name": "Bash", "tool_input": {"command": command}}


def all_refused_events():
    events = [mcp_event(tool) for tool in ACTING + OTHER_REFUSED]
    events.append({"tool_name": "mcp__plugin_cua-driver_cua-driver__click", "tool_input": {}})
    events.extend(bash_event(command) for command, _ in REFUSED_BASH)
    return events


class HookTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.mkdtemp()
        self.home = os.path.join(self.temp, "home")
        self.bin = os.path.join(self.temp, "bin")
        os.mkdir(self.home)
        os.mkdir(self.bin)

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def fake_vstack(self, body, directory=None):
        path = os.path.join(directory or self.bin, "vstack")
        with open(path, "w") as script:
            script.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, 0o755)
        return path

    def run_hook(self, stdin, role=None, timeout=20):
        env = {"HOME": self.home, "PATH": self.bin + ":/usr/bin:/bin"}
        if role is not None:
            env["VSTACK_FLEET_ROLE"] = role
        if not isinstance(stdin, str):
            stdin = json.dumps(stdin)
        return subprocess.run(
            [sys.executable, "-I", HOOK], input=stdin.encode(), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def assert_refused(self, result, tool):
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout.decode())
        specific = output["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")
        reason = specific["permissionDecisionReason"]
        self.assertIn("Refused cua-driver " + tool + ":", reason)
        self.assertIn("launch flags", reason)
        self.assertIn("lsappinfo front", reason)

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")


class FleetRoleTests(HookTestCase):
    def test_acting_tools_are_refused(self):
        for tool in ACTING:
            with self.subTest(tool=tool):
                self.assert_refused(self.run_hook(mcp_event(tool), role="crew"), tool)

    def test_plugin_server_form_is_refused(self):
        event = {"tool_name": "mcp__plugin_cua-driver_cua-driver__click", "tool_input": {}}
        self.assert_refused(self.run_hook(event, role="crew"), "click")

    def test_other_tools_outside_the_allow_list_are_refused(self):
        for tool in OTHER_REFUSED:
            with self.subTest(tool=tool):
                self.assert_refused(self.run_hook(mcp_event(tool), role="crew"), tool)

    def test_read_tools_and_launch_pass(self):
        for tool in READ_TOOLS:
            with self.subTest(tool=tool):
                self.assert_passes(self.run_hook(mcp_event(tool), role="crew"))

    def test_acting_bash_forms_are_refused(self):
        for command, tool in REFUSED_BASH:
            with self.subTest(command=command):
                self.assert_refused(self.run_hook(bash_event(command), role="crew"), tool)

    def test_reading_bash_forms_pass(self):
        for command in PASSING_BASH:
            with self.subTest(command=command):
                self.assert_passes(self.run_hook(bash_event(command), role="crew"))

    def test_monitor_commands_are_checked(self):
        event = {"tool_name": "Monitor", "tool_input": {"command": "cua-driver click '{}'"}}
        self.assert_refused(self.run_hook(event, role="crew"), "click")
        event = {"tool_name": "Monitor", "tool_input": {"command": "tail -f build.log"}}
        self.assert_passes(self.run_hook(event, role="crew"))

    def test_every_fleet_role_refuses(self):
        for role in ["admiral", "captain", "reviewer", "scout"]:
            with self.subTest(role=role):
                self.assert_refused(self.run_hook(mcp_event("click"), role=role), "click")


class NoRoleTests(HookTestCase):
    def test_everything_passes_without_a_fleet_role(self):
        for event in all_refused_events():
            with self.subTest(event=event):
                self.assert_passes(self.run_hook(event, role="none"))

    def test_an_unknown_role_passes(self):
        self.assert_passes(self.run_hook(mcp_event("click"), role="person"))


class VstackLookupTests(HookTestCase):
    def test_vstack_saying_crew_refuses(self):
        self.fake_vstack("echo crew")
        self.assert_refused(self.run_hook(mcp_event("click")), "click")

    def test_vstack_saying_none_passes(self):
        self.fake_vstack("echo none")
        self.assert_passes(self.run_hook(mcp_event("click")))

    def test_no_vstack_anywhere_passes(self):
        self.assert_passes(self.run_hook(mcp_event("click")))

    def test_vstack_under_home_plugin_cache_is_found(self):
        directory = os.path.join(self.home, ".claude", "plugins", "cache", "vstack", "vstack", "1.0.0", "bin")
        os.makedirs(directory)
        self.fake_vstack("echo crew", directory)
        self.assert_refused(self.run_hook(mcp_event("click")), "click")

    def test_vstack_failing_passes(self):
        self.fake_vstack("echo crew; exit 3")
        self.assert_passes(self.run_hook(mcp_event("click")))

    def test_vstack_that_hangs_passes_within_the_timeout(self):
        self.fake_vstack("sleep 30; echo crew")
        started = time.monotonic()
        result = self.run_hook(mcp_event("click"))
        elapsed = time.monotonic() - started
        self.assert_passes(result)
        self.assertLess(elapsed, 7.0)

    def test_other_tools_never_run_vstack(self):
        marker = os.path.join(self.temp, "vstack-ran")
        self.fake_vstack("touch '" + marker + "'; echo crew")
        for event in [
            {"tool_name": "Read", "tool_input": {"file_path": "/dev/null"}},
            mcp_event("click", server="other"),
            bash_event("git status"),
        ]:
            with self.subTest(event=event):
                self.assert_passes(self.run_hook(event))
                self.assertFalse(os.path.exists(marker))
        # The same fake vstack does run, and refuses, for a cua-driver acting call.
        self.assert_refused(self.run_hook(mcp_event("click")), "click")
        self.assertTrue(os.path.exists(marker))


class BadInputTests(HookTestCase):
    def test_bad_stdin_passes(self):
        for stdin in ["not json", "", "[1, 2]", "{\"tool_name\": 7}", "{\"tool_name\": \"Bash\"}"]:
            with self.subTest(stdin=stdin):
                self.assert_passes(self.run_hook(stdin, role="crew"))


if __name__ == "__main__":
    unittest.main()
