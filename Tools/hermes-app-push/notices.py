"""What each Hermes event sends (docs/notifications.md §2), as data.

``Notice`` is the content the app shows; it is sealed per device. ``apns_request`` wraps it with the
routing fields the relay and APNs need: category, interruption level, collapse id, expiry, and a
fallback alert that names only the kind ("Hermes needs your OK") so nothing readable leaves the
gateway even if the extension can't decrypt.

Never put a secret, password, code or sudo password in a notice. Hooks never hand those to plugins,
and every command or prompt text that does go in is passed through Hermes's redactor first.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import re
import time
from datetime import datetime
from dataclasses import asdict, dataclass, field
from typing import Any

from . import crypto

APPROVAL, QUESTION, REPLY, MESSAGE, TASK, OPEN = "APPROVAL", "QUESTION", "REPLY", "MESSAGE", "TASK", "OPEN"
CARD, BOARD = "CARD", "BOARD"  # a board card needs you (Reply, Open); a card's other news (Open)
MEMORY = "MEMORY"  # an approval titled "Save to memory?": Save, Don't Save (docs/memory.md)
# A card fill waiting for the person's OK (tools/browser_vault_tool.py _confirm_payment_fill): Hermes
# asks through the gateway's approval queue under this surface, and the app answers it only on its card,
# with Face ID (docs/web.md §4.3).
PAYMENT_SURFACE = "vault-payment"

KINDS = {
    # kind: (category, interruption level, relevance, fallback title)
    "approval": (APPROVAL, "time-sensitive", 1.0, "Hermes needs your OK"),
    "question": (QUESTION, "time-sensitive", 0.9, "Hermes has a question"),
    "password": (OPEN, "time-sensitive", 1.0, "Hermes needs a password"),
    "reply": (REPLY, "active", 0.5, "Hermes replied"),
    "task": (TASK, "passive", 0.3, "A scheduled task finished"),
    "task_failed": (TASK, "active", 0.6, "A scheduled task failed"),
    "message": (MESSAGE, "active", 0.6, "New message"),
    "background": (OPEN, "passive", 0.2, "Background work finished"),
    "test": (OPEN, "active", 0.4, "Push notifications are on"),
    # The Board (docs/board.md §5). Never "task": in the app, tasks are scheduled jobs.
    "card_needs_you": (CARD, "time-sensitive", 1.0, "A card needs you"),
    "card_review": (BOARD, "active", 0.6, "A card is ready for review"),
    "card_stopped": (BOARD, "active", 0.6, "A card stopped"),
    "card_done": (BOARD, "passive", 0.3, "A card is done"),
    # What Hermes Learned (docs/learned.md): a tidy that changed something. Opens Tidying.
    "tidied": (OPEN, "passive", 0.2, "Hermes tidied its skills"),
    # A widget request in a reply (docs/widgets.md §12): Open only, answered on its card.
    "widget": (OPEN, "time-sensitive", 1.0, "Hermes needs your OK"),
}
CARD_KINDS = ("card_needs_you", "card_review", "card_stopped", "card_done")

MAX_BODY = 400
MAX_COMMAND = 600
MAX_CHOICES = 3
MAX_PAYLOAD = 4096  # the relay's limit on a payload's JSON, and APNs's


@dataclass
class Notice:
    kind: str
    id: str
    title: str
    body: str
    subtitle: str = ""
    hidden: str = ""           # Lock Screen text when details are hidden: the kind and the gateway
    thread: str = ""           # threadIdentifier: the chat (session key), room id or task id
    summary: str = ""          # summaryArgument: the chat title
    session_id: str = ""       # durable session key, for opening the chat
    request_id: str = ""       # what an answer (approval.respond / clarify) targets
    expires_at: float | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def category(self) -> str:
        return MEMORY if self.kind == "approval" and self.extra.get("memory") else KINDS[self.kind][0]

    def content(self, gateway: dict, open_count: int, resolved: list[str], read: dict | None = None) -> dict:
        """``read``: the chats and rooms read lately (``store.recent_reads``), so the service extension clears
        their notifications whenever this one arrives (docs/notifications.md §2, Reading)."""
        data = {k: v for k, v in asdict(self).items() if v not in ("", None, {}) and k != "extra"}
        data.update(self.extra)
        data.update({"v": 1, "category": self.category, "gateway": gateway, "open": open_count,
                     "resolved": resolved[:20], "sent_at": round(time.time(), 3)})
        if read and (read.get("chats") or read.get("rooms")):
            data["read"] = {"chats": [list(r) for r in read.get("chats") or []],
                            "rooms": [list(r) for r in read.get("rooms") or []]}
        return data


# -- text helpers ------------------------------------------------------------------------------------

def redact(text: str) -> str:
    """Hermes's own redactor, forced; empty when it can't run (never fall back to the raw text)."""
    if not text:
        return ""
    try:
        from agent.redact import redact_sensitive_text
        return redact_sensitive_text(str(text), force=True)
    except Exception:
        return ""


ELLIPSIS = "…"


def clip(text: str, limit: int) -> str:
    """The text on one line in at most ``limit`` UTF-8 bytes: the relay and APNs count bytes, and a
    character outside ASCII takes two to four."""
    return cut(re.sub(r"\s+", " ", str(text or "")).strip(), limit)


def cut(text: str, limit: int) -> str:
    """``text`` in at most ``limit`` UTF-8 bytes, cut between characters and ended with "…" when cut:
    the app reads that as clipped, and a clipped command never offers Allow (security scan F7)."""
    data = text.encode()
    if len(data) <= limit:
        return text
    kept = data[: max(0, limit - len(ELLIPSIS.encode()))].decode("utf-8", errors="ignore")
    return kept.rstrip() + ELLIPSIS


# Every pattern here reads reply, room and cron text the agent wrote, so none may take more than
# one pass over it: a run of "[" with no "]", a long word inside ::widget{…}, or many lines of blank
# space made the earlier ones quadratic, holding the GIL for seconds (security scan F28).
_MARKDOWN = [(re.compile(r"```.*?```", re.S), " "), (re.compile(r"`([^`]*)`"), r"\1"),
             (re.compile(r"\*\*([^*]+)\*\*"), r"\1"), (re.compile(r"(?<!\w)\*([^*]+)\*(?!\w)"), r"\1"),
             (re.compile(r"^#+[ \t]*", re.M), ""), (re.compile(r"\[([^\[\]\n]+)\]\([^()\n]+\)"), r"\1"),
             (re.compile(r"^[ \t]*[-*+][ \t]+", re.M), "• ")]
# What a notice reads of a reply: its opening lines are all it shows.
MAX_PLAIN = 64_000


_WIDGET_OPEN = re.compile(r"(`{3,})widget")
_WIDGET_LINE = re.compile(r"^[ \t]*::widget\{(?P<attrs>[^\n]*)\}[ \t]*$", re.M)
_WIDGET_ATTR = re.compile(r'(?<![\w-])([A-Za-z_][\w-]*)\s*=\s*"((?:[^"\\]|\\.)*)"')
PRIVATE_WIDGET = "Hermes sent a widget."


def _stored_widget(widget_id: str) -> dict | None:
    """The newest revision hermes-app-widgets stored for a directive's id, if that plugin runs here."""
    if not re.fullmatch(r"w_[A-Za-z0-9]{6,40}", widget_id or ""):
        return None
    try:
        from .store import _root_home
        from pathlib import Path
        record = json.loads((Path(_root_home()) / "widgets" / f"{widget_id}.json").read_text())
        return record["revisions"][-1]
    except Exception:
        return None


def _widget_blocks(text: str) -> list[tuple[int, int, str]]:
    """Each ```widget block as (start, end, body), found line by line: an opener that never closes
    costs no second pass, the next opener simply takes over."""
    blocks: list[tuple[int, int, str]] = []
    opener: tuple[int, str, int] | None = None
    position = 0
    for line in text.split("\n"):
        if opener is not None and line.rstrip(" \t") == opener[1]:
            start, _fence, body = opener
            blocks.append((start, position + len(line), text[body:max(body, position - 1)]))
            opener = None
        elif match := _WIDGET_OPEN.match(line):
            opener = (position, match.group(1), position + len(line) + 1)
        position += len(line) + 1
    return blocks


def _is_private(payload: dict) -> bool:
    """Private unless it says normal, read failing closed (payload-contract.md §10)."""
    return str(payload.get("sensitivity") or "normal") != "normal"


REQUEST_TYPES = ("approval", "choice", "form")


def widget_requests(text: str) -> list[dict]:
    """The open requests a reply carries: approvals, questions and forms not yet resolved, as
    hermes-app-widgets stored them for its directive lines, or as its inline blocks carry them.
    Suggested follow-ups aren't requests."""
    if "widget" not in (text or ""):
        return []
    found: list[dict] = []
    for match in _WIDGET_LINE.finditer(text):
        attrs = {k: re.sub(r"\\(.)", r"\1", v) for k, v in _WIDGET_ATTR.findall(match["attrs"])}
        stored = _stored_widget(attrs.get("id", ""))
        if stored:
            found.append(stored)
    for _start, _end, body in _widget_blocks(text):
        try:
            payload = json.loads(body)
        except ValueError:
            continue
        if isinstance(payload, dict):
            found.append(payload)
    return [p for p in found if p.get("type") in REQUEST_TYPES and isinstance(p.get("id"), str)
            and not p.get("resolution") and p.get("style") != "suggestions"]


def widget_text(text: str) -> str:
    """Widgets read as their plain text in a notice, and a private one as "Hermes sent a widget."
    (docs/widgets/payload-contract.md §9): an inline block becomes its fallback_text, a directive line
    its alt."""
    def block(body: str) -> str:
        try:
            payload = json.loads(body)
        except ValueError:
            return ""
        if not isinstance(payload, dict) or _is_private(payload):
            return PRIVATE_WIDGET
        return str(payload.get("fallback_text") or payload.get("title") or PRIVATE_WIDGET)

    def line(match: re.Match) -> str:
        attrs = {k: re.sub(r"\\(.)", r"\1", v) for k, v in _WIDGET_ATTR.findall(match["attrs"])}
        stored = _stored_widget(attrs.get("id", ""))
        if stored is not None and _is_private(stored):
            return PRIVATE_WIDGET
        return attrs.get("alt") or PRIVATE_WIDGET

    if "widget" not in text:
        return text
    pieces, last = [], 0
    for start, end, body in _widget_blocks(text):
        pieces += [text[last:start], block(body)]
        last = end
    pieces.append(text[last:])
    return _WIDGET_LINE.sub(line, "".join(pieces))


def plain(markdown: str) -> str:
    text = widget_text(str(markdown or "")[:MAX_PLAIN])
    for pattern, replacement in _MARKDOWN:
        text = pattern.sub(replacement, text)
    return text


def first_lines(markdown: str, lines: int = 2, limit: int = 240, *, breaks: bool = False) -> str:
    """The text's opening lines, plain. ``breaks`` keeps them as lines (a reply's points read as points
    in the notification) instead of one run of text."""
    rows = [clip(row, limit) for row in plain(markdown).splitlines() if row.strip()]
    if not breaks:
        return clip(" ".join(rows[:lines]), limit)
    return cut("\n".join(rows[:lines]), limit)


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:24]


# -- builders ---------------------------------------------------------------------------------------

def approval(*, request_id: str, session_id: str, chat: str, gateway_name: str, command: str,
             description: str, choices: list[str], expires_at: float | None, smart_denied: bool = False,
             surface: str = "", bot: str = "") -> Notice:
    command = clip(redact(command), MAX_COMMAND)
    description = clip(redact(description), 200)
    if description.startswith("Save to memory"):
        # The memory tool asking before it saves: the entry is the one memory text a push carries.
        return Notice(
            kind="approval", id=request_id, request_id=request_id, session_id=session_id, thread=session_id,
            summary=chat, title=f"{bot} wants to remember something" if bot else "Hermes wants to remember something",
            subtitle=chat, body=clip(command, 240), hidden=f"Wants to remember something on {gateway_name}",
            expires_at=expires_at,
            extra={"command": command, "description": description, "choices": [c for c in choices if c != "always"],
                   "memory": True, "surface": surface, **({"bot": bot} if bot else {})})
    shown = clip(command, 80) or "a command"
    return Notice(
        kind="approval", id=request_id, request_id=request_id, session_id=session_id, thread=session_id,
        summary=chat, title=f"{bot} needs your OK" if bot else "Hermes needs your OK", subtitle=chat,
        body=f"Run {shown} on {gateway_name}?", hidden=f"Needs your OK on {gateway_name}", expires_at=expires_at,
        extra={"command": command, "description": description, "choices": choices, "smart_denied": smart_denied,
               "surface": surface, **({"bot": bot} if bot else {})})


def question(*, request_id: str, session_id: str, chat: str, gateway_name: str, questions: list[dict],
             prompt: str, expires_at: float | None, bot: str = "") -> Notice:
    first = questions[0] if questions else {}
    text = clip(redact(first.get("question") or prompt), MAX_BODY)
    choices = [clip(redact(c), 60) for c in (first.get("choices") or [])][:MAX_CHOICES]
    cleaned = [{"question": clip(redact(q.get("question", "")), MAX_BODY),
                "choices": [clip(redact(c), 60) for c in (q.get("choices") or [])][:8],
                "multi_select": bool(q.get("multi_select"))} for q in questions[:4]]
    return Notice(
        kind="question", id=request_id, request_id=request_id, session_id=session_id, thread=session_id,
        summary=chat, title=f"{bot} has a question" if bot else "Hermes has a question", subtitle=chat,
        body=text or "Open Hermes to answer.", hidden=f"Has a question on {gateway_name}", expires_at=expires_at,
        extra={"choices": choices if len(questions) <= 1 and not first.get("multi_select") else [],
               "questions": cleaned, **({"bot": bot} if bot else {})})


def password(*, request_id: str, session_id: str, chat: str, gateway_name: str, what: str,
             expires_at: float | None) -> Notice:
    # ``what`` is the command a sudo password is for, redacted; never a value.
    what = clip(redact(what), 120)
    return Notice(
        kind="password", id=request_id, request_id=request_id, session_id=session_id, thread=session_id,
        summary=chat, title="Hermes needs a password", subtitle=chat,
        body=f"For {what}" if what else "Open Hermes to enter it.", hidden=f"Needs a password on {gateway_name}",
        expires_at=expires_at)


def reply(*, session_id: str, turn_id: str, chat: str, gateway_name: str, text: str, seconds: float) -> Notice:
    # The gist of the answer, not just "Hermes replied": the first lines, enough to act on.
    return Notice(
        kind="reply", id=f"reply-{short_hash(session_id)}", session_id=session_id, thread=session_id, summary=chat,
        title=chat or "Hermes", body=first_lines(text, 4, 480, breaks=True) or "Hermes finished.",
        hidden=f"Reply ready on {gateway_name}", extra={"turn_id": turn_id, "seconds": round(seconds)})


def widget(*, payload: dict, session_id: str, chat: str, gateway_name: str, bot: str = "") -> Notice:
    """A widget request in a reply (docs/notifications.md §2): "<Bot> needs your OK" with the
    widget's title, or only "<Bot> sent a request" for a private one. Open only: it's answered on
    its card, where Face ID and the signature are."""
    who = bot or "Hermes"
    private = _is_private(payload)
    title = clip(redact(str(payload.get("title") or "")), 120)
    expires_at = None
    with contextlib.suppress(Exception):
        expires_at = datetime.fromisoformat(str(payload.get("expires_at")).replace("Z", "+00:00")).timestamp()
    return Notice(
        kind="widget", id=payload["id"], request_id=payload["id"], session_id=session_id, thread=session_id,
        summary=chat, title=f"{who} sent a request" if private else f"{who} needs your OK", subtitle=chat,
        body="Open Hermes to answer." if private or not title else title,
        hidden=f"Needs your OK on {gateway_name}", expires_at=expires_at,
        extra={"widget_type": payload.get("type"), "private": private, **({"bot": bot} if bot else {})})


def task(*, job_id: str, name: str, gateway_name: str, text: str, failed: bool) -> Notice:
    return Notice(
        kind="task_failed" if failed else "task", id=f"task-{short_hash(job_id or name)}",
        thread=f"task:{job_id or name}", summary=name, title=name or "Scheduled task",
        subtitle="Failed" if failed else "", body=first_lines(text, 4, 400, breaks=True) or ("Failed." if failed else "Done."),
        hidden=(f"A task failed on {gateway_name}" if failed else f"A task finished on {gateway_name}"),
        extra={"job_id": job_id, "failed": failed})


def card(kind: str, *, card_id: str, board: str, title: str, who: str, profile: str, project_id: str,
         gateway_name: str, text: str) -> Notice:
    """A board card: needs you (with the question), ready for review, stopped, or done. One notice
    per card at a time (the id collapses them); the thread is the board."""
    name = clip(redact(title), 80) or "A card"
    who = who or "Hermes"
    if kind == "card_needs_you":
        heading, subtitle, fallback = f"{who} needs you on “{name}”", "", "Open Hermes to answer."
        hidden = f"A card needs you on {gateway_name}"
    elif kind == "card_review":
        heading, subtitle, fallback = "Ready for review", name, "Open Hermes to review it."
        hidden = f"A card is ready for review on {gateway_name}"
    elif kind == "card_stopped":
        heading, subtitle, fallback = "Stopped", name, "It stopped before it was done."
        hidden = f"A card stopped on {gateway_name}"
    else:
        heading, subtitle, fallback = "Done", name, "Done."
        hidden = f"A card is done on {gateway_name}"
    return Notice(
        kind=kind, id=f"card-{short_hash(card_id)}", thread=f"board:{board or 'default'}", summary=name,
        title=heading, subtitle=subtitle, body=first_lines(redact(text), 4, 400) or fallback, hidden=hidden,
        extra={"card_id": card_id, "board": board or "default", "project_id": project_id or "",
               "card_title": name, **({"bot": who} if who != "Hermes" else {}), "assignee": profile or ""})


def tidied(*, profile: str, who: str, gateway_name: str, run: str, merged: int, archived: int,
           stale: int) -> Notice:
    """One quiet notice per Bot after its curator tidied: "Merged 2 overlapping skills and archived 3
    unused ones." The id collapses it with the previous tidy's."""
    parts = []
    if merged:
        parts.append(f"merged {merged} overlapping skill{'' if merged == 1 else 's'}")
    if archived:
        parts.append(f"archived {archived} unused one{'' if archived == 1 else 's'}")
    if stale:
        parts.append(f"marked {stale} as stale")
    sentence = ", ".join(parts[:-1]) + " and " + parts[-1] if len(parts) > 1 else "".join(parts)
    key = profile or "default"
    return Notice(
        kind="tidied", id=f"tidy-{short_hash(key)}", thread=f"learned:{key}", title=f"{who} tidied its skills",
        body=(sentence[:1].upper() + sentence[1:] + ".") if sentence else "Its skills are tidier.",
        hidden=f"Skills were tidied on {gateway_name}",
        extra={"run": run, "merged": merged, "archived": archived, "stale": stale,
               **({"profile": profile, "bot": who} if profile else {})})


def message(*, room_id: str, room: str, member_id: str, bot: str, gateway_name: str, text: str,
            mention: bool) -> Notice:
    return Notice(
        kind="message", id=f"msg-{short_hash(room_id + member_id + str(time.time()))}", thread=f"room:{room_id}",
        summary=room, title=bot or member_id, subtitle=room, body=first_lines(text, 3, 300, breaks=True),
        hidden=f"New message on {gateway_name}",
        extra={"room_id": room_id, "member_id": member_id, "bot": bot, "mention": mention})


# -- APNs requests ---------------------------------------------------------------------------------

def opens_only(notice: Notice) -> bool:
    """An approval answered only on its card in the app, never from a notification or the Lock Screen:
    a command Hermes's safety check flagged, or a card fill."""
    return notice.kind == "approval" and bool(notice.extra.get("smart_denied")
                                              or notice.extra.get("surface") == PAYMENT_SURFACE)


def apns_request(device: dict, notice: Notice, gateway: dict, open_count: int, resolved: list[str],
                 read: dict | None = None) -> dict:
    category, level, relevance, fallback = KINDS[notice.kind]
    if notice.category == MEMORY:
        category, level, fallback = MEMORY, "active", "Hermes wants to remember something"
    if notice.kind == "widget" and notice.extra.get("widget_type") != "approval":
        level, relevance = "active", 0.8  # a question or a form waits; only approvals are time sensitive
    if opens_only(notice):
        # Answered on its card in the app, never from a banner: even the fallback notification (before
        # the app's extension runs) offers no Allow.
        category = OPEN
    aps: dict[str, Any] = {
        "alert": {"title": fallback, "body": "Open Hermes to see it."},
        "mutable-content": 1, "category": category, "interruption-level": level, "relevance-score": relevance,
    }
    if level != "passive":
        aps["sound"] = "default"
    content = notice.content(gateway, open_count, resolved, read)
    _fit(aps, content)
    request = {
        "token": device["token"], "environment": device.get("environment", "production"), "topic": device["topic"],
        "push_type": "alert", "priority": 10 if level in ("time-sensitive", "active") else 5,
        "payload": {"aps": aps, "hermes": crypto.seal(device["public_key"], content)},
    }
    if notice.request_id or notice.kind in ("reply", "task", "task_failed", "tidied", *CARD_KINDS):
        request["collapse_id"] = (notice.request_id or notice.id)[:64]
    expiry = notice.expires_at or time.time() + 86_400
    request["expiration"] = int(expiry)
    return request


def payload_size(aps: dict, content: dict) -> int:
    """The bytes of ``{"aps", "hermes": seal(content)}`` as the relay counts them, without sealing: the
    envelope's box is base64 of nonce (12) + the compact JSON + tag (16), as ``crypto.seal`` makes it."""
    plain = len(json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode())
    envelope = {"v": 1, "epk": "A" * 44, "box": "A" * (4 * -(-(plain + 28) // 3))}
    return len(json.dumps({"aps": aps, "hermes": envelope}, ensure_ascii=False, separators=(",", ":")).encode())


def _fit(aps: dict, content: dict) -> None:
    """Makes a notice fit the relay's limit. First the oldest reads it lists go: they're a hint the next
    notice, an app refresh or coming back to the app also brings. Then its longest text is halved until
    it fits (a long command, a description, four questions with their choices), each cut marked "…"."""
    read = content.get("read")
    while read and payload_size(aps, content) > MAX_PAYLOAD:
        kinds = [kind for kind in ("chats", "rooms") if read[kind]]
        oldest = min(kinds, key=lambda kind: read[kind][-1][1])
        read[oldest].pop()
        if not read["chats"] and not read["rooms"]:
            content.pop("read")
            break
    while payload_size(aps, content) > MAX_PAYLOAD:
        texts = _texts(content)
        if not texts:
            break
        holder, key, size = max(texts, key=lambda text: text[2])
        if size <= MIN_TEXT:
            break
        holder[key] = cut(holder[key], max(MIN_TEXT, size // 2))
    if payload_size(aps, content) > MAX_PAYLOAD:
        # Only the ids are left to give: the requests answered lately, then the extra questions.
        content.pop("resolved", None)
        if content.get("questions"):
            content["questions"] = content["questions"][:1]


MIN_TEXT = 24  # bytes: a cut never leaves less of a text than this
_TRIMMABLE = ("body", "description", "command", "subtitle", "summary", "title", "card_title", "detail")


def _texts(content: dict) -> list[tuple[Any, Any, int]]:
    """Each text a notice carries that may be cut, as (holder, key, UTF-8 bytes): the notice's own and its
    questions' texts and choices."""
    texts = [(content, key, len(content[key].encode())) for key in _TRIMMABLE if isinstance(content.get(key), str)]
    for question in content.get("questions") or []:
        if isinstance(question, dict) and isinstance(question.get("question"), str):
            texts.append((question, "question", len(question["question"].encode())))
        choices = question.get("choices") if isinstance(question, dict) else None
        for index, choice in enumerate(choices or []):
            if isinstance(choice, str):
                texts.append((choices, index, len(choice.encode())))
    return [text for text in texts if text[2] > MIN_TEXT]


def withdraw_request(device: dict, ids: list[str], gateway: dict, open_count: int) -> dict:
    """A background push: the app (or the next extension run) removes these delivered notices."""
    content = {"v": 1, "kind": "withdraw", "ids": ids, "gateway": gateway, "open": open_count,
               "sent_at": round(time.time(), 3)}
    return {"token": device["token"], "environment": device.get("environment", "production"),
            "topic": device["topic"], "push_type": "background", "priority": 5, "expiration": int(time.time() + 900),
            "payload": {"aps": {"content-available": 1}, "hermes": crypto.seal(device["public_key"], content)}}


def sync_request(device: dict, sessions: list[str], gateway: dict, open_count: int, profile: str | None = None) -> dict:
    """A background push: these chats changed, so the app reads them now and is up to date when the person
    comes back to it."""
    content = {"v": 1, "kind": "sync", "sessions": sessions, "gateway": gateway, "open": open_count,
               "sent_at": round(time.time(), 3)}
    if profile:
        content["profile"] = profile
    return {"token": device["token"], "environment": device.get("environment", "production"),
            "topic": device["topic"], "push_type": "background", "priority": 5, "expiration": int(time.time() + 1800),
            "payload": {"aps": {"content-available": 1}, "hermes": crypto.seal(device["public_key"], content)}}


def read_request(device: dict, read: dict, gateway: dict, open_count: int) -> dict:
    """A background push: these chats and rooms were read on another device since this one was last in the
    app, so it removes the notifications sent before each was read and sets the badge. ``read`` is shaped
    like a notice's (``{chats: [[id, at], …], rooms}``) and names everything read since then, so a later
    one replaces an earlier one (collapse id ``read``)."""
    content = {"v": 1, "kind": "read", "read": {"chats": list(read.get("chats") or []),
                                                "rooms": list(read.get("rooms") or [])},
               "gateway": gateway, "open": open_count, "sent_at": round(time.time(), 3)}
    return {"token": device["token"], "environment": device.get("environment", "production"),
            "topic": device["topic"], "push_type": "background", "priority": 5, "collapse_id": "read",
            "expiration": int(time.time() + 3600),
            "payload": {"aps": {"content-available": 1}, "hermes": crypto.seal(device["public_key"], content)}}


def badge_request(device: dict, count: int) -> dict:
    """A badge-only push: the app icon's count, nothing shown and nothing sealed (the relay takes exactly
    ``{aps: {badge}}`` at priority 5), for when the app isn't woken."""
    return {"token": device["token"], "environment": device.get("environment", "production"),
            "topic": device["topic"], "push_type": "alert", "priority": 5, "collapse_id": "badge",
            "expiration": int(time.time() + 3600), "payload": {"aps": {"badge": max(0, min(int(count), 9999))}}}


def activity_request(device: dict, activity: dict, state: dict, *, event: str = "update", alert: bool = False,
                     dismiss_after: float | None = None) -> dict:
    """A Live Activity update. ``content-state`` carries only the phase in the clear; the rest is sealed
    and the widget opens it with the same device key as the extension."""
    now = int(time.time())
    aps: dict[str, Any] = {
        "timestamp": now, "event": event,
        "content-state": {"phase": state.get("phase", "working"), "sealed": crypto.seal(device["public_key"], state)},
        "stale-date": now + 900, "relevance-score": 100 if state.get("phase") == "needsYou" else 50,
    }
    if alert:
        aps["alert"] = {"title": KINDS["approval"][3], "body": "Open Hermes to answer."}
        aps["sound"] = "default"
    if event == "end":
        aps["dismissal-date"] = int(now + (dismiss_after if dismiss_after is not None else 240))
    return {"token": activity["token"], "environment": device.get("environment", "production"),
            "topic": f"{device['topic']}.push-type.liveactivity", "push_type": "liveactivity",
            "priority": 10 if alert or event == "end" else 5, "payload": {"aps": aps}}
