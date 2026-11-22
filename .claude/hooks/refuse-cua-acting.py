#!/usr/bin/env python3
"""Refuses cua-driver calls that act on the desktop, in fleet sessions only.

cua-driver's acting tools can fall back to the foreground on their own and bring an app in front
of the person's work, and cua-driver has no setting that fails closed, so this repository refuses
them itself. The person's own sessions (no fleet role) pass through untouched.
"""

import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys

# Tools that only read, plus launch_app. Every other cua-driver tool is refused in a fleet role,
# including any tool a newer cua-driver adds.
ALLOW = frozenset([
    "list_windows", "get_window_state", "get_accessibility_tree", "get_config", "get_guide",
    "launch_app", "zoom", "screenshot", "get_desktop_state", "get_screen_size",
    "get_cursor_position", "list_apps", "check_permissions", "health_report", "verify_state",
])

# The acting tools the refusal names. They are refused because they are not in ALLOW.
ACTING = (
    "click", "double_click", "right_click", "invoke_menu", "hotkey", "press_key", "type_text",
    "set_value", "scroll", "drag", "move_cursor", "bring_to_front", "run_steps", "run_script",
)

FLEET_ROLES = frozenset(["admiral", "captain", "crew", "reviewer", "scout"])

ROLE_TIMEOUT_SECONDS = 5

MCP_TOOL = re.compile(r"^mcp__.*cua-driver.*__(.+)$")

# A cua-driver word on its own or at the end of a path, optionally quoted.
CUA_WORD = re.compile(r"(?:^|(?<=[\s'\"`/;|&(){}=]))cua-driver(?=$|[\s'\"`;|&()])")

# Shell words after cua-driver: separators end the command, quoted strings are one word.
SHELL_TOKEN = re.compile(r"""[;&|\n(){}`]|'[^']*'|"[^"]*"|\$\([^)]*\)|[^\s'";&|(){}`]+""")
SEPARATORS = frozenset([";", "&", "|", "\n", "(", ")", "{", "}", "`"])
PLAIN_TOOL = re.compile(r"^[A-Za-z0-9_]+$")

# The CLI also runs a tool named directly (`cua-driver click '{...}'`), so any other subcommand
# is read as a tool and refused unless it is in ALLOW or only reports on the driver.
CLI_READS = frozenset(["list-tools", "describe", "manifest", "status", "doctor", "check-update", "help"])
PERMISSION_READS = frozenset(["", "status"])
# A word that could name a subcommand or tool. Paths, file names and JSON cannot.
COMMAND_SHAPED = re.compile(r"^[a-z][a-z0-9_-]*$")


def names_command(word):
    """Whether a word after cua-driver names a subcommand or tool rather than a flag's value."""
    return bool(COMMAND_SHAPED.match(word)) or word[:1] in ("$", "`")


def message(tool):
    return (
        "Refused cua-driver " + tool + ": in fleet sessions cua-driver is read-only on the "
        "desktop. Its acting tools (" + ", ".join(ACTING) + " and anything else that acts) can "
        "fall back to the foreground and bring an app in front of the person's work. Allowed "
        "route: drive the app under test with its own launch flags first; when an in-window "
        "action is unavoidable, use a background accessibility script on your own app's pid only "
        "(for example AXSelectedTextRange, or AXPress on an in-window button), never menu bar "
        "items, keystrokes, the Dock or opens that activate an app; run `lsappinfo front` before "
        "and after every acting step, the launch included. If your app is frontmost or an action "
        "is refused, stop, quit only your own processes and report. A step that cannot be done "
        "this way is reported as not verified."
    )


def unquote(word):
    if len(word) >= 2 and word[0] == word[-1] and word[0] in "'\"":
        return word[1:-1]
    return word


def words_after(command, start):
    """The shell words of one command, up to the first separator."""
    words = []
    for token in SHELL_TOKEN.findall(command, start):
        if token in SEPARATORS:
            break
        words.append(unquote(token))
    return words


def refused_invocation(words):
    """What a cua-driver invocation would run that acts, or None when it only reads."""
    i = 0
    # Global flags and their values before the subcommand.
    while i < len(words) and words[i].startswith("-"):
        if "=" in words[i] or i + 1 >= len(words):
            i += 1
        elif words[i + 1].startswith("-") or names_command(words[i + 1]):
            i += 1
        else:
            i += 2
    if i >= len(words):
        return None
    sub = words[i]
    rest = words[i + 1:]
    if sub == "permissions":
        action = next((w for w in rest if not w.startswith("-")), "")
        return None if action in PERMISSION_READS else "permissions " + action
    if sub != "call":
        # A tool or subcommand named directly, refused by default (mcp and serve included). A
        # word that cannot name one (a path, a file name) passes.
        if sub in CLI_READS or sub in ALLOW or not names_command(sub):
            return None
        return sub
    # Flags after call never take the tool word as their value, so a flag's value is read as the
    # tool and refused: a wrong guess refuses rather than lets an acting tool through.
    tool = next((w for w in rest if not w.startswith("-")), "")
    if not tool:
        return "call"
    if PLAIN_TOOL.match(tool) and tool in ALLOW:
        return None
    return tool


def refused_in_bash(command):
    """The first acting cua-driver call anywhere in a shell command, quotes and heredocs included."""
    for match in CUA_WORD.finditer(command):
        start = match.end()
        # Step over what closes a quoted path or a substitution that yields the program, as in
        # "$(which cua-driver)" call click, so it neither opens a string nor ends the command.
        while command[start:start + 1] in ("'", '"', ")", "`"):
            start += 1
        refused = refused_invocation(words_after(command, start))
        if refused is not None:
            return refused
    return None


def refused_tool(event):
    tool_name = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool_name, str):
        return None
    match = MCP_TOOL.match(tool_name)
    if match:
        tool = tool_name.rsplit("__", 1)[1]
        return None if tool in ALLOW else tool
    # Monitor runs a shell command too.
    if tool_name in ("Bash", "Monitor") and isinstance(tool_input, dict):
        command = tool_input.get("command")
        if isinstance(command, str) and "cua-driver" in command:
            return refused_in_bash(command)
    return None


def find_vstack():
    found = shutil.which("vstack")
    if found:
        return found
    home = os.environ.get("HOME", "")
    if not home:
        return None
    pattern = os.path.join(home, ".claude", "plugins", "cache", "vstack", "vstack", "*", "bin", "vstack")
    candidates = [path for path in glob.glob(pattern) if os.access(path, os.X_OK)]
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def fleet_role():
    role = os.environ.get("VSTACK_FLEET_ROLE", "").strip().lower()
    if role:
        return role
    try:
        vstack = find_vstack()
        if not vstack:
            return "none"
        process = subprocess.Popen(
            [vstack, "role"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=ROLE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            # The lookup runs in its own process group, so this stops only what this hook started.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return "none"
        if process.returncode != 0:
            return "none"
        return output.decode("utf-8", "replace").strip().lower() or "none"
    except Exception:
        return "none"


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(event, dict):
        return
    tool = refused_tool(event)
    if tool is None or fleet_role() not in FLEET_ROLES:
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message(tool),
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
