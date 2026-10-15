"""The plugin's brain: devices, hooks → notices, withdrawals, Live Activities, cron delivery.

Everything here is best-effort and off the agent's path: hook handlers do a little bookkeeping and
enqueue; the relay thread does the network. A failure is logged and never raised into Hermes.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import re
import socket
import sys
import threading
import time
from typing import Any, Callable

from . import crypto, notices
from .relay import DEAD_TOKEN_REASONS, Delivery, Relay
from .store import Store

logger = logging.getLogger("hermes_app_push")
VERSION = "1.0.0"

DEFAULT_PREFERENCES = {
    "approvals": True,          # approvals and questions
    "passwords": True,          # password, secret and sign-in prompts
    "replies": True,
    "reply_after": 30,          # seconds a turn must run before its reply notifies
    "tasks": "all",             # all | failures | off (scheduled tasks and Kanban cards)
    "bots": "mentions",         # all | mentions | off
    "background": True,         # unused: helpers no longer notify on their own; older apps still send it
    "live_activity": True,
    "show_details": "unlocked",  # always | unlocked | never (the app applies it; synced for completeness)
    "mention_names": [],        # how the person is @mentioned in group chats
}
CHOICE_OPTIONS = {"tasks": {"all", "failures", "off"}, "bots": {"all", "mentions", "off"},
                  "show_details": {"always", "unlocked", "never"}}
_TOKEN = re.compile(r"^[0-9a-fA-F]{32,400}$")
_TOPIC = re.compile(r"^[A-Za-z0-9.-]{3,200}$")
_DEVICE = re.compile(r"^[A-Za-z0-9._:-]{4,80}$")
ACTIVITY_MIN_INTERVAL = 12.0   # seconds between "working" Live Activity updates
ROOM_MESSAGE_SETTLE = 5.0      # a Bot's streamed message counts as finished after this quiet time
# Surfaces whose replies the app reports. A messaging platform's own app already notifies, and cron
# results come through the delivery platform.
NOTIFY_PLATFORMS = {"", "api_server", "api", "tui", "desktop", "dashboard", "webui", "cli", "local", "acp"}


class PushError(ValueError):
    pass


class Push:
    def __init__(self, *, store: Store | None = None, config: Callable[[str, Any], Any] | None = None):
        self.store = store or Store()
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
        itself (the Mac); without it, a ``running`` device gets nothing pushed."""
        device_id = _require(args, "device_id", _DEVICE)
        state = args.get("state")
        if state not in ("foreground", "running", "away"):
            raise PushError("state must be foreground, running or away")
        live = args.get("live")
        live = [str(s)[:120] for s in live if s][:200] if isinstance(live, list) else None
        session = str(args.get("session_id") or "") or None
        self.store.set_presence(device_id, state, session, live)
        self._release_held(device_id, state, session, live)
        return {"ok": True, "open": len(self.store.open_requests())}

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
        result = self.relay.post(notices.apns_request(device, notice, self.gateway(), 0, []))
        self._handle_result(device_id, result)
        return {"ok": result.get("status") == 200, "status": result.get("status"), "reason": result.get("reason")}

    COMMANDS = ("register", "unregister", "preferences", "presence", "activity", "status", "test")

    # -- delivery ---------------------------------------------------------------------------------------

    def _wants(self, device_id: str, device: dict, notice: notices.Notice, walked_away: set | None = None,
               ignore_presence: bool = False) -> bool:
        prefs = {**DEFAULT_PREFERENCES, **(device.get("preferences") or {})}
        kind = notice.kind
        if kind in ("approval", "question") and not prefs["approvals"]:
            return False
        if kind == "password" and not prefs["passwords"]:
            return False
        # A reply: when the turn ran past the threshold, or this device was watching the chat when the
        # turn started and has left since (asked, then put the phone away).
        if kind == "reply" and (not prefs["replies"] or (notice.extra.get("seconds", 0) < prefs["reply_after"]
                                                         and device_id not in (walked_away or set()))):
            return False
        if kind == "task" and prefs["tasks"] != "all":
            return False
        if kind == "task_failed" and prefs["tasks"] == "off":
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
        sent = 0
        for device_id, device in state["devices"].items():
            wanted = self._wants(device_id, device, notice, walked_away)
            # Hermes waits on this one: if only the screen held it back, keep it for when the person leaves.
            hold = (not wanted and notice.kind in ("approval", "question", "password") and notice.request_id
                    and self._wants(device_id, device, notice, walked_away, ignore_presence=True))
            if not wanted and not hold:
                continue
            try:
                request = notices.apns_request(device, notice, self.gateway(), len(state["requests"]), resolved)
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
        return sent

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
                        parent_session_id: str = "", **_: Any) -> None:
        if not turn_id:
            return
        # A subagent's turn is part of its parent's; a messaging platform's chat notifies in that app.
        reports = not parent_session_id and str(platform or "").lower() in NOTIFY_PLATFORMS
        watching = {device_id for device_id, entry in self.store.read()["presence"].items()
                    if entry.get("state") == "foreground" and entry.get("session") == session_id}
        with self._lock:
            self._turns[turn_id] = {"session": session_id, "start": time.time(), "text": "", "reports": reports,
                                    "watching": watching, "profile": _profile()}
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
        if not turn or not turn.get("reports", True):
            return
        seconds = time.time() - turn["start"]
        session = turn["session"] or session_id
        chat = self.chat_title(session)
        result = notices.first_lines(turn["text"], 1, 120) if completed else ("Stopped." if interrupted else
                                                                              "Didn't finish.")
        self._activity(session, {"phase": "done", "result": result, "title": chat, "started_at": turn["start"],
                                 "ended_at": time.time(), "ok": bool(completed)}, event="end", force=True)
        if completed and turn["text"].strip():
            notice = notices.reply(session_id=session, turn_id=turn_id, chat=chat, gateway_name=self.gateway_name(),
                                   text=turn["text"], seconds=seconds)
            if turn.get("profile"):
                notice.extra["profile"] = turn["profile"]
            self.deliver(notice, walked_away=turn.get("watching"))

    def on_pre_tool_call(self, tool_name: str = "", args: Any = None, session_id: str = "", **_: Any) -> None:
        args = args if isinstance(args, dict) else {}
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
        if coalesced or not surface.startswith(("gateway", "transport")):
            return  # followers reuse the leader's prompt; CLI/smart approvals aren't answerable from a phone
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
        self._activity(chat_session, {**(self._activity_state.get(chat_session) or {}), "phase": "needsYou",
                                      "command": notice.extra["command"], "request_id": request_id,
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
            buffer["text"] += text
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
        names = set()
        for device in self.store.devices().values():
            names.update(n.lower() for n in (device.get("preferences") or {}).get("mention_names", []) if n)
        lowered = buffer["text"].lower()
        mention = any(f"@{n}" in lowered for n in names | {"all", "everyone"})
        self.deliver(notices.message(room_id=room_id, room=room_name, member_id=member_id, bot=bot,
                                     gateway_name=self.gateway_name(), text=buffer["text"], mention=mention))

    def on_kanban_task_completed(self, task_id: str = "", board: str = "", assignee: str = "",
                                 summary: str = "", **_: Any) -> None:
        self.deliver(notices.kanban(task_id=task_id, board=board, title=_kanban_title(task_id, board),
                                    assignee=assignee or "", gateway_name=self.gateway_name(), text=summary or "",
                                    blocked=False))

    def on_kanban_task_blocked(self, task_id: str = "", board: str = "", assignee: str = "", reason: str = "",
                               **_: Any) -> None:
        self.deliver(notices.kanban(task_id=task_id, board=board, title=_kanban_title(task_id, board),
                                    assignee=assignee or "", gateway_name=self.gateway_name(), text=reason or "",
                                    blocked=True))

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
        for device_id, device in state["devices"].items():
            if not self._wants(device_id, device, notice):
                continue
            request = notices.apns_request(device, notice, self.gateway(), len(state["requests"]), [])
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


def _profile() -> str:
    """The Bot (profile) this hook runs for, or "" for the gateway's own."""
    with contextlib.suppress(Exception):
        from hermes_cli.profiles import get_active_profile_name
        name = get_active_profile_name()
        if name not in ("default", "custom"):
            return name
    return ""


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


def _kanban_title(task_id: str, board: str) -> str:
    with contextlib.suppress(Exception):
        from hermes_cli import kanban_db
        from hermes_cli.kanban_db_connect import connect_closing
        with connect_closing(board=board or None) as conn:
            task = kanban_db.get_task(conn, task_id)
            if task is not None and task.title:
                return str(task.title)
    return ""


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
