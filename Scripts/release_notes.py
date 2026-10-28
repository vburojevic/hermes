#!/usr/bin/env python3
"""Release notes from commit subjects (docs/releasing.md §Public release).

    python3 -I Scripts/release_notes.py notes <version> <build> <tag> [<previous tag>]
        prints the GitHub release notes for the commits since <previous tag>
    python3 -I Scripts/release_notes.py changelog <version> <build> [<previous tag>]
        adds the same changes to CHANGELOG.md, as the newest build under the version's heading
    python3 -I Scripts/release_notes.py testflight <version> <build> [<previous tag>]
        prints TestFlight's What to Test for the public beta: plain text, under 4,000 characters

Subjects read "Area: what changed for the person" (AGENTS.md), so they are the notes. Areas
that don't change the app for the person using it (docs, tests, mocks, release tooling) are left
out, and the rest are grouped by area.
"""

import datetime
import re
import subprocess
import sys

SOURCE_REPO = "vburojevic/hermes"
RELEASES_REPO = "vburojevic/hermes-releases"
TESTFLIGHT = "https://testflight.apple.com/join/CVhbq8Ur"
WEBSITE = "https://hermesapp.dev"
# Areas whose commits aren't release notes.
SKIP_AREAS = {
    "AGENTS", "Build", "CI", "Changelog", "Contributing", "Debug", "Design", "Docs", "docs", "Mock",
    "Mocks", "README", "Release", "Repo", "Scripts", "Tests",
}
SUBJECT = re.compile(r"([^:]{1,40}):\s*(.+)")
# A subject that reached main in the wrong words, corrected here instead of rewriting public
# history: one "<commit> <subject>" per line, the commit as a full or short hash.
CORRECTIONS = "Scripts/release-note-corrections.txt"


def corrections():
    try:
        with open(CORRECTIONS, encoding="utf-8") as file:
            lines = [line.strip() for line in file]
    except FileNotFoundError:
        return {}
    pairs = (line.split(maxsplit=1) for line in lines if line and not line.startswith("#"))
    return {sha: subject for sha, subject in pairs}


def changes(previous_tag):
    """(area, text) for each commit since previous_tag (the whole history when there's none)."""
    rev = f"{previous_tag}..HEAD" if previous_tag else "HEAD"
    log = subprocess.run(["git", "log", "--reverse", "--no-merges", "--format=%H %s", rev],
                         check=True, capture_output=True, text=True).stdout
    fixed = corrections()
    rows = []
    for line in log.splitlines():
        sha, _, subject = line.partition(" ")
        subject = next((text for prefix, text in fixed.items() if sha.startswith(prefix)), subject)
        match = SUBJECT.match(subject)
        if not match:
            continue  # the first public commit ("Hermes 1.0 beta") and anything without an area
        area, text = match.groups()
        if area not in SKIP_AREAS:
            rows.append((area, text))
    return rows


def grouped(rows):
    order, by_area = [], {}
    for area, text in rows:
        if area not in by_area:
            order.append(area)
            by_area[area] = []
        by_area[area].append(text)
    return [f"- **{area}:** {text}" for area in order for text in by_area[area]]


def notes(version, build, tag, previous_tag):
    dmg = f"https://github.com/{RELEASES_REPO}/releases/download/{tag}/Hermes-{version}-{build}.dmg"
    lines = [
        f"Hermes {version} beta, build {build}. Hermes is in public beta: expect rough edges, and "
        f"please [report bugs](https://github.com/{SOURCE_REPO}/issues/new?template=bug_report.yml).",
        "",
        f"**Get it:** [TestFlight]({TESTFLIGHT}) for iPhone and iPad · [Mac DMG]({dmg}) "
        f"(installed copies update themselves) · [hermesapp.dev]({WEBSITE})",
        "",
        "## What's new",
        "",
    ]
    rows = changes(previous_tag)
    lines += grouped(rows) if rows else ["- Fixes and polish."]
    if previous_tag:
        lines += ["", f"**Every commit:** https://github.com/{SOURCE_REPO}/compare/{previous_tag}...{tag}"]
    return "\n".join(lines) + "\n"


# App Store Connect refuses What to Test with emoji, pictographic symbols (dingbats such as ✓),
# variation selectors or private-use characters. A few read as words; the rest are dropped.
SYMBOL_WORDS = {"✓": "a check mark", "✔": "a check mark", "✗": "a cross", "✘": "a cross", "★": "a star"}
REFUSED = [(0x2600, 0x27BF), (0x2B00, 0x2BFF), (0xE000, 0xF8FF), (0xFE00, 0xFE0F), (0x1F000, 0x1FAFF)]


def plain_for_testflight(text):
    for symbol, words in SYMBOL_WORDS.items():
        text = text.replace(symbol, words)
    return "".join(c for c in text if not any(low <= ord(c) <= high for low, high in REFUSED))


def testflight(version, build, previous_tag, limit=4000):
    """What to Test: TestFlight shows plain text, so no Markdown, and caps it at 4,000 characters."""
    head = (f"Hermes {version} beta, build {build}. It's a beta: expect rough edges. Send feedback with a "
            f"screenshot from TestFlight, or report bugs at github.com/{SOURCE_REPO}/issues. Leave keys "
            f"and addresses out of both.")
    rows = changes(previous_tag)
    lines = [plain_for_testflight(f"- {area}: {text}") for area, text in rows] or ["- Fixes and polish."]
    tail = f"Every change: github.com/{SOURCE_REPO}/releases"
    kept = []
    for i, line in enumerate(lines):
        rest = len(lines) - i
        more = f"- …and {rest} more" if rest > 1 else ""
        if len("\n".join([head, "", "What's new:", *kept, line, more, "", tail])) > limit:
            kept.append(f"- …and {rest} more")
            break
        kept.append(line)
    return "\n".join([head, "", "What's new:", *kept, "", tail]) + "\n"


def changelog(version, build, previous_tag, path="CHANGELOG.md"):
    """Insert this build's changes right under the version's heading (and its highlights)."""
    text = open(path, encoding="utf-8").read()
    heading = f"## {version} beta"
    if heading not in text:
        raise SystemExit(f"{path} has no '{heading}' section")
    if f"### Build {build}" in text:
        return  # a rerun adds nothing twice
    day = datetime.datetime.strptime(build[:6], "%y%m%d").strftime("%B %-d, %Y")
    rows = changes(previous_tag)
    body = "\n".join(grouped(rows) if rows else ["- Fixes and polish."])
    section = f"### Build {build} ({day})\n\n{body}\n\n"
    # Newest build first: before the previous build's section, or before the private beta's.
    start = text.index(heading)
    nxt = [i for i in (text.find("\n### Build ", start), text.find("\n### Private beta", start)) if i != -1]
    at = min(nxt) + 1 if nxt else len(text)
    open(path, "w", encoding="utf-8").write(text[:at] + section + text[at:])


if __name__ == "__main__":
    command, args = sys.argv[1], sys.argv[2:]
    if command == "notes":
        version, build, tag = args[:3]
        sys.stdout.write(notes(version, build, tag, args[3] if len(args) > 3 else ""))
    elif command == "testflight":
        version, build = args[:2]
        sys.stdout.write(testflight(version, build, args[2] if len(args) > 2 else ""))
    elif command == "changelog":
        version, build = args[:2]
        changelog(version, build, args[2] if len(args) > 2 else "")
    else:
        raise SystemExit(__doc__)
