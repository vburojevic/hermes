"""The plugin's brain: devices, hooks → notices, withdrawals, Live Activities, cron delivery.

Everything here is best-effort and off the agent's path: hook handlers do a little bookkeeping and
enqueue; the relay thread does the network. A failure is logged and never raised into Hermes.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

from . import crypto, hostinfo, notices
from .relay import DEAD_TOKEN_REASONS, Delivery, Relay
from .store import Store, recent_reads

logger = logging.getLogger("hermes_app_push")
VERSION = "1.4.4"

DEFAULT_PREFERENCES = {
    "approvals": True,          # approvals and questions
    "passwords": True,          # password, secret and sign-in prompts
    "replies": True,
    "reply_after": 30,          # seconds a turn must run before its reply notifies
    "tasks": "all",             # all | failures | off (scheduled tasks and Kanban cards)
    "bots": "mentions",         # all | mentions | off
    "background": True,         # unused: helpers no longer notify on their own; older apps still send it
    "live_activity": True,
    "show_details": "always",  # always | unlocked | never (the app applies it; synced for completeness)
    "mention_names": [],        # how the person is @mentioned in group chats
}
CHOICE_OPTIONS = {"tasks": {"all", "failures", "off"}, "bots": {"all", "mentions", "off"},
                  "show_details": {"always", "unlocked", "never"}}
_TOKEN = re.compile(r"^[0-9a-fA-F]{32,400}$")
_TOPIC = re.compile(r"^[A-Za-z0-9.-]{3,200}$")
_DEVICE = re.compile(r"^[A-Za-z0-9._:-]{4,80}$")
ACTIVITY_MIN_INTERVAL = 12.0   # seconds between "working" Live Activity updates
CARD_POLL_SECONDS = 5.0        # how often the gateway looks for cards ready for review or stopped, while busy
CARD_IDLE_POLL_SECONDS = 30.0  # the slowest it looks once no card is running and the boards are quiet
TIDY_POLL_SECONDS = 30.0       # how often it looks for a finished tidy (the curator's run reports)
ROOM_MESSAGE_SETTLE = 5.0      # a Bot's streamed message counts as finished after this quiet time
PUSH_DEBOUNCE = 3.0            # a read or badge push waits this long, so a burst of reads goes as one
MAX_PRESENCE_IDS = 200         # chats (and rooms) a device may name as unread or muted when it leaves
MAX_LISTED_IDS = 600           # chats (and rooms) its list shows, when it leaves
MAX_READ_IDS = 50              # chats (and rooms) one ``read`` may name
# Surfaces whose replies the app reports. A messaging platform's own app already notifies, and cron
# results come through the delivery platform.
NOTIFY_PLATFORMS = {"", "api_server", "api", "tui", "desktop", "dashboard", "webui", "cli", "local", "acp"}
# One board watcher per process. A multiplexed gateway imports this plugin once per profile it serves,
# each copy under its own module name (often from its own install), and a reload imports it again: the
# registry lives on ``sys``, which every copy shares.
_WATCHER = "_hermes_app_push_watcher"
# This copy's seat in the registry: the package Hermes imported it as (one per profile scope, the same
# across reloads, so a reloaded copy takes its predecessor's seat).
_SCOPE = __name__.rpartition(".")[0] or __name__


class PushError(ValueError):
    pass


class Push:
    def __init__(self, *, store: Store | None = None, config: Callable[[str, Any], Any] | None = None,
                 later: Callable[[float, Callable[[], None], tuple[str, str]], Any] | None = None):
        self.store = store or Store()
        # Runs a read or badge push's flush after a delay, ``later(seconds, flush, (kind, device))``: a daemon
        # timer; tests pass their own.
        self._later = later or _later
        self._due: set[tuple[str, str]] = set()     # (read | badge, device) flushes waiting in this process
        self._config = config or (lambda key, default=None: default)
        self.relay = Relay(self.store, lambda: str(self._config("relay_url", "") or ""), self.gateway_name)
        self._lock = threading.RLock()
        self._turns: dict[str, dict] = {}          # turn_id -> {session, start, text}
        self._active_sessions: dict[str, int] = {}  # session -> running turns
        self._clarify: dict[str, list[dict]] = {}   # session -> questions from the latest clarify call
        self._activity_sent: dict[str, float] = {}  # activity id -> last working update
        self._activity_state: dict[str, dict] = {}  # session -> latest Live Activity state
        self._room_buffers: dict[tuple, dict] = {}
        self._titles: dict[str, tuple[float, str]] = {}

    # -- identity -----------------------------------------------------------------------------------

    def gateway_name(self) -> str:
        configured = str(self._config("gateway_name", "") or "").strip()
        if configured:
            return configured[:64]
        name = socket.gethostname().split(".")[0]
        return name[:64] or "Hermes"

    def gateway(self) -> dict:
        return {"id": self.relay.installation_id() or "", "name": self.gateway_name()}

    def chat_title(self, session_key: str) -> str:
        if not session_key:
            return ""
        cached = self._titles.get(session_key)
        if cached and time.time() - cached[0] < 120:
            return cached[1]
        title = ""
        with contextlib.suppress(Exception):
            from hermes_state import SessionDB
            title = SessionDB().get_session_title(session_key) or ""
        self._titles[session_key] = (time.time(), title)
        return title

    # -- the app's commands (``/app-push <name> <json>`` through command.dispatch) ---------------------

    def register(self, args: dict) -> dict:
        device_id = _require(args, "device_id", _DEVICE)
        token = _require(args, "token", _TOKEN).lower()
        topic = _require(args, "topic", _TOPIC)
        environment = args.get("environment", "production")
        if environment not in ("development", "production"):
            raise PushError("environment must be development or production")
        public_key = str(args.get("public_key") or "")
        crypto.parse_public_key(public_key)  # raises ValueError on a bad key
        record = {"token": token, "topic": topic, "environment": environment, "public_key": public_key,
                  "platform": str(args.get("platform") or "ios")[:16], "name": str(args.get("name") or "")[:80],
                  "app_version": str(args.get("app_version") or "")[:32],
                  "preferences": _preferences(args.get("preferences") or {})}
        self.store.put_device(device_id, record)
        _wake()  # the board watcher starts from now for this device without waiting out an idle pause
        relay = "ok"
        try:
            self.relay.ensure_installation()
        except Exception as exc:
            relay = f"error: {exc}"
        return {"ok": True, "version": VERSION, "gateway": self.gateway(), "relay": relay,
                "devices": len(self.store.devices())}

    def unregister(self, args: dict) -> dict:
        device_id = _require(args, "device_id", _DEVICE)
        return {"ok": True, "removed": self.store.remove_device(device_id)}

    def preferences(self, args: dict) -> dict:
        device_id = _require(args, "device_id", _DEVICE)
        if device_id not in self.store.devices():
            raise PushError("device not registered")
        prefs = _preferences(args.get("preferences") or {})
        self.store.put_device(device_id, {"preferences": prefs})
        return {"ok": True, "preferences": prefs}

    def presence(self, args: dict) -> dict:
        """``state``: ``foreground`` (``session_id`` = the visible chat), ``running`` (the Mac app is open but
        not in front), or ``away``. ``live``: chats the app hears over its own connection and notifies about
        itself (the Mac); without it, a ``running`` device gets nothing pushed. ``sync`` (with ``away``): the
        chats to keep current on the device while it's away (``_sync``). ``unread`` and ``muted`` (with
        ``away``, ``{chats, rooms}``): what its badge counts as it leaves, and what it never counts, with
        ``badge_others`` what the person's other gateways add to it; a device that sends no ``unread`` gets no
        badge pushes (docs/notifications.md §2, Reading)."""
        device_id = _require(args, "device_id", _DEVICE)
        state = args.get("state")
        if state not in ("foreground", "running", "away"):
            raise PushError("state must be foreground, running or away")
        live = args.get("live")
        live = [str(s)[:120] for s in live if s][:200] if isinstance(live, list) else None
        session = str(args.get("session_id") or "") or None
        self.store.set_presence(device_id, state, session, live)
        # Leaving, the app names the chats to keep current while it's away (``sync``); older apps don't.
        if state == "away" and isinstance(args.get("sync"), list):
            self.store.set_sync(device_id, [str(s)[:120] for s in args["sync"] if s][:20])
        if state == "foreground":
            self.store.reset_reading(device_id)  # the app decides what's read while it's in front
        elif state == "away":
            unread = _id_sets(args.get("unread"))
            others = args.get("badge_others")
            others = min(int(others), 9999) if isinstance(others, (int, float)) and not isinstance(others, bool) and others > 0 else 0
            self.store.set_badge(device_id, unread, _id_sets(args.get("muted")) if unread is not None else None, others,
                                 _id_sets(args.get("listed"), MAX_LISTED_IDS))
        self._release_held(device_id, state, session, live)
        return {"ok": True, "open": len(self.store.open_requests())}

    def read(self, args: dict) -> dict:
        """Chats (``chats``: session ids) and group chats (``rooms``) read on ``device_id``. Every notice
        lists them for six hours, and devices away from the app that were sent a reply or message for one
        get a background ``read`` push, at most one every 30 s; the reader itself gets nothing
        (docs/notifications.md §2, Reading)."""
        device_id = _require(args, "device_id", _DEVICE)
        chats = _ids(args.get("chats"), "chats", MAX_READ_IDS)
        rooms = _ids(args.get("rooms"), "rooms", MAX_READ_IDS)
        if not chats and not rooms:
            return {"ok": True, "open": len(self.store.open_requests())}
        result = self.store.record_read(device_id, chats, rooms)
        for owed, wait in result["read"]:
            self._soon("read", owed, max(PUSH_DEBOUNCE, wait))
        for moved in result["badge"]:
            self._soon("badge", moved, PUSH_DEBOUNCE)
        return {"ok": True, "open": result["open"]}

    def _release_held(self, device_id: str, state: str, session: str | None, live: list | None) -> None:
        """Requests held back because their chat was on screen go out once it isn't (the person left)."""
        released = []

        def change(data: dict) -> None:
            held = data.setdefault("held", {}).get(device_id) or {}
            keep = {}
            for rid, entry in held.items():
                if rid not in data["requests"]:
                    continue  # answered or expired meanwhile
                chats = set(entry.get("chats") or [])
                still_shown = (state == "foreground" and session in chats) or bool(live and chats & set(live))
                if still_shown:
                    keep[rid] = entry
                else:
                    released.append(entry["request"])
            if keep:
                data["held"][device_id] = keep
            else:
                data["held"].pop(device_id, None)

        self.store.update(change)
        for request in released:
            self.relay.enqueue(Delivery(device_id, request, on_done=self._done(device_id)))

    def activity(self, args: dict) -> dict:
        """The app started (``token``) or ended (no token) a Live Activity for a chat."""
        device_id = _require(args, "device_id", _DEVICE)
        token = args.get("token")
        if token:
            if not _TOKEN.match(str(token)):
                raise PushError("token must be hex")
            session = str(args.get("session_id") or "")
            self.store.set_activity(device_id, {"token": str(token).lower(), "session": session,
                                                "activity_id": str(args.get("activity_id") or "")[:80]})
        else:
            self.store.set_activity(device_id, None)
        return {"ok": True}

    def status(self, args: dict) -> dict:
        state = self.store.read()
        device_id = args.get("device_id")
        device = state["devices"].get(device_id) if device_id else None
        return {"ok": True, "version": VERSION, "gateway": self.gateway(), "relay_url": self.relay.url,
                "relay_registered": bool(state.get("installation", {}).get("id")),
                "relay_error": self.relay.last_error, "devices": len(state["devices"]),
                "registered": device is not None, "preferences": device.get("preferences") if device else None,
                "open": len(state["requests"])}

    def test(self, args: dict) -> dict:
        device_id = _require(args, "device_id", _DEVICE)
        device = self.store.devices().get(device_id)
        if not device:
            raise PushError("device not registered")
        notice = notices.Notice(kind="test", id=f"test-{int(time.time())}", title="Push notifications are on",
                                body=f"{self.gateway_name()} can reach this device.",
                                hidden=f"Test from {self.gateway_name()}")
        result = self.relay.post(notices.apns_request(device, notice, self.gateway(), 0, [],
                                                      recent_reads(self.store.read())))
        self._handle_result(device_id, result)
        return {"ok": result.get("status") == 200, "status": result.get("status"), "reason": result.get("reason")}

    def host(self, args: dict) -> dict:
        """How the gateway's computer schedules Hermes's services (``hostinfo``): the app's Settings
        → Setup → Priority flags a Mac that throttles them."""
        return {"ok": True, "version": VERSION, "host": hostinfo.report()}

    COMMANDS = ("register", "unregister", "preferences", "presence", "read", "activity", "status", "test", "host")

    # -- delivery ---------------------------------------------------------------------------------------

    def _wants(self, device_id: str, device: dict, notice: notices.Notice, walked_away: set | None = None,
               ignore_presence: bool = False) -> bool:
        prefs = {**DEFAULT_PREFERENCES, **(device.get("preferences") or {})}
        kind = notice.kind
        if kind in ("approval", "question", "widget") and not prefs["approvals"]:
            return False
        if kind == "password" and not prefs["passwords"]:
            return False
        origin = notice.extra.get("origin")
        if kind == "reply" and origin == "routine":
            # A Bot's take on its routine's output: nobody was waiting on it, so no threshold. A
            # scheduled task's news, under the same switch.
            if prefs["tasks"] != "all":
                return False
        elif kind == "reply" and origin == "bot":
            # A Bot answering another Bot's message: Bots talking among themselves, like a group chat.
            if prefs["bots"] == "off" or (prefs["bots"] == "mentions" and not notice.extra.get("mention")):
                return False
        # A reply: when the turn ran past the threshold, or this device was watching the chat when the
        # turn started and has left since (asked, then put the phone away).
        elif kind == "reply" and (not prefs["replies"] or (notice.extra.get("seconds", 0) < prefs["reply_after"]
                                                           and device_id not in (walked_away or set()))):
            return False
        if kind == "task" and prefs["tasks"] != "all":
            return False
        if kind == "task_failed" and prefs["tasks"] == "off":
            return False
        # Board cards follow the same switch: a card that needs you or stopped is a "failure".
        if kind in ("card_review", "card_done") and prefs["tasks"] != "all":
            return False
        if kind in ("card_needs_you", "card_stopped") and prefs["tasks"] == "off":
            return False
        # A tidy is routine news, like a task that finished.
        if kind == "tidied" and prefs["tasks"] != "all":
            return False
        if kind == "message" and (prefs["bots"] == "off" or (prefs["bots"] == "mentions"
                                                            and not notice.extra.get("mention"))):
            return False
        presence = None if ignore_presence else self.store.presence(device_id)
        if presence:
            chats = {c for c in (notice.thread, notice.session_id) if c}
            live = presence.get("live")
            if presence["state"] == "running" and live is None:
                return False  # an older Mac app that posts everything itself
            if live and chats & set(live):
                return False  # the app hears this chat over its own connection and notifies itself
            if presence["state"] == "foreground" and presence.get("session") in chats:
                return False  # the chat on screen docks its card instead
        return True

    def deliver(self, notice: notices.Notice, walked_away: set | None = None) -> int:
        state = self.store.read()
        resolved = [rid for rid, _ in state["resolved"]]
        read = recent_reads(state)
        sent = 0
        tracked = []  # devices sent a reply or Bot message: a read elsewhere clears it there
        for device_id, device in state["devices"].items():
            wanted = self._wants(device_id, device, notice, walked_away)
            # Hermes waits on this one: if only the screen held it back, keep it for when the person leaves.
            hold = (not wanted and notice.kind in ("approval", "question", "password", "widget") and notice.request_id
                    and self._wants(device_id, device, notice, walked_away, ignore_presence=True))
            if not wanted and not hold:
                continue
            try:
                request = notices.apns_request(device, notice, self.gateway(), len(state["requests"]), resolved, read)
            except Exception:
                logger.warning("app push: couldn't build a notice for %s", device_id, exc_info=True)
                continue
            if hold:
                chats = [c for c in (notice.thread, notice.session_id) if c]
                self.store.update(lambda data, d=device_id, r=request, c=chats: data.setdefault("held", {})
                                  .setdefault(d, {}).__setitem__(notice.request_id, {"request": r, "chats": c}))
                continue
            self.relay.enqueue(Delivery(device_id, request, on_done=self._done(device_id)))
            sent += 1
            tracked.append(device_id)
        self._delivered(notice, tracked)
        return sent

    def _delivered(self, notice: notices.Notice, device_ids: list[str]) -> None:
        """Remembers which chat or room these devices were just notified about, and counts it unread on
        those that count unread chats in their badge."""
        key = _read_key(notice)
        if key is None or not device_ids:
            return
        try:
            moved = self.store.record_delivered(device_ids, *key)
        except Exception:
            logger.warning("app push: couldn't note what was sent", exc_info=True)
            return
        for device_id in moved:
            self._soon("badge", device_id, PUSH_DEBOUNCE)

    def withdraw(self, ids: list[str]) -> None:
        if not ids:
            return
        state = self.store.read()
        for device_id, device in state["devices"].items():
            with contextlib.suppress(Exception):
                request = notices.withdraw_request(device, ids, self.gateway(), len(state["requests"]))
                self.relay.enqueue(Delivery(device_id, request, on_done=self._done(device_id)))

    def _done(self, device_id: str) -> Callable[[dict], None]:
        return lambda result: self._handle_result(device_id, result)

    # -- reading: read and badge pushes (docs/notifications.md §2, Reading) ---------------------------------

    def _soon(self, kind: str, device_id: str, delay: float) -> None:
        """One waiting read (or badge) push per device in this process: whatever changes meanwhile goes with
        it, since its flush reads the store when it runs."""
        key = (kind, device_id)
        with self._lock:
            if key in self._due:
                return
            self._due.add(key)

        def run() -> None:
            with self._lock:
                self._due.discard(key)
            flush = self._flush_read if kind == "read" else self._flush_badge
            try:
                flush(device_id)
            except Exception:
                logger.warning("app push: a %s push failed", kind, exc_info=True)

        try:
            self._later(delay, run, key)
        except Exception:
            with self._lock:
                self._due.discard(key)
            logger.warning("app push: couldn't schedule a %s push", kind, exc_info=True)

    def _flush_read(self, device_id: str) -> None:
        """Sends ``device_id`` what was read since it was last in the app, unless it's back or nothing is owed."""
        claimed, wait = self.store.claim_read_push(device_id)
        if claimed is None:
            if wait > 0:
                self._soon("read", device_id, wait)  # another process sent one meanwhile: after its window
            return
        device = self.store.devices().get(device_id)
        if not device:
            return
        request = notices.read_request(device, claimed["read"], self.gateway(), claimed["open"])
        self.relay.enqueue(Delivery(device_id, request, on_done=self._done(device_id)))

    def _flush_badge(self, device_id: str) -> None:
        """Sets the badge of a device away from the app when its count moved since it last showed one."""
        count = self.store.claim_badge(device_id)
        device = self.store.devices().get(device_id) if count is not None else None
        if device:
            self.relay.enqueue(Delivery(device_id, notices.badge_request(device, count), on_done=self._done(device_id)))

    def _handle_result(self, device_id: str, result: dict) -> None:
        if result.get("status") == 410 or result.get("reason") in DEAD_TOKEN_REASONS:
            logger.info("app push: %s no longer accepts notifications; forgetting it", device_id)
            self.store.remove_device(device_id)

    # -- Live Activities ---------------------------------------------------------------------------------

    def _activity(self, session_key: str, state: dict, *, event: str = "update", alert: bool = False,
                  force: bool = False) -> None:
        if not session_key:
            return
        self._activity_state[session_key] = state
        stored = self.store.read()
        for device_id, activity in stored["activities"].items():
            if activity.get("session") != session_key:
                continue
            device = stored["devices"].get(device_id)
            if not device or not {**DEFAULT_PREFERENCES, **device.get("preferences", {})}["live_activity"]:
                continue
            key = activity.get("activity_id") or device_id
            now = time.time()
            if not force and now - self._activity_sent.get(key, 0) < ACTIVITY_MIN_INTERVAL:
                continue
            self._activity_sent[key] = now
            request = notices.activity_request(device, activity, {**state, "gateway": self.gateway_name()},
                                               event=event, alert=alert)
            self.relay.enqueue(Delivery(device_id, request))
            if event == "end":
                self.store.set_activity(device_id, None)

    # -- hooks ---------------------------------------------------------------------------------------

    def on_pre_llm_call(self, session_id: str = "", turn_id: str = "", platform: str = "",
                        parent_session_id: str = "", user_message: Any = "", **_: Any) -> None:
        if not turn_id:
            return
        # A subagent's turn is part of its parent's; a messaging platform's chat notifies in that app.
        reports = not parent_session_id and str(platform or "").lower() in NOTIFY_PLATFORMS
        watching = {device_id for device_id, entry in self.store.read()["presence"].items()
                    if entry.get("state") == "foreground" and entry.get("session") == session_id}
        with self._lock:
            self._turns[turn_id] = {"session": session_id, "start": time.time(), "text": "", "reports": reports,
                                    "watching": watching, "profile": _profile(), "origin": _origin(user_message)}
            self._active_sessions[session_id] = self._active_sessions.get(session_id, 0) + 1
        if reports:
            self._activity(session_id, {"phase": "working", "step": "Thinking", "started_at": time.time(),
                                        "title": self.chat_title(session_id)})

    def on_post_llm_call(self, turn_id: str = "", assistant_response: Any = "", **_: Any) -> None:
        with self._lock:
            if turn_id in self._turns:
                self._turns[turn_id]["text"] = str(assistant_response or "")

    def on_session_end(self, session_id: str = "", turn_id: str = "", completed: bool = False,
                       failed: bool = False, interrupted: bool = False, **_: Any) -> None:
        with self._lock:
            turn = self._turns.pop(turn_id, None)
            if turn:
                count = self._active_sessions.get(turn["session"], 1) - 1
                if count > 0:
                    self._active_sessions[turn["session"]] = count
                else:
                    self._active_sessions.pop(turn["session"], None)
        if turn:
            self._sync(turn["session"] or session_id, turn.get("profile"))
        if not turn or not turn.get("reports", True):
            return
        seconds = time.time() - turn["start"]
        session = turn["session"] or session_id
        chat = self.chat_title(session)
        # A reply that is Hermes' silence marker ("[SILENT]", "NO_REPLY") is the agent deciding to say
        # nothing: Hermes delivers nothing for it, and the app hides it in the chat.
        silent = completed and _is_silence(turn["text"], routine=turn.get("origin") == "routine")
        if silent:
            result = "Nothing to report."
        else:
            result = notices.first_lines(turn["text"], 1, 120) if completed else ("Stopped." if interrupted else
                                                                                  "Didn't finish.")
        self._activity(session, {"phase": "done", "result": result, "title": chat, "started_at": turn["start"],
                                 "ended_at": time.time(), "ok": bool(completed)}, event="end", force=True)
        requests = notices.widget_requests(turn["text"]) if completed and not silent else []
        if requests:
            # A reply that asks something with a widget notifies like an approval, whatever its length.
            notice = notices.widget(payload=requests[0], session_id=session, chat=chat, gateway_name=self.gateway_name())
            _tag_profile(notice)
            self.store.open_request(notice.request_id, {"kind": "widget", "session": session,
                                                        "expires_at": notice.expires_at})
            self.deliver(notice, walked_away=turn.get("watching"))
        elif completed and not silent and turn["text"].strip():
            notice = notices.reply(session_id=session, turn_id=turn_id, chat=chat, gateway_name=self.gateway_name(),
                                   text=turn["text"], seconds=seconds)
            if turn.get("profile"):
                notice.extra["profile"] = turn["profile"]
            if turn.get("origin") in ("routine", "bot"):
                notice.extra["origin"] = turn["origin"]
                notice.extra["mention"] = self._mentions(turn["text"])
            self.deliver(notice, walked_away=turn.get("watching"))

    # -- keeping chats current on devices that left the app ---------------------------------------------

    def _sync(self, session_key: str, profile: str | None = None) -> None:
        """A turn ended in ``session_key``: devices that left the app keeping that chat current get a
        background push, so the app reads it now and shows it as it is when the person comes back."""
        if not session_key:
            return
        try:
            wake, later = self.store.claim_sync(session_key)
        except Exception:
            logger.warning("app push: couldn't read which devices keep chats current", exc_info=True)
            return
        for device_id in wake:
            self._send_sync(device_id, [session_key], profile)
        for device_id, wait in later:
            timer = threading.Timer(wait + 0.5, self._send_held_sync, args=(device_id,))
            timer.daemon = True
            timer.start()

    def _send_held_sync(self, device_id: str) -> None:
        try:
            held = self.store.claim_held_sync(device_id)
        except Exception:
            logger.warning("app push: couldn't read the chats held for a device", exc_info=True)
            return
        if held:
            self._send_sync(device_id, held, None)

    def _send_sync(self, device_id: str, sessions: list[str], profile: str | None) -> None:
        presence = self.store.presence(device_id)
        if presence and presence["state"] == "foreground":
            return  # back in the app, which reads its chats itself
        state = self.store.read()
        device = state["devices"].get(device_id)
        if not device:
            return
        try:
            request = notices.sync_request(device, sessions, self.gateway(), len(state["requests"]), profile)
        except Exception:
            logger.warning("app push: couldn't build a sync for %s", device_id, exc_info=True)
            return
        self.relay.enqueue(Delivery(device_id, request, on_done=self._done(device_id)))

    def on_pre_tool_call(self, tool_name: str = "", args: Any = None, session_id: str = "", **_: Any) -> None:
        args = args if isinstance(args, dict) else {}
        if tool_name == "widget" and args.get("op") in ("claim", "resolve") and isinstance(args.get("id"), str):
            # Answered (on any device or platform) or settled: its notification goes.
            closed, _remaining = self.store.close_requests([args["id"]])
            self.withdraw(closed)
        if tool_name == "clarify" and isinstance(args.get("questions"), list):
            self._clarify[session_id] = [q for q in args["questions"] if isinstance(q, dict)]
        state = dict(self._activity_state.get(session_id) or {"started_at": time.time(),
                                                              "title": self.chat_title(session_id)})
        state.update({"phase": "working", "step": _step(tool_name, args)})
        progress = _plan_progress(tool_name, args)
        if progress:
            state["progress"] = progress
        self._activity(session_id, state)

    def on_pre_approval_request(self, session_key: str = "", command: str = "", description: str = "",
                                pattern_keys: Any = None, surface: str = "", coalesced: bool = False,
                                **extra: Any) -> None:
        # Followers reuse the leader's prompt; CLI/smart approvals aren't answerable from a phone. A card
        # fill comes through the gateway's queue under its own surface: it notifies, but only opens the chat
        # (outside a gateway session it has no request id, below).
        if coalesced or not (surface.startswith(("gateway", "transport")) or surface == notices.PAYMENT_SURFACE):
            return
        entry = self._pending_approval(session_key, command)
        request_id = str((entry or {}).get("request_id") or extra.get("request_id") or "")
        if not request_id:
            return
        timeout = _config_number("approvals.timeout", 300)
        expires_at = time.time() + timeout if timeout > 0 else None
        choices = ["once", "deny"]
        if (entry or {}).get("allow_session", True) is not False:
            choices.insert(1, "session")
        if (entry or {}).get("allow_permanent", True) is not False:
            choices.insert(-1, "always")
        # The approval queue is keyed by ``session_key``: the stored session id in the TUI gateway, the run
        # id for an API server run. The chat itself is the agent's ``session_id`` when the hook carries it.
        chat_session = str(extra.get("session_id") or "") or session_key
        chat = self.chat_title(chat_session)
        notice = notices.approval(request_id=request_id, session_id=chat_session, chat=chat,
                                  gateway_name=self.gateway_name(), command=command, description=description,
                                  choices=choices, expires_at=expires_at,
                                  smart_denied=bool((entry or {}).get("smart_denied")), surface=surface)
        answer = _answer_route(session_key)
        if answer:
            notice.extra["answer"] = answer
        _tag_profile(notice)
        notice.extra["answerable"] = answer is not None
        self.store.open_request(request_id, {"kind": "approval", "session": chat_session, "key": session_key,
                                             "expires_at": expires_at})
        self.deliver(notice)
        # A flagged command's or a card fill's Live Activity carries no request id, so it shows no Allow on
        # the Lock Screen.
        open_only = notices.opens_only(notice)
        self._activity(chat_session, {**(self._activity_state.get(chat_session) or {}), "phase": "needsYou",
                                      "command": notice.extra["command"], "request_id": None if open_only else request_id,
                                      "expires_at": expires_at, "title": chat, "answer": answer},
                       alert=True, force=True)

    def on_post_approval_response(self, session_key: str = "", session_id: str = "", **_: Any) -> None:
        tracked = [rid for rid, r in self.store.open_requests().items()
                   if r.get("kind") == "approval" and r.get("key", r.get("session")) == session_key]
        if not tracked:
            return
        pending = {str(e.get("request_id")) for e in _gateway_approvals(session_key)}
        done = [rid for rid in tracked if rid not in pending]
        closed, _remaining = self.store.close_requests(done)
        self.withdraw(closed)
        chat_session = session_id or session_key
        if chat_session in self._active_sessions:
            state = {**(self._activity_state.get(chat_session) or {}), "phase": "working", "step": "Continuing"}
            for key in ("command", "request_id", "answer"):
                state.pop(key, None)
            self._activity(chat_session, state, force=True)

    def on_human_input_request(self, kind: str = "", request_id: str = "", session_id: str = "",
                               session_key: str = "", prompt: str = "", **_: Any) -> None:
        if kind == "approval" or not request_id:
            return
        session = session_key or session_id
        chat = self.chat_title(session)
        if kind == "clarify":
            timeout = _config_number("agent.clarify_timeout", 3600)
            expires_at = time.time() + timeout if timeout > 0 else None
            questions = self._clarify.pop(session, None) or [{"question": line} for line in prompt.splitlines()
                                                            if line.strip()]
            notice = notices.question(request_id=request_id, session_id=session, chat=chat,
                                      gateway_name=self.gateway_name(), questions=questions, prompt=prompt,
                                      expires_at=expires_at)
            if _answerable_here():
                # The app answers through the session's open requests (``session.resume`` → ``request.answer``).
                notice.extra["answer"] = {"via": "socket", "session_id": session}
            _tag_profile(notice)
            step = notice.body
        else:  # a password or other value prompt: never the value, only what it's for
            expires_at = time.time() + (120 if kind == "sudo" else 300)
            notice = notices.password(request_id=request_id, session_id=session, chat=chat,
                                      gateway_name=self.gateway_name(), what=prompt if kind == "sudo" else "",
                                      expires_at=expires_at)
            step = "Needs a password"
        self.store.open_request(request_id, {"kind": notice.kind, "session": session, "expires_at": expires_at})
        self.deliver(notice)
        self._activity(session, {**(self._activity_state.get(session) or {}), "phase": "needsYou",
                                 "question": step, "request_id": request_id, "title": chat}, alert=True, force=True)

    def on_human_input_resolved(self, kind: str = "", request_id: str = "", session_id: str = "",
                                session_key: str = "", **_: Any) -> None:
        if kind == "approval" or not request_id:
            return
        closed, _remaining = self.store.close_requests([request_id])
        self.withdraw(closed)
        session = session_key or session_id
        if session in self._active_sessions:
            state = {**(self._activity_state.get(session) or {}), "phase": "working", "step": "Continuing"}
            state.pop("question", None)
            self._activity(session, state, force=True)

    def on_room_member_activity(self, room_id: str = "", member_id: str = "", turn_id: str = "", kind: str = "",
                                payload: Any = None, **_: Any) -> None:
        if kind != "message.delta" or not room_id:
            return
        text = str((payload or {}).get("text") or (payload or {}).get("delta") or "")
        key = (room_id, member_id, turn_id)
        with self._lock:
            buffer = self._room_buffers.setdefault(key, {"text": "", "timer": None})
            # Notices read a room message's opening lines: the rest isn't kept (F28).
            buffer["text"] = (buffer["text"] + text)[:notices.MAX_PLAIN]
            if buffer["timer"]:
                buffer["timer"].cancel()
            buffer["timer"] = threading.Timer(ROOM_MESSAGE_SETTLE, self._flush_room, args=(key,))
            buffer["timer"].daemon = True
            buffer["timer"].start()

    def _flush_room(self, key: tuple) -> None:
        with self._lock:
            buffer = self._room_buffers.pop(key, None)
        if not buffer or not buffer["text"].strip():
            return
        room_id, member_id, _turn = key
        room_name, bot = _room_names(room_id, member_id)
        self.deliver(notices.message(room_id=room_id, room=room_name, member_id=member_id, bot=bot,
                                     gateway_name=self.gateway_name(), text=buffer["text"],
                                     mention=self._mentions(buffer["text"])))

    def _mentions(self, text: str) -> bool:
        """Whether ``text`` @mentions the person (any device's ``mention_names``) or everyone."""
        names = set()
        for device in self.store.devices().values():
            names.update(n.lower() for n in (device.get("preferences") or {}).get("mention_names", []) if n)
        lowered = str(text or "").lower()
        return any(f"@{n}" in lowered for n in names | {"all", "everyone"})

    # -- the Board (docs/board.md §5) -------------------------------------------------------------------
    # Hermes fires hooks for a blocked card and a finished one; "ready for review" and "stopped" have
    # none, so the gateway's process watches the boards' events for those (``watch_cards``).

    def on_kanban_task_completed(self, task_id: str = "", board: str = "", assignee: str = "",
                                 summary: str = "", **_: Any) -> None:
        _wake()  # the boards are busy: the watcher looks often again
        self.card_notice("card_done", task_id, board, assignee, summary)

    def on_kanban_task_blocked(self, task_id: str = "", board: str = "", assignee: str = "", reason: str = "",
                               **_: Any) -> None:
        _wake()
        # Only a card that waits on a person: a dependency wait (back in To Do) or a flaky failure
        # that may clear says nothing.
        card = _kanban_card(task_id, board)
        if card is not None and (card.get("status") != "blocked" or card.get("block_kind") in ("dependency", "transient")):
            return
        self.card_notice("card_needs_you", task_id, board, assignee, reason, card=card)

    def card_notice(self, kind: str, task_id: str, board: str, assignee: str, text: str,
                    card: dict | None = None) -> None:
        if not task_id:
            return
        card = card if card is not None else (_kanban_card(task_id, board) or {})
        profile = assignee or card.get("assignee") or ""
        self.deliver(notices.card(kind, card_id=task_id, board=board or card.get("board") or "", title=card.get("title", ""),
                                  who=_profile_title(profile), profile=profile, project_id=card.get("project_id", ""),
                                  gateway_name=self.gateway_name(), text=text or ""))

    def watch_cards(self, key: str | None = None) -> None:
        """Joins the process's one board watcher, starting it if no copy has yet (the gateway process;
        worker processes don't). Every profile the gateway serves joins; the watcher looks once per
        state store they share (boards and cursors are the root's), never once per profile."""
        registry = _watcher()
        with registry["lock"]:
            registry["members"][key or _SCOPE] = self
            thread = registry.get("thread")
            if thread is None or not thread.is_alive():
                thread = threading.Thread(target=_watch, args=(registry,), name="app-push-cards", daemon=True)
                registry["thread"] = thread
                thread.start()

    def watch_settings(self) -> tuple[float, float, float]:
        """(seconds between looks while busy, the slowest while idle, seconds between tidy looks)."""
        fast = _seconds(self._config("card_poll_seconds", None), CARD_POLL_SECONDS, 1, 300)
        idle = max(fast, _seconds(self._config("card_idle_poll_seconds", None), CARD_IDLE_POLL_SECONDS, 1, 600))
        tidy = _seconds(self._config("tidy_poll_seconds", None), TIDY_POLL_SECONDS, 5, 3600)
        return fast, idle, tidy

    def poll_cards(self) -> int:
        """Review requests and stops since the last look, once each: the cursor per board moves under
        the store's lock, so two processes never send the same one."""
        return self._poll_cards()[0]

    def _poll_cards(self) -> tuple[int, bool]:
        """(notices sent, whether the boards are busy: an event since the last look or a card running).
        A board with nothing new costs one lock-free read of the store and no write."""
        from hermes_cli import kanban_db
        from hermes_cli.kanban_db_connect import connect_closing
        sent, busy = 0, False
        cursors = self.store.read().get("card_cursors") or {}
        for meta in kanban_db.list_boards():
            slug = meta.get("slug") or "default"
            with connect_closing(board=slug) as conn:
                latest = int(conn.execute("SELECT COALESCE(MAX(id), 0) FROM task_events").fetchone()[0])
                busy = _cards_running(conn) or busy
                seen = cursors.get(slug)
                if seen is not None and seen >= latest:
                    continue  # nothing since the last look (cursors only move forward)
                busy = True

                def advance(state: dict, slug: str = slug, latest: int = latest):
                    cursors = state.setdefault("card_cursors", {})
                    start = cursors.get(slug)
                    cursors[slug] = max(latest, start or 0)
                    return start

                start = self.store.update(advance)
                if start is None or start >= latest:
                    continue  # first sight of the board: start from now, never the backlog
                rows = conn.execute(
                    "SELECT task_id, kind, payload FROM task_events WHERE id > ? AND id <= ? "
                    "AND kind IN ('review_requested', 'gave_up', 'crashed') ORDER BY id", (start, latest)).fetchall()
            for task_id, kind, payload in rows:
                try:
                    data = json.loads(payload) if payload else {}
                except ValueError:
                    data = {}
                card = _kanban_card(task_id, slug)
                if card is None:
                    continue
                if kind == "review_requested":
                    self.card_notice("card_review", task_id, slug, card.get("assignee") or "", card.get("summary") or "", card=card)
                else:
                    self.card_notice("card_stopped", task_id, slug, card.get("assignee") or "",
                                     str(data.get("error") or card.get("error") or ""), card=card)
                sent += 1
        return sent, busy

    # -- What Hermes Learned (docs/learned.md) ---------------------------------------------------------------
    # The curator fires no hook when it tidies: the same watcher looks for new run reports
    # (``logs/curator/<run>/run.json``) in each profile's home and sends one quiet notice for the newest
    # tidy that changed something.

    def poll_tidies(self) -> int:
        sent = 0
        cursors = self.store.read().get("tidy_cursors") or {}
        for profile, home in _profile_homes():
            root = home / "logs" / "curator"
            seen = cursors.get(profile)
            try:
                names = sorted(p.name for p in root.iterdir()) if root.is_dir() else []
                # Only runs past the cursor can say anything (cursors only move forward).
                runs = [n for n in names if (seen is None or n > seen) and (root / n / "run.json").is_file()]
            except OSError:
                continue
            if seen is not None and not runs:
                continue  # nothing since the last look: no lock, no write

            def advance(state: dict, profile: str = profile, latest: str = runs[-1] if runs else ""):
                cursors = state.setdefault("tidy_cursors", {})
                start = cursors.get(profile)
                cursors[profile] = max(latest, start or "")
                return start

            start = self.store.update(advance)
            if start is None:
                continue  # first sight of the profile: from now on, never the old reports
            for run in reversed([r for r in runs if r > start]):
                try:
                    report = json.loads((root / run / "run.json").read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                merged, archived, stale = _tidy_counts(report)
                if not (merged or archived or stale):
                    continue
                name = "" if profile == "default" else profile
                self.deliver(notices.tidied(profile=name, who=_profile_title(name), gateway_name=self.gateway_name(),
                                            run=run, merged=merged, archived=archived, stale=stale))
                sent += 1
                break  # the newest tidy says it; older ones in between would only collapse into it
        return sent

    # -- cron delivery -------------------------------------------------------------------------------------

    async def send_cron(self, chat_id: str, message: str) -> dict:
        """``deliver: apppush`` (or ``apppush:fail`` as a job's ``failure_deliver``) lands here."""
        name, job_id, text = _parse_cron(message)
        with contextlib.suppress(Exception):
            from cron.execution_identity import current_cron_execution
            execution = current_cron_execution()
            name = name or getattr(execution, "job_name", "") or ""
            job_id = job_id or getattr(execution, "job_id", "") or ""
        failed = str(chat_id or "").lower() in ("fail", "failed", "failure", "failures")
        notice = notices.task(job_id=job_id, name=name or "Scheduled task", gateway_name=self.gateway_name(),
                              text=text, failed=failed)
        state = self.store.read()
        sent = 0
        read = recent_reads(state)
        for device_id, device in state["devices"].items():
            if not self._wants(device_id, device, notice):
                continue
            request = notices.apns_request(device, notice, self.gateway(), len(state["requests"]), [], read)
            try:
                result = await asyncio.to_thread(self.relay.post, request)
            except Exception as exc:
                return {"error": f"app push: {exc}"}
            self._handle_result(device_id, result)
            sent += 1
        return {"success": True, "message_id": notice.id, "devices": sent}

    # -- helpers for hooks -----------------------------------------------------------------------------------

    def _pending_approval(self, session_key: str, command: str) -> dict | None:
        """The queue entry this hook is about: the newest pending approval with this command that we haven't
        notified yet (the entry is queued before the hook fires)."""
        known = set(self.store.open_requests(session_key))
        candidates = [e for e in _gateway_approvals(session_key) if str(e.get("command") or "") == command]
        fresh = [e for e in candidates if str(e.get("request_id")) not in known]
        return (fresh or candidates or [None])[-1]


# -- module helpers --------------------------------------------------------------------------------------

def _require(args: dict, key: str, pattern: re.Pattern) -> str:
    value = str(args.get(key) or "")
    if not pattern.match(value):
        raise PushError(f"{key} is missing or malformed")
    return value


def _ids(value: Any, key: str, limit: int) -> list[str]:
    """A list of chat or room ids: strings, each clipped to 120 characters, without repeats, at most ``limit``."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise PushError(f"{key} must be a list of ids")
    return list(dict.fromkeys(v[:120] for v in value if isinstance(v, str) and v))[:limit]


def _id_sets(value: Any, limit: int = 0) -> dict | None:
    """``{chats, rooms}`` as ``presence`` takes it (``unread``, ``muted``, ``listed``); None when it isn't one."""
    if not isinstance(value, dict):
        return None
    sets = {}
    for kind in ("chats", "rooms"):
        try:
            sets[kind] = _ids(value.get(kind), kind, limit or MAX_PRESENCE_IDS)
        except PushError:
            sets[kind] = []
    return sets


def _read_key(notice: notices.Notice) -> tuple[str, str] | None:
    """What a read clears a notice by: a reply's chat, a Bot message's room. Requests, task results and
    cards stay until they settle."""
    if notice.kind == "reply":
        key = notice.session_id or notice.thread
        return ("chats", key) if key else None
    if notice.kind == "message":
        key = str(notice.extra.get("room_id") or "") or notice.thread.removeprefix("room:")
        return ("rooms", key) if key else None
    return None


def _later(delay: float, run: Callable[[], None], key: tuple[str, str]) -> threading.Timer:
    timer = threading.Timer(delay, run)
    timer.name, timer.daemon = f"app-push-{key[0]}", True
    timer.start()
    return timer


def _preferences(raw: dict) -> dict:
    prefs = dict(DEFAULT_PREFERENCES)
    for key, default in DEFAULT_PREFERENCES.items():
        if key not in raw:
            continue
        value = raw[key]
        if isinstance(default, bool):
            prefs[key] = bool(value)
        elif key == "reply_after":
            with contextlib.suppress(TypeError, ValueError):
                prefs[key] = max(0, min(int(value), 3600))
        elif key == "mention_names":
            prefs[key] = [str(v)[:40] for v in (value or []) if str(v).strip()][:8]
        elif key in CHOICE_OPTIONS and value in CHOICE_OPTIONS[key]:
            prefs[key] = value
    return prefs


def _gateway_approvals(session_key: str) -> list[dict]:
    with contextlib.suppress(Exception):
        from tools.approval import list_gateway_approvals
        return list_gateway_approvals(session_key) or []
    return []


def _origin(user_message: Any) -> str:
    """Who started a turn: a routine delivering its output into a Bot Chat (``bot-chat`` cron
    delivery, cron/scheduler_delivery.py), another Bot's message (tools/bot_mode_dm.py), or the person."""
    text = user_message
    if isinstance(text, list):  # multimodal content: the first text part
        text = next((part.get("text") for part in text if isinstance(part, dict) and part.get("text")), "")
    text = str(text or "").lstrip()
    if text.startswith('[Cronjob "'):
        return "routine"
    if text.startswith("Message from 🤖 "):
        return "bot"
    return "person"


def _profile() -> str:
    """The Bot (profile) this hook runs for, or "" for the gateway's own."""
    with contextlib.suppress(Exception):
        from hermes_cli.profiles import get_active_profile_name
        name = get_active_profile_name()
        if name not in ("default", "custom"):
            return name
    return ""


def _is_silence(text: str, routine: bool = False) -> bool:
    """Hermes' own rule for a reply that delivers nothing (``gateway.response_filters``): exactly a
    silence marker in a chat, and for a routine's output also one that opens with ``[SILENT]`` and a
    note, as Hermes treats cron. An older Hermes without the filters gets the plain markers."""
    try:
        from gateway import response_filters as filters
        check = filters.is_autonomous_silence_response if routine else filters.is_intentional_silence_response
        return bool(check(text))
    except Exception:
        stripped = (text or "").strip()
        marker = stripped.upper().strip("*_`.!")
        return marker in _SILENCE_MARKERS or (routine and stripped.upper().startswith("[SILENT]"))


_SILENCE_MARKERS = {"[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"}


def _tag_profile(notice: notices.Notice) -> None:
    """Bot Chats live in their profile: the app resumes the session there to answer or reply."""
    profile = _profile()
    if profile:
        notice.extra["profile"] = profile


def _answerable_here() -> bool:
    """Requests raised in the TUI/desktop gateway can be answered from the app over its socket."""
    return "tui_gateway.server" in sys.modules or "tui_gateway" in sys.modules


def _answer_route(session_key: str) -> dict | None:
    """How the app answers this approval in the background, or None (a messaging platform's own prompt):
    ``run``: ``POST /v1/runs/{run_id}/approval`` on the API server (its approval key is the run id);
    ``socket``: ``approval.respond {session_id, choice, request_id}`` on the backend socket, which falls
    back from a stale session id to the request id."""
    if session_key.startswith("run_") and "gateway.platforms.api_server" in sys.modules:
        return {"via": "run", "run_id": session_key}
    if _answerable_here():
        return {"via": "socket", "session_id": session_key}
    return None


def _config_number(dotted: str, default: float) -> float:
    with contextlib.suppress(Exception):
        from hermes_cli.config import load_config_readonly
        node: Any = load_config_readonly()
        for part in dotted.split("."):
            node = node.get(part) if isinstance(node, dict) else None
        if node is not None:
            return float(node)
    return float(default)


_STEPS = {"terminal": "Running a command", "execute_code": "Running code", "web_search": "Searching the web",
          "web_extract": "Reading a page", "browser_navigate": "Browsing", "read_file": "Reading files",
          "write_file": "Editing files", "patch": "Editing files", "search_files": "Searching files",
          "delegate_task": "Handing off work", "clarify": "Asking you", "todo": "Planning", "memory": "Remembering",
          "image_generate": "Making an image", "send_message": "Sending a message"}


def _step(tool_name: str, args: dict) -> str:
    step = _STEPS.get(tool_name) or (f"Using {tool_name.replace('_', ' ')}" if tool_name else "Working")
    if tool_name == "terminal" and args.get("command"):
        command = notices.clip(notices.redact(str(args["command"])), 60)
        if command:
            return f"{step}: {command}"
    return step


def _plan_progress(tool_name: str, args: dict) -> dict | None:
    if tool_name not in ("todo", "update_plan"):
        return None
    items = args.get("todos") or args.get("items") or args.get("plan") or []
    if not isinstance(items, list) or not items:
        return None
    done = sum(1 for item in items if isinstance(item, dict)
               and str(item.get("status", "")).lower() in ("completed", "done"))
    return {"done": done, "total": len(items)}


_CRON = re.compile(r"^Cronjob Response:\s*(?P<name>.+?)\s*\n\(job_id:\s*(?P<id>[^)]+)\)\s*\n-+\s*\n+(?P<body>.*)$", re.S)


def _parse_cron(message: str) -> tuple[str, str, str]:
    match = _CRON.match(str(message or ""))
    if match:
        return match["name"].strip(), match["id"].strip(), match["body"].strip()
    return "", "", str(message or "")


def _kanban_card(task_id: str, board: str) -> dict | None:
    """The card's facts a notice needs (title, column, why it's blocked, who, project, latest
    summary); None when it can't be read."""
    with contextlib.suppress(Exception):
        from hermes_cli import kanban_db
        from hermes_cli.kanban_db_connect import connect_closing
        with connect_closing(board=board or None) as conn:
            task = kanban_db.get_task(conn, task_id)
            if task is None:
                return None
            project = task.project_id
            if not project:
                with contextlib.suppress(Exception):
                    project = (kanban_db.read_board_metadata(board) or {}).get("project_id") if board else None
            return {"title": str(task.title or ""), "status": task.status, "block_kind": task.block_kind,
                    "assignee": task.assignee or "", "project_id": project or "", "board": board or "",
                    "summary": kanban_db.latest_summary(conn, task_id) or "", "error": task.last_failure_error or ""}
    return None


def _cards_running(conn) -> bool:
    """Whether a card on this board is being worked on: its review request or stop can come any moment."""
    try:
        return bool(conn.execute("SELECT EXISTS(SELECT 1 FROM tasks WHERE status = 'running')").fetchone()[0])
    except Exception:
        return True  # can't tell: keep looking often


# -- the board watcher (one per process) ------------------------------------------------------------------

def _watcher() -> dict:
    """The process's board watcher registry, shared by every copy of the plugin Hermes imported."""
    registry = vars(sys).get(_WATCHER)
    if registry is None:  # setdefault is atomic: two copies starting at once still agree on one
        registry = vars(sys).setdefault(_WATCHER, {"lock": threading.Lock(), "thread": None, "members": {},
                                                   "wake": threading.Event()})
    return registry


def _leaders(registry: dict) -> list:
    """One registered ``Push`` per state store: every profile of one Hermes root shares the root's store
    (its devices and its board and tidy cursors), so one look serves them all."""
    with registry["lock"]:
        members = list(registry["members"].values())
    leaders: dict[str, Any] = {}
    for push in members:
        leaders.setdefault(str(push.store.path), push)
    return list(leaders.values())


class Pace:
    """How long the board watcher waits between looks: ``fast`` while a card is running or the boards just
    changed, doubling up to ``idle`` while nothing happens."""

    def __init__(self, fast: float = CARD_POLL_SECONDS, idle: float = CARD_IDLE_POLL_SECONDS):
        self.fast, self.idle = fast, max(idle, fast)
        self.interval = self.fast

    def configure(self, fast: float, idle: float) -> None:
        self.fast, self.idle = fast, max(idle, fast)
        self.interval = min(max(self.interval, self.fast), self.idle)

    def after(self, busy: bool) -> float:
        """The wait after a look that found the boards ``busy`` (or not)."""
        self.interval = self.fast if busy else min(self.interval * 2, self.idle)
        return self.interval


def _wake() -> None:
    """Something happened (a device registered, a card moved): the watcher goes back to its fast pace."""
    registry = vars(sys).get(_WATCHER)
    if registry is not None:
        registry["wake"].set()


def _wait(registry: dict, pace: Pace, last: float) -> None:
    """Until the next look: ``pace.interval`` after the last one, or ``pace.fast`` after it once woken."""
    wake = registry["wake"]
    while True:
        left = last + pace.interval - time.monotonic()
        if left <= 0:
            return
        if wake.wait(left):
            wake.clear()
            if registry.get("thread") is not threading.current_thread():
                return  # let go (see ``_watch``)
            pace.interval = pace.fast


def _watch(registry: dict) -> None:
    """Cards ready for review or stopped (Hermes has no hook for those), and finished tidies, for every
    profile that joined."""
    pace = Pace()
    tidies_at = 0.0
    last = time.monotonic()
    while True:
        leaders = _leaders(registry)
        tidy_every = TIDY_POLL_SECONDS
        if leaders:
            with contextlib.suppress(Exception):
                fast, idle, tidy_every = leaders[0].watch_settings()
                pace.configure(fast, idle)
        _wait(registry, pace, last)
        last = time.monotonic()
        if registry.get("thread") is not threading.current_thread():
            return  # the registry let this watcher go (tests reset it); a gateway's never does
        leaders = _leaders(registry)  # a profile may have reloaded meanwhile
        if not leaders:
            continue
        busy = False
        for push in leaders:
            try:
                if push.store.devices():
                    busy = push._poll_cards()[1] or busy
            except Exception:
                logger.debug("app push: card watch failed", exc_info=True)
        if time.monotonic() - tidies_at >= tidy_every:
            tidies_at = time.monotonic()
            for push in leaders:
                try:
                    if push.store.devices():
                        push.poll_tidies()
                except Exception:
                    logger.debug("app push: tidy watch failed", exc_info=True)
        pace.after(busy)


def _seconds(value: Any, default: float, low: float, high: float) -> float:
    try:
        number = float(value) if value is not None and value != "" else default
    except (TypeError, ValueError):
        return default
    return min(max(number, low), high) if number == number else default  # NaN → default


def _profile_homes() -> list[tuple[str, Path]]:
    """Every profile's home, the default's first: where each one's curator writes its reports. A cheap
    directory listing (``list_profile_names``), never ``list_profiles``, which reads each profile."""
    with contextlib.suppress(Exception):
        from hermes_cli.profiles import list_profile_names
        from hermes_constants import get_default_hermes_root
        root = get_default_hermes_root()
        return [(name, root if name == "default" else root / "profiles" / name) for name in list_profile_names()]
    with contextlib.suppress(Exception):
        from hermes_cli.profiles import list_profiles  # a Hermes without the cheap listing
        return [(p.name, Path(p.path)) for p in list_profiles(lazy_skill_count=True)]
    from hermes_constants import get_hermes_home
    return [("default", get_hermes_home())]


def _tidy_counts(report: dict) -> tuple[int, int, int]:
    """Merged, archived and marked stale, as the app counts them (HermesKit's ``CuratorReport``):
    merged skills are archived too but count once; unused ones archived before the review are only
    counted in ``auto_transitions``."""
    def names(rows) -> set[str]:
        return {str(r.get("name") if isinstance(r, dict) else r) for r in rows or [] if r}

    auto = report.get("auto_transitions") or {}
    merged = names(report.get("consolidated"))
    archived = (names(report.get("pruned")) | names(report.get("archived"))) - merged
    stale = sum(1 for t in report.get("state_transitions") or [] if isinstance(t, dict) and t.get("to") == "stale")
    return (len(merged), len(archived) + int(auto.get("archived") or 0), max(stale, int(auto.get("marked_stale") or 0)))


def _profile_title(profile: str) -> str:
    """A profile's name as the app shows it: "Hermes" for the default, else its display name."""
    if not profile or profile == "default":
        return "Hermes"
    with contextlib.suppress(Exception):
        from hermes_cli.profiles import get_profile_dir, read_profile_meta
        meta = read_profile_meta(get_profile_dir(profile))
        name = meta.get("bot_title") or meta.get("display_name")
        if name:
            return str(name)
    return profile.replace("-", " ").replace("_", " ").title()


def _room_names(room_id: str, member_id: str) -> tuple[str, str]:
    room, bot = room_id, member_id
    with contextlib.suppress(Exception):
        from gateway.hosted_rooms import room_state
        state = room_state(room_id) or {}
        room = str(state.get("name") or room_id)
        for member in state.get("members") or []:
            if str(member.get("member_id")) == member_id:
                bot = str(member.get("display_name") or member.get("handle") or member_id)
    return room, bot
