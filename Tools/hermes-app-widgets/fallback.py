"""Generated ``fallback_text`` (payload-contract.md §3, §8.3): each primitive's "Text fallback" rule as a
template.

The text is what Telegram, Slack, the CLI, notifications and Copy show, so it stands alone: the title,
the key values formatted, states as words, absolute dates and times (it's read later), and how to
answer in words. Over the cap it keeps the first items and ends "… and N more (in the Hermes app)",
never mid-sentence. Approvals the app must sign end with ``SIGNED_SENTENCE`` instead of "Reply …".
"""
from __future__ import annotations

import re
from datetime import date, datetime
from typing import Any, Callable

CAP = 2000
STACK_CAP = 4000
SIGNED_SENTENCE = "Open the Hermes app to approve; this can't be approved by text."
_CURRENCY = {"EUR": "€", "USD": "$", "GBP": "£", "JPY": "¥", "INR": "₹", "KRW": "₩", "CNY": "¥", "ILS": "₪",
             "RUB": "₽", "TRY": "₺", "UAH": "₴", "PLN": "zł ", "BRL": "R$", "AUD": "A$", "CAD": "CA$", "NZD": "NZ$"}
_STATE_WORDS = {"ok": "OK", "info": "info", "warning": "needs attention", "critical": "critical",
                "unverified": "not verified", "pending": "pending", "stale": "out of date", "neutral": "",
                "new": "new", "removed": "removed"}


# ---- formatting


def _group(number: float, decimals: int, trim: bool = False) -> str:
    text = f"{round(number, 6):,.{decimals}f}"
    return text.rstrip("0").rstrip(".") if trim and "." in text else text


def _decimals(value: float, precision: int | None, default: int) -> int:
    if precision is not None:
        return precision
    return 0 if float(round(value, 6)).is_integer() else default


def parse_time(value: Any) -> datetime | date | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            return date.fromisoformat(text)
        return datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError:
        return None


def when(value: Any, with_day: bool = True) -> str:
    """Absolute, in the value's own offset: "Fri 16 Oct at 10:55", "Fri 16 Oct", "10:55"."""
    moment = parse_time(value)
    if moment is None:
        return str(value or "")
    if isinstance(moment, datetime):
        clock = moment.strftime("%H:%M")
        return f"{moment.strftime('%a')} {moment.day} {moment.strftime('%b')} at {clock}" if with_day else clock
    return f"{moment.strftime('%a')} {moment.day} {moment.strftime('%b')}"


def day(value: Any) -> str:
    moment = parse_time(value)
    if moment is None:
        return str(value or "")
    return f"{moment.strftime('%a')} {moment.day} {moment.strftime('%b')}"


def clock(value: Any) -> str:
    moment = parse_time(value)
    return moment.strftime("%H:%M") if isinstance(moment, datetime) else day(value)


def span(start: Any, end: Any = None) -> str:
    a, b = parse_time(start), parse_time(end)
    if isinstance(a, datetime) and isinstance(b, datetime):
        same_day = a.date() == b.date()
        return f"{when(start)}–{clock(end)}" if same_day else f"{when(start)} – {when(end)}"
    if a is not None and b is not None and a != b:
        return f"{day(start)} – {day(end)}"
    return when(start)


def seconds_words(value: Any) -> str:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return ""
    seconds = float(value)
    if seconds < 60:
        return f"{seconds:.1f} s".replace(".0 s", " s") if seconds < 10 else f"{round(seconds)} s"
    minutes, rest = divmod(round(seconds), 60)
    if minutes < 60:
        return f"{minutes} min {rest} s" if rest else f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    if hours < 48:
        return f"{hours} h {minutes} min" if minutes else f"{hours} h"
    return f"{round(hours / 24)} days"


def _bytes(value: float) -> str:
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if abs(value) < 1000 or unit == "TB":
            return f"{value:,.0f} {unit}" if unit == "bytes" else f"{value:,.1f} {unit}".replace(".0 ", " ")
        value /= 1000
    return str(value)


def money(value: float, currency: str | None, precision: int | None = None) -> str:
    symbol = _CURRENCY.get(currency or "", (currency + " ") if currency else "")
    sign = "−" if value < 0 else ""
    return f"{sign}{symbol}{_group(abs(value), _decimals(value, precision, 2))}"


def quantity(q: Any) -> str:
    """A Quantity in words; ``—`` style "unknown" for null, never 0."""
    if not isinstance(q, dict):
        return "" if q is None else str(q)
    if q.get("display"):
        return str(q["display"])
    value, fmt = q.get("value"), q.get("format") or "number"
    unit = q.get("unit")
    if value is None:
        return "unknown"
    precision = q.get("precision")
    if fmt == "text" or isinstance(value, str) and fmt in ("number", "integer", "text"):
        text = str(value)
    elif fmt in ("countdown", "datetime", "relative") and isinstance(value, str):
        text = when(value)
    elif fmt == "date":
        text = day(value)
    elif fmt == "time":
        text = clock(value)
    elif not isinstance(value, (int, float)) or isinstance(value, bool):
        text = str(value)
    elif fmt == "percent":
        text = f"{_group(value * 100, _decimals(value * 100, precision, 1))}%"
    elif fmt == "currency":
        text = money(value, q.get("currency"), precision)
    elif fmt == "duration":
        text = seconds_words(value)
    elif fmt == "bytes":
        text = _bytes(float(value))
    elif fmt == "integer":
        text = _group(round(value), 0)
    else:
        text = _group(value, _decimals(value, precision, 2), trim=precision is None)
    if unit and fmt not in ("currency", "percent"):
        text += unit if unit in ("%", "°", "°C", "°F", "′", "″") else f" {unit}"
    return text.replace("-", "−", 1) if text.startswith("-") else text


def delta(d: Any, currency: str | None = None) -> str:
    if not isinstance(d, dict) or not isinstance(d.get("value"), (int, float)):
        return ""
    value, fmt = d["value"], d.get("format") or "percent"
    if value == 0:
        text = "no change"
    else:
        sign = "+" if value > 0 else "−"
        magnitude = abs(value)
        if fmt == "percent":
            text = f"{sign}{_group(magnitude * 100, _decimals(magnitude * 100, None, 1), trim=True)}%"
        elif fmt == "currency":
            text = sign + money(magnitude, d.get("currency") or currency)
        elif fmt == "points":
            text = f"{sign}{_group(magnitude, _decimals(magnitude, None, 1))} points"
        else:
            text = f"{sign}{_group(magnitude, _decimals(magnitude, None, 2))}"
    return f"{text} {d['period']}" if d.get("period") else text


def state_word(state: Any) -> str:
    return _STATE_WORDS.get(str(state or ""), str(state or ""))


def tags(items: Any) -> str:
    labels = [t.get("label") for t in items or [] if isinstance(t, dict) and t.get("label")]
    return f" [{', '.join(labels)}]" if labels else ""


def sentence(text: str) -> str:
    text = text.strip()
    bare = text.rstrip("”\"'’)]")
    if not text or text[-1] in ".!?…:" or (bare != text and bare[-1:] in (".", "!", "?", "…")):
        return text
    return text + "."


def oxford(words: list[str], last: str = "or") -> str:
    words = [w for w in words if w]
    if len(words) <= 1:
        return "".join(words)
    if len(words) == 2:
        return f"{words[0]} {last} {words[1]}"
    return f"{', '.join(words[:-1])} {last} {words[-1]}"


# ---- capping


def fit(head: str, parts: list[str], tail: str = "", cap: int = CAP, joiner: str = " ") -> str:
    """Head, then as many parts as fit whole, then the tail; dropped parts become "… and N more"."""
    head, tail = head.strip(), tail.strip()

    def build(n: int) -> str:
        body = joiner.join(p for p in parts[:n] if p)
        more = f"… and {len(parts) - n} more (in the Hermes app)." if n < len(parts) else ""
        glue = joiner if "\n" in joiner else " "
        return glue.join(x for x in (head, body, more, tail) if x).strip()

    for n in range(len(parts), -1, -1):
        text = build(n)
        if len(text) <= cap:
            return text
    return head[:cap - 1].rstrip() + "…"


def answer_words(ids: list[str]) -> str:
    quoted = [f"“{w}”" for w in ids if w]
    return f"Reply {oxford(quoted)}." if quoted else ""


def _action_reply(payload: dict) -> str:
    labels = [a.get("label") for a in payload.get("actions") or []
              if isinstance(a, dict) and (a.get("kind") or "reply") == "reply" and a.get("label")]
    return answer_words([l.lower() for l in labels])


# ---- signing


def requires_signature(payload: dict) -> bool:
    """Approvals that cost money, can't be undone, need authentication or are transfers (§6.3)."""
    if not isinstance(payload, dict) or payload.get("type") != "approval":
        return False
    subject = payload.get("subject") or {}
    consequences = payload.get("consequences") or {}
    kind = subject.get("kind")
    known = {"purchase", "message", "post", "release", "spend", "delete", "booking", "transfer", "other"}
    if kind not in known or kind in ("transfer", "purchase", "spend"):
        return True
    if payload.get("authentication") == "required" or consequences.get("reversible") not in ("yes", "until"):
        return True
    cost = ((consequences.get("cost") or {}).get("amount") or {}).get("value")
    amount = (subject.get("amount") or {}).get("value")
    return any(isinstance(v, (int, float)) and v != 0 for v in (cost, amount))


_SENTENCE = re.compile(r".*?(?:[.!?…]+[\"”’)\]]*(?=\s|$)|$)\s*", re.S)
_INVITE = re.compile(r"\b(reply|answer|say|type|send|text)\b", re.IGNORECASE)
_APPROVE_WORD = re.compile(r"\b(approve|yes|ok|confirm)\b", re.IGNORECASE)


def sentences(text: str) -> list[str]:
    return [m.group(0) for m in _SENTENCE.finditer(text or "") if m.group(0)]


def drop_reply_invites(text: str, words: re.Pattern = _APPROVE_WORD) -> str:
    """Remove the sentences that ask for an answer in words ("Reply “approve”, “edit” or “reject”.")."""
    kept = [s for s in sentences(text) if not (_INVITE.search(s) and words.search(s))]
    return "".join(kept).strip()


def signed_fallback(text: str) -> str:
    """The stored fallback of a signed approval: no "Reply approve", and the open-the-app sentence last."""
    body = drop_reply_invites((text or "").replace(SIGNED_SENTENCE, ""))
    body = sentence(body) if body else ""
    room = CAP - len(SIGNED_SENTENCE) - 1
    if len(body) > room:
        body = body[:room - 1].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"
    return f"{body} {SIGNED_SENTENCE}".strip()


# ---- per type


def _title(payload: dict) -> str:
    title = payload.get("title") or ""
    subtitle = payload.get("subtitle")
    return f"{title} ({subtitle})" if subtitle else title


def f_metric(p: dict) -> str:
    lines = []
    for item in p.get("items") or []:
        line = f"{item.get('label')}: {quantity(item.get('value'))}"
        if item.get("target"):
            line += f" of {quantity(item['target'])}"
        extra = delta(item.get("delta"), (item.get("value") or {}).get("currency"))
        if extra:
            line += f" ({extra})"
        if item.get("note"):
            line += f", {item['note']}"
        lines.append(sentence(line))
    return fit(f"{_title(p)}:" if len(lines) > 1 else "", lines)


def f_meter(p: dict) -> str:
    lines = []
    zones = p.get("zones") or []
    for item in p.get("items") or []:
        value = item.get("value") or {}
        target = item.get("target")
        scale = target or ({"value": item["max"], "format": value.get("format"), "currency": value.get("currency")}
                           if item.get("max") is not None else None)
        line = f"{item.get('label')}: {quantity(value)}"
        if value.get("value") is None:
            line += f" ({item['note']})" if item.get("note") else ""
            lines.append(sentence(line))
            continue
        if scale and scale.get("value"):
            line += f" of {quantity(scale)}"
            if value.get("format") != "percent" and isinstance(value.get("value"), (int, float)):
                line += f" ({round(value['value'] / scale['value'] * 100)}%"
                zone = next((z for z in item.get("zones") or zones
                             if z.get("from", 0) <= value["value"] < z.get("to", float("inf"))), None)
                line += f", {zone['label'].lower()})" if zone and zone.get("label") else ")"
            if item.get("remaining") and isinstance(value.get("value"), (int, float)) and scale.get("value") >= value["value"]:
                left = dict(scale, value=scale["value"] - value["value"])
                line += f". {quantity(left)} left"
        if item.get("note"):
            line += f", {item['note']}" if item.get("remaining") else f" ({item['note']})"
        lines.append(sentence(line))
    head = p.get("headline") or ""
    note = p.get("note") or ""
    return fit(sentence(f"{p.get('title')}: {head}") if head else "", lines, sentence(note) if note else "")


def _number_label(label: str, value: str) -> str:
    """A label that carries its own number ("Prev close 238.84") with the number formatted."""
    bare = re.sub(r"\s*[-+]?[\d.,]+\s*$", "", label or "").strip()
    return f"{bare} {value}" if bare else value


def f_chart(p: dict) -> str:
    head = p.get("headline") or {}
    stats = p.get("stats") or []
    lead = _title(p) if stats else f"{p.get('title')}"
    if head:
        lead += f": {quantity(head.get('value'))}"
        if head.get("label"):
            lead += f" {head['label']}"
        if head.get("delta"):
            lead += f" ({delta(head['delta'])})"
    if stats and (p.get("x") or {}).get("kind") == "time" and p.get("as_of"):
        lead += f", {day(p['as_of'])}"
    parts = []
    if p.get("kind") == "share" or p.get("parts"):
        values = [(x.get("label"), (x.get("value") or {})) for x in p.get("parts") or []]
        total = sum(v.get("value") or 0 for _, v in values if isinstance(v.get("value"), (int, float)))
        for label, value in values:
            pct = f" ({round((value.get('value') or 0) / total * 100)}%)" if total else ""
            parts.append(f"{label}: {quantity(value)}{pct}")
        return fit(sentence(lead), [sentence("; ".join(parts))] if parts else [], sentence(p.get("note") or ""))
    xs = (p.get("x") or {}).get("values") or []
    y = p.get("y") or {}
    y_format = {"value": None, "format": y.get("format"), "unit": y.get("unit"), "currency": y.get("currency"),
                "precision": y.get("precision")}
    if p.get("target") and stats:
        t = p["target"]
        parts.append(sentence(_number_label(t.get("label") or "Target", quantity(dict(y_format, value=t.get("value"))))))
    if stats:
        # A quote: its stats are the key values (Open, High, Low, Volume), so the series isn't retold.
        words = [f"{s.get('label')} {quantity(s.get('value'))}" for s in stats]
        words = words[:1] + [w[0].lower() + w[1:] if w[:1].isupper() and not w[1:2].isupper() else w for w in words[1:]]
        parts.append(sentence(", ".join(words)))
        return fit(sentence(lead), parts, sentence(p.get("note") or ""))
    for series in p.get("series") or []:
        values = series.get("values") or []
        known = [(x, v) for x, v in zip(xs, values) if isinstance(v, (int, float))]
        if not known:
            continue
        fmt = {"value": None, "format": y.get("format"), "unit": y.get("unit"), "currency": y.get("currency"),
               "precision": y.get("precision")}
        low = min(known, key=lambda kv: kv[1])
        high = max(known, key=lambda kv: kv[1])
        first, last = known[0], known[-1]

        def label(x: str) -> str:
            return day(x) if re.fullmatch(r"\d{4}-\d{2}-\d{2}", x or "") else (when(x) if parse_time(x) else x)

        parts.append(sentence(f"{series.get('label')}: {quantity(dict(fmt, value=first[1]))} ({label(first[0])}) to "
                              f"{quantity(dict(fmt, value=last[1]))} ({label(last[0])}); low "
                              f"{quantity(dict(fmt, value=low[1]))}, high {quantity(dict(fmt, value=high[1]))}"))
    if p.get("baseline"):
        b = p["baseline"]
        label = b.get("label") or "Usual range"
        parts.append(sentence(label if re.search(r"\d", label) else f"{label}: {b.get('from')}–{b.get('to')}"))
    if p.get("target"):
        t = p["target"]
        value = quantity(dict(y_format, value=t.get("value")))
        label = t.get("label") or "Target"
        parts.append(sentence(_number_label(label, value) if re.search(r"\d", label) else f"{label}: {value}"))
    return fit(sentence(lead), parts, sentence(p.get("note") or ""))


def f_calendar(p: dict) -> str:
    head = p.get("title") or ""
    streak = p.get("streak")
    if streak:
        unit = streak.get("unit") or "day"
        head += f": {streak['current']}-{unit} streak"
        if streak.get("best") is not None:
            head += f" (best {streak['best']})"
    marks = sorted(p.get("marks") or [], key=lambda m: m.get("date") or "")
    parts = []
    missed = [day(m["date"]) for m in marks if m.get("status") == "missed"]
    if missed:
        parts.append(sentence(f"Missed {oxford(missed, 'and')}"))
    labelled = [f"{m['label']} {day(m['date'])}" + (f" ({m['note']})" if m.get("note") else "")
                for m in marks if m.get("label")]
    parts += [sentence(x) for x in labelled]
    if not parts and marks:
        done = sum(1 for m in marks if m.get("status") in (None, "done"))
        parts.append(sentence(f"{done} of {len(marks)} days marked between {day(p.get('start'))} and {day(p.get('end'))}"))
    return fit(sentence(head), parts)


def f_verdict(p: dict) -> str:
    outcome = p.get("outcome") or {}
    lead = f"{outcome.get('label') or state_word(outcome.get('state'))}"
    if outcome.get("reason"):
        lead += f": {outcome['reason']}"
    if outcome.get("score"):
        lead += f" ({outcome['score'].get('value')} of {outcome['score'].get('max')})"
    criteria = []
    for c in p.get("criteria") or []:
        line = f"{c.get('label')}: {c.get('value') or state_word(c.get('state'))}"
        how = (c.get("evidence") or {}).get("label")
        if c.get("note"):
            line += f" ({c['note']})"
        elif how:
            line += f" ({how})"
        criteria.append(sentence(line))
    tail = sentence(f"What would change it: {p['would_change']}") if p.get("would_change") else ""
    return fit(sentence(f"{p.get('title')}. {lead}"), criteria, tail)


def f_scoreboard(p: dict) -> str:
    status = {"live": "live", "final": "final", "scheduled": "scheduled", "postponed": "postponed"}.get(p.get("status"), "")
    sides = p.get("sides") or []
    scores = [f"{s.get('name')} {quantity(s.get('score')) if isinstance(s.get('score'), dict) else s.get('score')}"
              + (" (winner)" if s.get("winner") else "") for s in sides]
    lead = f"{p.get('title')}, {status}" if status else p.get("title")
    if p.get("period"):
        lead += f" at {p['period']}"
    if p.get("competition"):
        lead += f" ({p['competition']})"
    details = [sentence(f"{s.get('name')}: {s['detail']}") for s in sides if s.get("detail")]
    sig = p.get("significance") or {}
    tail = ""
    if sig:
        tail = "Significant" if sig.get("reached") else "Not significant yet"
        if sig.get("confidence"):
            tail += f" at {round(sig['confidence'] * 100)}% confidence"
        tail = sentence(tail)
    if p.get("starts_at") and p.get("status") == "scheduled":
        lead += f", starts {when(p['starts_at'])}"
    return fit(sentence(f"{lead}: {', '.join(scores)}"), details, " ".join(x for x in (tail, sentence(p.get("note") or "")) if x))


def _list_row(item: dict) -> str:
    line = str(item.get("title") or "")
    if item.get("rank") is not None:
        line = f"{item['rank']}. {line}"
    if item.get("subtitle"):
        line += f" — {item['subtitle']}"
    if item.get("value"):
        line += f": {quantity(item['value'])}"
    extra = []
    if item.get("previous"):
        extra.append(f"was {quantity(item['previous'])}")
    if item.get("delta"):
        extra.append(delta(item["delta"]))
    movement = item.get("movement") or {}
    if movement.get("new"):
        extra.append("new")
    elif movement.get("previous") is not None and item.get("rank") is not None:
        move = movement["previous"] - item["rank"]
        extra.append(f"{'▲' if move > 0 else '▼'} {abs(move)}, was {movement['previous']}" if move else "no change")
    if item.get("at"):
        extra.append(when(item["at"]))
    if extra:
        line += f" ({', '.join(extra)})"
    return line + tags(item.get("tags"))


_SEVERITY = {"critical": 0, "warning": 1, "unverified": 2, "pending": 3, "info": 4, "stale": 5, "ok": 6, None: 7}


def f_list(p: dict) -> str:
    items = p.get("items") or []
    counts = p.get("counts") or []
    head = p.get("title") or ""
    if p.get("subtitle"):
        head += f", {p['subtitle']}"
    if counts:
        head += ": " + ", ".join(f"{c.get('value')} {c.get('label')}" for c in counts)
    elif items:
        noun = p.get("noun") or ("item" if len(items) == 1 else "items")
        head += f": {p.get('total') or len(items)} {noun}"
    if not items:
        return sentence(f"{head}. {p.get('empty_text') or 'Nothing to show.'}")
    groups = p.get("groups") or []
    parts = []
    if groups:
        order = [None] + [g.get("id") for g in groups]
        titles = {g.get("id"): g.get("title") for g in groups}
        for gid in order:
            rows = [i for i in items if i.get("group") == gid]
            if not rows:
                continue
            rows.sort(key=lambda r: _SEVERITY.get(r.get("state"), 7))
            text = "; ".join(_list_row(r) for r in rows)
            parts.append(sentence(f"{titles[gid]}: {text}" if gid else text))
    else:
        rows = sorted(items, key=lambda r: _SEVERITY.get(r.get("state"), 7)) if p.get("layout") != "ranked" else items
        parts = [sentence(_list_row(r)) for r in rows]
    return fit(sentence(head), parts, _action_reply(p))


def f_checklist(p: dict) -> str:
    items = p.get("items") or []
    done = sum(1 for i in items if i.get("checked"))
    head = f"{p.get('title')} ({done} of {len(items)})" if items else f"{p.get('title')}"
    if not items:
        return sentence(f"{head}. {p.get('empty_text') or 'Nothing to tick.'}")

    def row(i: dict) -> str:
        line = f"[{'x' if i.get('checked') else ' '}] {i.get('label')}"
        if i.get("detail"):
            line += f", {i['detail']}"
        if i.get("due"):
            line += f" (due {when(i['due'])})"
        return line + tags(i.get("tags"))

    groups = p.get("groups") or []
    parts = []
    if groups:
        titles = {g.get("id"): g.get("title") for g in groups}
        for gid in [None] + [g.get("id") for g in groups]:
            rows = [i for i in items if i.get("group") == gid]
            if rows:
                text = "; ".join(row(i) for i in rows)
                parts.append(sentence(f"{titles[gid]} — {text}" if gid else text))
    else:
        parts = [sentence(row(i)) for i in items]
    return fit(f"{head}:", parts, "Reply with what's done (“got lemons”).")


def _cell(value: Any, column: dict) -> str:
    if isinstance(value, dict):
        if value.get("display"):
            return str(value["display"])
        value = value.get("value")
    if value is None:
        return "—"
    fmt = column.get("format") or ("number" if isinstance(value, (int, float)) else "text")
    if fmt == "delta":
        return delta({"value": value, "format": column.get("delta_format") or "percent"}, column.get("currency"))
    if fmt == "text" or isinstance(value, str) and fmt not in ("date", "time", "datetime", "relative", "countdown"):
        return str(value)
    return quantity({"value": value, "format": fmt, "currency": column.get("currency"), "unit": column.get("unit"),
                     "precision": column.get("precision")})


def f_table(p: dict) -> str:
    columns = p.get("columns") or []
    rows = p.get("rows") or []
    if not rows:
        return sentence(f"{_title(p)}. {p.get('empty_text') or 'Nothing to show.'}")
    first, rest = (columns[0], columns[1:]) if columns else ({}, [])

    def line(row: dict) -> str:
        cells = [f"{_cell(row.get(c['key']), c)} {c.get('label', '').lower()}".strip()
                 if c.get("format") not in ("delta",) else f"({_cell(row.get(c['key']), c)})"
                 for c in rest if c.get("key") in row]
        text = " ".join(x for x in [", ".join(x for x in cells if not x.startswith("(")),
                                     " ".join(x for x in cells if x.startswith("("))] if x)
        return f"{_cell(row.get(first.get('key')), first)}: {text}"

    parts = [line(r) + ";" for r in rows]
    if parts:
        parts[-1] = parts[-1].rstrip(";") + "."
    tail = sentence(f"Total: {line(p['total']).split(': ', 1)[-1]}") if p.get("total") else ""
    return fit(f"{_title(p)}:", parts, tail)


def _field_value(field: dict) -> str:
    value = field.get("value")
    if isinstance(value, dict) and value.get("format") in ("relative", "countdown") and field.get("detail"):
        return str(field["detail"])
    text = quantity(value) if isinstance(value, dict) else ("—" if value is None else str(value))
    if field.get("detail"):
        text += f" ({field['detail']})"
    return text


def f_details(p: dict) -> str:
    parts = []
    for section in p.get("sections") or []:
        fields = "; ".join(f"{f.get('label')} {_field_value(f)}" for f in section.get("fields") or [])
        parts.append(sentence(f"{section['title']}: {fields}" if section.get("title") else fields))
    return fit(f"{_title(p)}:", parts, _action_reply(p))


_MARKS = {"done": "[x]", "running": "[~]", "waiting": "[ ]", "failed": "[!]", "blocked": "[!]", "unknown": "[?]",
          "skipped": "[-]"}


def f_outline(p: dict) -> str:
    rows: list[str] = []
    files = p.get("mode") == "files"

    def walk(nodes: list, depth: int) -> None:
        for node in nodes or []:
            label = node.get("label") or ""
            if files:
                line = f"{label} ({node['change']})" if node.get("change") else label
            else:
                mark = _MARKS.get(node.get("state")) if node.get("state") else ""
                line = f"{mark} {label}".strip()
            if node.get("detail"):
                line += f" ({node['detail']})"
            rows.append("  " * depth + line)
            walk(node.get("children") or [], depth + 1)

    walk(p.get("nodes") or [], 0)
    done = sum(1 for r in rows if r.lstrip().startswith("[x]"))
    head = f"{p.get('title')} ({done} of {len(rows)})" if not files else f"{p.get('title')} ({len(rows)})"
    return fit(f"{head}:", [r + ";" for r in rows[:-1]] + [rows[-1] + "."] if rows else [], joiner="\n")


def f_diff(p: dict) -> str:
    if p.get("mode") == "text":
        text = p.get("text") or {}
        return fit(sentence(_title(p)), [f"Before: “{text.get('before', '')}”", f"After: “{text.get('after', '')}”"])
    parts = []
    for row in p.get("rows") or []:
        before = quantity(row["before"]) if isinstance(row.get("before"), dict) else row.get("before")
        after = quantity(row["after"]) if isinstance(row.get("after"), dict) else row.get("after")
        change = row.get("change")
        if change == "added":
            line = f"{row.get('label')}: added {after}"
        elif change == "removed":
            line = f"{row.get('label')}: removed (was {before})"
        else:
            line = f"{row.get('label')}: {before if before is not None else '—'} → {after if after is not None else '—'}"
        if row.get("delta"):
            line += f" ({delta(row['delta'])})"
        parts.append(line + ";")
    if parts:
        parts[-1] = parts[-1][:-1] + "."
    else:
        return sentence(f"{_title(p)}. {p.get('empty_text') or 'Nothing changed.'}")
    return fit(f"{_title(p)}:", parts)


def f_timeline(p: dict) -> str:
    parts = []
    for event in p.get("events") or []:
        state = event.get("state")
        word = {"current": "now: ", "upcoming": "expected: ", "critical": "failed: ", "warning": "warning: ",
                "cancelled": "cancelled: ", "unverified": "not verified: "}.get(state, "")
        at = span(event.get("time"), event.get("end")) if event.get("end") else when(event.get("time"))
        line = f"{at} — {word}{event.get('title')}"
        if event.get("detail"):
            line += f" ({event['detail']})"
        parts.append(sentence(line))
    if not parts:
        return sentence(f"{_title(p)}. {p.get('empty_text') or 'Nothing yet.'}")
    return fit(sentence(_title(p)), parts)


def f_agenda(p: dict) -> str:
    events = p.get("events") or []
    head = day(p.get("date")) if p.get("view") != "days" else f"{day(p.get('date'))}, {p.get('span', 7)} days"
    all_day = [e for e in events if e.get("all_day")]
    timed = sorted((e for e in events if not e.get("all_day")), key=lambda e: e.get("start") or "")
    parts = []
    if all_day:
        parts.append(sentence("All day: " + "; ".join(e.get("title", "") for e in all_day)))
    previous_end = None
    for event in timed:
        start, end = event.get("start"), event.get("end")
        if p.get("complete") and previous_end and start and previous_end < start and \
                str(previous_end)[:10] == str(start)[:10]:
            parts.append(sentence(f"Free {clock(previous_end)}–{clock(start)}"))
        times = f"{clock(start)}–{clock(end)}" if end else clock(start)
        if p.get("view") == "days":
            times = f"{day(start)} {times}"
        extra = []
        if (event.get("place") or {}).get("name"):
            extra.append(event["place"]["name"])
        people = [x.get("name") for x in event.get("people") or [] if x.get("name")]
        if people:
            extra.append("with " + oxford(people[:3] + ([f"{len(people) - 3} more"] if len(people) > 3 else []), "and"))
        if event.get("note"):
            extra.append(event["note"])
        state = event.get("state")
        line = f"{times} {event.get('title')}"
        if extra:
            line += f" ({'; '.join(extra)})"
        if state in ("tentative", "cancelled", "invited"):
            line += f", {'not answered' if state == 'invited' else state}"
        parts.append(sentence(line))
        previous_end = end or previous_end
    if not events:
        return sentence(f"{p.get('title')}, {head}. {p.get('empty_text') or 'Nothing scheduled.'}")
    return fit(sentence(f"{p.get('title')}, {head}" if p.get("title") not in (None, "") else head), parts)


def f_entity(p: dict) -> str:
    kind = {"pull_request": "Pull request", "listing": "Listing", "product": "Product", "person": "Person",
            "place": "Place", "event": "Event", "file": "File", "link": "Link", "review": "Review"}.get(p.get("kind"), "")
    lead = f"{kind}: {p.get('name')}" if kind else str(p.get("name"))
    if p.get("eyebrow"):
        lead += f" — {p['eyebrow']}"
    facts = [sentence(lead)]
    if p.get("detail"):
        facts.append(sentence(p["detail"]))
    price = p.get("price")
    if price:
        text = quantity(price.get("amount"))
        if price.get("per"):
            text += f" {price['per']}"
        if price.get("was"):
            text += f" (was {quantity(price['was'])}" + (f", {delta(price['change'])}" if price.get("change") else "") + ")"
        lowest = price.get("lowest")
        if lowest:
            low, now = (lowest.get("amount") or {}).get("value"), (price.get("amount") or {}).get("value")
            word = lowest.get("label", "").lower()
            text += f": {word}" if low == now else f"; {word}: {quantity(lowest.get('amount'))}"
        elif len(price.get("history") or []) >= 2:
            history = [v for v in price["history"] if isinstance(v, (int, float))]
            if history and min(history) != max(history):
                fmt = dict(price.get("amount") or {})
                text += (f"; between {quantity(dict(fmt, value=min(history)))} and "
                         f"{quantity(dict(fmt, value=max(history)))} recently")
        facts.append(sentence(text))
    if p.get("rating"):
        r = p["rating"]
        facts.append(sentence(f"Rated {r.get('value')} of {r.get('scale', 5)}" + (f" ({r['count']:,} ratings)" if r.get("count") else "")))
    if p.get("when"):
        facts.append(sentence(span(p["when"].get("start"), p["when"].get("end"))))
    if p.get("place"):
        place = p["place"]
        facts.append(sentence(", ".join(x for x in (place.get("name"), place.get("address")) if x)))
    pr = p.get("pull_request")
    if pr:
        checks = pr.get("checks") or {}
        reviews = pr.get("reviews") or {}
        bits = [f"{pr.get('repo')}#{pr.get('number')}", pr.get("state") or "", f"checks {checks.get('state')}"]
        if checks.get("failing"):
            bits.append("failing: " + ", ".join(checks["failing"]))
        if reviews.get("state"):
            bits.append(f"reviews {reviews['state'].replace('_', ' ')}")
        facts.append(sentence(", ".join(b for b in bits if b)))
    attributes = [f"{a.get('label')}" + (f" {a['value']}" if a.get("value") else "") for a in p.get("attributes") or []]
    if attributes:
        facts.append(sentence(", ".join(attributes)))
    if p.get("tags"):
        facts.append(sentence(", ".join(t.get("label", "") for t in p["tags"])))
    if p.get("body"):
        facts.append(f"“{p['body']}”")
    if p.get("note"):
        facts.append(sentence(p["note"]))
    if p.get("gone"):
        facts.append("No longer available.")
    url = p.get("url")
    tail = url if isinstance(url, str) and url.startswith("https://") else ""
    return fit(facts[0], facts[1:], tail)


def f_media(p: dict) -> str:
    items = p.get("items") or []
    parts = []
    for item in items:
        media = item.get("media") or {}
        kind = media.get("kind") or "image"
        what = item.get("caption") or media.get("alt") or ""
        length = f", {seconds_words(media['duration'])}" if media.get("duration") else ""
        label = {"image": "photo", "video": "video", "audio": "audio"}.get(kind, kind)
        line = f"{what} ({label}{length})"
        if item.get("transcript"):
            line += f": “{item['transcript']}”"
        parts.append(line + ";")
    if parts:
        parts[-1] = parts[-1][:-1] + "."
    count = len(items)
    noun = "photo" if all((i.get("media") or {}).get("kind", "image") == "image" for i in items) else "item"
    return fit(f"{p.get('title')}, {count} {noun}{'s' if count != 1 else ''}:", parts)


def f_code(p: dict) -> str:
    title = p.get("title") or ""
    if p.get("path"):
        title += f" ({p['path']})"
    tail = ""
    result = p.get("result")
    if result:
        tail = f"{result.get('label') or state_word(result.get('state'))}"
        if result.get("exit_code") is not None:
            tail += f", exit code {result['exit_code']}"
        if result.get("duration") is not None and not result.get("label"):
            tail += f", in {seconds_words(result['duration'])}"
        if result.get("output"):
            tail += f": {result['output']}"
        tail = sentence(tail)
    if p.get("kind") == "log" or p.get("lines"):
        counts = p.get("counts") or {}
        summary = ", ".join(f"{counts[k]} {k}{'s' if counts[k] != 1 else ''}" for k in ("error", "warning") if counts.get(k))
        lines = []
        for line in (p.get("lines") or [])[-40:]:
            at = clock(line["at"]) + " " if line.get("at") else ""
            repeat = f" (×{line['repeat']})" if line.get("repeat", 1) > 1 else ""
            lines.append(f"{at}{(line.get('level') or 'info').upper()} {line.get('text', '')}{repeat}")
        body = "```\n" + "\n".join(lines) + "\n```" if lines else ""
        head = f"{title}{': ' + summary if summary else ''}:"
        text = "\n".join(x for x in (head, body, tail) if x)
        while len(text) > CAP and len(lines) > 1:
            lines.pop(0)
            body = "```\n… earlier lines in the Hermes app\n" + "\n".join(lines) + "\n```"
            text = "\n".join(x for x in (head, body, tail) if x)
        return text[:CAP]
    language = (p.get("language") or "").lower()
    code = p.get("text") or ""
    command = f"$ {p['command']}\n" if p.get("command") else ""
    head = f"{title}:"
    room = CAP - len(head) - len(tail) - len(language) - 12 - len(command)
    if len(code) > room:
        code = code[:max(room - 40, 0)].rsplit("\n", 1)[0] + "\n… (the rest is in the Hermes app)"
    return "\n".join(x for x in (head, f"```{language}\n{command}{code}\n```", tail) if x)


def f_sources(p: dict) -> str:
    items = p.get("items") or []
    trust = {"primary": "primary source", "secondary": "secondary", "unverified": "not confirmed", "retracted": "retracted"}
    if p.get("layout") == "quote" and items:
        s = items[0]
        tail = f"— {s.get('title')}" + (f", {s['site']}" if s.get("site") else "") + (f": {s['url']}" if str(s.get("url", "")).startswith("https://") else "")
        return fit(f"“{s.get('excerpt', '')}”", [], tail)
    parts = []
    for n, s in enumerate(items, 1):
        line = f"[{n}] {s.get('title')}"
        if s.get("site"):
            line += f" — {s['site']}"
        if s.get("published"):
            line += f", {day(s['published'])}"
        line += f" ({trust.get(s.get('trust'), s.get('trust'))})"
        if str(s.get("url", "")).startswith("https://"):
            line += f": {s['url']}"
        parts.append(line)
    if not parts:
        return sentence(f"{p.get('title')}. {p.get('empty_text') or 'No sources.'}")
    return fit(f"{p.get('title')}:", parts)


def f_weather(p: dict) -> str:
    unit = "°C" if p.get("unit") != "fahrenheit" else "°F"
    place = (p.get("place") or {}).get("name") or p.get("title")
    now = p.get("now") or {}
    words = (now.get("label") or (now.get("condition") or "").replace("-", " ")).lower()

    def deg(v: Any) -> str:
        return "unknown" if v is None else f"{round(v)}°"

    lead = f"{place}"
    moment = parse_time(p.get("as_of"))
    if isinstance(moment, datetime):
        lead += f", {moment.strftime('%A')}"
    if now:
        lead += f": {deg(now.get('temp'))[:-1] + unit if now.get('temp') is not None else 'unknown'}"
        if words:
            lead += f" and {words}"
        if now.get("feels") is not None:
            lead += f" (feels {deg(now['feels'])})"
        if now.get("high") is not None:
            lead += f", high {deg(now['high'])}"
        if now.get("low") is not None:
            lead += f", low {deg(now['low'])}"
    parts = []
    # An official warning leads: before the hours, the days and the tip (weather.md, variant Alert).
    for alert in p.get("alerts") or []:
        title = alert.get("title") or ""
        if alert.get("from") and alert.get("until"):
            title += f", {clock(alert['from'])}–{clock(alert['until'])}" if day(alert["from"]) == day(alert["until"]) \
                else f", {when(alert['from'])} – {when(alert['until'])}"
        elif alert.get("until"):
            title += f", until {when(alert['until'])}"
        prefix = "Warning: " if alert.get("severity") == "critical" else ""
        parts.append(sentence(f"{prefix}{title} ({alert.get('issuer')})"))
    rainy = [h for h in p.get("hours") or [] if (h.get("precip_chance") or 0) >= 0.4]
    if rainy:
        parts.append(sentence("Rain likely at " + ", ".join(f"{clock(h['at'])} ({round(h['precip_chance'] * 100)}%)" for h in rainy[:4])))
    days = [f"{day(d.get('date'))[:3]} {deg(d.get('low'))[:-1]}–{deg(d.get('high'))}{unit[-1]}"
            + (f", rain {round(d['precip_chance'] * 100)}%" if (d.get("precip_chance") or 0) >= 0.3 else "")
            for d in p.get("days") or []]
    if days:
        parts.append(sentence("; ".join(days)))
    if p.get("tip"):
        parts.append(sentence(p["tip"].get("text", "")))
    source = (p.get("source") or {}).get("name")
    tail = f"({source}, {clock(p.get('as_of'))})" if source else ""
    return fit(sentence(lead), parts, tail)


_FLIGHT_STATE = {"scheduled": "scheduled", "boarding": "boarding", "departed": "departed", "in_air": "in the air",
                 "landed": "landed", "arrived": "arrived", "delayed": "delayed", "cancelled": "cancelled",
                 "diverted": "diverted"}


def _minutes_off(scheduled: Any, actual: Any) -> str:
    a, b = parse_time(scheduled), parse_time(actual)
    if not isinstance(a, datetime) or not isinstance(b, datetime):
        return ""
    minutes = round((b - a).total_seconds() / 60)
    if minutes == 0:
        return "on time"
    return f"{abs(minutes)} minute{'s' if abs(minutes) != 1 else ''} {'early' if minutes < 0 else 'late'}"


def f_flight(p: dict) -> str:
    """A flight (route mode flight): number and cities, the state, the gate and time it left (or
    leaves), then landing: terminal, time in the arrival city's own time, early or late, baggage."""
    flight = p.get("flight") or {}
    depart, arrive = flight.get("depart") or {}, flight.get("arrive") or {}
    origin = (p.get("from") or {}).get("name") or depart.get("city") or depart.get("airport")
    destination = (p.get("to") or {}).get("name") or arrive.get("city") or arrive.get("airport")
    state = flight.get("state")
    lead = " ".join(x for x in (flight.get("number"), f"{origin} → {destination}") if x)
    leaves = depart.get("scheduled") or (p.get("from") or {}).get("time")
    if leaves:
        lead += f", {day(leaves)}"
    status = (p.get("status") or {}).get("label") or _FLIGHT_STATE.get(state, "")
    gone = state in ("departed", "in_air", "landed", "arrived")
    gate = f"gate {depart['gate']}" if depart.get("gate") else ""
    if gone:
        left_at = depart.get("actual") or depart.get("estimated") or depart.get("scheduled")
        detail = " ".join(x for x in ("left", gate, f"at {clock(left_at)}" if left_at else "") if x)
    elif state == "cancelled":
        detail = ""
    else:
        leaves_at = depart.get("estimated") or depart.get("scheduled")
        detail = " ".join(x for x in ("leaves", f"terminal {depart['terminal']}," if depart.get("terminal") else "",
                                      gate, f"at {clock(leaves_at)}" if leaves_at else "") if x)
        off = _minutes_off(depart.get("scheduled"), depart.get("estimated"))
        if off and off != "on time":
            detail += f" ({off})"
    lead += f": {status[0].lower() + status[1:] if status else ''}" + (f", {detail}" if detail else "")
    parts = []
    if state not in ("cancelled", "diverted"):
        lands_at = arrive.get("actual") or arrive.get("estimated") or arrive.get("scheduled")
        if lands_at:
            verb = "Landed" if state in ("landed", "arrived") else "Landing"
            where = f" at Terminal {arrive['terminal']}" if arrive.get("terminal") else ""
            local = ""
            a, b = parse_time(leaves), parse_time(lands_at)
            if isinstance(a, datetime) and isinstance(b, datetime) and a.utcoffset() != b.utcoffset():
                local = f" {arrive.get('city') or destination} time"
            text = f"{verb}{where} at {clock(lands_at)}{local}"
            off = _minutes_off(arrive.get("scheduled"), lands_at)
            if off and lands_at != arrive.get("scheduled"):
                text += f", {off}"
            if arrive.get("baggage"):
                text += f"; baggage belt {arrive['baggage']}"
            parts.append(sentence(text))
    for change in flight.get("changes") or []:
        parts.append(sentence(change))
    for alert in p.get("alerts") or []:
        parts.append(sentence(alert.get("text", "")))
    return fit(sentence(lead), parts)


def f_route(p: dict) -> str:
    if p.get("mode") == "flight" and p.get("flight"):
        return f_flight(p)
    to = (p.get("to") or {}).get("name")
    lead = f"To {to}"
    origin = p.get("from") or {}
    if p.get("leave_by"):
        lead += f": leave {origin.get('name', '')} at {clock(p['leave_by'])}".replace("  ", " ")
    lead += f", {seconds_words(p.get('duration'))}"
    if (p.get("to") or {}).get("time"):
        lead += f", arrive {clock(p['to']['time'])}"
    parts = []
    status = p.get("status")
    if status:
        parts.append(sentence(status.get("label", "")))
    legs = []
    for leg in p.get("legs") or []:
        text = leg.get("label") or leg.get("mode")
        if leg.get("line") and leg["line"] not in str(text):
            text = f"{leg['line']}: {text}"
        bits = []
        if leg.get("depart"):
            bits.append(f"at {clock(leg['depart'])}")
        if leg.get("stops"):
            bits.append(f"{leg['stops']} stops")
        if leg.get("duration") is not None:
            bits.append(seconds_words(leg["duration"]))
        legs.append(f"{text} ({', '.join(bits)})" if bits else text)
    if legs:
        parts.append(sentence("; ".join(legs)))
    for alert in p.get("alerts") or []:
        parts.append(sentence(alert.get("text", "")))
    return fit(sentence(lead), parts)


def f_pass(p: dict) -> str:
    status = next((f.get("value") for f in p.get("fields") or [] if f.get("label", "").lower() == "status"), None)
    lead = p.get("title") or ""
    if status:
        lead += f", {status.lower()}"
    trip = p.get("trip")
    if trip:
        a, b = trip.get("from") or {}, trip.get("to") or {}

        def stop(x: dict) -> str:
            name = x.get("name", "")
            if x.get("code"):
                name += f" ({x['code']})"
            return name + (f" {clock(x['time'])}" if x.get("time") else "")

        lead += f": {stop(a)} → {stop(b)}"
    event = p.get("event")
    if event:
        lead += f": {event.get('name')}" + (f", {event['venue']}" if event.get("venue") else "") + \
                (f", {when(event['starts'])}" if event.get("starts") else "")
    fields = [f"{f.get('label', '').capitalize() if f.get('label', '').isupper() else f.get('label')} {f.get('value')}"
              for f in p.get("fields") or [] if f.get("label", "").lower() != "status"]
    parts = [sentence(", ".join(fields))] if fields else []
    tail_bits = [p.get("holder") or ""]
    if p.get("reference"):
        tail_bits.append(f"{(p['reference'].get('label') or 'booking').lower()} {p['reference'].get('value')}")
    tail = sentence(", ".join(b for b in tail_bits if b)) if any(tail_bits) else ""
    tail = " ".join(x for x in (tail, "The pass is in the Hermes app.") if x)
    return fit(sentence(lead), parts, tail)


def f_status(p: dict) -> str:
    items = p.get("items") or []
    reply = _action_reply(p)

    def metrics(item: dict) -> str:
        values = [f"{m.get('label')} {quantity(m.get('value'))}" for m in item.get("metrics") or []]
        return f" ({', '.join(values)})" if values else ""

    if len(items) == 1:
        i = items[0]
        line = f"{i.get('name')}: {i.get('headline') or state_word(i.get('state'))}"
        if i.get("detail"):
            line = sentence(line) + " " + i["detail"].rstrip(".")
        line += metrics(i)
        parts = [sentence(line)]
        if i.get("fix"):
            parts.append(sentence(f"One thing to fix: {i['fix'][0].lower() + i['fix'][1:]}"))
        return fit(parts[0], parts[1:], reply)
    healthy = [i for i in items if i.get("state") == "ok"]
    problems = sorted((i for i in items if i.get("state") != "ok"), key=lambda i: _SEVERITY.get(i.get("state"), 7))
    head = f"{p.get('title')}: {len(healthy)} of {len(items)} healthy"
    parts = [sentence(f"{i.get('name')} {i.get('headline') or state_word(i.get('state'))}"
                      + (f": {i['detail']}" if i.get("detail") else "") + metrics(i)) for i in problems]
    if healthy:
        names = oxford([i.get("name", "") for i in healthy], "and")
        parts.append(sentence(f"{names} {'is' if len(healthy) == 1 else 'are'} healthy"))
    return fit(sentence(head), parts, reply)


def f_steps(p: dict) -> str:
    steps = p.get("steps") or []
    result = p.get("result") or {}
    lead = p.get("title") or ""
    if result.get("text"):
        lead += f": {result['text']}"
    parts = []
    for s in steps:
        state = s.get("state")
        word = {"done": "passed", "failed": "failed", "running": "running", "waiting": "waiting",
                "skipped": "was skipped", "blocked": "is blocked", "unknown": "unknown"}.get(state, state)
        line = f"{s.get('title')} {word}"
        if s.get("duration") is not None and state in ("done", "failed"):
            line += f" {'in' if state == 'done' else 'after'} {seconds_words(s['duration'])}"
        if s.get("progress") is not None and state == "running":
            line += f" ({round(s['progress'] * 100)}%)"
        if s.get("detail"):
            line += f": {s['detail']}"
        parts.append(line + ";")
    if parts:
        parts[-1] = parts[-1][:-1] + "."
    tail = sentence(result["detail"]) if result.get("detail") and result.get("detail_style") != "code" else ""
    return fit(sentence(lead), parts, tail)


def f_alert(p: dict) -> str:
    severity = (p.get("severity") or "").capitalize()
    status = p.get("status") or ("resolved" if p.get("ended_at") else "ongoing")
    lead = f"{severity}, {status}: {p.get('headline')}"
    parts = []
    if p.get("impact"):
        parts.append(sentence(f"Impact: {p['impact']}"))
    if p.get("started_at"):
        parts.append(sentence(f"Started {when(p['started_at'])}"))
    for line in p.get("timeline") or []:
        parts.append(sentence(f"{clock(line.get('at'))} {line.get('text')}"))
    if p.get("next"):
        parts.append(sentence(f"Next: {p['next']}"))
    return fit(sentence(lead), parts, "Reply “acknowledge” when you've seen it." if not p.get("acknowledged") else "")


def f_choice(p: dict) -> str:
    options = p.get("options") or []
    question = p.get("question") or p.get("title") or ""
    if p.get("style") == "suggestions":
        return fit("You could ask next:", [], oxford([f"“{o.get('label')}”" for o in options]) + ".")
    if p.get("answer"):
        chosen = [o.get("label") for o in options if o.get("id") in (p["answer"].get("selected") or [])]
        if p["answer"].get("other"):
            chosen.append(f"“{p['answer']['other']}”")
        return sentence(f"{question} Answered: {oxford(chosen, 'and')}")
    parts = []
    for n, o in enumerate(options, 1):
        line = f"{n}) {o.get('label')}"
        if o.get("at"):
            line = f"{n}) {when(o['at'])}" if not o.get("label") else line
        if o.get("detail"):
            line += f", {o['detail']}"
        if o.get("recommended"):
            line += " (recommended)"
        parts.append(sentence(line))
    many = p.get("select") == "many"
    tail = "Reply with the numbers or names of the ones you want." if many else "Reply with your choice."
    if p.get("style") == "rating":
        tail = "Reply with your rating."
    return fit(question if question.endswith("?") else sentence(question), parts, tail)


def f_form(p: dict) -> str:
    fields = p.get("fields") or []
    if p.get("submitted"):
        values = [f"{f.get('label')}: {p['submitted'].get(f.get('id'), '—')}" for f in fields]
        return fit(sentence(p.get("title") or ""), [sentence("; ".join(values))])
    lead = p.get("intro") or f"{p.get('title')}: I need"
    items = []
    for f in fields:
        default = f.get("default")
        item = f.get("label", "").lower() if lead.endswith("need") else f.get("label", "")
        if default not in (None, ""):
            if f.get("kind") == "choice":
                default = next((o.get("label") for o in f.get("options") or [] if o.get("id") == default), default)
            elif f.get("kind") in ("date", "datetime", "time"):
                default = when(default) if f.get("kind") != "time" else default
            elif isinstance(default, bool):
                default = "yes" if default else "no"
            item += f" ({default}?)"
        items.append(item)
    text = sentence(f"{lead.rstrip('.:')}: {oxford(items, 'and')}") if items else sentence(lead)
    return fit(text, [], "Reply with your answers.")


def f_approval(p: dict) -> str:
    subject = p.get("subject") or {}
    consequences = p.get("consequences") or {}
    lead = f"{p.get('title')}, needs your OK"
    facts = []
    head = " ".join(x for x in (subject.get("verb"), subject.get("summary")) if x)
    message = subject.get("message")
    if message:
        to = (message.get("to") or {}).get("name")
        head = f"{subject.get('verb', 'Send')} to {to} on {message.get('channel')}: “{message.get('text', '')}”"
        if message.get("translation"):
            head += f" ({message['translation']})"
    if subject.get("amount"):
        head += f", {quantity(subject['amount'])}"
    if head:
        facts.append(sentence(head))
    items = [f"{i.get('label')}" + (f" {quantity(i['value'])}" if i.get("value") else "") for i in subject.get("items") or []]
    if items:
        facts.append(sentence("; ".join(items)))
    if subject.get("change"):
        change = subject["change"]
        facts.append(sentence(f"{change.get('label') or 'Change'}: {quantity(change.get('from'))} → {quantity(change.get('to'))}"))
    cost = consequences.get("cost")
    if cost:
        line = f"Costs {quantity(cost.get('amount'))}"
        if cost.get("recurring") and cost["recurring"] != "once":
            line += f" {cost['recurring']}"
        if cost.get("method"):
            line += f" from {cost['method']}"
        facts.append(sentence(line))
    if consequences.get("affects"):
        facts.append(sentence("Affects " + "; ".join(consequences["affects"])))
    reversible = consequences.get("reversible")
    if reversible == "no":
        facts.append("It can't be undone.")
    elif reversible == "until" and consequences.get("reversible_until"):
        facts.append(sentence(f"It can be undone until {when(consequences['reversible_until'])}"))
    if consequences.get("undo_note"):
        facts.append(sentence(consequences["undo_note"]))
    if p.get("expires_at"):
        facts.append(sentence(f"This request expires {when(p['expires_at'])}"))
    if p.get("resolution"):
        r = p["resolution"]
        return fit(sentence(f"{p.get('title')}: {r.get('message') or r.get('state')}"), [])
    if requires_signature(p):
        return fit(sentence(lead + ":"), facts, SIGNED_SENTENCE, cap=CAP)
    return fit(sentence(lead + ":"), facts, "Reply “approve”, “edit” or “reject”.")


def f_receipt(p: dict) -> str:
    undone = p.get("undone")
    if undone:
        refund = undone.get("refund")
        text = undone.get("headline", "")
        if refund:
            text += f": {quantity(refund.get('amount'))} refunded" + (f" to {refund['to']}" if refund.get("to") else "") + \
                    (f" {refund['when']}" if refund.get("when") else "")
        return sentence(text)
    lead = p.get("headline") or p.get("title") or ""
    facts = [f"{f.get('label')} {quantity(f.get('value'))}" + (f" ({f['detail']})" if f.get("detail") else "")
             for f in p.get("facts") or []]
    parts = [sentence("; ".join(facts))] if facts else []
    if p.get("detail"):
        parts.insert(0, sentence(p["detail"]))
    conf = p.get("confirmation")
    if isinstance(conf, dict) and conf.get("label"):
        parts.append(sentence(f"Confirmed by {conf['label']}"))
    tail = ""
    undo = p.get("undo")
    if undo:
        tail = f"You can undo it until {when(undo['until'])}: reply “undo”." if undo.get("until") else "Reply “undo” to undo it."
    return fit(sentence(lead), parts, tail)


def f_control(p: dict) -> str:
    device = p.get("device") or {}
    name = device.get("name", "")
    if device.get("room"):
        name += f" in the {device['room'].lower()}" if not device["room"][0].isupper() else f" in {device['room']}"
    values = []
    for c in p.get("controls") or []:
        value = c.get("value")
        if value is None:
            values.append(f"{c.get('label', '').lower()} unknown")
        elif c.get("kind") == "switch":
            values.append("on" if value else "off")
        elif c.get("kind") in ("scenes", "segmented"):
            option = next((o.get("label") for o in c.get("options") or [] if o.get("id") == value), value)
            values.append(f"{c.get('label', '').lower()} {option}")
        else:
            values.append(f"{c.get('label', '').lower()} {value}{c.get('unit') or ''}")
    lead = f"{name}: {', '.join(values)}" if values else name
    if device.get("reachable") is False:
        lead += f" ({device.get('status') or 'not answering'})"
    return fit(sentence(lead), [], "Tell me what to change.")


def f_summary(p: dict) -> str:
    kind = p.get("kind")
    if kind == "story":
        story = p.get("story") or {}
        tag = "[Rumor] " if story.get("status") == "rumor" else ""
        sources = ", ".join(s.get("name", "") for s in story.get("sources") or [])
        lead = sentence(f"{tag}{story.get('headline')}" + (f" ({sources})" if sources else ""))
        parts = [sentence(story["body"])] if story.get("body") else []
        return fit(lead, parts, sentence(f"Why it matters: {story.get('why', '')}"))
    if kind == "standup":
        parts = []
        for person in p.get("people") or []:
            bits = [f"done {person['done']}" if person.get("done") else "",
                    f"today {person['today']}" if person.get("today") else "",
                    f"blocked on {person['blocked']}" if person.get("blocked") else ""]
            parts.append(sentence(f"{(person.get('person') or {}).get('name')}: {'; '.join(b for b in bits if b)}"))
        return fit(sentence(p.get("tldr") or p.get("title") or ""), parts)
    parts = [sentence(x.get("text", "")) for x in p.get("points") or []]
    tail = sentence(f"Do first: {p['do_first'].get('text', '')}") if p.get("do_first") else ""
    return fit(sentence(p.get("tldr") or p.get("title") or ""), parts, tail)


def f_guide(p: dict) -> str:
    lead = p.get("title") or ""
    bits = []
    if p.get("servings"):
        bits.append(f"serves {p['servings']}")
    total = sum((s.get("timer") or {}).get("seconds", 0) if isinstance(s.get("timer"), dict) else (s.get("timer") or 0)
                for s in p.get("steps") or [] if isinstance(s.get("timer"), (int, float, dict)))
    if total:
        bits.insert(0, seconds_words(total))
    if bits:
        lead += f" ({', '.join(bits)})"
    parts = []
    needs = []
    for n in p.get("needs") or []:
        amount = n.get("amount")
        amount = quantity(amount) if isinstance(amount, dict) else (amount or "")
        needs.append(f"{amount} {n.get('label')}".strip())
    if needs:
        word = {"equipment": "You'll need", "items": "You'll need"}.get(p.get("needs_kind"), "You'll need")
        parts.append(sentence(f"{word}: {', '.join(needs)}"))
    for n, s in enumerate(p.get("steps") or [], 1):
        timer = s.get("timer")
        seconds = timer.get("seconds") if isinstance(timer, dict) else timer
        line = f"{n}. {str(s.get('title') or '').rstrip('.')}"
        if isinstance(seconds, (int, float)):
            line += f" ({seconds_words(seconds)})"
        parts.append(sentence(line))
    return fit(sentence(lead), parts)


def f_compare(p: dict) -> str:
    options = p.get("options") or []
    criteria = p.get("criteria") or []
    parts = []
    for o in options:
        values = []
        if o.get("price") and not any("price" in str(c.get("label", "")).lower() for c in criteria):
            values.append(quantity(o["price"]) if isinstance(o["price"], dict) else str(o["price"]))
        for c in criteria:
            v = (c.get("values") or {}).get(o.get("id"))
            if isinstance(v, dict):
                v = quantity(v)
            if v not in (None, ""):
                values.append(f"{c.get('label', '').lower()} {v}")
        parts.append(sentence(f"{o.get('name')}: {', '.join(values)}" if values else str(o.get("name"))))
    pick = p.get("pick")
    tail = ""
    if pick:
        pick_id = pick.get("option") if isinstance(pick, dict) else pick
        name = next((o.get("name") for o in options if o.get("id") == pick_id), pick_id)
        why = pick.get("why") if isinstance(pick, dict) else None
        tail = sentence(f"Pick: {name}" + (f", {why}" if why else ""))
    if p.get("choose"):
        tail = " ".join(x for x in (tail, "Reply with the one you want.") if x)
    return fit(f"{p.get('title')}:", parts, tail)


def f_handoff(p: dict) -> str:
    def name(x: Any) -> str:
        return x.get("name", "") if isinstance(x, dict) else str(x or "")

    task = p.get("task") or {}
    status = p.get("status") or {}
    state = status.get("state")
    title = re.sub(r"^to\s+", "", task.get("title", ""), flags=re.IGNORECASE)
    lead = f"{name(p.get('from'))} asked {name(p.get('to'))} to {title[0:1].lower() + title[1:]}"
    parts = [f"“{task['context']}”"] if task.get("context") else []
    if state == "done":
        result = status.get("result") or {}
        lead = f"{name(p.get('to'))} finished: {result.get('summary', task.get('title', ''))}"
        parts = [str(result.get("label") or "")] if result.get("label") else []
    elif state == "declined":
        parts.append(sentence(f"{name(p.get('to'))} declined: {status.get('reason', '')}"))
    else:
        word = {"sent": "hasn't started yet", "accepted": "accepted it", "working": "is working on it"}.get(state, state)
        line = f"{name(p.get('to'))} {status.get('activity') or word}"
        if status.get("total"):
            line += f" ({status.get('done', 0)} of {status['total']}{' ' + status['unit'] if status.get('unit') else ''})"
        parts.append(sentence(line))
    return fit(sentence(lead), parts)


def f_flashcard(p: dict) -> str:
    cards = p.get("cards") or []
    progress = p.get("progress") or {}
    lead = f"{p.get('title')}, {len(cards)} card{'s' if len(cards) != 1 else ''}"
    if progress.get("due_today"):
        lead += f" ({progress['due_today']} due today)"
    if not cards:
        return sentence(f"{lead}. {p.get('empty_text') or 'Nothing to review.'}")
    first = cards[0]
    return fit(sentence(lead), [sentence(f"Card 1: {first.get('front')}")],
               "Reply with the answer, then again, hard, good or easy.")


TEMPLATES: dict[str, Callable[[dict], str]] = {
    "metric": f_metric, "meter": f_meter, "chart": f_chart, "calendar": f_calendar, "verdict": f_verdict,
    "scoreboard": f_scoreboard, "list": f_list, "checklist": f_checklist, "table": f_table, "details": f_details,
    "outline": f_outline, "diff": f_diff, "timeline": f_timeline, "agenda": f_agenda, "entity": f_entity,
    "media": f_media, "code": f_code, "sources": f_sources, "weather": f_weather, "route": f_route, "pass": f_pass,
    "status": f_status, "steps": f_steps, "alert": f_alert, "choice": f_choice, "form": f_form,
    "approval": f_approval, "receipt": f_receipt, "control": f_control, "summary": f_summary, "guide": f_guide,
    "compare": f_compare, "handoff": f_handoff, "flashcard": f_flashcard,
}


def generate(payload: dict) -> str:
    """The fallback text for a payload without one. Stacks join their children's (each filled first)."""
    wtype = payload.get("type")
    if wtype == "stack":
        head = payload.get("title") or ""
        schedule = (payload.get("schedule") or {}).get("label")
        bits = [x for x in (payload.get("producer", {}).get("name") if isinstance(payload.get("producer"), dict) else None,
                            schedule.lower() if schedule else None, day(payload.get("as_of"))) if x]
        if bits:
            head += f" ({', '.join(bits)})"
        labels = {}
        for section in payload.get("sections") or []:
            if section.get("children"):
                labels[section["children"][0]] = section.get("label")
        parts = []
        for child in payload.get("children") or []:
            text = child.get("fallback_text") or generate(child)
            key = child.get("id") or child.get("ref")
            parts.append(f"{labels[key]}: {text}" if labels.get(key) else text)
        return fit(sentence(head), parts, cap=STACK_CAP, joiner="\n\n")
    template = TEMPLATES.get(wtype)
    text = ""
    if template is not None:
        try:
            text = template(payload)
        except Exception:  # a template must never block a valid widget; the generic text still stands alone
            text = ""
    if not text.strip():
        text = fit(sentence(_title(payload)), [sentence(payload["summary"])] if payload.get("summary") else [])
    return text[:CAP]
