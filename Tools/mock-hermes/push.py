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

Reading (docs/notifications.md §2, Reading): ``read`` and ``presence`` with ``unread``/``muted`` work like
the plugin's, read and badge pushes included, and so does plugin 1.4.6's badge: news read on another device
before its notice goes notifies nothing, and withdrawals, syncs and the answers to ``presence`` and ``status``
carry the latest reads. ``GET /api/mock/push-state`` shows what it recorded,
``POST /api/mock/read {chats, rooms}`` plays a read on another device, ``POST /api/mock/badge {badge}``
sends every device a badge-only push now.
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
                       "bots": "mentions", "background": True, "live_activity": True, "show_details": "always",
                       "mention_names": []}

B: dict = {}          # backend.py's globals
G = None              # server.py (the API server mock), when it runs too
STATE = {"devices": {}, "presence": {}, "requests": {}, "resolved": [], "activities": {}, "turns": {}, "held": {},
         "sync": {}, "reads": {"chats": {}, "rooms": {}}, "delivered": {}, "cleared": {}, "badges": {},
         "read_pushes": {}}
SYNC_MIN_INTERVAL = 60  # the plugin's: iOS rations background pushes
ROOM_MESSAGE_SETTLE = 5.0  # the plugin's: a Bot's streamed message notifies after this quiet time
# The plugin's reading rules: reads listed in notices for six hours (the newest 12 of each), at most one read
# push a device every 30 s carrying at most 40 of each, read and badge pushes 3 s after what moved them.
READ_TTL, NOTICE_READS, READ_MIN_INTERVAL, CLEARED_MAX, PUSH_DEBOUNCE = 6 * 3600, 12, 30, 40, 3.0
DUE: set = set()        # (read | badge, device) pushes waiting
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
        for key in ("delivered", "cleared", "badges", "read_pushes"):
            STATE[key].pop(args["device_id"], None)
    return {"ok": True, "removed": removed}


def cmd_preferences(args):
    with LOCK:
        device = STATE["devices"].get(args["device_id"])
        if device is None:
            raise ValueError("device not registered")
        device["preferences"] = {**DEFAULT_PREFERENCES, **(args.get("preferences") or {})}
        return {"ok": True, "preferences": device["preferences"]}


def cmd_presence(args):
    device_id = args["device_id"]
    with LOCK:
        STATE["presence"][device_id] = {"state": args["state"], "session": args.get("session_id"),
                                        "live": args.get("live"), "at": time.time()}
        # Leaving, the app names the chats to keep current while it's away.
        if args["state"] == "away" and isinstance(args.get("sync"), list):
            sent = STATE["sync"].get(device_id, {}).get("sent", 0)
            STATE["sync"][device_id] = {"sessions": [str(x) for x in args["sync"] if x][:20], "sent": sent}
        # Requests held back while their chat was on screen go out once it isn't.
        released, keep = [], {}
        for rid, (request, chats) in (STATE["held"].pop(device_id, None) or {}).items():
            if rid not in STATE["requests"]:
                continue
            if args["state"] == "foreground" and args.get("session_id") in chats:
                keep[rid] = (request, chats)
            else:
                released.append(request)
        if keep:
            STATE["held"][device_id] = keep
        if args["state"] == "foreground":
            # The app decides what's read while it's in front: forget what it was sent, cleared and counted.
            for key in ("delivered", "cleared", "badges"):
                STATE[key].pop(device_id, None)
            STATE["read_pushes"].get(device_id, {}).pop("pending", None)
        elif args["state"] == "away":
            unread, muted = _id_sets(args.get("unread")), _id_sets(args.get("muted")) or {"chats": [], "rooms": []}
            if unread is None:
                STATE["badges"].pop(device_id, None)  # its badge doesn't count unread chats
            else:
                others = args.get("badge_others")
                others = int(others) if isinstance(others, (int, float)) and not isinstance(others, bool) and others > 0 else 0
                # What the icon shows as the app leaves (plugin 1.4.5): a count that isn't this one is set right.
                shown = args.get("badge")
                shown = int(shown) if isinstance(shown, (int, float)) and not isinstance(shown, bool) and shown >= 0 else None
                STATE["badges"][device_id] = {
                    "chats": unread["chats"], "rooms": unread["rooms"], "muted_chats": muted["chats"],
                    "muted_rooms": muted["rooms"], "others": others,
                    "listed_chats": (_id_sets(args.get("listed")) or {"chats": []})["chats"],
                    "listed_rooms": (_id_sets(args.get("listed")) or {"rooms": []})["rooms"],
                    "shown": shown}
        device = STATE["devices"].get(device_id)
        open_count = len(STATE["requests"])
    if args["state"] == "away" and device_id in STATE["badges"]:
        soon("badge", device_id, PUSH_DEBOUNCE)
    for request in released:
        log(f"→ held request to {device.get('name') if device else device_id} (left the chat)")
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
    # Plugin 1.4.6: the latest reads ride along, so a room read elsewhere reaches this device.
    read = recent_reads()
    return {"ok": True, "open": open_count, **({"read": read} if read else {})}


def cmd_read(args):
    """Chats and rooms read on ``device_id`` (the plugin's ``read``): listed in every notice for six hours;
    other devices away from the app that were sent something for them get a read push, and their badge."""
    device_id = str(args.get("device_id") or "")
    if not device_id:
        raise ValueError("device_id is missing or malformed")
    chats, rooms = _ids(args.get("chats"), "chats", 50), _ids(args.get("rooms"), "rooms", 50)
    owed, moved = [], []
    with LOCK:
        now = time.time()
        read = {"chats": chats, "rooms": rooms}
        for kind in ("chats", "rooms"):
            times = STATE["reads"][kind]
            times.update({key: now for key in read[kind]})
            for key in [key for key, at in times.items() if now - at > READ_TTL]:
                times.pop(key)
        for other in STATE["devices"]:
            if other == device_id or in_app(other):
                continue
            sent = STATE["delivered"].get(other) or {}
            matched = False
            for kind in ("chats", "rooms"):
                for key in [key for key in read[kind] if key in (sent.get(kind) or {})]:
                    sent[kind].pop(key)
                    STATE["cleared"].setdefault(other, {}).setdefault(kind, {})[key] = now  # when it was read
                    matched = True
            record = STATE["badges"].get(other)
            # Plugin 1.4.6: a chat it counted, never sent to it, goes in its read push too.
            counted = {kind: [key for key in (record or {}).get(kind, []) if key in read[kind]] for kind in ("chats", "rooms")}
            if any(counted.values()):
                matched = True
                for kind, keys in counted.items():
                    for key in keys:
                        STATE["cleared"].setdefault(other, {}).setdefault(kind, {})[key] = now
            # Rooms too: the app marks a room read when it hears another device read it.
            if record and (set(chats) & set(record["chats"]) or set(rooms) & set(record["rooms"])):
                record["chats"] = [c for c in record["chats"] if c not in set(chats)]
                record["rooms"] = [r for r in record["rooms"] if r not in set(rooms)]
                moved.append(other)
            if matched:
                entry = STATE["read_pushes"].setdefault(other, {})
                entry["pending"] = True
                owed.append((other, entry.get("sent", 0) + READ_MIN_INTERVAL - now))
        open_count = len(STATE["requests"])
    if chats or rooms:
        log(f"read on {device_id}: {', '.join(chats + rooms)}")
    for other, wait in owed:
        soon("read", other, max(PUSH_DEBOUNCE, wait))
    for other in moved:
        soon("badge", other, PUSH_DEBOUNCE)
    return {"ok": True, "open": open_count}


def _ids(value, key, limit):
    """The plugin's id lists: strings clipped to 120 characters, no repeats, at most ``limit``."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"{key} must be a list of ids")
    return list(dict.fromkeys(v[:120] for v in value if isinstance(v, str) and v))[:limit]


def _id_sets(value):
    if not isinstance(value, dict):
        return None
    sets = {}
    for kind in ("chats", "rooms"):
        try:
            sets[kind] = _ids(value.get(kind), kind, 200)
        except ValueError:
            sets[kind] = []
    return sets


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
    expire()
    read = recent_reads()
    with LOCK:
        device = STATE["devices"].get(args.get("device_id") or "")
        return {"ok": True, "version": "mock", "gateway": GATEWAY, "relay_url": RELAY["mode"], "relay_registered": True,
                "relay_error": None, "devices": len(STATE["devices"]), "registered": device is not None,
                "preferences": device["preferences"] if device else None, "open": len(STATE["requests"]),
                **({"read": read} if read else {})}


# Hermes writes the gateway's plist again without ProcessType on every update and restart
# (gateway_launchd.refresh_launchd_plist_if_needed), and launchd keeps running the job as it loaded
# it until the deferred reload, RELOAD_AFTER seconds later. setup.py and app_plugins.py call
# reset_priority when a good run gets that far; set_states clears it.
PRIORITY = {"reset_at": None, "stripped": None}
RELOAD_AFTER = 20


def reset_priority(at):
    with LOCK:
        PRIORITY.update(reset_at=at, stripped=None)


def cmd_host(args):
    """``/app-push host`` (plugin ``hostinfo.report``): Hermes's launchd jobs on the gateway's Mac,
    shaped by setup.py's states. ``throttled-here`` and ``priority-here`` report this Mac's machine
    id and plists in build/mock-launch-agents (written throttled, or Interactive), and read them
    back, so the Mac app's fix shows up as interactive. After an update or restart (PRIORITY) the
    gateway's plist has lost ProcessType, and from RELOAD_AFTER on launchd runs it that way."""
    states = B.get("MOCK_SETUP_STATES") or set()
    if "push-old" in states:
        raise ValueError("unknown command 'host'")
    if "host-linux" in states:
        return {"ok": True, "version": "mock", "host": {"os": "linux", "machine_id": "mock-linux", "jobs": []}}
    here = "throttled-here" in states or "priority-here" in states
    throttled = "throttled-here" in states or "throttled" in states
    with LOCK:
        reset_at = PRIORITY["reset_at"]
        reset = reset_at is not None and time.time() >= reset_at
        reloaded = reset and time.time() >= reset_at + RELOAD_AFTER
        strip = reset and PRIORITY["stripped"] != reset_at
        if strip:
            PRIORITY["stripped"] = reset_at
    folder = HERE.parent.parent / "build" / "mock-launch-agents" if here else pathlib.Path("/Users/sam/Library/LaunchAgents")
    machine = "mock-machine-0001"
    if here:
        import hashlib
        import plistlib
        import re
        out = subprocess.run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', out)
        machine = hashlib.sha256(match.group(1).encode()).hexdigest()[:16] if match else machine
        folder.mkdir(parents=True, exist_ok=True)
    jobs = []
    for index, (label, role, program) in enumerate((("ai.hermes.dashboard", "dashboard", ["hermes", "dashboard"]),
                                                     ("ai.hermes.gateway", "gateway", ["hermes", "gateway", "run"]))):
        plist = folder / f"{label}.plist"
        process_type = None if throttled else "Interactive"
        rewritten = reset and role == "gateway"
        if here:
            if not plist.exists():
                data = {"Label": label, "ProgramArguments": program, "RunAtLoad": True}
                plist.write_bytes(plistlib.dumps(data if throttled else {**data, "ProcessType": "Interactive"}))
            if rewritten and strip:
                data = plistlib.loads(plist.read_bytes())
                data.pop("ProcessType", None)
                plist.write_bytes(plistlib.dumps(data))
            process_type = plistlib.loads(plist.read_bytes()).get("ProcessType")
        elif rewritten:
            process_type = None
        # Until the reload, the gateway runs as it was loaded before the run.
        loaded = process_type if not rewritten or reloaded else (None if throttled else "Interactive")
        interactive = loaded == "Interactive"
        jobs.append({"label": label, "role": role, "plist": str(plist), "process_type": process_type,
                     "spawn_type": "interactive" if interactive else "daemon", "pid": 4100 + index + (100 if reloaded and rewritten else 0),
                     "priority": 31 if interactive else 20})
    return {"ok": True, "version": "mock", "host": {"os": "darwin", "machine_id": machine, "jobs": jobs}}


def cmd_test(args):
    with LOCK:
        device = STATE["devices"].get(args["device_id"])
    if device is None:
        raise ValueError("device not registered")
    notice = notices.Notice(kind="test", id=f"test-{int(time.time())}", title="Push notifications are on",
                            body=f"{GATEWAY['name']} can reach this device.", hidden=f"Test from {GATEWAY['name']}")
    result = relay(device, notices.apns_request(device, notice, GATEWAY, 0, [], recent_reads()))
    return {"ok": result.get("status") == 200, "status": result.get("status"), "reason": result.get("reason")}


COMMANDS = {"register": cmd_register, "unregister": cmd_unregister, "preferences": cmd_preferences,
            "presence": cmd_presence, "read": cmd_read, "activity": cmd_activity, "status": cmd_status,
            "test": cmd_test, "host": cmd_host}


# ── Delivery ─────────────────────────────────────────────────────────────────────────────────────────

def presence(device_id):
    entry = STATE["presence"].get(device_id)
    if not entry or time.time() - entry["at"] > PRESENCE_TTL:
        return None
    return entry


def in_app(device_id):
    here = presence(device_id)
    return bool(here) and here["state"] in ("foreground", "running")


def recent_reads():
    """What every notice lists: the newest reads of the last six hours, ``{chats: [[id, at]…], rooms}``."""
    now = time.time()
    with LOCK:
        listed = {kind: [[key, round(at, 3)] for key, at in sorted(STATE["reads"][kind].items(), key=lambda i: -i[1])
                         if now - at <= READ_TTL][:NOTICE_READS] for kind in ("chats", "rooms")}
    return listed if listed["chats"] or listed["rooms"] else {}


def news_key(notice):
    if notice.kind == "reply":
        return "chats", notice.session_id or notice.thread
    if notice.kind == "message":
        return "rooms", notice.extra.get("room_id") or notice.thread.removeprefix("room:")
    return None, None


def read_since(notice, news_at):
    """Plugin 1.4.6: a reply or Bot message whose chat was read on some device after it landed."""
    kind, key = news_key(notice)
    with LOCK:
        at = STATE["reads"].get(kind, {}).get(key) if kind and key else None
    return at is not None and at >= news_at


def delivered(notice, device_ids):
    """A reply's chat or a Bot message's room went to these devices: a read elsewhere clears it there, and
    it counts on badges that count unread chats (unless it's muted there)."""
    kind, key = news_key(notice)
    if not key:
        return
    moved = []
    with LOCK:
        for device_id in device_ids:
            STATE["delivered"].setdefault(device_id, {}).setdefault(kind, {})[key] = time.time()
            record = STATE["badges"].get(device_id)
            # Only a chat the app lists counts (plugin 1.4.2): routine runs and one-shot chats never do.
            if (record and key not in record[f"muted_{kind}"] and key not in record[kind]
                    and key in record.get(f"listed_{kind}", [])):
                record[kind].append(key)
                moved.append(device_id)
    for device_id in moved:
        soon("badge", device_id, PUSH_DEBOUNCE)


def soon(kind, device_id, delay):
    """One waiting read (or badge) push per device: what changes meanwhile goes with it."""
    with LOCK:
        if (kind, device_id) in DUE:
            return
        DUE.add((kind, device_id))
    timer = threading.Timer(delay, flush, args=(kind, device_id))
    timer.daemon = True
    timer.start()


def flush(kind, device_id):
    request, retry = None, 0
    with LOCK:
        DUE.discard((kind, device_id))
        device = STATE["devices"].get(device_id)
        if device is None or in_app(device_id):
            STATE["read_pushes"].get(device_id, {}).pop("pending", None)
            return
        if kind == "read":
            entry = STATE["read_pushes"].get(device_id) or {}
            wait = entry.get("sent", 0) + READ_MIN_INTERVAL - time.time()
            if entry.get("pending") and wait > 0.5:
                retry = wait  # inside the 30 s window: after it
            elif entry.get("pending"):
                cleared = STATE["cleared"].get(device_id) or {}
                read = {k: [[key, round(at, 3)] for key, at in sorted((cleared.get(k) or {}).items(),
                                                                      key=lambda i: -i[1])][:CLEARED_MAX]
                        for k in ("chats", "rooms")}
                entry.pop("pending", None)
                if read["chats"] or read["rooms"]:
                    entry["sent"] = time.time()
                    request = notices.read_request(device, read, GATEWAY, len(STATE["requests"]))
                    log(f"→ read {', '.join(key for key, _at in read['chats'] + read['rooms'])} to "
                        f"{device.get('name') or device_id}")
        else:
            record = STATE["badges"].get(device_id)
            count = (min(len(STATE["requests"]) + len(record["chats"]) + len(record["rooms"]) + record.get("others", 0), 9999)
                     if record else None)
            if count is not None and count != record["shown"]:
                record["shown"] = count
                request = notices.badge_request(device, count)
                log(f"→ badge {count} to {device.get('name') or device_id}")
    if request is not None:
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
    elif retry:
        soon("read", device_id, retry)


def wants(device_id, device, notice, walked_away=(), ignore_presence=False):
    prefs = device["preferences"]
    kind = notice.kind
    if kind in ("approval", "question", "widget") and not prefs["approvals"]:
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
    if kind in ("card_review", "card_done") and prefs["tasks"] != "all":
        return False
    if kind in ("card_needs_you", "card_stopped") and prefs["tasks"] == "off":
        return False
    if kind == "tidied" and prefs["tasks"] != "all":
        return False
    if kind == "message" and (prefs["bots"] == "off" or (prefs["bots"] == "mentions" and not notice.extra.get("mention"))):
        return False
    here = None if ignore_presence else presence(device_id)
    if here:
        chats = {c for c in (notice.thread, notice.session_id) if c}
        if here.get("live") and chats & set(here["live"]):
            return False
        if here["state"] == "foreground" and here.get("session") in chats:
            return False
    return True


def expire():
    """Forget requests past their deadline, like the plugin: they must not pin the badge."""
    now = time.time()
    with LOCK:
        for rid in [rid for rid, r in STATE["requests"].items() if r.get("expires_at") and r["expires_at"] < now - 30]:
            STATE["requests"].pop(rid, None)


def card_notice(kind, card, payload):
    """The mock board's events as the plugin's card notices (docs/board.md §5)."""
    if kind == "blocked" and (payload.get("kind") or "needs_input") in ("needs_input", "capability"):
        notice_kind, text = "card_needs_you", payload.get("reason") or ""
    elif kind == "review_requested":
        notice_kind, text = "card_review", B["MOCK_KANBAN"].latest_summary(card) or ""
    elif kind in ("gave_up", "crashed"):
        notice_kind, text = "card_stopped", payload.get("error") or card.get("last_failure_error") or ""
    elif kind == "completed":
        notice_kind, text = "card_done", payload.get("summary") or ""
    else:
        return
    profile = card.get("assignee") or ""
    board = card.get("_board") or "default"
    project = (B["MOCK_KANBAN"].BOARDS.get(board) or {}).get("project_id") or ""
    who = "Hermes" if profile in ("", "default") else B["bot_title"](profile)
    deliver(notices.card(notice_kind, card_id=card["id"], board=board, title=card.get("title", ""), who=who,
                         profile=profile, project_id=project, gateway_name=GATEWAY["name"], text=text))


def tidied_notice(profile, merged, archived, stale=0):
    """The mock curator's tidy (learned.py) as the plugin's notice (docs/learned.md)."""
    name = "" if profile in ("", "default") else profile
    who = B["bot_title"](name) if name else "Hermes"
    deliver(notices.tidied(profile=name, who=who, gateway_name=GATEWAY["name"], run=time.strftime("%Y%m%d-%H%M%S"),
                           merged=merged, archived=archived, stale=stale))


def deliver(notice, walked_away=(), news_at=None):
    expire()
    if news_at is not None and read_since(notice, news_at):
        log(f"{notice.kind} for a chat read since it landed: not sent")
        return
    with LOCK:
        devices = dict(STATE["devices"])
        open_count = len(STATE["requests"])
        resolved = list(STATE["resolved"])
    read = recent_reads()
    sent = []
    for device_id, device in devices.items():
        wanted = wants(device_id, device, notice, walked_away)
        if not wanted:
            if notice.kind in ("approval", "question", "password", "widget") and notice.request_id \
                    and wants(device_id, device, notice, walked_away, ignore_presence=True):
                request = notices.apns_request(device, notice, GATEWAY, open_count, resolved, read)
                with LOCK:
                    STATE["held"].setdefault(device_id, {})[notice.request_id] = (
                        request, [c for c in (notice.thread, notice.session_id) if c])
                log(f"held {notice.kind} for {device.get('name') or device_id} (chat on screen)")
            continue
        request = notices.apns_request(device, notice, GATEWAY, open_count, resolved, read)
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
        log(f"→ {notice.kind} '{notice.title}' to {device.get('name') or device_id}")
        sent.append(device_id)
    delivered(notice, sent)
    if notice.request_id:
        # Its extension counts the request in the badge, so that's what the icon shows now (plugin 1.4.5).
        with LOCK:
            for device_id in sent:
                record = STATE["badges"].get(device_id)
                if record is not None:
                    record["shown"] = min(len(STATE["requests"]) + len(record["chats"]) + len(record["rooms"])
                                          + record.get("others", 0), 9999)


def reply_or_request(session_id, turn_id, chat, text, seconds, walked_away, news_at=None):
    """A reply, or, when it asks something with a widget, the widget request (the plugin's
    ``on_session_end``): at once, Open only (docs/widgets.md §12)."""
    requests = notices.widget_requests(text)
    if requests:
        notice = notices.widget(payload=requests[0], session_id=session_id, chat=chat, gateway_name=GATEWAY["name"])
        with LOCK:
            STATE["requests"][notice.request_id] = {"kind": "widget", "session": session_id, "expires": notice.expires_at}
        deliver(notice, walked_away=walked_away)
        return
    deliver(notices.reply(session_id=session_id, turn_id=turn_id, chat=chat, gateway_name=GATEWAY["name"],
                          text=text, seconds=seconds), walked_away=walked_away, news_at=news_at)


def withdraw(ids):
    with LOCK:
        closed = [rid for rid in ids if STATE["requests"].pop(rid, None) is not None]
        STATE["resolved"] = (closed + STATE["resolved"])[:30]
        devices = dict(STATE["devices"])
        open_count = len(STATE["requests"])
    if not closed:
        return
    for device in devices.values():
        request = notices.withdraw_request(device, closed, GATEWAY, open_count, recent_reads())
        threading.Thread(target=relay, args=(device, request), daemon=True).start()
    log(f"withdrew {', '.join(closed)}")
    # Like plugin 1.4.5: the badge goes as its own push too, since iOS may drop the background withdraw.
    for device_id in list(STATE["badges"]):
        soon("badge", device_id, PUSH_DEBOUNCE)


def sync(stored, profile=None):
    """The plugin's `_sync`: a turn ended in `stored`, so devices that left the app keeping it current get a
    background push, at most once a minute (a change meanwhile goes after it)."""
    now = time.time()
    wake, later = [], []
    with LOCK:
        for device_id, entry in STATE["sync"].items():
            if stored not in entry["sessions"] or device_id not in STATE["devices"]:
                continue
            wait = entry.get("sent", 0) + SYNC_MIN_INTERVAL - now
            if wait <= 0:
                entry.update(sent=now, held=[])
                wake.append(device_id)
            else:
                if stored not in entry.setdefault("held", []):
                    entry["held"].append(stored)
                later.append((device_id, wait))
    for device_id in wake:
        send_sync(device_id, [stored], profile)
    for device_id, wait in later:
        threading.Timer(wait + 0.5, send_held_sync, args=(device_id,)).start()


def send_held_sync(device_id):
    with LOCK:
        entry = STATE["sync"].get(device_id)
        if not entry or not entry.get("held") or time.time() - entry.get("sent", 0) < SYNC_MIN_INTERVAL:
            return
        held = entry["held"]
        entry.update(sent=time.time(), held=[])
    send_sync(device_id, held)


def send_sync(device_id, sessions, profile=None):
    here = presence(device_id)
    if here and here["state"] == "foreground":
        return  # back in the app, which reads its chats itself
    with LOCK:
        device = STATE["devices"].get(device_id)
        open_count = len(STATE["requests"])
    if device is None:
        return
    request = notices.sync_request(device, sessions, GATEWAY, open_count, profile, recent_reads())
    threading.Thread(target=relay, args=(device, request), daemon=True).start()
    log(f"→ sync {', '.join(sessions)} to {device.get('name') or device_id}")


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


def _tls():
    """python.org builds ship without CA certificates; use the system's."""
    import os
    import ssl
    cafile = "/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None
    return ssl.create_default_context(cafile=cafile)


def https_relay(request):
    base = RELAY["mode"].rstrip("/")

    def post(path, body, headers=None):
        data = json.dumps(body).encode()
        req = urllib.request.Request(f"{base}{path}", data=data, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "hermes-mock-push",
                                              **(headers or {})})
        with urllib.request.urlopen(req, timeout=15, context=_tls()) as response:
            return json.loads(response.read() or b"{}")

    try:
        if not RELAY["installation"]:
            answer = post("/v1/installations", {"client": "hermes-mock-push", "name": GATEWAY["name"]})
            RELAY["installation"], RELAY["secret"] = answer["installation_id"], answer["secret"]
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


def profile_of(stored):
    session = B["STORED"].get(stored) or {}
    profile = session.get("profile", "default")
    return "" if profile == "default" else profile


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
    kanban = backend_globals.get("MOCK_KANBAN")
    if kanban is not None:
        kanban.HOOKS.append(card_notice)
    backend_globals["MOCK_LEARNED_TIDIED"] = tidied_notice
    backend_globals["MOCK_RESET_PRIORITY"] = reset_priority

    def dispatch(params):
        installed = backend_globals.get("APP_PLUGIN_INSTALLED")
        # Hermes knows the command only while the root has the plugin on (app_plugins.py).
        if str(params.get("name") or "").lstrip("/") == "app-push" and (installed is None or installed("hermes-app-push")):
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

    def push_reply(query, body):
        # Mock-only: a finished reply's notice now, as if its turn ran long ({"text", "chat", "session_id",
        # "profile"}), for checking how notifications read without waiting out a 30 s turn. `"delay": n`
        # sends it n seconds after the reply landed (a slow end of turn), so a read meanwhile counts.
        notice = notices.reply(session_id=body.get("session_id") or "mock_session", turn_id=f"mock-{time.time()}",
                               chat=body.get("chat") or "", gateway_name=GATEWAY["name"], text=body.get("text") or "",
                               seconds=999)
        if body.get("profile"):
            notice.extra["profile"] = body["profile"]
        try:
            delay = max(0.0, min(float(body.get("delay") or 0), 60.0))
        except (TypeError, ValueError):
            return 400, {"ok": False, "error": "delay must be a number"}
        if not delay:
            deliver(notice)
            return 200, {"ok": True}
        timer = threading.Timer(delay, deliver, kwargs={"notice": notice, "news_at": time.time()})
        timer.daemon = True
        timer.start()
        return 200, {"ok": True}

    backend_globals["HTTP_ROUTES"][("POST", "/api/mock/push-reply")] = push_reply

    def push_sync(query, body):
        # Mock-only: a `sync` to every device now, whatever its presence ({"sessions": [...]}), for checking
        # the app's handling without leaving it in the background.
        with LOCK:
            devices = dict(STATE["devices"])
            open_count = len(STATE["requests"])
        for device in devices.values():
            request = notices.sync_request(device, list(body.get("sessions") or []), GATEWAY, open_count, None,
                                           recent_reads())
            threading.Thread(target=relay, args=(device, request), daemon=True).start()
        return 200, {"ok": True, "devices": len(devices)}

    backend_globals["HTTP_ROUTES"][("POST", "/api/mock/sync")] = push_sync

    def push_state(query, body):
        # Mock-only: what the push mock recorded for reading (docs/notifications.md §2, Reading).
        with LOCK:
            return 200, json.loads(json.dumps({key: STATE[key] for key in (
                "presence", "reads", "delivered", "cleared", "badges", "read_pushes")}))

    def mock_read(query, body):
        # Mock-only: chats and rooms read on another device ({"chats", "rooms", "device_id"?}), as the app's
        # `read` from there: devices away that were sent something for them get a read push (and a badge).
        try:
            return 200, cmd_read({"device_id": body.get("device_id") or "mock-other-device",
                                  "chats": body.get("chats"), "rooms": body.get("rooms")})
        except ValueError as error:
            return 400, {"ok": False, "error": str(error)}

    def mock_badge(query, body):
        # Mock-only: a badge-only push to every device now ({"badge": n}), whatever its presence.
        try:
            count = int(body.get("badge") or 0)
        except (TypeError, ValueError):
            return 400, {"ok": False, "error": "badge must be a number"}
        with LOCK:
            devices = dict(STATE["devices"])
        for device in devices.values():
            threading.Thread(target=relay, args=(device, notices.badge_request(device, count)), daemon=True).start()
        return 200, {"ok": True, "devices": len(devices)}

    backend_globals["HTTP_ROUTES"][("GET", "/api/mock/push-state")] = push_state
    backend_globals["HTTP_ROUTES"][("POST", "/api/mock/read")] = mock_read
    backend_globals["HTTP_ROUTES"][("POST", "/api/mock/badge")] = mock_badge

    original_request = backend_globals["server_request"]

    def server_request(sid, method, params, timeout=300):
        try:
            return _server_request(sid, method, params, timeout)
        except Exception as error:  # noqa: BLE001 — a mock should say what broke
            import traceback
            log(f"server_request hook failed: {error}\n{traceback.format_exc()}")
            raise

    def _server_request(sid, method, params, timeout=300):
        runtime = backend_globals["RUNTIME"].get(sid) or {}
        stored = runtime.get("stored", "")
        log(f"{method} requested in {stored or sid}")
        notice = None
        expires = time.time() + timeout
        if method == "approval":
            request_id = params.get("request_id") or f"ap_{uuid.uuid4().hex[:6]}"
            params = {**params, "request_id": request_id}
            # The plugin hears a card fill's surface from Hermes's hook; the socket's frame doesn't carry
            # it, so the mock knows web_turns.py's card fill by its command.
            command = str(params.get("command", ""))
            notice = notices.approval(request_id=request_id, session_id=stored, chat=chat_title(stored),
                                      gateway_name=GATEWAY["name"], command=command,
                                      description=params.get("description", ""),
                                      choices=params.get("choices") or ["once", "deny"], expires_at=expires,
                                      surface="vault-payment" if command.startswith("Fill payment card '") else "",
                                      bot=bot_of(stored))
            notice.extra["answer"] = {"via": "socket", "session_id": stored}
            # Like the plugin: a card fill's Live Activity carries no request id (no Allow on the Lock Screen).
            state = {"phase": "needsYou", "command": notice.extra["command"],
                     "request_id": None if notices.opens_only(notice) else request_id,
                     "started_at": (STATE["turns"].get(sid) or {}).get("start"),
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
            if profile_of(stored):
                notice.extra["profile"] = profile_of(stored)
            with LOCK:
                STATE["requests"][notice.request_id] = {"kind": notice.kind, "session": stored, "expires_at": expires}
            deliver(notice)
            activity(stored, state, alert=True)
        try:
            return original_request(sid, method, params, timeout)
        finally:
            if notice is not None:
                withdraw([notice.request_id])
                started = (STATE["turns"].get(sid) or {}).get("start")
                activity(stored, {"phase": "working", "step": "Continuing", "title": chat_title(stored),
                                  **({"started_at": started} if started else {})})

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
        if "long" in words:
            # A long planned turn: the Live Activity's steps and progress, like the plugin's
            # pre_tool_call updates (every 6 s here).
            stored = backend_globals["ensure_row"](sid)
            backend_globals["add_message"](stored, "user", text)
            backend_globals["emit"](sid, "session.info", {"running": True})
            backend_globals["emit"](sid, "message.start", {})
            steps = ["Listing snapshots older than 30 days", "Checking which snapshots are in use",
                     "Measuring the space each one takes", "Planning what to keep",
                     "Deleting 14 old snapshots", "Compacting the volume", "Verifying the backup chain",
                     "Writing the summary"]
            for index, label in enumerate(steps):
                if backend_globals["RUNTIME"][sid]["interrupt"]:
                    break
                if index == 4 and "approve" in words:
                    # Needs you, mid-turn: the activity turns to Deny / Allow Once.
                    server_request(sid, "approval", {
                        "request_id": f"ap_{uuid.uuid4().hex[:6]}", "command": "rm -rf ~/snapshots/2026-0[1-8]-*",
                        "description": "deletes files recursively", "choices": ["once", "session", "always", "deny"]})
                activity(stored, {"phase": "working", "step": label, "started_at": turn["start"],
                                  "progress": {"done": index, "total": len(steps)}, "title": chat_title(stored)})
                backend_globals["tool"](sid, stored, "terminal", {"command": label.lower()},
                                        json.dumps({"output": "ok", "exit_code": 0}), 6.0, label)
            reply = "Done. Freed **42 GB** and kept the last 7 days of snapshots."
            backend_globals["stream"](sid, reply)
            return backend_globals["finish"](sid, stored, reply)
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
                    notice.extra["bot"] = bot
                if profile_of(stored):
                    notice.extra["profile"] = profile_of(stored)
                deliver(notice, walked_away=turn["watching"])
        return result

    backend_globals["finish"] = finish

    # A Bot Chat's reply stored (a turn over the socket, another Bot's message, a routine's delivery):
    # the chat changed, for devices keeping it current.
    original_add = backend_globals["add_message"]

    def add_message(sid, role, content, ts=None, touch=True, **extra):
        row = original_add(sid, role, content, ts=ts, touch=touch, **extra)
        if role == "assistant" and content and not extra.get("tool_calls") and extra.get("display_kind") != "hidden":
            threading.Thread(target=sync, args=(sid, profile_of(sid)), daemon=True).start()
        return row

    backend_globals["add_message"] = add_message

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
            reply_or_request(self.session_id, self.id, session.get("title") or "", self.output, seconds, self._push_watching,
                             news_at=time.time())

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
                reply_or_request(stored, sid, title(stored), text, time.time() - turn["start"], turn["watching"],
                                 news_at=time.time())
            sync(stored)
        return result

    original_event = chats.room_event

    def room_event(room, kind, actor, payload):
        # The plugin's ``on_room_member_activity``: a Bot's message in a group chat notifies once it has
        # settled, 5 s on; a room read on another device meanwhile notifies nothing (plugin 1.4.6).
        event = original_event(room, kind, actor, payload)
        text = (payload or {}).get("text") or ""
        if kind == "message.member" and text.strip():
            profile = (actor or {}).get("profile") or (actor or {}).get("id") or ""
            name = next((m.get("display_name") for m in room.get("members") or [] if m.get("profile") == profile), profile)
            notice = notices.message(room_id=room["room_id"], room=room.get("name") or "", member_id=profile, bot=name,
                                     gateway_name=GATEWAY["name"], text=text, mention=False)
            timer = threading.Timer(ROOM_MESSAGE_SETTLE, deliver, kwargs={"notice": notice, "news_at": event["created_at"]})
            timer.daemon = True
            timer.start()
        return event

    chats.run_chat_turn, chats.finish, chats.room_event = run_chat_turn, finish, room_event
