"""from_file (payload-contract.md §4): every parser, the DOCTYPE refusal, workspace-only paths and
the 5 MB cap, then the whole path through the widget tool."""
from __future__ import annotations

import json
import os

import pytest

from harness import WORKSPACE, call, plugin_module, session

JUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites time="132.5">
  <testsuite name="SyncTests" tests="12" failures="0" time="40.2">
    <testcase classname="SyncTests" name="testReconnect" time="1.0"/>
  </testsuite>
  <testsuite name="SnapshotTests" tests="3" failures="2" skipped="0" time="92.3">
    <testcase classname="SnapshotTests" name="testDarkContrastPaywall"><failure message="Snapshot differs by 3.1%">diff</failure></testcase>
    <testcase classname="SnapshotTests" name="testListEmpty"><failure message="Missing empty text"/></testcase>
    <testcase classname="SnapshotTests" name="testLight"/>
  </testsuite>
</testsuites>
"""

LCOV = """TN:
SF:Sources/Sync/Reconnect.swift
DA:1,1
DA:2,0
LF:10
LH:8
end_of_record
SF:Sources/Sync/Backoff.swift
LF:10
LH:5
end_of_record
"""

COBERTURA = """<?xml version="1.0"?>
<coverage line-rate="0.75" lines-valid="40" lines-covered="30" version="7.4">
  <packages><package name="app"><classes>
    <class name="a.py" filename="app/a.py"><lines><line number="1" hits="1"/><line number="2" hits="0"/></lines></class>
  </classes></package></packages>
</coverage>
"""

COVERAGE_PY = {"meta": {"version": "7.4"}, "totals": {"covered_lines": 90, "num_statements": 120, "percent_covered": 75.0},
               "files": {"app/core.py": {"summary": {"covered_lines": 80, "num_statements": 90}},
                         "app/cli.py": {"summary": {"covered_lines": 10, "num_statements": 30}}}}

CSV = "date,installs,revenue,note\n2026-10-12,120,240.5,launch\n2026-10-13,180,310,\n2026-10-14,,290,outage\n"

ICS = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:1
SUMMARY:Stand-up
DTSTART;TZID=America/New_York:20261012T090000
DTEND;TZID=America/New_York:20261012T093000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=12
LOCATION:Zoom
END:VEVENT
BEGIN:VEVENT
UID:2
SUMMARY:Dentist
DTSTART:20261016T150000Z
DTEND:20261016T160000Z
LOCATION:200 W 57th St
DESCRIPTION:Leave by 10:40
END:VEVENT
BEGIN:VEVENT
UID:3
SUMMARY:Mom's birthday
DTSTART;VALUE=DATE:20261016
DTEND;VALUE=DATE:20261017
END:VEVENT
BEGIN:VEVENT
UID:4
SUMMARY:Next week
DTSTART:20261023T090000Z
END:VEVENT
END:VCALENDAR
"""

SARIF = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "swiftlint", "rules": [{"id": "force_unwrap",
                                                                                              "defaultConfiguration": {"level": "warning"}}]}},
                                         "results": [
    {"ruleId": "force_unwrap", "message": {"text": "Force unwrapping should be avoided"},
     "locations": [{"physicalLocation": {"artifactLocation": {"uri": "Sources/Sync.swift"}, "region": {"startLine": 42}}}]},
    {"ruleId": "sql_injection", "level": "error", "message": {"text": "Query built from user input"},
     "locations": [{"physicalLocation": {"artifactLocation": {"uri": "Sources/DB.swift"}, "region": {"startLine": 7}}}]},
    {"ruleId": "todo", "level": "note", "message": {"text": "TODO left in code"}}]}]}

GH_RUN = {"displayTitle": "CI", "status": "completed", "conclusion": "failure", "jobs": [
    {"name": "Build", "status": "completed", "conclusion": "success", "startedAt": "2026-10-16T10:00:00Z",
     "completedAt": "2026-10-16T10:00:48Z", "steps": [{"name": "Compile", "conclusion": "success"}]},
    {"name": "Test", "status": "completed", "conclusion": "failure", "startedAt": "2026-10-16T10:00:50Z",
     "completedAt": "2026-10-16T10:03:00Z", "steps": [{"name": "Set up", "conclusion": "success"},
                                                     {"name": "Run tests", "conclusion": "failure"}]},
    {"name": "Deploy", "status": "completed", "conclusion": "skipped", "steps": []}]}

GH_CHECKS = [{"name": "lint", "state": "SUCCESS", "bucket": "pass", "startedAt": "2026-10-16T10:00:00Z",
              "completedAt": "2026-10-16T10:00:20Z"},
             {"name": "tests", "state": "IN_PROGRESS", "bucket": "pending", "startedAt": "2026-10-16T10:00:00Z"}]


@pytest.fixture
def p(hermes):
    return plugin_module("parsers")


def write(name: str, content) -> str:
    path = WORKSPACE / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if isinstance(content, str) else json.dumps(content))
    return name


def parse(p, name, content, wtype, **options):
    write(name, content)
    path = p.resolve_path(name, WORKSPACE)
    return p.parse(path, {"path": name, **options}, wtype, options.pop("agent", None))


def test_junit_fills_steps_failed_first(p):
    fields, _ = parse(p, "junit.xml", JUNIT, "steps", parser="junit")
    assert [s["title"] for s in fields["steps"]] == ["SnapshotTests", "SyncTests"]
    assert fields["steps"][0]["state"] == "failed" and fields["steps"][0]["detail"] == "1 passed, 2 failed"
    assert fields["steps"][1]["duration"] == 40.2
    assert fields["result"] == {"state": "critical", "text": "2 of 15 tests failed"}


def test_junit_fills_metric_and_code(p):
    fields, _ = parse(p, "junit.xml", JUNIT, "metric", parser="junit")
    values = {i["id"]: i["value"]["value"] for i in fields["items"]}
    assert values == {"passed": 13, "failed": 2, "skipped": 0, "duration": 132.5}
    fields, _ = parse(p, "junit.xml", JUNIT, "code", parser="junit")
    assert fields["kind"] == "log" and fields["counts"] == {"error": 2}
    assert fields["lines"][0] == {"level": "error", "source": "SnapshotTests.testDarkContrastPaywall",
                                  "text": "Snapshot differs by 3.1%"}


def test_xml_with_a_doctype_is_refused(p):
    bomb = '<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">]><testsuite name="x">&lol;</testsuite>'
    with pytest.raises(p.ParseError, match="DOCTYPE"):
        parse(p, "bomb.xml", bomb, "steps", parser="junit")
    with pytest.raises(p.ParseError, match="DOCTYPE"):
        parse(p, "cov.xml", COBERTURA.replace("<coverage", '<!DOCTYPE coverage SYSTEM "x.dtd"><coverage'), "meter",
              parser="coverage")


def test_coverage_lcov_cobertura_and_coverage_py(p):
    fields, _ = parse(p, "lcov.info", LCOV, "meter", parser="coverage")
    item = fields["items"][0]
    assert item["value"] == {"value": 0.65, "format": "percent", "precision": 1} and item["max"] == 1
    fields, _ = parse(p, "cobertura.xml", COBERTURA, "meter", parser="coverage")
    assert fields["items"][0]["value"]["value"] == 0.75
    fields, _ = parse(p, "coverage.json", COVERAGE_PY, "table", parser="coverage")
    assert [r["file"] for r in fields["rows"]] == ["app/cli.py", "app/core.py"]  # least covered first
    assert fields["total"]["coverage"] == 0.75
    with pytest.raises(p.ParseError, match="fills meter or table"):
        parse(p, "lcov.info", LCOV, "list", parser="coverage")


def test_csv_table_chart_and_list(p):
    fields, _ = parse(p, "data.csv", CSV, "table", parser="csv", columns=["date", "installs", "revenue"])
    assert [c["key"] for c in fields["columns"]] == ["date", "installs", "revenue"]
    assert [c["format"] for c in fields["columns"]] == ["text", "integer", "number"]
    assert fields["rows"][2] == {"date": "2026-10-14", "installs": None, "revenue": 290}
    fields, _ = parse(p, "data.csv", CSV, "chart", parser="csv", columns=["date", "installs"])
    assert fields["x"] == {"kind": "date", "values": ["2026-10-12", "2026-10-13", "2026-10-14"]}
    assert fields["series"][0]["values"] == [120, 180, None]  # a gap, never 0
    fields, _ = parse(p, "data.csv", CSV, "list", parser="csv", columns=["note", "date", "revenue"])
    assert fields["items"][0] == {"title": "launch", "subtitle": "2026-10-12", "value": {"value": 240.5}}
    with pytest.raises(p.ParseError, match="did you mean 'revenue'"):
        parse(p, "data.csv", CSV, "table", parser="csv", columns=["revenu"])


def test_tsv_flashcards_and_jsonl_table(p):
    fields, _ = parse(p, "deck.tsv", "front\tback\nreceipt\trecibo\nbag\tbolsa\n", "flashcard", parser="tsv")
    assert fields["cards"][0]["front"] == "receipt" and fields["progress"] == {"done": 0, "total": 2}
    rows = "\n".join(json.dumps(r) for r in [{"app": "Trailhead", "installs": 1204}, {"app": "Pantry", "installs": 64}])
    fields, _ = parse(p, "apps.jsonl", rows, "table", parser="jsonl")
    assert fields["rows"] == [{"app": "Trailhead", "installs": 1204}, {"app": "Pantry", "installs": 64}]


def test_json_pointers_fill_fields_but_never_actions(p):
    report = {"summary": {"title": "Disk"}, "readings": [{"label": "Disk", "value": {"value": 0.88, "format": "percent"}}]}
    fields, _ = parse(p, "report.json", report, "metric", parser="json", map={"items": "/readings"})
    assert fields == {"items": report["readings"]}
    sneaky = {"rows": [{"label": "x", "actions": [{"id": "pay", "label": "Pay"}]}]}
    with pytest.raises(p.ParseError, match="can't set items\\[0\\].actions"):
        parse(p, "sneaky.json", sneaky, "list", parser="json", map={"items": "/rows"})
    with pytest.raises(p.ParseError, match="no key 'missing'"):
        parse(p, "report.json", report, "metric", parser="json", map={"items": "/missing"})


def test_log_levels_counts_repeats_and_json_records(p):
    log = "\n".join([
        "2026-10-16T14:02:10+02:00 INFO starting",
        "2026-10-16T14:02:14+02:00 ERROR 5xx on /api/checkout",
        "2026-10-16T14:02:15+02:00 ERROR 5xx on /api/checkout",
        "  at Checkout.swift:42",
        "2026-10-16T14:03:00+02:00 WARN queue at 1.2k",
        "2026-10-16T14:04:00+02:00 DEBUG noise"])
    fields, _ = parse(p, "app.log", log, "code", parser="log", level="warning")
    assert fields["counts"] == {"error": 2, "warning": 1}
    assert [line["level"] for line in fields["lines"]] == ["error", "error", "warning"]
    assert fields["lines"][1]["text"].endswith("⏎ at Checkout.swift:42")
    records = "\n".join(json.dumps(r) for r in [
        {"time": "2026-10-16T12:00:00Z", "level": "error", "msg": "boom"},
        {"time": "2026-10-16T12:00:01Z", "level": "error", "msg": "boom"},
        {"time": "2026-10-16T11:00:00Z", "level": "info", "msg": "old"}])
    fields, _ = parse(p, "app.jsonl", records, "code", parser="log", since="2026-10-16T11:30:00Z")
    assert fields["lines"] == [{"level": "error", "text": "boom", "at": "2026-10-16T12:00:00+00:00", "repeat": 2}]


def test_ics_fills_one_day_with_recurrences(p):
    fields, _ = parse(p, "cal.ics", ICS, "agenda", parser="ics", agent={"date": "2026-10-16"})
    titles = [e["title"] for e in fields["events"]]
    assert titles == ["Mom's birthday", "Stand-up", "Dentist"]  # all-day first, then by time
    standup = fields["events"][1]
    assert standup["start"] == "2026-10-16T09:00:00-04:00" and standup["place"] == {"name": "Zoom"}
    assert fields["events"][0] == {"id": "mom-s-birthday", "title": "Mom's birthday", "all_day": True, "start": "2026-10-16"}
    assert "date" not in fields  # the agent chose the day
    fields, _ = parse(p, "cal.ics", ICS, "agenda", parser="ics", agent={"date": "2026-10-19", "view": "days", "span": 7})
    assert sum(1 for e in fields["events"] if e["title"] == "Stand-up") == 3  # Mon, Wed, Fri
    assert any(e["title"] == "Next week" for e in fields["events"])


def test_sarif_lists_findings_worst_first(p):
    fields, _ = parse(p, "lint.sarif", SARIF, "list", parser="sarif")
    first = fields["items"][0]
    assert first["title"] == "Query built from user input" and first["tags"] == [{"label": "Error", "state": "critical"}]
    assert first["subtitle"] == "Sources/DB.swift:7 · sql_injection" and first["url"] == "hermes-file:Sources/DB.swift#L7"
    assert fields["items"][1]["tags"][0]["label"] == "Warning"  # from the rule's default level
    assert fields["counts"] == [{"label": "errors", "value": 1, "state": "critical"},
                                {"label": "warnings", "value": 1, "state": "warning"},
                                {"label": "notes", "value": 1, "state": "info"}]


def test_gh_run_and_pr_checks(p):
    fields, _ = parse(p, "run.json", GH_RUN, "steps", parser="gh-run")
    assert fields["kind"] == "pipeline"
    assert [(s["title"], s["state"]) for s in fields["steps"]] == [("Build", "done"), ("Test", "failed"), ("Deploy", "skipped")]
    assert fields["steps"][1]["detail"] == "Failed at “Run tests”" and fields["steps"][1]["duration"] == 130.0
    assert fields["result"]["state"] == "critical"
    fields, _ = parse(p, "checks.json", GH_CHECKS, "steps", parser="gh-run")
    assert [s["state"] for s in fields["steps"]] == ["done", "waiting"] and "result" not in fields


def test_paths_stay_inside_the_workspace(p, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("x")
    for raw in ("../secret.txt", str(outside), "/etc/hosts"):
        with pytest.raises(p.ParseError, match="outside the workspace|absolute"):
            p.resolve_path(raw, WORKSPACE)
    link = WORKSPACE / "link.txt"
    if link.exists() or link.is_symlink():
        link.unlink()
    os.symlink(outside, link)
    with pytest.raises(p.ParseError, match="outside the workspace"):
        p.resolve_path("link.txt", WORKSPACE)


def test_files_over_5_mb_are_not_read(p):
    big = WORKSPACE / "big.csv"
    with open(big, "wb") as handle:
        handle.truncate(5 * 1024 * 1024 + 1)
    with pytest.raises(p.ParseError, match="over 5 MB|5 MB aren't read"):
        p.parse(p.resolve_path("big.csv", WORKSPACE), {"path": "big.csv", "parser": "csv"}, "table")


def test_from_file_through_the_tool(widgets):
    write("ci/junit.xml", JUNIT)
    payload = {"type": "steps", "v": 1, "title": "CI · main", "from_file": {"path": "ci/junit.xml", "parser": "junit"}}
    with session(platform="api_server", session_id="sess-app", cwd=str(WORKSPACE)):
        result = call(widgets, {"op": "create", "payload": payload})
        assert "error" not in result, result
        stored = result["payload"]
        assert stored["source"] == {"name": "ci/junit.xml", "kind": "file", "url": "hermes-file:ci/junit.xml"}
        assert stored["as_of"]  # the file's modification time
        assert stored["steps"][0]["state"] == "failed"
        assert "SnapshotTests failed" in result["fallback_text"]
        conflict = call(widgets, {"op": "create", "payload": {**payload, "steps": [
            {"id": "x", "title": "Typed", "state": "done"}]}})
        assert "steps is filled from ci/junit.xml" in conflict["error"]
        outside = call(widgets, {"op": "create", "payload": {**payload, "from_file": {"path": "../x.xml", "parser": "junit"}}})
        assert "outside the workspace" in outside["error"]
