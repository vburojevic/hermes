"""Memory for the combined mock (`docs/memory.md`), shaped like the gateway:

  - GET /api/learning/graph: `memory[]` cards (MEMORY.md first, then USER.md) and memory nodes with
    ids memory:<source>:<index>:<fingerprint> (sha256 of the entry, 12 hex).
  - GET/PUT/DELETE /api/learning/node: full text, edit, forget. A stale fingerprint answers
    "memory node id is stale — refresh the graph"; an edit over the store's cap answers
    "Replacement would put memory at X/Y chars. Shorten the new content." (both 400).
  - GET /api/memory, PUT /api/memory/provider, POST /api/memory/reset {target: all|memory|user}.
  - GET/PUT /api/memory/providers/{mem0,hindsight}/config and POST …/hindsight/setup: Mem0 needs its
    key; Hindsight is unavailable until its packages and `uv tool install hindsight-api` are
    installed (about 4 s), then needs its key. POST /api/mock/memory/install {"fails": true} makes
    the install fail on the uv step, with uv's words.
  - GET/PUT /api/config: the `memory` section (memory_enabled, user_profile_enabled, write_approval,
    limits, provider), merged with whatever else serves /api/config.
  - command.dispatch {name: "memory"}: pending | approve <id|all> | reject <id|all> | approval on|off,
    answered with the gateway's text.

Turns (regular chats and Bot Chats):
  - "remember …" / "vegetarian": the memory tool adds an entry. With Ask Before Saving on, Hermes
    first asks: an approval request titled "Save to memory?" (allow_permanent false) — Don't Save,
    Save, Save All in This Chat.
  - "in a task" (nobody can answer): the save is staged and waits for review.
  - "forget …": removes an entry; "beta 3": patches the Studio Mac entry; "three things": a batch.

Demo data is the designs': six things about you, fourteen notes (94% full), two saves waiting for
review; Research Buddy has its own three and nine. The chat "Hermes app in SwiftUI" saved one of
the about-you entries ("New in this chat"). mock.memory.reset (or POST /api/mock/memory/reset) puts it all
back; mock.memory.stage
{text, target, profile} stages a save as a task would.
"""

import hashlib
import json
import threading
import time
import uuid

B = None  # backend.py's module globals
G = None  # server.py
C = None  # chats.py

LOCK = threading.Lock()
DELIM = "\n§\n"
STORES = {}    # profile -> {"memory": [...], "user": [...]}
SETTINGS = {}  # profile -> memory config section
PENDING = {}   # profile -> [record]
PROVIDERS = [
    {"name": "honcho", "description": "Long-term recall across chats (Honcho).", "available": True, "configured": True,
     "status": "ready"},
    {"name": "mem0", "description": "Mem0 memory layer.", "available": False, "configured": False,
     "status": "needs_config"},
    {"name": "hindsight", "description": "Hindsight long-term memory.", "available": False, "configured": False,
     "status": "unavailable"},
]
# Hindsight's install as Hermes runs it (memory_providers.py `_install_memory_provider_setup`).
HINDSIGHT = {"installed": False, "fails": False, "api_key": ""}
HINDSIGHT_SETUP = {"pip_dependencies": ["hindsight-client>=0.4"], "python_dependencies_declared": True,
                   "external_dependencies": [{"name": "hindsight-api", "install": "uv tool install hindsight-api",
                                              "check": "hindsight-api --version"}],
                   "required_env": ["HINDSIGHT_API_KEY"]}
HINDSIGHT_FIELDS = [
    {"key": "api_key", "label": "API key", "kind": "secret", "description": "From hindsight.vectorize.io → Keys.",
     "placeholder": "hs-…", "required": True, "options": [], "url": "https://hindsight.vectorize.io", "when": None},
]
ACTIVE = {}    # profile -> provider ("" built-in)
# Mem0's settings as Hermes describes them (hermes_cli/web_routers/memory_providers.py):
# GET /api/memory/providers/mem0/config, PUT with {values}; the key makes it ready.
MEM0_FIELDS = [
    {"key": "api_key", "label": "API key", "kind": "secret", "description": "From app.mem0.ai → API Keys.",
     "placeholder": "m0-…", "required": True, "options": [], "url": "https://app.mem0.ai", "when": None},
    {"key": "mode", "label": "Where it runs", "kind": "select", "description": "", "placeholder": "", "required": False,
     "options": [{"value": "cloud", "label": "Mem0 Cloud", "description": ""}, {"value": "local", "label": "On the gateway", "description": ""}],
     "url": "", "when": None},
    {"key": "host", "label": "Host", "kind": "text", "description": "Your Mem0 server.", "placeholder": "http://localhost:8000",
     "required": True, "options": [], "url": "", "when": {"mode": "local"}},
]
MEM0_VALUES = {"mode": "cloud"}

ABOUT = [
    "Sam. Lives in Lisbon; writes in English, speaks Portuguese.",
    "Prefers 24-hour times and metric units.",
    "Likes the short answer first, details after.",
    "Writing the Hermes app in SwiftUI for iOS, iPadOS and macOS 27.",
    "Calls the Synology NAS “the box”.",
    "Reviews pull requests in the morning; no pings after 22:00.",
]
NOTES = [
    "Studio Mac: macOS 27, Xcode 27 beta 2, repo at ~/Code/hermes-app.",
    "Home Server runs Docker; NAS is nas.local (Synology DSM 7).",
    "Release builds: make release. Never push to main; open a pull request.",
    "Morning briefing: news, calendar, weather. Flag only what needs action.",
    "Studio Mac builds with Xcode 27 beta 2; use xcodebuild -scheme Hermes.",
    "TestFlight builds go to the internal testers after every fix, and the Mac app is installed from the notarized DMG into /Applications the same day.",
    "The mock gateway lives in Tools/mock-hermes; start it with backend.py --port 19119 --gateway-port 18642 and point a Debug build at it with the HERMES_BOOTSTRAP launch flags.",
    "Hermes App has three lanes worth knowing: main, feature/push-notifications and the bugs worktree; check which one a question is about before touching files.",
    "Backups: the NAS snapshots nightly at 02:00, and the Home Server copies /srv to the NAS at 03:00; restore drills happen on the first Sunday of every month, and a failed snapshot is reported in the morning briefing rather than as a notification at night.",
    "Blog posts go to the blog as Markdown with a hero image at 1600 px wide; drafts live in the blog repo under drafts/ until Sam says publish, and every post gets a short summary for the newsletter that goes out on Thursdays.",
    "Calendar is Google Calendar for work and iCloud for home; the morning briefing reads both and skips anything marked private or tentative.",
    "Prefers small pull requests: one feature or fix each, with before-and-after screenshots for anything that changes the UI, and a line on how it was tested.",
    "Swift style: no force unwraps in app code, Swift Testing rather than XCTest for new tests, and comments that say why rather than what the code does, in code and in reviews.",
    "The push relay's keys live in the password manager and are never pasted into chats, logs or the repo; rotating them is done from the CLI, never by hand in the dashboard.",
]
RESEARCH_ABOUT = [
    "Follows LLM inference research: decoding, KV caches, quantisation.",
    "Wants arXiv links plus a two-line summary, not PDFs.",
    "Reads the digest at 08:00 on weekdays.",
]
RESEARCH_NOTES = [
    "Digest sources: arXiv cs.CL and cs.LG, Hugging Face papers, three blogs.",
    "Speculative decoding papers go in the 'decoding' folder.",
    "KV cache work: track 4-bit and paged-attention results.",
    "Summaries: two lines, then the link; no PDFs.",
    "Benchmarks to compare: MMLU-Pro, GPQA, LiveCodeBench.",
    "Skip papers without code unless they're from a major lab.",
    "Weekly roundup goes out Friday at 17:00.",
    "Notion page 'Reading list' holds what Sam wants to read later.",
    "Quantisation: note the bit width and the perplexity change.",
]


def install(backend_globals, gateway_module, chats_module):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    routes = B["HTTP_ROUTES"]
    routes[("GET", "/api/learning/graph")] = graph
    routes[("GET", "/api/learning/node")] = node_detail
    routes[("PUT", "/api/learning/node")] = node_edit
    routes[("DELETE", "/api/learning/node")] = node_delete
    routes[("GET", "/api/memory")] = memory_status
    routes[("GET", "/api/memory/providers/mem0/config")] = mem0_config
    routes[("PUT", "/api/memory/providers/mem0/config")] = mem0_save
    routes[("GET", "/api/memory/providers/hindsight/config")] = hindsight_config
    routes[("PUT", "/api/memory/providers/hindsight/config")] = hindsight_save
    routes[("POST", "/api/memory/providers/hindsight/setup")] = hindsight_install
    routes[("POST", "/api/mock/memory/install")] = hindsight_mock
    routes[("PUT", "/api/memory/provider")] = memory_provider
    routes[("POST", "/api/memory/reset")] = memory_reset
    routes[("POST", "/api/mock/memory/reset")] = lambda query, body: (seed(), (200, {"ok": True}))[1]

    previous_get, previous_put = routes.get(("GET", "/api/config")), routes.get(("PUT", "/api/config"))

    def get_config(query, body):
        status, payload = previous_get(query, body) if previous_get else (200, {})
        payload = dict(payload or {})
        payload["memory"] = dict(SETTINGS[profile_of(query, body)], provider=ACTIVE.get(profile_of(query, body), ""))
        return status, payload

    def put_config(query, body):
        section = ((body or {}).get("config") or {}).get("memory")
        if isinstance(section, dict):
            settings = SETTINGS[profile_of(query, body)]
            for key in ("memory_enabled", "user_profile_enabled", "write_approval"):
                if key in section:
                    settings[key] = bool(section[key])
        return previous_put(query, body) if previous_put else (200, {"ok": True})

    routes[("GET", "/api/config")] = get_config
    routes[("PUT", "/api/config")] = put_config

    methods = B["METHODS"]
    original_dispatch = methods.get("command.dispatch")

    def dispatch(params):
        if (params.get("name") or "").lstrip("/") == "memory":
            return {"type": "exec", "output": memory_command(runtime_profile(params), params.get("arg") or "")}
        return original_dispatch(params)

    methods["command.dispatch"] = dispatch
    methods["mock.memory.reset"] = lambda params: (seed(), {"ok": True})[1]
    methods["mock.memory.stage"] = mock_stage

    original_start = B["start_turn"]

    def start_turn(sid, text, runner):
        lower = (text or "").lower()
        if any(k in lower for k in ("remember", "vegetarian", "forget ", "beta 3")) and not text.startswith("[The person invoked"):
            return original_start(sid, text, memory_turn)
        return original_start(sid, text, runner)

    B["start_turn"] = start_turn
    seed()


# ---------------------------------------------------------------- state

def key(profile):
    if not profile or profile == "default" or (profile in B["PROFILES"] and B["PROFILES"][profile]["is_default"]):
        return "default"
    return profile


def profile_of(query, body=None):
    named = (body or {}).get("profile") if isinstance(body, dict) else None
    named = named or ((query or {}).get("profile") or [None])[0]
    profile = key(named)
    ensure(profile)
    return profile


def runtime_profile(params):
    runtime = B["RUNTIME"].get(params.get("session_id") or "")
    profile = key((runtime or {}).get("profile") or params.get("profile"))
    ensure(profile)
    return profile


def ensure(profile):
    with LOCK:
        STORES.setdefault(profile, {"memory": [], "user": []})
        SETTINGS.setdefault(profile, defaults())
        PENDING.setdefault(profile, [])


def defaults():
    return {"memory_enabled": True, "user_profile_enabled": True, "write_approval": True,
            "memory_char_limit": 2200, "user_char_limit": 1375, "nudge_interval": 10}


def seed():
    now = time.time()
    with LOCK:
        STORES.clear(), SETTINGS.clear(), PENDING.clear(), ACTIVE.clear()
        STORES["default"] = {"memory": list(NOTES), "user": list(ABOUT)}
        STORES["researcher"] = {"memory": list(RESEARCH_NOTES), "user": list(RESEARCH_ABOUT)}
        for profile in ("default", "researcher"):
            SETTINGS[profile] = defaults()
            PENDING[profile] = []
        PENDING["default"] = [
            record("add", "memory", "NAS snapshots older than 30 days are safe to delete.", None,
                   origin="foreground", created=now - 2 * 3600, pid="a1b2c3d4"),
            record("patch", "memory", "beta 3", "beta 2", origin="background_review", created=now - 5 * 3600,
                   pid="e5f6a7b8", matched="Studio Mac builds with Xcode 27 beta 2; use xcodebuild -scheme Hermes."),
        ]
    seed_chat()


def seed_chat():
    """A chat that saved one of the about-you entries ("New in this chat")."""
    sid = "mem_swiftui"
    now = time.time()
    with G.LOCK:
        if sid in G.SESSIONS:
            return
        G.session_row(sid, "Hermes app in SwiftUI", "tui", now - 3600, now - 3500, "I'm writing the Hermes app in SwiftUI")
        G.add_message(sid, "user", "I'm writing the Hermes app in SwiftUI for iOS, iPadOS and macOS 27. Keep that in mind.",
                      timestamp=now - 3600)
        args = {"action": "add", "target": "user", "content": ABOUT[3]}
        G.add_message(sid, "assistant", "", finish_reason="tool_calls", timestamp=now - 3590,
                      tool_calls=[{"id": "call_mem1", "type": "function", "function": {"name": "memory", "arguments": json.dumps(args)}}])
        G.add_message(sid, "tool", json.dumps({"success": True, "done": True, "target": "user", "message": "Entry added."}),
                      tool_call_id="call_mem1", tool_name="memory", timestamp=now - 3589)
        G.add_message(sid, "assistant", "Noted. I'll keep SwiftUI and the 27 SDKs in mind from your next chat.",
                      finish_reason="stop", timestamp=now - 3500)


def record(action, target, content, old_text, *, origin, created, pid=None, matched=None):
    label = "user profile" if target == "user" else "memory"
    payload = {"action": action, "target": target, "content": content, "old_text": old_text}
    if matched:
        payload["matched_entry"] = matched
    if origin == "background_review" and action in ("patch", "remove", "replace"):
        detail = f"- patch span '{old_text}' -> '{content}' (rest of the entry is kept)" if action == "patch" else f"- {action}: {old_text}"
        summary = f"background review consolidation ({action} on {target}): {detail}"[:200]
    elif action == "add":
        summary = f"add to {label}: {content[:120]}"
    elif action == "remove":
        summary = f"remove from {label}: {(old_text or '')[:120]}"
    else:
        detail = f"entry matching: {old_text}\nspan '{old_text}' becomes: {content} (rest of the entry is kept)"
        summary = f"patch in {label}: {detail[:120]}"
    return {"id": pid or uuid.uuid4().hex[:8], "subsystem": "memory", "action": action, "summary": summary,
            "origin": origin, "created_at": created, "payload": payload}


def fingerprint(entry):
    return hashlib.sha256(entry.strip().encode("utf-8")).hexdigest()[:12]


def chars(entries):
    return len(DELIM.join(entries))


def limit(profile, target):
    settings = SETTINGS[profile]
    return settings["user_char_limit"] if target == "user" else settings["memory_char_limit"]


# ---------------------------------------------------------------- REST

def cards(profile):
    out = []
    for target, source in (("memory", "memory"), ("user", "profile")):
        for entry in STORES[profile][target]:
            first = entry.splitlines()[0].strip()
            out.append({"source": source, "timestamp": int(time.time()), "title": first[:80] + ("…" if len(first) > 80 else ""),
                        "body": entry[:1200], "fingerprint": fingerprint(entry)})
    return out


def graph(query, body):
    profile = profile_of(query)
    with LOCK:
        memory = cards(profile)
    nodes = [{"id": "swift-6-migration", "label": "swift-6-migration", "kind": "skill", "category": "software-development"}]
    nodes += [{"id": f"memory:{c['source']}:{i}:{c['fingerprint']}", "label": c["title"], "kind": "memory",
               "memorySource": c["source"], "category": "memory"} for i, c in enumerate(memory)]
    return 200, {"nodes": nodes, "edges": [], "clusters": [], "memory": memory,
                 "stats": {"memory_nodes": len(memory)}}


def locate(profile, node_id):
    """(target, index) of the entry the id names, or an error message."""
    parts = (node_id or "").split(":")
    if len(parts) not in (3, 4) or parts[0] != "memory" or parts[1] not in ("memory", "profile"):
        return None, f"bad memory node id: {node_id!r}"
    target = "user" if parts[1] == "profile" else "memory"
    entries = STORES[profile][target]
    if len(parts) == 4:
        for index, entry in enumerate(entries):
            if fingerprint(entry) == parts[3]:
                return (target, index), None
        return None, "memory node id is stale — refresh the graph"
    return None, "memory node id is stale — refresh the graph"


def node_detail(query, body):
    profile = profile_of(query)
    node_id = (query.get("id") or [""])[0]
    with LOCK:
        found, error = locate(profile, node_id)
        if error:
            return 404, {"detail": error}
        target, index = found
        text = STORES[profile][target][index]
    return 200, {"ok": True, "kind": "memory", "id": node_id, "label": text.splitlines()[0][:80], "content": text}


def node_edit(query, body):
    profile = profile_of(query, body)
    content = ((body or {}).get("content") or "").strip()
    with LOCK:
        found, error = locate(profile, (body or {}).get("id"))
        if error:
            return 400, {"detail": error}
        if not content:
            return 400, {"detail": "empty memory — use delete to remove it"}
        target, index = found
        entries = list(STORES[profile][target])
        entries[index] = content
        cap = limit(profile, target)
        if chars(entries) > cap:
            return 400, {"detail": f"Replacement would put memory at {chars(entries):,}/{cap:,} chars. Shorten the new content."}
        STORES[profile][target] = entries
    name = "USER.md" if target == "user" else "MEMORY.md"
    return 200, {"ok": True, "message": f"updated memory in {name}"}


def node_delete(query, body):
    profile = profile_of(query, body)
    with LOCK:
        found, error = locate(profile, (body or {}).get("id"))
        if error:
            return 400, {"detail": error}
        target, index = found
        del STORES[profile][target][index]
    name = "USER.md" if target == "user" else "MEMORY.md"
    return 200, {"ok": True, "message": f"deleted memory from {name}"}


def memory_status(query, body):
    profile = profile_of(query)
    with LOCK:
        files = {target: len(DELIM.join(STORES[profile][target]).encode()) for target in ("memory", "user")}
    return 200, {"active": ACTIVE.get(profile, ""), "providers": PROVIDERS, "builtin_files": files}


def memory_provider(query, body):
    profile = profile_of(query, body)
    name = ((body or {}).get("provider") or "").strip().lower()
    if name in ("builtin", "built-in"):
        name = ""
    if name:
        row = next((p for p in PROVIDERS if p["name"] == name), None)
        if row is None:
            return 400, {"detail": f"Unknown memory provider '{name}'."}
        if row["status"] != "ready":
            return 400, {"detail": f"Memory provider '{name}' is not ready ({row['status'].replace('_', ' ')}). "
                                   "Configure it in the dashboard first."}
    ACTIVE[profile] = name
    return 200, {"ok": True, "active": name}


def memory_reset(query, body):
    target = ((body or {}).get("target") or "all").strip().lower()
    if target not in ("all", "memory", "user"):
        return 400, {"detail": "target must be all, memory, or user"}
    profile = profile_of(query)
    deleted = []
    with LOCK:
        for store, name in (("memory", "MEMORY.md"), ("user", "USER.md")):
            if target in ("all", store) and STORES[profile][store]:
                STORES[profile][store] = []
                deleted.append(name)
    return 200, {"ok": True, "deleted": deleted}


# ---------------------------------------------------------------- /memory

def memory_command(profile, arg):
    words = arg.split()
    if not words:
        state = "on" if SETTINGS[profile]["write_approval"] else "off"
        return f"memory.write_approval = {state}\n\n" + pending_text(profile)
    sub, rest = words[0].lower(), words[1:]
    if sub == "pending":
        return pending_text(profile)
    if sub in ("approve", "apply"):
        return approve(profile, rest)
    if sub in ("reject", "deny", "drop"):
        return reject(profile, rest)
    if sub in ("approval", "mode"):
        if not rest:
            return f"memory.write_approval = {'on' if SETTINGS[profile]['write_approval'] else 'off'}\nSet with: /memory approval <on|off>"
        value = rest[0].lower()
        if value not in ("on", "off", "true", "false"):
            return f"Invalid value '{value}'. Use: on or off."
        SETTINGS[profile]["write_approval"] = value in ("on", "true")
        return f"memory.write_approval set to '{'on' if SETTINGS[profile]['write_approval'] else 'off'}'."
    return "Usage: /memory pending | approve <id> | reject <id> | approval <on|off>"


def pending_text(profile):
    with LOCK:
        records = sorted(PENDING[profile], key=lambda r: r["created_at"])
    if not records:
        return "No pending memory writes."
    lines = [f"Pending memory writes ({len(records)}):"]
    for r in records:
        tag = " [auto]" if r["origin"] == "background_review" else ""
        lines.append(f"  {r['id']}{tag}  {r['summary']}")
        matched = r["payload"].get("matched_entry")
        if matched and r["action"] in ("patch", "replace", "remove"):
            lines.append(f"      {r['action']}s entry: {matched}")
    lines.append("")
    lines.append("Apply: /memory approve <id>   Reject: /memory reject <id>")
    return "\n".join(lines)


def approve(profile, rest):
    if not rest:
        return "Usage: /memory approve|reject <id>  (or 'all')"
    with LOCK:
        records = list(PENDING[profile])
        if not records:
            return "No pending memory writes."
        targets = records if rest[0].lower() == "all" else [r for r in records if r["id"] == rest[0]]
        if not targets:
            return f"No pending memory write with id '{rest[0]}'."
        applied, changed, failed = 0, [], []
        for r in targets:
            p = r["payload"]
            entries = STORES[profile][p["target"]]
            if p["action"] == "add":
                if p["content"] not in entries:
                    entries.append(p["content"])
            else:
                matched = p.get("matched_entry")
                if matched not in entries:
                    failed.append(f"{r['id']}: the entry changed since it was staged")
                    continue
                index = entries.index(matched)
                if p["action"] == "remove":
                    del entries[index]
                else:
                    entries[index] = matched.replace(p["old_text"], p["content"], 1) if p["action"] == "patch" else p["content"]
                changed.append(f"  {r['id']}: {matched}")
            PENDING[profile] = [x for x in PENDING[profile] if x["id"] != r["id"]]
            applied += 1
    out = [f"Approved {applied} memory write(s)."]
    if changed:
        out.append("Patched entry (as it was before the edit):")
        out.extend(changed)
    if failed:
        out.append("Failed:")
        out.extend(f"  {f}" for f in failed)
    return "\n".join(out)


def reject(profile, rest):
    if not rest:
        return "Usage: /memory approve|reject <id>  (or 'all')"
    with LOCK:
        if rest[0].lower() == "all":
            n = len(PENDING[profile])
            PENDING[profile] = []
            return f"Rejected {n} pending memory write(s)."
        before = len(PENDING[profile])
        PENDING[profile] = [r for r in PENDING[profile] if r["id"] != rest[0]]
        if len(PENDING[profile]) < before:
            return f"Rejected pending memory write '{rest[0]}'."
    return f"No pending memory write with id '{rest[0]}'."


def mock_stage(params):
    profile = key(params.get("profile"))
    ensure(profile)
    rec = record("add", params.get("target") or "memory", params.get("text") or "Something a task learned.", None,
                 origin="foreground", created=time.time())
    with LOCK:
        PENDING[profile].append(rec)
    return {"ok": True, "pending_id": rec["id"]}


# ---------------------------------------------------------------- turns

def helpers(sid):
    """(tool, stream, finish) for the runtime's kind: a regular chat or a Bot Chat."""
    if B["RUNTIME"][sid].get("kind") == "chat":
        def tool(stored, name, args, result, seconds=0.4):
            C.tool(sid, stored, name, args, seconds, context=args.get("content") or args.get("old_text") or "", result=result)
        return tool, lambda text: C.stream(sid, text), lambda stored, text: C.finish(sid, stored, text)

    def tool(stored, name, args, result, seconds=0.4):
        B["tool"](sid, stored, name, args, result, seconds, args.get("content") or args.get("old_text") or "")
    return tool, lambda text: B["stream"](sid, text), lambda stored, text: B["finish"](sid, stored, text)


def memory_turn(sid, text):
    runtime = B["RUNTIME"][sid]
    kind = runtime.get("kind")
    if kind == "chat":
        stored = runtime["stored"]
        G.add_message(stored, "user", text)
    else:
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})
    profile = key(runtime.get("profile"))
    ensure(profile)
    tool, stream, finish = helpers(sid)
    lower = text.lower()
    time.sleep(0.3)

    if "forget " in lower:
        with LOCK:
            entries = STORES[profile]["memory"]
            victim = next((e for e in entries if "nas" in e.lower() and "backup" in e.lower()), entries[-1] if entries else None)
            if victim:
                entries.remove(victim)
        result = {"success": True, "done": True, "target": "memory", "message": "Entry removed.", "removed_entry": victim}
        tool(stored, "memory", {"action": "remove", "target": "memory", "old_text": "backups"}, json.dumps(result))
        answer = "Done, I've forgotten that."
        stream(answer)
        return finish(stored, answer)

    if "beta 3" in lower:
        with LOCK:
            entries = STORES[profile]["memory"]
            index = next((i for i, e in enumerate(entries) if "beta 2" in e and "xcodebuild" in e), None)
            after = None
            if index is not None:
                after = entries[index].replace("beta 2", "beta 3", 1)
                entries[index] = after
        result = {"success": True, "done": True, "target": "memory", "message": "Entry patched."}
        if after:
            result["patched_entry_after"] = after
        tool(stored, "memory", {"action": "patch", "target": "memory", "old_text": "beta 2", "content": "beta 3"}, json.dumps(result))
        answer = "Updated: the Studio Mac builds with Xcode 27 beta 3 now."
        stream(answer)
        return finish(stored, answer)

    if "three things" in lower:
        ops = [{"action": "add", "content": "Flies from Lisbon (LIS)."},
               {"action": "add", "content": "Prefers aisle seats."},
               {"action": "add", "content": "Hotel near the old town, under 150 EUR a night."}]
        with LOCK:
            STORES[profile]["user"].extend(op["content"] for op in ops)
        tool(stored, "memory", {"target": "user", "operations": ops}, json.dumps({"success": True, "done": True, "target": "user"}))
        answer = "Got all three. I'll use them from your next chat."
        stream(answer)
        return finish(stored, answer)

    porto = "vegetarian" in lower
    if porto:
        content, target = "Vegetarian; avoids flights after 21:00.", "user"
    else:
        said = text.split("remember", 1)[-1].strip(" :,.").removeprefix("that ").strip()
        content = (said[:1].upper() + said[1:]).rstrip(".") + "." if said else "Prefers 24-hour times."
        target = "user" if any(w in f" {lower} " for w in (" i ", " i'm ", " my ", " me ")) else "memory"
    label = "user profile" if target == "user" else "memory"
    args = {"action": "add", "target": target, "content": content}

    if porto:
        B["emit"](sid, "message.interim", {"text": "I'll remember your food and flight preferences for next time.", "already_streamed": False})

    settings = SETTINGS[profile]
    staged = None
    if settings["write_approval"]:
        nobody = "in a task" in lower or "task:" in lower
        if nobody:
            staged = record("add", target, content, None, origin="foreground", created=time.time())
        elif not runtime.get("memory_session_allowed"):
            reply = B["server_request"](sid, "approval", {
                "request_id": uuid.uuid4().hex, "title": "Save to memory?", "command": content,
                "description": f"Save to memory: add to {label}", "tool_name": "memory",
                "allow_session": True, "allow_permanent": False, "choices": ["once", "session", "deny"]})
            choice = (reply or {}).get("choice", "deny")
            if reply is None or choice == "deny":
                tool(stored, "memory", args, json.dumps({"success": False, "error": "Memory write denied by user. The change was not saved."}))
                answer = ("Here's a plan for 14–18 May: a 07:40 flight out, a 17:10 flight back, and three vegetarian places near "
                          "Ribeira for dinner. I won't keep your preferences.") if porto else "Okay, I won't keep that."
                stream(answer)
                return finish(stored, answer)
            if choice == "session":
                runtime["memory_session_allowed"] = True

    if staged:
        with LOCK:
            PENDING[profile].append(staged)
        result = {"success": True, "staged": True, "pending_id": staged["id"],
                  "message": "Staged for approval (memory.write_approval is on). Not yet saved — review with /memory pending."}
    else:
        with LOCK:
            if content not in STORES[profile][target]:
                STORES[profile][target].append(content)
            count = len(STORES[profile][target])
        result = {"success": True, "done": True, "target": target, "entry_count": count, "message": "Entry added."}
    tool(stored, "memory", args, json.dumps(result))
    if porto:
        answer = ("Here's a plan for 14–18 May: a 07:40 flight out, a 17:10 flight back, and three vegetarian places "
                  "near Ribeira for dinner.")
    elif staged:
        answer = "I've put that up for your review; it isn't saved until you approve it."
    else:
        answer = "Got it. I'll remember that from your next chat."
    stream(answer)
    return finish(stored, answer)


def mem0_config(query, body):
    with LOCK:
        fields = [{**f, "value": "" if f["kind"] == "secret" else MEM0_VALUES.get(f["key"], ""),
                   "is_set": bool(MEM0_VALUES.get(f["key"]))} for f in MEM0_FIELDS]
    return 200, {"name": "mem0", "label": "Mem0", "fields": fields, "setup": {}}


def mem0_save(query, body):
    values = (body or {}).get("values") or {}
    known = {f["key"] for f in MEM0_FIELDS}
    unknown = sorted(k for k in values if k not in known)
    if unknown:
        return 400, {"detail": f"Unknown setting(s) for mem0: {', '.join(unknown)}"}
    with LOCK:
        MEM0_VALUES.update({k: v for k, v in values.items() if v not in (None, "")})
        if MEM0_VALUES.get("api_key"):
            for provider in PROVIDERS:
                if provider["name"] == "mem0":
                    provider.update(available=True, configured=True, status="ready")
    return 200, {"ok": True}


def set_hindsight(status, **changes):
    HINDSIGHT.update(changes)
    for provider in PROVIDERS:
        if provider["name"] == "hindsight":
            provider.update(available=status == "ready", configured=status == "ready", status=status)


def hindsight_config(query, body):
    with LOCK:
        fields = [{**f, "value": "", "is_set": bool(HINDSIGHT["api_key"])} for f in HINDSIGHT_FIELDS]
        setup = {**HINDSIGHT_SETUP, "dependencies_installed": HINDSIGHT["installed"]}
    return 200, {"name": "hindsight", "label": "Hindsight", "fields": fields, "setup": setup}


def hindsight_install(query, body):
    time.sleep(4)

    def row(kind, status, command="", stderr=""):
        return {"kind": kind, "name": "hindsight" if kind == "pip" else "hindsight-api", "status": status,
                "command": command, "returncode": None if kind == "pip" else (0 if status != "failed" and status != "missing" else 1),
                "stdout": "", "stderr": stderr}

    with LOCK:
        results = [row("pip", "installed", "hermes pm install"),
                   row("external_check", "missing", "hindsight-api --version", "bash: hindsight-api: command not found")]
        if HINDSIGHT["fails"]:
            results.append(row("external_install", "failed", "uv tool install hindsight-api",
                               "error: Failed to fetch: `https://pypi.org/simple/hindsight-api/`\n"
                               "  Caused by: Could not connect, are you offline?"))
            status = "unavailable"
        else:
            results += [row("external_install", "installed", "uv tool install hindsight-api"),
                        row("external_check", "verified", "hindsight-api --version")]
            status = "ready" if HINDSIGHT["api_key"] else "needs_config"
            set_hindsight(status, installed=True)
        ok = all(r["status"] != "failed" for r in results)
    return 200, {"ok": ok, "provider": "hindsight", "results": results,
                 "status": {"name": "hindsight", "status": status}}


def hindsight_save(query, body):
    values = (body or {}).get("values") or {}
    with LOCK:
        if not HINDSIGHT["installed"]:
            return 400, {"detail": "Memory provider 'hindsight' is not ready (unavailable). Install its dependencies first."}
        if values.get("api_key"):
            set_hindsight("ready", api_key=values["api_key"])
    return 200, {"ok": True, "active": "hindsight"}


def hindsight_mock(query, body):
    with LOCK:
        set_hindsight("unavailable", installed=False, api_key="", fails=bool((body or {}).get("fails")))
    return 200, {"ok": True, "fails": HINDSIGHT["fails"]}
