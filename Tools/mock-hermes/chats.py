"""Normal chats over the gateway protocol, for the combined mock.

The real `hermes gateway` (API server) and `hermes serve` (backend) share one session
database, so the app can run any chat over the backend's `/api/ws`. This module gives the
mock the same property: `backend.py --gateway-port 18642` serves the API-server mock
(server.py) from the same process, and the socket methods below create, resume and run
its sessions, writing turns into its store. Bot Chats keep backend.py's own scripts.

Scripted chat behaviour by message content (gateway-protocol events):
  contains "approve"  -> asks to run a command (an `approval` server request)
  contains "fail"     -> the turn fails (recoverable)
  contains "key expired" / "signed out" -> the provider refused its key / sign-in (error_surface)
  contains "slow"     -> a long multi-tool turn (stop, reconnect)
  contains "short"    -> a two-sentence answer after a pause, no tools
  anything else       -> a plan, a web search, a command and a file edit, then the answer
"""

import json
import re
import threading
import time
import uuid

B = None  # backend.py's module globals
G = None  # server.py (API-server mock) module


def install(backend_globals, gateway_module):
    global B, G
    B, G = backend_globals, gateway_module
    methods = B["METHODS"]

    def say_in_room(query, body):
        # Mock-only: the person says something in a group chat (`{"room", "text"}`), as if typed,
        # so the room's discussion runs (turn.started, replies, hand-offs) without driving the UI.
        room = ROOMS.get(body.get("room") or "") or next(iter(ROOMS.values()), None)
        if room is None:
            return 404, {"detail": "No room"}
        threading.Thread(target=run_discussion, args=(room, body.get("text") or "What do we still need?"), daemon=True).start()
        return 200, {"ok": True, "room": room["room_id"]}

    B["HTTP_ROUTES"][("POST", "/api/mock/room-say")] = say_in_room
    B["CHAT_TURN_ELSEWHERE"] = turn_elsewhere
    original = {name: methods[name] for name in ("session.create", "session.resume", "prompt.submit")}

    def create(params):
        if params.get("hidden") or (params.get("profile") or "default") != "default" or params.get("title") == B["BOT_CHAT"]:
            return original["session.create"](params)
        return create_chat(params)

    def resume(params):
        stored = params.get("session_id") or ""
        with G.LOCK:
            known = stored in G.SESSIONS
        return resume_chat(params) if known else original["session.resume"](params)

    def submit(params):
        sid = params.get("session_id") or ""
        runtime = B["RUNTIME"].get(sid)
        if runtime is None or runtime.get("kind") != "chat":
            return original["prompt.submit"](params)
        return submit_chat(sid, runtime, params.get("text") or "", bool(params.get("queued")))

    B["CHATS_HOOKS"].update({"add_message": G.add_message, "finish": finish})
    methods["session.create"] = create
    methods["session.resume"] = resume
    methods["prompt.submit"] = submit
    methods["config.set"] = config_set
    methods["file.attach"] = file_attach
    methods["pdf.attach"] = pdf_attach
    methods["prompt.btw"] = prompt_btw
    methods["session.steer"] = session_steer
    methods["commands.catalog"] = commands_catalog
    methods["complete.slash"] = complete_slash
    methods["slash.exec"] = slash_exec
    methods["command.dispatch"] = command_dispatch
    methods["complete.path"] = complete_path
    methods["shell.exec"] = shell_exec
    methods["connection.respond"] = connection_respond
    methods["session.branch"] = session_branch
    methods["prompt.background"] = prompt_background
    methods["process.list"] = process_list
    methods["process.kill"] = process_kill
    for name, fn in GROUP_METHODS.items():
        methods[name] = fn
    seed_rooms()
    methods["tools.configure"] = lambda params: {"changed": params.get("names") or [], "action": params.get("action")}


def new_chat_runtime(stored):
    sid = B["new_runtime"](stored, "default")
    B["RUNTIME"][sid]["kind"] = "chat"
    return sid


def create_chat(params):
    stored = f"{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
    now = time.time()
    with G.LOCK:
        G.session_row(stored, params.get("title") or "", params.get("source") or "hermes_app", now, now, "",
                      model=params.get("model") or "anthropic/claude-sonnet-4.6")
    sid = new_chat_runtime(stored)
    return {"session_id": sid, "stored_session_id": stored, "message_count": 0, "messages": [],
            "info": {"model": params.get("model") or "anthropic/claude-sonnet-4.6", "running": False}}


def resume_chat(params):
    stored = params["session_id"]
    with B["LOCK"]:
        # A runtime Hermes let go (a reap, a restart) isn't resumed: the chat gets a fresh one.
        sid = next((k for k, r in B["RUNTIME"].items() if r["stored"] == stored and not r.get("dead")), None) \
            or new_chat_runtime(stored)
        runtime = B["RUNTIME"][sid]
    with G.LOCK:
        count = len(G.MESSAGES.get(stored, []))
    return {"session_id": sid, "resumed": stored, "message_count": count, "messages": [], "messages_omitted": True,
            "info": {"model": "anthropic/claude-sonnet-4.6", "running": runtime["running"]},
            **B["live_turn"](runtime), "running": runtime["running"], "session_key": stored,
            "status": "streaming" if runtime["running"] else "idle", "open_requests": B["open_requests"](sid),
            "queued": {"user": runtime["queue"][0]["text"]} if runtime.get("queue") else None}


def turn_elsewhere(stored, text, reply, seconds):
    """backend.py's `turn_elsewhere` for a normal chat (`/api/mock/turn-elsewhere`): Hermes starts a
    turn by itself, its events go to whoever is attached, and a reap stops it where it is."""
    with G.LOCK:
        if stored not in G.SESSIONS:
            return False
    with B["LOCK"]:
        sid = next((k for k, r in B["RUNTIME"].items()
                    if r["stored"] == stored and not r.get("dead") and not r["running"]), None)
    if sid is None:
        G.add_message(stored, "user", text, display_kind="internal_notification")
        G.add_message(stored, "assistant", reply, finish_reason="stop")
        return True

    def run():
        with B["LOCK"]:
            runtime = B["RUNTIME"][sid]
            runtime.update(running=True, interrupt=False, turn_started=time.time())
            runtime["inflight"] = {"user": text, "assistant": "", "streaming": True, "display_kind": "internal_notification"}
        G.add_message(stored, "user", text, display_kind="internal_notification")
        emit(sid, "session.info", {"running": True})
        emit(sid, "message.start", {})
        deadline = time.time() + max(0.0, seconds - 2)
        while time.time() < deadline:
            if interrupted(sid):
                return
            time.sleep(0.2)
        if not stream(sid, reply, delay=2 / max(1, len(reply) / 7)) or B["RUNTIME"][sid].get("dead"):
            return
        finish(sid, stored, reply)
    threading.Thread(target=run, daemon=True).start()
    return True


def submit_chat(sid, runtime, text, queued=False):
    gated = B["submit_gate"](sid, runtime, text)
    if gated is not None:
        return gated
    with B["LOCK"]:
        busy = runtime["running"]
    if busy:
        return B["busy_submit"](sid, text, queued)
    B["start_turn"](sid, text, run_chat_turn)
    return {"status": "streaming"}


def config_set(params):
    key, value = params.get("key", ""), params.get("value", "")
    if key == "busy" and value in ("queue", "steer", "interrupt"):
        B["BUSY"]["mode"] = value  # display.busy_input_mode, for every client
    if key == "model" and any(w in value.lower() for w in ("opus", "expensive")) and not params.get("confirm_expensive_model"):
        # Like Hermes's selection guards: an expensive model waits for the person to confirm.
        message = f"{value.split(' --')[0]} costs about 5x more per token than your current model."
        return {"key": key, "value": value, "warning": message, "confirm_required": True, "confirm_message": message}
    return {"key": key, "value": value, "scope": "session" if params.get("session_id") else "global"}


def file_attach(params):
    B["runtime_for"](params)
    name = params.get("name") or "file"
    path = f"/home/hermes/.hermes/uploads/{uuid.uuid4().hex[:6]}/{name}"
    return {"attached": True, "name": name, "path": path, "ref_path": path, "ref_text": f"@file:{path}", "uploaded": True}


def pdf_attach(params):
    B["runtime_for"](params)
    name = params.get("filename") or "document.pdf"
    if "nopdftoppm" in name:
        raise B["RPCError"](5000, "pdftoppm is not installed on this host")
    return {"attached": True, "filename": name, "pages_attached": 2,
            "pages": [{"path": f"/tmp/{name}-1.png", "page": 1}, {"path": f"/tmp/{name}-2.png", "page": 2}],
            "count": 2, "text": ""}


def prompt_btw(params):
    sid = params.get("session_id") or ""
    question = params.get("text") or ""
    task = f"btw_{uuid.uuid4().hex[:6]}"

    def answer():
        emit(sid, "btw.complete", {"task_id": task, "question": question,
                                   "text": "It runs the release target: a clean build, strips symbols and signs the app with your Developer ID."})
    threading.Timer(1.6, answer).start()
    return {"task_id": task}


def session_steer(params):
    # The same as a Bot's: rejected when idle, 4010 while the turn's agent is built, else queued.
    return B["method_session_steer"](params)


# ── Commands and skills ──────────────────────────────────────────────────────

SKILLS = {
    "github-pr-workflow": "Open, review and land pull requests with the gh CLI.",
    "arxiv": "Search and summarise arXiv papers.",
    "synology": "Manage a Synology NAS over SSH.",
    "test-driven-development": "Write the failing test first, then the code.",
    "gh-issues": "Triage and update GitHub issues.",
}
COMMANDS = [
    ("new", "Start a new session"), ("retry", "Resend your last message"), ("undo", "Remove the last exchange"),
    ("title", "Rename this chat"), ("steer", "Add a note after the next tool call"),
    ("queue", "Send this next, without interrupting"), ("btw", "Ask a side question"), ("goal", "Set a standing goal"),
    ("plan", "Plan before doing"), ("usage", "Token usage"), ("status", "Session status"),
    ("context", "Context window"), ("compress", "Compress the conversation"), ("model", "Switch model"),
    ("reasoning", "Reasoning effort"), ("help", "Show commands"), ("tools", "List tools"),
    ("kanban", "Show the task board"), ("reload-mcp", "Reload MCP servers from config"),
    ("login", "Sign in to a model provider"), ("voice", "Toggle voice mode"),
    ("copy", "Copy the last assistant response to clipboard"), ("paste", "Attach clipboard image from your clipboard"),
    ("update", "Update Hermes Agent to the latest version"), ("quit", "Exit the CLI (use --delete to also remove session history)"),
]
# Like Hermes's registry (`hermes_cli/commands.py`): the category each command is listed under, and
# where it's offered outside a terminal (`CommandDef.desktop`: None offered, "hidden" kept out of
# the popover, otherwise why not). Gateway-only commands (/restart, /approve) aren't in the
# catalog at all, as in `tui_gateway`'s `commands.catalog`.
CATEGORY = {"usage": "Info", "status": "Info", "context": "Info", "help": "Info", "update": "Info", "copy": "Info", "paste": "Info",
            "model": "Configuration", "reasoning": "Configuration", "reload-mcp": "Configuration", "login": "Configuration",
            "voice": "Configuration", "tools": "Tools & Skills", "kanban": "Tools & Skills", "quit": "Exit"}
DESKTOP = {"model": "hidden", "reload-mcp": "advanced", "login": "settings", "voice": "composer-voice",
           "copy": "terminal", "paste": "terminal", "update": "terminal", "quit": "terminal"}
ARGUMENT_MODES = {"model": "options", "reasoning": "options", "voice": "options"}


def commands_catalog(params):
    """`commands.catalog`: registry pairs, then skills (also in `pairs`, keyed "/name" as Hermes keys
    them), per-command composer metadata, categories in registry order, and the alias map."""
    pairs = [[f"/{n}", d] for n, d in COMMANDS]
    categories = {}
    for n, d in COMMANDS:
        categories.setdefault(CATEGORY.get(n, "Session"), []).append([f"/{n}", d])
    skills = {f"/{n}": {"usage": len(d) % 7, "origin": "local"} for n, d in SKILLS.items()}
    pairs += [[f"/{n}", d] for n, d in SKILLS.items()]
    return {"pairs": pairs, "sub": {}, "canon": {"/reset": "/new", "/compact": "/compress", **{f"/{n}": f"/{n}" for n, _ in COMMANDS}},
            "commands": {f"/{n}": {"argument_mode": ARGUMENT_MODES.get(n, "text" if n in ("new", "title", "goal", "steer", "queue", "btw", "plan") else None),
                                   "desktop": DESKTOP.get(n)} for n, _ in COMMANDS},
            "categories": [{"name": name, "pairs": rows} for name, rows in categories.items()],
            "skills": skills, "skill_count": len(skills), "warning": ""}


def complete_slash(params):
    text = (params.get("text") or "/").lstrip("/").lower()
    items = [{"text": f"/{n}", "display": f"/{n}", "meta": d, "kind": "skill"} for n, d in SKILLS.items() if n.startswith(text)]
    items += [{"text": f"/{n}", "display": f"/{n}", "meta": d, "kind": "command"} for n, d in COMMANDS if n.startswith(text)]
    return {"items": items, "replace_from": 0}


def slash_exec(params):
    command = (params.get("command") or "").strip().lstrip("/")
    name, _, arg = command.partition(" ")
    if name in SKILLS:
        raise B["RPCError"](4018, f"skill command: use command.dispatch for /{name}")
    if name == "goal" and arg in ("clear", "stop"):
        return {"output": "Goal cleared."}
    if name in ("goal", "plan", "queue", "steer", "retry", "undo"):
        # Like Hermes: the pending-input built-ins answer with command.dispatch's directive.
        return command_dispatch({"name": name, "arg": arg, "session_id": params.get("session_id")})
    if name == "usage":
        return {"output": "Model: Claude Sonnet 4.6 · OpenRouter\nTokens: 48,210 in · 6,904 out\nCost: $0.25\nContext: 31% of 200K\nDuration: 42 min"}
    if name == "status":
        return {"output": "Session: idle\nModel: claude-sonnet-4.6\nTools: 24 enabled\nUptime: 3 h 12 min"}
    if name == "context":
        return {"output": "System prompt: 6,120 tokens\nTools: 9,804 tokens\nMessages: 46,320 tokens\nFree: 137,756 tokens"}
    if name in ("compress", "compact"):
        return {"output": "Compressed 42 messages into a 1,180-token summary."}
    if name == "help":
        return {"output": "\n".join(f"/{n}  {d}" for n, d in COMMANDS)}
    if name == "kanban":
        return {"output": "Todo 3 · Doing 1 · Done 12"}
    raise B["RPCError"](4018, f"not a quick/plugin/bundle/skill command: /{name}")


def command_dispatch(params):
    name, arg = (params.get("name") or "").lstrip("/"), params.get("arg") or ""
    if name in SKILLS:
        stacked = [w.lstrip("/") for w in arg.split() if w.startswith("/") and w.lstrip("/") in SKILLS]
        body = " ".join(w for w in arg.split() if not (w.startswith("/") and w.lstrip("/") in SKILLS))
        loaded = ", ".join([name] + stacked)
        return {"type": "skill", "name": name, "display": f"/{name} {arg}".strip(),
                "message": f"[The person invoked skills: {loaded}. Follow their instructions.]\n\n{body}"}
    if name == "goal":
        return {"type": "send", "message": f"Standing goal: {arg}. Work toward it.", "display": "/goal resume", "notice": "Goal set"}
    if name in ("plan", "queue", "steer"):
        return {"type": "send", "message": arg or name, "display": f"/{name} {arg}".strip()}
    if name == "undo":
        return {"type": "prefill", "message": "the message you removed"}
    raise B["RPCError"](4018, f"not a quick/plugin/bundle/skill command: /{name}")


PATHS = ["CHANGELOG.md", "Sources/", "Sources/Sync/", "Sources/Sync/Reconnect.swift", "Sources/Sync/Backoff.swift",
         "Package.swift", "README.md", "Tests/SyncTests.swift"]

FILES = {
    "CHANGELOG.md": "## 1.3\n- Faster reconnect after sleep\n- Skills in the composer\n- Bots and files as pills\n\n## 1.2\n- Group chats\n- Voice mode\n",
    "Sources/Sync/Reconnect.swift": "import Foundation\n\n/// Reconnects with backoff after the Mac wakes.\nstruct Reconnect {\n    var attempt = 0\n}\n",
    "README.md": "# Hermes\n\nAn always-on agent for your Mac and iPhone.\n",
}


def shell_exec(params):
    """File previews for pills: `wc -c < 'path' && head -c N -- 'path'`, `ls -1p -- 'path'`."""
    command = params.get("command") or ""
    quoted = re.findall(r"'((?:[^']|'\\'')*)'", command)
    path = quoted[0].replace("'\\''", "'") if quoted else ""
    if command.startswith("ls "):
        prefix = path.rstrip("/") + "/"
        names = sorted({p[len(prefix):].split("/")[0] + ("/" if "/" in p[len(prefix):] else "") for p in PATHS if p.startswith(prefix) and p != prefix})
        return {"stdout": "\n".join(names) + "\n", "stderr": "", "code": 0} if names else {"stdout": "", "stderr": "no such directory", "code": 1}
    if path in FILES:
        text = FILES[path]
        return {"stdout": f"{len(text.encode()) * 220}\n{text}", "stderr": "", "code": 0}
    return {"stdout": "", "stderr": f"{path}: No such file or directory", "code": 1}


def complete_path(params):
    word = (params.get("word") or "@").lstrip("@")
    if word.startswith("file:") or word.startswith("folder:"):
        word = word.split(":", 1)[1]
    items = []
    for path in PATHS:
        if path.lower().startswith(word.lower()) or (word and word.lower() in path.lower()):
            kind = "folder" if path.endswith("/") else "file"
            items.append({"text": f"@{kind}:{path}", "display": path, "meta": "dir" if kind == "folder" else "2 KB"})
    return {"items": items[:10]}


PROCESSES = {}  # process_id -> {"command", "running", "started"}


def prompt_background(params):
    sid = params.get("session_id") or ""
    task = f"bg_{uuid.uuid4().hex[:6]}"

    def done():
        emit(sid, "background.complete", {"task_id": task, "text": "Audited 14 targets for strict concurrency · 3 need changes.\n\n"
                                          "- **HermesKit**: 2 warnings in `GatewaySocket`\n- **App**: 1 `@unchecked Sendable`\n- **Widgets**: clean"})
    threading.Timer(3.0, done).start()
    return {"task_id": task}


def process_list(params):
    return {"processes": [{"id": pid, "command": p["command"], "started_at": p["started"], "running": p["running"]}
                          for pid, p in PROCESSES.items()]}


def process_kill(params):
    pid = params.get("process_id") or ""
    if pid in PROCESSES:
        PROCESSES[pid]["running"] = False
    return {"killed": True}


def run_dev_server(sid):
    pid = f"proc_{uuid.uuid4().hex[:6]}"
    PROCESSES[pid] = {"command": "npm run dev", "running": True, "started": time.time() - 120}
    lines = ["> hermes-app@1.3 dev\n", "Server listening on :5173\n"]
    for line in lines:
        emit(sid, "agent.terminal.output", {"process_id": pid, "chunk": line})
        time.sleep(0.4)
    n = 0
    while PROCESSES[pid]["running"] and n < 60:
        emit(sid, "agent.terminal.output", {"process_id": pid, "chunk": f"GET /api/health 200 {3 + n % 4} ms\n"})
        time.sleep(1.5)
        n += 1
    emit(sid, "terminal.close", {"process_id": pid})


def session_branch(params):
    """A new chat with the first `count` visible rows (user / assistant with text)."""
    sid = params.get("session_id") or ""
    runtime = B["RUNTIME"].get(sid)
    if runtime is None:
        raise B["RPCError"](4001, "session not found")
    parent = runtime["stored"]
    with G.LOCK:
        rows = [dict(r) for r in G.MESSAGES.get(parent, []) if r["role"] in ("user", "assistant") and (r.get("content") or "").strip()]
        title = (G.SESSIONS.get(parent) or {}).get("title") or "Branch"
    count = params.get("count")
    if isinstance(count, (int, float)) and count > 0:
        rows = rows[:int(count)]
    if not rows:
        raise B["RPCError"](4008, "nothing to branch — send a message first")
    stored = f"{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
    now = time.time()
    with G.LOCK:
        G.session_row(stored, f"{title} (branch)", "hermes_app", now, now, "")
    for r in rows:
        G.add_message(stored, r["role"], r["content"])
    new_sid = new_chat_runtime(stored)
    return {"session_id": new_sid, "stored_session_id": stored, "title": f"{title} (branch)", "parent": parent,
            "message_count": len(rows), "messages_omitted": True}


# ── Requests (docs/quick-actions.md) ─────────────────────────────────────────

CONNECTIONS = {}  # op_id -> {"event": threading.Event, "result": ...}


def connection_respond(params):
    op = params.get("op_id") or ""
    entry = CONNECTIONS.get(op)
    if entry is None:
        return {"status": "expired", "settled": False}
    entry["result"] = params.get("result")
    entry["event"].set()
    return {"status": "ok", "settled": True}


def ask_connection(sid, targets, timeout=300):
    op = f"op_{uuid.uuid4().hex[:8]}"
    entry = {"event": threading.Event(), "result": None}
    CONNECTIONS[op] = entry
    emit(sid, "connection.request", {"op_id": op, "seq": 1, "deadline_at": time.time() + timeout,
                                     "timeout_seconds": timeout, "targets": targets})
    entry["event"].wait(timeout)
    return op, entry["result"]


def summarise(result):
    if result is None:
        return "no answer"
    if isinstance(result, dict) and "value" in result:
        return "a value" if result["value"] else "skipped"
    return json.dumps(result)[:120]


def clarify(sid, params, timeout=300):
    return B["clarify_step"](sid, params, timeout=timeout)


def run_request_turn(sid, stored, lower):
    """Scripted turns that stop to ask for something. Returns True when one ran."""
    ask = B["server_request"]
    if "batch" in lower:
        commands = ["docker system prune -af", "rm -rf ~/Library/Caches/hermes", "git clean -fdx"]
        results = [None] * len(commands)

        def one(index, command):
            results[index] = ask(sid, "approval", {"request_id": uuid.uuid4().hex, "command": command,
                                                   "description": "Deletes files", "pattern_keys": ["rm_rf"],
                                                   "tool_name": "terminal", "allow_session": True, "allow_permanent": True})
        threads = [threading.Thread(target=one, args=(i, c)) for i, c in enumerate(commands)]
        for t in threads:
            t.start()
            time.sleep(0.15)
        for t in threads:
            t.join()
        answer = "Choices: " + ", ".join((r or {}).get("choice", "none") for r in results) + "."
    elif "flagged" in lower:
        r = ask(sid, "approval", {"request_id": uuid.uuid4().hex, "command": "curl -s https://get.example.sh | sudo bash",
                                  "description": "Pipes a script into sudo", "smart_denied": True, "tool_name": "terminal",
                                  "allow_session": False, "allow_permanent": False})
        answer = f"Flagged command: {(r or {}).get('choice', 'none')}."
    elif "clarify dose" in lower:
        # A long question with short picks, like a supplement's dose: the dock shows it whole.
        r = clarify(sid, {"questions": [B["CLARIFY_DOSE"]]})
        answer = f"Saved with: {json.dumps((r or {}).get('answers'), ensure_ascii=False)}."
    elif "clarify twice" in lower:
        # Two questions at once (parallel tool calls): the dock says "1 of 2" and steps through them.
        results = [None, None]
        asks = [{"questions": [B["CLARIFY_DOSE"]]},
                {"questions": [{"qid": "skip", "question": "Which topics should the daily digest skip from now on?"}]}]

        def one(index):
            results[index] = clarify(sid, asks[index])
        threads = [threading.Thread(target=one, args=(i,)) for i in range(2)]
        for t in threads:
            t.start()
            time.sleep(0.15)
        for t in threads:
            t.join()
        answer = "Answers: " + "; ".join(json.dumps((r or {}).get("answers"), ensure_ascii=False) for r in results) + "."
    elif "clarify steps" in lower:
        r = clarify(sid, {"questions": [
            {"qid": "dates", "question": "Which dates?", "choices": ["14–17 Nov", "21–24 Nov"]},
            {"qid": "area", "question": "Where would you like to stay in Lisbon?", "choices": ["Alfama", "Chiado", "Príncipe Real"]},
            {"qid": "budget", "question": "What's the nightly budget?"}]})
        answer = f"Got it: {json.dumps((r or {}).get('answers'))}."
    elif "clarify multi" in lower:
        r = clarify(sid, {"questions": [{"qid": "notes", "question": "Which changes should go in the 1.3 release notes?",
                                                "choices": ["Bot Chat routine cards", "Faster reconnects", "Typed throws migration", "Internal refactors"],
                                                "multi_select": True}]})
        answer = f"Including: {json.dumps((r or {}).get('answers'))}."
    elif "clarify open" in lower:
        r = clarify(sid, {"questions": [{"qid": "skip", "question": "Which topics should the daily digest skip from now on?"}]})
        answer = f"Noted: {json.dumps((r or {}).get('answers'))}."
    elif "clarify pair" in lower:
        r = clarify(sid, {"questions": B["CLARIFY_PAIR"]})
        answer = f"Set up with: {json.dumps((r or {}).get('answers'), ensure_ascii=False)}."
    elif "clarify long" in lower:
        # A real ask: a long question, and picks too long for one line (three on an iPhone).
        r = clarify(sid, {"questions": [{"qid": "swap", "question": "Pull Appeeky volume and difficulty for replacement keywords (e.g. carryon, camping, flight, beach, essentials) and bring you an exact keyword-field swap? Costs roughly 20–30 Appeeky credits.",
                                                "choices": ["Yes, research and draft the swap, then note which keywords changed and why (Recommended, about 25 credits)", "Leave keywords as they are",
                                                            "Draft from judgement, no credit spend"]}]})
        answer = f"Going with: {json.dumps((r or {}).get('answers'))}."
    elif "clarify" in lower:
        r = clarify(sid, {"questions": [{"qid": "db", "question": "Which database should I run the migration against first?",
                                                "choices": ["Staging — Safe to reset; refreshed nightly", "Production — Takes a backup first",
                                                            "A local copy — Docker, on this Mac"]}]})
        answer = f"Running against: {json.dumps((r or {}).get('answers'))}."
    elif "secret" in lower:
        r = ask(sid, "secret", {"env_var": "ARXIV_API_KEY", "prompt": "Paste your arXiv API key so the digest can use the full-text search."})
        answer = f"Secret: {summarise(r)}."
    elif "sudo" in lower:
        r = ask(sid, "sudo", {"command": "sudo systemctl restart nginx"})
        answer = f"Sudo: {summarise(r)}."
    elif "unlock" in lower:
        r = ask(sid, "vault.unlock_prompt", {"backend": "onepassword", "display_name": "1Password"})
        answer = f"Vault: {summarise(r)}."
    elif "save login" in lower:
        r = ask(sid, "vault.save_login", {"origin": "https://linear.app", "site": "linear.app"})
        answer = f"Login: {summarise(r)}."
    elif "2fa" in lower:
        r = ask(sid, "vault.code", {"site": "github.com"})
        answer = f"Code: {summarise(r)}."
    elif "choose accent" in lower:
        r = ask(sid, "setup_choose", {"kind": "accent", "question": "Which colour should this gateway use in the sidebar?",
                                      "options": [{"id": a, "label": a.capitalize()} for a in
                                                  ["graphite", "gold", "ember", "rose", "violet", "ocean", "mint", "lime"]]})
        answer = f"Accent: {json.dumps(r)}."
    elif "choose theme" in lower:
        r = ask(sid, "setup_choose", {"kind": "theme", "question": "Hermes can follow your device or stay light or dark.",
                                      "options": [{"id": "system", "label": "System"}, {"id": "light", "label": "Light"}, {"id": "dark", "label": "Dark"}]})
        answer = f"Theme: {json.dumps(r)}."
    elif "choose apps" in lower:
        r = ask(sid, "setup_choose", {"kind": "connectors", "question": "Which of these should Hermes be able to use?", "multi_select": True,
                                      "preselected": ["github", "linear"],
                                      "options": [{"id": "github", "label": "GitHub", "detail": "Issues, pull requests and code search"},
                                                  {"id": "linear", "label": "Linear", "detail": "Create and update issues"},
                                                  {"id": "gcal", "label": "Google Calendar", "detail": "Read and add events"}]})
        answer = f"Apps: {json.dumps(r)}."
    elif "connect linear" in lower:
        op, r = ask_connection(sid, [{"name": "linear", "kind": "mcp", "action": "connect", "origin": "official", "scan": "passed",
                                      "detail": "Read and update Linear issues from chat: search, create, assign, comment.",
                                      "required_env": [{"name": "LINEAR_API_KEY", "required": True, "secret": True},
                                                       {"name": "LINEAR_TEAM", "required": False, "secret": False, "default": "ENG"}]}])
        answer = f"Linear: {summarise(r)}."
    elif "sign in" in lower:
        op = None

        def follow():
            time.sleep(4)
            for o, e in list(CONNECTIONS.items()):
                if e["result"] is not None and o == follow.op:
                    emit(sid, "connection.update", {"op_id": o, "targets": [{"name": "github", "state": "connected"}]})
                    time.sleep(2.5)
                    emit(sid, "connection.update", {"op_id": o, "settled": True, "targets": [{"name": "github", "state": "connected"}]})
        targets = [{"name": "github", "kind": "connector", "action": "authorize",
                    "connect_url": "https://github.com/login/oauth/authorize?client_id=mock",
                    "detail": "Hermes will open pull requests and read issues as your account. You can disconnect any time."}]
        opid = f"op_{uuid.uuid4().hex[:8]}"
        follow.op = opid
        entry = {"event": threading.Event(), "result": None}
        CONNECTIONS[opid] = entry
        emit(sid, "connection.request", {"op_id": opid, "seq": 1, "timeout_seconds": 300, "targets": targets})
        entry["event"].wait(300)
        follow()
        answer = "GitHub is connected; carrying on."
    elif "install" in lower:
        op, r = ask_connection(sid, [
            {"name": "excalidraw", "kind": "skill", "action": "install", "origin": "official", "scan": "passed",
             "detail": "Sketch diagrams as .excalidraw files."},
            {"name": "mermaid-render", "kind": "plugin", "action": "install", "origin": "community", "scan": "warnings",
             "detail": "Render Mermaid diagrams to SVG."}])
        answer = f"Add-ons: {summarise(r)}."
    elif "timeout" in lower:
        r = clarify(sid, {"questions": [{"qid": "x", "question": "Quick check: go ahead?", "choices": ["Yes", "No"]}]}, timeout=6)
        answer = "No answer, so I carried on with the safe default."
    else:
        return False
    stream(sid, answer)
    finish(sid, stored, answer)
    return True


# ── Hosted group chats (groups.*) ─────────────────────────────────────────────

ROOMS = {}
ROOMS_LOCK = threading.Lock()
MEMBER_LINES = {
    "default": "Three things before Friday: release notes, a backup before the deploy, and a short post. @writer, @ops, can you take yours?",
    "writer": "On it. I'll draft the release notes from the merged PRs and post them here by 15:00.",
    "ops": "Snapshot of the database and staging tonight, 02:00–02:20. I will confirm when it lands.",
    "researcher": None,  # passes
}


def room_member(profile, handle, name):
    return {"member_id": profile, "profile": profile, "handle": handle, "display_name": name,
            "target": {"kind": "local", "profile": profile}}


def room_row(room):
    return {"room_id": room["room_id"], "name": room["name"], "members": room["members"],
            "authority_gateway_id": "mock", "authority_epoch": 1, "revision": room["revision"],
            "created_at": room["created_at"], "updated_at": room["updated_at"], "idempotent": False,
            "latest_seq": len(room["events"])}


def room_event(room, kind, actor, payload):
    with ROOMS_LOCK:
        seq = len(room["events"]) + 1
        event = {"room_id": room["room_id"], "seq": seq, "event_id": f"ev{seq}", "kind": kind, "actor": actor,
                 "authority_epoch": 1, "payload": payload, "created_at": time.time(), "idempotent": False}
        room["events"].append(event)
        room["updated_at"] = event["created_at"]
    return event


def seed_rooms():
    if ROOMS:
        return
    members = [room_member("default", "hermes", "Hermes"), room_member("researcher", "researcher", "Research Buddy"),
               room_member("writer", "writer", "Ada"), room_member("ops", "ops", "Ops")]
    now = time.time()
    room = {"room_id": "launch-crew", "name": "Launch crew", "members": members, "revision": 1, "created_at": now - 3600,
            "updated_at": now - 1800, "events": [], "working": False, "pending": [], "stop": False}
    ROOMS[room["room_id"]] = room
    run_discussion(room, "We ship Hermes 1.3 on Friday. What do we still need?", wait=False)


def run_discussion(room, text, wait=True, approve=False, client_id=None):
    event = room_event(room, "message.user", {"kind": "user", "id": "desktop"}, {"text": text, "thread_id": "main"})
    if client_id:
        with ROOMS_LOCK:
            room.setdefault("sent", {})[client_id] = event["seq"]
    room["working"] = True
    room["stop"] = False
    delay = 1.2 if wait else 0
    order = [m["profile"] for m in room["members"]]
    turn = 0
    if wait and "together" in text.lower():
        # Mock-only: "together" has Research Buddy, Ada and Ops think at once (three `turn.started`
        # before any words, for 15 s), for the app's thinking lines: two named, then "+1 more".
        trio = [p for p in ("researcher", "writer", "ops") if p in order]
        started = []
        for profile in trio:
            turn += 1
            fields = {"discussion_event_id": "d1", "member_id": profile, "member_index": order.index(profile),
                      "round_index": 0, "task_id": f"task{turn}", "thread_id": "main", "turn_id": f"turn{turn}"}
            room_event(room, "turn.started", {"kind": "gateway", "id": "mock"}, fields)
            started.append((profile, fields))
        time.sleep(15)
        for profile, fields in started:
            if room["stop"]:
                break
            message = room_event(room, "message.member", {"kind": "member", "id": profile, "profile": profile}, {**fields, "text": MEMBER_LINES.get(profile) or "On it."})
            room_event(room, "turn.settled", {"kind": "gateway", "id": "mock"}, {**fields, "message_event_id": message["event_id"], "passed": False, "seen_through_seq": message["seq"]})
            time.sleep(delay)
        room_event(room, "room.activity", {"kind": "gateway", "id": "mock"}, {"status": "settled", "reason_code": "silent_round", "thread_id": "main", "discussion_event_id": "d1"})
        room["working"] = False
        return
    for round_index, speakers in enumerate([order, ["writer"]]):
        for profile in speakers:
            if profile not in order or room["stop"]:
                continue
            turn += 1
            fields = {"discussion_event_id": "d1", "member_id": profile, "member_index": order.index(profile),
                      "round_index": round_index, "task_id": f"task{turn}", "thread_id": "main", "turn_id": f"turn{turn}"}
            # Hermes logs the start of each member's turn (`turn.started`); the app's faces watch it.
            if wait:
                room_event(room, "turn.started", {"kind": "gateway", "id": "mock"}, fields)
            time.sleep(delay * 2)
            if approve and profile == "ops":
                room["pending"] = [{"kind": "approval", "task_id": f"task{turn}", "execution_generation": 1, "run_id": "r",
                                    "session_id": "s", "request_id": f"req{turn}", "member_id": "ops",
                                    "approval": {"command": "pg_dump hermes > /backups/hermes-1.3.sql",
                                                 "description": "Backs up the production database", "choices": ["once", "deny"]}}]
                while room["pending"] and not room["stop"]:
                    time.sleep(0.3)
            line = MEMBER_LINES.get(profile) if round_index == 0 else "Release notes are in: typed throws, Bot Chat routine cards and faster reconnects. Want the post in the same voice?"
            if line:
                message = room_event(room, "message.member", {"kind": "member", "id": profile, "profile": profile}, {**fields, "text": line})
                room_event(room, "turn.settled", {"kind": "gateway", "id": "mock"}, {**fields, "message_event_id": message["event_id"], "passed": False, "seen_through_seq": message["seq"]})
            else:
                room_event(room, "turn.settled", {"kind": "gateway", "id": "mock"}, {**fields, "message_event_id": None, "passed": True, "seen_through_seq": 0})
    room_event(room, "room.activity", {"kind": "gateway", "id": "mock"}, {"status": "settled", "reason_code": "silent_round", "thread_id": "main", "discussion_event_id": "d1"})
    room["working"] = False


def groups_capabilities(params):
    return {"protocol_version": 2, "driver": True, "persistent_process": True, "authority_gateway_id": "mock",
            "room_link": {"enabled": False}, "features": [], "methods": list(GROUP_METHODS), "max_log_limit": 500}


def groups_list(params):
    rows = [room_row(r) for r in sorted(ROOMS.values(), key=lambda r: -r["updated_at"]) if not r.get("disbanded")]
    return {"rooms": rows, "next_offset": None}


def group_room(params):
    room = ROOMS.get(params.get("room_id") or "")
    if room is None or room.get("disbanded"):
        raise B["RPCError"](4114, "room not found")
    return room


def groups_create(params):
    now = time.time()
    room = {"room_id": params["room_id"], "name": params.get("name") or "Group", "members": params.get("members") or [],
            "revision": 1, "created_at": now, "updated_at": now, "events": [], "working": False, "pending": [], "stop": False}
    ROOMS[room["room_id"]] = room
    return {"room": room_row(room)}


def groups_state(params):
    room = group_room(params)
    return {"room": room_row(room), "driver_status": {"running": True, "working": room["working"], "blocked": bool(room["pending"]),
                                                      "counts": {}, "pending_actions": room["pending"], "peer_routes": []}}


def groups_send(params):
    room = group_room(params)
    text = (params.get("payload") or {}).get("text") or ""
    client_id = params.get("event_id")
    # Like Hermes' hosted rooms (`user_event_id`): one person's message per event_id, so a send that
    # goes again after a timeout or a dropped socket gets the first one's event back.
    with ROOMS_LOCK:
        sent = room.setdefault("sent", {})
        seq = sent.get(client_id) if client_id else None
    if seq is not None:
        return {"event": room["events"][seq - 1], "client_event_id": client_id, "accepted": True, "driver_started": True}
    threading.Thread(target=run_discussion, args=(room, text), kwargs={"approve": "backup" in text.lower(), "client_id": client_id}, daemon=True).start()
    time.sleep(0.05)
    with ROOMS_LOCK:
        seq = sent.get(client_id)
    return {"event": room["events"][seq - 1] if seq else None, "client_event_id": client_id, "accepted": True, "driver_started": True}


def groups_log(params):
    room = group_room(params)
    since = int(params.get("since_seq") or 0)
    limit = int(params.get("limit") or 100)
    events = [e for e in room["events"] if e["seq"] > since][:limit]
    latest = len(room["events"])
    cursor = events[-1]["seq"] if events else since
    return {"events": events, "cursor": cursor, "latest_seq": latest, "has_more": cursor < latest,
            "authority": {"gateway_id": "mock", "epoch": 1}}


def groups_rename(params):
    room = group_room(params)
    room["name"] = params.get("name") or room["name"]
    event = room_event(room, "room.renamed", {"kind": "user", "id": "desktop"}, {"name": room["name"]})
    return {"room": room_row(room), "event": event}


def groups_disband(params):
    room = group_room(params)
    room["disbanded"] = True
    return {"tombstone": {"room_id": room["room_id"], "disbanded_at": time.time(), "idempotent": False}}


def groups_stop(params):
    room = group_room(params)
    room["stop"] = True
    room["pending"] = []
    return {"cancelled": 1}


def groups_approve(params):
    room = group_room(params)
    room["pending"] = []
    return {"approved": True, "result": {}}


def groups_retry(params):
    return {"retried": False, "task": {}}


GROUP_METHODS = {
    "groups.capabilities": groups_capabilities, "groups.list": groups_list, "groups.create": groups_create,
    "groups.state": groups_state, "groups.send": groups_send, "groups.log": groups_log, "groups.rename": groups_rename,
    "groups.disband": groups_disband, "groups.stop": groups_stop, "groups.approve": groups_approve, "groups.retry": groups_retry,
}


def take_steers(sid):
    """Steer Now messages arrive at the next step, as the gateway does: stored as a `steer` row."""
    stored = B["RUNTIME"][sid]["stored"]

    def store(row):
        G.add_message(stored, "user", row["content"], display_kind="steer", display_content=row["display_content"])
        B["RUNTIME"][sid].setdefault("read_steers", []).append(row["display_content"])

    B["deliver_steers"](sid, store)
    if B["RUNTIME"][sid].get("read_steers"):
        time.sleep(0.5)  # the next model request
        for text in B["RUNTIME"][sid]["read_steers"][-1:]:
            emit(sid, "reasoning.delta", {"text": f"The person added: {text}. I'll take that into account."})


# ── Scripted turns ───────────────────────────────────────────────────────────

def emit(sid, kind, payload):
    B["emit"](sid, kind, payload)


def interrupted(sid):
    return B["RUNTIME"][sid]["interrupt"]


def stream(sid, text, chunk=7, delay=0.022):
    for i in range(0, len(text), chunk):
        if interrupted(sid):
            return False
        B["check_redirect"](sid)  # a redirect cancels the model request that's writing
        emit(sid, "message.delta", {"text": text[i:i + chunk]})
        time.sleep(delay)
    return True


def tool(sid, stored, name, args, seconds, *, context, result, result_text=None, extra=None, risk=None):
    B["check_redirect"](sid)
    call = f"call_{uuid.uuid4().hex[:8]}"
    G.add_message(stored, "assistant", "", finish_reason="tool_calls",
                  tool_calls=[{"id": call, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}])
    emit(sid, "tool.start", {"tool_id": call, "name": name, "context": context, "args": args})
    B["RUNTIME"][sid]["tool_running"] = True
    waited = 0.0
    while waited < seconds and not interrupted(sid):
        time.sleep(0.1)
        waited += 0.1
    B["RUNTIME"][sid]["tool_running"] = False
    G.add_message(stored, "tool", result, tool_call_id=call, tool_name=name)
    payload = {"tool_id": call, "name": name, "args": args, "duration_s": round(waited, 2), "result": result,
               "summary": None}
    if result_text:
        payload["result_text"] = result_text
    payload.update(extra or {})
    emit(sid, "tool.complete", payload)
    # Hermes's scan of a web, browser or MCP result (agent/tool_executor.py): advisory findings,
    # emitted after tool.complete and only when something was found.
    if risk:
        emit(sid, "tool.output_risk", {"tool_id": call, "name": name, "risk": "high", "findings": risk, "redacted": False})
    if interrupted(sid):
        B["RUNTIME"][sid].pop("steers", None)  # Stop drops steers Hermes hasn't read
        return False
    # Hermes delivers a steer with the tool result; the model reads it on its next step.
    take_steers(sid)
    return True


def run_page_risks_turn(sid, stored):
    """The "page risks" turn in a chat (backend.py's PAGE_RISKS)."""
    for url, findings, text in B["PAGE_RISKS"]:
        if not tool(sid, stored, "web_extract", {"urls": [url]}, 0.6, context=url,
                    result=json.dumps({"results": [{"url": url, "content": text}]}), extra={"summary": "1 page"},
                    risk=findings):
            return finish(sid, stored, "", status="interrupted")
    if not stream(sid, B["PAGE_RISKS_ANSWER"]):
        return finish(sid, stored, "", status="interrupted")
    return finish(sid, stored, B["PAGE_RISKS_ANSWER"])


USAGE = {"model": "anthropic/claude-sonnet-4.6", "input": 18310, "output": 912, "reasoning": 240, "total": 19222,
         "calls": 3, "cost_usd": 0.0612, "context_used": 21400, "context_max": 200000, "context_percent": 10.7,
         "cache_read": 9000}


def finish(sid, stored, text, *, status="complete", error=None, recoverable=None, warning=None, usage_override=None,
           error_surface=None):
    if text:
        late = B["CONFIG"].get("late_store") or 0
        if late:
            # Hermes queues transcript writes while its database is busy: the reply lands after the turn ends.
            # The row keeps the message's own time (hermes_state_messages.append_message `timestamp`).
            ended = time.time()
            threading.Timer(late, lambda: G.add_message(stored, "assistant", text, finish_reason="stop", timestamp=ended)).start()
        else:
            G.add_message(stored, "assistant", text, finish_reason="stop")
    payload = {"text": text, "status": status, "usage": {**USAGE, **(usage_override or {})}}
    if error:
        payload["error"] = error
    if recoverable is not None:
        payload["recoverable"] = recoverable
    if warning:
        payload["warning"] = warning
    if error_surface:
        payload["error_surface"] = error_surface
    emit(sid, "message.complete", payload)
    with B["LOCK"]:
        B["RUNTIME"][sid]["running"] = False
        B["RUNTIME"][sid]["inflight"] = None
    emit(sid, "session.info", {"running": False, "model": "anthropic/claude-sonnet-4.6"})
    B["after_turn"](sid, run_chat_turn)


def title_later(sid, stored, text):
    def apply():
        with G.LOCK:
            session = G.SESSIONS.get(stored)
            if not session or session["title"]:
                return
            lines = [l for l in text.strip().split("\n") if l.strip() and not l.startswith("[")]
            session["title"] = (lines[0] if lines else text.strip())[:40].rstrip(".?!").capitalize()
            title = session["title"]
        emit(sid, "session.title", {"title": title})
    threading.Timer(1.2, apply).start()


def think(sid, pieces, seconds):
    """A model request: reasoning streams in; a redirect cancels it (Hermes' active-turn redirect)."""
    for piece in pieces:
        B["check_redirect"](sid)
        emit(sid, "reasoning.delta", {"text": piece})
        time.sleep(seconds / len(pieces))
    B["check_redirect"](sid)


def run_snapshots_turn(sid, stored, lower):
    """The follow-ups scenario (screens/iphone/follow-ups.elyx): list, then a long delete, so there's time
    to steer, redirect, queue, ask aside or run something in the background."""
    B["RUNTIME"][sid]["read_steers"] = []
    for piece in ["Old snapshots are using the space. ", "I'll count them first."]:
        emit(sid, "reasoning.delta", {"text": piece})
        time.sleep(0.1)
    listing = "ls -1 /volume1/@snapshots | wc -l"
    if not tool(sid, stored, "terminal", {"command": listing}, 3.0, context=listing,
                result=json.dumps({"output": "41 snapshots, 212 GB", "exit_code": 0})):
        return finish(sid, stored, "", status="interrupted")
    if "compact" in lower:
        # "… and compact": Hermes compacts the chat between steps, for 8 s; a steer or redirect sent
        # then is held for the next turn (`status.update` kind `compacting`).
        B["compact_between_steps"](sid, B["RUNTIME"][sid])
    think(sid, ["41 snapshots, 212 GB. ", "Most are older than a month, ", "so those can go."], 2.4)
    narration = "I'll delete everything older than 30 days."
    stream(sid, narration)
    emit(sid, "message.interim", {"text": narration, "already_streamed": True})
    read = B["RUNTIME"][sid].get("read_steers") or []
    week = any("week" in r.lower() for r in read)
    delete = "find /volume1/@snapshots -mtime +30 ! -newer week-start -delete" if week else "find /volume1/@snapshots -mtime +30 -delete"
    if not tool(sid, stored, "terminal", {"command": delete}, 9.0, context=delete,
                result=json.dumps({"output": "removed 11 snapshots", "exit_code": 0})):
        return finish(sid, stored, "", status="interrupted")
    think(sid, ["Removed 11. ", "Let me sum up ", "what was freed."], 2.4)
    read = B["RUNTIME"][sid].get("read_steers") or []
    answer = "Done. Freed **42 GB**: removed 11 snapshots older than 30 days."
    if read:
        answer += " As you asked, I " + ("kept this week's snapshots." if any("week" in r.lower() for r in read) else f"took your note into account: {read[-1]}")
    time.sleep(0.4)
    stream(sid, answer)
    return finish(sid, stored, answer)


def run_chat_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    B["begin_turn"](sid, stored, text, G.add_message)
    title_later(sid, stored, text)
    lower = text.lower()
    B["mock_warnings"](sid, text)
    time.sleep(0.3)

    if text.startswith("[The person invoked skills"):
        answer = "On it. I'll write a failing test for #123 first, fix it, then open the PR with `gh pr create`."
        stream(sid, answer)
        return finish(sid, stored, answer)

    # A provider that refused its credentials (agent/error_surface.py): the chat offers the fix.
    if "key expired" in lower:
        time.sleep(0.4)
        return finish(sid, stored, "", status="error", recoverable=True,
                      error="Provider authentication failed: Anthropic rejected the API key (401 invalid x-api-key)",
                      error_surface={"layer": "auth", "code": "auth", "retryable": False, "provider": "anthropic",
                                     "model": "claude-sonnet-4.6", "provider_label": "Anthropic",
                                     "auth_kind": "api_key", "api_key_env": "ANTHROPIC_API_KEY"})
    if "signed out" in lower:
        time.sleep(0.4)
        return finish(sid, stored, "", status="error", recoverable=True,
                      error="Provider authentication failed: the OpenAI Codex sign-in was revoked (refresh token expired)",
                      error_surface={"layer": "auth", "code": "auth_permanent", "retryable": False, "provider": "openai-codex",
                                     "provider_label": "OpenAI Codex", "auth_kind": "oauth"})

    if "fail" in lower:
        stream(sid, "Let me try that")
        time.sleep(0.4)
        return finish(sid, stored, "", status="error", recoverable=True,
                      error="The model provider returned 529: overloaded. Try again in a moment.")

    if "snapshot" in lower:
        return run_snapshots_turn(sid, stored, lower)

    if "short" in lower:
        time.sleep(1.2)
        answer = ("Yes. The nightly job keeps 14 days of snapshots and prunes the rest at 03:00.\n\n"
                  "Nothing older than a month is left, so there's nothing to clean up today.")
        stream(sid, answer)
        return finish(sid, stored, answer)

    for piece in ["They want a straight answer. ", "I'll check the facts ", "before replying."]:
        emit(sid, "reasoning.delta", {"text": piece})
        time.sleep(0.08)

    if "models" in lower:
        labels = ["anthropic/claude-opus-4.6", "openai/gpt-5", "nousresearch/hermes-4-405b"]
        for label in labels:
            emit(sid, "moa.progress", {"label": label, "refs_done": 0, "refs_total": 3})
        for i, label in enumerate(labels):
            time.sleep(0.9)
            emit(sid, "moa.reference", {"label": label, "text": "…", "index": i, "count": 3})
        emit(sid, "moa.aggregating", {"aggregator": "anthropic/claude-sonnet-4.6"})
        time.sleep(0.6)
        answer = "All three agree: run the migration against **staging** first, then production with a backup."
        stream(sid, answer)
        return finish(sid, stored, answer)
    if "remember" in lower:
        tool(sid, stored, "memory", {"action": "add", "content": "you prefer 24-hour times"}, 0.4,
             context="you prefer 24-hour times", result=json.dumps({"success": True}))
        answer = "Got it, I'll use 24-hour times from now on."
        stream(sid, answer)
        return finish(sid, stored, answer)
    if "react" in lower or "review" in lower or "full" in lower:
        answer = "Sure. Here's the short version: it's done."
        stream(sid, answer)
        finish(sid, stored, answer, usage_override={"context_percent": 86.0, "context_used": 172000} if "full" in lower else None)
        if "react" in lower:
            with G.LOCK:
                user_rows = [r for r in G.MESSAGES.get(stored, []) if r["role"] == "user"]
            if user_rows:
                emit(sid, "message.reaction", {"row_id": user_rows[-1]["id"], "role": "user", "reactions": [{"emoji": "👍", "author": "hermes"}]})
        if "review" in lower:
            time.sleep(1.0)
            emit(sid, "review.summary", {"text": "no issues found"})
        return
    if "dev server" in lower:
        threading.Thread(target=run_dev_server, args=(sid,), daemon=True).start()
        answer = "The dev server is running in the background on :5173."
        stream(sid, answer)
        return finish(sid, stored, answer)

    if any(k in lower for k in ("batch", "flagged", "clarify", "secret", "sudo", "unlock", "save login", "2fa",
                                "choose ", "connect linear", "sign in", "install", "timeout")):
        if run_request_turn(sid, stored, lower):
            return

    if "page risks" in lower:
        return run_page_risks_turn(sid, stored)

    if "approve" in lower:
        command = "rm -rf ./build && make release"
        stream(sid, "I'll clean the build folder first.")
        emit(sid, "message.interim", {"text": "I'll clean the build folder first.", "already_streamed": True})
        result = B["server_request"](sid, "approval", {
            "request_id": uuid.uuid4().hex, "command": command, "description": "Recursive delete",
            "pattern_key": "rm_rf", "pattern_keys": ["rm_rf"], "tool_name": "terminal",
            "allow_session": True, "allow_permanent": True})
        choice = (result or {}).get("choice", "deny")
        if result is None or choice == "deny":
            answer = "Okay, I didn't touch the build folder. Let me know if you want a safer cleanup."
            stream(sid, answer)
            return finish(sid, stored, answer)
        tool(sid, stored, "terminal", {"command": command}, 1.4, context=command,
             result=json.dumps({"output": "Release build succeeded in 41.2s", "exit_code": 0}),
             result_text="$ make release\n  Compiling 214 files\n  Linking Hermes\nRelease build succeeded in 41.2s")
        answer = "Done. The release build **succeeded in 41.2 s** and the artifacts are in `./build/release`."
        stream(sid, answer)
        return finish(sid, stored, answer)

    slow = "slow" in lower
    todos = [{"id": "1", "content": "Search for what changed", "status": "in_progress"},
             {"id": "2", "content": "Check the project's settings", "status": "pending"},
             {"id": "3", "content": "Update the build settings", "status": "pending"}]
    emit(sid, "todo.updated", {"todos": todos, "revision": 1})

    query = text.strip()[:60]
    results = ("1. Swift 6.4 release notes — swift.org\n2. Region-based isolation, explained — forums.swift.org\n"
               "3. Migrating to Swift 6 — hackingwithswift.com")
    if not tool(sid, stored, "web_search", {"query": query}, 1.2 if not slow else 4, context=query, result=results,
                extra={"summary": "3 results"}):
        return finish(sid, stored, "", status="interrupted")
    todos[0]["status"], todos[1]["status"] = "completed", "in_progress"
    emit(sid, "todo.updated", {"todos": todos, "revision": 2})

    emit(sid, "message.interim", {"text": "Now let me check how the project sets strict concurrency.", "already_streamed": False})
    grep = "grep -rn SWIFT_STRICT_CONCURRENCY *.xcodeproj | head"
    if not tool(sid, stored, "terminal", {"command": grep}, 0.9 if not slow else 4, context=grep,
                result=json.dumps({"output": "project.pbxproj:412: SWIFT_STRICT_CONCURRENCY = minimal;", "exit_code": 0}),
                result_text="project.pbxproj:412:  SWIFT_STRICT_CONCURRENCY = minimal;\nproject.pbxproj:688:  SWIFT_STRICT_CONCURRENCY = minimal;"):
        return finish(sid, stored, "", status="interrupted")
    todos[1]["status"], todos[2]["status"] = "completed", "in_progress"
    emit(sid, "todo.updated", {"todos": todos, "revision": 3})

    diff = ("--- a/Project.xcconfig\n+++ b/Project.xcconfig\n@@ -12,3 +12,3 @@\n SWIFT_VERSION = 6.0\n"
            "-SWIFT_STRICT_CONCURRENCY = minimal\n+SWIFT_STRICT_CONCURRENCY = complete\n SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor\n")
    if not tool(sid, stored, "patch", {"path": "Project.xcconfig"}, 0.7, context="Project.xcconfig",
                result=json.dumps({"success": True}), extra={"inline_diff": diff}):
        return finish(sid, stored, "", status="interrupted")
    todos[2]["status"] = "completed"
    emit(sid, "todo.updated", {"todos": todos, "revision": 4})

    answer = G.RICH_ANSWER
    if not stream(sid, answer):
        return finish(sid, stored, "", status="interrupted")
    return finish(sid, stored, answer)
