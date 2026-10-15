"""What each Hermes event sends (docs/notifications.md §2), as data.

``Notice`` is the content the app shows; it is sealed per device. ``apns_request`` wraps it with the
routing fields the relay and APNs need: category, interruption level, collapse id, expiry, and a
fallback alert that names only the kind ("Hermes needs your OK") so nothing readable leaves the
gateway even if the extension can't decrypt.

Never put a secret, password, code or sudo password in a notice. Hooks never hand those to plugins,
and every command or prompt text that does go in is passed through Hermes's redactor first.
"""
from __future__ import annotations

import hashlib
import re
import time
from dataclasses import asdict, dataclass, field
from typing import Any

from . import crypto

APPROVAL, QUESTION, REPLY, MESSAGE, TASK, OPEN = "APPROVAL", "QUESTION", "REPLY", "MESSAGE", "TASK", "OPEN"

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
}

MAX_BODY = 400
MAX_COMMAND = 600
MAX_CHOICES = 3


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
        return KINDS[self.kind][0]

    def content(self, gateway: dict, open_count: int, resolved: list[str]) -> dict:
        data = {k: v for k, v in asdict(self).items() if v not in ("", None, {}) and k != "extra"}
        data.update(self.extra)
        data.update({"v": 1, "category": self.category, "gateway": gateway, "open": open_count,
                     "resolved": resolved[:20], "sent_at": round(time.time(), 3)})
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


def clip(text: str, limit: int) -> str:
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


_MARKDOWN = [(re.compile(r"```.*?```", re.S), " "), (re.compile(r"`([^`]*)`"), r"\1"),
             (re.compile(r"\*\*([^*]+)\*\*"), r"\1"), (re.compile(r"(?<!\w)\*([^*]+)\*(?!\w)"), r"\1"),
             (re.compile(r"^#+\s*", re.M), ""), (re.compile(r"\[([^\]]+)\]\([^)]+\)"), r"\1"),
             (re.compile(r"^\s*[-*+]\s+", re.M), "• ")]


def plain(markdown: str) -> str:
    text = str(markdown or "")
    for pattern, replacement in _MARKDOWN:
        text = pattern.sub(replacement, text)
    return text


def first_lines(markdown: str, lines: int = 2, limit: int = 240, *, breaks: bool = False) -> str:
    """The text's opening lines, plain. ``breaks`` keeps them as lines (a reply's points read as points
    in the notification) instead of one run of text."""
    rows = [clip(row, limit) for row in plain(markdown).splitlines() if row.strip()]
    if not breaks:
        return clip(" ".join(rows[:lines]), limit)
    text = "\n".join(rows[:lines])
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:24]


# -- builders ---------------------------------------------------------------------------------------

def approval(*, request_id: str, session_id: str, chat: str, gateway_name: str, command: str,
             description: str, choices: list[str], expires_at: float | None, smart_denied: bool = False,
             surface: str = "", bot: str = "") -> Notice:
    command = clip(redact(command), MAX_COMMAND)
    description = clip(redact(description), 200)
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


def task(*, job_id: str, name: str, gateway_name: str, text: str, failed: bool) -> Notice:
    return Notice(
        kind="task_failed" if failed else "task", id=f"task-{short_hash(job_id or name)}",
        thread=f"task:{job_id or name}", summary=name, title=name or "Scheduled task",
        subtitle="Failed" if failed else "", body=first_lines(text, 4, 400, breaks=True) or ("Failed." if failed else "Done."),
        hidden=(f"A task failed on {gateway_name}" if failed else f"A task finished on {gateway_name}"),
        extra={"job_id": job_id, "failed": failed})


def kanban(*, task_id: str, board: str, title: str, assignee: str, gateway_name: str, text: str,
           blocked: bool) -> Notice:
    """A Kanban card finished (or is stuck and needs someone)."""
    name = clip(redact(title), 80) or "Task"
    return Notice(
        kind="task_failed" if blocked else "task", id=f"kanban-{short_hash(task_id)}", thread=f"kanban:{board or 'default'}",
        summary=name, title=name, subtitle=("Blocked" if blocked else "Done") + (f" · {assignee}" if assignee else ""),
        body=first_lines(redact(text), 4, 400) or ("Needs a look." if blocked else "Done."),
        hidden=(f"A task is blocked on {gateway_name}" if blocked else f"A task finished on {gateway_name}"),
        extra={"job_id": task_id, "failed": blocked, "kanban": True})


def message(*, room_id: str, room: str, member_id: str, bot: str, gateway_name: str, text: str,
            mention: bool) -> Notice:
    return Notice(
        kind="message", id=f"msg-{short_hash(room_id + member_id + str(time.time()))}", thread=f"room:{room_id}",
        summary=room, title=bot or member_id, subtitle=room, body=first_lines(text, 3, 300, breaks=True),
        hidden=f"New message on {gateway_name}",
        extra={"room_id": room_id, "member_id": member_id, "bot": bot, "mention": mention})


# -- APNs requests ---------------------------------------------------------------------------------

def apns_request(device: dict, notice: Notice, gateway: dict, open_count: int, resolved: list[str]) -> dict:
    category, level, relevance, fallback = KINDS[notice.kind]
    aps: dict[str, Any] = {
        "alert": {"title": fallback, "body": "Open Hermes to see it."},
        "mutable-content": 1, "category": category, "interruption-level": level, "relevance-score": relevance,
    }
    if level != "passive":
        aps["sound"] = "default"
    request = {
        "token": device["token"], "environment": device.get("environment", "production"), "topic": device["topic"],
        "push_type": "alert", "priority": 10 if level in ("time-sensitive", "active") else 5,
        "payload": {"aps": aps, "hermes": crypto.seal(device["public_key"], notice.content(gateway, open_count,
                                                                                            resolved))},
    }
    if notice.request_id or notice.kind in ("reply", "task", "task_failed"):
        request["collapse_id"] = (notice.request_id or notice.id)[:64]
    expiry = notice.expires_at or time.time() + 86_400
    request["expiration"] = int(expiry)
    return request


def withdraw_request(device: dict, ids: list[str], gateway: dict, open_count: int) -> dict:
    """A background push: the app (or the next extension run) removes these delivered notices."""
    content = {"v": 1, "kind": "withdraw", "ids": ids, "gateway": gateway, "open": open_count,
               "sent_at": round(time.time(), 3)}
    return {"token": device["token"], "environment": device.get("environment", "production"),
            "topic": device["topic"], "push_type": "background", "priority": 5, "expiration": int(time.time() + 900),
            "payload": {"aps": {"content-available": 1}, "hermes": crypto.seal(device["public_key"], content)}}


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
