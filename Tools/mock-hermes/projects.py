"""Projects (workspaces) for the combined mock: the gateway's `projects.*` calls, `project.facts`,
`session.workspace.move`, `session.active_list`, the change events, and the dashboard's `/api/git/*`
REST mirror the desktop uses for worktrees.

Shapes follow Hermes Agent (tui_gateway/contracts/projects_pets.py, methods_projects.py,
project_tree.py, hermes_cli/projects_db.py, web_routers/git.py). Demo data is the Elyx design's:
Hermes App, Homelab, Blog, Hermes Agent fork and dotfiles, an archived Portfolio written by the
desktop app (an `hsl(…)` colour and a codicon glyph), and two found repos, caffeinated-site and
pantry. "Fix the reconnect after sleep" runs a long test turn so a project shows as working.

Chats live in server.py's store (G.SESSIONS); this module adds `_cwd` and `_branch` to the rows.
"""

import hashlib
import json
import os
import threading
import time
import uuid

B = None  # backend.py globals
G = None  # server.py module
C = None  # chats.py module

HOME = "/Users/studio"
NOW = time.time()
HOUR = 3600
DAY = 86400
LOCK = threading.RLock()

PROJECTS = {}      # id -> ProjectInfo-ish dict (folders as dicts)
ORDER = []         # creation order
STATE = {"active_id": None, "version": 0}

# Git checkouts on the "gateway": repo root -> branch of its main checkout.
REPOS = {
    f"{HOME}/Code/hermes-app": "main",
    f"{HOME}/Code/homelab": "main",
    f"{HOME}/Sites/blog": "main",
    f"{HOME}/.hermes/hermes-agent": "main",
    f"{HOME}/dotfiles": "main",
    f"{HOME}/Sites/portfolio": "main",
    f"{HOME}/Code/caffeinated-site": "main",
    f"{HOME}/Code/pantry": "main",
}
# Linked worktrees: path -> (main repo, branch).
WORKTREES = {
    f"{HOME}/Code/hermes-app-worktrees/push-notifications": (f"{HOME}/Code/hermes-app", "feature/push-notifications"),
}
OTHER_BRANCHES = {f"{HOME}/Code/hermes-app": ["release/1.3", "fix/reconnect"]}

FACTS = {
    f"{HOME}/Code/hermes-app": {"manifests": ["Package.swift", "Hermes.xcodeproj"], "packageManagers": [],
                                "verifyCommands": ["swift test", "xcodebuild -scheme Hermes test"],
                                "contextFiles": ["AGENTS.md", "docs/README.md"]},
    f"{HOME}/Code/homelab": {"manifests": ["docker-compose.yml", "Makefile"], "packageManagers": [],
                             "verifyCommands": ["make check"], "contextFiles": ["AGENTS.md"]},
    f"{HOME}/Sites/blog": {"manifests": ["package.json", "tsconfig.json"], "packageManagers": ["pnpm"],
                           "verifyCommands": ["pnpm run build", "pnpm run lint"], "contextFiles": ["CLAUDE.md"]},
    f"{HOME}/.hermes/hermes-agent": {"manifests": ["pyproject.toml"], "packageManagers": ["uv"],
                                     "verifyCommands": ["scripts/run_tests.sh", "pytest"], "contextFiles": ["AGENTS.md"]},
    f"{HOME}/dotfiles": {"manifests": ["Makefile"], "packageManagers": [], "verifyCommands": [], "contextFiles": []},
}

RUNNING_TITLE = "Fix the reconnect after sleep"


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def install(backend_globals, gateway_module, chats_module):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    seed()
    methods = B["METHODS"]
    for name, fn in {
        "projects.list": projects_list, "projects.get": projects_get, "projects.create": projects_create,
        "projects.update": projects_update, "projects.add_folder": projects_add_folder,
        "projects.remove_folder": projects_remove_folder, "projects.set_primary": projects_set_primary,
        "projects.archive": projects_archive, "projects.delete": projects_delete,
        "projects.set_active": projects_set_active, "projects.for_cwd": projects_for_cwd,
        "projects.discover_repos": projects_discover_repos, "projects.tree": projects_tree,
        "projects.project_sessions": projects_project_sessions, "project.facts": project_facts,
        "session.workspace.move": session_workspace_move, "session.cwd.set": session_cwd_set,
        "session.active_list": session_active_list, "config.get": config_get,
    }.items():
        methods[name] = guard(fn)
    wrap_session_methods(methods)
    complete = methods["complete.path"]

    def complete_path(params):
        word = params.get("word") or ""
        if word.startswith("~") or word.startswith("/"):
            return {"items": list_folders(word)}
        return complete(params)

    methods["complete.path"] = complete_path
    B["HTTP_ROUTES"].update({
        ("GET", "/api/git/worktrees"): git_worktrees,
        ("GET", "/api/git/branches"): git_branches,
        ("POST", "/api/git/worktree/add"): git_worktree_add,
    })
    threading.Thread(target=watch, daemon=True).start()
    threading.Timer(1.0, start_running_turn).start()


def guard(fn):
    """Projects errors as the gateway reports them (5061/5062/5063)."""
    def call(params):
        try:
            return fn(params or {})
        except RPCError as error:
            raise B["RPCError"](error.code, error.message)
    return call


# ---------------------------------------------------------------- seed


def add_project(pid, name, folders, icon, color, created, archived=False):
    PROJECTS[pid] = {
        "id": pid, "slug": slugify(name), "name": name, "description": None, "icon": icon, "color": color,
        "board_slug": None, "primary_path": folders[0], "archived": archived, "created_at": int(created),
        "folders": [{"path": path, "label": None, "is_primary": i == 0, "added_at": int(created) + i} for i, path in enumerate(folders)],
    }
    ORDER.append(pid)


def chat(sid, title, cwd, last, preview, answer, source="cli", branch=None):
    with G.LOCK:
        G.session_row(sid, title, source, last - 20 * 60, last, preview)
        G.add_message(sid, "user", preview, timestamp=last - 60)
        G.add_message(sid, "assistant", answer, timestamp=last)
        place(G.SESSIONS[sid], cwd, branch)


def place(session, cwd, branch=None):
    session["_cwd"] = cwd
    session["_branch"] = branch if branch is not None else branch_of(cwd)


def seed():
    add_project("p_4f2a9c1e", "Hermes App", [f"{HOME}/Code/hermes-app", f"{HOME}/.hermes/hermes-agent"],
                "chevron.left.forwardslash.chevron.right", "ocean", NOW - 60 * DAY)
    add_project("p_8b13d7a2", "Homelab", [f"{HOME}/Code/homelab"], "server.rack", "mint", NOW - 55 * DAY)
    add_project("p_c09e5f31", "Blog", [f"{HOME}/Sites/blog"], "pencil.line", "ember", NOW - 50 * DAY)
    add_project("p_5d7e2b90", "Hermes Agent fork", [f"{HOME}/.hermes/hermes-agent"], "cpu", "violet", NOW - 45 * DAY)
    add_project("p_e6a41c08", "dotfiles", [f"{HOME}/dotfiles"], "terminal", "graphite", NOW - 40 * DAY)
    # Written by the Hermes desktop app: a codicon and an hsl() swatch.
    add_project("p_71b3f9d4", "Portfolio", [f"{HOME}/Sites/portfolio"], "rocket", "hsl(330 68% 58%)", NOW - 90 * DAY, archived=True)

    app = f"{HOME}/Code/hermes-app"
    tasks = f"{app}/.worktrees"
    push = f"{HOME}/Code/hermes-app-worktrees/push-notifications"
    # The pinned "Swift 6 migration plan" from server.py's seed runs in Hermes App.
    with G.LOCK:
        welcome = G.SESSIONS.get("api_1760_welcome")
        if welcome:
            welcome["pinned"] = True
            welcome["_last"] = NOW - 2 * HOUR
            place(welcome, app)
    chat("prj_reconnect", RUNNING_TITLE, app, NOW - 90, "Fix the reconnect after sleep",
         "Found it: the socket kept its old backoff after wake. Running the tests now.")
    chat("prj_release13", "Release notes for 1.3", app, NOW - DAY - 3 * HOUR, "Draft the 1.3 release notes",
         "Drafted from 23 merged PRs. Ready for review.")
    chat("prj_syncrefactor", "Sync engine refactor notes", app, NOW - 4 * DAY, "Write up the sync refactor",
         "Notes are in docs/sync.md: three stages, one actor each.")
    chat("prj_pushplugin", "Push notifications plugin", push, NOW - 5 * HOUR, "Sketch the push plugin",
         "The plugin registers push.register and hooks approvals.")
    chat("prj_apns", "APNs relay sketch", push, NOW - 3 * DAY, "How should the relay hold the APNs key?",
         "Relay holds the key; content stays encrypted.")
    chat("prj_task_ic", "Add Increase Contrast snapshots", f"{tasks}/t_7c21e9", NOW - DAY - HOUR, "Task · in review",
         "Snapshots for every screen in both contrast modes. In review.")
    chat("prj_task_bump", "Bump swift-collections", f"{tasks}/t_19ab04", NOW - 3 * DAY - HOUR, "Task · merged",
         "Bumped to 1.3.0; all tests pass. Merged.")
    chat("prj_task_flaky", "Fix the flaky reconnect test", f"{tasks}/t_e30c5d", NOW - 5 * DAY, "Task · done",
         "The test waited on wall-clock time; it uses a test clock now.")

    lab = f"{HOME}/Code/homelab"
    for i, (title, ago, ask, answer) in enumerate([
        ("Upgrade Home Assistant", 3 * HOUR, "Upgrade Home Assistant to 2026.10", "Upgraded; the Zigbee add-on restarted cleanly."),
        ("Pi-hole blocklists", DAY + 2 * HOUR, "Tidy the Pi-hole blocklists", "Merged five lists into two; 18% fewer false positives."),
        ("NAS backup schedule", 2 * DAY, "When do the NAS backups run?", "Nightly at 02:30, weekly snapshot on Sundays."),
        ("Grafana dashboard for power", 4 * DAY, "Add a power-usage dashboard", "Added: per-circuit kWh with a 30-day trend."),
        ("Renew the TLS certificates", 8 * DAY, "Renew the homelab certificates", "Renewed via DNS challenge; next renewal in 60 days."),
        ("Docker cleanup", 12 * DAY, "Clean up old Docker images", "Removed 38 images, freed 21 GB."),
    ]):
        chat(f"prj_lab_{i}", title, lab, NOW - ago, ask, answer)

    blog = f"{HOME}/Sites/blog"
    chat("prj_blog_0", "Post: Building Hermes for iPhone", blog, NOW - 3 * DAY - 2 * HOUR, "Outline a post about the iPhone app",
         "Outline: why native, the composer, approvals on the go, what's next.")
    chat("prj_blog_1", "Fix the RSS feed dates", blog, NOW - 6 * DAY, "The RSS feed shows UTC dates", "Fixed: dates use the site's time zone now.")
    chat("prj_blog_2", "Dark mode for code blocks", blog, NOW - 9 * DAY, "Code blocks are unreadable in dark mode", "Switched to Xcode's dark theme colours.")

    agent = f"{HOME}/.hermes/hermes-agent"
    chat("prj_fork_0", "Rebase the fork on upstream", agent, NOW - 16 * DAY, "Rebase my fork on upstream main", "Rebased; two conflicts in the gateway, both resolved.")
    chat("prj_fork_1", "Profile-scoped projects", agent, NOW - 18 * DAY, "How are projects scoped per profile?", "Each profile has its own projects.db in its home.")

    chat("prj_dot_0", "zsh startup time", f"{HOME}/dotfiles", NOW - 32 * DAY, "Why is my shell slow to start?", "nvm was loading eagerly; it's lazy now. 640 ms → 90 ms.")
    # Activity without a message (docs/inbox.md §2): Hermes' heartbeat in the dotfiles chat moved 7
    # minutes ago (`last_activity_at`: any API call, tool or retry stamps it), and the blog post's
    # chat was compacted 25 minutes ago, its handoff summary stored as the person's newest row. Their
    # search results keep their last messages' times; "zsh" is a title hit for the dotfiles chat.
    with G.LOCK:
        G.SESSIONS["prj_dot_0"]["_last"] = NOW - 7 * 60
    G.add_message("prj_blog_0", "user", B["compaction_summary"]("## Historical Task Snapshot\nThe person asked for a post outline."),
                  timestamp=NOW - 25 * 60)
    chat("prj_folio_0", "Portfolio redesign", f"{HOME}/Sites/portfolio", NOW - 70 * DAY, "Redesign the portfolio", "New grid layout with case studies.")

    site = f"{HOME}/Code/caffeinated-site"
    for i, (title, ago) in enumerate([("Landing page copy", 2 * DAY), ("Pricing table", 6 * DAY), ("Press kit", 11 * DAY), ("Footer links", 20 * DAY)]):
        chat(f"prj_site_{i}", title, site, NOW - ago, f"Help with the {title.lower()}", "Done.")
    for i, (title, ago) in enumerate([("Pantry keyboard shortcuts", 7 * DAY), ("Pantry release build", 15 * DAY)]):
        chat(f"prj_pantry_{i}", title, f"{HOME}/Code/pantry", NOW - ago, f"Help with {title}", "Done.")

    # Everything else (Telegram, Slack, the CLI) ran in the home folder: no project.
    with G.LOCK:
        for session in G.SESSIONS.values():
            if "_cwd" not in session:
                place(session, HOME)


def start_running_turn():
    """A long `swift test` run in Hermes App, so the project row shows working."""
    try:
        sid = C.new_chat_runtime("prj_reconnect")
        B["start_turn"](sid, "Run the test suite and fix what fails", run_tests_turn)
    except Exception as error:  # noqa: BLE001 — demo garnish only
        print(f"[mock-projects] couldn't start the demo turn: {error}", flush=True)


def run_tests_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    command = "swift test --parallel"
    call = f"call_{uuid.uuid4().hex[:8]}"
    C.emit(sid, "tool.start", {"tool_id": call, "name": "terminal", "context": command, "args": {"command": command}})
    passed = 212
    while passed < 240 and not C.interrupted(sid):
        C.emit(sid, "status.update", {"kind": "status", "text": f"Running swift test · {passed} of 240 passed"})
        for _ in range(240):
            if C.interrupted(sid):
                break
            time.sleep(0.25)
        passed += 1
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "terminal", "args": {"command": command}, "duration_s": 600,
                                  "result": json.dumps({"output": f"{passed} of 240 passed", "exit_code": 0}), "summary": None})
    if C.interrupted(sid):
        return C.finish(sid, stored, "", status="interrupted")
    answer = "All **240 tests pass**. The reconnect now resets its backoff after the Mac wakes."
    C.stream(sid, answer)
    return C.finish(sid, stored, answer)


# ---------------------------------------------------------------- helpers


def slugify(name):
    out, dash = [], False
    for ch in name.lower():
        if ch.isalnum():
            out.append(ch)
            dash = False
        elif not dash:
            out.append("-")
            dash = True
    return ("".join(out).strip("-") or "project")[:64]


def norm(path):
    path = (path or "").strip()
    if path.startswith("~"):
        path = HOME + path[1:]
    path = os.path.normpath(path) if path else path
    return path.rstrip("/") or "/"


def contains(folder, path):
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def repo_of(cwd):
    """(repo root, worktree path or None) for a folder, folding linked worktrees into their repo."""
    for wt, (repo, _) in WORKTREES.items():
        if contains(wt, cwd):
            return repo, wt
    best = None
    for repo in REPOS:
        if contains(repo, cwd) and (best is None or len(repo) > len(best)):
            best = repo
    return best, None


def branch_of(cwd):
    repo, wt = repo_of(cwd)
    if wt:
        return WORKTREES[wt][1]
    if repo:
        tasks = f"{repo}/.worktrees/"
        if cwd.startswith(tasks):
            return "hermes/" + cwd[len(tasks):].split("/")[0]
        return REPOS[repo]
    return ""


def info(pid):
    p = PROJECTS[pid]
    out = dict(p)
    folders = sorted(p["folders"], key=lambda f: (not f["is_primary"], f["added_at"]))
    out["folders"] = [dict(f) for f in folders]
    return out


def find(pid):
    pid = (pid or "").strip()
    if pid in PROJECTS:
        return pid
    for key, p in PROJECTS.items():
        if p["slug"] == pid:
            return key
    raise RPCError(5062, "no such project")


def changed():
    with LOCK:
        STATE["version"] += 1


def listing():
    return {"projects": [info(pid) for pid in ORDER if pid in PROJECTS], "active_id": STATE["active_id"]}


def broadcast(kind):
    frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": "", "payload": {}}}
    with B["LOCK"]:
        peers = list(B["CLIENTS"])
    for peer in peers:
        try:
            peer.send(frame)
        except OSError:
            pass


# ---------------------------------------------------------------- projects.*


def projects_list(params):
    with LOCK:
        return listing()


def projects_get(params):
    with LOCK:
        return {"project": info(find(params.get("id")))}


def projects_create(params):
    name = (params.get("name") or "").strip()
    if not name:
        raise RPCError(5063, "project name must not be empty")
    folders = [norm(f) for f in params.get("folders") or [] if (f or "").strip()]
    primary = norm(params["primary_path"]) if params.get("primary_path") else (folders[0] if folders else None)
    if primary and primary not in folders:
        folders.insert(0, primary)
    with LOCK:
        if primary:
            for pid, p in PROJECTS.items():
                if not p["archived"] and p["primary_path"] and p["primary_path"].lower() == primary.lower():
                    raise RPCError(5063, f"folder already belongs to project '{p['slug']}' ({pid}); switch to it instead of creating a duplicate")
        pid = "p_" + uuid.uuid4().hex[:8]
        slug, n = slugify(name), 2
        base = slug
        while any(p["slug"] == slug for p in PROJECTS.values()):
            slug, n = f"{base}-{n}", n + 1
        now = int(time.time())
        PROJECTS[pid] = {
            "id": pid, "slug": slug, "name": name, "description": params.get("description"), "icon": params.get("icon") or None,
            "color": params.get("color") or None, "board_slug": None, "primary_path": primary, "archived": False, "created_at": now,
            "folders": [{"path": f, "label": None, "is_primary": f == primary, "added_at": now + i} for i, f in enumerate(folders)],
        }
        ORDER.append(pid)
        if params.get("use"):
            STATE["active_id"] = pid
        result = {"project": info(pid)}
    changed()
    return result


def projects_update(params):
    with LOCK:
        pid = find(params.get("id"))
        p = PROJECTS[pid]
        if "name" in params and params["name"] is not None:
            if not params["name"].strip():
                raise RPCError(5063, "project name must not be empty")
            p["name"] = params["name"].strip()
        for key in ("description", "icon", "color", "board_slug"):
            if key in params and params[key] is not None:
                p[key] = params[key] if (params[key] != "" or key == "description") else None
        result = {"project": info(pid)}
    changed()
    return result


def projects_add_folder(params):
    path = norm(params.get("path"))
    with LOCK:
        pid = find(params.get("id"))
        p = PROJECTS[pid]
        existing = next((f for f in p["folders"] if f["path"] == path), None)
        if existing:
            existing["label"] = params.get("label") or existing["label"]
        else:
            p["folders"].append({"path": path, "label": params.get("label"), "is_primary": False, "added_at": int(time.time())})
        if params.get("is_primary") or not p["primary_path"]:
            set_primary(p, path)
        result = {"project": info(pid)}
    changed()
    return result


def set_primary(p, path):
    if not any(f["path"] == path for f in p["folders"]):
        return
    for f in p["folders"]:
        f["is_primary"] = f["path"] == path
    p["primary_path"] = path


def projects_remove_folder(params):
    path = norm(params.get("path"))
    with LOCK:
        pid = find(params.get("id"))
        p = PROJECTS[pid]
        p["folders"] = [f for f in p["folders"] if f["path"] != path]
        if p["primary_path"] == path:
            p["primary_path"] = None
            if p["folders"]:
                set_primary(p, min(p["folders"], key=lambda f: f["added_at"])["path"])
        result = {"project": info(pid)}
    changed()
    return result


def projects_set_primary(params):
    with LOCK:
        pid = find(params.get("id"))
        set_primary(PROJECTS[pid], norm(params.get("path")))
        result = {"project": info(pid)}
    changed()
    return result


def projects_archive(params):
    with LOCK:
        pid = find(params.get("id"))
        PROJECTS[pid]["archived"] = not params.get("restore")
        result = listing()
    changed()
    return result


def projects_delete(params):
    with LOCK:
        pid = find(params.get("id"))
        del PROJECTS[pid]
        ORDER.remove(pid)
        result = listing()
    changed()
    return result


def projects_set_active(params):
    with LOCK:
        pid = params.get("id")
        STATE["active_id"] = find(pid) if pid else None
        result = {"active_id": STATE["active_id"]}
    changed()
    return result


def owning_project(cwd):
    """The non-archived project whose folder is the deepest match for the folder or its git root (so
    linked worktrees elsewhere on disk belong with their repo); a primary folder wins a tie."""
    best, best_len, best_primary = None, -1, False
    repo, _ = repo_of(cwd)
    with LOCK:
        for pid in ORDER:
            p = PROJECTS.get(pid)
            if not p or p["archived"]:
                continue
            for f in p["folders"]:
                if contains(f["path"], cwd) or (repo and contains(f["path"], repo)):
                    length, primary = len(f["path"]), f["path"] == p["primary_path"]
                    if length > best_len or (length == best_len and primary and not best_primary):
                        best, best_len, best_primary = pid, length, primary
    return best


def projects_for_cwd(params):
    cwd = norm(params.get("cwd")) if params.get("cwd") else HOME
    if not os.path.isabs(cwd) or not (any(contains(r, cwd) for r in REPOS) or any(contains(w, cwd) for w in WORKTREES) or cwd == HOME):
        cwd = HOME  # a folder that doesn't exist resolves to the gateway's folder
    pid = owning_project(cwd)
    return {"project": info(pid) if pid else None, "cwd": cwd, "branch": branch_of(cwd)}


def projects_discover_repos(params):
    totals = {}
    with G.LOCK:
        for s in G.SESSIONS.values():
            repo, _ = repo_of(s.get("_cwd") or HOME)
            if repo and s["message_count"] > 0:
                count, last = totals.get(repo, (0, 0))
                totals[repo] = (count + 1, max(last, s["_last"]))
    repos = [{"root": root, "label": os.path.basename(root), "sessions": n, "last_active": last} for root, (n, last) in totals.items()]
    repos.sort(key=lambda r: r["last_active"], reverse=True)
    return {"repos": repos, "discovery_policy": {"enabled": False, "roots": [], "exclude_paths": []}}


def project_facts(params):
    cwd = norm(params.get("cwd")) if params.get("cwd") else HOME
    repo, _ = repo_of(cwd)
    if not repo:
        return {"facts": None}
    facts = FACTS.get(repo, {"manifests": [], "packageManagers": [], "verifyCommands": [], "contextFiles": []})
    return {"facts": {"root": repo, **facts}}


def config_get(params):
    if params.get("key") == "project":
        cwd = norm(params.get("cwd")) if params.get("cwd") else HOME
        return {"cwd": cwd, "branch": branch_of(cwd)}
    return {"value": None}


# ---------------------------------------------------------------- tree


def tree_sessions(limit):
    with G.LOCK:
        rows = [s for s in G.SESSIONS.values()
                if s["message_count"] >= 1 and not s.get("archived") and not s.get("hidden")
                and s.get("source") not in ("cron", "kanban", "oneshot") and not s.get("parent_session_id")]
        rows.sort(key=lambda s: s["_last"], reverse=True)
        return [dict(s) for s in rows[:limit]]


def row(s, profile):
    return {"id": s["id"], "_lineage_root_id": None, "_lineage_ids": [s["id"]], "parent_session_id": None,
            "title": s["title"] or None, "preview": s["_preview"] or None, "started_at": s["started_at"],
            "ended_at": None, "last_active": s["_last"], "source": s["source"], "archived": False,
            "message_count": s["message_count"], "tool_call_count": s["tool_call_count"], "input_tokens": 0,
            "output_tokens": 0, "actual_cost_usd": None, "estimated_cost_usd": s["estimated_cost_usd"],
            "model": s["model"], "is_active": False, "cwd": s.get("_cwd"), "git_branch": s.get("_branch") or None,
            "git_repo_root": repo_of(s.get("_cwd") or HOME)[0], "profile": profile or "default"}


def lanes_for(repo, sessions, hydrate, profile):
    groups = {}
    for s in sessions:
        cwd = s.get("_cwd") or repo
        _, wt = repo_of(cwd)
        if cwd.startswith(f"{repo}/.worktrees/t_"):
            key = (f"{repo}::kanban", "kanban", f"{repo}/.worktrees", False, True)
        elif wt:
            key = (wt, os.path.basename(wt), wt, False, False)
        else:
            branch = s.get("_branch") or "main"
            key = (f"{repo}::branch::{branch}", branch, repo, True, False)
        groups.setdefault(key, []).append(s)

    def order(item):
        (lid, label, _, is_main, is_kanban), rows = item
        trunk = is_main and label in ("main", "master", "trunk", "develop")
        return (0 if trunk else 2 if is_kanban else 1, -max(r["_last"] for r in rows), label)

    lanes = []
    for (lid, label, path, is_main, is_kanban), rows in sorted(groups.items(), key=order):
        lanes.append({"id": lid, "label": label, "path": path, "isMain": is_main, "isKanban": is_kanban, "isGit": True,
                      "sessions": [row(r, profile) for r in rows] if hydrate else []})
    return lanes


def node_for(pid, sessions, preview_limit, hydrate, profile):
    p = PROJECTS[pid]
    repos = []
    for f in sorted(p["folders"], key=lambda f: (not f["is_primary"], f["added_at"])):
        mine = [s for s in sessions if contains(f["path"], s.get("_cwd") or "") or contains(f["path"], repo_of(s.get("_cwd") or "")[0] or "\0")]
        repos.append({"id": f["path"], "label": os.path.basename(f["path"]), "path": f["path"],
                      "groups": lanes_for(f["path"], mine, hydrate, profile) if mine else [], "sessionCount": len(mine)})
    return node(pid, p["name"], p["primary_path"], p["color"], p["icon"], False, False, sessions, repos, preview_limit, hydrate, profile)


def node(nid, label, path, color, icon, is_auto, is_home, sessions, repos, preview_limit, hydrate, profile):
    newest = sorted(sessions, key=lambda s: s["_last"], reverse=True)
    return {"id": nid, "label": label, "path": path, "color": color, "icon": icon, "isAuto": is_auto, "isNoProject": is_home,
            "sessionCount": len(sessions), "lastActive": newest[0]["_last"] if newest else 0, "totalTokens": 0, "totalCostUsd": 0.0,
            "repos": repos, "previewSessions": [] if hydrate else [row(s, profile) for s in newest[:preview_limit]],
            "sessionIds": [s["id"] for s in newest]}


def build_tree(preview_limit, session_limit, hydrate, profile):
    sessions = tree_sessions(session_limit)
    owned, auto, home = {}, {}, []
    for s in sessions:
        cwd = s.get("_cwd") or HOME
        pid = owning_project(cwd)
        if pid:
            owned.setdefault(pid, []).append(s)
            continue
        repo, _ = repo_of(cwd)
        if repo:
            auto.setdefault(repo, []).append(s)
        else:
            home.append(s)
    nodes = []
    if home:
        nodes.append(node("__no_project__", "Home", None, None, None, False, True, home,
                          [{"id": "__no_project__", "label": "Home", "path": None, "sessionCount": len(home),
                            "groups": [{"id": "__no_project__::home", "label": "Home", "path": None, "isMain": True, "isKanban": False,
                                        "sessions": [row(r, profile) for r in home] if hydrate else []}]}],
                          preview_limit, hydrate, profile))
    with LOCK:
        for pid in ORDER:
            p = PROJECTS.get(pid)
            if p and not p["archived"]:
                nodes.append(node_for(pid, owned.get(pid, []), preview_limit, hydrate, profile))
    for repo, rows in sorted(auto.items(), key=lambda kv: -max(r["_last"] for r in kv[1])):
        nodes.append(node(repo, os.path.basename(repo), repo, None, None, True, False, rows,
                          [{"id": repo, "label": os.path.basename(repo), "path": repo, "groups": lanes_for(repo, rows, hydrate, profile),
                            "sessionCount": len(rows)}], preview_limit, hydrate, profile))
    return {"projects": nodes, "active_id": STATE["active_id"], "scoped_session_ids": [s["id"] for s in sessions]}


def projects_tree(params):
    return build_tree(int(params.get("preview_limit") or 3), int(params.get("session_limit") or 2000), False, params.get("profile"))


def projects_project_sessions(params):
    pid = params.get("project_id") or ""
    if not pid:
        raise RPCError(5063, "project_id required")
    tree = build_tree(3, int(params.get("session_limit") or 5000), True, params.get("profile"))
    return {"project": next((n for n in tree["projects"] if n["id"] == pid), None)}


# ---------------------------------------------------------------- sessions


def live_info(stored):
    with G.LOCK:
        s = G.SESSIONS.get(stored) or {}
        cwd = s.get("_cwd") or HOME
    pid = owning_project(cwd)
    project = None
    if pid:
        p = PROJECTS[pid]
        project = {"id": pid, "slug": p["slug"], "name": p["name"], "primary_path": p["primary_path"]}
    return {"cwd": cwd, "branch": branch_of(cwd) or None, "project": project}


def wrap_session_methods(methods):
    create, resume = methods["session.create"], methods["session.resume"]

    def create_with_cwd(params):
        cwd = params.get("cwd")
        result = create(params)
        stored = result.get("stored_session_id")
        with G.LOCK:
            session = G.SESSIONS.get(stored)
            if session is not None:
                place(session, norm(cwd) if cwd else HOME)
        if stored:
            result.setdefault("info", {}).update(live_info(stored))
        return result

    def resume_with_cwd(params):
        result = resume(params)
        stored = params.get("session_id")
        with G.LOCK:
            known = stored in G.SESSIONS
        if known:
            result.setdefault("info", {}).update(live_info(stored))
        return result

    methods["session.create"] = create_with_cwd
    methods["session.resume"] = resume_with_cwd


def session_workspace_move(params):
    key = params.get("session_key") or ""
    if not key:
        raise B["RPCError"](4007, "session_key required")
    raw = params.get("cwd") or ""
    if not raw:
        raise B["RPCError"](4016, "cwd required")
    cwd = norm(raw)
    repo, wt = repo_of(cwd)
    if not (repo or wt or cwd == HOME):
        raise B["RPCError"](4017, f"working directory does not exist: {raw}")
    with G.LOCK:
        session = G.SESSIONS.get(key)
        if session is None:
            raise B["RPCError"](4007, "session not found")
        place(session, cwd)
    # A live agent follows, even mid-turn.
    with B["LOCK"]:
        live = [sid for sid, r in B["RUNTIME"].items() if r.get("stored") == key]
    for sid in live:
        C.emit(sid, "session.info", live_info(key))
    return {"cwd": cwd, "branch": branch_of(cwd), "git_repo_root": repo or ""}


def session_cwd_set(params):
    sid = params.get("session_id") or ""
    runtime = B["RUNTIME"].get(sid)
    if runtime is None:
        raise B["RPCError"](4001, "session not found")
    if runtime.get("running"):
        raise B["RPCError"](4009, "session busy")
    cwd = norm(params.get("cwd") or "")
    if not cwd:
        raise B["RPCError"](4016, "cwd required")
    with G.LOCK:
        session = G.SESSIONS.get(runtime["stored"])
        if session is not None:
            place(session, cwd)
    data = live_info(runtime["stored"])
    C.emit(sid, "session.info", data)
    return data


def session_active_list(params):
    with B["LOCK"]:
        rows = [(sid, r) for sid, r in B["RUNTIME"].items() if r.get("kind") == "chat"]
    out = []
    for sid, r in rows:
        with G.LOCK:
            s = G.SESSIONS.get(r["stored"]) or {}
        out.append({"current": False, "id": sid, "session_key": r["stored"], "status": "working" if r.get("running") else "idle",
                    "title": s.get("title"), "preview": s.get("_preview"), "message_count": s.get("message_count", 0),
                    "model": s.get("model"), "started_at": s.get("started_at"), "last_active": s.get("_last")})
    return {"sessions": out}


# ---------------------------------------------------------------- change events


def watch():
    """Like tui_gateway/change_watcher.py: polls and broadcasts `sessions.changed` (at most every 2 s)
    and `projects.changed` to every client; the first reading is a silent baseline."""
    last_digest, last_version, last_sent, pending = None, STATE["version"], 0.0, False
    while True:
        time.sleep(0.5)
        with G.LOCK:
            parts = sorted((s["id"], s.get("_cwd"), s.get("_branch"), s.get("title"), s.get("archived"), s.get("pinned"),
                            s.get("hidden"), s.get("_last_read_at"), s["message_count"]) for s in G.SESSIONS.values())
        with B["LOCK"]:
            # The Bots' stores too (Hermes watches every served profile), read marks included.
            parts += sorted((sid, s.get("last_read_at"), len(s["messages"])) for sid, s in B["STORED"].items())
        digest = hashlib.sha1(json.dumps(parts, default=str).encode()).hexdigest()
        if last_digest is not None and digest != last_digest:
            pending = True
        last_digest = digest
        if pending and time.time() - last_sent >= 2:
            broadcast("sessions.changed")
            last_sent, pending = time.time(), False
        with LOCK:
            version = STATE["version"]
        if version != last_version:
            last_version = version
            broadcast("projects.changed")


# ---------------------------------------------------------------- folders on the "gateway"

FOLDERS = sorted({*REPOS, *WORKTREES, f"{HOME}/Documents", f"{HOME}/Downloads", f"{HOME}/Code/new-app",
                  f"{HOME}/Code/hermes-app/Sources", f"{HOME}/Code/hermes-app/Tests", f"{HOME}/Sites/blog/posts"})


def list_folders(word):
    """complete.path for `~/…` and `/…` words: the folders directly inside, as `~/Code/` and so on."""
    base = word if word.endswith("/") else word.rsplit("/", 1)[0] + "/"
    prefix = word[len(base):]
    absolute = norm(base) + "/"
    names = set()
    for folder in FOLDERS:
        if folder.startswith(absolute):
            name = folder[len(absolute):].split("/")[0]
            if name and name.lower().startswith(prefix.lower()):
                names.add(name)
    return [{"text": f"{base}{name}/", "display": f"{name}/", "meta": "dir"} for name in sorted(names)][:30]


# ---------------------------------------------------------------- /api/git (dashboard REST)


def git_worktrees(query, body):
    path = norm((query.get("path") or [""])[0])
    repo, _ = repo_of(path)
    if not repo:
        return 400, {"detail": "not a git repository"}
    rows = [{"path": repo, "branch": REPOS[repo], "isMain": True, "detached": False, "locked": False}]
    rows += [{"path": wt, "branch": branch, "isMain": False, "detached": False, "locked": False}
             for wt, (r, branch) in WORKTREES.items() if r == repo]
    return 200, {"worktrees": rows}


def git_branches(query, body):
    path = norm((query.get("path") or [""])[0])
    repo, _ = repo_of(path)
    if not repo:
        return 400, {"detail": "not a git repository"}
    worktree_of = {branch: wt for wt, (r, branch) in WORKTREES.items() if r == repo}
    names = [REPOS[repo]] + OTHER_BRANCHES.get(repo, []) + list(worktree_of)
    return 200, {"branches": [{"name": n, "checkedOut": n == REPOS[repo] or n in worktree_of, "isDefault": n == REPOS[repo],
                               "isRemote": False, "worktreePath": worktree_of.get(n, repo if n == REPOS[repo] else None)}
                              for n in dict.fromkeys(names)]}


def git_worktree_add(query, body):
    repo, _ = repo_of(norm(body.get("path") or ""))
    if not repo:
        return 400, {"detail": "not a git repository"}
    slug = slugify(body.get("name") or "") if body.get("name") else f"work-{uuid.uuid4().hex[:8]}"
    branch = body.get("branch") or f"hermes/{slug}"
    path = f"{repo}/.worktrees/{slug}"
    WORKTREES[path] = (repo, branch)
    return 200, {"path": path, "branch": branch, "repoRoot": repo}
