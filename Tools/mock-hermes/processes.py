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
  "bot messages" (Bot Chats)              -> messages to other Bots in both shapes Hermes has, each
                                            ending as Hermes stores it (docs/chat.md §2a):
                                            `message_agent` to Ada, replied after ~3 s; to Ops,
                                            waiting ~20 s, then "No reply"; the Bot running
                                            `hermes -p writer chat -q …` itself, replied; and
                                            `hermes -p ops chat … --query-file …` (no words here),
                                            ended and no longer listed ("Ended"); and a
                                            `message_agent` streamed without `args` (a mirrored row),
                                            ended with no answer and no longer listed: no words live
  "background tasks"                      -> five checks in the background, finishing as Hermes tells
                                            the chat (docs/chat.md §2a): the tests (exit 1), a fetch,
                                            a build and a lint, the gateway's batch row (ids only)
                                            and two rows in a row (one group of four); a reply; the docs build (~25 s, one
                                            line); a reply; then a completion with no details
                                            (`Command: unknown`, no output, no step here)
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
            # Hermes's registry lets go of a finished process after a while: the list no longer has it.
            mine = [entry(pid, p) for pid, p in PROCS.items() if p["stored"] == stored and not (p.get("forget") and not p["running"])]
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
            # `message_agent` is offered in a Bot Chat only (tools/bot_mode_dm.py).
            if kind is None or kind == "messages":
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
    if "bot messages" in lower:
        return "messages"
    if "background tasks" in lower:
        return "tasks"
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


def call_tool(sid, stored, name, args, result, seconds, context, live_args=True):
    """A tool call as Hermes stores and streams it (`tool.complete`'s `result` is the parsed JSON).
    `live_args=False` streams it without `args`, as a mirrored row or a room relay does
    (tui_gateway/contracts/events.py `ToolCompletePayload`); the stored row keeps them."""
    call = f"call_{uuid.uuid4().hex[:8]}"
    B["store_row"](sid, stored, "assistant", "", tool_calls=[{"id": call, "type": "function",
                   "function": {"name": name, "arguments": json.dumps(args)}}], finish_reason="tool_calls")
    live = {"args": args} if live_args else {}
    B["emit"](sid, "tool.start", {"tool_id": call, "name": name, "context": context, **live})
    time.sleep(seconds)
    B["store_row"](sid, stored, "tool", json.dumps(result), tool_call_id=call, tool_name=name)
    B["emit"](sid, "tool.complete", {"tool_id": call, "name": name, **live, "duration_s": seconds,
                                     **B["tool_complete_fields"](name, result, seconds)})


def run_scenario(kind, sid, stored, *, stream, finish):
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})
    time.sleep(0.3)
    for piece in ["The person wants ", "work to keep running ", "after this turn."]:
        B["emit"](sid, "reasoning.delta", {"text": piece})
        time.sleep(0.08)
    if kind == "messages":
        return run_messages(sid, stored, stream=stream, finish=finish)
    if kind == "tasks":
        return run_tasks(sid, stored, stream=stream, finish=finish)
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


# The words of "bot messages" (invented).
ADA_ASK = ("Could you draft the 2.4 release notes tonight? Three lines: offline edits sync, the share sheet "
           "opens in under a second, exports keep their folders.")
ADA_REPLY = "Done: the draft is in `docs/releases/2.4.md`, three lines in the order you gave them."
OPS_ASK = "Can you check last night's offsite backup finished?"
QUERY_ASK = "Is the blog post for 2.4 scheduled?"
QUERY_REPLY = "Yes, for 9:00 tomorrow."
UNHEARD_ASK = "Please rotate the staging keys when the backup is done."


def delivery_runner(target, dm):
    """Hermes's own delivery of a `message_agent` call (tools/bot_mode_dm.py `_delivery_command`):
    the words are in a file, not in the command."""
    return (f"{HOME}/.hermes/hermes-agent/venv/bin/python {HOME}/.hermes/hermes-agent/tools/bot_mode_dm.py "
            f"--run-delivery --author '{{\"id\":\"bot:default\",\"name\":\"hermes\",\"is_bot\":true}}' query-file "
            f"/tmp/hermes-dm/{dm}.txt --profile-home {HOME}/.hermes/profiles/{target} {HOME}/.local/bin/hermes -p {target}")


def run_messages(sid, stored, *, stream, finish):
    """The words "bot messages" in a Bot Chat: five messages to other Bots, as Hermes sends them.
    `message_agent` answers with its delivery's process (`process_id`) and the reply comes back as
    that process's completion notice (`process_complete`); a Bot can also run Hermes itself in the
    background (the bundled hermes-agent skill's `hermes chat -q …`)."""
    def message(target, words, title, live_args=True):
        dm = f"dm_{uuid.uuid4().hex[:8]}"
        pid = start(stored, delivery_runner(target, dm), HOME, notify=True, persist=DELIVERIES["persist"])
        call_tool(sid, stored, "message_agent", {"target": target, "message": words},
                  {"status": "queued", "delivery_id": dm, "to": f"@{target}", "reply_delivery": "notification",
                   "detail": f"Message queued for @{target}: this acknowledges the hand-off to a background delivery "
                             "process, not a delivery receipt — do NOT wait or poll.",
                   "process_id": pid, "queued_at": int(time.time())}, 0.5, title, live_args=live_args)
        return pid

    def shell(command, title):
        pid = start(stored, command, HOME, notify=True)
        call_tool(sid, stored, "terminal", {"command": command, "background": True, "notify_on_complete": True},
                  {"output": "Background process started", "session_id": pid, "pid": 40021, "exit_code": 0, "error": None,
                   "notify_on_complete": True}, 0.4, title)
        return pid

    # A message whose words never reached this chat live (streamed without `args`): its delivery ends
    # with no answer and the list lets it go, so while the turn runs it has no words, no answer and
    # no wait. The stored row has its words.
    unheard = message("ops", UNHEARD_ASK, "Ops", live_args=False)
    with LOCK:
        PROCS[unheard]["forget"] = True

    def end_unheard():
        time.sleep(2)
        exit_process(unheard, 0)

    threading.Thread(target=end_unheard, daemon=True).start()
    ada = message("writer", ADA_ASK, "Ada")
    ops = message("ops", OPS_ASK, "Ops")
    query = f"hermes -p writer chat -q {json.dumps(QUERY_ASK)}"
    asked = shell(query, query)
    quiet = f"hermes -p ops chat --in ~ -c 'Bot Chat' --create-if-missing -Q --query-file /tmp/hermes-dm/dm_5c2e.txt"
    silent = shell(quiet, quiet)
    with LOCK:
        PROCS[silent]["forget"] = True
    # The model writes its answer: the steps stay live a while, as they would.
    time.sleep(8)
    answer = "I've messaged Ada and Ops, and asked Ada about the blog post. Their answers will show here."
    stream(sid, answer)
    finish(sid, stored, answer)

    def notice(pid, output, code=0, outcome="completed normally"):
        with LOCK:
            command = PROCS[pid]["command"]
        text, meta = B["process_notice"](pid, command, code, output, outcome=outcome)
        B["add_message"](stored, "user", text, display_kind="process_complete", display_metadata=meta)

    def later():
        notice(unheard, "")
        time.sleep(2)
        exit_process(silent, 0)
        notice(silent, "")
        time.sleep(1.5)
        reply = json.dumps({"reply": ADA_REPLY, "status": "delivered", "delivery_id": "dm"})
        write(ada, reply + "\n")
        exit_process(ada, 0)
        notice(ada, reply)
        time.sleep(1.5)
        write(asked, QUERY_REPLY + "\n")
        exit_process(asked, 0)
        notice(asked, QUERY_REPLY)
        time.sleep(15)
        line = "No reply from @ops within 600s."
        write(ops, line + "\n")
        exit_process(ops, 0)
        notice(ops, line)

    threading.Thread(target=later, daemon=True).start()


# "background tasks": what each check prints, how long it runs and how it exits (invented).
TASKS = [
    ("python3 -B -m unittest discover -s tests", 5,
     "..........F.\n======================================================================\n"
     "FAIL: test_offline_edit_survives_sync (tests.test_sync.SyncTests)\n"
     "----------------------------------------------------------------------\n"
     "AssertionError: 2 != 3\n\nRan 12 tests in 0.84s\n\nFAILED (failures=1)\n", 1),
    ("git fetch origin && git status -sb", 3, "## main...origin/main [behind 2]\n", 0),
    ("swift build", 9, "Building for debugging...\n[412/412] Compiling Trailhead Map.swift\nBuild complete! (8.71s)\n", 0),
    ("ruff check .", 9.5, "All checks passed!\n", 0),
]
DOCS_BUILD = ("cd ~/Code/trailhead-docs && npm run docs:build", 25,
              "> trailhead-docs@2.4.0 docs:build\n> astro build\n\n 48 page(s) built in 23.9s\n Complete!\n")


def run_tasks(sid, stored, *, stream, finish):
    """The words "background tasks": five checks started in the background, then their completion
    notices stored as Hermes stores them (tools/process_registry_notifications.py): the gateway's
    batch row for two that landed together (`[IMPORTANT: 2 background processes completed for this
    session.` and a `- proc_…: exit_code=…` line each) and two single rows with nothing between,
    which the app shows as one group; the long docs build alone; and a completion
    Hermes knew nothing about (`Command: unknown`, no output)."""
    def shell(command):
        pid = start(stored, command, f"{HOME}/Code/trailhead", notify=True)
        call_tool(sid, stored, "terminal", {"command": command, "background": True, "notify_on_complete": True},
                  {"output": "Background process started", "session_id": pid, "pid": 40021, "exit_code": 0, "error": None,
                   "notify_on_complete": True}, 0.3, command)
        return pid

    pids = [shell(command) for command, _, _, _ in TASKS]
    docs = shell(DOCS_BUILD[0])
    answer = "The tests, a fetch, a build, the lint and the docs build are running. I'll look at them as they finish."
    stream(sid, answer)
    result = finish(sid, stored, answer)

    def notice(pid, command, code, output):
        outcome = "completed normally" if code == 0 else "exited"
        return (f"[IMPORTANT: Background process {pid} {outcome} (exit code {code}).\n"
                f"Command: {command}\nOutput:\n{output}]")

    def store(text, title):
        B["store_row"](sid, stored, "user", text, display_kind="process_complete",
                       display_metadata={"display_text": title})

    def later():
        began = time.time()
        for (command, seconds, output, code), pid in sorted(zip(TASKS, pids), key=lambda item: item[0][1]):
            time.sleep(max(0, began + seconds - time.time()))
            write(pid, output)
            exit_process(pid, code)
        blocks = [notice(pid, command, code, output.rstrip("\n")) for (command, _, output, code), pid in zip(TASKS, pids)]
        # Completions that land together come as one row: the gateway's own batch
        # (gateway/run_notifications.py `_format_coalesced_process_completions`), which names only
        # ids and, on the app's local sessions, is tagged `process_complete`. The rest come alone.
        lines = ["[IMPORTANT: 2 background processes completed for this session.",
                 "Treat these results as one completion batch and send at most one consolidated user-facing response."]
        for (command, _, output, code), pid in list(zip(TASKS, pids))[:2]:
            lines += [f"\n- {pid}: exit_code={code}, reason=exited", output.strip()]
        lines.append("If a result does not change the current conclusion, absorb it silently.]")
        store("\n".join(lines), "2 Background Processes Finished")
        store(blocks[2], f"Background Process Finished: {TASKS[2][0]}")
        store(blocks[3], f"Background Process Finished: {TASKS[3][0]}")
        B["store_row"](sid, stored, "assistant", "The tests failed: `test_offline_edit_survives_sync` expects 3 edits "
                       "and gets 2. The fetch, the build and the lint are fine.", finish_reason="stop")
        time.sleep(max(0, began + DOCS_BUILD[1] - time.time()))
        write(docs, DOCS_BUILD[2])
        exit_process(docs, 0)
        store(notice(docs, DOCS_BUILD[0], 0, DOCS_BUILD[2].rstrip("\n")), f"Background Process Finished: {DOCS_BUILD[0]}")
        B["store_row"](sid, stored, "assistant", "The docs built: 48 pages.", finish_reason="stop")
        time.sleep(3)
        # Hermes writes "unknown" when the event lost its command (format_process_notification).
        store(f"[IMPORTANT: Background process proc_{uuid.uuid4().hex[:12]} completed normally (exit code 0).\n"
              "Command: unknown\nOutput:\n]", "Background Process Finished")
        B["store_row"](sid, stored, "assistant", "Something started before this chat finished too; nothing to do.",
                       finish_reason="stop")

    threading.Thread(target=later, daemon=True).start()
    return result


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
