"""Setup states (docs/setup.md §5): a gateway with features turned off or missing, shaped like
Hermes's answers, so each "not set up" state in Settings → Setup can be seen and fixed.

- GET/PUT /api/config: `checkpoints`, `terminal.backend`, `curator.enabled`,
  `dashboard.turn_isolation` and `plugins.disabled`, merged with whatever else serves the config
  (checkpoints.py, memory.py, audio.py). A PUT deep-merges like Hermes: objects merge, lists replace.
- GET /api/hermes/update/check: `behind`, `can_apply`, `update_command`, like
  hermes_cli/web_routers/actions.py.
- POST /api/hermes/update and GET /api/actions/hermes-update/status: `hermes update` runs for
  about 9 s, its log growing like the real one (an earlier run first, step lines, indented details,
  colour codes, a progress line redrawn with \r; `lines=N` tails it), the dashboard "restarting"
  (502) for 2 s of it, then exits with a receipt carrying the start's `action_id`. A good run moves
  the version to 0.22.0.
- /api/status: `gateway_running` and `fts_rebuild` (backend.py merges `STATUS_EXTRA`).
- /api/plugins/kanban/*: 404 {"detail": "Plugin not found"} while `kanban` is in plugins.disabled
  (web_server.py), or 404 "Not Found" for an older Hermes without it.
- GET /api/curator: `enabled` follows `curator.enabled`; POST /api/curator/run refuses while off
  with Hermes's words.
- groups.capabilities: `driver: false` when the room service didn't start.
- GET /api/memory: the active provider can be one that isn't set up (`needs_config`).
- connectors.list: `available: false` while `tools.connectors.enabled` is off, or while signed in
  to Nous without apps in the plan.
- /api/jobs: the morning briefing's results didn't arrive (`last_status: delivery_failed`,
  `last_delivery_error`), or its last scheduled run didn't start (`last_fire_error`), like
  cron/jobs.py.

Mock-only: `--setup <state>[,<state>…]` starts in those states; `POST /api/mock/setup
{"states": [...]}` sets them while running ("ready" clears them). States: board-off, board-missing,
tidying-off, tidying-paused, turn-isolation, no-driver, gateway-stopped, update, docker,
memory-provider, search-index, delivery-failed, missed-run, apps-off, apps-not-included,
update-fails (exit 1 on a merge conflict), update-owes (a partial run: a plugin to reinstall),
update-refused (Hermes runs from the desktop app bundle), update-slow (the same run over 36 s, for
screenshots under load). The update-* states imply `update`.
throttled (macOS runs the gateway and dashboard as background jobs; `/app-push host`, push.py),
throttled-here (the same on this very Mac: the report carries this Mac's machine id and plists in
build/mock-launch-agents, so the Mac app's Run at Full Priority edits those with
`-HERMES_LAUNCH_AGENTS_DIR`), host-linux, push-old (a push plugin older than `host`).
"""

import copy
import pathlib
import secrets
import shutil
import threading
import time

B = None
G = None
LOCK = threading.Lock()

STATES = set()
ALL_STATES = {"board-off", "board-missing", "tidying-off", "tidying-paused", "turn-isolation", "no-driver",
              "gateway-stopped", "update", "docker", "memory-provider", "search-index", "delivery-failed", "missed-run",
              "apps-off", "apps-not-included", "update-fails", "update-owes", "update-refused", "update-slow",
              "throttled", "throttled-here", "host-linux", "push-old"}
BRIEF = {}  # the morning briefing as seeded, to put back

# What a PUT changed, over the states' defaults.
CONFIG = {}

# throttled-here's LaunchAgents, for the Mac app's -HERMES_LAUNCH_AGENTS_DIR.
MOCK_AGENTS = pathlib.Path(__file__).resolve().parent.parent.parent / "build" / "mock-launch-agents"

# The update the app started: its id, when, and the version it left.
UPDATE = {"action_id": None, "started": None, "version": "0.21.6"}
# What `hermes update` prints into ~/.hermes/logs/hermes-update.log, by second: step lines,
# indented details, colour codes and a progress line redrawn with \r, like the real log. The file
# keeps every run, so an earlier one comes first.
EARLIER_UPDATE = ["=== hermes-update started 2026-10-17 09:12:03 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f ===",
                  "→ Fetching updates…", "✓ Already up to date.", ""]
UPDATE_LINES = [(0, "☤ Update available: 12 commits behind origin/main"), (0.5, "→ Fetching updates…"),
                (1.5, "→ Pulling 12 commits from origin/main"), (2, "  ✓ Fast-forwarded a1b2c3d..e4f5a6b"),
                (3, "→ Updating Python dependencies"),
                (3.5, "  Resolved 84 packages\r  Downloaded 12 of 84\r  Installed 84 packages"),
                (4.5, "\x1b[32m  ✓ Dependencies up to date\x1b[0m"), (5, "→ Reinstalling plugins (2)"),
                (5.5, "  ✓ hermes-app-push 1.3.0"), (5.8, "→ Restarting gateways"),
                (6, "  → ai.hermes.gateway: draining (up to 600s)..."),
                (8, "  ✓ Restarted ai.hermes.gateway"), (8.5, "✓ Hermes Agent 0.22.0")]
UPDATE_SECONDS = 9


def tail(lines, query):
    """The route's `lines=N` (1 to 2000, 200 by default): the log's last N lines."""
    try:
        count = min(max(int((query.get("lines") or ["200"])[0]), 1), 2000)
    except ValueError:
        count = 200
    return lines[-count:]


def deep_merge(base, override):
    result = dict(base)
    for key, value in override.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        elif not (isinstance(result.get(key), dict) and value is None):
            result[key] = value
    return result


def config_section():
    """The parts of config.yaml this module owns, as the states set them and PUTs changed them."""
    base = {
        "terminal": {"backend": "docker" if "docker" in STATES else "local"},
        "curator": {"enabled": "tidying-off" not in STATES},
        "dashboard": {"turn_isolation": "turn-isolation" in STATES},
        "plugins": {"disabled": ["kanban"] if "board-off" in STATES else []},
        "tools": {"connectors": {"enabled": "apps-off" not in STATES}},
    }
    return deep_merge(base, CONFIG)


def kanban_off():
    return "kanban" in config_section()["plugins"]["disabled"]


def set_states(states):
    with LOCK:
        STATES.clear()
        STATES.update(s for s in states if s in ALL_STATES)
        CONFIG.clear()
        UPDATE.update(action_id=None, started=None, version="0.21.6")
        # Run at Full Priority's plists start over (push.py writes them again when asked).
        shutil.rmtree(MOCK_AGENTS, ignore_errors=True)
        B["STATUS_EXTRA"].pop("version", None)
        if "tidying-paused" in STATES:
            set_curator_paused(True)
        refresh_status()
        refresh_jobs()


def refresh_jobs():
    job = getattr(G, "JOBS", {}).get("job_brief")
    if job is None:
        return
    if not BRIEF:
        BRIEF.update(job)
    job.clear()
    job.update(BRIEF)
    if "delivery-failed" in STATES:
        job["last_status"] = "delivery_failed"
        job["last_delivery_error"] = "telegram: no home channel set. Send /sethome in the chat Hermes should post to."
    if "missed-run" in STATES:
        job["last_fire_error"] = {"at": "2026-10-18T07:30:01+02:00", "detail": "scheduler fire could not reach the runner (connection refused)"}


def refresh_status():
    extra = B["STATUS_EXTRA"]
    extra["gateway_running"] = "gateway-stopped" not in STATES
    if "search-index" in STATES:
        extra["fts_rebuild"] = {"pending": 1200, "total": 4000, "indexed": 2800, "percent": 70}
    else:
        extra.pop("fts_rebuild", None)


def set_curator_paused(paused):
    learned = B.get("MOCK_LEARNED")
    if learned is not None:
        for state in learned.CURATOR.values():
            state["paused"] = paused


def install(backend_globals, gateway_module, states=()):
    global B, G
    B, G = backend_globals, gateway_module
    routes = B["HTTP_ROUTES"]
    B["MOCK_SETUP_STATES"] = STATES  # push.py's `/app-push host` reads them

    previous_get, previous_put = routes.get(("GET", "/api/config")), routes.get(("PUT", "/api/config"))

    def get_config(query, body):
        status, config = previous_get(query, body) if previous_get else (200, {})
        if status != 200:
            return status, config
        with LOCK:
            return 200, deep_merge(config, config_section())

    def put_config(query, body):
        incoming = (body or {}).get("config") or {}
        owned = {key: incoming[key] for key in ("terminal", "curator", "dashboard", "plugins", "tools") if key in incoming}
        with LOCK:
            CONFIG.update(deep_merge(CONFIG, owned))
        rest = {key: value for key, value in incoming.items() if key not in owned}
        if previous_put and rest:
            return previous_put(query, {**(body or {}), "config": rest})
        return 200, {"ok": True}

    routes[("GET", "/api/config")] = get_config
    routes[("PUT", "/api/config")] = put_config

    def pace():
        return 4 if "update-slow" in STATES else 1

    def update_wanted():
        return UPDATE["version"] == "0.21.6" and any(state.startswith("update") for state in STATES)

    def update_check(query, body):
        behind = 12 if update_wanted() else 0
        return 200, {"install_method": "git", "current_version": UPDATE["version"], "behind": behind,
                     "update_available": behind > 0, "can_apply": True, "update_command": "hermes update",
                     "message": None if behind else "You're on the latest version."}

    def update_start(query, body):
        if "update-refused" in STATES:
            return 200, {"ok": False, "pid": None, "name": "hermes-update", "error": "update_not_in_place",
                         "message": "✗ This Hermes runs from inside the desktop app bundle.\n\n"
                                    "Manage updates from within the desktop app.\n"
                                    "Prefer a self-managed source install? See:\n"
                                    "  https://hermes-agent.nousresearch.com/docs/user-guide/switching-to-source",
                         "update_command": "Manage updates from within the desktop app"}
        with LOCK:
            if UPDATE["started"] and time.time() - UPDATE["started"] < UPDATE_SECONDS * pace():
                return 200, {"ok": True, "pid": 4242, "name": "hermes-update", "already_running": True,
                             "action_id": UPDATE["action_id"]}
            UPDATE.update(action_id=secrets.token_hex(16), started=time.time())
            return 200, {"ok": True, "pid": 4242, "name": "hermes-update", "action_id": UPDATE["action_id"]}

    def update_status(query, body):
        with LOCK:
            started, action_id = UPDATE["started"], UPDATE["action_id"]
            if started is None:
                return 200, {"name": "hermes-update", "running": False, "exit_code": None, "pid": None, "lines": []}
            # update-slow runs the same timeline 4 times slower, for screenshots under load.
            elapsed = (time.time() - started) / pace()
            if 6 <= elapsed < 8:
                return 502, {"detail": "Bad Gateway"}
            lines = EARLIER_UPDATE + [f"=== hermes-update started 2026-10-18 21:00:00 {action_id} ==="]
            lines += [line for at, line in UPDATE_LINES if elapsed >= at]
            if "update-fails" in STATES:
                lines = [line for line in lines if "Restart" not in line and "draining" not in line and "0.22.0" not in line]
            if elapsed < UPDATE_SECONDS:
                return 200, {"name": "hermes-update", "running": True, "exit_code": None, "pid": 4242,
                             "lines": tail(lines, query)}
            receipt = {"outcome": "success", "action_id": action_id, "started_at": started, "finished_at": started + UPDATE_SECONDS,
                       "pre_sha": "a1b2c3d", "post_sha": "e4f5a6b", "post_version": "0.22.0", "fleet_states": ["restarted"],
                       "followups": [], "user_action": None}
            exit_code = 0
            if "update-fails" in STATES:
                lines.append("✗ Merge conflict between local commits and upstream — update stopped, nothing was changed.")
                lines.append("  Resolve manually: cd ~/.hermes/hermes-agent && git merge origin/main")
                receipt.update(outcome="failed", post_sha=None, post_version=None)
                exit_code = 1
            elif "update-owes" in STATES:
                receipt.update(outcome="partial", followups=[{"step": "plugins", "reason": "hermes-app-push didn't reinstall"}])
                exit_code = 1
            else:
                lines.append(f"=== hermes-update completed {action_id} ===")
            if receipt["post_version"]:
                UPDATE["version"] = receipt["post_version"]
                B["STATUS_EXTRA"]["version"] = receipt["post_version"]
            return 200, {"name": "hermes-update", "running": False, "exit_code": exit_code, "pid": 4242,
                         "lines": tail(lines, query), "action_id": action_id if exit_code == 0 else None, "receipt": receipt}

    routes[("GET", "/api/hermes/update/check")] = update_check
    routes[("POST", "/api/hermes/update")] = update_start
    routes[("GET", "/api/actions/hermes-update/status")] = update_status

    # The Board's routes: refused while the plugin is off, missing on an "older Hermes".
    for key in [key for key in routes if key[1].startswith("/api/plugins/kanban/")]:
        handler = routes[key]

        def guarded(query, body, handler=handler):
            if "board-missing" in STATES:
                return 404, {"detail": "Not Found"}
            if kanban_off():
                return 404, {"detail": "Plugin not found"}
            return handler(query, body)

        routes[key] = guarded

    curator_status = routes.get(("GET", "/api/curator"))
    curator_run = routes.get(("POST", "/api/curator/run"))

    def curator(query, body):
        status, payload = curator_status(query, body)
        payload = dict(payload)
        payload["enabled"] = config_section()["curator"]["enabled"]
        return status, payload

    def run(query, body):
        if not config_section()["curator"]["enabled"]:
            return 409, {"detail": "curator: disabled via config; enable with `curator.enabled: true`"}
        return curator_run(query, body)

    if curator_status:
        routes[("GET", "/api/curator")] = curator
    if curator_run:
        routes[("POST", "/api/curator/run")] = run

    memory_status = routes.get(("GET", "/api/memory"))

    def memory(query, body):
        status, payload = memory_status(query, body)
        if "memory-provider" in STATES and status == 200:
            payload = copy.deepcopy(payload)
            payload["active"] = "honcho"
            for provider in payload.get("providers", []):
                if provider.get("name") == "honcho":
                    provider["status"] = "needs_config"
        return status, payload

    if memory_status:
        routes[("GET", "/api/memory")] = memory

    methods = B["METHODS"]
    capabilities = methods.get("groups.capabilities")

    def groups_capabilities(params):
        answer = dict(capabilities(params))
        if "no-driver" in STATES:
            answer["driver"] = False
        return answer

    if capabilities:
        methods["groups.capabilities"] = groups_capabilities

    # Apps: off in config, or signed in to Nous without them in the plan (tools/connectors).
    connectors = methods.get("connectors.list")

    def connectors_list(params):
        apps_on = config_section()["tools"]["connectors"]["enabled"]
        if not apps_on or "apps-not-included" in STATES:
            return {"available": False, "connectors": []}
        return connectors(params)

    if connectors:
        methods["connectors.list"] = connectors_list

    def mock_control(query, body):
        states = (body or {}).get("states") or []
        set_states([] if states == ["ready"] else states)
        return 200, {"ok": True, "states": sorted(STATES)}

    routes[("POST", "/api/mock/setup")] = mock_control
    set_states(states)
