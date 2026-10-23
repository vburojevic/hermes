"""A long coding turn's file edits, for the combined mock (`docs/chat.md` §1, the Changes row): "many
edits" in a Bot Chat or a Bot Mode chat.

Shaped like Hermes Agent's own tools:
  - `write_file` returns `{bytes_written, dirs_created}`; its `tool.complete` carries an `inline_diff` of
    the file before and after (agent/display.py `_diff_from_snapshot`, `a/path` even for a new file).
  - `patch` returns PatchResult.to_dict(): `{success, diff, files_modified, files_created,
    files_deleted}` with difflib's diff, or `{success: false, error}`; in its V4A mode a deletion's diff
    goes to `/dev/null` (tools/patch_parser.py).
  - `inline_diff` is that diff as Hermes renders it for a terminal: a "┊ review diff" header, each file
    as "a/path → b/path", every line in ANSI colour, and no more than 80 lines or 6 files, with
    "… omitted N diff line(s)" after (`_summarize_rendered_diff_sections`).

The turn: a 100-line report script created, then patched four times; a helper patched twice; a new
note; an old script deleted; a patch that fails to match; two checks in between; the reply.
"""

import difflib
import json

ROOT = "/srv/projects/testflight-tools"
MAX_FILES = 6
MAX_LINES = 80

FILE = "\033[38;2;218;165;32m"
HUNK = "\033[38;2;139;134;130m"
PLUS = "\033[38;2;255;255;255;48;2;20;90;20m"
MINUS = "\033[38;2;255;255;255;48;2;120;20;20m"
DIM = "\033[38;2;150;150;150m"
RESET = "\033[0m"


def unified(path, before, after):
    """difflib's unified diff, as Hermes's tools make it (`after=None`: deleted)."""
    old = before.splitlines(keepends=True) if before else []
    new = after.splitlines(keepends=True) if after else []
    return "".join(difflib.unified_diff(old, new, fromfile=f"a/{path}", tofile="/dev/null" if after is None else f"b/{path}"))


def inline(diff):
    """`diff` as `tool.complete.inline_diff` carries it (agent/display.py)."""
    sections, current = [], []
    for line in diff.splitlines():
        if line.startswith("--- ") and current:
            sections.append(current)
            current = []
        current.append(line)
    if current:
        sections.append(current)
    rendered, omitted_lines, omitted_files = [], 0, 0
    for index, section in enumerate(sections):
        lines, old = [], None
        for raw in section:
            if raw.startswith("--- "):
                old = raw[4:].strip()
            elif raw.startswith("+++ "):
                lines.append(f"{FILE}{old or 'a/?'} → {raw[4:].strip()}{RESET}")
            else:
                colour = HUNK if raw.startswith("@@") else MINUS if raw.startswith("-") else PLUS if raw.startswith("+") else DIM
                lines.append(f"{colour}{raw}{RESET}")
        room = MAX_LINES - len(rendered)
        if index >= MAX_FILES or room <= 0:
            omitted_files += 1
            omitted_lines += len(lines)
        elif len(lines) <= room:
            rendered += lines
        else:
            rendered += lines[:room]
            omitted_lines += len(lines) - room
            omitted_files += 1
    if omitted_lines or omitted_files:
        summary = f"… omitted {omitted_lines} diff line(s)"
        if omitted_files:
            summary += f" across {omitted_files} additional file(s)/section(s)"
        rendered.append(f"{HUNK}{summary}{RESET}")
    return "\n".join(["  ┊ review diff"] + rendered)


def report_script():
    """A 100-line script, like the one in the person's screenshot."""
    lines = ['"""Fetch TestFlight crash reports and feedback for a build."""', "", "import json", "import os", "import sys", "",
             "API = \"https://api.appstoreconnect.apple.com/v1\"", "CRASH_LOGS_PER_RUN = 20", ""]
    for name in ("crashes", "feedback", "screenshots", "devices", "builds", "testers", "sessions", "groups"):
        lines += [f"def fetch_{name}(client, build):",
                  f"    \"\"\"Every {name[:-1]} record for `build`, newest first.\"\"\"",
                  f"    rows = client.get(f\"{{API}}/builds/{{build}}/{name}\")",
                  "    out = []",
                  "    for row in rows.get(\"data\", []):",
                  "        attrs = row.get(\"attributes\") or {}",
                  "        out.append({\"id\": row.get(\"id\"), \"kind\": \"" + name + "\", **attrs})",
                  "    return out",
                  "",
                  ""]
    lines += ["def main(argv):", "    build = argv[1] if len(argv) > 1 else os.environ.get(\"BUILD\")",
              "    rows, failures = [], 0", "    for fetch in (fetch_crashes, fetch_feedback):", "        rows += fetch(None, build)",
              "    print(json.dumps(rows, indent=2))", "    return 1 if failures else 0", "", "",
              "if __name__ == \"__main__\":", "    sys.exit(main(sys.argv))"]
    return "\n".join(lines) + "\n"


BUDGET = "\n".join(["\"\"\"How many crash logs a run may download.\"\"\"", "", "DEFAULT = 20", "", "",
                    "def budget(env):", "    value = env.get(\"CRASH_BUDGET\")", "    return int(value) if value else DEFAULT", ""]) + "\n"
OLD_REPORTS = "\n".join(["# Superseded by testflight_reports.py.", "import sys", "", "print(\"use testflight_reports.py\")",
                         "sys.exit(1)"]) + "\n"
NOTE = "\n".join(["# TestFlight reports", "", "`scripts/testflight_reports.py <build>` prints a build's crashes and feedback",
                  "as JSON. `CRASH_BUDGET` caps the crash logs it downloads (20 by default)."]) + "\n"


def many_edits(sid, stored, runtime, tool, stream, finish, emit):
    def write(path, before, after, seconds=1.2):
        full = f"{ROOT}/{path}"
        tool(sid, stored, "write_file", {"path": full, "content": after},
             json.dumps({"bytes_written": len(after.encode()), "dirs_created": False}), seconds, path,
             inline_diff=inline(unified(path, before, after)))

    def patch(path, before, old, new, seconds=0.8):
        full = f"{ROOT}/{path}"
        after = before.replace(old, new, 1)
        diff = unified(path, before, after)
        tool(sid, stored, "patch", {"path": full, "old_string": old, "new_string": new},
             json.dumps({"success": True, "diff": diff, "files_modified": [full]}), seconds, path, inline_diff=inline(diff))
        return after

    def check(command, output, code=0):
        tool(sid, stored, "terminal", {"command": command}, json.dumps({"output": output, "exit_code": code}), 1.5, command)

    emit(sid, "message.interim", {"text": "I'll write the report script first, then wire the crash budget into it.",
                                  "already_streamed": False})
    script = report_script()
    write("scripts/testflight_reports.py", None, script, seconds=2)
    if runtime["interrupt"]:
        return finish(sid, stored, "", status="interrupted")
    script = patch("scripts/testflight_reports.py", script, "import os\n", "import os\nimport re\n")
    script = patch("scripts/testflight_reports.py", script, "    rows, failures = [], 0\n",
                   "    rows, failures, blocked = [], 0, None\n    crash_budget = CRASH_LOGS_PER_RUN\n")
    check("python3 scripts/testflight_reports.py 2610231809", "Traceback (most recent call last):\nNameError: name 'points' is not defined", 1)
    script = patch("scripts/testflight_reports.py", script, "        attrs = row.get(\"attributes\") or {}\n        out.append({\"id\": row.get(\"id\"), \"kind\": \"crashes\", **attrs})",
                   "        attrs = row.get(\"attributes\") or {}\n        def points(key):\n            value = attrs.get(key)\n"
                   "            return value if type(value) is int else None\n        out.append({\"id\": row.get(\"id\"), \"kind\": \"crashes\", "
                   "\"screenWidth\": points(\"screenWidth\"), **attrs})")
    budget = patch("scripts/crash_budget.py", BUDGET, "DEFAULT = 20\n", "DEFAULT = 25\n")
    budget = patch("scripts/crash_budget.py", budget, "    return int(value) if value else DEFAULT\n",
                   "    try:\n        return max(0, int(value)) if value else DEFAULT\n    except ValueError:\n        return DEFAULT\n")
    # A patch whose old text isn't in the file: Hermes's own refusal, and nothing changes.
    tool(sid, stored, "patch", {"path": f"{ROOT}/scripts/crash_budget.py", "old_string": "DEFAULT = 20\n", "new_string": "DEFAULT = 30\n"},
         json.dumps({"success": False, "error": "Could not find a match for old_string in the file"}), 0.6, "scripts/crash_budget.py")
    script = patch("scripts/testflight_reports.py", script, "import json\n", "import json\nimport logging\n")
    write("docs/testflight.md", None, NOTE)
    # V4A: deleting the script the new one replaces.
    deletion = unified("scripts/old_reports.py", OLD_REPORTS, None)
    tool(sid, stored, "patch", {"mode": "patch", "patch": "*** Begin Patch\n*** Delete File: scripts/old_reports.py\n*** End Patch"},
         json.dumps({"success": True, "diff": deletion, "files_deleted": ["scripts/old_reports.py"]}), 0.6, "scripts/old_reports.py",
         inline_diff=inline(deletion))
    check("python3 scripts/testflight_reports.py 2610231809 | head -3", "[\n  {\n    \"id\": \"crash-1\",")
    if runtime["interrupt"]:
        return finish(sid, stored, "", status="interrupted")
    answer = ("Done. `scripts/testflight_reports.py` fetches a build's crashes and feedback, and the crash budget "
              "now comes from `CRASH_BUDGET` (25 by default, never negative). I removed `old_reports.py` and wrote a "
              "short note in `docs/testflight.md`. One edit to the budget didn't apply: the default had already changed.")
    stream(sid, answer)
    return finish(sid, stored, answer)
