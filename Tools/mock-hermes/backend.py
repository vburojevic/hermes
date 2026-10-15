#!/usr/bin/env python3
"""A mock Hermes backend (`hermes serve`) for developing Bot Mode in the Hermes app.

Implements the slice of the dashboard REST API and the `/api/ws` JSON-RPC gateway
that Hermes Desktop's Bots pane uses (see tui_gateway/methods_*.py and
hermes_cli/web_routers/*.py in NousResearch/hermes-agent), with scripted agent
turns instead of a model, so no provider credentials or spend are needed.

    python3 Tools/mock-hermes/backend.py --port 19119                 # ungated: token in GET /
    python3 Tools/mock-hermes/backend.py --port 19119 --password pw   # gated: sign in as admin / pw

Scripted Bot Chat behaviour by message content:
  contains "approve"  -> asks for approval (a server->client JSON-RPC request) first
  contains "disk"     -> surveys Docker disk usage, then asks to prune it
  contains "fail"     -> the turn fails
  contains "slow"     -> a long multi-tool turn (good for testing stop and reconnect)
  an @mention note    -> uses message_agent and drops a DM into the other Bot's chat
  anything else       -> thinks, searches, then answers in Markdown
"""

import argparse
import base64
import hashlib
import json
import re
import secrets
import socket
import struct
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

LOCK = threading.RLock()
NOW = time.time()
HOUR = 3600
DAY = 86400
BOT_CHAT = "Bot Chat"


def iso(timestamp):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(timestamp))
    return stamp[:-2] + ":" + stamp[-2:]  # +02:00, as Hermes sends it
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

PROFILES = {}      # name -> profile dict
STORED = {}        # stored session id -> {profile, title, hidden, source, started_at, last_active, messages}
RUNTIME = {}       # runtime sid -> {stored, profile, running, interrupt, seq, ring, pending_title, pending_hidden}
CRON = {}          # profile -> {job_id: job}
PENDING = {}       # srq id -> {"event": Event, "result": dict | None, "sid": str}
CLIENTS = set()    # connected WebSocket peers
DROP = {"settle": 0, "refuse_until": 0.0}  # /api/mock/drop-sockets: resumes answered 4009, sockets refused
TICKETS = {}       # ws ticket -> expiry
SESSIONS_AUTH = {} # access cookie -> username
HTTP_ROUTES = {}   # (method, path) -> fn(query, body) -> (status, json): REST added by modules (projects.py)

CONFIG = {"token": secrets.token_urlsafe(24), "password": None, "username": "admin"}
GATEWAY_PAGING = []  # server.py's page_rows and throttle, when it runs alongside


# ── Data ─────────────────────────────────────────────────────────────────────

def avatar_png():
    """A 96x96 PNG: a teal→indigo diagonal gradient, the kind of photo avatar a user uploads."""
    size = 96
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            t = (x + y) / (2 * size - 2)
            dx, dy = x - size / 2, y - size / 2
            glow = max(0.0, 1 - (dx * dx + dy * dy) ** 0.5 / (size * 0.7))
            r = int((20 + 80 * t) + 60 * glow)
            g = int((184 - 120 * t) + 40 * glow)
            b = int((166 + 70 * t) + 20 * glow)
            row += bytes([min(r, 255), min(g, 255), min(b, 255)])
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", raw) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(png).decode()


def new_id():
    return time.strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6]


def add_profile(name, *, default=False, description="", display_name="", meta=None, model="claude-sonnet-4-6",
                provider="anthropic", avatar=None, previous=None):
    PROFILES[name] = {
        "name": name, "path": f"/Users/demo/.hermes/profiles/{name}" if not default else "/Users/demo/.hermes",
        "is_default": default, "model": model, "provider": provider, "description": description,
        "display_name": display_name, "skill_count": 38, "previous_names": previous or [],
        "ui_meta": {"hermes-bots": meta} if meta else {}, "revision": 1 if meta else 0, "avatar": avatar,
    }
    CRON.setdefault(name, {})


def add_session(profile, title, *, hidden=False, source="tui", started=None, sid=None):
    sid = sid or new_id()
    STORED[sid] = {"id": sid, "profile": profile, "title": title, "hidden": hidden, "source": source,
                   "started_at": started or time.time(), "last_active": started or time.time(), "messages": []}
    return sid


def add_message(sid, role, content, ts=None, touch=True, **extra):
    with LOCK:
        session = STORED[sid]
        ts = ts or time.time()
        row = {"id": sum(len(s["messages"]) for s in STORED.values()) + 1, "session_id": sid, "role": role,
               "content": content, "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": ts,
               "token_count": None, "finish_reason": None, "reasoning": None, "reasoning_content": None,
               "display_kind": None}
        row.update(extra)
        session["messages"].append(row)
        if touch:
            session["last_active"] = max(session["last_active"], ts)
        return row


def seed():
    add_profile("default", default=True, description="Your everyday assistant")
    chat = add_session("default", BOT_CHAT, hidden=True, started=NOW - 6 * DAY)
    add_message(chat, "user", "Hey, tell me about yourself!", NOW - 6 * DAY)
    add_message(chat, "assistant", "I'm **Hermes**, your always-on agent on this Mac. I keep notes, run errands on the web, "
                "and look after your files. Ask me anything, or `@mention` another Bot to bring them in.", NOW - 6 * DAY + 8)
    add_message(chat, "user", "What's the weather like for my run tomorrow?", NOW - 50 * 60)
    add_message(chat, "assistant", "", NOW - 50 * 60 + 2, finish_reason="tool_calls",
                tool_calls=[{"id": "call_w1", "type": "function", "function": {"name": "web_search", "arguments": json.dumps({"query": "Zagreb weather tomorrow 7am"})}}],
                reasoning="They run in the morning; check the forecast around 7am.")
    add_message(chat, "tool", "Sunny, 12°C at 07:00, light wind from the north.", NOW - 50 * 60 + 4, tool_call_id="call_w1", tool_name="web_search")
    add_message(chat, "assistant", "Looks great: **sunny and 12 °C** at 7:00 with a light northerly breeze. Long sleeves for the first kilometre.", NOW - 50 * 60 + 7)
    other = add_session("default", "Swift 6 migration plan", source="tui", started=NOW - 3 * HOUR)
    add_message(other, "user", "Help me plan the Swift 6 migration", NOW - 3 * HOUR)
    add_message(other, "assistant", "Start with complete checking in one module at a time.", NOW - 3 * HOUR + 12)

    add_profile("researcher", description="Research Buddy — digs through papers and the web for answers",
                meta={"title": "Research Buddy", "shape": "hexagon", "color": "hsl(150 68% 58%)", "imageKind": "shape",
                      "custom": True, "created": (NOW - 9 * DAY) * 1000},
                previous=["scholar"])
    chat = add_session("researcher", BOT_CHAT, hidden=True, started=NOW - 9 * DAY)
    add_message(chat, "user", "Hey, tell me about yourself!", NOW - 9 * DAY)
    add_message(chat, "assistant", "I'm **Research Buddy**. I read papers, compare sources, and send you tidy digests.", NOW - 9 * DAY + 6)
    digest_at = (NOW - 5 * 60) // 1800 * 1800  # the last half hour, so the schedule reads "at 20:00"
    add_message(chat, "user", "Message from 🤖 Hermes (@hermes): Can you find the latest on on-device LLM quantisation for Apple silicon?", digest_at - 14 * 60)
    add_message(chat, "assistant", "On it: **4-bit group-wise quantisation** is the sweet spot on M-series chips.", digest_at - 13 * 60)
    add_message(chat, "user", '[Cronjob "[bot:researcher] Daily digest" output — scheduled job, not the user. Review it, act on '
                "anything that needs action, and summarize for the chat.]\n\n3 new papers on on-device inference, 1 on agent memory.", digest_at + 3)
    add_message(chat, "assistant", "Your **daily digest** is in:\n\n- **Speculative decoding**, 2.1× faster\n"
                "- **4-bit KV caches**, no quality loss\n- **Episodic memory** beats RAG\n\nWant summaries?", digest_at + 40)
    # The digest's schedule matches its delivery above, so the routines sheet and the chat agree.
    ran = time.localtime(digest_at)
    CRON["researcher"]["job_digest"] = {
        "job_id": "job_digest", "name": "[bot:researcher] Daily digest", "prompt": "Summarise new arXiv papers on agents and on-device ML.",
        "schedule": f"{ran.tm_min} {ran.tm_hour} * * *", "repeat": "forever", "deliver": "bot-chat", "enabled": True, "state": "scheduled",
        "next_run_at": iso(digest_at + DAY), "last_run_at": iso(digest_at + 3), "last_status": "ok",
    }
    CRON["researcher"]["job_reading"] = {
        "job_id": "job_reading", "name": "[bot:researcher] Weekly reading list", "prompt": "Pick the five best papers of the week and explain why.",
        "schedule": "0 17 * * 5", "repeat": "forever", "deliver": "bot-chat", "enabled": True, "state": "scheduled",
        "next_run_at": "2026-10-16T17:00:00+02:00", "last_run_at": "2026-10-09T17:00:02+02:00", "last_status": "ok",
    }
    CRON["researcher"]["job_watch"] = {
        "job_id": "job_watch", "name": "[bot:researcher] Watch MLX releases", "prompt": "Check the MLX GitHub releases and tell me what changed.",
        "schedule": "every 6h", "repeat": "forever", "deliver": "bot-chat", "enabled": False, "state": "paused",
        "next_run_at": None, "last_run_at": "2026-10-10T12:00:00+02:00", "last_status": "ok", "paused_reason": None,
    }

    add_profile("writer", display_name="Ada", description="Ada — drafts posts, release notes and emails in your voice",
                meta={"shape": "cloud", "color": "hsl(330 68% 58%)", "imageKind": "shape", "custom": True, "created": (NOW - 2 * DAY) * 1000})
    chat = add_session("writer", BOT_CHAT, hidden=True, started=NOW - 2 * DAY)
    add_message(chat, "user", "Hey, tell me about yourself!", NOW - 2 * DAY)
    add_message(chat, "assistant", "I'm **Ada**. Hand me bullet points and I'll hand back something you'd be proud to post.", NOW - 2 * DAY + 5)
    CRON["writer"]["job_weekly"] = {
        "job_id": "job_weekly", "name": "[bot:writer] Weekly newsletter draft", "prompt": "Draft this week's newsletter from my notes.",
        "schedule": "0 9 * * 5", "repeat": "forever", "deliver": "bot-chat", "enabled": True, "state": "scheduled",
        "next_run_at": "2026-10-16T09:00:00+02:00", "last_run_at": None, "last_status": None,
    }

    add_profile("ops", description="Ops — keeps an eye on servers, backups and deploys",
                meta={"title": "Ops", "imageKind": "photo", "custom": True, "created": (NOW - 20 * DAY) * 1000},
                avatar=avatar_png())
    chat = add_session("ops", BOT_CHAT, hidden=True, started=NOW - 20 * DAY)
    add_message(chat, "user", "Hey, tell me about yourself!", NOW - 20 * DAY)
    add_message(chat, "assistant", "I'm **Ops**. I watch your servers and backups and tell you before things break.", NOW - 20 * DAY + 5)
    if CONFIG.get("seed_bot_chat"):
        # A local export of a real Bot Chat (rows as Hermes stores them), to reproduce layout bugs
        # with real turns. The file stays on the machine; nothing in it is part of the mock.
        with open(CONFIG["seed_bot_chat"]) as handle:
            for row in json.load(handle):
                extra = {k: row.get(k) for k in ("tool_calls", "tool_call_id", "tool_name", "reasoning",
                                                  "display_kind", "finish_reason") if row.get(k) is not None}
                add_message(chat, row["role"], row.get("content") or "", row.get("timestamp"), **extra)
    if CONFIG.get("long_bot_chats"):
        # Real Bot Chats run to hundreds of messages, with code and tables: long enough for lazy rows.
        start = NOW - 4 * DAY
        for turn in range(90):
            ts = start + turn * 3000
            add_message(chat, "user", f"Check #{turn + 1}: how are the disks and the backups doing on the NAS?", ts)
            add_message(chat, "assistant", f"Check #{turn + 1} is done.\n\n| Volume | Used | Free |\n|---|---|---|\n"
                        f"| tank | {60 + turn % 30}% | {40 - turn % 30}% |\n| backup | 41% | 59% |\n\n"
                        "```sh\nzpool status tank\n  state: ONLINE\n  scan: scrub repaired 0B with 0 errors\n```\n\n"
                        "- Snapshots rotated\n- Offsite copy verified\n- Nothing needs your attention", ts + 20)
    add_message(chat, "assistant", "Nightly backup finished: **212 GB**, 0 errors. Next run at 02:00.", NOW - 5 * HOUR)
    worker = add_session("ops", "kanban: rotate certificates", source="kanban", started=NOW - 10 * 60)
    STORED[worker]["last_active"] = time.time()

    add_profile("scout", description="", meta={"hidden": True, "created": (NOW - 40 * DAY) * 1000})


# ── Projections ──────────────────────────────────────────────────────────────

def preview_of(session):
    for row in reversed(session["messages"]):
        if row["role"] in ("user", "assistant") and isinstance(row["content"], str) and row["content"].strip():
            text = row["content"].strip().replace("\n", " ").replace("\r", " ")  # like Hermes' _shape_preview
            return text[:80] + ("..." if len(text) > 80 else "")
    return ""


def session_ref(session, *, canonical=False):
    ref = {"id": session["id"], "title": session["title"], "preview": preview_of(session),
           "started_at": session["started_at"], "last_active": session["last_active"],
           "message_count": len(session["messages"]), "live_message_count": len(session["messages"])}
    if canonical:
        ref.update({"resolved_id": session["id"], "root_title": session["title"]})
    else:
        ref["source"] = session["source"]
    return ref


def profile_row(profile, include_sessions=True):
    row = {k: profile[k] for k in ("name", "path", "is_default", "model", "provider", "description", "display_name",
                                   "skill_count", "previous_names")}
    if include_sessions:
        mine = [s for s in STORED.values() if s["profile"] == profile["name"]]
        human = sorted((s for s in mine if not s["hidden"] and s["source"] != "kanban"), key=lambda s: -s["last_active"])
        workers = sorted((s for s in mine if s["source"] == "kanban"), key=lambda s: -s["last_active"])
        canonical = next((s for s in mine if s["title"] == BOT_CHAT), None)
        row["last_session"] = session_ref(human[0]) if human else None
        row["worker_session"] = session_ref(workers[0]) if workers else None
        row["canonical_session"] = session_ref(canonical, canonical=True) if canonical else None
    row["ui_meta_revisions"] = {"hermes-bots": profile["revision"]}
    if profile["ui_meta"]:
        row["ui_meta"] = profile["ui_meta"]
    row["has_avatar"] = profile["avatar"] is not None
    return row


def cron_job(job):
    out = {"job_id": job["job_id"], "name": job["name"], "skill": None, "skills": [],
           "prompt_preview": job["prompt"][:100], "model": None, "provider": None, "pinned": False, "base_url": None,
           "schedule": job["schedule"], "repeat": job["repeat"], "deliver": job["deliver"],
           "next_run_at": job.get("next_run_at"), "last_run_at": job.get("last_run_at"),
           "last_status": job.get("last_status"), "last_delivery_error": None, "last_delivery_unverified": None,
           "last_fire_error": None, "last_error": job.get("last_error"), "enabled": job["enabled"],
           "state": job["state"], "paused_at": None, "paused_reason": job.get("paused_reason")}
    return out


# ── WebSocket plumbing (RFC 6455, server side) ───────────────────────────────

class Peer:
    def __init__(self, handler):
        self.handler = handler
        self.write_lock = threading.Lock()
        self.alive = True
        self.answers_requests = False

    def send(self, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        header = bytearray([0x81])
        if len(data) < 126:
            header.append(len(data))
        elif len(data) < 65536:
            header += bytes([126]) + struct.pack(">H", len(data))
        else:
            header += bytes([127]) + struct.pack(">Q", len(data))
        with self.write_lock:
            if not self.alive:
                return
            try:
                self.handler.wfile.write(bytes(header) + data)
                self.handler.wfile.flush()
            except OSError:
                self.alive = False

    def close(self, code, reason=""):
        payload = struct.pack(">H", code) + reason.encode()
        with self.write_lock:
            try:
                self.handler.wfile.write(bytes([0x88, len(payload)]) + payload)
                self.handler.wfile.flush()
            except OSError:
                pass
            self.alive = False

    def cut(self):
        """Drops the TCP connection without a close frame, like a network that went away."""
        self.alive = False
        try:
            self.handler.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def recv(self):
        """One complete message as text, or None when the peer closed."""
        message = b""
        while True:
            head = self.handler.rfile.read(2)
            if len(head) < 2:
                return None
            fin, opcode = head[0] & 0x80, head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.handler.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.handler.rfile.read(8))[0]
            mask = self.handler.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
            payload = bytearray(self.handler.rfile.read(length))
            for i in range(len(payload)):
                payload[i] ^= mask[i % 4]
            if opcode == 0x8:
                return None
            if opcode == 0x9:  # ping -> pong
                with self.write_lock:
                    self.handler.wfile.write(bytes([0x8A, len(payload)]) + bytes(payload))
                    self.handler.wfile.flush()
                continue
            if opcode == 0xA:
                continue
            message += bytes(payload)
            if fin:
                return message.decode("utf-8", "replace")


def ok(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def err(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def emit(sid, kind, payload):
    with LOCK:
        runtime = RUNTIME.get(sid)
        if runtime is None:
            return
        runtime["seq"] += 1
        event = {"type": kind, "session_id": sid, "seq": runtime["seq"], "payload": payload}
        runtime["ring"].append(event)
        del runtime["ring"][:-400]
        # Like the real gateway: session events go to the transports attached to the session.
        peers = [p for p in runtime["peers"] if p in CLIENTS]
    for peer in peers:
        peer.send({"jsonrpc": "2.0", "method": "event", "params": event})


def server_request(sid, method, params, timeout=300):
    rid = f"srq-{uuid.uuid4().hex[:12]}"
    entry = {"event": threading.Event(), "result": None, "sid": sid, "declined": set(), "frame": {
        "jsonrpc": "2.0", "id": rid, "method": method, "params": {"session_id": sid, **params}}}
    with LOCK:
        PENDING[rid] = entry
        peers = [p for p in RUNTIME[sid]["peers"] if p in CLIENTS and p.answers_requests]
        entry["asked"] = set(peers)
    for peer in peers:
        peer.send(entry["frame"])
    answered = entry["event"].wait(timeout)
    with LOCK:
        PENDING.pop(rid, None)
    if not answered:
        emit(sid, "request.cancel", {"id": rid, "method": method, "reason": "timeout"})
    return entry["result"]


def open_requests(sid):
    with LOCK:
        return [{"id": rid, "method": e["frame"]["method"], "params": e["frame"]["params"]}
                for rid, e in PENDING.items() if e["sid"] == sid]


# ── Scripted turns ───────────────────────────────────────────────────────────

MENTION_RE = re.compile(r'@[\w-]+ = agent profile "([^"]+)"')


def stream(sid, text, chunk=7, delay=0.025):
    for i in range(0, len(text), chunk):
        if RUNTIME[sid]["interrupt"]:
            return False
        emit(sid, "message.delta", {"text": text[i:i + chunk]})
        time.sleep(delay)
    return True


def tool(sid, stored, name, args, result, seconds, context):
    check_redirect(sid)
    call = f"call_{uuid.uuid4().hex[:8]}"
    add_message(stored, "assistant", "", tool_calls=[{"id": call, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}],
                finish_reason="tool_calls")
    emit(sid, "tool.start", {"tool_id": call, "name": name, "context": context, "args": args})
    RUNTIME[sid]["tool_running"] = True
    waited = 0.0
    while waited < seconds:
        if RUNTIME[sid]["interrupt"]:
            break
        time.sleep(0.1)
        waited += 0.1
    RUNTIME[sid]["tool_running"] = False
    add_message(stored, "tool", result, tool_call_id=call, tool_name=name)
    emit(sid, "tool.complete", {"tool_id": call, "name": name, "args": args, "duration_s": round(waited, 2),
                                "result": result, "summary": f"Completed in {waited:.1f}s"})
    deliver_steers(sid, lambda row: add_message(stored, "user", row["content"], display_kind="steer",
                                                display_content=row["display_content"]))


STEER_OPEN = ("[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; "
              "not tool output and not a new delivery when replayed from conversation history]")
STEER_CLOSE = "[/OUT-OF-BAND USER MESSAGE]"


BUSY = {"mode": "interrupt"}  # display.busy_input_mode (Hermes' default); config.get/set "busy"


class Redirected(Exception):
    """A redirect landed: the turn drops the rest of its plan and answers the correction."""

    def __init__(self, text):
        super().__init__(text)
        self.text = text


def start_turn(sid, text, runner):
    """Marks the runtime busy and runs one turn (a prompt, or a message drained from the queue)."""
    with LOCK:
        runtime = RUNTIME[sid]
        runtime["running"] = True
        runtime["interrupt"] = False
        runtime["turn_started"] = time.time()
    threading.Thread(target=guarded, args=(sid, text, runner), daemon=True).start()


def guarded(sid, text, runner):
    """Runs a turn; a redirect ends the planned work and answers the correction instead (Hermes keeps
    the work done, cancels the model request in flight, and appends the correction as a user row)."""
    try:
        runner(sid, text)
    except Redirected as redirect:
        runtime = RUNTIME[sid]
        stored = runtime.get("stored")
        # The cancelled model request leaves a hidden placeholder, then the correction as a user row.
        store_row(sid, stored, "assistant", "", display_kind="hidden")
        store_user(sid, stored, redirect.text)
        emit(sid, "status.update", {"kind": "status", "text": "Changing course…"})
        time.sleep(0.4)
        answer = f"Changed course. I stopped and did this instead: **{redirect.text.rstrip('.')}**."
        stream(sid, answer)
        finish_any(sid, stored, answer)


def store_user(sid, stored, text):
    store_row(sid, stored, "user", text)


def store_row(sid, stored, role, text, **extra):
    if RUNTIME[sid].get("kind") == "chat":
        CHATS_HOOKS["add_message"](stored, role, text, **extra)
    else:
        add_message(stored, role, text, **extra)


def finish_any(sid, stored, text):
    if RUNTIME[sid].get("kind") == "chat":
        CHATS_HOOKS["finish"](sid, stored, text)
    else:
        finish(sid, stored, text)


CHATS_HOOKS = {}  # chats.py fills these for normal (non-Bot) chats


def check_redirect(sid):
    """Between steps: a pending redirect takes over (Hermes never kills a running tool for it)."""
    with LOCK:
        text = RUNTIME[sid].pop("redirect", None)
    if text:
        raise Redirected(text)


def busy_submit(sid, text, queued):
    """Hermes' _handle_busy_submit: a client queue drain (`queued: true`) and anything with images is held
    for the next turn; plain text follows display.busy_input_mode (steer, interrupt → redirect, queue)."""
    with LOCK:
        runtime = RUNTIME[sid]
        media = runtime.pop("attached_images", 0)
        mode = "queue" if queued or media else BUSY["mode"]
        if mode == "steer":
            runtime.setdefault("steers", []).append(text)
            return {"status": "steered"}
        if mode == "interrupt" and time.time() - runtime.get("turn_started", 0) >= 0.5:
            redirect_or_steer(runtime, text)
            return {"status": "redirected"}
        runtime.setdefault("queue", []).append({"text": text, "media": media})
        return {"status": "queued"}


def after_turn(sid, runner):
    """Hermes' post-turn chain: a steer the turn never read is requeued first, then one queued prompt runs."""
    with LOCK:
        runtime = RUNTIME[sid]
        leftover = runtime.pop("steers", [])
        runtime.pop("redirect", None)
        if runtime.get("interrupt"):
            leftover = []  # an interrupt drops unread steers
        if leftover:
            runtime.setdefault("queue", []).insert(0, {"text": "\n".join(leftover), "media": 0})
        if not runtime.get("queue") or runtime["running"]:
            return
        nxt = runtime["queue"].pop(0)
        runtime["running"] = True
    threading.Timer(0.5, start_turn, args=(sid, nxt["text"], runner)).start()


def method_session_redirect(params):
    sid, runtime = runtime_for(params)
    text = (params.get("text") or "").strip()
    with LOCK:
        if not runtime["running"]:
            return {"status": "rejected", "text": text}
        if time.time() - runtime.get("turn_started", 0) < 0.5:
            # The agent is still being built: Hermes queues it for the next turn.
            runtime.setdefault("queue", []).append({"text": text, "media": 0})
            return {"status": "queued", "text": text}
        redirect_or_steer(runtime, text)
    return {"status": "redirected", "text": text}


def redirect_or_steer(runtime, text):
    """Hermes never kills a running tool for a redirect: during one it goes in with the result, like a steer."""
    if runtime.get("tool_running"):
        runtime.setdefault("steers", []).append(text)
    else:
        runtime["redirect"] = text


def method_session_steer(params):
    sid, runtime = runtime_for(params)
    text = (params.get("text") or "").strip()
    with LOCK:
        if not runtime["running"]:
            return {"status": "rejected", "text": text}
        runtime.setdefault("steers", []).append(text)
    return {"status": "queued", "text": text}


def method_config_get(params):
    if params.get("key") == "busy":
        return {"value": BUSY["mode"]}
    return {"value": None}


def deliver_steers(sid, store):
    """Steer Now, the way Hermes delivers it: after the newest tool result, as its own `user` row typed
    `steer`, wrapped in the out-of-band marker; the REST projection adds `display_content` (the words)."""
    with LOCK:
        steers = RUNTIME[sid].pop("steers", []) if sid in RUNTIME else []
    for text in steers:
        store({"content": f"{STEER_OPEN}\n{text}\n{STEER_CLOSE}", "display_content": text})


def bot_title(profile):
    meta = PROFILES[profile]["ui_meta"].get("hermes-bots", {})
    if meta.get("title"):
        return meta["title"]
    if PROFILES[profile]["display_name"]:
        return PROFILES[profile]["display_name"]
    return "Hermes" if PROFILES[profile]["is_default"] else profile.replace("-", " ").title()


def ensure_row(sid):
    """Bot Chats are lazy: the stored row appears on the first prompt."""
    runtime = RUNTIME[sid]
    stored = runtime["stored"]
    if stored not in STORED:
        add_session(runtime["profile"], runtime["pending_title"] or "Untitled", hidden=runtime["pending_hidden"],
                    source="desktop", sid=stored)
    return stored


def finish(sid, stored, text, status="complete", error=None):
    if text:
        add_message(stored, "assistant", text, finish_reason="stop")
    payload = {"text": text, "status": status, "usage": {"input_tokens": 1830, "output_tokens": 212, "total_tokens": 2042}}
    if error:
        payload["error"] = error
    emit(sid, "message.complete", payload)
    with LOCK:
        RUNTIME[sid]["running"] = False
    emit(sid, "session.info", {"running": False, "model": "claude-sonnet-4-6"})
    after_turn(sid, run_turn)


COMPRESSION_WARNING = (
    "⚠ Compression model gpt-6-sol (openai-codex) context is 272,000 tokens, but the main model "
    "claude-opus-5-5[1m] (claude-subscription-directsdk-experimental)'s compression threshold was 500,000 tokens. "
    "Auto-lowered this session's threshold to 272,000 tokens so compression can run.\n"
    "  To make this permanent, edit config.yaml — either:\n  1. Use a larger compression model:\n"
    "       auxiliary:\n         compression:\n           model: <model-with-500,000+-context>\n"
    "  2. Lower the compression threshold:\n       compression:\n         threshold: 0.27"
)


AUX_UNAVAILABLE_WARNING = (
    "⚠ Configured auxiliary compression provider 'openai-codex' is unavailable, so older messages in long chats "
    "will be cut without a summary. Sign in to that provider again, or change auxiliary.compression in your config."
)


def lifecycle(sid, text):
    """A lifecycle status the way Hermes' gateway sends it (tui_gateway/server.py `_status_update`): text that
    mentions compaction or compression is re-tagged `compacting`, warnings included."""
    lowered = text.lower()
    compacting = ("compact" in lowered or "compress" in lowered or "context reduced to" in lowered) \
        and "compaction complete" not in lowered and "compression is currently blocked" not in lowered
    emit(sid, "status.update", {"kind": "compacting" if compacting else "lifecycle", "text": text})


def mock_warnings(sid, visible):
    """Hermes' compression diagnostics, sent as the agent starts: "compression" (the helper model is
    unavailable) and "threshold" (the helper's window is smaller than the threshold)."""
    lowered = visible.lower()
    if "compression" in lowered:
        lifecycle(sid, AUX_UNAVAILABLE_WARNING)
    if "threshold" in lowered:
        lifecycle(sid, COMPRESSION_WARNING)


def run_turn(sid, text):
    runtime = RUNTIME[sid]
    stored = ensure_row(sid)
    profile = runtime["profile"]
    me = bot_title(profile)
    add_message(stored, "user", text)
    emit(sid, "session.info", {"running": True})
    emit(sid, "message.start", {})
    time.sleep(0.3)
    lower = text.lower()
    visible = text.split("\n\n[@mentions resolved", 1)[0]
    mock_warnings(sid, visible)

    if lower.startswith("hey, tell me about yourself"):
        intro = (f"Hi! I'm **{me}**. This is our Bot Chat, one continuous conversation that never resets. "
                 f"I remember what we talk about, I can run **routines** on a schedule, and you can `@mention` "
                 f"other Bots and I'll message them for you.")
        stream(sid, intro)
        return finish(sid, stored, intro)

    if "fail" in visible.lower():
        stream(sid, "Let me try that")
        time.sleep(0.4)
        return finish(sid, stored, "", status="error", error="The model provider returned 529: overloaded. Try again in a moment.")

    cleanup = "disk" in visible.lower()
    thoughts = (["The disk is nearly full. ", "I'll see what's using the space ", "before deleting anything."] if cleanup
                else ["The user wants ", "a clear answer. ", "I'll check a source ", "before replying."])
    for piece in thoughts:
        emit(sid, "reasoning.delta", {"text": piece})
        time.sleep(0.08)

    if cleanup or "approve" in visible.lower():
        if cleanup:
            command, description, size = "docker system prune -af", "Remove unused Docker images and build cache (14 GB)", "14 GB"
            tool(sid, stored, "terminal", {"command": "docker system df"},
                 json.dumps({"output": "TYPE         SIZE     RECLAIMABLE\nImages       18.2GB   14.1GB (77%)\nBuild Cache  2.3GB    2.3GB", "exit_code": 0}),
                 1.2, "docker system df")
        elif "script" in visible.lower():
            # A long heredoc, like Hermes' real "script execution via heredoc" approvals.
            command = ("python3 - <<'PY'\nimport json,shutil,os\nfrom pathlib import Path\n"
                       "h=Path.home()/'.hermes';p=h/'profiles/fitness';d=json.loads((h/'honcho.json').read_text())\n"
                       "src=next(iter(d['hosts'].values()));x=dict(src);x['workspace']='hermes_fitness'\n"
                       "print('Honcho host: hermes_fitness / aiPeer fitness')\n"
                       "s=h/'skills';dest=h/'profiles/fitness/skills';restored=[];missing=[]\n"
                       "for name in ['argus-cli-usage','reading-readiness','logging-meals','tracking-metrics']:\n"
                       " hits=[q for q in dest.rglob(name) if q.is_dir()]\n if not hits:\n"
                       "  cand=[q for q in s.rglob(name) if q.is_dir()]\n  q=dest/name\n"
                       "  if q.is_symlink() and not q.exists():q.unlink()\n"
                       "  if cand and not q.exists():shutil.copytree(cand[0],q);restored.append(name)\n"
                       "  else:missing.append(name)\n"
                       "print('restored',restored,'missing',missing)\n"
                       "w=[q for q in dest.rglob('SKILL.md') if 'workspace' in q.read_text()]\nPY\n"
                       "hermes -p fitness config set command_allowlist '[]'")
            description, size = "script execution via heredoc", "the script"
        else:
            command, description, size = "rm -rf ~/Library/Caches/com.example.build", "Delete the build cache (1.2 GB)", "1.2 GB"
        result = server_request(sid, "approval", {
            "request_id": f"ap_{uuid.uuid4().hex[:6]}", "command": command,
            "description": description, "choices": ["once", "session", "always", "deny"]})
        choice = (result or {}).get("choice", "deny")
        if choice == "deny" or result is None:
            answer = "Okay, I **didn't delete** anything. It's all still there if you change your mind."
            stream(sid, answer)
            return finish(sid, stored, answer)
        tool(sid, stored, "terminal", {"command": command}, json.dumps({"output": "", "exit_code": 0}), 0.8, command)
        answer = f"Done. Freed **{size}** (approved: `{choice}`)."
        stream(sid, answer)
        return finish(sid, stored, answer)

    mentioned = MENTION_RE.findall(text)
    if mentioned:
        emit(sid, "message.interim", {"text": "I'll loop them in.", "already_streamed": False})
        for target in mentioned:
            if target not in PROFILES:
                continue
            ask = re.sub(r"\s*@[\w-]+\s*", " ", visible).strip(" ,:")
            note = f"{ask[:1].upper()}{ask[1:]}"
            tool(sid, stored, "message_agent", {"target": "hermes" if PROFILES[target]["is_default"] else target, "message": note},
                 json.dumps({"delivered": True}), 0.6, f"→ {bot_title(target)}")
            deliver_dm(profile, target, note)
        names = ", ".join(f"**{bot_title(t)}**" for t in mentioned if t in PROFILES)
        answer = f"I've messaged {names}. Their reply will show up in their Bot Chat."
        stream(sid, answer)
        return finish(sid, stored, answer)

    if "busy" in visible.lower():
        # A long agentic turn like real ones: dozens of tool rounds with narration in between.
        for step in range(1, 31):
            if runtime["interrupt"]:
                return finish(sid, stored, "", status="interrupted")
            if step % 5 == 1:
                emit(sid, "message.interim", {"text": f"Round {step // 5 + 1}: checking the next batch of hosts.", "already_streamed": False})
            tool(sid, stored, "terminal", {"command": f"ssh host{step} df -h /"},
                 json.dumps({"output": f"/dev/disk{step}  500G  {200 + step}G  {300 - step}G  {40 + step}%  /", "exit_code": 0}),
                 0.15, f"ssh host{step} df -h /")
        answer = "All **30 hosts** checked. Disk use is between 41% and 70%; nothing needs attention."
        stream(sid, answer)
        return finish(sid, stored, answer)

    if "slow" in visible.lower():
        for step in range(1, 7):
            if runtime["interrupt"]:
                break
            tool(sid, stored, "web_search", {"query": f"source {step}"}, f"Result {step}: three relevant pages.", 1.4, f"source {step}")
            emit(sid, "status.update", {"kind": "status", "text": f"Reading source {step} of 6…"})
        if runtime["interrupt"]:
            return finish(sid, stored, "", status="interrupted")
        answer = "After six sources, the consensus is clear: **ship it on Friday**."
        stream(sid, answer)
        return finish(sid, stored, answer)

    tool(sid, stored, "web_search", {"query": visible[:60]}, "1. A helpful page\n2. Another helpful page", 1.1, visible[:60])
    answer = (f"Here's what I found, from {me}:\n\n"
              "- **Short answer:** yes, it works the way you expect\n"
              "- It's quickest from the command line: `hermes bots`\n\n"
              "```swift\nlet bot = try await roster.open(\"researcher\")\n```\n\n"
              "Want me to set up a routine for this?")
    if stream(sid, answer):
        return finish(sid, stored, answer)
    return finish(sid, stored, "", status="interrupted")


def deliver_dm(sender, target, text):
    with LOCK:
        chat = next((s for s in STORED.values() if s["profile"] == target and s["title"] == BOT_CHAT), None)
        if chat is None:
            chat = STORED[add_session(target, BOT_CHAT, hidden=True)]
        handle = "hermes" if PROFILES[sender]["is_default"] else sender
        add_message(chat["id"], "user", f"Message from 🤖 {bot_title(sender)} ({'@' + handle}): {text}")

    def reply():
        time.sleep(4)
        if "background" not in text.lower():
            add_message(chat["id"], "assistant", f"Got it, {bot_title(sender)}. I'll take a look and report back here.")
            return
        # Hermes delivers a Bot's message through a one-shot `hermes chat -c 'Bot Chat'` when no app holds
        # the chat. It lingers for its background process and answers the completion in-process, and that
        # follow-up turn never touches `last_activity_at`: the roster's preview and count move, its time doesn't.
        add_message(chat["id"], "assistant", f"Started the check in the background, {bot_title(sender)}. "
                    "I'll report here when it finishes.")
        time.sleep(6)
        add_message(chat["id"], "user", "[IMPORTANT: Background process proc_mock01 completed normally (exit code 0).\n"
                    "Command: hermes -p ops chat -c 'Bot Chat' -Q\nOutput\nok]", touch=False)
        add_message(chat["id"], "assistant", f"{bot_title(sender)} confirmed the change in its chat. "
                    "The backup check passed and nothing else needs doing.", touch=False)
    threading.Thread(target=reply, daemon=True).start()


def deliver_routine(profile, title, output, reply):
    """Routines deliver into a Bot Chat as a full turn: the job's output, then the Bot's reply."""
    with LOCK:
        chat = next((s for s in STORED.values() if s["profile"] == profile and s["title"] == BOT_CHAT), None)
        if chat is None:
            return
        add_message(chat["id"], "user", f'[Cronjob "[bot:{profile}] {title}" output — scheduled job, not the user. '
                    f"Review it, act on anything that needs action, and summarize for the chat.]\n\n{output}")
        add_message(chat["id"], "assistant", reply, ts=time.time() + 2)


def ambient():
    """Background life: the ops worker heartbeats and routines post into Bot Chats."""
    tick = 0
    while True:
        time.sleep(15)
        tick += 1
        with LOCK:
            for s in STORED.values():
                if s["source"] == "kanban":
                    s["last_active"] = time.time()
        if tick % 8 == 0:
            deliver_routine("researcher", "Daily digest", f"Digest #{tick // 8}: two new papers on speculative decoding.",
                            "📰 Two new papers on **speculative decoding** look worth a read. Want summaries?")


# ── Methods ──────────────────────────────────────────────────────────────────

def method_profiles_list(params):
    include = params.get("include_sessions", True) is not False
    with LOCK:
        rows = [profile_row(p, include) for p in PROFILES.values()]
    return {"profiles": rows, "bot_mode_protocol": True, "install_id": "mock-install-0001"}


def method_profiles_get_asset(params):
    profile = PROFILES.get(params.get("name") or "")
    if profile is None:
        raise RPCError(4064, "profile not found")
    if not profile["avatar"]:
        return {"found": False}
    return {"found": True, "mime": "image/png", "size": len(profile["avatar"]), "data": profile["avatar"]}


def method_profiles_set_asset(params):
    profile = PROFILES.get(params.get("name") or "")
    if profile is None:
        raise RPCError(4064, "profile not found")
    if params.get("clear"):
        profile["avatar"] = None
        return {"ok": True, "asset": "avatar", "removed": True}
    data = params.get("data") or ""
    if not data.startswith("data:image/"):
        raise RPCError(4070, "unsupported image format")
    profile["avatar"] = data
    return {"ok": True, "asset": "avatar", "size": len(data)}


def method_profiles_configure(params):
    with LOCK:
        profile = PROFILES.get(params.get("name") or "")
        if profile is None:
            raise RPCError(4064, "profile not found")
        applied = {}
        if "ui_meta" in params:
            expected = (params.get("ui_meta_expected_revisions") or {}).get("hermes-bots")
            if expected is not None and expected != profile["revision"]:
                return {"ok": False, "applied": {"ui_meta": False,
                        "ui_meta_conflicts": {"hermes-bots": {"expected": expected, "actual": profile["revision"]}},
                        "ui_meta_revisions": {"hermes-bots": profile["revision"]}}}
            value = (params["ui_meta"] or {}).get("hermes-bots")
            if value is None:
                profile["ui_meta"].pop("hermes-bots", None)
            else:
                profile["ui_meta"]["hermes-bots"] = value
            profile["revision"] += 1
            applied.update({"ui_meta": True, "ui_meta_revisions": {"hermes-bots": profile["revision"]}})
        if "description" in params:
            profile["description"] = params["description"] or ""
            applied["description"] = True
        if "soul" in params:
            applied["soul"] = True
        return {"ok": True, "applied": applied}


def method_profiles_create(params):
    name = (params.get("name") or "").strip()
    if not name:
        raise RPCError(4061, "name required")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", name) or name in PROFILES:
        raise RPCError(4062, f"profile '{name}' already exists or is invalid")
    with LOCK:
        add_profile(name, description=params.get("description") or "")
    return {"ok": True, "name": name, "path": PROFILES[name]["path"], "soul_written": bool(params.get("soul")),
            "model_set": False, "mirrored": {"env": True, "auth": "shared", "model_inherited": True, "voice": False}}


def new_runtime(stored, profile, *, title=None, hidden=False):
    sid = uuid.uuid4().hex[:8]
    RUNTIME[sid] = {"stored": stored, "profile": profile, "running": False, "interrupt": False, "seq": 0, "ring": [],
                    "pending_title": title, "pending_hidden": hidden, "peers": set()}
    return sid


def runtime_for(params):
    sid = params.get("session_id") or ""
    if sid not in RUNTIME:
        raise RPCError(4001, "session not found")
    return sid, RUNTIME[sid]


def method_session_create(params):
    profile = (params.get("profile") or "default").strip() or "default"
    if profile not in PROFILES:
        raise RPCError(4064, f"unknown profile: {profile}")
    with LOCK:
        stored = new_id()
        sid = new_runtime(stored, profile, title=params.get("title") or None, hidden=bool(params.get("hidden")))
    return {"session_id": sid, "stored_session_id": stored, "message_count": 0, "messages": [],
            "info": {"model": PROFILES[profile]["model"], "running": False}}


def method_session_title(params):
    sid, runtime = runtime_for(params)
    title = (params.get("title") or "").strip()
    if not title:
        raise RPCError(4021, "title required")
    with LOCK:
        runtime["pending_title"] = title
        if runtime["stored"] in STORED:
            STORED[runtime["stored"]]["title"] = title
    emit(sid, "session.title", {"title": title})
    return {"title": title, "session_id": sid}


def method_session_list(params):
    profile = (params.get("profile") or "default").strip() or "default"
    with LOCK:
        mine = [s for s in STORED.values() if s["profile"] == profile and s["source"] != "kanban"]
        if params.get("title"):
            match = next((s for s in mine if s["title"] == params["title"]), None)
            rows = [match] if match else []
            return {"sessions": [dict(session_ref(s, canonical=True), source=s["source"]) for s in rows]}
        if not params.get("include_hidden"):
            mine = [s for s in mine if not s["hidden"]]
        mine.sort(key=lambda s: -s["last_active"])
        limit = int(params.get("limit") or 200)
        return {"sessions": [session_ref(s) for s in mine[:limit]]}


def method_session_resume(params):
    stored = params.get("session_id") or ""
    profile = (params.get("profile") or "default").strip() or "default"
    with LOCK:
        session = STORED.get(stored)
        if session is None or session["profile"] != profile:
            raise RPCError(4007, "session not found")
        sid = next((k for k, r in RUNTIME.items() if r["stored"] == stored), None) or new_runtime(stored, profile)
        runtime = RUNTIME[sid]
        if DROP["settle"] > 0 and runtime["running"]:
            DROP["settle"] -= 1
            raise RPCError(4009, "session disconnect interrupt settling")
        omit = bool(params.get("omit_messages"))
        return {"session_id": sid, "resumed": stored, "message_count": len(session["messages"]),
                "messages": [] if omit else session["messages"], "messages_omitted": omit,
                "info": {"model": PROFILES[profile]["model"], "running": runtime["running"]},
                "inflight": None, "running": runtime["running"], "session_key": stored,
                "started_at": session["started_at"], "status": "streaming" if runtime["running"] else "idle",
                "open_requests": open_requests(sid),
                "queued": {"user": runtime["queue"][0]["text"]} if runtime.get("queue") else None}


def method_prompt_submit(params):
    sid, runtime = runtime_for(params)
    text = params.get("text") or ""
    with LOCK:
        busy = runtime["running"]
    if busy:
        return busy_submit(sid, text, bool(params.get("queued")))
    start_turn(sid, text, run_turn)
    return {"status": "streaming"}


def method_session_interrupt(params):
    sid, runtime = runtime_for(params)
    with LOCK:
        runtime["interrupt"] = True
        cancelled = [rid for rid, e in PENDING.items() if e["sid"] == sid]
    for rid in cancelled:
        entry = PENDING.get(rid)
        if entry:
            entry["event"].set()
        emit(sid, "request.cancel", {"id": rid, "method": "approval", "reason": "interrupted"})
    return {"status": "interrupted"}


def method_session_compress(params):
    sid, runtime = runtime_for(params)
    emit(sid, "status.update", {"kind": "compressing", "text": "Compacting context…"})
    time.sleep(1.2)
    count = len(STORED.get(runtime["stored"], {"messages": []})["messages"])
    after = max(2, count // 3)
    emit(sid, "status.update", {"kind": "ready", "text": ""})
    return {"status": "compressed", "removed": count - after, "before_messages": count, "after_messages": after,
            "before_tokens": 18240, "after_tokens": 4410,
            "summary": {"noop": False, "aborted": False, "refused_would_grow": False, "fallback_used": False,
                        "headline": f"Compressed: {count} → {after} messages",
                        "token_line": "Approx request size: ~18,240 → ~4,410 tokens", "note": None}}


def method_events_since(params):
    sid, runtime = runtime_for(params)
    last = int(params.get("last_seen") or 0)
    with LOCK:
        frames = [e for e in runtime["ring"] if e["seq"] > last]
        truncated = bool(runtime["ring"]) and last < runtime["ring"][0]["seq"] - 1
        return {"events": frames, "latest_seq": runtime["seq"], "truncated": truncated, "count": len(frames),
                "epoch": EPOCH, "open_requests": open_requests(sid)}


def method_image_attach_bytes(params):
    sid, runtime = runtime_for(params)
    with LOCK:
        runtime["attached_images"] = runtime.get("attached_images", 0) + 1
    return {"attached": True, "name": params.get("filename") or "image.png"}


def method_cron_manage(params):
    profile = (params.get("profile") or "default").strip() or "default"
    jobs = CRON.setdefault(profile, {})
    action = params.get("action", "list")
    with LOCK:
        if action == "list":
            rows = [cron_job(j) for j in jobs.values() if j["enabled"] or params.get("include_disabled")]
            return {"success": True, "count": len(rows), "jobs": rows, "scoped": profile}
        if action == "add":
            schedule = (params.get("schedule") or "").strip()
            if not schedule:
                return {"success": False, "error": "schedule is required"}
            jid = uuid.uuid4().hex[:12]
            once = schedule.startswith("in ")
            jobs[jid] = {"job_id": jid, "name": params.get("name") or "Untitled", "prompt": params.get("prompt") or "",
                         "schedule": schedule if not once else f"once {schedule}", "repeat": "once" if once else "forever",
                         "deliver": params.get("deliver") or "local", "enabled": True, "state": "scheduled",
                         "next_run_at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() + 1800)),
                         "last_run_at": None, "last_status": None}
            job = cron_job(jobs[jid])
            return {"success": True, "job_id": jid, "name": job["name"], "schedule": job["schedule"],
                    "repeat": job["repeat"], "deliver": job["deliver"], "next_run_at": job["next_run_at"], "job": job,
                    "message": f"Cron job '{job['name']}' created."}
        job = jobs.get(params.get("name") or "")
        if job is None:
            return {"success": False, "error": f"Job with ID or name '{params.get('name')}' not found."}
        if action == "remove":
            del jobs[job["job_id"]]
            return {"success": True, "message": f"Cron job '{job['name']}' removed.",
                    "removed_job": {"id": job["job_id"], "name": job["name"], "schedule": job["schedule"]}}
        if action in ("pause", "resume"):
            job["enabled"] = action == "resume"
            job["state"] = "scheduled" if job["enabled"] else "paused"
            return {"success": True, "job": cron_job(job)}
    raise RPCError(4016, f"unknown cron action: {action}")


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


METHODS = {
    "profiles.list": method_profiles_list,
    "profiles.get_asset": method_profiles_get_asset,
    "profiles.set_asset": method_profiles_set_asset,
    "profiles.configure": method_profiles_configure,
    "profiles.create": method_profiles_create,
    "session.create": method_session_create,
    "session.title": method_session_title,
    "session.list": method_session_list,
    "session.resume": method_session_resume,
    "session.interrupt": method_session_interrupt,
    "session.compress": method_session_compress,
    "session.events.since": method_events_since,
    "prompt.submit": method_prompt_submit,
    "image.attach_bytes": method_image_attach_bytes,
    "session.redirect": method_session_redirect,
    "session.steer": method_session_steer,
    "config.get": method_config_get,
    "cron.manage": method_cron_manage,
    "gateway.ping": lambda params: {"pong": True},
    "setup.runtime_check": lambda params: {"ok": True},
}

EPOCH = uuid.uuid4().hex[:8]


# ── HTTP ─────────────────────────────────────────────────────────────────────

INDEX = """<!doctype html><html><head><meta charset="utf-8"><title>Hermes</title>
<script>window.__HERMES_SESSION_TOKEN__={token};window.__HERMES_DASHBOARD_EMBEDDED_CHAT__=true;</script>
</head><body><div id="root"></div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "HermesMock/0.21.6"

    def log_message(self, fmt, *args):
        if "/api/status" not in (args[0] if args else ""):
            print("[backend]", fmt % args, flush=True)

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        if GATEWAY_PAGING:
            GATEWAY_PAGING[1](len(data))
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or []):
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def cookies(self):
        jar = {}
        for part in (self.headers.get("Cookie") or "").split(";"):
            if "=" in part:
                key, value = part.strip().split("=", 1)
                jar[key] = value
        return jar

    def authorized(self, query=None):
        if CONFIG["password"]:
            if self.cookies().get("hermes_session_at") in SESSIONS_AUTH:
                return True
            ticket = (query or {}).get("ticket", [None])[0]
            with LOCK:
                expiry = TICKETS.pop(ticket, None) if ticket else None
            return expiry is not None and expiry > time.time()
        token = self.headers.get("X-Hermes-Session-Token") or (query or {}).get("token", [None])[0]
        return token == CONFIG["token"]

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/api/ws":
            return self.websocket(query)
        if url.path == "/api/status":
            return self.send_json(200, {"version": "0.21.6", "auth_required": bool(CONFIG["password"]),
                                        "auth_providers": ["basic"] if CONFIG["password"] else [],
                                        "install_id": "mock-install-0001", "gateway_running": True})
        if url.path == "/api/health":
            return self.send_json(200, {"ok": True})
        if url.path == "/":
            html = INDEX.format(token=json.dumps("" if CONFIG["password"] else CONFIG["token"])).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            return self.wfile.write(html)
        if not self.authorized():
            return self.send_json(401, {"detail": "Unauthorized"})
        route = HTTP_ROUTES.get(("GET", url.path))
        if route:
            return self.send_json(*route(query, {}))
        match = re.fullmatch(r"/api/sessions/([^/]+)/messages", url.path)
        if match:
            sid = unquote(match.group(1))
            profile = (query.get("profile", ["default"])[0] or "default")
            with LOCK:
                session = STORED.get(sid)
                if session is None or session["profile"] != profile:
                    return self.send_json(404, {"detail": "Session not found"})
                rows, pagination = GATEWAY_PAGING[0](list(session["messages"]), query) if GATEWAY_PAGING else (session["messages"][-int(query.get("limit", ["500"])[0]):], {})
            return self.send_json(200, {"session_id": sid, "profile": profile, "messages": rows, "pagination": pagination})
        self.send_json(404, {"detail": "Not Found"})

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        if url.path == "/auth/password-login":
            if not CONFIG["password"]:
                return self.send_json(404, {"detail": "Not Found"})
            if body.get("username") != CONFIG["username"] or body.get("password") != CONFIG["password"]:
                return self.send_json(401, {"detail": "Invalid username or password"})
            access, refresh = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
            SESSIONS_AUTH[access] = body["username"]
            return self.send_json(200, {"ok": True, "next": "/"}, headers=[
                ("Set-Cookie", f"hermes_session_at={access}; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600"),
                ("Set-Cookie", f"hermes_session_rt={refresh}; Path=/auth; HttpOnly; SameSite=Lax; Max-Age=2592000"),
            ])
        if not self.authorized():
            return self.send_json(401, {"detail": "Unauthorized"})
        route = HTTP_ROUTES.get(("POST", url.path))
        if route:
            return self.send_json(*route(parse_qs(url.query), body))
        if url.path == "/api/auth/ws-ticket":
            ticket = secrets.token_urlsafe(18)
            with LOCK:
                TICKETS[ticket] = time.time() + 30
            return self.send_json(200, {"ticket": ticket, "ttl_seconds": 30})
        if url.path == "/api/mock/drop-sockets":
            # Mock-only: the network blips. Every socket drops mid-whatever (turns keep running), the next
            # `settle` resumes of a running chat answer 4009 like Hermes' client-gone settling window, and
            # new sockets are cut for `outage` seconds.
            with LOCK:
                peers = list(CLIENTS)
                DROP["settle"] = int(body.get("settle") or 0)
                DROP["refuse_until"] = time.time() + float(body.get("outage") or 0)
            for peer in peers:
                peer.cut()
            return self.send_json(200, {"ok": True, "dropped": len(peers)})
        if url.path == "/api/mock/message-agent":
            # Mock-only: another Bot's `message_agent`, delivered off-socket like Hermes' one-shot CLI.
            if body.get("from") not in PROFILES or body.get("to") not in PROFILES:
                return self.send_json(404, {"detail": "Unknown profile"})
            deliver_dm(body["from"], body["to"], body.get("text") or "")
            return self.send_json(200, {"ok": True})
        match = re.fullmatch(r"/api/cron/jobs/([^/]+)/trigger", url.path)
        if match:
            profile = parse_qs(url.query).get("profile", ["default"])[0]
            job = CRON.get(profile, {}).get(match.group(1))
            if job is None:
                return self.send_json(404, {"detail": "Job not found"})
            job["last_run_at"] = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
            job["last_status"] = "ok"
            if job["deliver"].startswith("bot-chat"):
                deliver_routine(profile, job["name"].split("] ", 1)[-1], job["prompt"], "Done. Everything looks good ✅")
            return self.send_json(200, {"ok": True, "job_id": job["job_id"]})
        self.send_json(404, {"detail": "Not Found"})

    def websocket(self, query):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or (self.headers.get("Upgrade") or "").lower() != "websocket":
            return self.send_json(400, {"detail": "Expected a WebSocket upgrade"})
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        authorized = self.authorized(query)
        self.wfile.write((f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        self.wfile.flush()
        self.close_connection = True
        peer = Peer(self)
        if not authorized:
            return peer.close(4401, "unauthorized")
        if time.time() < DROP["refuse_until"]:
            return peer.cut()
        with LOCK:
            CLIENTS.add(peer)
        peer.send({"jsonrpc": "2.0", "method": "event", "params": {
            "type": "gateway.ready", "session_id": "", "payload": {"heartbeat": True, "replay_epoch": EPOCH}}})
        try:
            while True:
                text = peer.recv()
                if text is None:
                    break
                for line in text.splitlines():
                    if line.strip():
                        threading.Thread(target=self.dispatch, args=(peer, line), daemon=True).start()
        except (OSError, ValueError, struct.error):
            pass
        finally:
            with LOCK:
                CLIENTS.discard(peer)
            peer.alive = False

    def dispatch(self, peer, line):
        try:
            frame = json.loads(line)
        except ValueError:
            return
        rid, method = frame.get("id"), frame.get("method")
        if method is None and rid is not None:
            with LOCK:
                entry = PENDING.get(rid)
                if entry is None:
                    return
                if "error" in frame:
                    # A "not shown here" decline settles only once every asked client said so.
                    entry["declined"].add(peer)
                    if entry["declined"] >= entry["asked"]:
                        entry["result"] = None
                        entry["event"].set()
                else:
                    entry["result"] = frame.get("result")
                    entry["event"].set()
            return
        if method == "client.capabilities":
            peer.answers_requests = bool((frame.get("params") or {}).get("server_requests"))
            return peer.send(ok(rid, {"server_requests": ["approval", "clarify", "sudo", "secret"]}))
        handler = METHODS.get(method)
        if handler is None:
            return peer.send(err(rid, -32601, f"unknown method: {method}"))
        try:
            result = handler(frame.get("params") or {})
            if method in ("session.create", "session.resume") and result.get("session_id") in RUNTIME:
                with LOCK:
                    RUNTIME[result["session_id"]]["peers"].add(peer)
            peer.send(ok(rid, result))
        except RPCError as error:
            peer.send(err(rid, error.code, str(error)))
        except Exception as error:  # noqa: BLE001 — a mock should say what broke
            peer.send(err(rid, 5000, f"{type(error).__name__}: {error}"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19119)
    parser.add_argument("--password", help="gate the backend behind username/password sign-in (user: admin)")
    parser.add_argument("--token", help="fixed session token for the ungated mode")
    parser.add_argument("--quiet-world", action="store_true", help="no background activity")
    parser.add_argument("--long-bot-chats", action="store_true", help="give Ops a long Bot Chat (180 messages)")
    parser.add_argument("--seed-bot-chat", metavar="JSON", help="load Ops's Bot Chat from a local export of message rows")
    parser.add_argument("--gateway-port", type=int,
                        help="also serve the API-server mock (server.py) on this port, sharing its sessions with "
                             "the socket, like the real gateway and backend share one database (chats.py)")
    parser.add_argument("--gateway-key", default="dev-key-0123456789abcdef")
    parser.add_argument("--bandwidth", type=int, default=0, metavar="KBPS",
                        help="answer HTTP like a phone over the network at this many kbit/s (0: localhost speed)")
    parser.add_argument("--long-chat", action="store_true", help="seed 'Homelab rebuild', a chat as big as a long real one")
    parser.add_argument("--push-relay", default="simctl",
                        help="where push notices go (push.py): simctl (the simulator that registered), a relay URL, "
                             "or none (no plugin)")
    args = parser.parse_args()
    CONFIG["password"] = args.password
    CONFIG["long_bot_chats"] = args.long_bot_chats
    CONFIG["seed_bot_chat"] = args.seed_bot_chat
    if args.token:
        CONFIG["token"] = args.token
    seed()
    if args.gateway_port:
        import importlib.util
        import pathlib
        here = pathlib.Path(__file__).resolve().parent
        spec = importlib.util.spec_from_file_location("mock_gateway", here / "server.py")
        gateway = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gateway)
        gateway.Handler.key = args.gateway_key
        gateway.seed()
        gateway.NETWORK["kbps"] = args.bandwidth
        if args.long_chat:
            gateway.seed_long_chat()
        GATEWAY_PAGING.extend([gateway.page_rows, gateway.throttle])
        api = ThreadingHTTPServer((args.host, args.gateway_port), gateway.Handler)
        api.daemon_threads = True
        threading.Thread(target=api.serve_forever, daemon=True).start()
        spec = importlib.util.spec_from_file_location("mock_chats", here / "chats.py")
        chats = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(chats)
        chats.install(globals(), gateway)
        spec = importlib.util.spec_from_file_location("mock_projects", here / "projects.py")
        projects = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(projects)
        projects.install(globals(), gateway, chats)
        spec = importlib.util.spec_from_file_location("mock_helpers", here / "helpers.py")
        helpers = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helpers)
        helpers.install(globals(), gateway, chats)
        print(f"[mock-backend] API server on http://{args.host}:{args.gateway_port}, sharing chats with the socket", flush=True)
    import importlib.util as _util
    import pathlib as _pathlib
    _spec = _util.spec_from_file_location("mock_push", _pathlib.Path(__file__).resolve().parent / "push.py")
    _push = _util.module_from_spec(_spec)
    _spec.loader.exec_module(_push)
    if args.push_relay != "none":  # `none`: a gateway without the plugin (Set Up Push)
        _push.install(globals(), gateway if args.gateway_port else None, relay_mode=args.push_relay,
                      chats_module=chats if args.gateway_port else None)
    if not args.quiet_world:
        threading.Thread(target=ambient, daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    mode = f"gated (admin / {args.password})" if args.password else f"ungated (token {CONFIG['token']})"
    print(f"[mock-backend] listening on http://{args.host}:{args.port} — {mode}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
