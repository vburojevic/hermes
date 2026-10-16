"""The Board: a mock of the gateway's kanban plugin (`plugins/kanban/dashboard/plugin_api.py`).

REST under `/api/plugins/kanban/` with `?board=` on every card call, and the event WebSocket
(`/api/plugins/kanban/events?board=&since=`) that sends `{events, cursor}` while cards change.
The Hermes App project's board ("hermes-app") is seeded like `screens/iphone/board.elyx`; other
projects get a board the first time the app opens theirs.

A pretend dispatcher picks up cards that became Ready while the mock runs (after a few seconds,
or at once after `POST /dispatch`), runs them for ~20 s with heartbeats and worker output, and
finishes them. Seeded cards stay where the design puts them.

Mock-only:
  POST /api/mock/kanban/reset                       reseed
  POST /api/mock/kanban/config {dispatcher, socket} pause the dispatcher; refuse the event socket
  POST /api/mock/kanban/act {card, action, ...}     drive a card: needs_input (reason), review (ok),
                                                     gave_up, complete, stale, heartbeat
"""

import copy
import hashlib
import re
import threading
import time

B = None          # backend.py's globals
G = None          # server.py (the API server), for regular chats
C = None          # chats.py
LOCK = threading.RLock()
HOME = "/Users/studio"
APP_REPO = f"{HOME}/Code/hermes-app"

WORKFLOW = {
    "columns": [
        {"key": "triage", "label": "Triage", "icon": "◇", "drag_target": True},
        {"key": "todo", "label": "Todo", "icon": "◻", "drag_target": True},
        {"key": "scheduled", "label": "Scheduled", "icon": "⏱", "drag_target": False},
        {"key": "ready", "label": "Ready", "icon": "▶", "drag_target": True},
        {"key": "running", "label": "Running", "icon": "●", "drag_target": False},
        {"key": "blocked", "label": "Blocked", "icon": "⊘", "drag_target": True},
        {"key": "review", "label": "Review", "icon": "◎", "drag_target": False},
        {"key": "done", "label": "Done", "icon": "✓", "drag_target": True},
    ],
    "manual": {
        "triage": ["ready", "todo"], "todo": ["ready", "scheduled", "triage"],
        "scheduled": ["ready", "todo", "triage"],
        "ready": ["blocked", "done", "review", "scheduled", "todo", "triage"],
        "running": ["blocked", "done", "ready", "review", "scheduled", "todo", "triage"],
        "blocked": ["done", "ready", "scheduled", "todo", "triage"],
        "review": ["done", "ready", "todo", "triage"], "done": ["ready", "todo", "triage"],
        "archived": ["ready", "todo", "triage"],
    },
    "archived": "archived",
}
COLUMNS = [c["key"] for c in WORKFLOW["columns"]]

BOARDS = {}       # slug -> {slug, name, project_id, default_workdir, created_at}
CARDS = {}        # card id -> card dict (the gateway's task row) with "_board"
COMMENTS = {}     # card id -> [comment]
RUNS = {}         # card id -> [run]
LOGS = {}         # card id -> [line]
EVENTS = {}       # board slug -> [event]
SIM = {}          # card id -> {"ends": epoch, "beat": epoch} for runs the pretend dispatcher started
STATE = {"dispatcher": True, "socket": True, "dispatch_now": set(), "next_event": 400, "next_run": 30, "next_comment": 70}
HOOKS = []        # fn(kind, card, payload): push.py's notices (needs you, review, stopped, done)

RUN_SECONDS = 20
DISPATCH_DELAY = 6


def now():
    return int(time.time())


def short(cid):
    return cid[-4:]


def card_id(text):
    return "t_" + hashlib.sha1(text.encode()).hexdigest()[:8]


def emit(card, kind, payload=None, run_id=None, at=None):
    """Appends an event to the card's board (the socket sends it within 0.3 s)."""
    with LOCK:
        STATE["next_event"] += 1
        event = {"id": STATE["next_event"], "task_id": card["id"], "run_id": run_id, "kind": kind,
                 "payload": payload, "created_at": at or now()}
        EVENTS.setdefault(card["_board"], []).append(event)
    for hook in HOOKS:
        try:
            hook(kind, dict(card), payload or {})
        except Exception as error:  # noqa: BLE001 — a notice must never break the board
            print(f"[kanban] hook failed: {error}", flush=True)
    return event


def new_card(board, cid, title, status, *, body=None, assignee=None, priority=0, created=None, parents=(),
             summary=None, workspace_kind="worktree", **extra):
    card = {
        "id": cid, "title": title, "body": body, "assignee": assignee, "status": status, "priority": priority,
        "created_by": "dashboard", "created_at": int(created or now()), "started_at": None, "completed_at": None,
        "workspace_kind": workspace_kind,
        "workspace_path": f"{APP_REPO}/.worktrees/{cid}" if workspace_kind == "worktree" and board == "hermes-app" else None,
        "claim_lock": None, "claim_expires": None, "tenant": None,
        "branch_name": f"wt/{cid[:2]}{short(cid)}" if workspace_kind == "worktree" else None,
        "project_id": BOARDS.get(board, {}).get("project_id"), "result": None, "idempotency_key": None,
        "consecutive_failures": 0, "worker_pid": None, "last_failure_error": None, "max_runtime_seconds": None,
        "last_heartbeat_at": None, "current_run_id": None, "workflow_template_id": None, "current_step_key": None,
        "skills": None, "model_override": None, "provider_override": None, "reasoning_effort": None,
        "max_retries": None, "goal_mode": False, "goal_max_turns": None, "session_id": None, "block_kind": None,
        "block_recurrences": 0, "completion_contract": None,
        "_board": board, "_parents": list(parents), "_summary": summary, "_ready_at": None,
    }
    card.update(extra)
    with LOCK:
        CARDS[cid] = card
        COMMENTS.setdefault(cid, [])
        RUNS.setdefault(cid, [])
    return card


def add_run(card, *, status, started, ended=None, outcome=None, summary=None, error=None, metadata=None, beat=None):
    with LOCK:
        STATE["next_run"] += 1
        run = {"id": STATE["next_run"], "task_id": card["id"], "profile": card["assignee"], "step_key": None,
               "status": status, "claim_lock": None, "claim_expires": None, "worker_pid": None,
               "max_runtime_seconds": None, "last_heartbeat_at": beat, "started_at": int(started),
               "ended_at": int(ended) if ended else None, "outcome": outcome, "summary": summary,
               "metadata": metadata, "error": error}
        RUNS.setdefault(card["id"], []).append(run)
        if ended is None:
            card["current_run_id"] = run["id"]
        if summary:
            card["_summary"] = summary
        return run


def add_comment(card, author, body, at=None):
    with LOCK:
        STATE["next_comment"] += 1
        comment = {"id": STATE["next_comment"], "task_id": card["id"], "author": author, "body": body,
                   "created_at": int(at or now())}
        COMMENTS.setdefault(card["id"], []).append(comment)
    return comment


def receipt(ok, failing=()):
    checks = []
    for name in ("build (iOS 27)", "test (snapshots)", "lint"):
        classification = "failure" if name in failing else "success"
        checks.append({"name": name, "id": abs(hash(name)) % 10_000_000,
                       "url": f"https://github.com/caffeinated/hermes-app/actions/runs/{abs(hash(name)) % 10_000_000}",
                       "head_sha": "4be1c9a" + "0" * 33, "classification": classification,
                       "conclusion": classification})
    data = {"ok": ok, "classification": "success" if ok else "failure", "head_sha": "4be1c9a" + "0" * 33,
            "pr_url": "https://github.com/caffeinated/hermes-app/pull/142", "checks": checks,
            "required": [{"context": c["name"], "app_id": None} for c in checks],
            "recovery": "Fix required failures, rerun infrastructure checks or wait, then retry completion."}
    if not ok:
        data["detail"] = f"{', '.join(failing)} failed on the PR's head."
    return data


# ---------------------------------------------------------------- seed


def seed():
    with LOCK:
        for table in (BOARDS, CARDS, COMMENTS, RUNS, LOGS, EVENTS, SIM):
            table.clear()
        STATE.update(dispatcher=True, socket=True, dispatch_now=set(), next_event=400, next_run=30, next_comment=70)
    t = now()
    BOARDS["hermes-app"] = {"slug": "hermes-app", "name": "Hermes App", "project_id": "p_4f2a9c1e",
                            "default_workdir": APP_REPO, "created_at": t - 30 * 86400}

    release = new_card("hermes-app", "t_9a4f5d02", "Release 1.3", "todo", assignee="default", created=t - 3 * 86400,
                       body="Everything for the 1.3 release.", summary="Split into 5 cards by Hermes.", workspace_kind="scratch")
    tab_bar = new_card("hermes-app", "t_3c7019ab", "Fix the tab bar on iPad", "done", assignee="default", created=t - 2 * 86400,
                       completed_at=t - 2 * 3600, summary="The tab bar keeps its items when the sidebar collapses.")
    notes = new_card("hermes-app", "t_6e2a41d7", "Draft the 1.3 release notes", "done", assignee="writer", created=t - 2 * 86400,
                     completed_at=t - 5 * 3600, summary="Drafted from 23 merged PRs.", workspace_kind="scratch")
    video = new_card("hermes-app", "t_2b6d8c3e", "Record the 1.3 preview video", "ready", assignee="default", created=t - 86400,
                     body="30 s, iPhone and Mac, from the TestFlight build.", parents=[])
    listing = new_card("hermes-app", "t_8f31c4e8", "Write the App Store listing", "blocked", assignee="writer",
                       created=t - 86400, block_kind="needs_input", workspace_kind="scratch",
                       body="Write the listing for 1.3: subtitle, description, keywords and what’s new. Keep it under the limits and match the site.")
    ship = new_card("hermes-app", "t_7c1e0b19", "Ship 1.3 to TestFlight", "todo", assignee="default", created=t - 86400,
                    body="Archive, upload, write the notes for testers.", parents=[video["id"], listing["id"]], workspace_kind="scratch")
    # Split into cards by Hermes: the split card waits on every new card (`decompose_triage_task`).
    release["_parents"] = [ship["id"], video["id"], listing["id"], tab_bar["id"], notes["id"]]
    emit(release, "decomposed", {"children": release["_parents"]}, at=t - 3 * 86400 + 60)
    contrast = new_card("hermes-app", "t_51e03fa2", "Add Increase Contrast snapshot tests", "ready", assignee="default",
                        created=t - 20 * 3600, body="Snapshot every screen with Increase Contrast on, light and dark.")

    # Running: fresh (heard 20 s ago, second attempt after a crash), and quiet for 9 minutes.
    reconnect = new_card("hermes-app", "t_4d90a91c", "Fix the reconnect after sleep", "running", assignee="default",
                         created=t - 3 * 3600, started_at=t - 50 * 60, last_heartbeat_at=t - 20, consecutive_failures=0,
                         body="After the Mac sleeps, the app shows Offline until you quit it.")
    add_run(reconnect, status="crashed", started=t - 50 * 60, ended=t - 41 * 60, outcome="crashed",
            error="worker stopped responding", summary=None)
    add_run(reconnect, status="running", started=t - 6 * 60, beat=t - 20,
            summary="Running swift test · 212 of 240 passed. Two failures in ReconnectTests are the old sleep timer; fixing next.")
    LOGS[reconnect["id"]] = ["Building for debugging...", "Test Suite ReconnectTests started", "✔ testBackoffCaps (0.02 s)",
                             "✘ testResumeAfterSleep: timeout", "… 212 of 240 passed"]
    swift_collections = new_card("hermes-app", "t_1b5577d0", "Bump swift-collections to 1.2", "running", assignee="ops",
                                 created=t - 2 * 3600, started_at=t - 14 * 60, last_heartbeat_at=t - 9 * 60)
    add_run(swift_collections, status="running", started=t - 14 * 60, beat=t - 9 * 60, summary="Resolving packages…")
    LOGS[swift_collections["id"]] = ["Fetching https://github.com/apple/swift-collections", "Resolving packages…"]

    add_comment(listing, "writer", "Draft is in listing.md. Waiting on the category before keywords.", t - 25 * 60)
    add_comment(listing, "dashboard", "Use the short subtitle from the site.", t - 40 * 60)
    add_run(listing, status="blocked", started=t - 40 * 60, ended=t - 25 * 60, outcome="blocked",
            summary="Which category: Developer Tools or Productivity?")
    emit(listing, "blocked", {"reason": "Which App Store category should the listing use: Developer Tools or Productivity?",
                              "kind": "needs_input", "recurrences": 1, "source_status": "running"}, at=t - 25 * 60)

    swiftdata = new_card("hermes-app", "t_0c2be6f1", "Migrate settings to SwiftData", "blocked", assignee="default",
                         created=t - 86400 + 3600, consecutive_failures=3,
                         last_failure_error="Build fails: Schema version 3 is missing a migration stage.")
    for attempt in range(3):
        add_run(swiftdata, status="crashed" if attempt < 2 else "gave_up", started=t - (5 - attempt) * 3600,
                ended=t - (5 - attempt) * 3600 + 600, outcome="crashed" if attempt < 2 else "gave_up",
                error="Build fails: Schema version 3 is missing a migration stage.")
    swiftdata["_summary"] = "Build fails: Schema version 3 is missing a migration stage."
    emit(swiftdata, "gave_up", {"failures": 3, "effective_limit": 3, "error": swiftdata["last_failure_error"]}, at=t - 3 * 3600)

    review = new_card("hermes-app", "t_e9d43fa2", "Add Increase Contrast snapshot tests to iPad", "review", assignee="scout",
                      created=t - 30 * 3600, started_at=t - 3 * 3600, completion_contract="https://github.com/caffeinated/hermes-app/pull/142")
    add_run(review, status="done", started=t - 3 * 3600, ended=t - 10 * 60, outcome="review_requested",
            summary="Added 46 snapshot tests with Increase Contrast on, light and dark. Fixed text-tertiary and link to reach 7:1.",
            metadata={"changed_files": [{"path": "Tests/SnapshotTests/ContrastTests.swift", "additions": 312, "deletions": 0},
                                        {"path": "Design/Tokens.swift", "additions": 4, "deletions": 4},
                                        {"path": "Tests/SnapshotTests/__Snapshots__/Contrast", "additions": 46, "deletions": 0},
                                        {"path": "Design/Colors.xcassets", "additions": 8, "deletions": 8}]})
    emit(review, "review_requested", {"reviewer": "scout"}, at=t - 10 * 60)
    emit(review, "pr_acceptance", receipt(True), at=t - 10 * 60)
    add_comment(review, "scout", "Checked every screen in both appearances. The two colour fixes match the tokens doc.", t - 10 * 60)

    done_titles = [("Snapshot the onboarding screens", "default"), ("Cache Bot faces on disk", "default"),
                   ("Translate the Settings strings", "writer"), ("Rotate the APNs key", "ops"),
                   ("Fix the Bot Chat scroll jump", "default"), ("Tidy the project's README", "writer"),
                   ("Drop the old push relay", "ops")]
    for index, (title, who) in enumerate(done_titles):
        new_card("hermes-app", card_id(title), title, "done", assignee=who, created=t - (4 + index) * 86400,
                 completed_at=t - (1 + index) * 86400, summary="Done.")


# ---------------------------------------------------------------- serialisation


def latest_summary(card):
    for run in reversed(RUNS.get(card["id"], [])):
        if run.get("summary"):
            return run["summary"]
    return card.get("_summary")


def links(card):
    children = [c["id"] for c in CARDS.values() if card["id"] in c["_parents"] and c["_board"] == card["_board"]]
    return {"parents": sorted(card["_parents"]), "children": sorted(children)}


def task_dict(card, full_summary=False):
    out = {k: v for k, v in card.items() if not k.startswith("_")}
    summary = latest_summary(card)
    out["latest_summary"] = summary if full_summary or not summary else summary[:200]
    current = next((r for r in reversed(RUNS.get(card["id"], [])) if r["ended_at"] is None), None)
    out["current_run_started_at"] = current["started_at"] if current else None
    out["age"] = {"created_age_seconds": now() - card["created_at"], "started_age_seconds": None, "time_to_complete_seconds": None}
    return out


def board_card(card):
    d = task_dict(card)
    lk = links(card)
    d["link_counts"] = {"parents": len(lk["parents"]), "children": len(lk["children"])}
    d["comment_count"] = len(COMMENTS.get(card["id"], []))
    kids = [CARDS[c] for c in lk["children"] if c in CARDS]
    d["progress"] = {"done": sum(1 for k in kids if k["status"] == "done"), "total": len(kids)} if kids else None
    if card.get("consecutive_failures"):
        d["warnings"] = {"count": 1, "kinds": {"repeated_failures": 1}, "latest_at": now(), "highest_severity": "error"}
    return d


def board_of(query, body=None):
    slug = (query.get("board", [None])[0] or (body or {}).get("board") or "default").strip().lower()
    return slug


def require_board(slug):
    if slug != "default" and slug not in BOARDS:
        return 404, {"detail": f"board {slug!r} does not exist"}
    return None


def card_in(cid, slug):
    card = CARDS.get(cid)
    if card is None or card["_board"] != slug:
        return None
    return card


def parents_open(card):
    return [CARDS[p] for p in card["_parents"] if p in CARDS and CARDS[p]["status"] not in ("done", "archived")]


# ---------------------------------------------------------------- REST


def get_workflow(query, body):
    return 200, copy.deepcopy(WORKFLOW)


def project_name(pid):
    projects = B.get("MOCK_PROJECTS")
    return projects.get(pid, {}).get("name") if projects and pid else None


def get_boards(query, body):
    with LOCK:
        rows = []
        for slug, meta in BOARDS.items():
            counts = {}
            for card in CARDS.values():
                if card["_board"] == slug:
                    counts[card["status"]] = counts.get(card["status"], 0) + 1
            rows.append({"slug": slug, "name": meta["name"], "description": None, "icon": None, "color": None,
                         "default_workdir": meta.get("default_workdir"), "project_id": meta.get("project_id"),
                         "project_name": project_name(meta.get("project_id")), "is_current": slug == "hermes-app",
                         "counts": counts, "total": sum(n for s, n in counts.items() if s != "archived"),
                         "default_workspace_kind": "worktree" if meta.get("default_workdir") else "scratch",
                         "archived": False, "created_at": meta["created_at"]})
        return 200, {"boards": rows, "current": "hermes-app"}


def post_boards(query, body):
    slug = re.sub(r"[^a-z0-9-]+", "-", (body.get("slug") or "").lower()).strip("-")
    if not slug:
        return 400, {"detail": "slug is required"}
    with LOCK:
        if slug not in BOARDS:
            pid = body.get("project_id")
            workdir = body.get("default_workdir")
            projects = B.get("MOCK_PROJECTS") or {}
            if pid and not workdir and pid in projects:
                workdir = projects[pid].get("primary_path")
            BOARDS[slug] = {"slug": slug, "name": body.get("name") or slug, "project_id": pid,
                            "default_workdir": workdir, "created_at": now()}
        meta = BOARDS[slug]
    return 200, {"board": {"slug": slug, "name": meta["name"], "project_id": meta["project_id"],
                           "project_name": project_name(meta["project_id"]), "default_workdir": meta["default_workdir"],
                           "default_workspace_kind": "worktree" if meta["default_workdir"] else "scratch", "total": 0},
                 "current": "hermes-app"}


def get_board(query, body):
    slug = board_of(query)
    if (missing := require_board(slug)):
        return missing
    with LOCK:
        columns = {c: [] for c in COLUMNS}
        cards = [c for c in CARDS.values() if c["_board"] == slug and c["status"] != "archived"]
        cards.sort(key=lambda c: (-c["priority"], c["created_at"], c["id"]))
        for card in cards:
            columns.setdefault(card["status"], []).append(board_card(card))
        columns["done"].sort(key=lambda d: -(d["completed_at"] or 0))
        latest = EVENTS.get(slug, [{"id": 0}])[-1]["id"] if EVENTS.get(slug) else 0
        return 200, {"columns": [{"name": name, "tasks": rows} for name, rows in columns.items()],
                     "tenants": [], "assignees": sorted(B["PROFILES"].keys()), "latest_event_id": latest, "now": now()}


def get_assignees(query, body):
    with LOCK:
        rows = []
        for name in B["PROFILES"]:
            counts = {}
            for card in CARDS.values():
                if card["assignee"] == name:
                    counts[card["status"]] = counts.get(card["status"], 0) + 1
            rows.append({"name": name, "on_disk": True, "counts": counts})
        return 200, {"assignees": rows}


def get_orchestration(query, body):
    return 200, {"orchestrator_profile": "", "default_assignee": "", "auto_decompose": True, "auto_promote_children": True,
                 "resolved_orchestrator_profile": "default", "resolved_default_assignee": "default", "active_profile": "default"}


def get_card(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 404, {"detail": f"task {match.group(1)} not found"}
        lk = links(card)
        linked = [CARDS[i] for i in lk["parents"] + lk["children"] if i in CARDS]
        events = [e for e in EVENTS.get(slug, []) if e["task_id"] == card["id"]]
        return 200, {
            "task": task_dict(card, full_summary=True),
            "comments": list(COMMENTS.get(card["id"], [])), "events": events, "attachments": [], "links": lk,
            "link_tasks": [{"id": c["id"], "title": c["title"], "status": c["status"]} for c in linked],
            "child_results": [{"id": c["id"], "title": c["title"], "status": c["status"], "latest_summary": latest_summary(c),
                               "result": c["result"]} for c in linked if c["id"] in lk["children"]],
            "runs": list(RUNS.get(card["id"], [])),
        }


def get_log(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 404, {"detail": f"task {match.group(1)} not found"}
        lines = LOGS.get(card["id"])
        content = "\n".join(lines or []) + ("\n" if lines else "")
        tail = int(query.get("tail", ["0"])[0] or 0)
        size = len(content.encode())
        if tail and size > tail:
            content = content.encode()[-tail:].decode("utf-8", "ignore")
        return 200, {"task_id": card["id"], "path": f"{HOME}/.hermes/kanban/logs/{card['id']}.log", "exists": lines is not None,
                     "size_bytes": size, "content": content, "truncated": bool(tail and size > tail)}


def post_card(query, body):
    slug = board_of(query)
    if (missing := require_board(slug)):
        return missing
    title = (body.get("title") or "").strip()
    if not title:
        return 400, {"detail": "title is required"}
    with LOCK:
        cid = "t_" + hashlib.sha1(f"{title}{time.time()}".encode()).hexdigest()[:8]
        parents = [p for p in body.get("parents") or [] if p in CARDS]
        status = "triage" if body.get("triage") else "ready"
        card = new_card(slug, cid, title, status, body=body.get("body"), assignee=body.get("assignee") or None,
                        priority=int(body.get("priority") or 0), parents=parents,
                        workspace_kind=body.get("workspace_kind") or ("worktree" if BOARDS.get(slug, {}).get("default_workdir") else "scratch"))
        if status == "ready" and parents_open(card):
            card["status"] = "todo"
        if card["status"] == "ready":
            card["_ready_at"] = time.time()
    emit(card, "created", {"assignee": card["assignee"], "status": card["status"], "parents": parents})
    reply = {"task": task_dict(card)}
    if card["status"] == "ready" and card["assignee"] and not STATE["dispatcher"]:
        reply["warning"] = "No kanban dispatcher is running: this card waits until the gateway starts one (hermes gateway start)."
    return 200, reply


def post_estimate(query, body):
    title = (body.get("title") or "").strip()
    if not title:
        return 200, {"ok": False, "reason": "a title is required to estimate"}
    size = len(title) + len(body.get("body") or "")
    complexity = "S" if size < 60 else "M" if size < 240 else "L"
    return 200, {"ok": True, "est_tokens": 40_000 + size * 900, "complexity": complexity,
                 "rationale": "A rough guess from the title and description.", "model": "mock-aux"}


def end_current_run(card, outcome, summary=None, error=None):
    for run in reversed(RUNS.get(card["id"], [])):
        if run["ended_at"] is None:
            run.update(ended_at=now(), status=outcome, outcome=outcome)
            if summary:
                run["summary"] = summary
            if error:
                run["error"] = error
            card["current_run_id"] = None
            SIM.pop(card["id"], None)
            return run["id"]
    return None


def move(card, target, reason=None):
    """The PATCH status verbs; returns (status, detail) on a refusal, None when it moved."""
    current = card["status"]
    if target == current:
        return None
    if target == "running":
        return 400, "Cannot set status to 'running' directly; use the dispatcher/claim path"
    if target == "archived":
        end_current_run(card, "reclaimed")
        card["status"] = "archived"
        emit(card, "archived", None)
        return None
    if target not in WORKFLOW["manual"].get(current, []):
        return 409, f"status transition to {target!r} not valid from current state"
    if target in ("ready", "done", "review") and parents_open(card):
        names = ", ".join(f"{p['title']!r} ({p['id']}, status={p['status']})" for p in parents_open(card))
        return 409, f"Cannot move to 'ready': blocked by parent(s) not done — {names}" if target == "ready" else \
            f"cannot move {card['id']} to {target!r}: unsatisfied parent dependencies"
    if target == "done":
        latest = next((e for e in reversed(EVENTS.get(card["_board"], [])) if e["task_id"] == card["id"] and e["kind"] == "pr_acceptance"), None)
        if latest and not latest["payload"]["ok"]:
            # Approve re-collects the PR's checks; a failing receipt is recorded and the move refused.
            again = copy.deepcopy(latest["payload"])
            emit(card, "pr_acceptance", again, run_id=latest["run_id"])
            card["last_failure_error"] = f"PR acceptance {again['classification']}: {again.get('detail', '')} {again['recovery']}"
            return 409, "status transition to 'done' not valid from current state"
        run_id = end_current_run(card, "done")
        card.update(status="done", completed_at=now(), last_failure_error=None, consecutive_failures=0)
        emit(card, "completed", {"summary": latest_summary(card)}, run_id=run_id)
        return None
    if current == "running":
        run_id = end_current_run(card, "reclaimed", summary=f"status changed to {target} (dashboard/direct)")
        card.update(status=target, worker_pid=None)
        emit(card, "status", {"status": target, "requested_status": target}, run_id=run_id)
    elif current == "review":
        card["status"] = "ready" if target == "todo" else target
        emit(card, "review_reopened", {"status": card["status"]})
    elif current in ("blocked", "scheduled") and target == "ready":
        card.update(status="ready", block_kind=card["block_kind"])
        emit(card, "unblocked", {"reason": reason})
    else:
        card["status"] = target
        emit(card, "status", {"status": target, "requested_status": target})
    if card["status"] == "ready":
        card["_ready_at"] = time.time()
        if current == "blocked":
            card["consecutive_failures"] = 0
            card["last_failure_error"] = None
    return None


def patch_card(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 404, {"detail": f"task {match.group(1)} not found"}
        if body.get("assignee") is not None:
            if card["status"] == "running" and (body.get("assignee") or None) != card["assignee"]:
                return 409, {"detail": f"cannot reassign {card['id']}: still running"}
            card["assignee"] = body["assignee"] or None
            emit(card, "assigned", {"assignee": card["assignee"]})
        if body.get("status") is not None:
            refusal = move(card, body["status"], body.get("block_reason"))
            if refusal:
                return refusal[0], {"detail": refusal[1]}
        if body.get("priority") is not None:
            card["priority"] = int(body["priority"])
            emit(card, "reprioritized", {"priority": card["priority"]})
        if body.get("title") is not None or body.get("body") is not None:
            if body.get("title") is not None:
                if not body["title"].strip():
                    return 400, {"detail": "title cannot be empty"}
                card["title"] = body["title"].strip()
            if body.get("body") is not None:
                card["body"] = body["body"]
            emit(card, "edited", None)
        return 200, {"task": task_dict(card)}


def delete_card(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 404, {"detail": f"task {match.group(1)} not found"}
        CARDS.pop(card["id"], None)
        SIM.pop(card["id"], None)
        for other in CARDS.values():
            if card["id"] in other["_parents"]:
                other["_parents"].remove(card["id"])
    return 200, {"deleted": True, "task_id": card["id"]}


def post_comment(match, query, body):
    slug = board_of(query)
    text = (body.get("body") or "").strip()
    if not text:
        return 400, {"detail": "body is required"}
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 404, {"detail": f"task {match.group(1)} not found"}
        author = body.get("author") or "dashboard"
        add_comment(card, author, text)
    emit(card, "commented", {"author": author, "len": len(text)})
    return 200, {"ok": True}


def post_reclaim(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None or card["status"] != "running":
            return 409, {"detail": f"cannot reclaim {match.group(1)}: not in a claimable state (not running, or unknown id)"}
        run_id = end_current_run(card, "reclaimed", summary=body.get("reason"))
        card.update(status="ready", worker_pid=None, consecutive_failures=0)
        card["_ready_at"] = None  # a stopped card waits for a person (or the next real tick)
        emit(card, "reclaimed", {"reason": body.get("reason")}, run_id=run_id)
    return 200, {"ok": True, "task_id": card["id"]}


def post_reassign(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None:
            return 409, {"detail": f"cannot reassign {match.group(1)}: unknown id"}
        if card["status"] == "running":
            if not body.get("reclaim_first"):
                return 409, {"detail": f"cannot reassign {card['id']}: unknown id, or still running (pass reclaim_first=true to release the claim first)"}
            run_id = end_current_run(card, "reclaimed", summary="reassigned")
            card["status"] = "ready"
            emit(card, "reclaimed", {"reason": "reassigned"}, run_id=run_id)
        card["assignee"] = body.get("profile") or None
        emit(card, "assigned", {"assignee": card["assignee"]})
        if card["status"] == "ready":
            card["_ready_at"] = time.time()
    return 200, {"ok": True, "task_id": card["id"], "assignee": card["assignee"]}


def post_bulk(query, body):
    slug = board_of(query)
    ids = [i for i in body.get("ids") or [] if i]
    if not ids:
        return 400, {"detail": "ids is required"}
    results = []
    with LOCK:
        for cid in ids:
            entry = {"id": cid, "ok": True}
            card = card_in(cid, slug)
            if card is None:
                entry.update(ok=False, error="not found")
            else:
                if body.get("archive"):
                    move(card, "archived")
                elif body.get("status") is not None:
                    refusal = move(card, body["status"])
                    if refusal:
                        entry.update(ok=False, error=refusal[1])
                if body.get("assignee") is not None:
                    if card["status"] == "running":
                        end_current_run(card, "reclaimed", summary="reassigned")
                        card["status"] = "ready"
                    card["assignee"] = body["assignee"] or None
                    emit(card, "assigned", {"assignee": card["assignee"]})
            results.append(entry)
    return 200, {"results": results}


def post_specify(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None or card["status"] != "triage":
            return 200, {"ok": False, "task_id": match.group(1), "reason": "not in triage", "new_title": None}
        card["body"] = ((card.get("body") or "").strip() + "\n\nDone when: it's tested on iPhone, iPad and Mac, and the "
                        "screens match the design in light, dark and Increase Contrast.").strip()
        card["status"] = "todo"
    emit(card, "specified", {"author": body.get("author")})
    return 200, {"ok": True, "task_id": card["id"], "reason": None, "new_title": card["title"]}


def post_decompose(match, query, body):
    slug = board_of(query)
    with LOCK:
        card = card_in(match.group(1), slug)
        if card is None or card["status"] != "triage":
            return 200, {"ok": False, "task_id": match.group(1), "reason": "only triage cards can be split", "fanout": False,
                         "child_ids": [], "new_title": None}
        children = []
        for part in ("Plan", "Build", "Check"):
            child = new_card(slug, card_id(f"{card['id']}{part}"), f"{part}: {card['title']}", "ready",
                             assignee=card["assignee"] or "default")
            child["_ready_at"] = time.time()
            children.append(child)
        # The split card waits on every new card, and wakes when they're all done.
        card["_parents"].extend(child["id"] for child in children)
        card["_summary"] = f"Split into {len(children)} cards by Hermes."
        card["status"] = "todo"
    for child in children:
        emit(child, "created", {"status": "todo"})
    emit(card, "decomposed", {"children": [c["id"] for c in children]})
    return 200, {"ok": True, "task_id": card["id"], "reason": None, "fanout": True, "child_ids": [c["id"] for c in children],
                 "new_title": card["title"]}


def post_dispatch(query, body):
    slug = board_of(query)
    with LOCK:
        STATE["dispatch_now"].add(slug)
    return 200, {"spawned": [], "skipped": [], "reclaimed": []}


def get_sessions(previous):
    """`GET /api/sessions?source=kanban&cwd_prefix=`: a card's worker chat (Watch)."""
    def handler(query, body):
        if query.get("source", [None])[0] != "kanban":
            return previous(query, body) if previous else (200, {"sessions": [], "total": 0, "limit": 20, "offset": 0, "storage": {}})
        prefix = query.get("cwd_prefix", [""])[0]
        profile = query.get("profile", ["default"])[0] or "default"
        with B["LOCK"]:
            rows = [s for s in B["STORED"].values() if s.get("source") == "kanban" and s["profile"] == profile
                    and (s.get("cwd") or "").startswith(prefix)]
            rows.sort(key=lambda s: s["last_active"], reverse=True)
            out = [{"id": s["id"], "title": s["title"], "source": "kanban", "cwd": s.get("cwd"), "started_at": s["started_at"],
                    "last_active": s["last_active"], "message_count": len(s["messages"]), "profile": profile} for s in rows]
        limit = int(query.get("limit", ["20"])[0])
        return 200, {"sessions": out[:limit], "total": len(out), "limit": limit, "offset": 0, "storage": {}}
    return handler


# ---------------------------------------------------------------- mock controls


def mock_reset(query, body):
    seed()
    seed_worker_chats()
    return 200, {"ok": True}


def mock_config(query, body):
    with LOCK:
        for key in ("dispatcher", "socket"):
            if key in body:
                STATE[key] = bool(body[key])
    return 200, {"ok": True, "dispatcher": STATE["dispatcher"], "socket": STATE["socket"]}


def mock_act(query, body):
    with LOCK:
        card = CARDS.get(body.get("card") or "")
        if card is None:
            matches = [c for c in CARDS.values() if c["id"].endswith(body.get("card") or "~")]
            card = matches[0] if matches else None
        if card is None:
            return 404, {"detail": "no such card"}
        action = body.get("action")
        if action == "needs_input":
            reason = body.get("reason") or "Which one should I pick?"
            run_id = end_current_run(card, "blocked", summary=reason)
            if run_id is None:
                run_id = add_run(card, status="blocked", started=now() - 60, ended=now(), outcome="blocked", summary=reason)["id"]
            card.update(status="blocked", block_kind="needs_input", worker_pid=None)
            emit(card, "blocked", {"reason": reason, "kind": "needs_input", "recurrences": 1, "source_status": "running"}, run_id=run_id)
        elif action == "review":
            ok = bool(body.get("ok", True))
            run_id = end_current_run(card, "review_requested", summary=body.get("summary") or "Ready for review.")
            if run_id is None:
                run_id = add_run(card, status="done", started=now() - 600, ended=now(), outcome="review_requested",
                                 summary=body.get("summary") or "Ready for review.")["id"]
            card["status"] = "review"
            if body.get("reviewer"):
                card["assignee"] = body["reviewer"]
            emit(card, "review_requested", {"reviewer": card["assignee"]}, run_id=run_id)
            emit(card, "pr_acceptance", receipt(ok, () if ok else ("test (snapshots)",)), run_id=run_id)
            if not ok:
                card["last_failure_error"] = "PR acceptance failure: test (snapshots) failed on the PR's head."
        elif action == "gave_up":
            error = body.get("error") or "The build keeps failing."
            run_id = end_current_run(card, "gave_up", error=error)
            card.update(status="blocked", consecutive_failures=3, last_failure_error=error, worker_pid=None)
            emit(card, "gave_up", {"failures": 3, "effective_limit": 3, "error": error}, run_id=run_id)
        elif action == "complete":
            run_id = end_current_run(card, "done", summary=body.get("summary") or "Done.")
            card.update(status="done", completed_at=now())
            emit(card, "completed", {"summary": latest_summary(card)}, run_id=run_id)
        elif action == "stale":
            card["last_heartbeat_at"] = now() - 9 * 60
            emit(card, "status", {"status": card["status"], "requested_status": card["status"]})
        elif action == "heartbeat":
            beat(card)
        else:
            return 400, {"detail": f"unknown action {action!r}"}
    return 200, {"ok": True, "card": board_card(card)}


# ---------------------------------------------------------------- the pretend dispatcher


def beat(card, line=None):
    card["last_heartbeat_at"] = now()
    for run in reversed(RUNS.get(card["id"], [])):
        if run["ended_at"] is None:
            run["last_heartbeat_at"] = now()
            break
    if line:
        LOGS.setdefault(card["id"], []).append(line)
    emit(card, "heartbeat", None, run_id=card.get("current_run_id"))


def claim(card):
    card.update(status="running", started_at=card["started_at"] or now(), worker_pid=40000 + len(SIM))
    run = add_run(card, status="running", started=now(), beat=now(), summary=None)
    card["last_heartbeat_at"] = now()
    LOGS[card["id"]] = [f"Worker for {card['id']} started in {card.get('workspace_path') or 'a scratch folder'}"]
    SIM[card["id"]] = {"ends": time.time() + RUN_SECONDS, "beat": time.time()}
    emit(card, "claimed", {"lock": f"mock:{card['id']}"}, run_id=run["id"])
    emit(card, "spawned", {"pid": card["worker_pid"]}, run_id=run["id"])


def tick():
    steps = ["Reading the card and the project's AGENTS.md", "Planning the change", "Editing files",
             "Building for debugging…", "Running the tests", "Writing the summary"]
    while True:
        time.sleep(1)
        with LOCK:
            if not STATE["dispatcher"]:
                STATE["dispatch_now"].clear()
                continue
            t = time.time()
            for card in list(CARDS.values()):
                if card["status"] == "ready" and card["assignee"] and card["_ready_at"] is not None:
                    if card["_board"] in STATE["dispatch_now"] or t - card["_ready_at"] >= DISPATCH_DELAY:
                        card["_ready_at"] = None
                        claim(card)
            STATE["dispatch_now"].clear()
            for cid, sim in list(SIM.items()):
                card = CARDS.get(cid)
                if card is None or card["status"] != "running":
                    SIM.pop(cid, None)
                    continue
                if t >= sim["ends"]:
                    run_id = end_current_run(card, "done", summary=f"Finished “{card['title']}”: the change is in and the tests pass.")
                    card.update(status="done", completed_at=now(), worker_pid=None)
                    emit(card, "completed", {"summary": latest_summary(card)}, run_id=run_id)
                elif t - sim["beat"] >= 4:
                    sim["beat"] = t
                    done = int((t - (sim["ends"] - RUN_SECONDS)) / RUN_SECONDS * len(steps))
                    beat(card, steps[min(done, len(steps) - 1)])
            # The design's fresh run keeps being heard from.
            fresh = CARDS.get("t_4d90a91c")
            if fresh and fresh["status"] == "running" and cid_quiet(fresh, 15):
                beat(fresh)


def cid_quiet(card, seconds):
    return now() - (card.get("last_heartbeat_at") or 0) >= seconds


# ---------------------------------------------------------------- the event socket


def events_socket(handler, query):
    peer = B["accept_socket"](handler, query)
    if peer is None:
        return
    slug = board_of(query)
    if not STATE["socket"] or (slug != "default" and slug not in BOARDS):
        return peer.close(1008, "policy violation")
    since = query.get("since", [None])[0]
    with LOCK:
        events = EVENTS.get(slug, [])
        cursor = int(since) if since not in (None, "") else (events[-1]["id"] if events else 0)

    def reader():
        while peer.alive:
            if peer.recv() is None:
                peer.alive = False
    threading.Thread(target=reader, daemon=True).start()
    while peer.alive:
        time.sleep(0.3)
        if not STATE["socket"]:
            return peer.cut()
        with LOCK:
            fresh = [e for e in EVENTS.get(slug, []) if e["id"] > cursor][:200]
        if fresh:
            cursor = fresh[-1]["id"]
            peer.send({"events": fresh, "cursor": cursor})


# ---------------------------------------------------------------- install


def seed_worker_chats():
    """The running card's worker chat, so Watch has something to open."""
    if "STORED" not in B:
        return
    sid = "kanban_run_a91c"
    with B["LOCK"]:
        B["STORED"].pop(sid, None)
        B["add_session"]("default", "Fix the reconnect after sleep", hidden=True, source="kanban", started=time.time() - 6 * 60, sid=sid)
        B["STORED"][sid]["cwd"] = f"{APP_REPO}/.worktrees/t_4d90a91c"
    B["add_message"](sid, "user", "Work on t_4d90a91c: Fix the reconnect after sleep.", ts=time.time() - 6 * 60)
    B["add_message"](sid, "assistant", "Reproduced it: after sleep the socket keeps its old backoff. Running swift test now.",
                     ts=time.time() - 20)


def chat_turn(sid, text):
    """"Plan … as cards": Hermes adds three cards with `kanban_create` (`boardFromChat`)."""
    import json
    runtime = B["RUNTIME"][sid]
    if runtime.get("kind") == "chat":
        stored = runtime["stored"]
        G.add_message(stored, "user", text)
        tool = lambda name, args, result: C.tool(sid, stored, name, args, 0.5, context=args.get("title", ""), result=result)
        stream, finish = (lambda t: C.stream(sid, t)), (lambda t: C.finish(sid, stored, t))
    else:
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
        tool = lambda name, args, result: B["tool"](sid, stored, name, args, result, 0.5, args.get("title", ""))
        stream, finish = (lambda t: B["stream"](sid, t)), (lambda t: B["finish"](sid, stored, t))
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})
    time.sleep(0.3)
    made = []
    plan = [("Write the App Store listing", "writer", [], "Subtitle, description, keywords and what's new for 1.3."),
            ("Record the preview video", "default", [], "30 s, iPhone and Mac, from the TestFlight build."),
            ("Ship 1.3 to TestFlight", "default", [0, 1], "Archive, upload, write the notes for testers.")]
    for title, who, parents, body in plan:
        ids = [made[i] for i in parents]
        with LOCK:
            cid = card_id(f"{title}{time.time()}")
            card = new_card("hermes-app", cid, title, "ready", body=body, assignee=who, parents=ids, workspace_kind="scratch")
            card["session_id"] = stored
            if parents_open(card):
                card["status"] = "todo"
        emit(card, "created", {"assignee": who, "status": card["status"]})
        made.append(cid)
        args = {"title": title, "body": body, "assignee": who, "parents": ids}
        result = {"ok": True, "task_id": cid, "status": card["status"], "workspace_kind": "scratch", "workspace_path": None,
                  "project_id": "p_4f2a9c1e", "gated": card["status"] == "todo", "subscribed": False}
        if card["status"] == "todo":
            result["gated_by"] = ids[0]
        tool("kanban_create", args, json.dumps(result))
    answer = "Split it into three cards. The listing goes to Ada; TestFlight waits for the listing and the video."
    stream(answer)
    return finish(answer)


def install(backend_globals, gateway_module=None, chats_module=None):
    global B, G, C
    B, G, C = backend_globals, gateway_module, chats_module
    original_start = B.get("start_turn")
    if original_start:
        def start_turn(sid, text, runner):
            if " as cards" in (text or "").lower():
                return original_start(sid, text, chat_turn)
            return original_start(sid, text, runner)
        B["start_turn"] = start_turn
    routes = B["HTTP_ROUTES"]
    base = "/api/plugins/kanban"
    routes[("GET", f"{base}/workflow")] = get_workflow
    routes[("GET", f"{base}/boards")] = get_boards
    routes[("POST", f"{base}/boards")] = post_boards
    routes[("GET", f"{base}/board")] = get_board
    routes[("GET", f"{base}/assignees")] = get_assignees
    routes[("GET", f"{base}/orchestration")] = get_orchestration
    routes[("POST", f"{base}/tasks")] = post_card
    routes[("POST", f"{base}/tasks/bulk")] = post_bulk
    routes[("POST", f"{base}/estimate")] = post_estimate
    routes[("POST", f"{base}/dispatch")] = post_dispatch
    routes[("GET", "/api/sessions")] = get_sessions(routes.get(("GET", "/api/sessions")))
    routes[("POST", "/api/mock/kanban/reset")] = mock_reset
    routes[("POST", "/api/mock/kanban/config")] = mock_config
    routes[("POST", "/api/mock/kanban/act")] = mock_act
    patterns = B["PATTERN_ROUTES"]
    card = r"/api/plugins/kanban/tasks/(t_[0-9a-f]+)"
    patterns.append(("GET", re.compile(card), get_card))
    patterns.append(("PATCH", re.compile(card), patch_card))
    patterns.append(("DELETE", re.compile(card), delete_card))
    patterns.append(("GET", re.compile(card + "/log"), get_log))
    patterns.append(("POST", re.compile(card + "/comments"), post_comment))
    patterns.append(("POST", re.compile(card + "/reclaim"), post_reclaim))
    patterns.append(("POST", re.compile(card + "/reassign"), post_reassign))
    patterns.append(("POST", re.compile(card + "/specify"), post_specify))
    patterns.append(("POST", re.compile(card + "/decompose"), post_decompose))
    B["WS_ROUTES"][f"{base}/events"] = events_socket
    seed()
    seed_worker_chats()
    threading.Thread(target=tick, daemon=True).start()
