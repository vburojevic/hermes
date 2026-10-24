"""The widgets scenario: the hermes-app-widgets plugin, played by the mock (docs/widgets.md §13).

The plugin's engine needs ``jsonschema`` and the mocks are stdlib only, so this mirrors its results
instead of running it (Tools/hermes-app-widgets/core.py): ``widget`` create, update, resolve, claim
and get with the same JSON, ids and messages, and ``/app-widgets`` session, get, keys.register,
keys.remove, keys.list and status. Signed answers are checked for real (P-256 in pure Python below).

Turns run over the API server's runs (server.py: the stored tool row has the whole result, the
``tool.completed`` event a 500-character preview) and over the socket (chats.py: ``tool.complete``
carries the result, as with tool progress on; Bot Chats too, through backend.py's ``run_turn``, their
widgets the Bot's), so both of the app's paths get payloads the real way.
Examples come from the app's bundled spec, moved to now (``as_of`` and every time in them).

Words in a message:
  weather ("Weather today?")   what an agent told about widgets does (plugin 1.3.0): looks the forecast
                               up, reads widget_examples("weather"), answers one sentence and the card
  widgets / widgets 2 …        every example, three per reply, page by page
  widget <type>                that type's examples ("widget checklist", "widget stack"…)
  widget publish               an approval that needs no Face ID (a reversible post)
  widget lunch                 an approval that needs Face ID and a signature (it costs money)
  widget expiring              the publish approval, expiring 60 s from now
  widget silent                the publish approval; its first answer gets no update (Try Again)
  widget private               a private widget (health): never in a notification or a preview
  widget links                 a metric whose note has an https address (a link, asks first) and an http one (text)
  widget fence                 an agent-typed ```widget fence in a normal reply (it must stay code)
  widget unknown               a widget of a type this app doesn't know (a newer plugin)
  widget invalid               a payload missing a required field (shown as text, with why)
  widget suggestions           a reply ending in suggested follow-ups
  [widget <id> rev <n>] …      an answer: claim it (first answer wins, a repeated mid replays), then act

Over the socket, a chat the app hasn't marked (``/app-widgets session``) gets each directive's
``fallback_text`` instead, as the plugin's ``transform_llm_output`` does: that's how an unmarked chat
reads on a real gateway.

In a Bot group chat the app marked (``/app-widgets room``), "widget …" makes Ops answer with the
widget as an inline block, the way the plugin writes it for rooms; answers there are claimed alike.

``POST /api/mock/widget-answer {"id"?, "action", "values"?, "device"?, "hold"?}`` (backend) answers
the newest revision from "another device" (the newest widget without an id): a message in the
widget's chat, as a phone would send it; ``hold`` keeps the agent that many seconds between its
claim and its update, so the lock shows.
``--no-widgets`` leaves the plugin out: no ``widgets`` toolset, no scenario, ``/app-widgets`` is 4018.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import pathlib
import re
import secrets
import threading
import time
import uuid
from datetime import date, datetime, timedelta

HERE = pathlib.Path(__file__).resolve().parent
EXAMPLES = HERE.parent.parent / "Packages/HermesKit/Sources/HermesKit/Widgets/Spec/examples"
VERSION = "1.3.0"
ID_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
RESOLUTIONS = ("done", "failed", "rejected", "cancelled", "expired", "elsewhere")
BUILT_IN = {"choice": {"answer"}, "form": {"submit", "cancel"}, "checklist": {"check"}, "control": {"set"},
            "approval": {"approve", "edit", "reject"}, "receipt": {"undo"}, "flashcard": {"rate"},
            "alert": {"acknowledge"}, "compare": {"answer"}}
PRODUCER = {"name": "Hermes", "bot": "hermes"}
TOOLSET = {"name": "widgets", "label": "Widgets", "description": "Widgets in the Hermes app", "enabled": True,
           "configured": True, "tools": ["widget", "widget_examples"]}

ENABLED = {"on": True}
LOCK = threading.RLock()
WIDGETS = {}  # id -> record: {"revisions", "claims", "answered", "children", "parent", "session"}
KEYS = {}     # device_id -> {"public_key", "name", "fingerprint", "registered_at"}
MARKED = {}   # session id -> time marked
ROOMS = {}    # room id -> time marked
SILENT = set()
HOLD = {}     # mid -> seconds the agent waits after claiming, before it acts (the lock shows)
C = None      # chats.py, when the backend runs
B = None      # backend.py's globals
PUSH = None   # push.py, when it runs: answers withdraw a widget's notice


def now():
    return datetime.now().astimezone().replace(microsecond=0)


def rfc3339(moment):
    return moment.isoformat()


def parse_time(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def new_id():
    return "w_" + "".join(secrets.choice(ID_ALPHABET) for _ in range(10))


# ---------------------------------------------------------------- examples


def examples(kind=None):
    """The bundled examples by name ("approval-1"), in catalogue order, as the agent's input: no id,
    rev or producer, a stack's children with a ``ref`` instead of an id."""
    def order(path):
        base, _, number = path.stem.rpartition("-")
        return base, int(number)
    rows = []
    for path in sorted(EXAMPLES.glob("*.json"), key=order):
        if kind is None or path.stem.rpartition("-")[0] == kind:
            rows.append((path.stem, as_input(json.loads(path.read_text()))))
    return rows


def as_input(payload):
    payload = moved_to_now(payload)
    for key in ("id", "rev", "producer"):
        payload.pop(key, None)
    # A Bot's own face as the icon: the example is that Bot's, as the plugin would stamp it.
    icons = [payload.get("icon")] + [c.get("icon") for c in payload.get("children") or []]
    bot = next((i[4:] for i in icons if isinstance(i, str) and i.startswith("bot:")), None)
    if bot:
        payload["__producer"] = {"name": bot.replace("-", " ").title(), "bot": bot}
    for n, child in enumerate(payload.get("children") or []):
        child["ref"] = child.pop("id", None) or f"part{n + 1}"
        child.pop("rev", None)
        child.pop("producer", None)
    return payload


DATE_TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:\d\d)$")
DATE = re.compile(r"^\d{4}-\d\d-\d\d$")


def moved_to_now(payload):
    """Every time in an example moved by as much as its ``as_of`` is behind now (dates by whole days),
    so a request isn't expired and a figure isn't stale when it arrives."""
    as_of = parse_time(payload.get("as_of") or "")
    if as_of is None:
        return copy.deepcopy(payload)
    shift = now() - as_of
    days = timedelta(days=shift.days)

    def move(value):
        if isinstance(value, dict):
            return {k: move(v) for k, v in value.items()}
        if isinstance(value, list):
            return [move(v) for v in value]
        if isinstance(value, str) and DATE_TIME.match(value):
            moment = parse_time(value)
            return rfc3339((moment + shift).replace(microsecond=0)) if moment else value
        if isinstance(value, str) and DATE.match(value):
            try:
                return (date.fromisoformat(value) + days).isoformat()
            except ValueError:
                return value
        return value
    return move(payload)


def publish_approval(expires_in=1800):
    """An approval that needs no Face ID: a post that can be taken down, at no cost."""
    moment = now()
    return {"type": "approval", "v": 1, "title": "Publish the changelog?", "as_of": rfc3339(moment),
            "expires_at": rfc3339(moment + timedelta(seconds=expires_in)), "icon": "megaphone",
            "subject": {"kind": "post", "verb": "Publish", "summary": "Release notes for 2.4 on the blog",
                        "message": {"to": {"name": "The Hermes blog"}, "channel": "Blog",
                                    "text": "Hermes 2.4 brings widgets to your chats."}},
            "consequences": {"affects": ["Anyone reading the blog"], "reversible": "yes",
                             "undo_note": "You can take the post down again"},
            "fallback_text": "Publish the changelog? Release notes for 2.4 on the blog. Reply approve or reject."}


# ---------------------------------------------------------------- the widget tool


def alt(payload):
    """The directive's alt (the plugin's ``_alt``): the summary, else the plain text's start; a
    private widget's is only its title."""
    text = payload.get("title") if payload.get("sensitivity") == "private" else payload.get("summary") or ""
    if not text:
        for part in re.split(r"(?<=[.!?])\s+", " ".join(str(payload.get("fallback_text") or "").split())):
            if text and len(text) + len(part) > 140:
                break
            text = f"{text} {part}".strip()
    text = " ".join((text or payload.get("title") or "").split())
    if len(text) > 140:
        text = text[:139].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"
    return text.replace("\\", "\\\\").replace('"', '\\"')


def directive(payload):
    return f'::widget{{id="{payload["id"]}" alt="{alt(payload)}"}}'


def result(payload, refs=None):
    return {"id": payload["id"], "rev": payload["rev"], "directive": directive(payload),
            "fallback_text": payload.get("fallback_text") or "", "children": refs or {}, "payload": payload}


def order(payload):
    head = ("type", "v", "id", "rev", "title", "subtitle", "icon", "state", "state_label", "as_of", "stale_after",
            "expires_at", "refresh", "producer")
    first = {k: payload[k] for k in head if k in payload}
    return {**first, **{k: v for k, v in payload.items() if k not in first}}


def unused_id():
    while True:
        candidate = new_id()
        if candidate not in WIDGETS:
            return candidate


def prepare(raw, existing=None):
    payload = copy.deepcopy(raw)
    producer = payload.pop("__producer", None) or (existing or {}).get("producer") or PRODUCER
    refs = {}
    if payload.get("type") == "stack":
        known = dict((existing or {}).get("children") or {})
        for child in payload.get("children") or []:
            ref = child.pop("ref", None)
            child["id"] = known.get(ref) if ref and ref in known else unused_id()
            if ref:
                refs[ref] = child["id"]
            child.setdefault("as_of", payload.get("as_of"))
            child["producer"] = dict(producer)
            child["rev"] = 1
        for section in payload.get("sections") or []:
            section["children"] = [refs.get(name, name) for name in section.get("children") or []]
        if any(c.get("sensitivity") == "private" for c in payload.get("children") or []):
            payload["sensitivity"] = "private"
    payload["producer"] = dict(producer)
    payload.setdefault("fallback_text", payload.get("title") or "")
    return payload, refs


def op_create(raw, session=""):
    with LOCK:
        payload, refs = prepare(raw)
        payload["rev"] = 1
        payload["id"] = unused_id()
        payload = order(payload)
        WIDGETS[payload["id"]] = {"revisions": [payload], "claims": {}, "answered": {}, "children": refs, "session": session,
                                  "producer": payload["producer"]}
        for child in payload.get("children") or []:
            WIDGETS[child["id"]] = {"revisions": [child], "claims": {}, "answered": {}, "children": {},
                                    "parent": payload["id"], "session": session}
        return result(payload, refs)


def op_update(widget_id, raw):
    with LOCK:
        record = WIDGETS[widget_id]
        payload, refs = prepare(raw, existing=record)
        payload["id"] = widget_id
        payload["rev"] = record["revisions"][-1]["rev"] + 1
        payload = order(payload)
        record["revisions"].append(payload)
        record["children"] = {**record.get("children", {}), **refs}
        for child in payload.get("children") or []:
            put_child(child, widget_id)
        replace_in_parent(record, payload)
        return result(payload, refs)


def put_child(child, parent):
    entry = WIDGETS.get(child["id"])
    if entry is None:
        WIDGETS[child["id"]] = {"revisions": [child], "claims": {}, "answered": {}, "children": {}, "parent": parent}
    elif entry["revisions"][-1] != child:
        entry["revisions"].append(child)


def replace_in_parent(record, payload):
    parent = WIDGETS.get(record.get("parent") or "")
    if parent is None:
        return
    latest = copy.deepcopy(parent["revisions"][-1])
    latest["children"] = [payload if c.get("id") == payload["id"] else c for c in latest.get("children") or []]
    latest["rev"] += 1
    parent["revisions"].append(latest)


def op_resolve(widget_id, state, message=None, action=None, **extra):
    """The plugin's resolve: a resolution, the state from it, rev + 1, the plain text rewritten."""
    with LOCK:
        record = WIDGETS[widget_id]
        latest = copy.deepcopy(record["revisions"][-1])
        answer = record["answered"].get(str(latest["rev"])) or {}
        resolution = {"state": state, "at": rfc3339(now())}
        if action or answer.get("action"):
            resolution["action"] = action or answer["action"]
        if answer.get("by"):
            resolution["by"] = answer["by"][:40]
        if message:
            resolution["message"] = message
        if extra.get("undo") is not None:
            resolution["undo"] = extra["undo"]
        latest["resolution"] = resolution
        for key in ("answer", "submitted", "undone"):
            if extra.get(key) is not None:
                latest[key] = extra[key]
        if extra.get("undone") is not None:
            latest.pop("undo", None)
        latest["state"] = {"done": "ok", "failed": "critical"}.get(state, "info")
        latest.pop("state_label", None)
        latest["rev"] += 1
        words = {"done": "Done", "failed": "Failed", "rejected": "Rejected", "cancelled": "Cancelled",
                 "expired": "Expired", "elsewhere": "Answered elsewhere"}
        latest["fallback_text"] = f"{latest.get('title')}: {message or words[state]}."
        record["revisions"].append(latest)
        replace_in_parent(record, latest)
        return result(latest)


def actions_of(payload):
    """The answers a widget takes: its type's built-ins and every reply action in it."""
    allowed = set(BUILT_IN.get(payload.get("type"), set()))
    if (payload.get("refresh") or {}).get("mode") == "agent":
        allowed.add("refresh")

    def walk(value):
        if isinstance(value, dict):
            if isinstance(value.get("id"), str) and isinstance(value.get("label"), str) and value.get("kind") in ("reply", None) \
                    and ("kind" in value or "url" not in value):
                allowed.add(value["id"])
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk({k: v for k, v in payload.items() if k not in ("resolution", "children")})
    resolution = payload.get("resolution") or {}
    if resolution.get("state") == "failed":
        allowed.add("retry")
    if (resolution.get("undo") or {}).get("action"):
        allowed.add(resolution["undo"]["action"])
    if payload.get("type") == "receipt" and (not payload.get("undo") or payload.get("undone")):
        allowed.discard("undo")
    return allowed


def requires_signature(payload):
    """The plugin's ``fallback.requires_signature``: approvals that cost money, can't be undone, need
    authentication or are transfers."""
    if payload.get("type") != "approval":
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


def needs_signature(payload, action):
    if action == "approve" and requires_signature(payload):
        return True
    found = []

    def walk(value):
        if isinstance(value, dict):
            if value.get("id") == action and value.get("requires") == "authentication":
                found.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(payload)
    return bool(found)


def op_claim(widget_id, rev, action, mid, values, sig=None, device=None):
    """The plugin's claim, message for message: the gate before acting on an answer."""
    with LOCK:
        record = WIDGETS.get(widget_id)
        if record is None:
            return {"error": f'no widget "{widget_id}" on this gateway', "stored": False}
        moment = now()
        base = {"id": widget_id, "rev": rev, "action": action, "mid": mid}
        first = record["claims"].get(mid)
        latest = record["revisions"][-1]
        if first is not None:
            replay = {**first, "replay": True}
            if latest.get("resolution"):
                replay["resolution"] = latest["resolution"].get("state")
            replay["message"] = ("This answer was claimed before" + (f" ({first['result']})" if first["result"] != "ok" else "")
                                 + ". Check whether you already acted on it before doing anything"
                                 + ("; the widget is resolved, so don't act again." if latest.get("resolution") else "."))
            return replay
        target = next((r for r in record["revisions"] if r["rev"] == rev), None)

        def keep(outcome):
            record["claims"][mid] = {k: v for k, v in outcome.items() if k != "message"}
            return outcome

        answered = record["answered"].get(str(rev))
        if answered:
            return keep({**base, "result": "already_answered", "action": answered["action"], "mid": answered["mid"],
                         "by": answered.get("by"), "at": answered.get("at"),
                         "message": f"Already answered ({answered['action']}) by {answered.get('by') or 'someone'} "
                                    f"at {answered.get('at')}. Don't act on this one."})
        if target is None or rev < latest["rev"]:
            resolution = latest.get("resolution") or {}
            if target is not None and resolution and resolution.get("state") != "expired":
                return keep({**base, "result": "already_answered", "by": resolution.get("by"), "at": resolution.get("at"),
                             "action": resolution.get("action") or action,
                             "message": "This request was already answered and resolved. Don't act on it."})
            return keep({**base, "result": "stale_rev", "current_rev": latest["rev"],
                         "message": f"The person answered revision {rev}; the widget is at revision {latest['rev']}. "
                                    "For an approval, show the current terms and ask again; otherwise re-check "
                                    "and say what changed."})
        if target.get("resolution"):
            resolution = target["resolution"]
            return keep({**base, "result": "already_answered", "by": resolution.get("by"), "at": resolution.get("at"),
                         "action": resolution.get("action") or action,
                         "message": "This request is already resolved. Don't act on it."})
        expires = parse_time(target.get("expires_at") or "")
        if action == "undo" and target.get("type") == "receipt":
            expires = parse_time((target.get("undo") or {}).get("until") or "") or expires
        if expires is not None and moment >= expires:
            return keep({**base, "result": "expired", "expires_at": rfc3339(expires), "now": rfc3339(moment),
                         "message": f"The answer came after the request expired ({rfc3339(expires)}). Don't act; "
                                    "tell the person and ask again if it still matters."})
        allowed = actions_of(target)
        if action not in allowed:
            return {"error": f"{widget_id} has no action \"{action}\"; its actions are {', '.join(sorted(allowed)) or 'none'}",
                    "stored": False}
        signature, by = None, None
        if needs_signature(target, action):
            outcome = check_signature(widget_id, rev, action, values, mid, sig)
            if outcome["result"] != "ok":
                return {**base, **outcome}
            signature, by = outcome.get("signature"), outcome.get("by")
        by = by or (str(device)[:40] if device else None) or "Hermes app"
        at = rfc3339(moment)
        record["answered"][str(rev)] = {"mid": mid, "action": action, "by": by, "at": at, "values": canonical(values)[:2000]}
        outcome = {**base, "result": "ok", "at": at, "by": by,
                   "message": "Claimed: act on it now, then resolve the widget with what happened."}
        if signature:
            outcome["signature"] = signature
        return keep(outcome)


# ---------------------------------------------------------------- signed answers (contract §6.3)

P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
P256_A = P256_P - 3
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
P256_G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
          0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def canonical(values):
    return json.dumps(values if values is not None else {}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def signing_input(widget_id, rev, action, values, mid):
    digest = hashlib.sha256(canonical(values).encode()).hexdigest()
    return f"hermes-widgets-v1|{widget_id}|{int(rev)}|{action}|{digest}|{mid}".encode()


def b64(text):
    text = (text or "").strip()
    alt_chars = b"-_" if ("-" in text or "_" in text) else None
    return base64.b64decode(text + "=" * (-len(text) % 4), altchars=alt_chars)


def point_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P256_P == 0:
        return None
    if a == b:
        slope = (3 * a[0] * a[0] + P256_A) * pow(2 * a[1], -1, P256_P) % P256_P
    else:
        slope = (b[1] - a[1]) * pow(b[0] - a[0], -1, P256_P) % P256_P
    x = (slope * slope - a[0] - b[0]) % P256_P
    return x, (slope * (a[0] - x) - a[1]) % P256_P


def point_mul(k, point):
    out = None
    while k:
        if k & 1:
            out = point_add(out, point)
        point = point_add(point, point)
        k >>= 1
    return out


def public_point(encoded):
    """Base64 of the X9.63 point (65 bytes) or of the SubjectPublicKeyInfo DER (its last 65 bytes)."""
    raw = b64(encoded)
    if len(raw) != 65:
        raw = raw[-65:]
    if len(raw) != 65 or raw[0] != 4:
        raise ValueError("not a P-256 key")
    point = (int.from_bytes(raw[1:33], "big"), int.from_bytes(raw[33:], "big"))
    if (point[1] ** 2 - point[0] ** 3 - P256_A * point[0] - P256_B) % P256_P:
        raise ValueError("not on the curve")
    return point


def der_signature(raw):
    if len(raw) == 64:
        return int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")
    if raw[0] != 0x30:
        raise ValueError("not DER")

    def integer(at):
        if raw[at] != 0x02:
            raise ValueError("not DER")
        length = raw[at + 1]
        return int.from_bytes(raw[at + 2:at + 2 + length], "big"), at + 2 + length
    r, at = integer(2)
    s, _ = integer(at)
    return r, s


def verify(public_key, signature, message):
    try:
        point = public_point(public_key)
        r, s = der_signature(b64(signature))
        if not (1 <= r < P256_N and 1 <= s < P256_N):
            return False
        e = int.from_bytes(hashlib.sha256(message).digest(), "big")
        w = pow(s, -1, P256_N)
        total = point_add(point_mul(e * w % P256_N, P256_G), point_mul(r * w % P256_N, point))
        return total is not None and total[0] % P256_N == r
    except (ValueError, IndexError, TypeError):
        return False


def fingerprint(public_key):
    return hashlib.sha256(b64(public_key)).hexdigest()[:16]


def check_signature(widget_id, rev, action, values, mid, sig):
    if not KEYS:
        # No device registered a key yet: the app's Face ID check is the only gate.
        return {"result": "ok", "signature": "unavailable"}
    if not sig:
        return {"result": "unsigned", "reason": "missing",
                "message": "This approval needs the app's signature and the answer has none. Don't act; ask the "
                           "person to approve it in the Hermes app."}
    message = signing_input(widget_id, rev, action, values, mid)
    for device_id, entry in KEYS.items():
        if verify(entry.get("public_key", ""), str(sig), message):
            return {"result": "ok", "signature": "verified", "by": entry.get("name") or device_id}
    return {"result": "unsigned", "reason": "invalid", "message": "The signature doesn't match this answer. Don't act."}


# ---------------------------------------------------------------- /app-widgets


def command(raw):
    """``/app-widgets <command> <json>`` → one line of JSON, never raising (the plugin's handle_command)."""
    name, _, body = (raw or "").strip().partition(" ")
    if name not in ("session", "room", "get", "keys.register", "keys.remove", "keys.list", "status"):
        return dump({"ok": False, "error": f"unknown command {name!r}"})
    try:
        args = json.loads(body) if body.strip() else {}
        if not isinstance(args, dict):
            raise ValueError("arguments must be a JSON object")
    except ValueError as exc:
        return dump({"ok": False, "error": str(exc)})
    with LOCK:
        if name == "session":
            # One chat by both ids, or every chat the app knows (`session_ids`, up to 500), as 1.1.1 takes them.
            many = args.get("session_ids") if isinstance(args.get("session_ids"), list) else []
            ids = [str(v) for v in (args.get("session_id"), args.get("stored_session_id"), *many[:500]) if v]
            ids = [i for i in dict.fromkeys(ids) if re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", i)]
            if not ids:
                return dump({"ok": False, "error": "session_id is required"})
            for session_id in ids:
                MARKED[session_id] = time.time()
            print(f"[mock-widgets] marked {len(ids)} chat(s) as the app's", flush=True)
            return dump({"ok": True, "session_ids": ids})
        if name == "room":
            room_id = str(args.get("room_id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", room_id):
                return dump({"ok": False, "error": "room_id is required"})
            ROOMS[room_id] = time.time()
            return dump({"ok": True, "room_id": room_id})
        if name == "get":
            record = WIDGETS.get(str(args.get("id") or ""))
            if record is None:
                return dump({"ok": False, "error": "unknown widget"})
            latest = record["revisions"][-1]
            if args.get("rev") is not None:
                latest = next((r for r in record["revisions"] if r.get("rev") == args["rev"]), None)
                if latest is None:
                    return dump({"ok": False, "error": "unknown revision"})
            return dump({"ok": True, "id": args["id"], "rev": latest["rev"], "payload": latest})
        if name == "keys.register":
            device_id = str(args.get("device_id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", device_id):
                return dump({"ok": False, "error": "device_id is required"})
            public_key = str(args.get("public_key") or "")
            try:
                public_point(public_key)
            except Exception:
                return dump({"ok": False, "error": "public_key must be a base64 P-256 key (x963 or DER)"})
            KEYS[device_id] = {"public_key": public_key, "name": str(args.get("name") or "")[:40],
                               "fingerprint": fingerprint(public_key), "registered_at": time.time()}
            return dump({"ok": True, "device_id": device_id, "fingerprint": fingerprint(public_key), "devices": len(KEYS)})
        if name == "keys.remove":
            return dump({"ok": True, "removed": KEYS.pop(str(args.get("device_id") or ""), None) is not None})
        if name == "keys.list":
            return dump({"ok": True, "devices": [{"device_id": k, "name": v.get("name"), "fingerprint": v.get("fingerprint"),
                                                  "registered_at": v.get("registered_at")} for k, v in KEYS.items()]})
        return dump({"ok": True, "version": VERSION, "spec": "1.0", "widgets": len(WIDGETS), "keys": len(KEYS),
                     "validator": True, "app_platforms": [], "store_media": False, "text_answers": True})


# ---------------------------------------------------------------- scripts


WEATHER = re.compile(r"\b(weather|forecast)\b")


def matches(text):
    lower = text.lower()
    return ENABLED["on"] and (text.lstrip().startswith("[widget ") or re.search(r"\bwidgets?\b", lower) is not None
                              or WEATHER.search(lower) is not None)


def examples_result(kind):
    """``widget_examples(type)``: the type's catalogue entry and its examples as tool input."""
    catalog = json.loads((EXAMPLES.parent / "catalog.json").read_text())
    entry = next((t for t in catalog["types"] if t["type"] == kind), {})
    return dump({"type": kind, "summary": entry.get("summary"), "use": entry.get("use"), "avoid": entry.get("avoid"),
                 "limits": entry.get("limits"), "fallback": entry.get("fallback"),
                 "examples": [raw for _, raw in examples(kind)[:1]],
                 "note": "Examples are tool input: no id, rev or producer; fallback_text is optional."})


def script(text, session="", producer=None):
    """A turn as steps: ("tool", args, result JSON[, tool name]) and ("text", words). ``producer`` is
    the Bot whose turn it is (a Bot Chat), as the plugin stamps it from the profile."""
    stripped = text.strip()
    if stripped.startswith("[widget "):
        return answer_script(stripped)
    lower = stripped.lower()
    steps = []

    def create(raw):
        if producer and "__producer" not in raw:
            raw = {**raw, "__producer": producer}
        outcome = op_create(raw, session)
        shown = {k: v for k, v in raw.items() if k != "__producer"}
        steps.append(("tool", {"op": "create", "payload": shown}, dump(outcome)))
        return outcome["payload"]

    def stored(raw):
        """A payload this plugin wouldn't make (a newer type, a broken one), stored as a newer plugin would."""
        with LOCK:
            payload = {**copy.deepcopy(raw), "id": unused_id(), "rev": 1, "producer": dict(PRODUCER)}
            WIDGETS[payload["id"]] = {"revisions": [payload], "claims": {}, "answered": {}, "children": {}, "session": session}
        steps.append(("tool", {"op": "create", "payload": raw}, dump(result(payload))))
        return payload

    if WEATHER.search(lower) and re.search(r"\bwidgets?\b", lower) is None:
        # "Weather today?": the forecast looked up, the type's examples read before its first use, then
        # one sentence that says what matters and the card (the plugin's prompt section, 1.3.0).
        _, raw = examples("weather")[0]
        # Today, not the example's day (its times are already moved to now).
        weekday = now().strftime("%A")
        raw["fallback_text"] = (raw.get("fallback_text") or "").replace(raw.get("subtitle") or "\0", weekday)
        raw["subtitle"] = weekday
        place = (raw.get("place") or {}).get("name") or raw.get("title")
        steps.append(("tool", {"query": f"{place} weather today hourly"},
                      f"{place} today: {raw['now']['temp']}°, partly cloudy, rain likely this afternoon.", "web_search"))
        steps.append(("tool", {"type": "weather"}, examples_result("weather"), "widget_examples"))
        payload = create(raw)
        return steps + [("text", "Mild for now, with rain likely later today, so take an umbrella.\n\n" + directive(payload))]
    if "fence" in lower:
        _, raw = examples("metric")[0]
        block = json.dumps({**raw, "id": "w_fence00001", "rev": 1}, indent=2, ensure_ascii=False)
        return [("text", f"Here's the payload I'd send, as JSON:\n\n```widget\n{block}\n```")]
    if "unknown" in lower:
        _, raw = examples("metric")[0]
        payload = stored({**raw, "type": "hologram", "fallback_text": "Revenue today: €1,240, up 12% on last Monday."})
        return steps + [("text", "This one comes from a newer Hermes.\n\n" + directive(payload))]
    if "invalid" in lower:
        _, raw = examples("approval")[0]
        raw["consequences"].pop("cost", None)
        raw["subject"].pop("verb", None)
        payload = stored(raw)
        return steps + [("text", "Chef Remy wants your OK for lunch.\n\n" + directive(payload))]
    if "expiring" in lower or "silent" in lower or "publish" in lower:
        payload = create(publish_approval(60 if "expiring" in lower else 1800))
        if "silent" in lower:
            SILENT.add(payload["id"])
        return steps + [("text", "The release notes are ready.\n\n" + directive(payload))]
    if "lunch" in lower:
        _, raw = examples("approval")[0]
        payload = create(raw)
        return steps + [("text", "Chef Remy can bring lunch at 12:30.\n\n" + directive(payload))]
    if "links" in lower:
        # Addresses in a widget's words: the https one is a link that asks first, the http one stays text.
        _, raw = examples("metric")[0]
        raw["items"][0]["note"] = "Details at https://example.com/revenue (the old page was http://example.com/old)."
        payload = create(raw)
        return steps + [("text", "Revenue, with where it comes from.\n\n" + directive(payload))]
    if "private" in lower:
        _, raw = examples("chart")[0]
        payload = create({**raw, "sensitivity": "private"})
        return steps + [("text", "Here is this week's pulse.\n\n" + directive(payload))]
    if "suggestions" in lower:
        _, raw = examples("metric")[0]
        first = create(raw)
        follow = create({"type": "choice", "v": 1, "title": "Ask next", "as_of": rfc3339(now()), "style": "suggestions",
                         "fallback_text": "Ask next: compare with last week, or break it down by product.",
                         "options": [{"id": "week", "label": "Compare with last week"},
                                     {"id": "products", "label": "Break it down by product"},
                                     {"id": "month", "label": "What will this month end at?"}]})
        return steps + [("text", "Revenue is up today.\n\n" + directive(first) + "\n\n" + directive(follow))]
    kinds = {name.rpartition("-")[0] for name, _ in examples()}
    kind = next((k for k in sorted(kinds) if re.search(rf"\bwidget {re.escape(k)}\b", lower)), None)
    if kind:
        chosen = examples(kind)
        lead = f"Here are the {kind} widgets."
    else:
        found = re.search(r"widgets\s+(\d+)", lower)
        page = int(found.group(1)) if found else 1
        everything = examples()
        chosen = everything[(page - 1) * 3:page * 3]
        pages = (len(everything) + 2) // 3
        lead = f"Widgets, page {page} of {pages}." if chosen else f"There are {pages} pages of widgets."
    parts = [f"{name}\n\n" + directive(create(raw)) for name, raw in chosen]
    return steps + [("text", "\n\n".join([lead] + parts))]


def answer_script(text):
    """An answer arrives as the person's message: claim it, then act and resolve."""
    heading, _, details = text.partition("\n")
    match = re.match(r"\[widget (w_[A-Za-z0-9]+) rev (\d+)\] ([A-Za-z0-9_.-]+)", heading)
    if not match:
        return [("text", "I couldn't read that answer.")]
    widget_id, rev, action = match.group(1), int(match.group(2)), match.group(3)
    try:
        line = json.loads(details.strip().split("\n", 1)[0]) if details.strip() else {}
    except ValueError:
        line = {}
    mid, values = str(line.get("mid") or uuid.uuid4().hex), line.get("values") or {}
    claim_args = {"op": "claim", "id": widget_id, "rev": rev, "action": action, "mid": mid, "values": values}
    for key in ("sig", "device"):
        if line.get(key):
            claim_args[key] = line[key]
    verdict = op_claim(widget_id, rev, action, mid, values, sig=line.get("sig"), device=line.get("device"))
    steps = [("tool", claim_args, dump(verdict))]
    if PUSH is not None:
        PUSH.withdraw([widget_id])  # the push plugin's pre_tool_call on a claim
    if HOLD.get(mid):
        steps.append(("sleep", HOLD.pop(mid)))
    outcome = verdict.get("result")
    if "error" in verdict:
        return steps + [("text", "I couldn't take that answer: " + verdict["error"])]
    if outcome == "already_answered":
        return steps + [("text", f"That was already answered ({verdict.get('action')}) by {verdict.get('by') or 'another device'}, so I left it.")]
    if outcome == "expired":
        resolved = op_resolve(widget_id, "expired", "Expired · nothing happened", action=action)
        steps.append(("tool", {"op": "resolve", "id": widget_id, "state": "expired"}, dump(resolved)))
        return steps + [("text", "That request had expired, so I didn't do anything.")]
    if outcome == "stale_rev":
        return steps + [("text", "That was an older version; the terms have changed since. Have a look at the new one.")]
    if outcome == "unsigned":
        return steps + [("text", "I can only act on that approval from the Hermes app, with Face ID.")]
    if outcome != "ok":
        return steps + [("text", "I couldn't take that answer.")]
    if verdict.get("replay") and verdict.get("resolution"):
        return steps + [("text", "I've already done that.")]
    if widget_id in SILENT:
        SILENT.discard(widget_id)
        return steps + [("text", "On it.")]
    op, resolved, sentence = act(widget_id, action, values)
    if resolved is not None:
        steps.append(("tool", op, dump(resolved)))
    return steps + [("text", sentence)]


def act(widget_id, action, values):
    """What the agent does with a claimed answer, and the update or resolve it makes."""
    with LOCK:
        payload = copy.deepcopy(WIDGETS[widget_id]["revisions"][-1])
    kind = payload.get("type")

    def resolve(state, message, **extra):
        return ({"op": "resolve", "id": widget_id, "state": state, "message": message, **extra},
                op_resolve(widget_id, state, message, action=action, **extra))

    def update(changed):
        raw = {k: v for k, v in changed.items() if k not in ("id", "rev", "producer", "resolution")}
        return {"op": "update", "id": widget_id, "payload": raw}, op_update(widget_id, raw)

    if kind == "checklist" and action == "check":
        for item in payload.get("items") or []:
            if item["id"] in (values.get("checked") or []):
                item["checked"] = True
            if item["id"] in (values.get("unchecked") or []):
                item["checked"] = False
        done = sum(1 for i in payload.get("items") or [] if i.get("checked"))
        return (*update(payload), f"Ticked. {done} of {len(payload.get('items') or [])} done.")
    if kind == "control" and action == "set":
        for control in payload.get("controls") or []:
            if control.get("id") == values.get("control"):
                control["value"] = values.get("value")
        return (*update(payload), "Done; it reports the new setting.")
    if kind == "approval" and action == "approve":
        verb = (payload.get("subject") or {}).get("verb") or "Done"
        return (*resolve("done", f"{verb} · done"), f"{verb}: done.")
    if kind == "approval" and action == "reject":
        return (*resolve("rejected", "Not done · you said no"), "Okay, I didn't do it.")
    if kind == "approval" and action == "edit":
        subject = payload.get("subject") or {}
        if subject.get("message") and values.get("text"):
            subject["message"]["text"] = values["text"]
        return (*update(payload), "I changed it. Have a look at the new version.")
    if kind == "choice" and action == "answer":
        labels = [o["label"] for o in payload.get("options") or [] if o["id"] in (values.get("selected") or [])]
        if values.get("other"):
            labels.append(str(values["other"]))
        message = ", ".join(labels) or "None of these"
        answer = {k: v for k, v in values.items() if k in ("selected", "other")}
        return (*resolve("done", message[:120], answer=answer), f"Got it: {message}.")
    if kind == "form" and action == "submit":
        return (*resolve("done", "Sent · Hermes is on it", submitted=values), "Thanks, that's everything I need.")
    if action == "cancel":
        return (*resolve("cancelled", "Cancelled · nothing was sent"), "Cancelled.")
    if kind == "flashcard" and action == "rate":
        count = len(values.get("ratings") or [])
        return (*resolve("done", f"{count} cards rated · next review tomorrow"), f"Saved {count} ratings.")
    if kind == "receipt" and action == "undo":
        return (*resolve("done", "Undone · nothing was charged", undone={"at": rfc3339(now()), "message": "Order cancelled"}),
                "Cancelled the order.")
    if kind == "alert" and action == "acknowledge":
        return (*resolve("done", "You're on it"), "Noted: you're on it.")
    if kind == "compare" and action == "answer":
        name = next((o.get("name") or o.get("title") for o in payload.get("options") or [] if o.get("id") == values.get("option")), "that one")
        return (*resolve("done", f"Going with {name}"[:120]), f"Going with {name}.")
    if action == "refresh":
        payload["as_of"] = rfc3339(now())
        return (*update(payload), "Here's the latest.")
    label = action.replace("_", " ")
    return (*resolve("done", f"Done: {label}"[:120]), f"Done: {label}.")


# ---------------------------------------------------------------- the two transports


def play_run(run, gateway):
    """Over the API server: the tool row is stored before ``tool.completed``, whose preview is cut at 500."""
    sid = run.session_id
    run.status = "running"
    gateway.add_message(sid, "user", run.text)
    session = gateway.SESSIONS.get(sid)
    if session is not None and not session.get("title"):
        session["title"] = run.text.strip().split("\n")[0][:48]
    for kind, *rest in script(run.text, sid):
        if run.stop.is_set():
            break
        if kind == "sleep":
            time.sleep(rest[0])
        elif kind == "tool":
            args, outcome, *named = rest
            name = named[0] if named else "widget"
            call = f"call_{uuid.uuid4().hex[:8]}"
            gateway.add_message(sid, "assistant", "", finish_reason="tool_calls",
                                tool_calls=[{"id": call, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}])
            run.emit("tool.started", tool=name, preview=args.get("op") or args.get("type") or args.get("query"))
            time.sleep(0.3)
            gateway.add_message(sid, "tool", outcome, tool_call_id=call, tool_name=name)
            run.emit("tool.completed", tool=name, duration=0.3, error=False, preview=outcome[:500])
        else:
            out, _ = gateway.stream_text(run, rest[0], chunk=8, delay=0.015)
            gateway.add_message(sid, "assistant", out, finish_reason="stop")
            run.output = out
    if run.stop.is_set():
        run.status = "cancelled"
        run.emit("run.cancelled", completed=False, partial=True, interrupted=True)
    else:
        run.status = "completed"
        run.emit("run.completed", completed=True, partial=False, interrupted=False, output=run.output,
                 usage={"input_tokens": 920, "output_tokens": 140, "total_tokens": 1060})


def play_socket(sid, text):
    """Over the socket: ``tool.complete`` carries the parsed result, as Hermes sends it with tool progress on."""
    stored = B["RUNTIME"][sid]["stored"]
    C.G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    time.sleep(0.25)
    answer = ""
    for kind, *rest in script(text, stored):
        if kind == "sleep":
            time.sleep(rest[0])
        elif kind == "tool":
            args, outcome, *named = rest
            name = named[0] if named else "widget"
            if not C.tool(sid, stored, name, args, 0.3, context=args.get("op") or args.get("type") or args.get("query"),
                          result=outcome):
                return C.finish(sid, stored, answer, status="interrupted")
        else:
            answer = rest[0] if marked(sid, stored) else as_text(rest[0])
            if not C.stream(sid, answer):
                return C.finish(sid, stored, answer, status="interrupted")
    return C.finish(sid, stored, answer)


def marked(*ids):
    with LOCK:
        return any(i in MARKED for i in ids if i)


def as_text(words):
    """The plugin's ``transform_llm_output`` for a chat that isn't the app's: each directive becomes
    its widget's plain text."""
    def text(match):
        payload = newest_payload(match.group(1))
        return (payload or {}).get("fallback_text") or (match.group(2) or "").replace("\\\"", "\"")
    return re.sub(r'^::widget\{id="(w_[A-Za-z0-9]+)"(?: alt="((?:[^"\\]|\\.)*)")?[^\n]*\}$', text, words, flags=re.M)


def play_bot_chat(sid, text):
    """A Bot Chat (backend.py's ``run_turn``): the same turn in the Bot's own chat, its widgets the Bot's."""
    runtime = B["RUNTIME"][sid]
    stored = B["ensure_row"](sid)
    profile = runtime["profile"]
    B["begin_turn"](sid, stored, text, B["add_message"])
    time.sleep(0.25)
    answer = ""
    producer = {"name": B["bot_title"](profile)[:40], "bot": "hermes" if B["PROFILES"][profile]["is_default"] else profile}
    for kind, *rest in script(text, stored, producer):
        if kind == "sleep":
            time.sleep(rest[0])
        elif kind == "tool":
            args, outcome, *named = rest
            B["tool"](sid, stored, named[0] if named else "widget", args, outcome, 0.3,
                      args.get("op") or args.get("type") or args.get("query"))
        else:
            answer = rest[0] if marked(sid, stored) else as_text(rest[0])
            if B["stream"](sid, answer) is False:
                return B["finish"](sid, stored, answer, status="interrupted")
    return B["finish"](sid, stored, answer)


def inline_block(payload):
    """A widget as the plugin writes it into a reply for a marked room: an inline block."""
    return "```widget\n" + dump(payload) + "\n```"


def room_turn(room, text):
    """A marked room (``/app-widgets room``): Ops answers with a widget for the person as an inline
    block, and acts on answers. The app reads updates with ``/app-widgets get``: a room shows no
    tool rows."""
    C.room_event(room, "message.user", {"kind": "user", "id": "app"}, {"text": text, "thread_id": "main"})
    room["working"] = True
    fields = {"discussion_event_id": "dw", "member_id": "ops", "member_index": 0, "round_index": 0, "task_id": "taskw",
              "thread_id": "main", "turn_id": f"turnw{len(room['events'])}"}
    C.room_event(room, "turn.started", {"kind": "gateway", "id": "mock"}, fields)
    time.sleep(1.0)
    words = ""
    for kind, *rest in script(text, room["room_id"]):
        if kind == "text":
            words = rest[0]
        elif kind == "sleep":
            time.sleep(rest[0])
    if not text.strip().startswith("[widget "):
        # The plugin turns each directive into its payload, inline, for a marked room.
        def block(match):
            payload = newest_payload(match.group(1))
            return inline_block(payload) if payload else match.group(0)
        words = re.sub(r'^::widget\{id="(w_[A-Za-z0-9]+)"[^\n]*\}$', block, words, flags=re.M)
    message = C.room_event(room, "message.member", {"kind": "member", "id": "ops", "profile": "ops"}, {**fields, "text": words})
    C.room_event(room, "turn.settled", {"kind": "gateway", "id": "mock"},
                 {**fields, "message_event_id": message["event_id"], "passed": False, "seen_through_seq": message["seq"]})
    C.room_event(room, "room.activity", {"kind": "gateway", "id": "mock"},
                 {"status": "settled", "reason_code": "silent_round", "thread_id": "main", "discussion_event_id": "dw"})
    room["working"] = False


def newest_payload(widget_id):
    with LOCK:
        record = WIDGETS.get(widget_id)
        return copy.deepcopy(record["revisions"][-1]) if record else None


def install_gateway(gateway):
    """server.py: the toolset in ``/v1/toolsets`` and the scenario in runs."""
    if not ENABLED["on"]:
        return
    if not any(t["name"] == "widgets" for t in gateway.TOOLSETS):
        gateway.TOOLSETS.append(dict(TOOLSET))
    original = gateway.agent_turn

    def agent_turn(run):
        if not matches(run.text):
            return original(run)
        try:
            play_run(run, gateway)
        finally:
            run.finish()

    gateway.agent_turn = agent_turn


def install_backend(backend_globals, chats, push=None):
    """backend.py: the plugin in ``tools.list``, ``/app-widgets``, the scenario in socket chats, and
    another device's answer. With the push mock (push.py), a reply that asks with a widget notifies,
    reading this store as the push plugin reads the real one, and an answer withdraws it."""
    global B, C, PUSH
    B, C = backend_globals, chats
    if not ENABLED["on"]:
        return
    if push is not None and getattr(push, "notices", None) is not None:
        PUSH = push
        push.notices._stored_widget = newest_payload
    methods = backend_globals["METHODS"]
    original_tools, original_dispatch = methods.get("tools.list"), methods.get("command.dispatch")

    def tools_list(params):
        listing = dict(original_tools(params) if original_tools else {"toolsets": []})
        listing["toolsets"] = [r for r in listing.get("toolsets", []) if r.get("name") != "widgets"] + [
            {"name": "widgets", "description": TOOLSET["description"], "tool_count": 2, "enabled": True, "tools": TOOLSET["tools"]}]
        return listing

    def dispatch(params):
        if str(params.get("name") or "").lstrip("/") == "app-widgets":
            return {"type": "plugin", "output": command(params.get("arg") or "")}
        if original_dispatch:
            return original_dispatch(params)
        raise backend_globals["RPCError"](4018, f"not a quick/plugin/bundle/skill command: {params.get('name')}")

    def another_device(query, body):
        # Mock-only: someone answers from another device, as a message in the widget's chat.
        with LOCK:
            # No id: the newest widget a reply made (not a stack's part).
            widget_id = body.get("id") or next((k for k in reversed(list(WIDGETS)) if not WIDGETS[k].get("parent")), "")
            record = WIDGETS.get(widget_id)
            if record is None:
                return 404, {"detail": "No such widget"}
            payload = record["revisions"][-1]
            stored = record.get("session") or ""
        with backend_globals["LOCK"]:
            sid = next((k for k, r in backend_globals["RUNTIME"].items() if r.get("stored") == stored), None)
        if sid is None:
            return 404, {"detail": "That chat isn't open on the socket."}
        line = {"mid": uuid.uuid4().hex, "values": body.get("values") or {}, "device": body.get("device") or "Mac"}
        if body.get("hold"):
            HOLD[line["mid"]] = float(body["hold"])
        text = f"[widget {payload['id']} rev {payload['rev']}] {body.get('action') or 'approve'}\n{dump(line)}"
        runner = chats.run_chat_turn if backend_globals["RUNTIME"][sid].get("kind") == "chat" else backend_globals["run_turn"]
        backend_globals["start_turn"](sid, text, runner)
        return 200, {"ok": True, "session_id": sid, "rev": payload["rev"]}

    methods["tools.list"] = tools_list
    methods["command.dispatch"] = dispatch
    backend_globals["HTTP_ROUTES"][("POST", "/api/mock/widget-answer")] = another_device
    original_turn = chats.run_chat_turn

    def run_chat_turn(sid, text):
        if matches(text):
            return play_socket(sid, text)
        return original_turn(sid, text)

    # Bot Chats run through backend.py's own run_turn (prompt.submit looks it up at each turn).
    original_bot_turn = backend_globals["run_turn"]

    def run_turn(sid, text):
        if matches(text):
            return play_bot_chat(sid, text)
        return original_bot_turn(sid, text)

    backend_globals["run_turn"] = run_turn

    chats.run_chat_turn = run_chat_turn
    original_discussion = chats.run_discussion

    def run_discussion(room, text, wait=True, approve=False):
        if room["room_id"] in ROOMS and matches(text):
            return room_turn(room, text)
        return original_discussion(room, text, wait=wait, approve=approve)

    chats.run_discussion = run_discussion
