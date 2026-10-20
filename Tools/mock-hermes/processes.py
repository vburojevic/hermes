"""Background processes for the combined mock (docs/background-processes.md), shaped like Hermes's
process registry (tools/process_registry.py) and its gateway methods (tui_gateway/methods_tools.py).

Hermes starts them with the `terminal` tool and `background: true` (the tool's result carries the
process id as `session_id`), or with `message_agent` (its result carries `process_id`). Output
streams as `agent.terminal.output {process_id, chunk}`, raw: ANSI codes, `\\r` progress lines and,
here, Hermes's working-folder marker. Most processes send **no event when they exit**: only
`process.list` says so. A process started with `notify_on_complete` also sends
`status.update {kind: "process", text}`. `terminal.close` only closes a Terminal tab.

Scripted turns, in Bot Chats and normal chats:
  "release" with "docs", or "processes"  -> Docs site (`npm run docs:dev`, runs on) and Release
                                            build (`make release`, exits 0 after ~35 s, no event);
                                            the Docs site's tab is closed (`terminal.close`) while
                                            it still runs
  "trailhead" or "deploy log"             -> a message to Ada through `message_agent` that fails
                                            (a JSON error, exit 1) and `tail -f` on the deploy log
Controls:
  POST /api/mock/processes/exit  {process, code?, reason?}  ends one (by id or a word of its name), no event
  POST /api/mock/processes/close {process}                  `terminal.close` for one that still runs
  POST /api/mock/processes/reveal {process?}                `pane.reveal terminal` (Hermes's focus_pane) in its chat
  POST /api/mock/processes/reset                            forgets them all
  POST /api/mock/processes/deliveries {persist}             later `message_agent` deliveries start with
                                                            `persist_on_release` (Hermes with upstream
                                                            #136220) or without (Hermes 0.22, the default)
"""

import json
import os
import threading
import time
import uuid

B = None  # backend.py's module globals
G = None  # server.py (API-server mock)
C = None  # chats.py

LOCK = threading.Lock()
PROCS = {}  # process id -> {stored, command, cwd, pid, started, running, exit_code, exited_at, reason, output, notify, persist}
# Hermes 0.22 starts `message_agent`'s delivery without `persist_on_release`, so it stops with the sender's chat.
DELIVERIES = {"persist": False}
HOME = os.path.expanduser("~")
MARKER = "__HERMES_CWD_3fa9c2d1e0b4__"


def install(backend_globals, gateway_module, chats_module):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    methods = B["METHODS"]
    previous_list, previous_kill = methods.get("process.list"), methods.get("process.kill")

    def process_list(params):
        stored = stored_for(params.get("session_id") or "")
        with LOCK:
            mine = [entry(pid, p) for pid, p in PROCS.items() if p["stored"] == stored]
        others = previous_list(params).get("processes", []) if previous_list else []
        return {"processes": mine + others}

    def process_kill(params):
        pid = params.get("process_id") or ""
        if not pid:
            raise B["RPCError"](4012, "process_id required")
        with LOCK:
            process = PROCS.get(pid)
            if process is None:
                missing = True
            else:
                missing = False
                if process["stored"] != stored_for(params.get("session_id") or ""):
                    raise B["RPCError"](4044, f"no such process: {pid}")
                if not process["running"]:
                    return {"status": "already_exited", "command": process["command"], "exit_code": process["exit_code"],
                            "completion_reason": process["reason"], "termination_source": "process.kill", "output": process["output"][-2000:]}
                process.update(running=False, exit_code=-15, exited_at=time.time(), reason="killed")
                return {"status": "killed", "session_id": pid, "completion_reason": "killed",
                        "termination_source": "process.kill", "output": process["output"][-2000:]}
        if missing and previous_kill:
            return previous_kill(params)
        raise B["RPCError"](4044, f"no such process: {pid}")

    methods["process.list"] = process_list
    methods["process.kill"] = process_kill
    # `process.stop` stops every process on the gateway: the app must never call it.
    methods["process.stop"] = lambda params: (_ for _ in ()).throw(B["RPCError"](4000, "mock: the app must never call process.stop"))

    routes = B["HTTP_ROUTES"]
    routes[("POST", "/api/mock/processes/exit")] = mock_exit
    routes[("POST", "/api/mock/processes/close")] = mock_close
    routes[("POST", "/api/mock/processes/reset")] = lambda query, body: (200, {"ok": True, "forgot": reset()})
    routes[("POST", "/api/mock/processes/deliveries")] = mock_deliveries
    routes[("POST", "/api/mock/processes/reveal")] = mock_reveal

    original_bot = B["run_turn"]

    def run_turn(sid, text):
        kind = scenario(text)
        if kind is None:
            return original_bot(sid, text)
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
        return run_scenario(kind, sid, stored, stream=B["stream"], finish=B["finish"])

    B["run_turn"] = run_turn
    if C is not None:
        original_chat = C.run_chat_turn

        def run_chat_turn(sid, text):
            kind = scenario(text)
            if kind is None:
                return original_chat(sid, text)
            stored = B["RUNTIME"][sid]["stored"]
            G.add_message(stored, "user", text)
            return run_scenario(kind, sid, stored, stream=C.stream, finish=C.finish)

        C.run_chat_turn = run_chat_turn


def scenario(text):
    lower = text.lower()
    if "processes" in lower or ("release" in lower and "docs" in lower):
        return "release"
    if "trailhead" in lower or "deploy log" in lower:
        return "message"
    return None


def stored_for(sid):
    runtime = B["RUNTIME"].get(sid)
    return runtime["stored"] if runtime else sid


def sid_for(stored):
    """The runtime id the chat runs under now (a resume can give it a new one)."""
    return next((sid for sid, runtime in B["RUNTIME"].items() if runtime.get("stored") == stored), None)


def entry(pid, p):
    row = {"session_id": pid, "command": p["command"][:200], "cwd": p["cwd"], "pid": p["pid"],
           "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(p["started"])),
           "uptime_seconds": int(time.time() - p["started"]), "status": "running" if p["running"] else "exited",
           "output_preview": p["output"][-200:], "output_tail": p["output"][-4000:]}
    if p["notify"]:
        row["notify_on_complete"] = True
    if p.get("persist"):
        row["persist_on_release"] = True  # Hermes lists it only when set
    if not p["running"]:
        row.update(exit_code=p["exit_code"], exited_at=p["exited_at"], completion_reason=p["reason"])
    return row


def emit(stored, kind, payload):
    sid = sid_for(stored)
    if sid:
        B["emit"](sid, kind, payload)


def start(stored, command, cwd, notify=False, persist=False):
    pid = f"proc_{uuid.uuid4().hex[:12]}"
    with LOCK:
        PROCS[pid] = {"stored": stored, "command": command, "cwd": cwd, "pid": 40000 + len(PROCS) * 7, "started": time.time(),
                      "running": True, "exit_code": None, "exited_at": None, "reason": None, "output": "", "notify": notify,
                      "persist": persist}
    return pid


def write(pid, chunk):
    with LOCK:
        process = PROCS.get(pid)
        if process is None or not process["running"]:
            return False
        process["output"] += chunk
        stored = process["stored"]
    emit(stored, "agent.terminal.output", {"process_id": pid, "chunk": chunk})
    return True


def exit_process(pid, code=0, reason="exited"):
    """Ends a process the way Hermes's registry does: no event, unless it notifies on completion."""
    with LOCK:
        process = PROCS.get(pid)
        if process is None or not process["running"]:
            return
        process.update(running=False, exit_code=code, exited_at=time.time(), reason=reason)
        notify, stored, command = process["notify"], process["stored"], process["command"]
    if notify:
        verb = "Finished" if code == 0 else f"Failed (exit {code})"
        emit(stored, "status.update", {"kind": "process", "text": f"Background Process {verb}: {command[:80]}"})


def running(pid):
    with LOCK:
        return PROCS.get(pid, {}).get("running", False)


def call_tool(sid, stored, name, args, result, seconds, context):
    """A tool call as Hermes stores and streams it (`tool.complete`'s `result` is the parsed JSON)."""
    call = f"call_{uuid.uuid4().hex[:8]}"
    B["store_row"](sid, stored, "assistant", "", tool_calls=[{"id": call, "type": "function",
                   "function": {"name": name, "arguments": json.dumps(args)}}], finish_reason="tool_calls")
    B["emit"](sid, "tool.start", {"tool_id": call, "name": name, "context": context, "args": args})
    time.sleep(seconds)
    B["store_row"](sid, stored, "tool", json.dumps(result), tool_call_id=call, tool_name=name)
    B["emit"](sid, "tool.complete", {"tool_id": call, "name": name, "args": args, "duration_s": seconds, "result": result,
                                     "summary": f"Completed in {seconds:.1f}s"})


def run_scenario(kind, sid, stored, *, stream, finish):
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})
    time.sleep(0.3)
    for piece in ["The person wants ", "work to keep running ", "after this turn."]:
        B["emit"](sid, "reasoning.delta", {"text": piece})
        time.sleep(0.08)
    if kind == "release":
        docs = start(stored, f"cd {HOME}/Code/hermes-docs && npm run docs:dev", f"{HOME}/Code/hermes-docs")
        call_tool(sid, stored, "terminal", {"command": f"cd {HOME}/Code/hermes-docs && npm run docs:dev", "background": True},
                  {"output": "Background process started", "session_id": docs, "pid": 40000, "exit_code": 0, "error": None},
                  0.6, "npm run docs:dev")
        threading.Thread(target=run_docs, args=(docs,), daemon=True).start()
        build = start(stored, "make release > build.log 2>&1", f"{HOME}/Code/hermes", notify=True)
        call_tool(sid, stored, "terminal", {"command": "make release > build.log 2>&1", "background": True, "notify_on_complete": True},
                  {"output": "Background process started", "session_id": build, "pid": 40007, "exit_code": 0, "error": None,
                   "notify_on_complete": True}, 0.6, "make release")
        threading.Thread(target=run_release, args=(build, docs), daemon=True).start()
        answer = ("Both run in the background. The docs are at localhost:4321, and I'll tell you when the build "
                  "is signed.")
    else:
        message = start(stored, f"{HOME}/.hermes/hermes-agent/venv/bin/python {HOME}/.hermes/hermes-agent/tools/bot_mode_dm.py "
                                f"--run-delivery --author '{{\"id\":\"default\"}}' query-file /tmp/dm-7f3a.json "
                                f"{HOME}/.local/bin/hermes -p writer chat --in ~ -c 'Bot Chat' --create-if-missing -Q",
                        HOME, notify=True, persist=DELIVERIES["persist"])
        call_tool(sid, stored, "message_agent", {"target": "writer", "message": "Please rotate the Trailhead keys."},
                  {"status": "queued", "delivery_id": f"dm_{uuid.uuid4().hex[:8]}", "to": "Ada", "reply_delivery": "notification",
                   "detail": "Message queued for Ada.", "process_id": message, "queued_at": int(time.time())}, 0.5, "Ada")
        threading.Thread(target=run_message, args=(message,), daemon=True).start()
        log = start(stored, f"tail -f {HOME}/deploys/trailhead.log", f"{HOME}/deploys")
        call_tool(sid, stored, "terminal", {"command": f"tail -f {HOME}/deploys/trailhead.log", "background": True},
                  {"output": "Background process started", "session_id": log, "pid": 40014, "exit_code": 0, "error": None},
                  0.5, "tail -f ~/deploys/trailhead.log")
        threading.Thread(target=run_log, args=(log,), daemon=True).start()
        answer = "I've asked Ada to rotate the Trailhead keys, and I'm keeping an eye on the deploy log."
    stream(sid, answer)
    return finish(sid, stored, answer)


def run_docs(pid):
    lines = ["\x1b[2m> hermes-docs@1.3.0 docs:dev\x1b[0m\n", "\x1b[2m> astro dev --port 4321\x1b[0m\n\n",
             "\x1b[32m 🚀 astro\x1b[0m \x1b[1mv5.2\x1b[0m ready in 412 ms\n\n",
             "\x1b[1mLocal:\x1b[0m \x1b[36mhttp://localhost:4321/\x1b[0m\n"]
    for line in lines:
        write(pid, line)
        time.sleep(0.3)
    n = 0
    while running(pid) and n < 600:
        time.sleep(6)
        stamp = time.strftime("%H:%M:%S")
        write(pid, f"\x1b[2m{stamp}\x1b[0m \x1b[36m[watch]\x1b[0m src/content/changelog.md\n" if n % 2 == 0
              else f"\x1b[2m{stamp}\x1b[0m GET /changelog 200 in {3 + n % 5} ms\n")
        n += 1


def run_release(pid, docs):
    write(pid, "Archiving Hermes (Release)…\n")
    time.sleep(2)
    for done in range(0, 413, 59):
        if not write(pid, f"\rCompiling {min(done, 412)}/412 files"):
            return
        time.sleep(0.8)
    write(pid, "\rCompiling 412/412 files\n")
    write(pid, "Compiled 412 files in 1m 48s\n")
    write(pid, f"{MARKER}{HOME}/Code/hermes{MARKER}\n")
    time.sleep(3)
    # Hermes closes the Docs site's tab: the server keeps running.
    with LOCK:
        stored = PROCS[docs]["stored"]
    emit(stored, "terminal.close", {"process_id": docs})
    write(pid, "Exporting Hermes.app (Developer ID)\n")
    time.sleep(6)
    write(pid, "\x1b[1mSigning Hermes.app…\x1b[0m\n")
    time.sleep(8)
    if write(pid, "Hermes-1.3.dmg signed and notarized\n"):
        time.sleep(1)
        exit_process(pid, 0)


def run_message(pid):
    time.sleep(2.5)
    write(pid, json.dumps({"error": "target_busy: profile 'writer' is busy with another message. "
                                    "Retry after the current turn ends.", "delivered": False}) + "\n")
    time.sleep(0.5)
    exit_process(pid, 1)


def run_log(pid):
    write(pid, f"{time.strftime('%H:%M')} deploy started (trailhead@a41c9e2)\n")
    time.sleep(3)
    write(pid, f"{time.strftime('%H:%M')} deploy finished in 42 s\n")
    n = 0
    while running(pid) and n < 600:
        time.sleep(15)
        write(pid, f"{time.strftime('%H:%M')} healthcheck ok\n")
        n += 1


def find(word):
    with LOCK:
        if word in PROCS:
            return word
        return next((pid for pid, p in reversed(list(PROCS.items())) if word and word.lower() in p["command"].lower()), None)


def mock_deliveries(query, body):
    DELIVERIES["persist"] = bool((body or {}).get("persist"))
    return 200, {"ok": True, "persist": DELIVERIES["persist"]}


def mock_exit(query, body):
    pid = find(str(body.get("process") or ""))
    if pid is None:
        return 404, {"detail": "No such process"}
    exit_process(pid, int(body.get("code") or 0), str(body.get("reason") or "exited"))
    return 200, {"ok": True, "process": pid}


def mock_close(query, body):
    pid = find(str(body.get("process") or ""))
    if pid is None:
        return 404, {"detail": "No such process"}
    with LOCK:
        stored = PROCS[pid]["stored"]
    emit(stored, "terminal.close", {"process_id": pid})
    return 200, {"ok": True, "process": pid}


def mock_reveal(query, body):
    pid = find(str(body.get("process") or "")) or next(reversed(list(PROCS)), None)
    if pid is None:
        return 404, {"detail": "No process"}
    with LOCK:
        stored = PROCS[pid]["stored"]
    emit(stored, "pane.reveal", {"pane": "terminal"})
    return 200, {"ok": True, "process": pid}


def reset():
    with LOCK:
        count = len(PROCS)
        PROCS.clear()
    return count
