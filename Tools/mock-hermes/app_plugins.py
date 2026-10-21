"""The app's own Hermes plugins on the combined mock (docs/plugins.md §2): hermes-app-push and
hermes-app-widgets installed per profile, shaped like Hermes Agent's `plugins.manage` (tui_gateway/methods_tools.py,
hermes_cli/plugins_cmd_install.py) and `POST /api/gateway/restart` (hermes_cli/web_routers/actions.py).

Like the real gateway:
- `plugins.manage` takes an optional `profile`; one that doesn't exist answers 4064.
- `install {repo, ref, force, enable}` installs into that profile. A second install without `force`
  answers 5026 "Plugin '<name>' already exists…", and `ref` must be a full 40-character SHA; it pins
  the install (`pinned_sha`), and a pinned install only moves with a new `ref`.
- `list` rows carry the manifest's `version`, `source: git`, `status` and `pinned_sha`.
- `update` refuses git installs (4020): only catalog installs update over the protocol.
- `POST /api/gateway/restart` answers `{ok, pid, name: "gateway-restart"}`, and the gateway's
  `GET /health/detailed` reports the new pid from then on. `GET /api/actions/gateway-restart/status`
  follows it for about 5 s: `hermes gateway restart`'s log after its `=== gateway-restart started`
  header (the earlier restarts' lines before it), `running`, then `exit_code` 0.
- `/app-push` (push.py) answers 4018 while the root doesn't have hermes-app-push turned on.

Mock-only: `--app-plugins current|missing|partial|old|widened|off|failing` on backend.py picks the starting
state (`missing` with `--push-relay none`), and `POST /api/mock/app-plugins {state}` sets it again; its
answer counts the restarts so far. `POST /api/mock/restart {"fails": true}` makes the next restarts
exit 1 the way a gateway that can't take its port does. `failing` starts missing and every install fails the way a gateway
without network does (5026, the clone error).
"""

import re
import threading
import time

B = None  # backend.py globals
LOCK = threading.RLock()
SHA = re.compile(r"^[0-9a-fA-F]{40}$")
PUBLISHED = "75b06d277e8e274b6900e6d70fab4da7dfe9bf6e"

PUSH_HOOKS = ["pre_llm_call", "post_llm_call", "on_session_end", "pre_tool_call", "pre_approval_request",
              "post_approval_response", "on_human_input_request", "on_human_input_resolved", "on_room_member_activity",
              "kanban_task_completed", "kanban_task_blocked"]
APPS = {
    "hermes-app-push": {
        "repo": "vburojevic/hermes-app-push", "version": "1.4.5", "published": PUBLISHED,
        # What Hermes says it switched on (hermes_cli/plugins_activation.py): hooks and the command at once.
        "activation": {"activated_now": {"hooks": PUSH_HOOKS, "gateway_commands": ["app-push"]}, "deferred": {}, "live_now": {}},
        "description": "Push notifications for the Hermes iPhone, iPad and Mac app: approvals, questions, password "
                       "prompts, finished replies, scheduled tasks, background work and group chats.",
    },
    "hermes-app-widgets": {
        "repo": "vburojevic/hermes-app-widgets", "version": "1.2.2",
        "published": "7cbce1b0c249112feeff2a9c370b5c2169178654",
        "activation": {"activated_now": {"hooks": ["pre_llm_call", "subagent_start"],
                                         "gateway_transforms": ["transform_llm_output", "pre_gateway_dispatch"],
                                         "gateway_commands": ["app-widgets"]},
                       "deferred": {"tools": ["widget", "widget_examples"], "prompt": ["hermes-app-widgets"]},
                       "live_now": {"mcp_servers": [], "skills": [{"name": "hermes-app-widgets:widgets", "description": ""}]}},
        "description": "Widgets agents send to the Hermes app: cards for numbers, lists, schedules, statuses, "
                       "questions and approvals.",
    },
}
STATE = {"installed": {}, "restarts": 0, "mode": "current"}
# The restart running now (or last), and the earlier ones' lines, which the log file keeps.
RESTART = {"started": None, "log": [], "fails": False}
RESTART_SECONDS = 5
RESTART_LINES = [(0, "→ Draining 1 running chat (up to 600s)…"), (1.5, "  ✓ ai.hermes.gateway drained"),
                 (2, "→ Stopping ai.hermes.gateway"), (3, "→ Starting ai.hermes.gateway"),
                 (4.5, "  ✓ Listening on 127.0.0.1:8642"), (5, "✓ Gateway restarted")]
MODES = ("current", "missing", "partial", "old", "widened", "off", "failing")


# Older published versions (AppPlugin's capability lists): `old` keeps the same access, so the app
# updates quietly; `widened` has widgets 1.1.0, before 1.1.1 added pre_llm_call, so it asks first.
OLD = {"hermes-app-push": "1.1.0", "hermes-app-widgets": "1.1.1"}
WIDENED = {"hermes-app-widgets": "1.1.0"}


def seed(mode="current"):
    """`current`: every profile has it, installed by hand (unpinned). `missing` and `failing`: none
    has it. `partial`: Ada (writer) and Scout don't. `old`: every profile has the previous version,
    with the same access. `widened`: widgets is at 1.1.0 everywhere, whose pin adds a hook. `off`:
    every profile has it, and the root has hermes-app-push turned off."""
    profiles = list(B["PROFILES"])
    with LOCK:
        STATE["mode"] = mode
        STATE["installed"] = {p: {} for p in profiles}
        for profile in profiles:
            if mode in ("missing", "failing") or (mode == "partial" and profile in ("writer", "scout")):
                continue
            for name, app in APPS.items():
                off = mode == "off" and profile == "default" and name == "hermes-app-push"
                version = (OLD if mode == "old" else WIDENED if mode == "widened" else {}).get(name, app["version"])
                STATE["installed"][profile][name] = {"version": version,
                                                     "status": "not enabled" if off else "enabled", "pinned_sha": None,
                                                     "installed_sha": app["published"]}


def app_for(repo):
    repo = (repo or "").strip().lower().removesuffix(".git").removeprefix("https://github.com/").removeprefix("git@github.com:")
    return next((name for name, app in APPS.items() if app["repo"] == repo), None)


def row(name, entry):
    app = APPS[name]
    return {"name": name, "key": name, "version": entry["version"], "description": app["description"], "source": "git",
            "status": entry["status"], "portable": True, "install_dir": f"~/.hermes/plugins/{name}", "has_desktop_half": False,
            "catalog_name": None, "catalog_tier": None, "installed_sha": entry["installed_sha"], "catalog_sha": None,
            "catalog_version": None, "update_available": False, "pinned_sha": entry["pinned_sha"], "servers": [],
            "settings_schema": []}


def installed(name, profile="default"):
    """Whether `name` is installed and on in `profile` (push.py asks before answering /app-push)."""
    with LOCK:
        entry = STATE["installed"].get(profile, {}).get(name)
        return bool(entry and entry["status"] == "enabled")


def install(backend_globals, mode="current", gateway_module=None):
    global B
    B = backend_globals
    seed(mode)
    original = B["METHODS"]["plugins.manage"]
    error = B["RPCError"]

    def profile_of(params):
        profile = str(params.get("profile") or "").strip() or "default"
        if profile not in B["PROFILES"]:
            raise error(4064, f"profile '{profile}' not found")
        with LOCK:
            STATE["installed"].setdefault(profile, {})  # a Bot made since the seed
        return profile

    def manage(params):
        action = params.get("action") or "list"
        profile = profile_of(params)
        with LOCK:
            mine = STATE["installed"][profile]
            if action == "list":
                result = dict(original(params))
                rows = [r for r in result.get("plugins", []) if r.get("key") not in APPS]
                rows += [row(name, entry) for name, entry in mine.items()]
                return {**result, "plugins": rows, "user_count": sum(r["source"] != "bundled" for r in rows)}
            if action == "install" and app_for(params.get("repo") or params.get("identifier")):
                name = app_for(params.get("repo") or params.get("identifier"))
                ref = str(params.get("ref") or "").strip() or None
                if ref is not None and not SHA.match(ref):
                    raise error(5026, "--ref must be a full 40-character commit SHA.")
                existing = mine.get(name)
                if existing and not params.get("force"):
                    raise error(5026, f"Plugin '{name}' already exists. Use force reinstall or run `hermes plugins update {name}`.")
                if existing and existing["pinned_sha"] and ref is None:
                    raise error(5026, f"Plugin '{name}' is pinned. Reinstall it with an explicit --ref <40-character commit SHA> "
                                      "to change its source or revision.")
            elif action in ("toggle", "remove", "update") and (params.get("key") or params.get("name")) in APPS:
                name = params.get("key") or params.get("name")
                if name not in mine:
                    raise error(4020, f"plugin '{name}' not found")
                if action == "update":
                    raise error(4020, f"'{name}' is not a catalog install — update it via the CLI")
                if action == "remove":
                    del mine[name]
                    return {"ok": True, "name": name}
                mine[name]["status"] = "enabled" if params.get("enable") else "not enabled"
                return {"ok": True, "unchanged": False, "restart_required": False, "gateway_reloaded": True, "name": name,
                        "plugin": row(name, mine[name]), "activation": None}
            else:
                return original(params)
        time.sleep(0.8)  # the clone
        if STATE["mode"] == "failing":
            raise error(5026, f"Could not download the plugin from https://github.com/{APPS[name]['repo']}.git. Check the address "
                              "(browse the catalog with `hermes plugins search`), check your internet connection, or, if the "
                              "repository is private, sign in first with `gh auth login` (or set GITHUB_TOKEN in your .env).\n"
                              "Details: git clone failed: Could not resolve host: github.com")
        with LOCK:
            enabled = params.get("enable", True) is not False
            STATE["installed"][profile][name] = {"version": APPS[name]["version"], "status": "enabled" if enabled else "not enabled",
                                                 "pinned_sha": ref.lower() if ref else None, "installed_sha": (ref or APPS[name]["published"]).lower()}
            entry = STATE["installed"][profile][name]
        print(f"[mock-backend] installed {name} in {profile}{' (replaced)' if params.get('force') else ''}", flush=True)
        return {"ok": True, "name": name, "plugin_name": name, "plugin": row(name, entry), "enabled": enabled,
                "warnings": ["Custom (unreviewed) source — not from the Hermes catalog."], "missing_env": [],
                "known_issues": [], "python_dependencies": [], "restart_required": False, "gateway_reloaded": True,
                "activation": ({"name": name, "key": name, **APPS[name]["activation"]} if enabled else None)}

    def restart(query, body):
        with LOCK:
            # Requests within a run join it, as `_spawn_gateway_restart` reuses one in flight.
            if RESTART["started"] and time.time() - RESTART["started"] < RESTART_SECONDS:
                return 200, {"ok": True, "pid": 40000 + STATE["restarts"], "name": "gateway-restart"}
            STATE["restarts"] += 1
            count = STATE["restarts"]
            if RESTART["started"]:
                RESTART["log"] += restart_lines(RESTART_SECONDS)
            RESTART["started"] = time.time()
            # `hermes gateway restart` writes the gateway's plist again without ProcessType (push.py).
            if not RESTART["fails"] and B.get("MOCK_RESET_PRIORITY"):
                B["MOCK_RESET_PRIORITY"](RESTART["started"] + RESTART_SECONDS)
        if gateway_module is not None:
            gateway_module.RUNTIME["pid"] = 40000 + count  # the restarted gateway is a new process
        print("[mock-backend] gateway restart", flush=True)
        return 200, {"ok": True, "pid": 40000 + count, "name": "gateway-restart"}

    def restart_lines(elapsed):
        lines = [f"=== gateway-restart started {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(RESTART['started']))} ==="]
        lines += [line for at, line in RESTART_LINES if elapsed >= at]
        if RESTART["fails"] and elapsed >= RESTART_SECONDS:
            lines = [line for line in lines if "Gateway restarted" not in line and "Listening" not in line]
            lines.append("✗ ai.hermes.gateway didn't start: port 8642 is in use by another process")
        return lines

    def restart_status(query, body):
        with LOCK:
            if not RESTART["started"]:
                return 200, {"name": "gateway-restart", "running": False, "exit_code": None, "pid": None, "lines": []}
            elapsed = time.time() - RESTART["started"]
            lines = RESTART["log"] + restart_lines(elapsed)
            try:
                count = min(max(int((query.get("lines") or ["200"])[0]), 1), 2000)
            except ValueError:
                count = 200
            running = elapsed < RESTART_SECONDS
            return 200, {"name": "gateway-restart", "running": running,
                         "exit_code": None if running else (1 if RESTART["fails"] else 0),
                         "pid": 40000 + STATE["restarts"], "lines": lines[-count:]}

    def mock_restart(query, body):
        RESTART["fails"] = bool((body or {}).get("fails"))
        return 200, {"ok": True, "fails": RESTART["fails"]}

    def mock_state(query, body):
        mode = (body or {}).get("state") or "current"
        if mode not in MODES:
            return 400, {"detail": "state is one of " + ", ".join(MODES)}
        seed(mode)
        return 200, {"ok": True, "state": mode, "restarts": STATE["restarts"]}

    B["METHODS"]["plugins.manage"] = manage
    B["HTTP_ROUTES"][("POST", "/api/gateway/restart")] = restart
    B["HTTP_ROUTES"][("GET", "/api/actions/gateway-restart/status")] = restart_status
    B["HTTP_ROUTES"][("POST", "/api/mock/restart")] = mock_restart
    B["HTTP_ROUTES"][("POST", "/api/mock/app-plugins")] = mock_state
    B["APP_PLUGIN_INSTALLED"] = installed
