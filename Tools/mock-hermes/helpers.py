"""Helpers (delegated sub-agents) for the combined mock, shaped like Hermes Agent's background
delegation (tools/delegate_tool*.py, tui_gateway/methods_subagents.py, contracts/events.py).

Like the real gateway:
- `delegate_task` returns `{status: "dispatched", mode: "background", delegation_id, goals,
  subagent_ids}` and the turn ends; `subagent.*` events keep coming on the PARENT's runtime session,
  without timestamps; the results come back as a new turn that starts with a
  `display_kind: "async_delegation_complete"` row.
- Nested helpers only report `start` and `complete` (Hermes relays nothing else from depth 1).
- `subagent.steer` answers `queued` or `rejected`; a note that arrives after a helper's last step is
  reported only in its summary ("[steer did not land — …]").
- `spawn_tree.*` is a client-owned archive: Hermes never saves trees itself.

Mock-only, to make every state easy to reach:
- `subagent.spawn_requested` (Hermes builds it but its relay drops it) marks the fourth helper
  "waiting for a free slot", and `delegation.status` reports 3 concurrent children.
- A steer containing "late" lands after the helper's last step (missed); one containing "reject"
  is rejected.

Chat triggers: a message containing "helpers" (or "swift 6") runs the four-helper team; "nested"
runs a lead with three sub-helpers; add "slowly" to stretch the timings for screenshots.
A saved run of the team is seeded in "Swift 6 readiness check" (`api_helpers_past`).
"""

import json
import threading
import time
import uuid

B = None  # backend.py globals
G = None  # server.py module
C = None  # chats.py module

LOCK = threading.RLock()
HELPERS = {}        # subagent_id -> helper state
STATE = {"paused": False}
TREES = {}          # session key -> [entry]
TREE_FILES = {}     # path -> saved JSON
MAX_CONCURRENT = 3
MAX_DEPTH = 2


def install(backend_globals, gateway_module, chats_module):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    methods = B["METHODS"]
    methods.update({
        "subagent.list": subagent_list, "subagent.tail": subagent_tail, "subagent.interrupt": subagent_interrupt,
        "subagent.steer": subagent_steer, "delegation.status": delegation_status, "delegation.pause": delegation_pause,
        "spawn_tree.save": spawn_tree_save, "spawn_tree.list": spawn_tree_list, "spawn_tree.load": spawn_tree_load,
    })
    original = C.run_chat_turn

    def run_chat_turn(sid, text):
        lower = text.lower()
        if "nested" in lower and "helper" in lower:
            return run_team_turn(sid, text, nested=True)
        if "helpers" in lower or "swift 6" in lower:
            return run_team_turn(sid, text, nested=False)
        return original(sid, text)

    C.run_chat_turn = run_chat_turn
    seed_past_run()


def rpc_error(code, message):
    return B["RPCError"](code, message)


def runtime_owned(params):
    sid = params.get("session_id") or ""
    if sid not in B["RUNTIME"]:
        raise rpc_error(4001, "session not found or not owned by this transport")
    return sid


# ---------------------------------------------------------------- the team


TEAM = [
    # goal, model, steps: (seconds, kind, data…); the last step finishes the helper.
    ("Audit the app targets for strict concurrency", "anthropic/claude-sonnet-4.6", [
        (2, "think", "I'll find every target's concurrency setting first."),
        (3, "tool", "read_file", "Hermes.xcodeproj/project.pbxproj"),
        (4, "tool", "grep", "SWIFT_STRICT_CONCURRENCY → 3 minimal, 1 complete"),
        (4, "think", "Three targets are still minimal. Next I'll look for code that relies on implicit main-actor isolation."),
        (5, "tool", "terminal", "rg -n \"@MainActor\" Sources/"),
        (8, "tool", "read_file", "Sources/Sync/Reconnect.swift"),
        (9, "tool", "grep", "nonisolated(unsafe) → 4 matches"),
        (12, "tool", "read_file", "Packages/HermesKit/Package.swift"),
        (14, "think", "Writing up the findings."),
        (16, "done", "completed", "Three of four targets build with minimal checking. 14 warnings to fix before Swift 6 mode; "
                                  "most are implicit main-actor use in Sources/Sync.",
         {"files_read": ["Hermes.xcodeproj/project.pbxproj", "Sources/Sync/Reconnect.swift", "Packages/HermesKit/Package.swift"],
          "files_written": ["notes/concurrency-audit.md"]}),
    ]),
    ("Summarise the Swift 6.4 release notes", "anthropic/claude-haiku-4.5", [
        (1, "tool", "web_search", "Swift 6.4 release notes"),
        (2, "tool", "web_extract", "swift.org/blog/swift-6.4-released"),
        (3, "tool", "write_file", "notes/swift-6.4.md"),
        (2, "done", "completed", "Three changes matter for Hermes: typed throws in closures, @MainActor by default for app targets, "
                                 "and region-based isolation.",
         {"files_read": ["swift.org/blog/swift-6.4-released"], "files_written": ["notes/swift-6.4.md"]}),
    ]),
    ("Run the test suite under Swift 6 mode", "anthropic/claude-sonnet-4.6", [
        (2, "tool", "terminal", "swift test -Xswiftc -swift-version 6"),
        (6, "think", "… 1,204 lines (building HermesKit)"),
        (12, "done", "timeout", "Timed out after 600s", {"output_tail": [
            {"tool": "terminal", "preview": "swift test -Xswiftc -swift-version 6", "is_error": False},
            {"tool": "terminal", "preview": "… 1,204 lines (building HermesKit)", "is_error": False},
            {"tool": "timeout", "preview": "child exceeded 600 s", "is_error": True}]}),
    ]),
    ("Draft the migration checklist", "anthropic/claude-sonnet-4.6", [
        ("slot",),  # waits for a free slot
        (2, "think", "Reading the audit and the release notes."),
        (3, "tool", "read_file", "notes/swift-6.4.md"),
        (4, "tool", "write_file", "docs/swift-6-checklist.md"),
        (3, "done", "completed", "Four steps: enable complete checking per target, adopt MainActor isolation, fix the 14 warnings, "
                                 "then switch the language mode.", {"files_written": ["docs/swift-6-checklist.md"]}),
    ]),
]

NESTED_KIDS = ["Check Sources/Sync for @MainActor gaps", "Check Sources/UI for main-actor isolation",
               "Check Packages/HermesKit for Sendable gaps"]


def run_team_turn(sid, text, nested):
    stored = B["RUNTIME"][sid]["stored"]
    scale = 3.0 if "slowly" in text.lower() else 1.0
    G.add_message(stored, "user", text)
    C.title_later(sid, stored, text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    time.sleep(0.3)
    narration = "I'll split this into four parts and run them in parallel." if not nested else \
        "I'll have one helper audit the folders, with its own helpers for each, while another reads the release notes."
    C.stream(sid, narration)
    C.emit(sid, "message.interim", {"text": narration, "already_streamed": True})

    call = f"call_{uuid.uuid4().hex[:8]}"
    goals = [goal for goal, _, _ in TEAM] if not nested else ["Audit every source folder for main-actor isolation", TEAM[1][0]]
    args = {"tasks": [{"goal": goal} for goal in goals]}
    G.add_message(stored, "assistant", narration, finish_reason="tool_calls",
                  tool_calls=[{"id": call, "type": "function", "function": {"name": "delegate_task", "arguments": json.dumps(args)}}])
    C.emit(sid, "tool.start", {"tool_id": call, "name": "delegate_task", "context": f"{len(goals)} tasks", "args": args})
    if STATE["paused"]:
        result = json.dumps({"error": "Delegation is paused: new helpers can't start until it's turned back on."})
        G.add_message(stored, "tool", result, tool_call_id=call, tool_name="delegate_task")
        C.emit(sid, "tool.complete", {"tool_id": call, "name": "delegate_task", "args": args, "duration_s": 0.1, "result": result,
                                      "summary": "Delegation is paused"})
        answer = "Hermes can't start helpers right now: delegation is paused. Turn it back on in the Team page and ask again."
        C.stream(sid, answer)
        return C.finish(sid, stored, answer)

    delegation = f"deleg_{uuid.uuid4().hex[:8]}"
    helpers = []
    for index, goal in enumerate(goals):
        hid = f"sa-{index}-{uuid.uuid4().hex[:8]}"
        helpers.append(make_helper(sid, stored, hid, goal, index, len(goals), delegation, None, 0))
    if nested:
        helpers[0]["model"] = "anthropic/claude-opus-4.6"
    result = json.dumps({
        "status": "dispatched", "mode": "background", "count": len(goals), "delegation_id": delegation, "goals": goals,
        "subagent_ids": [h["id"] for h in helpers],
        "note": "Running in the background; results arrive as a new turn.",
    })
    # Workers start right away, sometimes before the call returns.
    threading.Thread(target=run_team, args=(sid, stored, helpers, scale, nested, delegation), daemon=True).start()
    time.sleep(0.6)
    G.add_message(stored, "tool", result, tool_call_id=call, tool_name="delegate_task")
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "delegate_task", "args": args, "duration_s": 0.6, "result": result,
                                  "summary": f"{len(goals)} helpers started"})
    answer = "They're working on it; I'll report back when they finish."
    C.stream(sid, answer)
    return C.finish(sid, stored, answer)


def make_helper(sid, stored, hid, goal, index, count, delegation, parent, depth, model=None):
    helper = {
        "id": hid, "sid": sid, "stored": stored, "goal": goal, "index": index, "count": count, "delegation": delegation,
        "parent": parent, "depth": depth, "model": model or (TEAM[index][1] if index < len(TEAM) else "anthropic/claude-sonnet-4.6"),
        "status": "queued", "started_at": None, "tool_count": 0, "last_tool": None, "accepting_steer": True,
        "log": [], "steers": [], "missed": [], "interrupt": False, "last_step": False,
    }
    # The live transcript's header and kickoff, as tools/delegation_live_log.py writes them.
    helper["log"] += ["=== Hermes subagent live transcript ===", f"delegation: {delegation}   task: {index}", f"goal: {goal}",
                      f"started: {time.strftime('%Y-%m-%d %H:%M:%S')}", "(append-only; streams while the subagent runs — tail -f me)",
                      "=" * 40]
    log(helper, "user", f"kickoff: {goal}")
    with LOCK:
        HELPERS[hid] = helper
    return helper


def base(helper):
    payload = {"subagent_id": helper["id"], "goal": helper["goal"], "task_index": helper["index"], "task_count": helper["count"],
               "depth": helper["depth"], "delegation_id": helper["delegation"], "model": helper["model"],
               "tool_count": helper["tool_count"], "child_session_id": f"child_{helper['id']}"}
    if helper["parent"]:
        payload["parent_id"] = helper["parent"]
    return payload


def log(helper, role, text):
    helper["log"].append(f"{time.strftime('%H:%M:%S')} {role:<9}| {text}")


def log_tool(helper, name, data):
    """`tool | -> name(args)`, then `result | name ok 0.4s: …` (the part after "→", if any)."""
    args, _, found = data.partition(" → ")
    log(helper, "tool", f"-> {name}({args})")
    log(helper, "result", f"{name} ok 0.4s: {found or 'done'}")


def emit(helper, kind, extra=None):
    payload = base(helper)
    payload.update(extra or {})
    # Hermes leaves out falsy keys.
    payload = {k: v for k, v in payload.items() if v not in (None, "", [], {}) or k in ("task_index", "tool_count", "depth")}
    C.emit(helper["sid"], kind, payload)


def run_team(sid, stored, helpers, scale, nested, delegation):
    started = time.time()
    threads = []
    if nested:
        lead, notes = helpers
        threads.append(threading.Thread(target=run_lead, args=(lead, scale), daemon=True))
        threads.append(threading.Thread(target=run_helper, args=(notes, TEAM[1][2], scale), daemon=True))
    else:
        for helper, (_, _, steps) in zip(helpers, TEAM):
            threads.append(threading.Thread(target=run_helper, args=(helper, steps, scale), daemon=True))
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    async_completion(sid, stored, helpers, time.time() - started, delegation)


def wait(helper, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if helper["interrupt"]:
            return False
        time.sleep(0.1)
    return True


def deliver_steers(helper):
    """Notes are read when a tool result comes back, before the next step."""
    while helper["steers"]:
        helper["steers"].pop(0)


def run_helper(helper, steps, scale):
    if steps and steps[0] == ("slot",):
        # Mock-only: shown as waiting for a free slot until the others make room.
        emit(helper, "subagent.spawn_requested", {"text": helper["goal"]})
        steps = steps[1:]
        while running_count(helper["sid"]) >= MAX_CONCURRENT - 1:
            time.sleep(0.25)
        # A beat longer, so "running, done, timed out, waiting" hold together for a while.
        if not wait(helper, 12 * scale):
            return finish(helper, "interrupted", "Cancelled before it started.")
    begin(helper)
    for index, step in enumerate(steps):
        seconds, kind = step[0] * scale, step[1]
        if kind == "done":
            helper["last_step"] = True
        if not wait(helper, seconds):
            return finish(helper, "interrupted", f"Stopped after {helper['tool_count']} tools. Partial findings kept.")
        if kind == "think":
            log(helper, "assistant", step[2])
            emit(helper, "subagent.thinking", {"text": step[2][:80]})
        elif kind == "tool":
            deliver_steers(helper)
            helper["tool_count"] += 1
            helper["last_tool"] = step[2]
            log_tool(helper, step[2], step[3])
            emit(helper, "subagent.tool", {"tool_name": step[2], "tool_preview": step[3], "text": step[3]})
            if helper["tool_count"] % 5 == 0:
                emit(helper, "subagent.progress", {"text": f"🔀 [{helper['index'] + 1}/{helper['count']}] {helper['tool_count']} tools"})
        elif kind == "done":
            return finish(helper, step[2], step[3], step[4] if len(step) > 4 else {})


def begin(helper):
    helper["status"] = "running"
    helper["started_at"] = time.time()
    log(helper, "start", helper["goal"])
    emit(helper, "subagent.start", {"text": helper["goal"]})


def finish(helper, status, text, extra=None):
    extra = dict(extra or {})
    helper["accepting_steer"] = False
    # A note that came after the last step is only in the summary.
    for note in helper["steers"] + helper["missed"]:
        text = f"{text}\n\n[steer did not land — the subagent finished before it could be delivered: {note}]"
    helper["steers"], helper["missed"] = [], []
    duration = round(time.time() - (helper["started_at"] or time.time()), 1)
    payload = {"status": status, "duration_seconds": duration, "text": text[:160],
               "input_tokens": 9000 + 1000 * helper["tool_count"], "output_tokens": 800 + 150 * helper["tool_count"],
               "api_calls": helper["tool_count"] + 2}
    if status in ("completed", "interrupted"):
        payload["summary"] = text[:500]
    payload.update(extra)
    if status == "completed":
        log(helper, "assistant", text)
    log(helper, "final", f"status={status} duration={duration}s summary: {text[:160]}")
    helper["status"] = status
    helper["result"] = payload
    emit(helper, "subagent.complete", payload)


def run_lead(lead, scale):
    begin(lead)
    for step in [(2, "think", "Splitting the audit by folder."), (2, "tool", "list_files", "Sources/ Packages/")]:
        if not wait(lead, step[0] * scale):
            return finish(lead, "interrupted", "Stopped while splitting the work.")
        if step[1] == "think":
            log(lead, "assistant", step[2])
            emit(lead, "subagent.thinking", {"text": step[2]})
        else:
            lead["tool_count"] += 1
            lead["last_tool"] = step[2]
            log_tool(lead, step[2], step[3])
            emit(lead, "subagent.tool", {"tool_name": step[2], "tool_preview": step[3], "text": step[3]})
    lead["tool_count"] += 1
    lead["last_tool"] = "delegate_task"
    emit(lead, "subagent.tool", {"tool_name": "delegate_task", "tool_preview": "3 tasks", "text": "3 tasks"})
    nested = f"deleg_{uuid.uuid4().hex[:8]}"
    kids = [make_helper(lead["sid"], lead["stored"], f"sa-{i}-{uuid.uuid4().hex[:8]}", goal, i, 3, nested, lead["id"], 1,
                        model="anthropic/claude-haiku-4.5")
            for i, goal in enumerate(NESTED_KIDS)]
    durations = [14, 6, 18]

    def kid(helper, seconds):
        # Hermes relays only start and complete from depth 1.
        helper["status"] = "running"
        helper["started_at"] = time.time()
        emit(helper, "subagent.start", {"text": helper["goal"]})
        if not wait(helper, seconds * scale):
            return finish(helper, "interrupted", "Stopped.")
        helper["tool_count"] = 4
        finish(helper, "completed", f"No gaps in {helper['goal'].split(' ')[1]}." if seconds < 10 else "Two gaps, both in tests.")

    threads = [threading.Thread(target=kid, args=(k, d), daemon=True) for k, d in zip(kids, durations)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if not wait(lead, 2 * scale):
        return finish(lead, "interrupted", "Stopped while writing up.")
    finish(lead, "completed", "Main-actor isolation is clean in Sources/UI; Sync and HermesKit have two gaps each.",
           {"files_read": ["Sources/", "Packages/HermesKit/"]})


def running_count(sid):
    with LOCK:
        return sum(1 for h in HELPERS.values() if h["sid"] == sid and h["status"] == "running" and h["depth"] == 0)


def async_completion(sid, stored, helpers, seconds, delegation):
    """Hermes's background-delegation result: a new turn opened by a notice row."""
    done = sum(1 for h in helpers if h["status"] == "completed")
    failed = len(helpers) - done
    with B["LOCK"]:
        runtime = B["RUNTIME"].get(sid)
        busy = runtime and runtime["running"]
    while busy:
        time.sleep(0.5)
        with B["LOCK"]:
            busy = B["RUNTIME"][sid]["running"]

    def runner(rsid, _text):
        notice = f"[Background delegation finished] {done} of {len(helpers)} helpers completed"
        G.add_message(stored, "user", notice, display_kind="async_delegation_complete")
        C.emit(rsid, "session.info", {"running": True})
        C.emit(rsid, "message.start", {})
        time.sleep(0.4)
        if failed:
            answer = ("**Not quite yet.** Three of four targets are still on minimal checking, and the test run under Swift 6 "
                      "timed out in HermesKit. The checklist in `docs/swift-6-checklist.md` takes you there in four steps.")
        else:
            answer = "All done. The audit and the release notes agree: two gaps to fix, both small. Details are in the notes."
        C.stream(rsid, answer)
        C.finish(rsid, stored, answer)

    B["start_turn"](sid, "", runner)


# ---------------------------------------------------------------- methods


def live_rows(sid):
    with LOCK:
        mine = [h for h in HELPERS.values() if h["sid"] == sid]
    rows = []
    for h in mine:
        if h["status"] != "running":
            continue
        rows.append({"subagent_id": h["id"], "parent_id": h["parent"], "depth": h["depth"], "goal": h["goal"],
                     "delegation_id": h["delegation"], "model": h["model"], "started_at": h["started_at"], "status": "running",
                     "tool_count": h["tool_count"], "last_tool": h["last_tool"], "accepting_steer": h["accepting_steer"]})
    return rows


def subagent_list(params):
    sid = runtime_owned(params)
    with LOCK:
        failed = [h for h in HELPERS.values() if h["sid"] == sid and h["depth"] == 0 and h["status"] in ("failed", "error", "timeout")]
    delegations = [{"delegation_id": h["delegation"], "task_index": h["index"], "status": h["status"], "goal": h["goal"],
                    "error": (h.get("result") or {}).get("text"), "dispatched_at": h["started_at"], "completed_at": time.time()}
                   for h in failed]
    return {"subagents": live_rows(sid), "delegations": delegations}


def find(params):
    hid = params.get("subagent_id") or ""
    if not hid:
        raise rpc_error(4000, "subagent_id required")
    sid = runtime_owned(params)
    with LOCK:
        helper = HELPERS.get(hid)
    return helper if helper and helper["sid"] == sid else None


def subagent_tail(params):
    helper = find(params)
    if not helper or helper["status"] != "running":
        return {"subagent_id": params.get("subagent_id"), "available": False, "text": "", "truncated": False}
    text = "\n".join(helper["log"]) + "\n"
    data = text.encode()
    return {"subagent_id": helper["id"], "available": True, "text": data[-16384:].decode(errors="ignore"), "truncated": len(data) > 16384}


def subagent_interrupt(params):
    helper = find(params)
    found = bool(helper and helper["status"] in ("running", "queued"))
    if found:
        helper["interrupt"] = True
        if helper["status"] == "queued":
            finish(helper, "interrupted", "Cancelled before it started.")
    return {"found": found, "subagent_id": params.get("subagent_id")}


def subagent_steer(params):
    text = (params.get("text") or "").strip()
    if not text:
        raise rpc_error(4002, "text is required")
    helper = find(params)
    if not helper or helper["status"] != "running" or not helper["accepting_steer"] or "reject" in text.lower():
        return {"status": "rejected", "subagent_id": params.get("subagent_id"), "text": text}
    if "late" in text.lower() or helper["last_step"]:
        helper["missed"].append(text)
    else:
        helper["steers"].append(text)
    return {"status": "queued", "subagent_id": helper["id"], "text": text}


def delegation_status(params):
    with LOCK:
        active = [{k: v for k, v in {"subagent_id": h["id"], "parent_id": h["parent"], "depth": h["depth"], "goal": h["goal"],
                                     "delegation_id": h["delegation"], "model": h["model"], "started_at": h["started_at"],
                                     "status": "running", "tool_count": h["tool_count"], "last_tool": h["last_tool"],
                                     "owner_agent_session_id": h["stored"]}.items()}
                  for h in HELPERS.values() if h["status"] == "running"]
    return {"active": active, "paused": STATE["paused"], "max_spawn_depth": MAX_DEPTH, "max_concurrent_children": MAX_CONCURRENT}


def delegation_pause(params):
    STATE["paused"] = bool(params.get("paused", True))
    return {"paused": STATE["paused"]}


def spawn_tree_save(params):
    rows = params.get("subagents") or []
    if not rows:
        raise rpc_error(4000, "subagents list required")
    session = params.get("session_id") or ""
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    path = f"/Users/studio/.hermes/spawn-trees/{session or 'default'}/{stamp}.json"
    data = {"session_id": session, "started_at": params.get("started_at"), "finished_at": params.get("finished_at") or time.time(),
            "label": params.get("label") or "", "subagents": rows}
    with LOCK:
        TREE_FILES[path] = data
        entries = TREES.setdefault(session, [])
        entries[:] = [e for e in entries if e["path"] != path]
        entries.append({"path": path, "session_id": session, "started_at": data["started_at"], "finished_at": data["finished_at"],
                        "label": data["label"], "count": len(rows)})
    return {"path": path, "session_id": session}


def spawn_tree_list(params):
    session = params.get("session_id")
    limit = int(params.get("limit") or 50)
    with LOCK:
        if params.get("cross_session") or not session:
            entries = [e for group in TREES.values() for e in group]
        else:
            entries = list(TREES.get(session, []))
    entries.sort(key=lambda e: e.get("finished_at") or 0, reverse=True)
    return {"entries": entries[:limit]}


def spawn_tree_load(params):
    path = params.get("path") or ""
    if not path:
        raise rpc_error(4000, "path required")
    if not path.startswith("/Users/studio/.hermes/spawn-trees/"):
        raise rpc_error(4030, "path outside the spawn-trees root")
    with LOCK:
        data = TREE_FILES.get(path)
    if data is None:
        raise rpc_error(5000, "could not read spawn tree")
    return data


# ---------------------------------------------------------------- a saved past run


def seed_past_run():
    """'Swift 6 readiness check': a finished team turn, its results turn, and its saved tree."""
    stored = "api_helpers_past"
    now = time.time()
    start = now - 26 * 3600
    G.session_row(stored, "Swift 6 readiness check", "hermes_app", start, start + 400, "Is the app ready for Swift 6 mode?")
    question = "Is the app ready for Swift 6 mode? Check every target, run the tests and give me a migration checklist."
    G.add_message(stored, "user", question, timestamp=start)
    delegation = "deleg_5f19c2aa"
    ids = ["sa-0-1a2b3c4d", "sa-1-2b3c4d5e", "sa-2-3c4d5e6f", "sa-3-4d5e6f70"]
    goals = [goal for goal, _, _ in TEAM]
    args = {"tasks": [{"goal": g} for g in goals]}
    G.add_message(stored, "assistant", "I'll split this into four parts and run them in parallel.", timestamp=start + 4,
                  finish_reason="tool_calls",
                  tool_calls=[{"id": "call_past1", "type": "function", "function": {"name": "delegate_task", "arguments": json.dumps(args)}}])
    G.add_message(stored, "tool", json.dumps({"status": "dispatched", "mode": "background", "count": 4, "delegation_id": delegation,
                                              "goals": goals, "subagent_ids": ids}),
                  tool_call_id="call_past1", tool_name="delegate_task", timestamp=start + 5)
    G.add_message(stored, "assistant", "They're working on it; I'll report back when they finish.", timestamp=start + 6, finish_reason="stop")
    G.add_message(stored, "user", "[Background delegation finished] 3 of 4 helpers completed", timestamp=start + 366,
                  display_kind="async_delegation_complete")
    G.add_message(stored, "assistant",
                  "**Not quite yet.** Three of four targets are still on minimal checking, and the test run under Swift 6 timed out in "
                  "HermesKit. The checklist below takes you there in four steps.", timestamp=start + 380, finish_reason="stop")
    statuses = ["completed", "completed", "timeout", "completed"]
    durations = [102, 58, 600, 74]
    summaries = [TEAM[0][2][-1][3], TEAM[1][2][-1][3], "Timed out after 600s", TEAM[3][2][-1][3]]
    rows = []
    for index, (hid, goal) in enumerate(zip(ids, goals)):
        row = {"id": hid, "goal": goal, "status": statuses[index], "depth": 0, "parentId": None, "index": index, "taskCount": 4,
               "toolCount": [12, 4, 31, 6][index], "tools": [], "notes": [], "thinking": [], "model": TEAM[index][1],
               "delegationId": delegation, "durationSeconds": durations[index], "summary": summaries[index],
               "startedAt": start + 6 + index, "inputTokens": [41000, 9000, 88000, 15000][index], "outputTokens": [2400, 800, 3100, 1200][index]}
        if index == 1:
            row["filesWritten"] = ["notes/swift-6.4.md"]
            row["filesRead"] = ["swift.org/blog/swift-6.4-released", "forums.swift.org"]
        if index == 2:
            row["outputTail"] = [{"tool": "terminal", "preview": "swift test -Xswiftc -swift-version 6", "isError": False},
                                 {"tool": "terminal", "preview": "… 1,204 lines (building HermesKit)", "isError": False},
                                 {"tool": "timeout", "preview": "child exceeded 600 s", "isError": True}]
        rows.append(row)
    path = f"/Users/studio/.hermes/spawn-trees/{stored}/{time.strftime('%Y%m%dT%H%M%S', time.gmtime(start + 366))}.json"
    data = {"session_id": stored, "started_at": start + 6, "finished_at": start + 366, "label": delegation, "subagents": rows}
    TREE_FILES[path] = data
    TREES[stored] = [{"path": path, "session_id": stored, "started_at": start + 6, "finished_at": start + 366, "label": delegation, "count": 4}]
    place = getattr(G, "SESSIONS", {}).get(stored)
    if place is not None and "_cwd" not in place:
        place["_cwd"] = "/Users/studio/Code/hermes-app"
        place["_branch"] = "main"
