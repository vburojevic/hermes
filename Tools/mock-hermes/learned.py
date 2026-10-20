"""What Hermes Learned (`docs/learned.md`): learned skills, the curator and its reports, for the mock.

On top of memory.py's graph (its memory cards stay the memories):
  - GET /api/learning/graph adds skills (useCount, state, createdBy, pinned, category, timestamp), the
    related-skill edges, memory→skill edges by shared words, and clusters. The default profile is
    seeded like `screens/iphone/learned.elyx`; other profiles get two skills.
  - GET/PUT/DELETE /api/learning/node for skill ids (SKILL.md text, edit, archive); memory ids go on
    to memory.py.
  - GET /api/skills/content?name= → {path} for the Inspector's File tab (and /api/fs/read-text there).
  - GET /api/curator, PUT /api/curator/paused, POST /api/curator/run (a tidy that takes ~6 s, merges
    or archives one unpinned skill and writes a report), GET /api/actions/curator-run/status.
  - Reports as run.json under /Users/studio/.hermes/logs/curator/<stamp>/ through GET /api/files and
    GET /api/files/read (base64 data URL), like the managed files.
  - `/curator pin|unpin|restore <name>` and `/curator list-archived` through slash.exec, with the
    gateway's own words.
In a chat, "… skill" makes Hermes write one with `skill_manage` (action create).

Mock-only: POST /api/mock/learned/reset.
"""

import base64
import json
import threading
import time
import uuid

B = None
G = None
C = None
M = None          # memory.py
LOCK = threading.RLock()
HOME = "/Users/studio"
HERMES = f"{HOME}/.hermes"
DAY = 86400

SKILLS = {}       # profile -> {name: skill}
ARCHIVED = {}     # profile -> {name: skill}
REPORTS = {}      # profile -> [(stamp, report)] oldest first
CURATOR = {}      # profile -> {paused, last_run_at}
RUN = {"running": False, "exit_code": None, "pid": None, "profile": None}


def skill(name, category, uses, days_ago, *, created_by="agent", state="active", related=(), text=None, created_days_ago=None):
    made = created_days_ago if created_days_ago is not None else max(days_ago, 9 + (hash(name) % 50))
    return {"name": name, "category": category, "useCount": uses, "timestamp": time.time() - days_ago * DAY,
            "created": time.time() - made * DAY,
            "createdBy": created_by, "state": state, "pinned": False, "related": list(related),
            "text": text or f"---\nname: {name}\ndescription: {name.replace('-', ' ').capitalize()} the way Studio Mac does it.\n---\n\n# {name}\n\n1. Check what's there.\n2. Do it.\n3. Report back.\n"}


def seed():
    now = time.time()
    with LOCK:
        SKILLS.clear(), ARCHIVED.clear(), REPORTS.clear(), CURATOR.clear()
        SKILLS["default"] = {s["name"]: s for s in [
            skill("ios-testing", "ios", 12, 1, related=["xcode-build", "swiftui-previews", "app-store-listing"],
                  text="---\nname: ios-testing\ndescription: Runs the iOS tests on Studio Mac and retries a flaky snapshot test once.\nrelated_skills: [xcode-build, swiftui-previews]\n---\n\n# ios-testing\nRun the iOS tests with xcodebuild on Studio Mac.\n1. Boot the iPhone 17 Pro simulator.\n2. Run the Hermes scheme; collect failures.\n3. Retry a failed snapshot test once.\n4. Report what failed, with the log lines.\n"),
            skill("xcode-build", "ios", 9, 3, related=["swiftui-previews"]),
            skill("swiftui-previews", "ios", 3, 12),
            skill("app-store-listing", "writing", 2, 2, related=["release-notes"], created_days_ago=2,
                  text="---\nname: app-store-listing\ndescription: Writes the App Store listing from the release notes and screenshots.\n---\n\n# app-store-listing\n1. Read the latest release notes.\n2. Draft the subtitle, promo text and what's new.\n3. Keep each under its limit.\n"),
            skill("release-notes", "writing", 7, 6, related=["changelog-style"]),
            skill("changelog-style", "writing", 2, 40, created_by="learn"),
            skill("nas-backups", "home", 8, 4, related=["synology-dsm", "docker-compose"]),
            skill("docker-compose", "home", 3, 15),
            skill("synology-dsm", "home", 1, 34, state="stale"),
            skill("arxiv-digest", "research", 6, 3.5, related=["paper-summary"], created_days_ago=3.5),
            skill("paper-summary", "research", 2, 25),
        ]}
        ARCHIVED["default"] = {s["name"]: s for s in [
            skill("xcode-test-runner", "ios", 4, 60, state="archived"),
            skill("snapshot-tests", "ios", 2, 70, state="archived"),
            skill("docker-cleanup", "home", 1, 92, state="archived"),
        ]}
        SKILLS["researcher"] = {s["name"]: s for s in [
            skill("arxiv-digest", "research", 9, 2, related=["paper-summary"]),
            skill("paper-summary", "research", 4, 9),
        ]}
        ARCHIVED["researcher"] = {}
        for profile in SKILLS:
            CURATOR[profile] = {"paused": False, "last_run_at": now - 2 * DAY}
        REPORTS["default"] = [(stamp(now - 9 * DAY), report(now - 9 * DAY)),
                              (stamp(now - 2 * DAY), report(now - 2 * DAY,
            consolidated=[{"name": "xcode-test-runner", "into": "ios-testing", "source": "absorbed_into", "reason": "xcode-test-runner and snapshot-tests overlapped"},
                          {"name": "snapshot-tests", "into": "ios-testing", "source": "absorbed_into", "reason": ""}],
            pruned=[{"name": "docker-cleanup", "source": "stale", "reason": "Unused for 92 days"}],
            stale=["synology-dsm"], marked_stale=4))]
        REPORTS["researcher"] = []


def stamp(ts):
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(ts))


def report(ts, consolidated=(), pruned=(), stale=(), marked_stale=0):
    archived = [c["name"] for c in consolidated] + [p["name"] for p in pruned]
    return {"started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts)), "duration_seconds": 41.2,
            "counts": {"archived_this_run": len(archived), "consolidated_this_run": len(consolidated), "pruned_this_run": len(pruned)},
            "auto_transitions": {"marked_stale": marked_stale, "archived": 0, "reactivated": 0, "checked": 14},
            "archived": archived, "consolidated": list(consolidated), "pruned": list(pruned),
            "state_transitions": [{"name": n, "from": "active", "to": "stale"} for n in stale], "added": []}


def install(backend_globals, gateway_module, chats_module, memory_module):
    global B, G, C, M
    B, G, C, M = backend_globals, gateway_module, chats_module, memory_module
    seed()
    routes, raw = B["HTTP_ROUTES"], B["RAW_ROUTES"]
    memory_graph = routes[("GET", "/api/learning/graph")]
    memory_detail = routes[("GET", "/api/learning/node")]
    memory_edit = routes[("PUT", "/api/learning/node")]
    memory_delete = routes[("DELETE", "/api/learning/node")]

    def is_memory(node_id):
        return (node_id or "").startswith("memory:")

    routes[("GET", "/api/learning/graph")] = lambda q, b: graph(q, b, memory_graph)
    routes[("GET", "/api/learning/node")] = lambda q, b: memory_detail(q, b) if is_memory(first(q, "id")) else node_detail(q, b)
    routes[("PUT", "/api/learning/node")] = lambda q, b: memory_edit(q, b) if is_memory((b or {}).get("id")) else node_edit(q, b)
    routes[("DELETE", "/api/learning/node")] = lambda q, b: memory_delete(q, b) if is_memory((b or {}).get("id")) else node_archive(q, b)
    routes[("GET", "/api/skills/content")] = skill_content
    routes[("GET", "/api/curator")] = curator_status
    routes[("PUT", "/api/curator/paused")] = curator_paused
    routes[("POST", "/api/curator/run")] = curator_run
    routes[("GET", "/api/actions/curator-run/status")] = lambda q, b: (200, {"name": "curator-run", "running": RUN["running"],
                                                                             "exit_code": RUN["exit_code"], "pid": RUN["pid"], "lines": []})
    routes[("GET", "/api/files")] = files_list
    routes[("GET", "/api/files/read")] = files_read
    routes[("POST", "/api/mock/learned/reset")] = lambda q, b: (seed(), (200, {"ok": True}))[1]
    # The Inspector's File tab reads the SKILL.md through /api/fs/read-text and saves with write-text.
    fs_read, fs_write = routes.get(("GET", "/api/fs/read-text")), routes.get(("POST", "/api/fs/write-text"))
    routes[("GET", "/api/fs/read-text")] = lambda q, b: fs_skill_read(q) or (fs_read(q, b) if fs_read else (404, {"detail": "not found"}))
    fs_ls = routes.get(("GET", "/api/fs/list"))
    routes[("GET", "/api/fs/list")] = lambda q, b: fs_skill_list(q) or (fs_ls(q, b) if fs_ls else (200, {"entries": []}))
    routes[("POST", "/api/fs/write-text")] = lambda q, b: fs_skill_write(b) or (fs_write(q, b) if fs_write else (404, {"detail": "not found"}))
    methods = B["METHODS"]
    slash = methods["slash.exec"]

    def slash_exec(params):
        command = (params.get("command") or "").strip()
        if command.startswith("/curator"):
            profile = M.runtime_profile(params)
            return {"output": curator_command(profile, command[len("/curator"):].strip())}
        return slash(params)

    methods["slash.exec"] = slash_exec
    original = C.run_chat_turn

    def run_chat_turn(sid, text):
        if "skill" in text.lower() and "test" not in text.lower():
            return run_skill_turn(sid, text)
        return original(sid, text)

    C.run_chat_turn = run_chat_turn


def first(query, name):
    return ((query or {}).get(name) or [""])[0]


def profile_of(query, body=None):
    profile = M.profile_of(query, body)
    with LOCK:
        SKILLS.setdefault(profile, {})
        ARCHIVED.setdefault(profile, {})
        REPORTS.setdefault(profile, [])
        CURATOR.setdefault(profile, {"paused": False, "last_run_at": None})
    return profile


# ---------------------------------------------------------------- the graph


def tokens(text):
    import re
    return {t for t in re.split(r"[^a-z0-9]+", (text or "").lower()) if len(t) >= 3}


def graph(query, body, memory_graph):
    profile = profile_of(query)
    status, base = memory_graph(query, body)
    if status != 200:
        return status, base
    memories = [n for n in base.get("nodes", []) if n.get("kind") == "memory"]
    # Spread the memories over the last ten weeks, oldest first, for the story's chart.
    now = time.time()
    for index, node in enumerate(memories):
        node["timestamp"] = now - (len(memories) - index) * 3.3 * DAY
        node.update(useCount=0, state="active", createdBy="memory", pinned=False)
    with LOCK:
        skills = list(SKILLS[profile].values())
    nodes = [{"id": s["name"], "label": s["name"], "kind": "skill", "timestamp": int(s["timestamp"]), "category": s["category"],
              "useCount": s["useCount"], "state": s["state"], "createdBy": s["createdBy"], "pinned": s["pinned"]} for s in skills]
    names = {s["name"] for s in skills}
    edges = []
    for s in skills:
        for target in s["related"]:
            if target in names:
                pair = tuple(sorted((s["name"], target)))
                if pair not in edges:
                    edges.append(pair)
    for node in memories:
        words = tokens(node["label"])
        scored = sorted(((len(words & tokens(s["name"])) + (6 if s["name"] in node["label"].lower() else 0), s["name"]) for s in skills), reverse=True)
        edges += [(node["id"], name) for score, name in scored[:2] if score > 0]
    clusters = {}
    for s in skills:
        clusters[s["category"]] = clusters.get(s["category"], 0) + 1
    if memories:
        clusters["memory"] = len(memories)
    return 200, {"nodes": nodes + memories, "edges": [{"source": a, "target": b} for a, b in edges],
                 "clusters": [{"category": c, "count": n} for c, n in sorted(clusters.items(), key=lambda kv: -kv[1])],
                 "memory": base.get("memory", []), "stats": {"learned_skills": len(skills), "memory_nodes": len(memories)}}


def node_detail(query, body):
    profile = profile_of(query)
    name = first(query, "id")
    with LOCK:
        s = SKILLS[profile].get(name)
    if s is None:
        return 404, {"detail": f"skill '{name}' not found"}
    return 200, {"ok": True, "kind": "skill", "id": name, "label": name, "content": s["text"]}


def node_edit(query, body):
    profile = profile_of(query, body)
    name, content = (body or {}).get("id"), (body or {}).get("content") or ""
    with LOCK:
        s = SKILLS[profile].get(name)
        if s is None:
            return 400, {"detail": f"skill '{name}' not found"}
        if not content.strip():
            return 400, {"detail": "empty SKILL.md"}
        s["text"] = content
    return 200, {"ok": True, "message": f"updated {name}"}


def node_archive(query, body):
    profile = profile_of(query, body)
    name = (body or {}).get("id")
    with LOCK:
        s = SKILLS[profile].pop(name, None)
        if s is None:
            return 400, {"detail": f"skill '{name}' not found"}
        s["state"] = "archived"
        ARCHIVED[profile][name] = s
    return 200, {"ok": True, "message": f"archived {name} (restore with `hermes curator restore {name}`)"}


def skill_path(profile, name):
    with LOCK:
        s = SKILLS.get(profile, {}).get(name)
    if s is None:
        return None
    root = HERMES if profile == "default" else f"{HERMES}/profiles/{profile}"
    return f"{root}/skills/{s['category']}/{name}/SKILL.md"


def skill_content(query, body):
    profile = profile_of(query)
    name = first(query, "name")
    path = skill_path(profile, name)
    if path is None:
        return 404, {"detail": f"Skill '{name}' not found."}
    with LOCK:
        text = SKILLS[profile][name]["text"]
    return 200, {"name": name, "content": text, "path": path}


def skill_at(path):
    for profile, skills in SKILLS.items():
        for name in skills:
            if skill_path(profile, name) == path:
                return profile, name
    return None


def fs_skill_read(query):
    found = skill_at(first(query, "path"))
    if not found:
        return None
    profile, name = found
    text = SKILLS[profile][name]["text"]
    return 200, {"path": first(query, "path"), "text": text, "language": "markdown", "mimeType": "text/markdown",
                 "byteSize": len(text.encode()), "truncated": False, "binary": False}


def fs_skill_list(query):
    """A skill's folder (and the skills tree above it) for the Inspector's file list."""
    path = (first(query, "path") or "").rstrip("/")
    if path == HOME:  # the home a chat without a project starts in
        return 200, {"entries": [{"name": ".hermes", "path": HERMES, "isDirectory": True},
                                 {"name": "Code", "path": f"{HOME}/Code", "isDirectory": True}]}
    if not path.startswith(HERMES):
        return None  # the projects' folders are inspector.py's
    entries = {}
    with LOCK:
        for profile, skills in SKILLS.items():
            for name in skills:
                root = HERMES if profile == "default" else f"{HERMES}/profiles/{profile}"
                file = f"{root}/skills/{skills[name]['category']}/{name}/SKILL.md"
                if not file.startswith(path + "/"):
                    continue
                child = file[len(path) + 1:].split("/", 1)[0]
                is_dir = "/" in file[len(path) + 1:]
                entries[child] = {"name": child, "path": f"{path}/{child}", "isDirectory": is_dir}
    if not entries:
        return None
    return 200, {"entries": sorted(entries.values(), key=lambda e: (not e["isDirectory"], e["name"]))}


def fs_skill_write(body):
    found = skill_at((body or {}).get("path"))
    if not found:
        return None
    profile, name = found
    with LOCK:
        SKILLS[profile][name]["text"] = (body or {}).get("content") or ""
    return 200, {"ok": True}


# ---------------------------------------------------------------- the curator


def curator_status(query, body):
    profile = profile_of(query)
    with LOCK:
        state = dict(CURATOR[profile])
    last = state.get("last_run_at")
    return 200, {"enabled": True, "paused": state["paused"], "interval_hours": 168,
                 "last_run_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(last)) if last else None,
                 "min_idle_hours": 2, "stale_after_days": 30, "archive_after_days": 90}


def curator_paused(query, body):
    profile = profile_of(query, body)
    with LOCK:
        CURATOR[profile]["paused"] = bool((body or {}).get("paused"))
    return 200, {"ok": True, "paused": CURATOR[profile]["paused"]}


def curator_run(query, body):
    profile = profile_of(query, body)
    if RUN["running"]:
        return 409, {"detail": "curator-run is already running"}
    RUN.update(running=True, exit_code=None, pid=40000 + int(time.time()) % 1000, profile=profile)

    def tidy():
        time.sleep(6)
        now = time.time()
        with LOCK:
            skills = SKILLS[profile]
            # Merge one unpinned, lightly used skill into a related one; pinned skills stay.
            merge = None
            for name, s in sorted(skills.items(), key=lambda kv: kv[1]["useCount"]):
                if s["pinned"]:
                    continue
                into = next((o["name"] for o in skills.values() if name in o["related"] and o["name"] != name), None)
                if into:
                    merge = (name, into)
                    break
            consolidated = []
            if merge:
                name, into = merge
                s = skills.pop(name)
                s["state"] = "archived"
                ARCHIVED[profile][name] = s
                consolidated.append({"name": name, "into": into, "source": "absorbed_into", "reason": f"{name} overlapped with {into}"})
            CURATOR[profile]["last_run_at"] = now
            REPORTS[profile].append((stamp(now), report(now, consolidated=consolidated)))
        RUN.update(running=False, exit_code=0)
        if consolidated:
            B["MOCK_LEARNED_TIDIED"](profile, len(consolidated), 0) if "MOCK_LEARNED_TIDIED" in B else None

    threading.Thread(target=tidy, daemon=True).start()
    return 200, {"ok": True, "pid": RUN["pid"], "name": "curator-run"}


def curator_command(profile, arg):
    parts = arg.split()
    verb, name = (parts[0] if parts else "status"), (parts[1] if len(parts) > 1 else "")
    with LOCK:
        skills, archived = SKILLS.setdefault(profile, {}), ARCHIVED.setdefault(profile, {})
        if verb in ("pin", "unpin"):
            s = skills.get(name)
            if s is None or s["createdBy"] not in ("agent", "learn"):
                return f"curator: '{name}' is bundled or hub-installed — cannot {verb} (only agent-created skills participate in curation)"
            s["pinned"] = verb == "pin"
            return f"curator: pinned '{name}' (will bypass auto-transitions)" if verb == "pin" else f"curator: unpinned '{name}'"
        if verb == "restore":
            s = archived.pop(name, None)
            if s is None:
                return f"curator: skill '{name}' not found in archive"
            if name in skills:
                archived[name] = s
                return f"curator: destination already exists: {HERMES}/skills/{s['category']}/{name}"
            s["state"] = "active"
            skills[name] = s
            return f"curator: restored to {HERMES}/skills/{s['category']}/{name}"
        if verb == "usage":
            rows = [{"name": n, "created_by": s["createdBy"], "use_count": s["useCount"],
                     "created_at": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(s.get("created", s["timestamp"])))}
                    for n, s in sorted(skills.items())]
            return json.dumps(rows, indent=2)
        if verb == "list-archived":
            return "\n".join(sorted(archived)) if archived else "curator: no archived skills"
    return "curator: active\n  runs: 12"


# ---------------------------------------------------------------- reports through the managed files


def logs_dir(profile):
    return f"{HERMES}/logs/curator" if profile == "default" else f"{HERMES}/profiles/{profile}/logs/curator"


def files_list(query, body):
    path = first(query, "path") or HOME
    if path == HOME:
        return 200, {"path": HOME, "parent": "/Users", "entries": [
            {"name": ".hermes", "path": HERMES, "is_directory": True}], "root": None, "locked_root": None, "can_change_path": True}
    with LOCK:
        for profile, reports in REPORTS.items():
            if path == logs_dir(profile):
                entries = [{"name": s, "path": f"{path}/{s}", "is_directory": True} for s, _ in reports]
                return 200, {"path": path, "parent": path.rsplit("/", 1)[0], "entries": entries, "root": None, "locked_root": None, "can_change_path": True}
    return 404, {"detail": "Path not found"}


def files_read(query, body):
    path = first(query, "path")
    with LOCK:
        for profile, reports in REPORTS.items():
            for s, r in reports:
                if path == f"{logs_dir(profile)}/{s}/run.json":
                    data = json.dumps(r).encode()
                    return 200, {"name": "run.json", "path": path, "size": len(data), "mime_type": "application/json",
                                 "data_url": "data:application/json;base64," + base64.b64encode(data).decode()}
    return 404, {"detail": "File not found"}


# ---------------------------------------------------------------- a chat where Hermes writes a skill


def run_skill_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    profile = B["RUNTIME"][sid].get("profile") or "default"
    profile = M.key(profile)
    G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    name = "commit-message-style"
    content = f"---\nname: {name}\ndescription: Writes commit messages the way this repo does.\n---\n\n# {name}\n1. Read the last ten subjects.\n2. Match their mood and length.\n"
    C.tool(sid, stored, "skill_manage", {"action": "create", "name": name, "content": content, "category": "writing"}, 0.8,
           context=name, result=json.dumps({"success": True, "message": f"Skill '{name}' created.", "path": f"writing/{name}"}))
    with LOCK:
        SKILLS.setdefault(profile, {})[name] = skill(name, "writing", 0, 0, related=["release-notes"], text=content, created_days_ago=0)
    answer = f"I wrote a skill for that, **{name}**, so next time I'll match the repo's commit style without asking."
    C.stream(sid, answer)
    C.finish(sid, stored, answer)
