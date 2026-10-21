#!/usr/bin/env python3
"""A mock Hermes Agent API server for developing and demoing the Hermes app.

Implements the subset of the real gateway's API the app uses (see
gateway/platforms/api_server*.py in NousResearch/hermes-agent), with scripted
agent turns instead of a model, so no provider credentials or spend are needed.

    python3 Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef

Scripted behaviour by message content:
  contains "approve"  -> asks for approval before running a command
  contains "fail"     -> the run fails
  contains "key expired" -> the run fails on the provider's key (Provider authentication failed)
  contains "slow"     -> a long multi-tool turn (good for testing stop/resume)
  contains "widget"   -> the widgets plugin's cards (widgets.py; --no-widgets leaves the plugin out)
  anything else       -> searches, runs a command, then answers in rich Markdown

A starved Mac (starve.py): `--starve 5-30`, or `POST /api/mock/starve {"seconds": 600}`.
"""

import argparse
import importlib.util
import json
import pathlib
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.RLock()
NOW = time.time()


def load_starve():
    """starve.py, one copy per process: the backend mock loads it under the same name, so both
    starve together."""
    module = sys.modules.get("mock_starve")
    if module is None:
        spec = importlib.util.spec_from_file_location("mock_starve", pathlib.Path(__file__).resolve().parent / "starve.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules["mock_starve"] = module
        spec.loader.exec_module(module)
    return module


STARVE = load_starve()
HOUR = 3600
DAY = 86400

SESSIONS = {}
MESSAGES = {}
RUNS = {}
JOBS = {}


def session_row(sid, title, source, started, last, preview, model="anthropic/claude-sonnet-4.6"):
    SESSIONS[sid] = {
        "id": sid, "source": source, "user_id": None, "model": model, "title": title,
        "started_at": started, "ended_at": None, "end_reason": None,
        "message_count": 0, "tool_call_count": 0, "input_tokens": 1200, "output_tokens": 340,
        "estimated_cost_usd": 0.012, "parent_session_id": None, "pinned": False, "archived": False,
        "hidden": False, "has_system_prompt": False, "has_model_config": False, "is_internal_child": False,
        "_last": last, "_preview": preview,
        # Hermes' read mark (docs/inbox.md §1): None = never tracked (read), 0 = marked unread, a time
        # = read until then. The API server's rows don't carry it; the dashboard's do (inbox.py).
        "_last_read_at": None,
    }
    MESSAGES[sid] = []


# `GET /health/detailed` reports the process id, which a restart changes (app_plugins.py bumps it).
RUNTIME = {"pid": 40000}
NETWORK = {"kbps": 0, "busy": 0}  # --bandwidth: a phone on Wi-Fi or Tailscale, not localhost; --busy: see below


def throttle(size):
    """Sends take as long as they would at the configured bandwidth (plus a round trip)."""
    if NETWORK["kbps"]:
        time.sleep(0.06 + size / (NETWORK["kbps"] * 128))


def page_rows(rows, query):
    """Hermes' GET /api/sessions/{id}/messages paging: limit (default and max 500), offset, and order
    (latest pages count back from the newest row, still returned oldest first)."""
    def arg(name):
        value = query.get(name)
        return value[0] if isinstance(value, list) else value
    raw_limit = arg("limit")
    limit = 500 if raw_limit is None else min(int(raw_limit), 500)
    offset = int(arg("offset") or 0)
    order = arg("order") or ("latest" if raw_limit is None else "oldest")
    if order == "latest":
        end = max(0, len(rows) - offset)
        page = rows[max(0, end - limit):end]
    else:
        page = rows[offset:offset + limit]
    return page, {"limit": limit, "offset": offset, "order": order, "returned": len(page)}


def seed_long_chat(turns=60):
    """A chat as big as a long real one: many turns of agent work with sizeable tool output."""
    sid = "long_history"
    session_row(sid, "Homelab rebuild", "cli", NOW - 9 * 86400, NOW - 3 * 60, "Rebuild the homelab")
    t = NOW - 9 * 86400
    for turn in range(turns):
        add_message(sid, "user", f"Step {turn + 1}: check the services on node {turn % 7} and fix what's broken.", timestamp=t)
        for call in range(8 + turn % 9):
            cid = f"call_long_{turn}_{call}"
            add_message(sid, "assistant", "", timestamp=t + call * 4 + 1,
                        tool_calls=[{"id": cid, "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": f"systemctl status svc-{call} --no-pager"})}}])
            output = "\n".join(f"svc-{call}.service line {i}: Active: active (running) since Tue; Main PID {1000 + i}; Tasks: {i % 9}; Memory: {i * 3}M" for i in range(30))
            add_message(sid, "tool", json.dumps({"output": output, "exit_code": 0}), timestamp=t + call * 4 + 3, tool_call_id=cid, tool_name="terminal")
        add_message(sid, "assistant", f"Node {turn % 7} is healthy again. I restarted **svc-{turn % 5}**, cleared a stale lock and confirmed the health checks pass.\n\n- Disk: 41% used\n- Load: 0.{turn % 9}\n- Next: watch the backups tonight.", timestamp=t + 200)
        t += 3 * 3600
    SESSIONS[sid]["_last_read_at"] = NOW - 2 * 86400  # read two days ago: many replies since


def add_message(sid, role, content, **extra):
    with LOCK:
        rows = MESSAGES.setdefault(sid, [])
        row = {
            "id": sum(len(v) for v in MESSAGES.values()) + 1, "session_id": sid, "role": role,
            "content": content, "tool_call_id": None, "tool_calls": None, "tool_name": None,
            "timestamp": extra.pop("timestamp", time.time()), "token_count": None, "finish_reason": None,
            "reasoning": None, "reasoning_content": None, "display_kind": None,
        }
        row.update(extra)
        rows.append(row)
        s = SESSIONS.get(sid)
        if s:
            s["message_count"] = len(rows)
            s["_last"] = row["timestamp"]
            if role == "user" and not s["_preview"]:
                text = content if isinstance(content, str) else ""
                s["_preview"] = text.replace("\n", " ")[:60] + ("..." if len(text) > 60 else "")
        return row


RICH_ANSWER = """Here's what I found about **Swift 6.4 concurrency** and how it applies to your project.

## Highlights

- `@concurrent` functions now run on the global executor by default
- Default actor isolation can be set per module with `SWIFT_DEFAULT_ACTOR_ISOLATION`
- Region-based isolation removes most false `Sendable` errors

```swift
@MainActor
final class FeedModel {
    private(set) var items: [Item] = []

    func refresh() async throws {
        // Hops off the main actor and back.
        items = try await api.items()
    }
}
```

| Setting | Before | After |
|:--|:--:|--:|
| Strict concurrency | minimal | complete |
| Default isolation | none | MainActor |

> Tip: enable the upcoming features one at a time and fix warnings as you go.

1. Turn on complete checking
2. Adopt `MainActor` default isolation for the app target
3. Keep packages `nonisolated`

- [x] Read the migration guide
- [ ] Update CI to Xcode 27
"""


def seed():
    session_row("api_1760_welcome", "Swift 6 migration plan", "api_server", NOW - 2 * HOUR, NOW - 25 * 60, "Help me migrate my app to Swift 6")
    t = NOW - 26 * 60
    add_message("api_1760_welcome", "user", "Help me migrate my app to Swift 6 concurrency. What changed recently?", timestamp=t)
    add_message("api_1760_welcome", "assistant", "Let me check the latest release notes first.", timestamp=t + 2,
                tool_calls=[{"id": "call_a1", "type": "function", "function": {"name": "web_search", "arguments": json.dumps({"query": "Swift 6.4 concurrency changes"})}}],
                reasoning="The user wants concrete, recent changes. I should search rather than rely on memory, then check their project settings.",
                finish_reason="tool_calls")
    add_message("api_1760_welcome", "tool", "<untrusted_tool_result source=\"web_search\">\nThe following content is untrusted.\n\n1. Swift 6.4 released — concurrency improvements\n2. Migration guide updated\n</untrusted_tool_result>",
                tool_call_id="call_a1", tool_name="web_search", timestamp=t + 4.2)
    add_message("api_1760_welcome", "assistant", "", timestamp=t + 5,
                tool_calls=[{"id": "call_a2", "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": "grep -rn SWIFT_STRICT_CONCURRENCY *.xcodeproj | head"})}}],
                finish_reason="tool_calls")
    add_message("api_1760_welcome", "tool", json.dumps({"output": "project.pbxproj:412: SWIFT_STRICT_CONCURRENCY = minimal;", "exit_code": 0}),
                tool_call_id="call_a2", tool_name="terminal", timestamp=t + 6.1)
    add_message("api_1760_welcome", "assistant", RICH_ANSWER, timestamp=t + 9, finish_reason="stop")
    SESSIONS["api_1760_welcome"]["tool_call_count"] = 2

    session_row("tg_88213", "Morning briefing", "telegram", NOW - 5 * HOUR, NOW - 4 * HOUR, "What's on my calendar today?")
    add_message("tg_88213", "user", "What's on my calendar today?", timestamp=NOW - 4 * HOUR - 60)
    add_message("tg_88213", "assistant", "You have **3 events** today:\n\n- 09:30 Stand-up\n- 13:00 Lunch with Maya\n- 16:00 Design review", timestamp=NOW - 4 * HOUR)

    session_row("cli_2026_1011", "Disk cleanup on the NAS", "cli", NOW - DAY - 3 * HOUR, NOW - DAY - 2 * HOUR, "Free up space on /volume1")
    add_message("cli_2026_1011", "user", "Free up space on /volume1", timestamp=NOW - DAY - 2 * HOUR - 300)
    add_message("cli_2026_1011", "assistant", "Removed 42 GB of old snapshots. `/volume1` is now at **61%**.", timestamp=NOW - DAY - 2 * HOUR)

    session_row("slack_5521", "Stand-up summary", "slack", NOW - 2 * DAY, NOW - 2 * DAY, "Summarise #team-ios for stand-up")
    add_message("slack_5521", "user", "Summarise #team-ios for stand-up", timestamp=NOW - 2 * DAY)
    add_message("slack_5521", "assistant", "**Yesterday:** widgets shipped to TestFlight. **Today:** sync fixes. **Blocked:** nothing.", timestamp=NOW - 2 * DAY + 15)

    # Commands, skills, Bots and gateway files as plain text, the way the CLI sends them: the
    # app draws them as cards, chips and pills (docs/commands-and-references.md).
    session_row("cli_release_prep", "Release prep", "cli", NOW - 3 * HOUR, NOW - 40 * 60, "fix issue #123 and open a PR")
    t = NOW - 3 * HOUR
    add_message("cli_release_prep", "user", "/github-pr-workflow /test-driven-development fix issue #123 and open a PR", timestamp=t)
    add_message("cli_release_prep", "assistant", "Fixed the reconnect loop in `Sources/Sync/Reconnect.swift` with a failing test first, then opened **#124**.", timestamp=t + 40)
    add_message("cli_release_prep", "user", "ask @ada to turn @file:CHANGELOG.md into release notes", timestamp=t + 120)
    add_message("cli_release_prep", "assistant", "Done: @ada is drafting the notes from @file:CHANGELOG.md and will post them by 15:00.", timestamp=t + 150)
    add_message("cli_release_prep", "user", "/goal Ship Hermes 1.3 by Friday", timestamp=t + 200)
    add_message("cli_release_prep", "assistant", "Goal set. I'll keep working toward **shipping Hermes 1.3 by Friday** across turns and check it off when the release is out.", timestamp=t + 205)
    add_message("cli_release_prep", "user", "/kanban", timestamp=t + 260)
    add_message("cli_release_prep", "assistant", "Three cards in progress, two in review.", timestamp=t + 262)

    session_row("discord_77", "Release notes draft", "discord", NOW - 4 * DAY, NOW - 4 * DAY, "Draft release notes for 2.3")
    add_message("discord_77", "user", "Draft release notes for 2.3", timestamp=NOW - 4 * DAY)
    add_message("discord_77", "assistant", "## 2.3\n\n- Faster sync\n- New widgets\n- Bug fixes", timestamp=NOW - 4 * DAY + 20)

    session_row("api_old_1", "Trip to Lisbon", "api_server", NOW - 12 * DAY, NOW - 12 * DAY, "Plan 3 days in Lisbon")
    add_message("api_old_1", "user", "Plan 3 days in Lisbon", timestamp=NOW - 12 * DAY)
    add_message("api_old_1", "assistant", "**Day 1** Alfama and the castle. **Day 2** Belém. **Day 3** Sintra.", timestamp=NOW - 12 * DAY + 30)

    session_row("api_old_2", "Kubernetes ingress debugging", "api_server", NOW - 45 * DAY, NOW - 45 * DAY, "Why does my ingress 404?")
    add_message("api_old_2", "user", "Why does my ingress 404?", timestamp=NOW - 45 * DAY)
    add_message("api_old_2", "assistant", "Your `pathType` is `Exact`; switch it to `Prefix`.", timestamp=NOW - 45 * DAY + 30)

    seed_read_marks()

    JOBS["job_brief"] = {
        "id": "job_brief", "name": "Morning briefing", "prompt": "Summarise overnight news, my calendar and the weather.",
        "skills": [], "schedule": {"kind": "cron", "expr": "30 7 * * *", "display": "every day at 07:30"}, "schedule_display": "every day at 07:30",
        "repeat": {"times": None, "completed": 41}, "enabled": True, "state": "scheduled",
        "created_at": "2026-09-01T07:30:00+02:00", "next_run_at": "2026-10-13T07:30:00+02:00",
        "last_run_at": "2026-10-12T07:30:04.120391+02:00", "last_status": "ok", "last_error": None, "deliver": "telegram",
    }
    JOBS["job_backup"] = {
        "id": "job_backup", "name": "Check NAS backups", "prompt": "Verify last night's backups finished and report failures.",
        "skills": ["synology"], "schedule": {"kind": "cron", "display": "0 6 * * *"}, "schedule_display": "0 6 * * *",
        "repeat": {"times": None, "completed": 12}, "enabled": False, "state": "paused",
        "created_at": "2026-09-20T10:00:00+02:00", "next_run_at": None, "last_run_at": "2026-10-09T06:00:01+02:00",
        "last_status": "error", "last_error": "ssh: connect to host nas.local port 22: Connection refused", "deliver": "local",
    }


def seed_read_marks():
    """Read marks as another device left them (docs/inbox.md §7): replies landed after some, one
    was marked unread, the oldest were never tracked."""
    marks = {
        "api_1760_welcome": SESSIONS["api_1760_welcome"]["_last"] + 1,  # read
        "tg_88213": NOW - 5 * HOUR,                                     # 1 reply since
        "cli_2026_1011": SESSIONS["cli_2026_1011"]["_last"] + 1,        # read
        "slack_5521": 0.0,                                              # marked unread
        "cli_release_prep": NOW - 3 * HOUR + 100,                       # 3 replies since
        "discord_77": SESSIONS["discord_77"]["_last"] + 1,              # read
    }
    for sid, mark in marks.items():
        SESSIONS[sid]["_last_read_at"] = mark


def public_session(s, listing):
    row = {k: v for k, v in s.items() if not k.startswith("_")}
    if listing:
        row["last_active"] = s["_last"]
        row["preview"] = s["_preview"] or ""
    return row


# ---------------------------------------------------------------- runs



# Mock-only: the next N read marks (`unread: false`) are refused with 503, as a busy gateway does
# (`POST /api/mock/fail-reads {count}` on the backend), for the app's read outbox.
FAILED_READS = {"count": 0}


def take_failed_read() -> bool:
    with LOCK:
        if FAILED_READS["count"] <= 0:
            return False
        FAILED_READS["count"] -= 1
        return True

class Run:
    def __init__(self, run_id, session_id, text):
        self.id = run_id
        self.session_id = session_id
        self.text = text
        self.events = []
        self.cond = threading.Condition()
        self.status = "queued"
        self.output = ""
        self.stop = threading.Event()
        self.approval = None
        self.approval_choice = None
        self.terminal = False

    def emit(self, name, **fields):
        with self.cond:
            seq = len(self.events)
            event = {"event": name, "run_id": self.id, "timestamp": time.time(), **fields, "seq": seq}
            self.events.append(event)
            self.cond.notify_all()

    def finish(self):
        with self.cond:
            self.terminal = True
            self.cond.notify_all()


def stream_text(run, text, chunk=6, delay=0.02):
    words = re.findall(r"\S+\s*|\s+", text)
    out = ""
    for i in range(0, len(words), chunk):
        if run.stop.is_set():
            return out, False
        piece = "".join(words[i:i + chunk])
        out += piece
        run.emit("message.delta", delta=piece)
        time.sleep(delay)
    return out, True


def tool(run, name, preview, result, seconds):
    run.emit("tool.started", tool=name, preview=preview)
    end = time.time() + seconds
    while time.time() < end:
        if run.stop.is_set():
            return False
        time.sleep(0.05)
    run.emit("tool.completed", tool=name, duration=round(seconds, 3), error=False, preview=result[:500])
    return True


def agent_turn(run):
    sid, text = run.session_id, run.text
    run.status = "running"
    add_message(sid, "user", text)
    s = SESSIONS[sid]
    if not s["title"]:
        s["title"] = text.strip().split("\n")[0][:48]  # instant "derived" title, upgraded later
        threading.Timer(2.5, lambda: s.__setitem__("title", s["title"].rstrip(".?!").capitalize()[:40])).start()
    lowered = text.lower()
    try:
        if "key expired" in lowered:
            # The API server only says so in words (gateway/platforms/api_server.py).
            time.sleep(0.6)
            run.status = "failed"
            run.emit("run.failed", error="⚠️ Provider authentication failed: Anthropic rejected the API key (401 invalid x-api-key)")
            return
        if "fail" in lowered:
            time.sleep(0.6)
            run.status = "failed"
            run.emit("run.failed", error="Provider returned 500: upstream overloaded")
            return
        if "approve" in lowered:
            narration = "I'll clean the build folder first. "
            stream_text(run, narration)
            command = "rm -rf ./build && make release"
            request_id = uuid.uuid4().hex
            run.approval = {"command": command, "pattern_key": "rm_rf", "pattern_keys": ["rm_rf"], "description": "Recursive delete",
                            "allow_permanent": True, "allow_session": True, "request_id": request_id,
                            "choices": ["once", "session", "always", "deny"]}
            run.status = "waiting_for_approval"
            run.emit("approval.request", **run.approval)
            while run.approval_choice is None and not run.stop.is_set():
                time.sleep(0.1)
            choice = run.approval_choice
            run.approval = None
            run.status = "running"
            run.emit("approval.responded", choice=choice or "deny", request_id=request_id, resolved=1)
            add_message(sid, "assistant", narration.strip(), finish_reason="tool_calls",
                        tool_calls=[{"id": "call_x", "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": command})}}])
            if choice == "deny" or choice is None:
                run.emit("tool.started", tool="terminal", preview=command)
                run.emit("tool.completed", tool="terminal", duration=0.01, error=True, preview="BLOCKED: denied by user")
                add_message(sid, "tool", "BLOCKED: denied by user", tool_call_id="call_x", tool_name="terminal")
                answer = "Okay — I didn't touch the build folder. Let me know if you want me to try a safer cleanup."
            else:
                tool(run, "terminal", command, "Release build succeeded in 41.2s", 1.6)
                add_message(sid, "tool", json.dumps({"output": "Release build succeeded in 41.2s", "exit_code": 0}), tool_call_id="call_x", tool_name="terminal")
                answer = "Done. The release build **succeeded in 41.2 s** and the artifacts are in `./build/release`."
            out, ok = stream_text(run, answer)
            add_message(sid, "assistant", out, finish_reason="stop")
            run.output = out
        else:
            slow = "slow" in lowered
            narration = "Let me look into that. "
            stream_text(run, narration)
            calls = [("web_search", {"query": text[:60]}, "1. Official docs\n2. Release notes\n3. Community thread", 1.4 if not slow else 4)]
            calls.append(("terminal", {"command": "uname -a && df -h /"}, "Darwin mini 27.0.0 arm64\n/dev/disk3s1  926Gi  412Gi  514Gi  45% /", 0.9 if not slow else 4))
            if slow:
                calls.append(("read_file", {"path": "~/projects/app/Package.swift"}, "// swift-tools-version: 6.2", 4))
            tool_calls = [{"id": f"call_{i}", "type": "function", "function": {"name": n, "arguments": json.dumps(a)}} for i, (n, a, _, _) in enumerate(calls)]
            add_message(sid, "assistant", narration.strip(), tool_calls=tool_calls, finish_reason="tool_calls",
                        reasoning="I should gather facts before answering: search, then check the machine.")
            for i, (name, args, result, seconds) in enumerate(calls):
                preview = next(iter(args.values()))
                if not tool(run, name, preview, result, seconds):
                    break
                add_message(sid, "tool", result, tool_call_id=f"call_{i}", tool_name=name)
            if not run.stop.is_set():
                out, ok = stream_text(run, RICH_ANSWER)
                add_message(sid, "assistant", out, finish_reason="stop")
                run.output = out
        if run.stop.is_set():
            run.status = "cancelled"
            run.emit("run.cancelled", completed=False, partial=True, interrupted=True)
        else:
            run.status = "completed"
            run.emit("run.completed", completed=True, partial=False, interrupted=False, output=run.output,
                     usage={"input_tokens": 1830, "output_tokens": 412, "total_tokens": 2242, "cache_read_tokens": 900, "cache_write_tokens": 0},
                     runtime={"provider": "openrouter", "model": "anthropic/claude-sonnet-4.6", "route_source": "global"})
    finally:
        run.finish()


# ---------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockHermes/0.1"
    key = ""

    def log_message(self, fmt, *args):
        print("[mock-hermes]", self.command, self.path, "->", args[1] if len(args) > 1 else "")

    # helpers
    def send_json(self, status, body, extra=None):
        data = json.dumps(body).encode()
        throttle(len(data))
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, message, code=None, kind="invalid_request_error"):
        self.send_json(status, {"error": {"message": message, "type": kind, "param": None, "code": code}})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return {}

    def authorized(self):
        if self.headers.get("Authorization", "") == f"Bearer {self.key}":
            return True
        self.send_json(401, {"error": {"message": "Invalid gateway API key (API_SERVER_KEY)", "type": "gateway_auth_error", "code": "gateway_auth_failed"}})
        return False

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def sse(self, data, event=None, id=None):
        frame = ""
        if id is not None:
            frame += f"id: {id}\n"
        if event:
            frame += f"event: {event}\n"
        frame += "data: " + json.dumps(data, ensure_ascii=False) + "\n\n"
        STARVE.wait()
        self.wfile.write(frame.encode())
        self.wfile.flush()

    def route(self, method):
        parsed = urlparse(self.path)
        path = re.sub(r"^/p/[^/]+", "", parsed.path).rstrip("/") or "/"
        query = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
        return path, query

    # dispatch
    def do_GET(self):
        path, query = self.route("GET")
        STARVE.wait(health=path in ("/health", "/v1/health"))
        if path in ("/health", "/v1/health"):
            return self.send_json(200, {"status": "ok", "platform": "hermes-agent", "version": "0.21.6"})
        if not self.authorized():
            return
        if path == "/health/detailed":
            return self.send_json(200, {"status": "ok", "platform": "hermes-agent", "version": "0.21.6",
                                        "gateway_state": "running", "pid": RUNTIME["pid"]})
        # --busy: an overloaded Mac, whose gateway answers its health check at once and
        # everything else only after a long wait.
        if NETWORK["busy"]:
            time.sleep(NETWORK["busy"])
        if path == "/v1/capabilities":
            return self.send_json(200, CAPABILITIES)
        if path == "/v1/models":
            return self.send_json(200, {"object": "list", "data": [{"id": "hermes-agent", "object": "model", "created": int(NOW), "owned_by": "hermes"}]})
        if path == "/api/model/options":
            return self.send_json(200, MODEL_OPTIONS)
        if path == "/v1/skills":
            return self.send_json(200, {"object": "list", "data": SKILLS})
        if path == "/v1/toolsets":
            return self.send_json(200, {"object": "list", "platform": "api_server", "data": TOOLSETS})
        if path == "/api/sessions":
            limit, offset = int(query.get("limit", 50)), int(query.get("offset", 0))
            with LOCK:
                # Like list_sessions_rich: archived and hidden rows stay out; pins come back regardless.
                listed = [s for s in SESSIONS.values() if (s["pinned"] or not s.get("archived")) and not s.get("hidden")]
                rows = sorted(listed, key=lambda s: s["_last"], reverse=True)
                page = rows[offset:offset + limit]
                return self.send_json(200, {"object": "list", "data": [public_session(s, True) for s in page],
                                            "limit": limit, "offset": offset, "has_more": offset + limit < len(rows)})
        m = re.fullmatch(r"/api/sessions/([^/]+)", path)
        if m:
            s = SESSIONS.get(m.group(1))
            return self.send_json(200, {"object": "hermes.session", "session": public_session(s, False)}) if s else self.error(404, f"Session not found: {m.group(1)}", "session_not_found")
        m = re.fullmatch(r"/api/sessions/([^/]+)/messages", path)
        if m:
            sid = m.group(1)
            if sid not in SESSIONS:
                return self.error(404, f"Session not found: {sid}", "session_not_found")
            with LOCK:
                rows, pagination = page_rows(list(MESSAGES.get(sid, [])), query)
            return self.send_json(200, {"object": "list", "session_id": sid, "data": rows, "pagination": pagination})
        m = re.fullmatch(r"/v1/runs/([^/]+)", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, f"Run not found: {m.group(1)}", "run_not_found")
            body = {"object": "hermes.run", "run_id": run.id, "status": run.status, "session_id": run.session_id,
                    "model": "hermes-agent", "output": run.output if run.terminal else None}
            if run.approval:
                body["approval"] = run.approval
            return self.send_json(200, body)
        m = re.fullmatch(r"/v1/runs/([^/]+)/events", path)
        if m:
            return self.run_events(m.group(1), query)
        if path == "/api/jobs":
            return self.send_json(200, {"jobs": list(JOBS.values())})
        return self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error", "param": None, "code": None}})

    def run_events(self, run_id, query):
        run = RUNS.get(run_id)
        if not run:
            return self.error(404, f"Run not found: {run_id}", "run_not_found")
        raw = self.headers.get("Last-Event-ID") or query.get("last_seq")
        last = int(raw) if raw is not None else -1
        self.start_sse()
        try:
            self.wfile.write(b": open\n\n")
            self.wfile.flush()
            sent = last + 1
            idle = time.time()
            while True:
                with run.cond:
                    pending = run.events[sent:]
                    terminal = run.terminal
                    if not pending and not terminal:
                        run.cond.wait(timeout=1.0)
                        pending = run.events[sent:]
                        terminal = run.terminal
                for event in pending:
                    self.sse(event, id=event["seq"])
                    sent += 1
                    idle = time.time()
                if terminal and sent >= len(run.events):
                    self.wfile.write(b": stream closed\n\n")
                    self.wfile.flush()
                    return
                if time.time() - idle > 10:
                    STARVE.wait()
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    idle = time.time()
        except (BrokenPipeError, ConnectionResetError):
            return  # the run continues detached

    def do_POST(self):
        path, _ = self.route("POST")
        if path == "/api/mock/starve":
            # Mock-only (starve.py): the whole machine starved, this gateway and the backend with it.
            return self.send_json(200, STARVE.configure(self.body()))
        STARVE.wait()
        if not self.authorized():
            return
        body = self.body()
        if path == "/api/sessions":
            sid = body.get("id") or f"api_{int(time.time())}_{uuid.uuid4().hex[:8]}"
            with LOCK:
                session_row(sid, body.get("title"), body.get("source", "api_server"), time.time(), time.time(), "", model=body.get("model"))
            return self.send_json(201, {"object": "hermes.session", "session": public_session(SESSIONS[sid], False)})
        m = re.fullmatch(r"/api/sessions/([^/]+)/fork", path)
        if m:
            src = SESSIONS.get(m.group(1))
            if not src:
                return self.error(404, "Session not found", "session_not_found")
            new_id = f"api_{int(time.time())}_{uuid.uuid4().hex[:8]}"
            with LOCK:
                session_row(new_id, body.get("title") or f"{src['title'] or 'Chat'} #2", "api_server", time.time(), time.time(), src["_preview"], model=src["model"])
                SESSIONS[new_id]["parent_session_id"] = src["id"]
                MESSAGES[new_id] = [dict(r, session_id=new_id) for r in MESSAGES[src["id"]]]
                SESSIONS[new_id]["message_count"] = len(MESSAGES[new_id])
                src["end_reason"] = "branched"
            return self.send_json(201, {"object": "hermes.session", "session": public_session(SESSIONS[new_id], False)})
        m = re.fullmatch(r"/api/sessions/([^/]+)/chat/stream", path)
        if m:
            return self.session_stream(m.group(1), body)
        if path == "/v1/runs":
            sid = body.get("session_id")
            text = body.get("input")
            if not text:
                return self.error(400, "Missing 'input' field")
            if sid not in SESSIONS:
                with LOCK:
                    session_row(sid, None, "api_server", time.time(), time.time(), "")
            run = Run(f"run_{uuid.uuid4().hex}", sid, text if isinstance(text, str) else str(text))
            RUNS[run.id] = run
            threading.Thread(target=agent_turn, args=(run,), daemon=True).start()
            return self.send_json(202, {"run_id": run.id, "status": "started", "replayed": False})
        m = re.fullmatch(r"/v1/runs/([^/]+)/stop", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, "Run not found", "run_not_found")
            if run.terminal:
                return self.error(409, "Run is not active", "run_not_active")
            run.stop.set()
            return self.send_json(200, {"run_id": run.id, "status": "stopping"})
        m = re.fullmatch(r"/v1/runs/([^/]+)/approval", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run or not run.approval:
                return self.error(409, "No approval pending", "approval_not_pending")
            run.approval_choice = body.get("choice", "once")
            return self.send_json(200, {"object": "hermes.run.approval_response", "run_id": run.id, "choice": run.approval_choice, "resolved": 1})
        m = re.fullmatch(r"/api/jobs/([^/]+)/(pause|resume|run)", path)
        if m:
            job = JOBS.get(m.group(1))
            if not job:
                return self.send_json(404, {"error": "Job not found"})
            if m.group(2) == "pause":
                job.update(enabled=False, state="paused", next_run_at=None)
            elif m.group(2) == "resume":
                job.update(enabled=True, state="scheduled", next_run_at="2026-10-13T07:30:00+02:00")
            return self.send_json(200, {"job": job})
        if path == "/api/jobs":
            if not body.get("name"):
                return self.send_json(400, {"error": "Name is required"})
            if not body.get("schedule"):
                return self.send_json(400, {"error": "Schedule is required"})
            # Like Hermes's parser (cron/jobs.py): an interval takes no time of day.
            bad = re.match(r"(?i)^every\s+(\d+\s*[mhdw]\w*\s+at\s+.+)$", body["schedule"].strip())
            if bad:
                return self.send_json(400, {"error": f"Invalid duration: '{bad.group(1)}'. Use format like '30m', '2h', '1d', or a bare unit like 'hour'."})
            jid = uuid.uuid4().hex[:12]
            JOBS[jid] = {"id": jid, "name": body["name"], "prompt": body.get("prompt", ""), "skills": body.get("skills") or [],
                         "schedule": {"kind": "interval", "display": body["schedule"]}, "schedule_display": body["schedule"],
                         "repeat": {"times": None, "completed": 0}, "enabled": True, "state": "scheduled",
                         "created_at": "2026-10-12T09:00:00+02:00", "next_run_at": "2026-10-13T09:00:00+02:00",
                         "last_run_at": None, "last_status": None, "last_error": None, "deliver": "local"}
            return self.send_json(200, {"job": JOBS[jid]})
        return self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error", "param": None, "code": None}})

    def session_stream(self, sid, body):
        if sid not in SESSIONS:
            return self.error(404, f"Session not found: {sid}", "session_not_found")
        message = body.get("message") or body.get("input")
        parts = message if isinstance(message, list) else [{"type": "text", "text": message or ""}]
        text = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text")
        images = sum(1 for p in parts if p.get("type") == "image_url")
        stored = "\n".join([text] + ["[screenshot]"] * images).strip()
        run_id = f"run_{uuid.uuid4().hex}"
        run = Run(run_id, sid, text)
        RUNS[run_id] = run
        seq = [0]

        def send(event, **fields):
            seq[0] += 1
            self.sse({**fields, "session_id": sid, "run_id": run_id, "seq": seq[0], "ts": time.time()}, event=event)

        self.start_sse()
        try:
            add_message(sid, "user", stored)
            s = SESSIONS[sid]
            if not s["title"]:
                s["title"] = (text or "Image").split("\n")[0][:48]
            send("run.started", user_message={"role": "user", "content": parts}, runtime={"provider": "", "model": "", "route_source": "global"})
            mid = f"msg_{uuid.uuid4().hex}"
            send("message.started", message={"id": mid, "role": "assistant"})
            send("tool.started", message_id=mid, tool_name="vision_analyze", preview=f"{images} image(s)", args={"count": images})
            time.sleep(1.2)
            send("tool.completed", message_id=mid, tool_name="vision_analyze", preview=None, args=None)
            answer = f"I can see **{images} image{'s' if images != 1 else ''}**. " + ("It looks like a screenshot of an app with a dark interface — the layout is clean and the hierarchy is clear." if images else "")
            for word in re.findall(r"\S+\s*", answer):
                send("assistant.delta", message_id=mid, delta=word)
                time.sleep(0.03)
            add_message(sid, "assistant", answer, finish_reason="stop")
            send("assistant.completed", message_id=mid, content=answer, completed=True, partial=False, interrupted=False,
                 runtime={"provider": "openrouter", "model": "anthropic/claude-sonnet-4.6", "route_source": "global"})
            run.status, run.output = "completed", answer
            run.finish()
            send("run.completed", message_id=mid, completed=True, partial=False, interrupted=False, messages=[],
                 usage={"input_tokens": 900, "output_tokens": 60, "total_tokens": 960}, runtime={"provider": "openrouter"})
            send("done")
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_PATCH(self):
        path, _ = self.route("PATCH")
        STARVE.wait()
        if not self.authorized():
            return
        body = self.body()
        m = re.fullmatch(r"/api/sessions/([^/]+)", path)
        if m and body.get("unread") is False and take_failed_read():
            return self.error(503, "Gateway busy", "busy")
        if m and m.group(1) in SESSIONS:
            # api_server.py's PATCH: these fields only, flags as booleans; `unread` moves the read
            # mark (false stamps it now, true sets it to 0).
            unknown = [key for key in body if key not in ("title", "end_reason", "pinned", "archived", "hidden", "unread")]
            if unknown:
                return self.error(400, f"Unsupported session field: {unknown[0]}", "unsupported_session_field")
            for key in ("pinned", "archived", "hidden", "unread"):
                if key in body and not isinstance(body[key], bool):
                    return self.error(400, f"{key} must be a boolean", "invalid_session_field")
            s = SESSIONS[m.group(1)]
            with LOCK:
                for key in ("title", "pinned", "archived", "hidden", "end_reason"):
                    if key in body:
                        s[key] = body[key]
                if body.get("pinned"):
                    s["hidden"] = False
                if "unread" in body:
                    s["_last_read_at"] = 0.0 if body["unread"] else time.time()
            return self.send_json(200, {"object": "hermes.session", "session": public_session(s, False)})
        return self.error(404, "Session not found", "session_not_found")

    def do_DELETE(self):
        path, _ = self.route("DELETE")
        STARVE.wait()
        if not self.authorized():
            return
        m = re.fullmatch(r"/api/sessions/([^/]+)", path)
        if m and m.group(1) in SESSIONS:
            SESSIONS.pop(m.group(1))
            MESSAGES.pop(m.group(1), None)
            return self.send_json(200, {"object": "hermes.session.deleted", "id": m.group(1), "deleted": True})
        m = re.fullmatch(r"/api/jobs/([^/]+)", path)
        if m and m.group(1) in JOBS:
            JOBS.pop(m.group(1))
            return self.send_json(200, {"ok": True})
        return self.error(404, "Not found", "not_found")


CAPABILITIES = {
    "object": "hermes.api_server.capabilities", "platform": "hermes-agent", "model": "hermes-agent",
    "auth": {"type": "bearer", "required": True},
    "features": {
        "chat_completions": True, "chat_completions_streaming": True, "responses_api": True, "run_submission": True,
        "run_status": True, "run_events_sse": True, "run_stop": True, "run_steer": True, "run_approval_response": True,
        "tool_progress_events": True, "approval_events": True, "session_resources": True, "model_options": True,
        "session_chat": True, "session_chat_streaming": True, "session_fork": True, "session_model_lock": True,
        "reasoning_streaming": True, "skills_api": True, "jobs_admin": False,
        "session_continuity_header": "X-Hermes-Session-Id", "session_key_header": "X-Hermes-Session-Key",
    },
    "endpoints": {},
}

MODEL_OPTIONS = {
    "model": "anthropic/claude-sonnet-4.6", "provider": "openrouter",
    "providers": [
        {"slug": "openrouter", "name": "OpenRouter", "is_current": True, "is_user_defined": False, "authenticated": True,
         "models": ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-4.6", "openai/gpt-5", "x-ai/grok-4.5", "google/gemini-3-pro", "deepseek/deepseek-v4", "qwen/qwen3-coder", "moonshotai/kimi-k2"],
         "featured_models": ["anthropic/claude-sonnet-4.6", "openai/gpt-5", "x-ai/grok-4.5", "google/gemini-3-pro"], "total_models": 8,
         "capabilities": {"openai/gpt-5": {"fast": True, "reasoning": True}},
         "pricing": {"anthropic/claude-sonnet-4.6": {"input": "$3.00", "output": "$15.00", "cache": None, "free": False}}},
        {"slug": "nous", "name": "Nous Portal", "is_current": False, "is_user_defined": False, "authenticated": True,
         "models": ["Hermes-4-405B", "Hermes-4-70B"], "featured_models": [], "total_models": 2},
        {"slug": "anthropic", "name": "Anthropic", "is_current": False, "is_user_defined": False, "authenticated": False,
         "models": [], "warning": "paste ANTHROPIC_API_KEY to activate"},
    ],
}

SKILLS = [
    {"name": "github-pr-workflow", "description": "Open, review and land pull requests with the gh CLI.", "category": "software-development"},
    {"name": "arxiv", "description": "Search and summarise papers from arXiv.", "category": "research"},
    {"name": "blogwatcher", "description": "Watch RSS feeds and summarise new posts.", "category": "research"},
    {"name": "synology", "description": "Manage a Synology NAS over SSH.", "category": "devops"},
    {"name": "excalidraw", "description": "Draw diagrams as Excalidraw files.", "category": "creative"},
]

TOOLSETS = [
    {"name": "core", "label": "Core", "description": "Files, terminal and code execution", "enabled": True, "configured": True, "tools": ["execute_code", "patch", "read_file", "search_files", "terminal", "write_file"]},
    {"name": "web", "label": "Web", "description": "Search and read the web", "enabled": True, "configured": True, "tools": ["web_extract", "web_search"]},
    {"name": "browser", "label": "Browser", "description": "Drive a real browser", "enabled": False, "configured": False, "tools": ["browser_click", "browser_navigate", "browser_snapshot", "browser_type"]},
    {"name": "memory", "label": "Memory", "description": "Long-term memory and past sessions", "enabled": True, "configured": True, "tools": ["memory", "session_search"]},
]


def install_widgets(gateway, enabled=True):
    """The widgets plugin's scenario (widgets.py), loaded beside this file like backend.py's modules."""
    import importlib.util
    import pathlib
    spec = importlib.util.spec_from_file_location("mock_widgets", pathlib.Path(__file__).resolve().parent / "widgets.py")
    widgets = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(widgets)
    widgets.ENABLED["on"] = enabled
    widgets.install_gateway(gateway)
    return widgets


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18642)
    parser.add_argument("--key", default="dev-key-0123456789abcdef")
    parser.add_argument("--no-widgets", action="store_true", help="a gateway without the hermes-app-widgets plugin")
    parser.add_argument("--starve", metavar="MIN-MAX",
                        help="a Mac too loaded to run Hermes, from launch: answers come in bursts every MIN-MAX seconds (starve.py)")
    args = parser.parse_args()
    if args.starve:
        STARVE.start(float("inf"), gap=STARVE.parse_gap(args.starve))
    Handler.key = args.key
    seed()
    install_widgets(sys.modules[__name__], enabled=not args.no_widgets)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"[mock-hermes] listening on http://{args.host}:{args.port} (key: {args.key})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
