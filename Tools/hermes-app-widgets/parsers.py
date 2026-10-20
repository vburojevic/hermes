"""Data from files (payload-contract.md §4): numbers a tool already wrote are read, not retyped.

Each parser takes the file's text, the ``from_file`` options and the widget type, and returns the
fields it fills. The caller merges them into the agent's payload (fields filled from the file win; a
field both set is an error) and sets ``source`` and ``as_of``. A parser only ever fills data: file
content can't set actions, sensitivity, producer or resolution (``FORBIDDEN_KEYS``).
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

MAX_BYTES = 5 * 1024 * 1024
FORBIDDEN_KEYS = frozenset({"actions", "action", "sensitivity", "producer", "resolution", "for"})
PARSERS = ("junit", "coverage", "csv", "tsv", "jsonl", "json", "log", "ics", "sarif", "gh-run")


class ParseError(ValueError):
    """A file the agent pointed at can't fill the widget; the message says why and what to do."""


# ---- reading


def resolve_path(raw: str, workspace: str | Path) -> Path:
    """A workspace-relative path, resolved inside the workspace (symlinks included) or refused."""
    if not isinstance(raw, str) or not raw.strip():
        raise ParseError("from_file.path is empty")
    if "\x00" in raw:
        raise ParseError("from_file.path contains a NUL character")
    root = Path(workspace).expanduser().resolve()
    candidate = Path(raw).expanduser()
    if candidate.is_absolute():
        raise ParseError(f"from_file.path {raw!r} is absolute; use a path inside the workspace ({root})")
    resolved = (root / candidate).resolve()
    if resolved != root and root not in resolved.parents:
        raise ParseError(f"from_file.path {raw!r} is outside the workspace ({root})")
    if not resolved.is_file():
        raise ParseError(f"from_file.path {raw!r} isn't a file in the workspace ({root})")
    return resolved


def read_text(path: Path) -> str:
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise ParseError(f"{path.name} is {size / 1048576:.1f} MB; files over 5 MB aren't read")
    with open(path, "rb") as handle:
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ParseError(f"{path.name} is over 5 MB; files over 5 MB aren't read")
    return data.decode("utf-8-sig", errors="replace")


# ---- shared helpers


def _xml(text: str, what: str):
    """Parse XML with no DOCTYPE (so no entity expansion of any kind)."""
    import xml.etree.ElementTree as ET
    head = text.lstrip()[:200000]
    if re.search(r"<!DOCTYPE|<!ENTITY", head, re.IGNORECASE) or re.search(r"<!DOCTYPE|<!ENTITY", text, re.IGNORECASE):
        raise ParseError(f"the {what} file has a DOCTYPE; files with a DOCTYPE or entities are refused")
    try:
        return ET.fromstring(text)
    except ET.ParseError as exc:
        raise ParseError(f"the file isn't valid {what} XML: {exc}") from None


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def slug(text: Any, used: set[str] | None = None, fallback: str = "item") -> str:
    """A stable ``Id`` (``^[a-z][a-z0-9_.-]{0,39}$``) from any label, unique within ``used``."""
    base = re.sub(r"[^a-z0-9_.-]+", "-", str(text or "").lower()).strip("-._")
    if not base or not base[0].isalpha():
        base = f"{fallback}-{base}" if base else fallback
    base = base[:36].rstrip("-._") or fallback
    out, n = base, 2
    while used is not None and out in used:
        suffix = f"-{n}"
        out, n = base[:40 - len(suffix)] + suffix, n + 1
    if used is not None:
        used.add(out)
    return out


def clip(text: Any, limit: int) -> str:
    """One line, at most ``limit`` characters, cut at a word with an ellipsis."""
    value = " ".join(str(text or "").split())
    if len(value) <= limit:
        return value
    cut = value[:limit - 1]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit * 0.6 else cut).rstrip(" ,;:.") + "…"


def _number(value: Any) -> float | int | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip().replace("−", "-")
    if not text or text.lower() in {"na", "n/a", "nan", "null", "none", "-", "—"}:
        return None
    text = re.sub(r"(?<=\d)[,_](?=\d{3}\b)", "", text)
    try:
        number = float(text)
    except ValueError:
        return None
    return int(number) if number.is_integer() and re.fullmatch(r"-?\d+", text) else number


def _iso_time(value: Any) -> str | None:
    """RFC 3339 with seconds and an offset, as the schemas want, or None."""
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        moment = datetime.fromtimestamp(value / 1000 if value > 1e11 else value, tz=timezone.utc)
    else:
        text = str(value).strip().replace(" ", "T", 1)
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            moment = datetime.fromisoformat(text)
        except ValueError:
            return None
        if moment.tzinfo is None:
            return None
    return moment.isoformat(timespec="seconds")


def _parse_time(value: str) -> datetime | None:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _seconds_between(start: Any, end: Any) -> float | None:
    a, b = _iso_time(start), _iso_time(end)
    if not a or not b:
        return None
    delta = (_parse_time(b) - _parse_time(a)).total_seconds()
    return round(delta, 1) if delta >= 0 else None


def _duration_words(seconds: float | None) -> str:
    if seconds is None:
        return ""
    if seconds < 60:
        return f"{seconds:.1f} s" if seconds < 10 and seconds % 1 else f"{round(seconds)} s"
    minutes, rest = divmod(round(seconds), 60)
    if minutes < 60:
        return f"{minutes} min {rest} s" if rest else f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes} min" if minutes else f"{hours} h"


def _plural(n: int, word: str, words: str | None = None) -> str:
    return f"{n} {word if n == 1 else (words or word + 's')}"


def _unsupported(parser: str, wtype: str, types: tuple[str, ...]) -> ParseError:
    return ParseError(f"the {parser} parser fills {', '.join(types[:-1])} or {types[-1]}, not {wtype}"
                      if len(types) > 1 else f"the {parser} parser fills {types[0]}, not {wtype}")


# ---- junit


def parse_junit(text: str, options: dict, wtype: str) -> dict:
    root = _xml(text, "JUnit")
    suites = [root] if _local(root.tag) == "testsuite" else [e for e in root.iter() if _local(e.tag) == "testsuite"]
    if not suites and _local(root.tag) != "testsuites":
        raise ParseError("the file isn't a JUnit report: no <testsuite> or <testsuites>")
    rows, failures = [], []
    for suite in suites:
        cases = [c for c in suite if _local(c.tag) == "testcase"]
        failed = skipped = 0
        for case in cases:
            outcome = next((c for c in case if _local(c.tag) in ("failure", "error", "skipped")), None)
            if outcome is None:
                continue
            if _local(outcome.tag) == "skipped":
                skipped += 1
                continue
            failed += 1
            name = ".".join(p for p in (case.get("classname"), case.get("name")) if p)
            message = outcome.get("message") or (outcome.text or "").strip().splitlines()[0:1]
            message = message[0] if isinstance(message, list) and message else (message or _local(outcome.tag))
            failures.append({"level": "error", "source": clip(name, 80), "text": clip(message, 2000)})
        tests = int(_number(suite.get("tests")) or len(cases))
        if not cases:
            failed = int(_number(suite.get("failures")) or 0) + int(_number(suite.get("errors")) or 0)
            skipped = int(_number(suite.get("skipped")) or _number(suite.get("disabled")) or 0)
        rows.append({"name": suite.get("name") or "Tests", "tests": tests, "failed": failed, "skipped": skipped,
                     "time": _number(suite.get("time"))})
    total = sum(r["tests"] for r in rows)
    failed = sum(r["failed"] for r in rows)
    skipped = sum(r["skipped"] for r in rows)
    passed = max(total - failed - skipped, 0)
    duration = _number(root.get("time")) or sum(r["time"] or 0 for r in rows) or None

    if wtype == "steps":
        used: set[str] = set()
        rows.sort(key=lambda r: (r["failed"] == 0, r["name"]))
        steps = []
        for r in rows[:20]:
            state = "failed" if r["failed"] else ("skipped" if r["tests"] and r["skipped"] == r["tests"] else "done")
            detail = ", ".join(x for x in (
                f"{r['tests'] - r['failed'] - r['skipped']} passed",
                f"{r['failed']} failed" if r["failed"] else "",
                f"{r['skipped']} skipped" if r["skipped"] else "") if x)
            step = {"id": slug(r["name"], used, "suite"), "title": clip(r["name"], 80), "state": state,
                    "detail": clip(detail, 120)}
            if r["time"] is not None:
                step["duration"] = round(float(r["time"]), 1)
            steps.append(step)
        result = ({"state": "critical", "text": clip(f"{failed} of {_plural(total, 'test')} failed", 120)} if failed
                  else {"state": "ok", "text": clip(f"All {_plural(total, 'test')} passed"
                                                    + (f", {skipped} skipped" if skipped else ""), 120)})
        return {"steps": steps, "result": result}
    if wtype == "metric":
        items = [{"id": "passed", "label": "Passed", "value": {"value": passed, "format": "integer"}},
                 {"id": "failed", "label": "Failed", "value": {"value": failed, "format": "integer"},
                  "state": "critical" if failed else "ok"},
                 {"id": "skipped", "label": "Skipped", "value": {"value": skipped, "format": "integer"}}]
        if duration is not None:
            items.append({"id": "duration", "label": "Duration", "value": {"value": round(float(duration), 1),
                                                                            "format": "duration"}})
        return {"items": items}
    if wtype == "code":
        lines = failures[-200:] or [{"level": "info", "text": f"All {_plural(total, 'test')} passed"}]
        return {"kind": "log", "lines": lines, "counts": {"error": failed},
                **({"omitted": len(failures) - 200} if len(failures) > 200 else {})}
    raise _unsupported("junit", wtype, ("steps", "metric", "code"))


# ---- coverage


def _coverage_rows(text: str) -> tuple[list[dict], int, int]:
    stripped = text.lstrip()
    rows: list[dict] = []
    if stripped.startswith("{"):
        try:
            data = json.loads(text)
        except ValueError as exc:
            raise ParseError(f"the coverage file isn't valid JSON: {exc}") from None
        if not isinstance(data, dict) or "totals" not in data:
            raise ParseError("the JSON isn't a coverage.py report (no \"totals\")")
        for name, entry in (data.get("files") or {}).items():
            summary = (entry or {}).get("summary") or {}
            rows.append({"file": name, "lines": int(summary.get("num_statements") or 0),
                         "covered": int(summary.get("covered_lines") or 0)})
        totals = data["totals"]
        return rows, int(totals.get("num_statements") or 0), int(totals.get("covered_lines") or 0)
    if stripped.startswith("<"):
        root = _xml(text, "Cobertura")
        if _local(root.tag) != "coverage":
            raise ParseError("the XML isn't a Cobertura report (no <coverage>)")
        files: dict[str, list[int]] = {}
        for cls in root.iter():
            if _local(cls.tag) != "class":
                continue
            lines = [ln for ln in cls.iter() if _local(ln.tag) == "line"]
            entry = files.setdefault(cls.get("filename") or cls.get("name") or "?", [0, 0])
            entry[0] += len(lines)
            entry[1] += sum(1 for ln in lines if int(_number(ln.get("hits")) or 0) > 0)
        rows = [{"file": k, "lines": v[0], "covered": v[1]} for k, v in files.items()]
        valid, covered = _number(root.get("lines-valid")), _number(root.get("lines-covered"))
        if valid is None or covered is None:
            valid, covered = sum(r["lines"] for r in rows), sum(r["covered"] for r in rows)
            if not valid and _number(root.get("line-rate")) is not None:
                return rows, 1000, round(float(root.get("line-rate")) * 1000)
        return rows, int(valid), int(covered)
    if "SF:" in text and "end_of_record" in text:
        current: dict | None = None
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("SF:"):
                current = {"file": line[3:], "lines": 0, "covered": 0, "_da": [0, 0]}
            elif current is None:
                continue
            elif line.startswith("LF:"):
                current["lines"] = int(_number(line[3:]) or 0)
            elif line.startswith("LH:"):
                current["covered"] = int(_number(line[3:]) or 0)
            elif line.startswith("DA:"):
                parts = line[3:].split(",")
                current["_da"][0] += 1
                current["_da"][1] += 1 if len(parts) > 1 and (_number(parts[1]) or 0) > 0 else 0
            elif line == "end_of_record":
                if not current["lines"] and current["_da"][0]:
                    current["lines"], current["covered"] = current["_da"]
                current.pop("_da")
                rows.append(current)
                current = None
        return rows, sum(r["lines"] for r in rows), sum(r["covered"] for r in rows)
    raise ParseError("the file isn't lcov, Cobertura XML or coverage.py JSON")


def parse_coverage(text: str, options: dict, wtype: str) -> dict:
    rows, total, covered = _coverage_rows(text)
    rate = round(covered / total, 4) if total else None
    if wtype == "meter":
        return {"items": [{"id": "lines", "label": "Line coverage",
                           "value": {"value": rate, "format": "percent", "precision": 1}, "max": 1,
                           **({} if rate is not None else {"state": "unverified"}),
                           "note": clip(f"{covered:,} of {total:,} lines covered", 120)}]}
    if wtype == "table":
        rows = [r for r in rows if r["lines"]]
        rows.sort(key=lambda r: (r["covered"] / r["lines"], r["file"]))
        out = [{"file": clip(r["file"], 120), "lines": r["lines"], "covered": r["covered"],
                "coverage": round(r["covered"] / r["lines"], 4)} for r in rows[:50]]
        return {"columns": [{"key": "file", "label": "File", "format": "text", "mono": True, "width": "wide"},
                            {"key": "lines", "label": "Lines", "format": "integer", "align": "end"},
                            {"key": "covered", "label": "Covered", "format": "integer", "align": "end"},
                            {"key": "coverage", "label": "Coverage", "format": "percent", "precision": 1,
                             "align": "end"}],
                "rows": out, "total": {"file": "Total", "lines": total, "covered": covered, "coverage": rate},
                "noun": "files" if len(rows) <= 50 else f"files (the 50 least covered of {len(rows)})"[:40]}
    raise _unsupported("coverage", wtype, ("meter", "table"))


# ---- csv / tsv / jsonl


def _records(text: str, parser: str) -> tuple[list[str], list[dict]]:
    if parser == "jsonl":
        header: list[str] = []
        rows = []
        for n, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except ValueError:
                raise ParseError(f"line {n} isn't JSON") from None
            if not isinstance(record, dict):
                raise ParseError(f"line {n} isn't a JSON object")
            for key in record:
                if key not in header:
                    header.append(key)
            rows.append(record)
        return header, rows
    reader = csv.reader(io.StringIO(text), delimiter="\t" if parser == "tsv" else ",")
    lines = [r for r in reader if any(cell.strip() for cell in r)]
    if not lines:
        raise ParseError("the file is empty")
    header = [h.strip() for h in lines[0]]
    if len(set(header)) != len(header) or not all(header):
        raise ParseError("the header row has empty or repeated column names")
    return header, [dict(zip(header, r)) for r in lines[1:]]


def _pick(header: list[str], options: dict) -> list[str]:
    wanted = options.get("columns")
    if not wanted:
        return header
    missing = [c for c in wanted if c not in header]
    if missing:
        import difflib
        hints = [f"{c!r} (did you mean {difflib.get_close_matches(c, header, 1)[0]!r}?)"
                 if difflib.get_close_matches(c, header, 1) else repr(c) for c in missing]
        raise ParseError(f"from_file.columns names {', '.join(hints)}, not in the header: {', '.join(header)}")
    return list(wanted)


def _format_for(values: list[Any]) -> str:
    numbers = [_number(v) for v in values if str(v).strip() not in ("", "None")]
    if numbers and all(isinstance(n, int) for n in numbers):
        return "integer"
    if numbers and all(n is not None for n in numbers):
        return "number"
    return "text"


def _x_kind(values: list[str]) -> str:
    if values and all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) for v in values):
        return "date"
    if values and all(_iso_time(v) for v in values):
        return "time"
    return "label"


def parse_rows(text: str, options: dict, wtype: str, parser: str) -> tuple[dict, list[str]]:
    header, records = _records(text, parser)
    columns = _pick(header, options)
    notes: list[str] = []
    if wtype == "table":
        if len(columns) > 6:
            raise ParseError(f"a table holds 6 columns and the file has {len(columns)}: pick them with from_file.columns")
        used: set[str] = set()
        keys = [slug(c, used, "col") for c in columns]
        formats = [_format_for([r.get(c) for r in records]) for c in columns]
        rows = []
        for record in records[:50]:
            row = {}
            for key, column, fmt in zip(keys, columns, formats):
                value = record.get(column)
                row[key] = _number(value) if fmt != "text" else (None if value in (None, "") else clip(value, 120))
            rows.append(row)
        if len(records) > 50:
            notes.append(f"kept the first 50 of {len(records)} rows")
        cols = [{"key": k, "label": clip(c, 24), "format": f, **({"align": "end"} if f != "text" else {})}
                for k, c, f in zip(keys, columns, formats)]
        return {"columns": cols, "rows": rows}, notes
    if wtype == "chart":
        if len(columns) < 2:
            raise ParseError("a chart needs an x column and at least one value column")
        x_col, value_cols = columns[0], columns[1:4]
        if len(columns) > 4:
            notes.append(f"a chart holds 3 series; used {', '.join(value_cols)}")
        records = records[:120]
        if len(records) < 2:
            raise ParseError("a chart needs at least 2 rows")
        xs = [clip(r.get(x_col), 40) or "—" for r in records]
        used = set()
        series = [{"id": slug(c, used, "series"), "label": clip(c, 40),
                   "values": [_number(r.get(c)) for r in records]} for c in value_cols]
        return {"x": {"kind": _x_kind(xs), "values": xs}, "series": series}, notes
    if wtype == "list":
        title_col = columns[0]
        subtitle_col = columns[1] if len(columns) > 1 else None
        value_col = columns[2] if len(columns) > 2 else None
        items = []
        for record in records[:50]:
            item = {"title": clip(record.get(title_col), 120) or "—"}
            if subtitle_col and str(record.get(subtitle_col) or "").strip():
                item["subtitle"] = clip(record.get(subtitle_col), 120)
            if value_col is not None:
                number = _number(record.get(value_col))
                item["value"] = {"value": number} if number is not None else {"value": clip(record.get(value_col), 32) or None, "format": "text"}
            items.append(item)
        if len(records) > 50:
            notes.append(f"kept the first 50 of {len(records)} rows")
        return {"items": items}, notes
    if wtype == "flashcard" and parser in ("tsv", "jsonl", "csv"):
        if len(columns) < 2:
            raise ParseError("flashcards need a front and a back column")
        front, back = columns[0], columns[1]
        used = set()
        cards = [{"id": slug(f"card-{n + 1}", used, "card"), "front": clip(r.get(front), 200),
                  "back": clip(r.get(back), 200)}
                 for n, r in enumerate(records[:20]) if str(r.get(front) or "").strip()]
        if len(records) > 20:
            notes.append(f"kept the first 20 of {len(records)} cards (send the rest in later batches)")
        return {"cards": cards, "progress": {"done": 0, "total": len(records)}}, notes
    raise _unsupported(parser, wtype, ("table", "chart", "list") + (("flashcard",) if parser != "csv" else ()))


# ---- json with pointers


def _pointer(document: Any, pointer: str) -> Any:
    if pointer in ("", "/"):
        return document if pointer == "" else document.get("") if isinstance(document, dict) else None
    node = document
    for raw in pointer.lstrip("/").split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, list):
            if not token.isdigit() or int(token) >= len(node):
                raise ParseError(f"JSON Pointer {pointer!r}: no index {token!r}")
            node = node[int(token)]
        elif isinstance(node, dict):
            if token not in node:
                raise ParseError(f"JSON Pointer {pointer!r}: no key {token!r}")
            node = node[token]
        else:
            raise ParseError(f"JSON Pointer {pointer!r}: {token!r} is inside a value, not an object or array")
    return node


def parse_json(text: str, options: dict, wtype: str) -> dict:
    mapping = options.get("map")
    if not isinstance(mapping, dict) or not mapping:
        raise ParseError("the json parser needs from_file.map: payload field → JSON Pointer")
    try:
        document = json.loads(text)
    except ValueError as exc:
        raise ParseError(f"the file isn't valid JSON: {exc}") from None
    out: dict = {}
    for field, pointer in mapping.items():
        path = [p for p in str(field).strip("/").split("/") if p] if str(field).startswith("/") else str(field).split(".")
        if not path or path[0] in ("type", "v", "id", "rev"):
            raise ParseError(f"from_file.map can't fill {field!r}")
        node = out
        for key in path[:-1]:
            node = node.setdefault(key, {})
            if not isinstance(node, dict):
                raise ParseError(f"from_file.map fills {field!r} inside a value already filled")
        node[path[-1]] = _pointer(document, pointer)
    return out


# ---- logs

_LEVELS = {"trace": "trace", "debug": "debug", "dbg": "debug", "info": "info", "inf": "info", "notice": "notice",
           "warn": "warning", "warning": "warning", "wrn": "warning", "error": "error", "err": "error",
           "fatal": "critical", "critical": "critical", "crit": "critical", "panic": "critical", "severe": "critical"}
_RANK = {"trace": 0, "debug": 1, "info": 2, "notice": 2, "warning": 3, "error": 4, "critical": 5}
_LINE = re.compile(
    r"^\s*\[?(?P<at>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\]?\s*"
    r"[\[(]?(?P<level>trace|debug|dbg|info|inf|notice|warn|warning|wrn|error|err|fatal|critical|crit|panic|severe)"
    r"[\])]?:?\s*(?P<text>.*)$", re.IGNORECASE)
_LEVEL_ONLY = re.compile(r"^\s*[\[(]?(?P<level>trace|debug|info|notice|warn|warning|error|fatal|critical)[\])]?:?\s+(?P<text>.*)$",
                         re.IGNORECASE)


def _log_record(line: str) -> dict | None:
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.startswith("{"):
        try:
            data = json.loads(stripped)
        except ValueError:
            data = None
        if isinstance(data, dict):
            level = str(data.get("level") or data.get("severity") or data.get("lvl") or data.get("levelname") or "info")
            text = data.get("msg") or data.get("message") or data.get("event") or stripped
            at = data.get("time") or data.get("ts") or data.get("timestamp") or data.get("@timestamp")
            record = {"level": _LEVELS.get(level.lower(), "info"), "text": str(text)}
            if data.get("logger") or data.get("source"):
                record["source"] = str(data.get("logger") or data.get("source"))
            if _iso_time(at):
                record["at"] = _iso_time(at)
            return record
    match = _LINE.match(stripped)
    if match:
        at = match["at"].replace(",", ".")
        at = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", at)
        record = {"level": _LEVELS[match["level"].lower()], "text": match["text"]}
        if _iso_time(at):
            record["at"] = _iso_time(at)
        return record
    match = _LEVEL_ONLY.match(stripped)
    if match:
        return {"level": _LEVELS[match["level"].lower()], "text": match["text"]}
    return {"level": "info", "text": stripped, "_plain": True}


def parse_log(text: str, options: dict, wtype: str) -> dict:
    if wtype != "code":
        raise _unsupported("log", wtype, ("code",))
    floor = _RANK.get(options.get("level") or "trace", 0)
    since = _parse_time(options["since"]) if options.get("since") else None
    records = []
    for line in text.splitlines():
        record = _log_record(line)
        if record is None:
            continue
        if record.pop("_plain", False) and records:
            # A continuation (a stack trace line) belongs to the record above it.
            records[-1]["text"] = (records[-1]["text"] + " ⏎ " + record["text"])
            continue
        records.append(record)
    counts = {"error": 0, "warning": 0, "info": 0, "debug": 0}
    kept: list[dict] = []
    for record in records:
        if _RANK.get(record["level"], 2) < floor:
            continue
        if since and record.get("at") and _parse_time(record["at"]) < since:
            continue
        bucket = {"critical": "error", "notice": "info", "trace": "debug"}.get(record["level"], record["level"])
        counts[bucket] += 1
        record["text"] = record["text"][:2000]
        if kept and kept[-1]["text"] == record["text"] and kept[-1]["level"] == record["level"]:
            kept[-1]["repeat"] = kept[-1].get("repeat", 1) + 1
            continue
        kept.append(record)
    if not kept:
        kept = [{"level": "info", "text": "No log lines match the filter."}]
    omitted = max(len(kept) - 200, 0)
    return {"kind": "log", "lines": kept[-200:], "counts": {k: v for k, v in counts.items() if v},
            **({"omitted": omitted} if omitted else {})}


# ---- iCalendar


def _ics_lines(text: str) -> list[tuple[str, dict, str]]:
    unfolded: list[str] = []
    for raw in text.splitlines():
        if raw.startswith((" ", "\t")) and unfolded:
            unfolded[-1] += raw[1:]
        else:
            unfolded.append(raw)
    out = []
    for line in unfolded:
        if ":" not in line:
            continue
        head, value = line.split(":", 1)
        name, *params = head.split(";")
        out.append((name.upper(), dict(p.split("=", 1) for p in params if "=" in p), value))
    return out


def _ics_value(value: str) -> str:
    return value.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def _ics_time(value: str, params: dict, default_tz) -> tuple[datetime | date, bool]:
    value = value.strip()
    if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        return datetime.strptime(value[:8], "%Y%m%d").date(), True
    moment = datetime.strptime(value.rstrip("Z")[:15], "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        # UTC times read in the gateway's zone: "09:00Z" is the 05:00 the person sees in New York.
        return moment.replace(tzinfo=timezone.utc).astimezone(default_tz), False
    tz = default_tz
    if params.get("TZID"):
        try:
            from zoneinfo import ZoneInfo
            tz = ZoneInfo(params["TZID"].strip('"'))
        except Exception:
            tz = default_tz
    return moment.replace(tzinfo=tz), False


_WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def _occurrences(start, rule: str, window_end, exdates: set) -> list:
    """Expand the common RRULEs (DAILY, WEEKLY with BYDAY, MONTHLY, YEARLY; INTERVAL, COUNT, UNTIL)."""
    parts = dict(p.split("=", 1) for p in rule.split(";") if "=" in p)
    freq, interval = parts.get("FREQ", ""), int(parts.get("INTERVAL", "1") or 1)
    count = int(parts["COUNT"]) if parts.get("COUNT", "").isdigit() else None
    until = None
    if parts.get("UNTIL"):
        with_tz = start.tzinfo if isinstance(start, datetime) else None
        raw = parts["UNTIL"]
        until = (datetime.strptime(raw[:8], "%Y%m%d").date() if len(raw) == 8 else
                 datetime.strptime(raw.rstrip("Z")[:15], "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc if raw.endswith("Z") else with_tz))
    days = [_WEEKDAYS[d[-2:]] for d in parts.get("BYDAY", "").split(",") if d[-2:] in _WEEKDAYS]
    out, current, n = [], start, 0
    limit_date = window_end

    def key(x):
        return x.date() if isinstance(x, datetime) else x

    for _ in range(5000):
        candidates = [current]
        if freq == "WEEKLY" and days:
            monday = current - timedelta(days=key(current).weekday())
            candidates = sorted(monday + timedelta(days=d) for d in days)
            candidates = [c for c in candidates if c >= start]
        for c in candidates:
            if until is not None and ((c > until) if type(c) is type(until) else key(c) > key(until)):
                return out
            if count is not None and n >= count:
                return out
            n += 1
            if key(c) > limit_date:
                return out
            if key(c) not in exdates:
                out.append(c)
        if freq == "DAILY":
            current = current + timedelta(days=interval)
        elif freq == "WEEKLY":
            current = (current - timedelta(days=key(current).weekday()) if days else current) + timedelta(weeks=interval)
        elif freq == "MONTHLY":
            month = key(current).month - 1 + interval
            year = key(current).year + month // 12
            try:
                current = current.replace(year=year, month=month % 12 + 1)
            except ValueError:
                return out
        elif freq == "YEARLY":
            try:
                current = current.replace(year=key(current).year + interval)
            except ValueError:
                return out
        else:
            return out
    return out


def parse_ics(text: str, options: dict, wtype: str, agent_payload: dict | None = None) -> dict:
    if wtype != "agenda":
        raise _unsupported("ics", wtype, ("agenda",))
    if "BEGIN:VCALENDAR" not in text.upper():
        raise ParseError("the file isn't iCalendar (no BEGIN:VCALENDAR)")
    agent_payload = agent_payload or {}
    local_tz = datetime.now().astimezone().tzinfo
    raw_events: list[dict] = []
    current: dict | None = None
    for name, params, value in _ics_lines(text):
        if name == "BEGIN" and value.upper() == "VEVENT":
            current = {"exdates": set()}
        elif name == "END" and value.upper() == "VEVENT" and current is not None:
            raw_events.append(current)
            current = None
        elif current is not None:
            if name in ("DTSTART", "DTEND"):
                current[name] = _ics_time(value, params, local_tz)
            elif name == "EXDATE":
                for part in value.split(","):
                    moment, _ = _ics_time(part, params, local_tz)
                    current["exdates"].add(moment.date() if isinstance(moment, datetime) else moment)
            elif name in ("SUMMARY", "LOCATION", "DESCRIPTION", "STATUS", "RRULE", "UID"):
                current[name] = _ics_value(value)
    if not raw_events:
        raise ParseError("the iCalendar file has no events")

    def day_of(moment):
        return moment.astimezone(local_tz).date() if isinstance(moment, datetime) else moment

    first_day = None
    if agent_payload.get("date"):
        first_day = date.fromisoformat(agent_payload["date"])
    else:
        starts = [day_of(e["DTSTART"][0]) for e in raw_events if "DTSTART" in e]
        today = datetime.now(local_tz).date()
        upcoming = [d for d in starts if d >= today]
        first_day = min(upcoming) if upcoming else (min(starts) if starts else today)
    view = agent_payload.get("view") or "day"
    span = agent_payload.get("span", 7) if view == "days" else 1
    last_day = first_day + timedelta(days=span - 1)

    events = []
    used: set[str] = set()
    for event in raw_events:
        if "DTSTART" not in event:
            continue
        start, all_day = event["DTSTART"]
        end = event.get("DTEND", (None, all_day))[0]
        length = (end - start) if end is not None else None
        starts = _occurrences(start, event["RRULE"], last_day, event["exdates"]) if event.get("RRULE") else [start]
        for occurrence in starts:
            occ_end = occurrence + length if length is not None else None
            first, last = day_of(occurrence), day_of(occ_end - timedelta(days=1) if all_day and occ_end else occ_end or occurrence)
            if last < first_day or first > last_day:
                continue
            item: dict = {"id": slug(event.get("SUMMARY") or "event", used, "event"),
                          "title": clip(event.get("SUMMARY") or "Busy", 80)}
            if all_day:
                item.update({"all_day": True, "start": occurrence.isoformat()})
                if occ_end and (occ_end - timedelta(days=1)) > occurrence:
                    item["end"] = (occ_end - timedelta(days=1)).isoformat()
            else:
                item["start"] = occurrence.isoformat(timespec="seconds")
                if occ_end is not None:
                    item["end"] = occ_end.isoformat(timespec="seconds")
            if event.get("LOCATION"):
                item["place"] = {"name": clip(event["LOCATION"], 80)}
            if event.get("DESCRIPTION"):
                item["note"] = clip(event["DESCRIPTION"], 80)
            status = (event.get("STATUS") or "").upper()
            if status in ("TENTATIVE", "CANCELLED"):
                item["state"] = status.lower()
            sort_at = occurrence if isinstance(occurrence, datetime) else datetime.combine(occurrence, datetime.min.time(), local_tz)
            events.append((day_of(occurrence), not all_day, sort_at, item))
    events.sort(key=lambda e: (e[0], e[1], e[2]))
    out: dict = {"events": [e[3] for e in events[:50]]}
    if not agent_payload.get("date"):
        out["date"] = first_day.isoformat()
    return out


# ---- SARIF

_SARIF_STATE = {"error": ("critical", "Error"), "warning": ("warning", "Warning"), "note": ("info", "Note"),
                "none": ("info", "Info")}


def parse_sarif(text: str, options: dict, wtype: str) -> dict:
    if wtype != "list":
        raise _unsupported("sarif", wtype, ("list",))
    if text.lstrip().startswith("<"):
        _xml(text, "SARIF")
        raise ParseError("SARIF is JSON; this file is XML")
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise ParseError(f"the SARIF file isn't valid JSON: {exc}") from None
    if not isinstance(data, dict) or not isinstance(data.get("runs"), list):
        raise ParseError("the file isn't SARIF 2.1 (no \"runs\")")
    findings = []
    for run in data["runs"]:
        rules = {}
        for rule in ((run.get("tool") or {}).get("driver") or {}).get("rules") or []:
            rules[rule.get("id")] = rule
        for result in run.get("results") or []:
            rule_id = result.get("ruleId") or ""
            level = result.get("level") or ((rules.get(rule_id) or {}).get("defaultConfiguration") or {}).get("level") or "warning"
            message = (result.get("message") or {}).get("text") or rule_id or "Finding"
            where = ""
            location = ((result.get("locations") or [{}])[0] or {}).get("physicalLocation") or {}
            uri = (location.get("artifactLocation") or {}).get("uri") or ""
            line = (location.get("region") or {}).get("startLine")
            if uri:
                where = f"{uri}:{line}" if line else uri
            findings.append((["error", "warning", "note", "none"].index(level) if level in _SARIF_STATE else 1,
                             where, rule_id, message, level, uri, line))
    findings.sort(key=lambda f: (f[0], f[1]))
    items = []
    for _rank, where, rule_id, message, level, uri, line in findings[:50]:
        state, word = _SARIF_STATE.get(level, ("warning", "Warning"))
        item = {"title": clip(message, 120), "tags": [{"label": word, "state": state}],
                "state": "critical" if state == "critical" else ("warning" if state == "warning" else "info")}
        subtitle = " · ".join(x for x in (where, rule_id) if x)
        if subtitle:
            item["subtitle"] = clip(subtitle, 120)
        if uri and not uri.startswith(("/", "file:")) and ".." not in uri and re.fullmatch(r"[^\s]+", uri):
            item["url"] = f"hermes-file:{uri}" + (f"#L{line}" if line else "")
        items.append(item)
    counts = []
    for level, label in (("error", "errors"), ("warning", "warnings"), ("note", "notes")):
        n = sum(1 for f in findings if f[4] == level)
        if n:
            counts.append({"label": label, "value": n, "state": _SARIF_STATE[level][0]})
    out: dict = {"items": items, "counts": counts[:4]}
    if len(findings) > 50:
        out["total"] = len(findings)
    return out


# ---- GitHub Actions (gh run view / gh pr checks)

_GH_STATE = {"success": "done", "pass": "done", "failure": "failed", "fail": "failed", "cancelled": "skipped",
             "cancel": "skipped", "skipped": "skipped", "skipping": "skipped", "neutral": "done",
             "timed_out": "failed", "action_required": "blocked", "startup_failure": "failed", "stale": "skipped",
             "in_progress": "running", "queued": "waiting", "pending": "waiting", "waiting": "waiting",
             "requested": "waiting"}


def parse_gh_run(text: str, options: dict, wtype: str) -> dict:
    if wtype != "steps":
        raise _unsupported("gh-run", wtype, ("steps",))
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise ParseError(f"the file isn't gh JSON output: {exc}") from None
    if isinstance(data, list):  # gh pr checks --json name,state,bucket,startedAt,completedAt,…
        jobs = [{"name": c.get("name") or c.get("workflow") or "check",
                 "state": _GH_STATE.get(str(c.get("bucket") or c.get("state") or "").lower(), "unknown"),
                 "started": c.get("startedAt"), "completed": c.get("completedAt"), "failed_step": None}
                for c in data if isinstance(c, dict)]
    elif isinstance(data, dict) and isinstance(data.get("jobs"), list):
        jobs = []
        for job in data["jobs"]:
            status = str(job.get("status") or "").lower()
            state = _GH_STATE.get(str(job.get("conclusion") or "").lower()) if status == "completed" else _GH_STATE.get(status)
            failed_step = next((s.get("name") for s in job.get("steps") or []
                                if str(s.get("conclusion") or "").lower() in ("failure", "timed_out")), None)
            jobs.append({"name": job.get("name") or "job", "state": state or "unknown", "started": job.get("startedAt"),
                         "completed": job.get("completedAt"), "failed_step": failed_step})
    else:
        raise ParseError("the JSON isn't `gh run view --json …,jobs` or `gh pr checks --json …` output")
    if not jobs:
        raise ParseError("the run has no jobs")
    used: set[str] = set()
    steps = []
    for job in jobs[:20]:
        step = {"id": slug(job["name"], used, "job"), "title": clip(job["name"], 80), "state": job["state"]}
        if job["failed_step"]:
            step["detail"] = clip(f"Failed at “{job['failed_step']}”", 120)
        if job["state"] in ("done", "failed"):
            seconds = _seconds_between(job["started"], job["completed"])
            if seconds is not None:
                step["duration"] = seconds
        steps.append(step)
    failed = [s for s in steps if s["state"] == "failed"]
    running = any(s["state"] in ("running", "waiting") for s in steps)
    out: dict = {"steps": steps, "kind": "pipeline" if 2 <= len(steps) <= 6 and all(len(s["title"]) <= 16 for s in steps) else "vertical"}
    if failed:
        out["result"] = {"state": "critical", "text": clip(f"{_plural(len(failed), 'job')} failed: "
                                                           + ", ".join(s["title"] for s in failed), 120)}
    elif not running:
        out["result"] = {"state": "ok", "text": clip(f"All {_plural(len(steps), 'job')} passed", 120)}
    starts = sorted(t for t in (_iso_time(j["started"]) for j in jobs) if t)
    if starts:
        out["started_at"] = starts[0]
    return out


# ---- entry point


def parse(path: Path, options: dict, wtype: str, agent_payload: dict | None = None) -> tuple[dict, list[str]]:
    """Fill fields of a ``wtype`` widget from ``path``; returns (fields, notes for the agent)."""
    parser = options.get("parser")
    if parser not in PARSERS:
        raise ParseError(f"from_file.parser {parser!r} isn't one of {', '.join(PARSERS)}")
    text = read_text(path)
    notes: list[str] = []
    handlers: dict[str, Callable[[], Any]] = {
        "junit": lambda: parse_junit(text, options, wtype),
        "coverage": lambda: parse_coverage(text, options, wtype),
        "json": lambda: parse_json(text, options, wtype),
        "log": lambda: parse_log(text, options, wtype),
        "ics": lambda: parse_ics(text, options, wtype, agent_payload),
        "sarif": lambda: parse_sarif(text, options, wtype),
        "gh-run": lambda: parse_gh_run(text, options, wtype),
    }
    if parser in ("csv", "tsv", "jsonl"):
        fields, notes = parse_rows(text, options, wtype, parser)
    else:
        fields = handlers[parser]()
    bad = sorted(_forbidden(fields))
    if bad:
        raise ParseError(f"data from a file can't set {', '.join(bad)}")
    return fields, notes


def _forbidden(value: Any, path: str = "") -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, item in value.items():
            here = f"{path}.{key}" if path else key
            if key in FORBIDDEN_KEYS:
                found.add(here)
            found |= _forbidden(item, here)
    elif isinstance(value, list):
        for n, item in enumerate(value):
            found |= _forbidden(item, f"{path}[{n}]")
    return found
