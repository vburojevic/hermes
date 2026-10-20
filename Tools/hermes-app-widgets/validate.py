"""Validation (payload-contract.md §10): the bundled JSON Schema 2020-12 schemas, then every rule in
semantic-rules.json marked plugin, both or warn.

Producers are strict, so a misspelt field is an error. Errors are text the model can act on: each
names the field path, what's wrong, the allowed values and the closest match for a misspelt name
("items[2].delta.good: "upward" isn't allowed; use up, down or neutral"). Warnings are stored with
the widget and returned to the agent, never shown to the person.
"""
from __future__ import annotations

import difflib
import json
import math
import re
from datetime import date, datetime
from functools import cached_property
from pathlib import Path
from typing import Any, Iterable, Iterator

SPEC = Path(__file__).resolve().parent / "spec"
BASE_ID = "https://hermesapp.dev/schemas/widgets/"
RESERVED_IDS = frozenset({"answer", "submit", "cancel", "check", "set", "approve", "edit", "reject", "undo",
                          "rate", "acknowledge", "refresh", "retry"})
# A type's own built-in may be an envelope action (alert.md: add `acknowledge` labelled "Acknowledge").
ENVELOPE_BUILT_INS = {"alert": {"acknowledge"}, "choice": {"answer"}, "form": {"submit", "cancel"},
                      "compare": {"answer"}}
MAX_PAYLOAD = 64 * 1024
MAX_ERRORS = 8
_PATTERNS = {
    "^[a-z][a-z0-9_.-]{0,39}$": "an id: lowercase letters, digits, - _ or ., starting with a letter",
    "^w_[A-Za-z0-9]{6,40}$": "a widget id: w_ and 6–40 letters or digits",
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}$": "an ISO date like 2026-10-16",
    "^[A-Z]{3}$": "an ISO 4217 currency code like EUR",
}


class WidgetError(ValueError):
    """Invalid input; ``issues`` are the lines to return to the model. Nothing is stored."""

    def __init__(self, issues: list[str] | str):
        self.issues = [issues] if isinstance(issues, str) else list(issues)
        super().__init__("; ".join(self.issues))


def dotted(path: Iterable[Any]) -> str:
    out = ""
    for part in path:
        out += f"[{part}]" if isinstance(part, int) else (f".{part}" if out else str(part))
    return out


def _quote(value: Any) -> str:
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= 60 else text[:57] + "…"


def _or_list(values: list[Any]) -> str:
    words = [str(v) for v in values]
    if len(words) <= 1:
        return "".join(words)
    return f"{', '.join(words[:-1])} or {words[-1]}"


def _did_you_mean(word: str, options: Iterable[str]) -> str:
    close = difflib.get_close_matches(str(word), [str(o) for o in options], n=1, cutoff=0.6)
    return f"; did you mean {_quote(close[0])}?" if close else ""


def _parse_time(value: Any) -> datetime | date | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            return date.fromisoformat(text)
        moment = datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
        return moment if moment.tzinfo else None
    except ValueError:
        return None


def _comparable(a: Any, b: Any) -> tuple[Any, Any] | None:
    """Two times or dates as values that compare (a date against a time compares by day)."""
    x, y = _parse_time(a), _parse_time(b)
    if x is None or y is None:
        return None
    if isinstance(x, datetime) and isinstance(y, datetime):
        return x, y
    return (x.date() if isinstance(x, datetime) else x), (y.date() if isinstance(y, datetime) else y)


class Spec:
    """The bundled schemas, catalogue, rules and symbol allowlist, loaded once."""

    def __init__(self, root: Path = SPEC):
        self.root = root

    def _json(self, relative: str) -> Any:
        return json.loads((self.root / relative).read_text())

    @cached_property
    def catalog(self) -> dict[str, dict]:
        return {t["type"]: t for t in self._json("catalog.json")["types"]}

    @cached_property
    def rules(self) -> list[dict]:
        return self._json("semantic-rules.json")["rules"]

    @cached_property
    def symbols(self) -> frozenset[str]:
        try:
            return frozenset(self._json("symbols.json")["symbols"])
        except FileNotFoundError:
            return frozenset()

    @cached_property
    def registry(self):
        from referencing import Registry, Resource
        registry = Registry()
        for path in sorted((self.root / "schemas").rglob("*.schema.json")):
            contents = json.loads(path.read_text())
            resource = Resource.from_contents(contents)
            relative = path.relative_to(self.root / "schemas").as_posix()
            registry = registry.with_resource(contents.get("$id") or BASE_ID + relative, resource)
            if relative != BASE_ID + relative:
                registry = registry.with_resource(BASE_ID + relative, resource)
        return registry

    def schema(self, wtype: str, kind: str = "full") -> dict:
        relative = f"schemas/{wtype}.schema.json" if kind == "full" else f"schemas/input/{wtype}.input.schema.json"
        return self._json(relative)

    def validator(self, wtype: str, kind: str = "full"):
        cache = self.__dict__.setdefault("_validators", {})
        key = (wtype, kind)
        if key not in cache:
            from jsonschema import Draft202012Validator, FormatChecker
            cache[key] = Draft202012Validator(self.schema(wtype, kind), registry=self.registry,
                                              format_checker=FormatChecker())
        return cache[key]

    def resolve(self, schema: dict, base: str) -> dict:
        """Follow ``$ref`` (relative to ``base``) to the schema it names."""
        ref = schema.get("$ref")
        if not ref:
            return schema
        resolver = self.registry.resolver(base_uri=base)
        return resolver.lookup(ref).contents


# ---- schema errors in words


class _Explain:
    def __init__(self, spec: Spec, base: str):
        self.spec, self.base = spec, base

    def known_properties(self, schema: dict, base: str, depth: int = 0) -> set[str]:
        names = set((schema.get("properties") or {}).keys())
        if depth > 4:
            return names
        for key in ("allOf", "anyOf", "oneOf"):
            for sub in schema.get(key) or []:
                if "$ref" in sub:
                    target, target_base = self._lookup(sub["$ref"], base)
                    names |= self.known_properties(target, target_base, depth + 1)
                else:
                    names |= self.known_properties(sub, base, depth + 1)
        for key in ("then", "else"):
            if isinstance(schema.get(key), dict):
                names |= self.known_properties(schema[key], base, depth + 1)
        return names

    def _lookup(self, ref: str, base: str) -> tuple[dict, str]:
        resolved = self.spec.registry.resolver(base_uri=base).lookup(ref)
        target_base = ref.split("#", 1)[0]
        if target_base and not target_base.startswith("http"):
            target_base = base.rsplit("/", 1)[0] + "/" + target_base
        return resolved.contents, target_base or base

    def condition(self, error) -> str:
        """For an error inside ``then``: "when subject.kind is purchase, spend, booking or transfer"."""
        path = list(error.schema_path)
        if "then" not in path:
            return ""
        index = len(path) - 1 - path[::-1].index("then")
        node: Any = self.spec.validator(*self._root_key).schema
        for part in path[:index]:
            try:
                node = node[part]
            except (KeyError, IndexError, TypeError):
                return ""
        cond = node.get("if") if isinstance(node, dict) else None
        words = self._describe(cond or {}, [])
        return f" when {words}" if words else ""

    _root_key: tuple[str, str] = ("", "full")

    def _describe(self, schema: dict, prefix: list[str]) -> str:
        parts = []
        for name, sub in (schema.get("properties") or {}).items():
            here = prefix + [name]
            if "const" in sub:
                parts.append(f"{'.'.join(here)} is {sub['const']}")
            elif "enum" in sub:
                parts.append(f"{'.'.join(here)} is {_or_list(sub['enum'])}")
            elif "properties" in sub:
                inner = self._describe(sub, here)
                if inner:
                    parts.append(inner)
        for name in schema.get("required") or []:
            if name not in (schema.get("properties") or {}):
                parts.append(f"{'.'.join(prefix + [name])} is set")
        return " and ".join(parts)

    def message(self, error) -> list[str]:
        path = dotted(error.absolute_path)
        where = path or "the payload"
        kind = error.validator
        value = error.instance
        schema = error.schema if isinstance(error.schema, dict) else {}
        if kind in ("anyOf", "oneOf") and error.context:
            from jsonschema.exceptions import best_match
            best = best_match(error.context)
            if best is not None and list(best.absolute_path) != list(error.absolute_path) or (
                    best is not None and best.validator not in ("type",)):
                return self.message(best)
            options = [s.get("$ref", "").split("/")[-1] or s.get("type") for s in error.validator_value]
            return [f"{where} doesn't match any allowed shape ({_or_list([o for o in options if o])})"]
        if kind == "enum":
            return [f"{where}: {_quote(value)} isn't allowed; use {_or_list(error.validator_value)}"
                    + _did_you_mean(value, error.validator_value)]
        if kind == "const":
            return [f"{where} must be {_quote(error.validator_value)}"]
        if kind == "required":
            missing = re.findall(r"'([^']+)' is a required property", error.message)
            name = missing[0] if missing else "?"
            field = f"{path}.{name}" if path else name
            return [f"{field} is required{self.condition(error)}"]
        if kind in ("unevaluatedProperties", "additionalProperties"):
            unexpected = re.findall(r"'([^']+)'", error.message.split("(", 1)[-1]) if "(" in error.message else []
            if not unexpected and isinstance(value, dict):
                known = self.known_properties(schema, self.base)
                unexpected = [k for k in value if k not in known]
            known = self.known_properties(schema, self.base)
            out = []
            for name in unexpected or ["?"]:
                field = f"{path}.{name}" if path else name
                if name in ("id", "rev", "producer") and not path:
                    out.append(f"{name} is set by the tool; leave it out")
                else:
                    out.append(f"unknown field {_quote(field)}" + _did_you_mean(name, known))
            return out
        if kind == "maxLength":
            return [f"{where} is {len(value)} characters; at most {error.validator_value}"]
        if kind == "minLength":
            return [f"{where} is empty" if not value else f"{where} needs at least {error.validator_value} characters"]
        if kind == "maxItems":
            return [f"{where} has {len(value)} items; at most {error.validator_value}"]
        if kind == "minItems":
            return [f"{where} has {len(value)} items; at least {error.validator_value}"]
        if kind in ("maxProperties", "minProperties"):
            return [f"{where} has {len(value)} entries; {'at most' if kind == 'maxProperties' else 'at least'} "
                    f"{error.validator_value}"]
        if kind == "pattern":
            ref = (schema.get("description") or "")
            words = _PATTERNS.get(error.validator_value)
            if not words:
                if "https" in error.validator_value:
                    words = "an https:// URL (no user info or spaces) or hermes-file:<relative path, no ..>"
                elif "bot:" in error.validator_value:
                    words = "an SF Symbol name (payload-contract.md §7) or bot:<handle>"
                elif "T[0-9]{2}" in error.validator_value:
                    words = "an RFC 3339 time with seconds and an offset, like 2026-10-16T09:41:00+02:00"
                else:
                    words = ref or f"the pattern {error.validator_value}"
            return [f"{where}: {_quote(value)} isn't {words}"]
        if kind == "format":
            fmt = {"date-time": "an RFC 3339 time with seconds and an offset, like 2026-10-16T09:41:00+02:00",
                   "date": "an ISO date like 2026-10-16"}.get(error.validator_value, error.validator_value)
            return [f"{where}: {_quote(value)} isn't {fmt}"]
        if kind == "type":
            expected = error.validator_value if isinstance(error.validator_value, list) else [error.validator_value]
            return [f"{where} must be {_or_list(expected)}, not {type(value).__name__.replace('dict', 'object').replace('str', 'string').replace('list', 'array')}"]
        if kind in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"):
            word = {"minimum": "at least", "maximum": "at most", "exclusiveMinimum": "more than",
                    "exclusiveMaximum": "less than"}[kind]
            return [f"{where} is {_quote(value)}; it must be {word} {error.validator_value}"]
        if kind == "not":
            hint = (error.validator_value or {}).get("description") if isinstance(error.validator_value, dict) else None
            return [f"{where}: {hint or 'this combination isn’t allowed'}"]
        if kind in ("contains", "minContains", "maxContains"):
            return [f"{where}: {error.message}"]
        if kind == "dependentRequired":
            return [f"{where}: {error.message.replace('is a dependency of', 'is needed with')}"]
        if kind == "propertyNames":
            return [f"{where}: key {error.message}"]
        return [f"{where}: {error.message}"]


def schema_issues(spec: Spec, wtype: str, payload: dict, kind: str = "full") -> list[str]:
    validator = spec.validator(wtype, kind)
    explain = _Explain(spec, validator.schema.get("$id") or BASE_ID)
    explain._root_key = (wtype, kind)
    issues: list[str] = []
    for error in sorted(validator.iter_errors(payload), key=lambda e: (list(map(str, e.absolute_path)), e.validator)):
        for line in explain.message(error):
            if line not in issues:
                issues.append(line)
    return issues


def raw_errors(spec: Spec, wtype: str, payload: dict, kind: str = "full") -> list:
    return list(spec.validator(wtype, kind).iter_errors(payload))


# ---- walking a payload


def walk(value: Any, path: tuple = ()) -> Iterator[tuple[tuple, Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, item in value.items():
            yield from walk(item, path + (key,))
    elif isinstance(value, list):
        for n, item in enumerate(value):
            yield from walk(item, path + (n,))


def strings(value: Any) -> Iterator[tuple[tuple, str]]:
    for path, item in walk(value):
        if isinstance(item, str):
            yield path, item
        if isinstance(item, dict):
            for key in item:
                if isinstance(key, str) and len(key) > 24:
                    yield path + ("<key>",), key


def _actions(payload: dict) -> Iterator[tuple[tuple, dict]]:
    """Every Action object: envelope actions, row actions and a summary's do_first.action."""
    for path, item in walk(payload):
        if not path:
            continue
        if path[-1] == "actions" and isinstance(item, list):
            for n, action in enumerate(item):
                if isinstance(action, dict):
                    yield path + (n,), action
        elif path[-1] == "action" and isinstance(item, dict) and "label" in item and len(path) >= 2 \
                and path[-2] == "do_first":
            yield path, item


def _is_quantity(item: Any) -> bool:
    return isinstance(item, dict) and "value" in item and isinstance(item.get("format"), str)


# ---- semantic rules


class Checks:
    """``semantic(payload, context)`` → (errors, warnings), one method per rule id in semantic-rules.json."""

    WHERE = ("plugin", "both", "warn")

    def __init__(self, spec: Spec):
        self.spec = spec

    def run(self, payload: dict, context: dict) -> tuple[list[str], list[str]]:
        errors: list[str] = []
        warnings: list[str] = []
        for rule in self.spec.rules:
            if rule["where"] not in self.WHERE:
                continue
            if rule["types"] != "*" and rule["types"] != payload.get("type"):
                continue
            check = getattr(self, "rule_" + rule["id"].replace(".", "_"), None)
            if check is None:
                continue
            found = list(check(payload, context) or [])
            (warnings if rule["where"] == "warn" else errors).extend(found)
        return errors, warnings

    # -- every widget

    def rule_actions_ids(self, p: dict, ctx: dict) -> Iterator[str]:
        # Reserved ids are refused on widget-level actions only (the envelope's and a summary's
        # do_first), except the type's own built-in: a row action may be called "check" (sources-1),
        # and an alert carries Acknowledge. Ids are unique per actions array.
        lists: dict[tuple, list[str]] = {}
        own = ENVELOPE_BUILT_INS.get(p.get("type"), set())
        for path, action in _actions(p):
            ident = action.get("id")
            widget_level = path[0] == "actions" or path[:2] == ("do_first", "action")
            if widget_level and ident in RESERVED_IDS and not (path[0] == "actions" and ident in own):
                yield f"{dotted(path)}.id {_quote(ident)} is reserved for the built-in action; use another id"
            if isinstance(path[-1], int):
                lists.setdefault(path[:-1], []).append(ident)
        for owner, ids in lists.items():
            seen = set()
            for ident in ids:
                if ident in seen:
                    yield f"action id {_quote(ident)} is used twice in {dotted(owner)}"
                seen.add(ident)

    def rule_actions_primary(self, p: dict, ctx: dict) -> Iterator[str]:
        widget_level = [path for path, a in _actions(p) if a.get("style") == "primary"
                        and (path[0] == "actions" or path[:2] == ("do_first", "action"))]
        if len(widget_level) > 1:
            yield f"{len(widget_level)} primary actions ({', '.join(dotted(x) for x in widget_level)}); make one secondary"
        rows: dict[tuple, int] = {}
        for path, action in _actions(p):
            if action.get("style") == "primary" and path[0] != "actions" and path[:2] != ("do_first", "action"):
                rows[path[:-2]] = rows.get(path[:-2], 0) + 1
        for row, count in rows.items():
            if count > 1:
                yield f"{dotted(row)} has {count} primary actions; make one secondary"

    def rule_actions_destructive(self, p: dict, ctx: dict) -> Iterator[str]:
        for path, action in _actions(p):
            kind = action.get("kind") or "reply"
            if action.get("style") == "destructive" and not action.get("confirm"):
                yield f"{dotted(path)}: a destructive action needs confirm"
            if kind == "open" and not action.get("url"):
                yield f"{dotted(path)}: an open action needs url"
            if kind == "copy" and action.get("value") in (None, ""):
                yield f"{dotted(path)}: a copy action needs value"
            echo = action.get("payload")
            if echo is not None and len(json.dumps(echo, ensure_ascii=False).encode()) > 1024:
                yield f"{dotted(path)}.payload is over 1 KB"

    _PAIRS = (("start", "end"), ("started_at", "ended_at"), ("starts_at", "ends_at"), ("from", "until"),
              ("depart", "arrive"), ("time", "end"))

    def rule_times_order(self, p: dict, ctx: dict) -> Iterator[str]:
        if p.get("expires_at") and p.get("as_of"):
            pair = _comparable(p["as_of"], p["expires_at"])
            if pair and pair[1] <= pair[0]:
                yield f"expires_at {p['expires_at']} isn't after as_of {p['as_of']}"
        if isinstance(p.get("stale_after"), (int, float)) and p["stale_after"] <= 0:
            yield "stale_after must be positive"
        for path, item in walk(p):
            if not isinstance(item, dict):
                continue
            for a, b in self._PAIRS:
                if a in item and b in item:
                    pair = _comparable(item[a], item[b])
                    if pair and pair[1] < pair[0]:
                        where = dotted(path)
                        yield f"{where + '.' if where else ''}{b} {item[b]} is before {a} {item[a]}"

    def rule_percent_fraction(self, p: dict, ctx: dict) -> Iterator[str]:
        for path, item in walk(p):
            if isinstance(item, dict) and item.get("format") == "percent" and isinstance(item.get("value"), (int, float)) \
                    and not isinstance(item.get("value"), bool) and abs(item["value"]) > 1.5:
                yield (f"{dotted(path)}.value {item['value']} with format percent: send {item['value'] / 100:g} "
                       f"for {item['value']:g}%")
            elif isinstance(item, dict) and path and path[-1] == "delta" and (item.get("format") or "percent") == "percent" \
                    and isinstance(item.get("value"), (int, float)) and abs(item["value"]) > 1.5:
                yield f"{dotted(path)}.value {item['value']} is a percent delta: send {item['value'] / 100:g} for {item['value']:g}%"

    _RELATIVE = re.compile(r"\b(today|tonight|tomorrow|yesterday|this (morning|afternoon|evening|week)|next week|"
                           r"in \d+ (minutes?|hours?|days?)|\d+ (minutes?|hours?|days?) ago)\b", re.IGNORECASE)
    _ABSOLUTE = re.compile(r"\b(\d{1,2}:\d{2}|\d{1,2} (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|"
                           r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{1,2}|\d{4}-\d{2}-\d{2}|"
                           r"(mon|tue|wed|thu|fri|sat|sun)[a-z]* \d{1,2})", re.IGNORECASE)

    def rule_fallback_absolute(self, p: dict, ctx: dict) -> Iterator[str]:
        if not ctx.get("agent_fallback"):
            return
        text = p.get("fallback_text") or ""
        for match in self._RELATIVE.finditer(text):
            window = text[max(0, match.start() - 40): match.end() + 40]
            if not self._ABSOLUTE.search(window):
                yield f"fallback_text says “{match.group(0)}” without a date or time beside it; it's read later"
                return

    def rule_fallback_cap(self, p: dict, ctx: dict) -> Iterator[str]:
        cap = 4000 if p.get("type") == "stack" else 2000
        text = p.get("fallback_text") or ""
        if len(text) > cap:
            yield (f"fallback_text is {len(text):,} characters; at most {cap:,}, ending “… and N more (in the "
                   f"Hermes app)” when items don't fit")

    def rule_secrets(self, p: dict, ctx: dict) -> Iterator[str]:
        from .redaction import secret_issue
        for path, text in strings(p):
            if path and path[-1] in ("type", "id", "as_of", "expires_at"):
                continue
            issue = secret_issue(text)
            if issue:
                yield f"{dotted(path) or 'a field'} {issue}; never put secrets in a widget (mask them: “•• 4242”)"

    def rule_producer(self, p: dict, ctx: dict) -> Iterator[str]:
        bot = (ctx.get("producer") or {}).get("bot")
        for path, item in walk(p):
            if path and path[-1] in ("icon", "symbol") and isinstance(item, str) and item.startswith("bot:"):
                if item[4:] != bot:
                    yield (f"{dotted(path)} {item} names another Bot; a bot: icon may only name the producer"
                           + (f" (bot:{bot})" if bot else " (this widget isn't from a Bot)"))
        if p.get("type") == "handoff":
            source = p.get("from") or {}
            if isinstance(source, dict) and source.get("bot") and source.get("bot") != bot:
                yield f"handoff.from.bot {source['bot']} must be the producer" + (f" ({bot})" if bot else "")

    def rule_groups(self, p: dict, ctx: dict) -> Iterator[str]:
        if not ctx.get("group"):
            return
        if p.get("sensitivity") == "private" or any(
                isinstance(c, dict) and c.get("sensitivity") == "private" for c in p.get("children") or []):
            yield "private widget in a group chat: private widgets stay in the person's own chat"
        needs_for = {"approval", "control", "form"}
        missing = {p.get("type")} & needs_for if not p.get("for") else set()
        missing |= {c.get("type") for c in p.get("children") or [] if isinstance(c, dict)
                    and c.get("type") in needs_for and not c.get("for") and not p.get("for")}
        if missing:
            yield f"{_or_list(sorted(missing))} in a group chat needs for: who may answer ({{\"name\": …}})"

    def rule_icon_allowlist(self, p: dict, ctx: dict) -> Iterator[str]:
        allowed = self.spec.symbols
        if not allowed:
            return
        for path, item in walk(p):
            if path and path[-1] in ("icon", "symbol", "glyph") and isinstance(item, str) and not item.startswith("bot:"):
                if item not in allowed:
                    yield (f"{dotted(path)} “{item}” isn't in the symbol allowlist; it's drawn as the default glyph"
                           + _did_you_mean(item, allowed))

    _ID_LISTS = ("items", "options", "fields", "nodes", "steps", "cards", "events", "criteria", "controls", "sides",
                 "groups", "series", "columns", "marks", "children")

    def rule_ids_unique(self, p: dict, ctx: dict) -> Iterator[str]:
        for path, item in walk(p):
            if not path or path[-1] not in self._ID_LISTS or not isinstance(item, list):
                continue
            key = "key" if path[-1] == "columns" else ("date" if path[-1] == "marks" else "id")
            seen: dict[Any, int] = {}
            for n, entry in enumerate(item):
                if isinstance(entry, dict) and entry.get(key) is not None:
                    ident = entry[key]
                    if ident in seen:
                        yield f"{dotted(path + (n,))}.{key} {_quote(ident)} is used twice"
                    seen[ident] = n

    # -- per type

    def rule_chart_series(self, p: dict, ctx: dict) -> Iterator[str]:
        xs = (p.get("x") or {}).get("values")
        if not xs:
            return
        for n, series in enumerate(p.get("series") or []):
            values = series.get("values") or []
            if len(values) != len(xs):
                yield f"series[{n}] has {len(values)} values for {len(xs)} x values"
        callout = p.get("callout")
        if callout and callout.get("x") not in xs:
            yield f"callout.x {_quote(callout.get('x'))} isn't one of the x values" + _did_you_mean(callout.get("x"), xs)
        kind = (p.get("x") or {}).get("kind")
        if kind in ("date", "time"):
            for n, value in enumerate(xs):
                parsed = _parse_time(value)
                if parsed is None or (kind == "date" and isinstance(parsed, datetime)):
                    yield f"x.values[{n}] {_quote(value)} isn't {'an ISO date' if kind == 'date' else 'an RFC 3339 time'}"
                    break
        ids = [s.get("id") for s in p.get("series") or [] if s.get("id")]
        if callout and callout.get("series") and callout["series"] not in ids:
            yield f"callout.series {_quote(callout['series'])} isn't a series id"

    def rule_verdict_safety(self, p: dict, ctx: dict) -> Iterator[str]:
        # The declared items live with the person, not in the payload; what can be checked is that a
        # safety verdict never says ok over an unknown and names each criterion once.
        if p.get("kind") != "safety":
            return
        labels = [c.get("label", "").strip().lower() for c in p.get("criteria") or []]
        for label in {l for l in labels if labels.count(l) > 1}:
            yield f"two criteria for “{label}”: one criterion per declared item"
        states = {c.get("state") for c in p.get("criteria") or []}
        outcome = (p.get("outcome") or {}).get("state")
        if "critical" in states and outcome != "critical":
            yield "a safety verdict with a critical criterion is critical"
        elif "unverified" in states and outcome not in ("unverified", "critical"):
            yield "a safety verdict with an unverified criterion is unverified"

    def rule_meter_zones(self, p: dict, ctx: dict) -> Iterator[str]:
        def check(zones: list, where: str) -> Iterator[str]:
            last_to = None
            previous_from = None
            for n, zone in enumerate(zones or []):
                start, end = zone.get("from"), zone.get("to")
                if previous_from is not None and start < previous_from:
                    yield f"{where}[{n}] starts before the zone above it; order zones by from"
                if last_to is not None and start < last_to:
                    yield f"{where}[{n - 1}] and {where}[{n}] overlap at {start:g}–{last_to:g}"
                if end is not None and end <= start:
                    yield f"{where}[{n}].to {end:g} isn't above from {start:g}"
                previous_from, last_to = start, (end if end is not None else math.inf)

        yield from check(p.get("zones"), "zones")
        for n, item in enumerate(p.get("items") or []):
            yield from check(item.get("zones"), f"items[{n}].zones")
            low, high = item.get("min", 0), item.get("max")
            target = (item.get("target") or {}).get("value")
            if isinstance(target, (int, float)) and high is not None and not (low <= target <= high):
                yield f"items[{n}].target {target:g} is outside min–max ({low:g}–{high:g})"

    def rule_calendar_range(self, p: dict, ctx: dict) -> Iterator[str]:
        start, end = _parse_time(p.get("start")), _parse_time(p.get("end"))
        seen = set()
        for n, mark in enumerate(p.get("marks") or []):
            day = _parse_time(mark.get("date"))
            if start and end and day and not (start <= day <= end):
                yield f"marks[{n}] {mark.get('date')} is outside {p.get('start')} – {p.get('end')}"
            if mark.get("date") in seen and (p.get("style") or "check") != "dot":
                yield f"marks[{n}]: a second mark for {mark.get('date')}; one mark per date"
            seen.add(mark.get("date"))

    def rule_list_counts(self, p: dict, ctx: dict) -> Iterator[str]:
        items = p.get("items") or []
        for n, group in enumerate(p.get("groups") or []):
            if group.get("count") is None:
                continue
            rows = sum(1 for i in items if i.get("group") == group.get("id"))
            if group["count"] != rows:
                yield f"groups[{n}].count {group['count']} but {rows} rows"
        for n, count in enumerate(p.get("counts") or []):
            if count.get("group"):
                rows = sum(1 for i in items if i.get("group") == count["group"])
                if count.get("value") != rows and not p.get("total"):
                    yield f"counts[{n}].value {count.get('value')} but group {count['group']} has {rows} rows"

    def rule_table_keys(self, p: dict, ctx: dict) -> Iterator[str]:
        keys = [c.get("key") for c in p.get("columns") or []]
        for n, row in enumerate(p.get("rows") or []):
            for key in row:
                if key not in keys:
                    yield f"rows[{n}] has key {_quote(key)} that isn't a column" + _did_you_mean(key, keys)
        total = p.get("total") or {}
        formats = {c.get("key"): c.get("format") or "number" for c in p.get("columns") or []}
        for key, value in total.items():
            if key not in keys:
                yield f"total has key {_quote(key)} that isn't a column" + _did_you_mean(key, keys)
            elif formats.get(key) == "text" and key != keys[0] and value not in (None, ""):
                yield f"total.{key}: the total row covers numeric columns only"

    def rule_details_emphasis(self, p: dict, ctx: dict) -> Iterator[str]:
        count = sum(1 for s in p.get("sections") or [] for f in s.get("fields") or [] if f.get("emphasis"))
        if count > 1:
            yield f"{count} emphasised fields; at most one"

    def rule_outline_size(self, p: dict, ctx: dict) -> Iterator[str]:
        total, deepest = 0, 0

        def visit(nodes: list, depth: int) -> None:
            nonlocal total, deepest
            for node in nodes or []:
                total += 1
                deepest = max(deepest, depth)
                visit(node.get("children") or [], depth + 1)

        visit(p.get("nodes") or [], 1)
        if total > 60:
            yield f"outline has {total} nodes; at most 60"
        if deepest > 4:
            yield f"outline is {deepest} levels deep; at most 4"

    def rule_entity_rating(self, p: dict, ctx: dict) -> Iterator[str]:
        rating = p.get("rating") or {}
        value, scale = rating.get("value"), rating.get("scale", 5)
        if isinstance(value, (int, float)) and value > scale:
            yield f"rating {value:g} on a scale of {scale}"

    def rule_media_mix(self, p: dict, ctx: dict) -> Iterator[str]:
        kinds = {(i.get("media") or {}).get("kind") or "image" for i in p.get("items") or []}
        if "audio" in kinds and kinds - {"audio"}:
            yield "items mix audio with images or video; one kind of media per widget"

    def rule_code_range(self, p: dict, ctx: dict) -> Iterator[str]:
        rng = p.get("range")
        if not rng:
            return
        start, end = rng.get("start"), rng.get("end")
        if end is not None and end < start:
            yield f"range {start}–{end}: end is before start"
        text = p.get("text")
        if isinstance(text, str) and end is not None and end >= start:
            lines = text.count("\n") + (0 if text.endswith("\n") else 1)
            if end - start + 1 != lines:
                yield f"range {start}–{end} is {end - start + 1} lines but text has {lines}"

    def rule_steps_titles(self, p: dict, ctx: dict) -> Iterator[str]:
        if p.get("kind") != "pipeline":
            return
        for n, step in enumerate(p.get("steps") or []):
            if len(step.get("title") or "") > 16:
                yield (f"steps[{n}] pipeline title “{step['title']}” is {len(step['title'])} characters; ≤ 16 or the "
                       f"app draws it vertically")

    def rule_status_fix(self, p: dict, ctx: dict) -> Iterator[str]:
        for n, item in enumerate(p.get("items") or []):
            if item.get("fix") and item.get("state") not in ("warning", "critical"):
                yield f"items[{n}] is {item.get('state')} but has fix; fix is for warning or critical items"

    def rule_choice_recommended(self, p: dict, ctx: dict) -> Iterator[str]:
        options = p.get("options") or []
        if sum(1 for o in options if o.get("recommended")) > 1:
            yield "two recommended options; at most one"
        if p.get("select") != "many" and any(o.get("preselected") for o in options):
            yield "preselected options need select: many"
        if p.get("style") == "times":
            times = [_parse_time(o.get("at")) for o in options if o.get("at")]
            if any(b < a for a, b in zip(times, times[1:]) if a and b):
                yield "times options aren't in time order"

    _SECRET_FIELD = re.compile(r"\b(pass(word|code|phrase)?|pin|api[ _-]?key|secret|token|private key|card number|"
                               r"credit card|cvv|cvc|security code|iban|ssn|social security)\b", re.IGNORECASE)

    def rule_form_secrets(self, p: dict, ctx: dict) -> Iterator[str]:
        for n, field in enumerate(p.get("fields") or []):
            words = " ".join(str(field.get(k) or "") for k in ("label", "placeholder", "help", "id"))
            match = self._SECRET_FIELD.search(words.replace("_", " "))
            if match:
                yield (f"fields[{n}] “{field.get('label')}” asks for a secret ({match.group(0)}); Hermes has its own "
                       f"secret request")

    def rule_approval_expiry(self, p: dict, ctx: dict) -> Iterator[str]:
        consequences = p.get("consequences") or {}
        until = consequences.get("reversible_until")
        if (p.get("subject") or {}).get("kind") == "purchase" and until and p.get("expires_at"):
            pair = _comparable(until, p["expires_at"])
            if pair and pair[1] > pair[0]:
                yield f"expires_at {p['expires_at']} is after the {until} cancellation window"

    def rule_summary_emphasis(self, p: dict, ctx: dict) -> Iterator[str]:
        for n, point in enumerate(p.get("points") or []):
            if point.get("emphasis") and not (point.get("text") or "").startswith(point["emphasis"]):
                yield f"points[{n}].emphasis isn't the start of its text"

    def rule_guide_start(self, p: dict, ctx: dict) -> Iterator[str]:
        start = p.get("start_at")
        ids = [s.get("id") for s in p.get("steps") or []]
        if start and start not in ids:
            yield f"start_at {_quote(start)} isn't a step" + _did_you_mean(start, ids)

    def rule_compare_keys(self, p: dict, ctx: dict) -> Iterator[str]:
        ids = [o.get("id") for o in p.get("options") or []]
        for n, criterion in enumerate(p.get("criteria") or []):
            for field in ("values", "scores"):
                for key in (criterion.get(field) or {}):
                    if key not in ids:
                        yield f"criteria[{n}].{field} has key {_quote(key)} that isn't an option" + _did_you_mean(key, ids)
            for key in criterion.get("best") or []:
                if key not in ids:
                    yield f"criteria[{n}].best {_quote(key)} isn't an option"
        pick = p.get("pick")
        pick_id = pick.get("option") if isinstance(pick, dict) else pick
        if pick_id is not None and pick_id not in ids:
            yield f"pick {_quote(pick_id)} isn't an option" + _did_you_mean(pick_id, ids)
        elif pick_id is not None and p.get("adjustable"):
            totals = {}
            for option in ids:
                totals[option] = sum((c.get("weight", 1)) * ((c.get("scores") or {}).get(option) or 0)
                                     for c in p.get("criteria") or [])
            if totals and any(c.get("scores") for c in p.get("criteria") or []) and \
                    totals[pick_id] < max(totals.values()):
                best = max(totals, key=totals.get)
                yield f"pick {pick_id} isn't the top weighted total ({best} is), and the comparison is adjustable"

    def rule_stack_children(self, p: dict, ctx: dict) -> Iterator[str]:
        children = p.get("children") or []
        types = [c.get("type") for c in children if isinstance(c, dict)]
        for n, child in enumerate(children):
            if not isinstance(child, dict):
                continue
            if child.get("type") == "stack":
                yield f"children[{n}] is a stack; a stack can't contain a stack"
                continue
            if child.get("type") not in self.spec.catalog:
                continue
            for issue in schema_issues(self.spec, child["type"], child, ctx.get("schema_kind", "full")):
                yield f"children[{n}] ({child['type']}): {issue}"
        refs = [c.get("id") or c.get("ref") for c in children if isinstance(c, dict)]
        for ident in {r for r in refs if r and refs.count(r) > 1}:
            yield f"children: {_quote(ident)} is used twice"
        order = []
        for n, section in enumerate(p.get("sections") or []):
            for name in section.get("children") or []:
                if name not in refs:
                    yield f"sections[{n}].children names {_quote(name)}, which isn't a child" + _did_you_mean(name, [r for r in refs if r])
                else:
                    order.append(refs.index(name))
        if order != sorted(order):
            yield "sections name the children out of order"
        if p.get("layout") == "carousel" and len(set(types)) > 1:
            yield f"a carousel holds one type; children are {', '.join(sorted(set(types)))}"
