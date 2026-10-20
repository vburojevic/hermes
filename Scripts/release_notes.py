#!/usr/bin/env python3
"""Release notes from commit subjects (docs/releasing.md §Public release).

    python3 -I Scripts/release_notes.py notes <version> <build> <tag> [<previous tag>]
        prints the GitHub release notes for the commits since <previous tag>
    python3 -I Scripts/release_notes.py changelog <version> <build> [<previous tag>]
        adds the same changes to CHANGELOG.md, as the newest build under the version's heading

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


def changes(previous_tag):
    """(area, text) for each commit since previous_tag (the whole history when there's none)."""
    rev = f"{previous_tag}..HEAD" if previous_tag else "HEAD"
    log = subprocess.run(["git", "log", "--reverse", "--no-merges", "--format=%s", rev],
                         check=True, capture_output=True, text=True).stdout
    rows = []
    for subject in log.splitlines():
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


def changelog(version, build, previous_tag, path="CHANGELOG.md"):
    """Insert this build's changes right under the version's heading (and its highlights)."""
    text = open(path, encoding="utf-8").read()
    heading = f"## {version} beta"
    if heading not in text:
        raise SystemExit(f"{path} has no '{heading}' section")
    if f"### Build {build}" in text:
        return  # a rerun (--mac-only) adds nothing twice
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
    elif command == "changelog":
        version, build = args[:2]
        changelog(version, build, args[2] if len(args) > 2 else "")
    else:
        raise SystemExit(__doc__)
