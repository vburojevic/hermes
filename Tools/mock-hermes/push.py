"""Push notifications for the mock gateway (docs/notifications.md), so the app's push work runs in
the simulator without a real Hermes or Apple.

It plays the ``hermes-app-push`` plugin (``Tools/hermes-app-push``): the app's ``/app-push`` commands
over ``command.dispatch``, and the same notices, built by the plugin's own ``notices.py`` and sealed
with a stdlib twin of its crypto (``pushcrypto.py``). Then a fake relay delivers them:

- ``simctl`` (default): ``xcrun simctl push`` to the simulator that registered (Debug simulator builds
  send their ``SIMULATOR_UDID``). simctl can't deliver Live Activity pushes, so those are logged.
- a URL (``--push-relay https://push.hermesapp.dev``): the real relay and APNs, like the plugin.

Also adds the gateway methods answering from a notification needs: ``approval.respond`` and
``request.answer``. Scripted triggers (any chat): "approve" or "disk" asks for an OK, "ask" asks a
question, "sudo" asks for a password, "slow" runs long; Tasks → Run Now posts a task result.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import threading
import time
import types
import urllib.request
import uuid

HERE = pathlib.Path(__file__).resolve().parent
PLUGIN = HERE.parent / "hermes-app-push"
PRESENCE_TTL = 75
DEFAULT_PREFERENCES = {"approvals": True, "passwords": True, "replies": True, "reply_after": 30, "tasks": "all",
                       "bots": "mentions", "background": True, "live_activity": True, "show_details": "unlocked",
                       "mention_names": []}

B: dict = {}          # backend.py's globals
G = None              # server.py (the API server mock), when it runs too
STATE = {"devices": {}, "presence": {}, "requests": {}, "resolved": [], "activities": {}, "turns": {}}
LOCK = threading.RLock()
RELAY = {"mode": "simctl", "installation": None, "secret": None}
GATEWAY = {"id": "inst_mock" + uuid.uuid4().hex[:6], "name": "Mock Gateway"}
notices = None


def log(message: str) -> None:
    print(f"[mock-push] {message}", flush=True)


# ── The plugin's notice builders, with the stdlib crypto and a stand-in redactor ─────────────────────

def _load_notices():
    package = types.ModuleType("mock_app_push")
    package.__path__ = [str(PLUGIN)]
    sys.modules["mock_app_push"] = package
    spec = importlib.util.spec_from_file_location("mock_app_push.crypto", HERE / "pushcrypto.py")
    crypto = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(crypto)
    sys.modules["mock_app_push.crypto"] = crypto
    package.crypto = crypto
    if "agent.redact" not in sys.modules:  # Hermes's redactor isn't here; mask the obvious secrets
        import re
        agent = types.ModuleType("agent")
        redact = types.ModuleType("agent.redact")
        redact.redact_sensitive_text = lambda text, force=False: re.sub(
            r"(?i)(bearer\s+|token=|password=|api[_-]?key=)\S+", r"\1***", str(text))
        agent.redact = redact
        sys.modules["agent"], sys.modules["agent.redact"] = agent, redact
    spec = importlib.util.spec_from_file_location("mock_app_push.notices", PLUGIN / "notices.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["mock_app_push.notices"] = module
    spec.loader.exec_module(module)
    return module


# ── The app's commands ───────────────────────────────────────────────────────────────────────────────

def command(arg: str) -> str:
    name, _, raw = (arg or "").strip().partition(" ")
    try:
        args = json.loads(raw) if raw.strip() else {}
        handler = COMMANDS.get(name)
        if handler is None:
            raise ValueError(f"unknown command: {name}")
        return json.dumps(handler(args))
    except Exception as error:  # noqa: BLE001 — answer like the plugin
        return json.dumps({"ok": False, "error": str(error)})


def cmd_register(args):
    device_id = args["device_id"]
    with LOCK:
        STATE["devices"][device_id] = {
            "token": args["token"], "topic": args["topic"], "environment": args.get("environment", "development"),
            "public_key": args["public_key"], "platform": args.get("platform", "ios"), "name": args.get("name", ""),
            "simulator": args.get("simulator"),
            "preferences": {**DEFAULT_PREFERENCES, **(args.get("preferences") or {})}}
    log(f"registered {args.get('name') or device_id} ({'simulator ' + args['simulator'][:8] if args.get('simulator') else 'device'})")
    return {"ok": True, "version": "mock", "gateway": GATEWAY, "relay": "ok", "devices": len(STATE["devices"])}


def cmd_unregister(args):
    with LOCK:
        removed = STATE["devices"].pop(args["device_id"], None) is not None
    return {"ok": True, "removed": removed}


def cmd_preferences(args):
    with LOCK:
        device = STATE["devices"].get(args["device_id"])
        if device is None:
            raise ValueError("device not registered")
        device["preferences"] = {**DEFAULT_PREFERENCES, **(args.get("preferences") or {})}
        return {"ok": True, "preferences": device["preferences"]}


def cmd_presence(args):
    with LOCK:
        STATE["presence"][args["device_id"]] = {"state": args["state"], "session": args.get("session_id"),
                                                "live": args.get("live"), "at": time.time()}
        return {"ok": True, "open": len(STATE["requests"])}


def cmd_activity(args):
    with LOCK:
        if args.get("token"):
            STATE["activities"][args["device_id"]] = {"token": args["token"], "session": args.get("session_id", ""),
                                                      "activity_id": args.get("activity_id", "")}
            log(f"Live Activity token for {args.get('session_id')}")
        else:
            STATE["activities"].pop(args["device_id"], None)
    return {"ok": True}


def cmd_status(args):
    with LOCK:
        device = STATE["devices"].get(args.get("device_id") or "")
        return {"ok": True, "version": "mock", "gateway": GATEWAY, "relay_url": RELAY["mode"], "relay_registered": True,
                "relay_error": None, "devices": len(STATE["devices"]), "registered": device is not None,
                "preferences": device["preferences"] if device else None, "open": len(STATE["requests"])}


def cmd_test(args):
    with LOCK:
        device = STATE["devices"].get(args["device_id"])
    if device is None:
        raise ValueError("device not registered")
    notice = notices.Notice(kind="test", id=f"test-{int(time.time())}", title="Push notifications are on",
                            body=f"{GATEWAY['name']} can reach this device.", hidden=f"Test from {GATEWAY['name']}")
    result = relay(device, notices.apns_request(device, notice, GATEWAY, 0, []))
    return {"ok": result.get("status") == 200, "status": result.get("status"), "reason": result.get("reason")}


COMMANDS = {"register": cmd_register, "unregister": cmd_unregister, "preferences": cmd_preferences,
            "presence": cmd_presence, "activity": cmd_activity, "status": cmd_status, "test": cmd_test}


# ── Delivery ─────────────────────────────────────────────────────────────────────────────────────────

def presence(device_id):
    entry = STATE["presence"].get(device_id)
    if not entry or time.time() - entry["at"] > PRESENCE_TTL:
        return None
    return entry


def wants(device_id, device, notice, walked_away=()):
    prefs = device["preferences"]
    kind = notice.kind
    if kind in ("approval", "question") and not prefs["approvals"]:
        return False
    if kind == "password" and not prefs["passwords"]:
        return False
    if kind == "reply" and (not prefs["replies"] or (notice.extra.get("seconds", 0) < prefs["reply_after"]
                                                     and device_id not in walked_away)):
        return False
    if kind == "task" and prefs["tasks"] != "all":
        return False
    if kind == "task_failed" and prefs["tasks"] == "off":
        return False
    if kind == "message" and (prefs["bots"] == "off" or (prefs["bots"] == "mentions" and not notice.extra.get("mention"))):
        return False
    here = presence(device_id)
    if here:
        chats = {c for c in (notice.thread, notice.session_id) if c}
        if here.get("live") and chats & set(here["live"]):
            return False
        if here["state"] == "foreground" and here.get("session") in chats:
            return False
    return True


def deliver(notice, walked_away=()):
    with LOCK:
        devices = dict(STATE["devices"])
        open_count = len(STATE["requests"])
        resolved = list(STATE["resolved"])
    for device_id, device in devices.items():
        if not wants(device_id, device, notice, walked_away):
            continue
        request = notices.apns_request(device, notice, GATEWAY, open_count, resolved)
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
        log(f"→ {notice.kind} '{notice.title}' to {device.get('name') or device_id}")


def withdraw(ids):
    with LOCK:
        closed = [rid for rid in ids if STATE["requests"].pop(rid, None) is not None]
        STATE["resolved"] = (closed + STATE["resolved"])[:30]
        devices = dict(STATE["devices"])
        open_count = len(STATE["requests"])
    if not closed:
        return
    for device in devices.values():
        request = notices.withdraw_request(device, closed, GATEWAY, open_count)
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
    log(f"withdrew {', '.join(closed)}")


def activity(session, state, *, event="update", alert=False):
    with LOCK:
        targets = [(STATE["devices"].get(d), a) for d, a in STATE["activities"].items() if a["session"] == session]
    for device, record in targets:
        if device is None:
            continue
        request = notices.activity_request(device, record, {**state, "gateway": GATEWAY["name"]}, event=event, alert=alert)
        threading.Thread(target=relay, args=(device, request), daemon=True).start()


def relay(device, request):
    if RELAY["mode"] == "simctl":
        return simctl(device, request)
    return https_relay(request)


def simctl(device, request):
    udid = device.get("simulator")
    if request["push_type"] == "liveactivity":
        log("Live Activity update (simctl can't deliver these; use --push-relay with a real relay)")
        return {"status": 200}
    if not udid:
        log(f"no simulator for {device.get('name')}; dropping {request['push_type']}")
        return {"status": 200}
    payload = {**request["payload"], "Simulator Target Bundle": device["topic"]}
    try:
        done = subprocess.run(["xcrun", "simctl", "push", udid, device["topic"], "-"], input=json.dumps(payload).encode(),
                              capture_output=True, timeout=30)
        if done.returncode != 0:
            log(f"simctl push failed: {done.stderr.decode(errors='replace').strip()}")
            return {"status": 500, "reason": "simctl"}
    except Exception as error:  # noqa: BLE001
        log(f"simctl push failed: {error}")
        return {"status": 500, "reason": str(error)}
    return {"status": 200}


def https_relay(request):
    base = RELAY["mode"].rstrip("/")

    def post(path, body, headers=None):
        data = json.dumps(body).encode()
        req = urllib.request.Request(f"{base}{path}", data=data, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "hermes-mock-push",
                                              **(headers or {})})
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read() or b"{}")

    try:
        if not RELAY["installation"]:
            answer = post("/v1/installations", {"client": "hermes-mock-push", "name": GATEWAY["name"]})
            RELAY["installation"], RELAY["secret"] = answer["installation_id"], answer["secret"]
            GATEWAY["id"] = RELAY["installation"]
        result = post("/v1/push", request, {"Authorization": f"Bearer {RELAY['secret']}",
                                            "X-Hermes-Installation": RELAY["installation"]})
        log(f"relay: {result}")
        return result
    except Exception as error:  # noqa: BLE001
        log(f"relay failed: {error}")
        return {"status": 502, "reason": str(error)}


# ── Hooks into the mock ──────────────────────────────────────────────────────────────────────────────

def chat_title(stored):
    session = B["STORED"].get(stored) or {}
    title = session.get("title") or ""
    if title == B["BOT_CHAT"]:
        return B["bot_title"](session.get("profile", "default"))
    return title


def bot_of(stored):
    session = B["STORED"].get(stored) or {}
    profile = session.get("profile", "default")
    if session.get("title") == B["BOT_CHAT"] and profile in B["PROFILES"]:
        return B["bot_title"](profile)
    return ""


def watching(stored):
    with LOCK:
        return {d for d, p in STATE["presence"].items()
                if p["state"] == "foreground" and p.get("session") == stored and time.time() - p["at"] <= PRESENCE_TTL}


def install(backend_globals, gateway_module=None, relay_mode="simctl", gateway_name="Mock Gateway", chats_module=None):
    global notices, G
    B.update(backend_globals)
    G = gateway_module
    notices = _load_notices()
    RELAY["mode"] = relay_mode
    GATEWAY["name"] = gateway_name
    methods = backend_globals["METHODS"]
    original_dispatch = methods.get("command.dispatch")

    def dispatch(params):
        if str(params.get("name") or "").lstrip("/") == "app-push":
            return {"type": "plugin", "output": command(params.get("arg") or "")}
        if original_dispatch:
            return original_dispatch(params)
        raise backend_globals["RPCError"](4018, f"not a quick/plugin/bundle/skill command: {params.get('name')}")

    def approval_respond(params):
        request_id = params.get("request_id") or ""
        choice = params.get("choice") or "deny"
        with backend_globals["LOCK"]:
            pending = backend_globals["PENDING"]
            rid = next((rid for rid, entry in pending.items() if entry["frame"]["method"] == "approval"
                        and entry["frame"]["params"].get("request_id") == request_id), None)
            if rid is None:
                return {"resolved": 0}
            pending[rid]["result"] = {"choice": choice}
            pending[rid]["event"].set()
        return {"resolved": 1}

    def request_answer(params):
        rid = params.get("id") or ""
        with backend_globals["LOCK"]:
            entry = backend_globals["PENDING"].get(rid)
            if entry is None:
                return {"status": "expired"}
            entry["result"] = params.get("result")
            entry["event"].set()
        return {"status": "ok"}

    methods["command.dispatch"] = dispatch
    methods["approval.respond"] = approval_respond
    methods["request.answer"] = request_answer

    original_request = backend_globals["server_request"]

    def server_request(sid, method, params, timeout=300):
        runtime = backend_globals["RUNTIME"].get(sid) or {}
        stored = runtime.get("stored", "")
        notice = None
        expires = time.time() + timeout
        if method == "approval":
            request_id = params.get("request_id") or f"ap_{uuid.uuid4().hex[:6]}"
            params = {**params, "request_id": request_id}
            notice = notices.approval(request_id=request_id, session_id=stored, chat=chat_title(stored),
                                      gateway_name=GATEWAY["name"], command=params.get("command", ""),
                                      description=params.get("description", ""),
                                      choices=params.get("choices") or ["once", "deny"], expires_at=expires,
                                      bot=bot_of(stored))
            notice.extra["answer"] = {"via": "socket", "session_id": stored}
            state = {"phase": "needsYou", "command": notice.extra["command"], "request_id": request_id,
                     "expires_at": expires, "title": chat_title(stored), "answer": notice.extra["answer"]}
        elif method == "clarify":
            request_id = f"hi_{uuid.uuid4().hex[:8]}"
            notice = notices.question(request_id=request_id, session_id=stored, chat=chat_title(stored),
                                      gateway_name=GATEWAY["name"], questions=params.get("questions") or [],
                                      prompt="", expires_at=expires, bot=bot_of(stored))
            notice.extra["answer"] = {"via": "socket", "session_id": stored}
            state = {"phase": "needsYou", "question": notice.body, "request_id": request_id, "title": chat_title(stored)}
        elif method in ("sudo", "secret"):
            request_id = f"hi_{uuid.uuid4().hex[:8]}"
            notice = notices.password(request_id=request_id, session_id=stored, chat=chat_title(stored),
                                      gateway_name=GATEWAY["name"], what=params.get("command", "") if method == "sudo" else "",
                                      expires_at=expires)
            state = {"phase": "needsYou", "question": "Needs a password", "request_id": request_id, "title": chat_title(stored)}
        if notice is not None:
            with LOCK:
                STATE["requests"][notice.request_id] = {"kind": notice.kind, "session": stored, "expires_at": expires}
            deliver(notice)
            activity(stored, state, alert=True)
        try:
            return original_request(sid, method, params, timeout)
        finally:
            if notice is not None:
                withdraw([notice.request_id])
                activity(stored, {"phase": "working", "step": "Continuing", "title": chat_title(stored)})

    backend_globals["server_request"] = server_request

    original_run = backend_globals["run_turn"]

    def run_turn(sid, text):
        runtime = backend_globals["RUNTIME"].get(sid) or {}
        stored = runtime.get("stored", "")
        turn = {"start": time.time(), "watching": watching(stored), "stored": stored}
        with LOCK:
            STATE["turns"][sid] = turn
        activity(stored, {"phase": "working", "step": "Thinking", "started_at": turn["start"], "title": chat_title(stored)})
        words = set(text.lower().replace("?", " ").replace(".", " ").split())
        if words & {"ask", "sudo"}:
            # A question or a password, then the reply: the turn's opening is the mock's own.
            stored = backend_globals["ensure_row"](sid)
            backend_globals["add_message"](stored, "user", text)
            backend_globals["emit"](sid, "session.info", {"running": True})
            backend_globals["emit"](sid, "message.start", {})
            if "ask" in words:
                answer = server_request(sid, "clarify", {"questions": [{
                    "qid": "q1", "question": "Keep the snapshots from the last 7 days, or the last 30?",
                    "choices": ["Last 7 Days", "Last 30 Days"]}]})
                picked = ((answer or {}).get("answers") or {}).get("q1") or "nothing yet"
                reply = f"Okay: **{picked}**. I'll keep those and clear the rest."
            else:
                server_request(sid, "sudo", {"command": "apt-get upgrade -y"}, timeout=120)
                reply = "Thanks. The upgrade finished: **14 packages** updated."
            backend_globals["stream"](sid, reply)
            return backend_globals["finish"](sid, stored, reply)
        return original_run(sid, text)

    backend_globals["run_turn"] = run_turn

    original_finish = backend_globals["finish"]

    def finish(sid, stored, text, status="complete", error=None):
        result = original_finish(sid, stored, text, status=status, error=error)
        with LOCK:
            turn = STATE["turns"].pop(sid, None)
        if turn:
            seconds = time.time() - turn["start"]
            ok = status == "complete"
            activity(stored, {"phase": "done", "result": notices.first_lines(text, 1, 120) if ok else "Didn't finish.",
                              "title": chat_title(stored), "started_at": turn["start"], "ended_at": time.time(),
                              "ok": ok}, event="end")
            if ok and text.strip():
                notice = notices.reply(session_id=stored, turn_id=sid, chat=chat_title(stored), gateway_name=GATEWAY["name"],
                                       text=text, seconds=seconds)
                bot = bot_of(stored)
                if bot:
                    notice.title = bot
                deliver(notice, walked_away=turn["watching"])
        return result

    backend_globals["finish"] = finish

    original_cron = methods.get("cron.manage")

    def cron_manage(params):
        result = original_cron(params)
        if params.get("action") == "run" and result.get("success") is not False:
            name = params.get("name") or "Routine"
            notice = notices.task(job_id=name, name=name, gateway_name=GATEWAY["name"],
                                  text="Ran on request. Two new papers on speculative decoding look worth a read.",
                                  failed=False)
            deliver(notice)
        return result

    if original_cron:
        methods["cron.manage"] = cron_manage

    if gateway_module is not None:
        install_api(gateway_module)
    if chats_module is not None:
        install_chats(chats_module, gateway_module)
    log(f"push ready: relay {RELAY['mode']}, gateway '{GATEWAY['name']}' ({GATEWAY['id']})")


def install_api(gateway):
    """API server runs (``/v1/runs``): approvals keyed by the run id, answered with ``POST
    /v1/runs/{id}/approval``; finished runs notify like socket turns."""
    run_class = gateway.Run
    original_emit = run_class.emit
    original_finish = run_class.finish

    def emit(self, name, **fields):
        original_emit(self, name, **fields)
        if name == "approval.request":
            request_id = fields.get("request_id") or f"ap_{uuid.uuid4().hex[:6]}"
            expires = time.time() + 300
            session = gateway.SESSIONS.get(self.session_id) or {}
            notice = notices.approval(request_id=request_id, session_id=self.session_id, chat=session.get("title") or "",
                                      gateway_name=GATEWAY["name"], command=fields.get("command", ""),
                                      description=fields.get("description", ""), choices=["once", "session", "always", "deny"],
                                      expires_at=expires)
            notice.extra["answer"] = {"via": "run", "run_id": self.id}
            with LOCK:
                STATE["requests"][request_id] = {"kind": "approval", "session": self.session_id, "expires_at": expires}
            deliver(notice)
        elif name == "approval.responded" and fields.get("request_id"):
            withdraw([fields["request_id"]])

    def finish(self):
        original_finish(self)
        if getattr(self, "_push_started", None) is None:
            return
        seconds = time.time() - self._push_started
        if self.status in ("completed", "complete") and (self.output or "").strip():
            session = gateway.SESSIONS.get(self.session_id) or {}
            deliver(notices.reply(session_id=self.session_id, turn_id=self.id, chat=session.get("title") or "",
                                  gateway_name=GATEWAY["name"], text=self.output, seconds=seconds),
                    walked_away=self._push_watching)

    original_init = run_class.__init__

    def init(self, run_id, session_id, text):
        original_init(self, run_id, session_id, text)
        self._push_started = time.time()
        self._push_watching = watching(session_id)

    run_class.emit, run_class.finish, run_class.__init__ = emit, finish, init


def install_chats(chats, gateway):
    """The app's own chats over the socket (``chats.py``): their turns notify like Bot Chats'."""
    original_run, original_finish = chats.run_chat_turn, chats.finish

    def title(stored):
        return ((gateway.SESSIONS.get(stored) if gateway else None) or {}).get("title") or ""

    def run_chat_turn(sid, text):
        stored = B["RUNTIME"][sid]["stored"]
        turn = {"start": time.time(), "watching": watching(stored), "stored": stored}
        with LOCK:
            STATE["turns"][sid] = turn
        activity(stored, {"phase": "working", "step": "Thinking", "started_at": turn["start"], "title": title(stored)})
        return original_run(sid, text)

    def finish(sid, stored, text, *, status="complete", **extra):
        result = original_finish(sid, stored, text, status=status, **extra)
        with LOCK:
            turn = STATE["turns"].pop(sid, None)
        if turn:
            ok = status == "complete"
            activity(stored, {"phase": "done", "result": notices.first_lines(text, 1, 120) if ok else "Didn't finish.",
                              "title": title(stored), "started_at": turn["start"], "ended_at": time.time(), "ok": ok},
                     event="end")
            if ok and (text or "").strip():
                deliver(notices.reply(session_id=stored, turn_id=sid, chat=title(stored), gateway_name=GATEWAY["name"],
                                      text=text, seconds=time.time() - turn["start"]), walked_away=turn["watching"])
        return result

    chats.run_chat_turn, chats.finish = run_chat_turn, finish
