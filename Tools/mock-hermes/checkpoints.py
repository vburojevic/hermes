"""Checkpoints for the combined mock (`docs/checkpoints.md`): rollback.list, rollback.diff and
rollback.restore, session.undo and session.close, and GET/PUT /api/config for checkpoints.enabled.

Shaped like `hermes serve` (tui_gateway/methods_tools.py, tools/checkpoint_manager.py):
  - A chat's agent reads checkpoints.enabled when it is built: a runtime keeps the value it started
    with; PUT /api/config changes it for new or reattached ones (session.close, then session.resume).
  - Hermes saves the folder before a turn's first file write; the message names the tool
    ("before patch"), never the turn.
  - A whole-folder restore overwrites the files (files created later stay), drops the chat's newest
    turn, and first saves a "pre-rollback snapshot". Refused while a turn runs (4009). One file can be
    restored any time and leaves the chat alone.
  - rollback.diff caps the diff at 4000 characters.

Demo data: Hermes App's folder (~/Code/hermes-app) and the chat "Reconnect and backoff" with three
turns that edited files, four checkpoints (the last turn of yesterday also ran `rm -rf .build`), at
14:31, 13:02 and yesterday 18:40 as in the designs (a day earlier before 14:45). Restoring also
reports Models/weights.bin as too large to checkpoint (`skipped_oversize`).

Switches (socket, no auth): mock.checkpoints {"enabled": bool, "now": bool, "busy": bool,
"container": bool} — "now" applies `enabled` to chats already open; "busy" makes every whole restore
answer 4009; "container" refuses diff and restore as for a docker backend. mock.checkpoints.reset.
`--checkpoints off` starts the gateway with checkpoints off.
"""

import difflib
import hashlib
import json
import os
import threading
import time
import uuid

B = None  # backend.py's module globals
G = None  # server.py
C = None  # chats.py

HOME = os.path.expanduser("~")
FOLDER = f"{HOME}/Code/hermes-app"
CHAT_ID = "prj_undo"
CHAT_TITLE = "Reconnect and backoff"
DIFF_LIMIT = 4000
LOCK = threading.RLock()

STATE = {"enabled": True, "busy": False, "container": False}
STORE = {}  # folder -> [checkpoint], newest first: {hash, ts, message, files}


def install(backend_globals, gateway_module, chats_module, enabled=True):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    STATE["enabled"] = enabled
    STATE["initially"] = enabled
    methods = B["METHODS"]
    methods["rollback.list"] = rollback_list
    methods["rollback.diff"] = rollback_diff
    methods["rollback.restore"] = rollback_restore
    methods["session.undo"] = session_undo
    methods["session.close"] = session_close
    methods["mock.checkpoints"] = mock_checkpoints
    methods["mock.checkpoints.reset"] = lambda params: (seed(), {"ok": True})[1]
    B["HTTP_ROUTES"][("GET", "/api/config")] = get_config
    B["HTTP_ROUTES"][("PUT", "/api/config")] = put_config

    # A runtime keeps the setting its agent was built with.
    original_new_runtime = B["new_runtime"]

    def new_runtime(stored, profile, **kwargs):
        sid = original_new_runtime(stored, profile, **kwargs)
        B["RUNTIME"][sid]["checkpoints"] = STATE["enabled"]
        return sid

    B["new_runtime"] = new_runtime

    # Hermes saves the folder before a turn's first file write.
    original_tool = C.tool

    def tool(sid, stored, name, args, seconds, **kwargs):
        if name in ("write_file", "patch"):
            take(sid, stored, name, args, kwargs.get("extra") or {})
        return original_tool(sid, stored, name, args, seconds, **kwargs)

    C.tool = tool

    original_start = B["start_turn"]

    def start_turn(sid, text, runner):
        if sid in B["RUNTIME"]:
            B["RUNTIME"][sid]["turn_started"] = time.time()
        return original_start(sid, text, runner)

    B["start_turn"] = start_turn
    seed()


# ---------------------------------------------------------------- demo data

def lines(text):
    return text.strip("\n").split("\n")


RECONNECT_OLD = lines("""
func reconnect() async {
    try await socket.open()
    await resume()
}

func resume() async {
    state = .connected
    attempt = 0
}
""")

RECONNECT_NEW = lines("""
func reconnect() async {
    try await withBackoff(max: 5) {
        try await socket.open()
    }
    await resume()
}

/// The Mac woke: the old socket is gone, so start over with a fresh backoff.
func didWake() async {
    backoff.reset()
    socket = Socket(url: endpoint)
    await reconnect()
}

func resume() async {
    state = .connected
    attempt = 0
    lastConnected = .now
}

private var backoff = Backoff(base: .milliseconds(250), cap: .seconds(8))
private var lastConnected: ContinuousClock.Instant?

extension Reconnect {
    var isStale: Bool {
        guard let lastConnected else { return true }
        return lastConnected.duration(to: .now) > .seconds(30)
    }
}
""")

TESTS_NEW = lines("""
import Testing
@testable import Sync

@Test func reconnectsAfterWake() async { #expect(await Reconnect.afterWake().state == .connected) }
""")

BACKOFF_OLD = lines("""
func next() -> Duration {
    attempt += 1
    return base * attempt
""")

BACKOFF_NEW = lines("""
func next() -> Duration {
    attempt += 1
    let delay = base * (1 << min(attempt, 6))
    return min(delay, cap) + jitter()
}

mutating func reset() {
    attempt = 0
}
""")

SYNC_OLD = lines("""
func send(_ change: Change) async throws {
    try await socket.send(change)
}

""")

SYNC_NEW = lines("""
func send(_ change: Change) async throws {
    try await withBackoff(max: 5) {
        try await socket.send(change)
    }
}

/// Retries with exponential backoff and jitter; gives up after `max` attempts.
func withBackoff<T>(max: Int, _ body: () async throws -> T) async throws -> T {
    var backoff = Backoff(base: .milliseconds(250), cap: .seconds(8))
    var lastError: (any Error)?
    for _ in 0..<max {
        do {
            return try await body()
        } catch {
            lastError = error
            try await Task.sleep(for: backoff.next())
        }
    }
    throw lastError ?? CancellationError()
}

enum SyncError: Error {
    case gaveUp(attempts: Int)
}

extension SyncClient {
    var isRetrying: Bool { backoff.attempt > 0 }
}

private var backoff = Backoff(base: .milliseconds(250), cap: .seconds(8))
""")

BACKOFF_V1_OLD = lines("""
struct Backoff {
""")

BACKOFF_V1_NEW = lines("""
/// How long to wait between attempts: doubles each time, up to a cap, with jitter.
struct Backoff {
    var base: Duration
    var cap: Duration
    var attempt = 0

    init(base: Duration, cap: Duration) {
        self.base = base
        self.cap = cap
    }

    func jitter() -> Duration {
        .milliseconds(Int.random(in: 0...100))
    }

func next() -> Duration {
    attempt += 1
    return base * attempt
}
}

extension Duration {
    static func * (lhs: Duration, rhs: Int) -> Duration {
        lhs * Double(rhs)
    }
}

// Used by SyncClient and Reconnect.
""")

RESOLVED_OLD = lines("""
      "identity" : "swift-collections",
      "location" : "https://github.com/apple/swift-collections",
      "revision" : "9bf03ff58ce34478e66aaee630e491823326fd06",
""")

RESOLVED_NEW = lines("""
      "identity" : "swift-collections",
      "location" : "https://github.com/apple/swift-collections",
      "revision" : "671108c96644956dddcd89dd59c203dcdb36cec7",
""")


def record(path, old, new, created=False):
    return {"path": path, "old": old, "new": new, "created": created}


# The folder's files before the first turn: each edit replaces its `old` block in one of these.
BASE = {
    "Sources/Sync/Reconnect.swift": ["import Foundation", "", "/// Reconnects after the Mac wakes.", "struct Reconnect {",
                                     "    var state: State = .idle", "    var attempt = 0", ""] + RECONNECT_OLD + ["}"],
    "Sources/Sync/Backoff.swift": ["import Foundation", ""] + BACKOFF_V1_OLD + ["}"],
    "Sources/Sync/SyncClient.swift": ["import Foundation", "", "actor SyncClient {", "    let socket: Socket", ""] + SYNC_OLD + ["}"],
    "Package.resolved": ["{", '  "pins" : [', "    {"] + RESOLVED_OLD + ['      "version" : "1.2.0"', "    }", "  ]", "}"],
    "README.md": ["# Hermes App", "", "The Hermes client for iPhone, iPad and Mac."],
}


def apply(files, change):
    """One edit: replace the block (or write the new file)."""
    current = files.get(change["path"])
    if current is None or not change["old"]:
        files[change["path"]] = list(change["new"])
        return
    for i in range(len(current) - len(change["old"]) + 1):
        if current[i:i + len(change["old"])] == change["old"]:
            files[change["path"]] = current[:i] + list(change["new"]) + current[i + len(change["old"]):]
            return
    files[change["path"]] = current + list(change["new"])


def day_base():
    """Today, or yesterday when it isn't 14:45 yet, so 14:31 is always in the past."""
    now = time.localtime()
    midnight = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, 0, 0, 0, 0, 0, -1))
    return midnight if now.tm_hour * 60 + now.tm_min >= 14 * 60 + 45 else midnight - 86400


def at(base, hour, minute, second=0):
    return base + hour * 3600 + minute * 60 + second


def seed():
    """The chat, the folder's files and its four checkpoints."""
    base = day_base()
    yesterday = base - 86400
    turns = [
        # (user time, user text, [(tool, args, edit, seconds after the message)], answer)
        (at(yesterday, 18, 39, 40), "Bump swift-collections", [
            ("terminal", {"command": "rm -rf .build"}, None, 30),
            ("patch", {"path": "Package.resolved"}, record("Package.resolved", RESOLVED_OLD, RESOLVED_NEW), 92),
        ], "Bumped swift-collections to 1.3.0 and cleared the build folder. All tests pass."),
        (at(base, 13, 1, 40), "Add backoff to the sync client", [
            ("patch", {"path": "Sources/Sync/SyncClient.swift"}, record("Sources/Sync/SyncClient.swift", SYNC_OLD, SYNC_NEW), 30),
            ("patch", {"path": "Sources/Sync/Backoff.swift"}, record("Sources/Sync/Backoff.swift", BACKOFF_V1_OLD, BACKOFF_V1_NEW), 34),
        ], "The sync client now retries with exponential backoff (up to 5 attempts, with jitter). The policy lives in Backoff.swift."),
        (at(base, 14, 30, 20), "Fix the reconnect after sleep", [
            ("patch", {"path": "Sources/Sync/Reconnect.swift"}, record("Sources/Sync/Reconnect.swift", RECONNECT_OLD, RECONNECT_NEW), 47),
            ("write_file", {"path": "Tests/ReconnectTests.swift"}, record("Tests/ReconnectTests.swift", [], TESTS_NEW, created=True), 52),
            ("patch", {"path": "Sources/Sync/Backoff.swift"}, record("Sources/Sync/Backoff.swift", BACKOFF_OLD, BACKOFF_NEW), 58),
            ("terminal", {"command": "swift test --parallel"}, None, 70),
        ], "Fixed. The socket now reconnects with backoff when the Mac wakes, and a new test covers it. swift test passes (240 of 240)."),
    ]
    files = {path: list(content) for path, content in BASE.items()}
    checkpoints = []
    with G.LOCK:
        G.SESSIONS.pop(CHAT_ID, None)
        G.MESSAGES.pop(CHAT_ID, None)
        last = turns[-1][0] + 120
        G.session_row(CHAT_ID, CHAT_TITLE, "hermes_app", turns[0][0], last, "Fix the reconnect after sleep",
                      model="anthropic/claude-sonnet-4.6")
        session = G.SESSIONS[CHAT_ID]
        session["_cwd"], session["_branch"] = FOLDER, "main"
        for when, text, calls, answer in turns:
            G.add_message(CHAT_ID, "user", text, timestamp=when)
            saved_in_turn = False
            for name, args, change, after in calls:
                destructive = name == "terminal" and args["command"].startswith("rm ")
                # Hermes saves before a file write or a destructive command, once per loop step.
                if change or destructive:
                    if not saved_in_turn or destructive or name == "patch" and after - calls[0][3] > 60:
                        message = f"before terminal: {args['command']}" if destructive else f"before {name}"
                        checkpoints.append(new_checkpoint(when + after - 2, message, files))
                        saved_in_turn = True
                call = f"call_{uuid.uuid4().hex[:8]}"
                full = dict(args)
                if change and name == "patch":
                    full.update(old_string="\n".join(change["old"]), new_string="\n".join(change["new"]))
                elif change:
                    full["content"] = "\n".join(change["new"])
                G.add_message(CHAT_ID, "assistant", "", timestamp=when + after - 1, finish_reason="tool_calls",
                              tool_calls=[{"id": call, "type": "function", "function": {"name": name, "arguments": json.dumps(full)}}])
                if change:
                    apply(files, change)
                output = "240 of 240 passed" if "test" in args.get("command", "") else ""
                result = {"success": True} if change else {"output": output, "exit_code": 0}
                G.add_message(CHAT_ID, "tool", json.dumps(result), timestamp=when + after, tool_call_id=call, tool_name=name)
            G.add_message(CHAT_ID, "assistant", answer, timestamp=when + 110, finish_reason="stop")
    with LOCK:
        STORE.clear()
        FILES.clear()
        STORE[FOLDER] = sorted(checkpoints, key=lambda c: c["ts"], reverse=True)
        FILES[FOLDER] = files
        STATE.update(enabled=STATE.get("initially", True), busy=False, container=False)
    for runtime in B["RUNTIME"].values():
        runtime["checkpoints"] = STATE["enabled"]


FILES = {}  # folder -> {path: [lines]}: the files now


def new_checkpoint(ts, message, files):
    digest = hashlib.sha1(f"{ts}{message}{uuid.uuid4()}".encode()).hexdigest()
    return {"hash": digest, "ts": ts, "message": message, "files": {p: list(c) for p, c in files.items()}}


# ---------------------------------------------------------------- diffs

def diff_against(checkpoint, now):
    """`git diff <checkpoint> --cached`: the checkpoint on the minus side, the files now on the plus."""
    sections, rows, added, removed = [], [], 0, 0
    for path in sorted(set(checkpoint["files"]) | set(now)):
        old, new = checkpoint["files"].get(path), now.get(path)
        if old == new:
            continue
        body = list(difflib.unified_diff(old or [], new or [], lineterm="", n=3))[2:]
        plus = sum(1 for line in body if line.startswith("+"))
        minus = sum(1 for line in body if line.startswith("-"))
        head = [f"diff --git a/{path} b/{path}"]
        if old is None:
            head += ["new file mode 100644", "index 0000000..1a2b3c4", "--- /dev/null", f"+++ b/{path}"]
        elif new is None:
            head += ["deleted file mode 100644", "index 1a2b3c4..0000000", f"--- a/{path}", "+++ /dev/null"]
        else:
            head += ["index 4d5e6f7..8a9b0c1 100644", f"--- a/{path}", f"+++ b/{path}"]
        sections.append("\n".join(head + body))
        rows.append(f" {path} | {plus + minus} {'+' * min(plus, 30)}{'-' * min(minus, 30)}")
        added, removed = added + plus, removed + minus
    if rows:
        rows.append(f" {len(rows)} file{'s' if len(rows) != 1 else ''} changed, {added} insertions(+), {removed} deletions(-)")
    return "\n".join(rows), "\n".join(sections)


# ---------------------------------------------------------------- methods

def runtime_of(params):
    sid, runtime = B["runtime_for"](params)
    with G.LOCK:
        cwd = (G.SESSIONS.get(runtime["stored"]) or {}).get("_cwd") or HOME
    return sid, runtime, cwd


def enabled_for(runtime):
    return runtime.get("checkpoints", STATE["enabled"])


def find(cwd, ref):
    checkpoints = STORE.get(cwd) or []
    if ref.isdigit() and len(ref) < 7:
        index = int(ref) - 1
        if not 0 <= index < len(checkpoints):
            raise B["RPCError"](5022, f"Invalid checkpoint number. Use 1-{len(checkpoints)}.")
        return checkpoints[index]
    return next((c for c in checkpoints if c["hash"].startswith(ref)), None)


def container_reason():
    return "Checkpoints are not taken for terminal.backend=docker: file paths belong to the container, not this host."


def rollback_list(params):
    _sid, runtime, cwd = runtime_of(params)
    if not enabled_for(runtime):
        return {"enabled": False, "checkpoints": []}
    with LOCK:
        rows = [{"hash": c["hash"], "timestamp": iso(c["ts"]), "message": c["message"]} for c in STORE.get(cwd) or []]
    return {"enabled": True, "checkpoints": rows[:20]}


def rollback_diff(params):
    _sid, _runtime, cwd = runtime_of(params)
    if not params.get("hash"):
        raise B["RPCError"](4014, "hash required")
    if STATE["container"]:
        raise B["RPCError"](5022, container_reason())
    with LOCK:
        checkpoint = find(cwd, params["hash"])
        if checkpoint is None:
            return {"stat": "", "diff": ""}  # the gateway ignores a failed diff
        stat, diff = diff_against(checkpoint, FILES.get(cwd) or {})
    return {"stat": stat, "diff": diff[:DIFF_LIMIT]}


def rollback_restore(params):
    _sid, runtime, cwd = runtime_of(params)
    ref, file_path = params.get("hash"), params.get("file_path")
    if not ref:
        raise B["RPCError"](4014, "hash required")
    with B["LOCK"]:
        running = runtime["running"]
    if not file_path and (running or STATE["busy"]):
        raise B["RPCError"](4009, "session busy — Hermes is still replying. Stop the current reply first "
                                  "(Stop button, or Ctrl+C in a terminal), then run /rollback restore.")
    if STATE["container"]:
        return {"success": False, "error": container_reason()}
    with LOCK:
        checkpoint = find(cwd, ref)
        if checkpoint is None:
            return {"success": False, "error": f"Checkpoint '{ref}' not found"}
        now = FILES.setdefault(cwd, {})
        if file_path and file_path not in checkpoint["files"]:
            return {"success": False, "error": f"error: pathspec '{file_path}' did not match any file(s) known to git"}
        # The files as they are now, so the restore itself can be undone (skipped when nothing changed).
        latest = STORE[cwd][0] if STORE.get(cwd) else None
        if latest is None or latest["files"] != now:
            STORE[cwd].insert(0, new_checkpoint(time.time(), f"pre-rollback snapshot (restoring to {checkpoint['hash'][:8]})", now))
        # `git checkout <hash> -- <path or .>`: files the checkpoint has are overwritten; files
        # created after it stay.
        for path, content in checkpoint["files"].items():
            if file_path is None or path == file_path:
                now[path] = list(content)
    result = {"success": True, "restored_to": checkpoint["hash"][:8], "reason": checkpoint["message"], "directory": cwd}
    if file_path:
        result["file"] = file_path
        return result
    # Kept as it was: over the size limit, never saved.
    result["skipped_oversize"] = ["Models/weights.bin"]
    result["history_removed"] = drop_last_turn(runtime["stored"])
    return result


def session_undo(params):
    _sid, runtime = B["runtime_for"](params)
    with B["LOCK"]:
        if runtime["running"]:
            raise B["RPCError"](4009, "session busy — Hermes is still replying. Stop the current reply first, then undo.")
    return {"removed": drop_last_turn(runtime["stored"])}


def drop_last_turn(stored):
    """The newest user message and everything after it."""
    with G.LOCK:
        rows = G.MESSAGES.get(stored) or []
        users = [i for i, row in enumerate(rows) if row["role"] == "user"]
        if not users:
            return 0
        removed = len(rows) - users[-1]
        del rows[users[-1]:]
        session = G.SESSIONS.get(stored)
        if session:
            session["message_count"] = len(rows)
        return removed


def session_close(params):
    sid = params.get("session_id") or ""
    with B["LOCK"]:
        runtime = B["RUNTIME"].pop(sid, None)
    return {"closed": runtime is not None}


def mock_checkpoints(params):
    with LOCK:
        if "enabled" in params:
            STATE["enabled"] = bool(params["enabled"])
            if params.get("now"):
                for runtime in B["RUNTIME"].values():
                    runtime["checkpoints"] = STATE["enabled"]
        for key in ("busy", "container"):
            if key in params:
                STATE[key] = bool(params[key])
        return dict(STATE)


def get_config(query, body):
    return 200, {"checkpoints": {"enabled": STATE["enabled"], "max_snapshots": 20, "max_total_size_mb": 500,
                                 "max_file_size_mb": 10, "retention_days": 7}}


def put_config(query, body):
    incoming = (body or {}).get("config") or {}
    section = incoming.get("checkpoints")
    if isinstance(section, dict) and "enabled" in section:
        STATE["enabled"] = bool(section["enabled"])
    elif isinstance(section, bool):
        STATE["enabled"] = section
    return 200, {"ok": True}


# ---------------------------------------------------------------- live turns

def take(sid, stored, name, args, extra):
    """Before a file write in a live turn: save the folder once per turn, then make the change."""
    runtime = B["RUNTIME"].get(sid)
    if runtime is None:
        return
    with G.LOCK:
        cwd = (G.SESSIONS.get(stored) or {}).get("_cwd") or HOME
    old, new = [], []
    for line in (extra.get("inline_diff") or "").split("\n"):
        if line.startswith("-") and not line.startswith("---"):
            old.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            new.append(line[1:])
    path = args.get("path") or "file"
    with LOCK:
        files = FILES.setdefault(cwd, {})
        if path not in files and name == "patch":
            files[path] = ["// " + path] + old  # a file the folder had before
        if enabled_for(runtime) and cwd not in (HOME, "/"):  # Hermes never checkpoints the home folder
            checkpoints = STORE.setdefault(cwd, [])
            turn = runtime.get("turn_started") or 0
            if not any(c["ts"] >= turn and not c["message"].startswith("pre-rollback") for c in checkpoints):
                checkpoints.insert(0, new_checkpoint(time.time(), f"before {name}", files))
        apply(files, record(path, old, new, created=name == "write_file"))


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts)) + offset(ts)


def offset(ts):
    seconds = -time.altzone if time.localtime(ts).tm_isdst > 0 and time.daylight else -time.timezone
    sign = "+" if seconds >= 0 else "-"
    seconds = abs(seconds)
    return f"{sign}{seconds // 3600:02d}:{seconds % 3600 // 60:02d}"
