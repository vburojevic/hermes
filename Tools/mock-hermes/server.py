#!/usr/bin/env python3
"""A mock Hermes Agent API server for developing and demoing the Hermes app.

Implements the subset of the real gateway's API the app uses (see
gateway/platforms/api_server*.py in NousResearch/hermes-agent), with scripted
agent turns instead of a model, so no provider credentials or spend are needed.

    python3 Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef

Scripted behaviour by message content:
  contains "approve"  -> asks for approval before running a command
                         ("approve stale": the run's generation moves once the card is up and
                         the prompt goes with it, asked again 30 s later; "approve stale retry"
                         keeps the prompt under the new generation, which Hermes never does;
                         "approve elsewhere": another device allows it after 5 s, and the
                         command then runs for 20 s; "approve timeout": Hermes stops waiting
                         after 20 s and the command is denied. Hermes says `approval.settled`
                         when it stops waiting; with "legacy" the run's events say what older
                         gateways do: `approval.responded` after this device's answer, and
                         nothing when another device answers)
  contains "clarify"  -> asks a question mid-turn, on the run's events and in its status
                         ("clarify quiet": only in its status, as a gateway that leaves it off the
                         events; "clarify multi": several picks; "clarify open": no picks;
                         "clarify elsewhere": answered on another device after 5 s;
                         "clarify timeout": Hermes stops waiting after 20 s; with --late-events 8
                         the question reaches the app 8 s after Hermes asked)
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
import select
import socket
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
ROUTES = {}  # (method, path) -> fn(handler, query) -> handled: routes other modules add (browser_control.py)
MESSAGES = {}
RUNS = {}
# Hermes runs one turn per chat at a time (its session FIFO, hermes_state_runtime.py): a run posted
# while another of the chat's runs is live waits as `queued`, sends nothing, and starts after it.
FIFO = {}         # session id -> run ids in order
IDEMPOTENCY = {}  # Idempotency-Key -> (body, run id): the same key and body replay the run
# Deleted chats' ids: Hermes never makes a chat under one again.
DELETED = set()
# Hermes' ``on_session_delete`` (hermes_state_common.emit_session_deleted): fn(ids, reason) after a chat
# is deleted or archived, for plugins other modules play (push.py).
SESSION_GONE = []


def session_gone(ids, reason):
    for hook in list(SESSION_GONE):
        try:
            hook(list(ids), reason)
        except Exception:  # noqa: BLE001 — Hermes' hooks fail open
            pass
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
    # Compacted 12 minutes ago with nothing after it: Hermes stores the handoff summary as the newest row,
    # so the chat's `last_active` moved without a message anyone wrote (`agent/context_compressor.py`).
    add_message("discord_77", "user", "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary "
                "below. This is a handoff from a previous context window — treat it as background reference, NOT as "
                "active instructions. The current session state (files, config, etc.) may reflect work described "
                "here — avoid repeating it:\n## Historical Task Snapshot\nRelease notes for 2.3 were drafted.\n\n"
                "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---",
                timestamp=NOW - 12 * 60)

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
        "discord_77": NOW - 4 * DAY + 21,                               # read before the compaction, nothing new
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

# Hermes sweeps a run's events this long after the run was created whenever nothing is listening,
# even while the run goes on: its later events are dropped, and the events answer 404 while its status
# stays (api_server_runs.py `_sweep_orphaned_runs_once`, api_server.py `_RUN_STREAM_TTL = 300`).
# `--run-stream-ttl` shortens it for a timing run. `--late-events` holds every run's events that long
# after its stream opens, as a stream that attached late (a slow network): what Hermes said meanwhile
# then arrives at once, each event with the time it was said.
RUN_STREAM = {"ttl": 300.0, "cut": 0, "late": 0.0}
# The API server's caps (api_server.py `_concurrency_limited_response`, hermes_state_runtime.py
# `ADMISSION_QUEUE_MAX`): at most `max_runs` runs live at once on the gateway (0 disables; Hermes's
# default is 10), then 429 `rate_limit_exceeded`; at most 32 runs queued in one chat, then 409
# `queue_full`, its message the bare reason. `POST /api/mock/run-caps {max_runs, queue_max}` lowers them.
RUN_CAPS = {"max_runs": 10, "queue_max": 32}
# `POST /api/mock/runs-down {seconds}`: a run's status answers 502 for that long (a proxy in front
# of a gateway too busy to answer) while the stored chats still read.
RUNS_DOWN = {"until": 0.0}


class Run:
    def __init__(self, run_id, session_id, text):
        self.id = run_id
        self.session_id = session_id
        self.text = text
        self.events = []
        self.created = time.time()
        self.subscribers = 0
        self.swept = False
        self.cond = threading.Condition()
        # A gateway restart killed it (`POST /api/mock/restart-gateway`): it stores, sends and changes
        # nothing more, and its status is what the restart left.
        self.killed = False
        self.status = "queued"
        self.output = ""
        self.error = None
        # Started under an Idempotency-Key: Hermes keeps its status over a restart
        # (api_server_runs.py `_durable_run_status`).
        self.durable = False
        self.stop = threading.Event()
        # The pending prompt as Hermes keeps it (session_pending_controls.py): kind, prompt_id,
        # execution_generation. An answer must name both, or it's refused.
        self.approval = None
        self.approval_choice = None
        self.generation = 1
        # Prompts dropped with an older generation, announced (`approval.settled`) the next time the
        # run is read, as Hermes's `PendingControls.snapshot` does.
        self.dropped = []
        self.admission_id = f"adm_{uuid.uuid4().hex[:12]}"
        self.terminal = False
        # Steers accepted and not read yet (`POST /v1/runs/{id}/steer`); read at the next step.
        self.steers = []

    @property
    def status(self):
        return self._status

    @status.setter
    def status(self, value):
        if not self.killed:
            self._status = value

    def kill(self):
        """A gateway restart under the run: as Hermes reads a run whose owner died, `interrupted`."""
        self.status = "interrupted"
        self.error = "The gateway restarted before this run settled."
        self.killed = True
        self.swept = True  # the events were the old process's: they answer 404
        self.events = []
        self.stop.set()
        self.finish()

    def is_swept(self):
        """Swept once nothing listened past the stream's lifetime (call with `cond` held)."""
        if not self.swept and self.subscribers == 0 and time.time() - self.created > RUN_STREAM["ttl"]:
            self.swept = True
            self.events = []
        return self.swept

    def emit(self, name, **fields):
        with self.cond:
            if self.killed or self.is_swept():
                return  # Hermes drops the events of a run whose stream it swept (`RunStream.put_event`)
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
    with LOCK:
        read, run.steers = run.steers, []
    for text in read:
        # Read with the tool's result, as Hermes does (`AIAgent.steer`).
        add_message(run.session_id, "user", text, display_kind="steer")
    return True


def wait_turn(run):
    """Waits, `queued`, while an earlier run of the chat is live (Hermes's FIFO)."""
    with LOCK:
        order = FIFO.setdefault(run.session_id, [])
        order.append(run.id)
        ahead = order[:order.index(run.id)]
    while not run.stop.is_set():
        if all(r not in RUNS or RUNS[r].terminal for r in ahead):
            return True
        time.sleep(0.1)
    return False


def agent_turn(run):
    sid, text = run.session_id, run.text
    if not wait_turn(run):
        # Stopped while it waited: only this run is cancelled; the ones behind it still run.
        run.status = "cancelled"
        run.emit("run.cancelled", completed=False, partial=False, interrupted=True)
        run.finish()
        return
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
            run.error = "⚠️ Provider authentication failed: Anthropic rejected the API key (401 invalid x-api-key)"
            run.emit("run.failed", error=run.error)
            return
        if "fail" in lowered:
            time.sleep(0.6)
            run.status = "failed"
            run.error = "Provider returned 500: upstream overloaded"
            run.emit("run.failed", error=run.error)
            return
        if "clarify" in lowered:
            clarify_turn(run, lowered)
        elif "heartbeat" in lowered:
            heartbeat_turn(run)
        elif "approve" in lowered:
            narration = "I'll clean the build folder first. "
            stream_text(run, narration)
            command = "rm -rf ./build && make release"
            choices = ["once", "deny", "session", "always"]

            legacy, timeout = "legacy" in lowered, "timeout" in lowered
            # How long Hermes waits, when it says (`PendingControls.register`'s `timeout_s`).
            wait = {"timeout_s": 20} if timeout else {}

            def ask():
                request_id = uuid.uuid4().hex
                run.approval = {"kind": "approval", "prompt_id": request_id, "execution_generation": run.generation,
                                "command": command, "description": "Recursive delete", "choices": choices, **wait}
                run.status = "waiting_for_approval"
                # The run's event is the prompt as Hermes projects it (session_api_turn.run_api_turn):
                # `request_id` for `prompt_id`, the allow_* flags, and its generation.
                run.emit("approval.request", command=command, description="Recursive delete", pattern_key="rm_rf",
                         pattern_keys=["rm_rf"], execution_generation=run.generation, request_id=request_id,
                         allow_session=True, allow_permanent=True, choices=["once", "session", "always", "deny"], **wait)
                return request_id

            request_id = ask()
            reask = None
            if "stale" in lowered:
                # The turn was claimed again (a restart, a drain): a new generation, so an answer
                # with the event's is refused stale_generation.
                run.generation += 1
                if "retry" in lowered:
                    # Never from Hermes: the same prompt under the new generation, to exercise the
                    # app's one retry.
                    run.approval["execution_generation"] = run.generation
                else:
                    # As Hermes does (PendingControls.snapshot): the prompt goes with its generation,
                    # announced only when something next reads the run, and the claimed turn asks
                    # again 30 s later. Older gateways never announce it.
                    if not legacy:
                        run.dropped.append((request_id, run.generation - 1))
                    run.approval = None
                    run.status = "running"
                    reask = time.time() + 30
            elsewhere = time.time() + 5 if "elsewhere" in lowered else None
            deadline = time.time() + 20 if timeout else None
            answered_here = False
            while run.approval_choice is None and not run.stop.is_set():
                if reask and time.time() > reask:
                    reask = None
                    request_id = ask()
                if elsewhere and time.time() > elsewhere:
                    # Allowed on another device (the WS viewer): Hermes takes the first answer.
                    run.approval_choice = "once"
                    break
                if deadline and time.time() > deadline:
                    # No answer in time: Hermes denies it.
                    break
                time.sleep(0.1)
            else:
                answered_here = run.approval_choice is not None
            if run.killed:
                return
            choice = run.approval_choice
            settled_generation = (run.approval or {}).get("execution_generation", run.generation)
            run.approval = None
            run.status = "running"
            if legacy:
                if answered_here:
                    run.emit("approval.responded", choice=choice, request_id=request_id, resolved=1)
            else:
                # However it ended (`PendingControls.snapshot`/`respond`), a Stop included: the prompt
                # and its generation.
                run.emit("approval.settled", prompt_id=request_id, execution_generation=settled_generation)
            add_message(sid, "assistant", narration.strip(), finish_reason="tool_calls",
                        tool_calls=[{"id": "call_x", "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": command})}}])
            if choice == "deny" or choice is None:
                run.emit("tool.started", tool="terminal", preview=command)
                run.emit("tool.completed", tool="terminal", duration=0.01, error=True, preview="BLOCKED: denied by user")
                add_message(sid, "tool", "BLOCKED: denied by user", tool_call_id="call_x", tool_name="terminal")
                answer = "Okay — I didn't touch the build folder. Let me know if you want me to try a safer cleanup."
            else:
                # Answered elsewhere, the command runs a while: this device's card is still up to tap.
                tool(run, "terminal", command, "Release build succeeded in 41.2s", 20 if elsewhere else 1.6)
                add_message(sid, "tool", json.dumps({"output": "Release build succeeded in 41.2s", "exit_code": 0}), tool_call_id="call_x", tool_name="terminal")
                answer = "Done. The release build **succeeded in 41.2 s** and the artifacts are in `./build/release`."
            out, ok = stream_text(run, answer)
            add_message(sid, "assistant", out, finish_reason="stop")
            run.output = out
        else:
            slow = "slow" in lowered
            # "marathon": six steps of 12 s, past a short `--run-stream-ttl` (a phone away meanwhile
            # comes back to a run whose events Hermes swept).
            marathon = "marathon" in lowered
            narration = "Let me look into that. "
            stream_text(run, narration)
            calls = [("web_search", {"query": text[:60]}, "1. Official docs\n2. Release notes\n3. Community thread", 1.4 if not slow else 4)]
            calls.append(("terminal", {"command": "uname -a && df -h /"}, "Darwin mini 27.0.0 arm64\n/dev/disk3s1  926Gi  412Gi  514Gi  45% /", 0.9 if not slow else 4))
            if slow:
                calls.append(("read_file", {"path": "~/projects/app/Package.swift"}, "// swift-tools-version: 6.2", 4))
            if marathon:
                calls = [(name, args, result, 12) for name, args, result, _ in calls]
                calls += [("read_file", {"path": f"~/projects/app/Sources/Part{i}.swift"}, f"// part {i}", 12) for i in range(1, 5)]
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
        if run.killed:
            pass
        elif run.stop.is_set():
            run.status = "cancelled"
            run.emit("run.cancelled", completed=False, partial=True, interrupted=True)
        else:
            run.status = "completed"
            with LOCK:
                unread, run.steers = run.steers, []
            run.emit("run.completed", completed=True, partial=False, interrupted=False, output=run.output,
                     **({"pending_steer": "\n".join(unread)} if unread else {}),
                     usage={"input_tokens": 1830, "output_tokens": 412, "total_tokens": 2242, "cache_read_tokens": 900, "cache_write_tokens": 0},
                     runtime={"provider": "openrouter", "model": "anthropic/claude-sonnet-4.6", "route_source": "global"})
    finally:
        run.finish()


# What Hermes ends every background-process wake with (gateway/run_notifications.py).
INTERNAL_NOTIFICATION_FOOTER = ("[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. "
                                "Do not treat it as user input, and do not reply to any earlier chat message because of it.]")


def heartbeat_turn(run):
    """"heartbeat": one reply that makes four tool calls, with narration and reasoning between them, and
    starts a background process. As Hermes does once the chat is idle (tools/process_registry_notifications.py,
    `format_process_notification`), the process then wakes the chat with two heartbeats, each answered with
    silence, and its completion, answered with a reply: `internal_notification` rows ending in the footer.
    Only the two replies are messages (docs/inbox.md §1 Counting)."""
    sid = run.session_id
    steps = [
        ("I'll start the test suite in the background. ", [("terminal", {"command": "make test", "background": True},
                                                              json.dumps({"session_id": "proc_7", "status": "started"}))]),
        ("While it runs, let me read the config. ", [("read_file", {"path": "Makefile"}, "test:\n\tswift test"),
                                                     ("search_files", {"pattern": "XCTest"}, "3 matches")]),
        ("", [("process", {"action": "poll", "session_id": "proc_7"}, json.dumps({"status": "running"}))]),
    ]
    for index, (narration, calls) in enumerate(steps):
        if narration:
            stream_text(run, narration)
        ids = [f"call_hb{index}_{n}" for n in range(len(calls))]
        add_message(sid, "assistant", narration.strip(), finish_reason="tool_calls",
                    reasoning=None if narration else "Check it started cleanly.",
                    tool_calls=[{"id": i, "type": "function", "function": {"name": n, "arguments": json.dumps(a)}}
                                for i, (n, a, _) in zip(ids, calls)])
        for call_id, (name, args, result) in zip(ids, calls):
            if not tool(run, name, next(iter(args.values())), result, 0.6):
                return
            add_message(sid, "tool", result, tool_call_id=call_id, tool_name=name)
    out, _ = stream_text(run, "The suite is running. I'll tell you how it went.")
    add_message(sid, "assistant", out, finish_reason="stop")
    run.output = out

    def wakes():
        for seq, age in ((1, "6s"), (2, "12s")):
            time.sleep(6)
            add_message(sid, "user", f"[Background process proc_7 heartbeat #{seq} — still running after {age} (next in 6s "
                        "when there is new output; you will also be told when it exits).\nCommand: make test\n"
                        f"Output since last heartbeat:\nTest Suite 'All tests' started]\n\n{INTERNAL_NOTIFICATION_FOOTER}",
                        display_kind="internal_notification")
            add_message(sid, "assistant", "[SILENT]", finish_reason="stop", timestamp=time.time() + 0.5)
        time.sleep(6)
        add_message(sid, "user", "[IMPORTANT: Background process proc_7 completed normally (exit code 0).\nCommand: make test\n"
                    f"Output:\nAll 412 tests passed]\n\n{INTERNAL_NOTIFICATION_FOOTER}", display_kind="internal_notification")
        add_message(sid, "assistant", "All 412 tests passed.", finish_reason="stop", timestamp=time.time() + 0.5)
    threading.Thread(target=wakes, daemon=True).start()


def clarify_turn(run, lowered):
    """A question mid-turn, as Hermes asks one over the API server: its clarify step runs, the
    prompt goes into the run's pending controls (`session_pending_controls.register_clarify`) and,
    as a `clarify.request`, onto the run's events (`session_api_turn.observe_api_controls`); when
    Hermes stops waiting it says `clarify.settled`. One question per prompt; the first pick carries
    "(Recommended)" and a chat app's turn ends the question with the skip hint."""
    sid = run.session_id
    quiet, elsewhere, timeout = "quiet" in lowered, "elsewhere" in lowered, "timeout" in lowered
    narration = "Before I deploy, one thing to settle. "
    stream_text(run, narration)
    if "multi" in lowered:
        question, choices, multi = "Which regions should get the release?", ["Europe (Recommended)", "US East", "Asia Pacific"], True
    elif "open" in lowered:
        question, choices, multi = "What should the release notes lead with?", [], False
    else:
        question, choices, multi = "Where should I deploy the build?", ["Staging (Recommended)", "Production"], False
    args = {"questions": [{"question": question, **({"choices": [c.replace(" (Recommended)", "") for c in choices]} if choices else {}),
                           **({"multi_select": True} if multi else {})}]}
    add_message(sid, "assistant", narration.strip(), finish_reason="tool_calls",
                tool_calls=[{"id": "call_q", "type": "function", "function": {"name": "clarify", "arguments": json.dumps(args)}}])
    run.emit("tool.started", tool="clarify", preview=question[:80])
    prompt_id = uuid.uuid4().hex
    prompt = {"kind": "clarify", "prompt_id": prompt_id, "execution_generation": run.generation,
              "question": question + '\nReply "skip" to skip this question.', "choices": choices, "multi_select": multi}
    if timeout:
        prompt["timeout_s"] = 20
    run.approval = prompt
    if not quiet:
        run.emit("clarify.request", **prompt)
    deadline = time.time() + (20 if timeout else 3600)
    other = time.time() + 5 if elsewhere else None
    outcome = "submitted"
    while run.approval_choice is None and not run.stop.is_set():
        if other and time.time() > other:
            # Answered on another device (the WS viewer): Hermes takes the first answer.
            run.approval_choice = (json.dumps([choices[-1]]) if multi else choices[-1]) if choices else "Speed"
        if time.time() > deadline:
            outcome = "timed_out"
            break
        time.sleep(0.1)
    answer = run.approval_choice
    run.approval, run.approval_choice = None, None
    if not quiet:
        run.emit("clarify.settled", prompt_id=prompt_id, execution_generation=run.generation)
    if run.stop.is_set():
        return
    if outcome == "timed_out":
        status, said = "unanswered", None
    elif not answer:
        status, said = "skipped", None
    else:
        # As the clarify tool reads it (`_clean_answer`): picks as a list, the label stripped.
        status, said = "answered", answer
        if multi:
            try:
                said = json.loads(answer)
            except json.JSONDecodeError:
                said = [answer]
            said = [str(item).replace(" (Recommended)", "") for item in (said if isinstance(said, list) else [said])]
        else:
            said = answer.replace(" (Recommended)", "")
    result = json.dumps({"responses": [{"question": question, "choices_offered": [c.replace(" (Recommended)", "") for c in choices] or None,
                                        "status": status, "user_response": said}], "outcome": outcome}, ensure_ascii=False)
    run.emit("tool.completed", tool="clarify", duration=0.01, error=False, preview=result[:500])
    add_message(sid, "tool", result, tool_call_id="call_q", tool_name="clarify")
    if said is None:
        reply = "No answer, so I'll hold the deploy. Say where when you're ready."
    elif multi:
        reply = f"Rolling the release out to **{', '.join(said)}**."
    else:
        reply = f"Got it: **{said}**. Deploying now."
    out, ok = stream_text(run, reply)
    add_message(sid, "assistant", out, finish_reason="stop")
    run.output = out


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

    def error(self, status, message, code=None, kind="invalid_request_error", extra=None):
        self.send_json(status, {"error": {"message": message, "type": kind, "param": None, "code": code}}, extra)

    def respond_run(self, run, body, kind):
        """POST /v1/runs/{id}/approval|clarify as Hermes answers it (api_server_authority_runs.respond_run):
        exactly {request_id, execution_generation, choice|answer}; a refusal's message is its bare reason."""
        field = "choice" if kind == "approval" else "answer"
        if not isinstance(body, dict) or set(body) != {"request_id", "execution_generation", field}:
            return self.error(400, "invalid_params", "invalid_params")
        generation = body["execution_generation"]
        if run.terminal or run.status not in ("running", "waiting_for_approval") or type(generation) is not int \
                or generation != run.generation:
            return self.error(409, "stale_generation", "stale_generation")
        prompt = run.approval
        # Answered a moment ago: Hermes no longer lists it, though the turn hasn't moved on yet.
        if not prompt or run.approval_choice is not None or prompt["prompt_id"] != body["request_id"] or prompt["kind"] != kind:
            return self.error(409, "approval_not_pending", "approval_not_pending")
        if not isinstance(body[field], str) or (kind == "approval" and body[field] not in prompt["choices"]):
            return self.error(400, "invalid_params", "invalid_params")
        run.approval_choice = body[field]
        return self.send_json(200, {"run_id": run.id, "status": "resolved", "prompt_id": prompt["prompt_id"]})

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
    def hooked(self, method, path, query):
        """A route another module adds (browser_control.py): it checks the key itself, if at all."""
        hook = ROUTES.get((method, path))
        return bool(hook) and hook(self, query)

    def do_GET(self):
        path, query = self.route("GET")
        if self.hooked("GET", path, query):
            return
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
        if m and time.time() < RUNS_DOWN["until"]:
            return self.error(502, "Bad Gateway", "bad_gateway")
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, f"Run not found: {m.group(1)}", "run_not_found")
            # As Hermes projects a run (api_server_authority_runs.run_projection): its generation and
            # the prompts it waits on, never a separate `approval`. Reading them settles the prompts
            # an older generation left (`PendingControls.snapshot`).
            while run.dropped and not run.terminal:
                prompt_id, generation = run.dropped.pop(0)
                run.emit("approval.settled", prompt_id=prompt_id, execution_generation=generation)
            pending = [dict(run.approval)] if run.approval else []
            body = {"object": "hermes.run", "run_id": run.id, "status": run.status, "session_id": run.session_id,
                    "admission_id": run.admission_id, "execution_generation": run.generation, "pending_controls": pending,
                    "model": "hermes-agent", "output": run.output if run.terminal else None}
            if run.error:
                body["error"] = run.error
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
        with run.cond:
            if run.is_swept():
                # The run goes on (its status says so), but its events are gone: 404, as Hermes.
                return self.error(404, f"Run not found: {run_id}", "run_not_found")
            run.subscribers += 1
        try:
            self.stream_run(run, query)
        finally:
            with run.cond:
                run.subscribers -= 1

    def stream_run(self, run, query):
        cut = RUN_STREAM["cut"]
        raw = self.headers.get("Last-Event-ID") or query.get("last_seq")
        last = int(raw) if raw is not None else -1
        self.start_sse()
        try:
            self.wfile.write(b": open\n\n")
            self.wfile.flush()
            held = time.time() + RUN_STREAM["late"]
            while time.time() < held:
                if self.client_left() or RUN_STREAM["cut"] != cut:
                    return
                time.sleep(0.1)
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
                if self.client_left() or RUN_STREAM["cut"] != cut:
                    return  # the run continues detached, with nothing listening (it may be swept)
                if time.time() - idle > 10:
                    STARVE.wait()
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    idle = time.time()
        except (BrokenPipeError, ConnectionResetError):
            return  # the run continues detached

    def client_left(self):
        """The client closed the stream (aiohttp notices at once; a blocking write only at the next one)."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
        except OSError:
            return True

    def do_POST(self):
        path, query = self.route("POST")
        if self.hooked("POST", path, query):
            return
        if path == "/api/mock/starve":
            # Mock-only (starve.py): the whole machine starved, this gateway and the backend with it.
            return self.send_json(200, STARVE.configure(self.body()))
        if path == "/api/mock/drop-run-streams":
            # Mock-only: every run's open event stream is closed, as when a phone's suspended app loses
            # its connections (a simulator keeps them open); the runs go on with nothing listening.
            with LOCK:
                RUN_STREAM["cut"] += 1
            return self.send_json(200, {"dropped": True})
        if path == "/api/mock/restart-gateway":
            # Mock-only: the gateway restarts under its runs (`hermes gateway restart`, a crash). Each run
            # dies where it is: it stores nothing more and its events go. A run started under an
            # Idempotency-Key keeps its status, `interrupted` if it hadn't ended (the app's runs are);
            # one without is forgotten (404). `{"forget": true}`: every run is forgotten, as an older
            # Hermes that kept no status over a restart.
            forget = bool(self.body().get("forget"))
            with LOCK:
                for run in list(RUNS.values()):
                    if not run.terminal:
                        run.kill()
                    if forget or not run.durable:
                        del RUNS[run.id]
                    else:
                        run.swept = True
                        run.events = []
                FIFO.clear()
                kept = len(RUNS)
            return self.send_json(200, {"ok": True, "kept": kept})
        if path == "/api/mock/runs-down":
            seconds = float(self.body().get("seconds") or 0)
            with LOCK:
                RUNS_DOWN["until"] = time.time() + seconds
            return self.send_json(200, {"ok": True, "seconds": seconds})
        if path == "/api/mock/run-caps":
            body = self.body()
            with LOCK:
                for key in ("max_runs", "queue_max"):
                    if isinstance(body.get(key), int) and body[key] >= 0:
                        RUN_CAPS[key] = body[key]
                caps = dict(RUN_CAPS)
            return self.send_json(200, caps)
        STARVE.wait()
        if not self.authorized():
            return
        body = self.body()
        if path == "/api/sessions":
            sid = body.get("id") or body.get("session_id") or f"api_{int(time.time())}_{uuid.uuid4().hex[:8]}"
            with LOCK:
                # Hermes refuses an id it has, or one that was deleted (create_conflict).
                if sid in SESSIONS:
                    return self.error(409, f"Session already exists: {sid}", "session_exists")
                if sid in DELETED:
                    return self.error(409, f"Session was deleted; its id cannot be reused: {sid}", "session_deleted")
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
            key = self.headers.get("Idempotency-Key")
            with LOCK:
                if key and key in IDEMPOTENCY:
                    # The same key: the run it started, with its live status; another body is a conflict
                    # (api_server_run_idempotency.py).
                    first_body, run_id = IDEMPOTENCY[key]
                    if first_body != body:
                        return self.error(409, "Idempotency-Key was used with a different request", "idempotency_key_conflict")
                    return self.send_json(202, {"run_id": run_id, "status": RUNS[run_id].status, "replayed": True})
                live = [r for r in RUNS.values() if not r.terminal]
                if RUN_CAPS["max_runs"] and len(live) >= RUN_CAPS["max_runs"]:
                    return self.error(429, f"Too many concurrent runs (max {RUN_CAPS['max_runs']})", "rate_limit_exceeded",
                                      kind="rate_limit_error", extra={"Retry-After": "1"})
                if sum(1 for r in live if r.session_id == sid and r.status == "queued") >= RUN_CAPS["queue_max"]:
                    # A store refusal: its message is the bare reason (api_server_authority_runs.py).
                    return self.error(409, "queue_full", "queue_full")
                run = Run(f"run_{uuid.uuid4().hex}", sid, text if isinstance(text, str) else str(text))
                run.durable = bool(key)
                RUNS[run.id] = run
                if key:
                    IDEMPOTENCY[key] = (body, run.id)
            threading.Thread(target=agent_turn, args=(run,), daemon=True).start()
            # `started` even for a run queued behind another: only GET says `queued` (api_server_runs.py).
            return self.send_json(202, {"run_id": run.id, "status": "started", "replayed": False})
        m = re.fullmatch(r"/v1/runs/([^/]+)/steer", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, "Run not found", "run_not_found")
            text = (body.get("input") or body.get("text") or "").strip()
            if not text:
                return self.error(400, "Missing 'input' field")
            if run.status != "running" or run.stop.is_set():
                # Queued, waiting for an approval, stopping or over: nothing to steer (runs.py).
                return self.error(409, f"Run is not currently accepting steer input: {run.id}", "run_not_accepting_steer")
            with LOCK:
                run.steers.append(text)
            run.emit("run.steered", text=text)
            return self.send_json(200, {"run_id": run.id, "accepted": True})
        m = re.fullmatch(r"/v1/runs/([^/]+)/stop", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, "Run not found", "run_not_found")
            if run.terminal:
                return self.error(409, "Run is not active", "run_not_active")
            run.stop.set()
            return self.send_json(200, {"run_id": run.id, "status": "stopping"})
        m = re.fullmatch(r"/v1/runs/([^/]+)/(approval|clarify)", path)
        if m:
            run = RUNS.get(m.group(1))
            if not run:
                return self.error(404, f"Run not found: {m.group(1)}", "run_not_found")
            return self.respond_run(run, body, m.group(2))
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
            archiving = body.get("archived") is True and not s.get("archived")
            with LOCK:
                for key in ("title", "pinned", "archived", "hidden", "end_reason"):
                    if key in body:
                        s[key] = body[key]
                if body.get("pinned"):
                    s["hidden"] = False
                if "unread" in body:
                    s["_last_read_at"] = 0.0 if body["unread"] else time.time()
            if archiving:
                session_gone([m.group(1)], "archive")
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
            DELETED.add(m.group(1))
            MESSAGES.pop(m.group(1), None)
            session_gone([m.group(1)], "delete")
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
    parser.add_argument("--run-stream-ttl", type=float, default=300, metavar="SECONDS",
                        help="sweep a run's events this long after it was created when nothing listens, even mid-run "
                             "(Hermes: 300); its status stays and its events answer 404")
    parser.add_argument("--late-events", type=float, default=0, metavar="SECONDS",
                        help="hold every run's events this long after its stream opens, as a stream that attached late")
    args = parser.parse_args()
    if args.starve:
        STARVE.start(float("inf"), gap=STARVE.parse_gap(args.starve))
    RUN_STREAM["ttl"] = args.run_stream_ttl
    RUN_STREAM["late"] = args.late_events
    Handler.key = args.key
    seed()
    install_widgets(sys.modules[__name__], enabled=not args.no_widgets)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"[mock-hermes] listening on http://{args.host}:{args.port} (key: {args.key})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
