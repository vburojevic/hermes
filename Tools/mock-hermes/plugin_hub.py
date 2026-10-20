"""Hermes's plugin catalog on the combined mock (docs/plugins.md §3–§7): the public catalog feed, the
gateway's view of it, and installed plugins in every state the hub shows. Shaped like Hermes Agent
0.22.2 (`hermes_cli/plugin_catalog*.py`, `plugins_cmd_install.py`, `tui_gateway/methods_tools.py`).

- `GET /docs/api/plugin-catalog.json` serves `plugin-catalog.json` (the feed the app reads for display;
  point a Debug build at it with `-HERMES_PLUGIN_CATALOG_URL`). `--plugin-catalog none` answers 404,
  so the app falls back to what it cached.
- `GET /api/system/stats`: the gateway's OS, hostname and Hermes version.
- `plugins.manage onboarding`: the feed's `onboarding` entries for this OS, not installed, with
  `app_state` (Blender, Figma and TouchDesigner present; Obsidian missing).
- `plugins.manage presence {names}`: state, sentence and the catalog's disclosure, in the order asked.
- `plugins.manage install {catalog_name}`: any feed entry. Refused like Hermes (5026): a pulled name
  (the kill list), another OS, a newer Hermes, or (with `failing`) a clone that can't reach GitHub.
  `missing_env` lists the entry's `requires_env` keys that aren't set; an install into a Bot's profile
  is recorded for that profile.
- `reload.env`: no params (any is 4000), `{updated}`.
- Installed for the hub: DaVinci Resolve (its app isn't running), Obsidian Memory (off), Langfuse (two
  keys missing) and agent-ledger (pulled from the catalog: it loads nothing, Hermes's toggle still says
  ok).

Mock-only: `POST /api/mock/plugin-hub {failing: bool, feed: bool, reset: bool}` (`reset` removes catalog
installs made since the start, and their keys).
"""

import copy
import json
import pathlib
import threading
import time

B = None
C = None  # connections.py
LOCK = threading.RLock()
HERE = pathlib.Path(__file__).resolve().parent
FEED = json.loads((HERE / "plugin-catalog.json").read_text())
STATE = {"failing": False, "feed": True, "profiles": {}}
OS = "Darwin"
HERMES_VERSION = "0.22.2"
PRESENT = {"blender", "xcode", "figma-desktop", "touchdesigner"}
MISSING_APP = {"obsidian": "Obsidian isn't installed on Studio Mac"}


def entry(name):
    return next((e for e in FEED["entries"] if e["name"] == name), None)


def runs_here(e):
    platforms = [p.lower() for p in e.get("platforms") or []]
    return not platforms or "macos" in platforms


def disclosure(e):
    text = e.get("description") or ""
    for marker in ("Disclosure —", "Disclosure:"):
        if marker in text:
            rest = text.split(marker, 1)[1].strip()
            return rest.split(". ", 1)[0].rstrip(".") + "."
    return ""


def app_state(name):
    if name in MISSING_APP:
        return "missing_app", MISSING_APP[name]
    return ("present", "") if name in PRESENT else ("unknown", "")


def version_tuple(text):
    return tuple(int(p) for p in text.split(".") if p.isdigit())


def seed_installed():
    """The hub's installed rows (pluginsHubMore)."""
    def plugin(key, title, tier, version, description, **extra):
        e = entry(key) or {}
        base = {"name": title, "key": key, "version": version, "description": description, "source": "user", "status": "enabled",
                "portable": True, "install_dir": f"~/.hermes/plugins/{key}", "has_desktop_half": False, "servers": [],
                "catalog_name": key, "catalog_tier": tier, "installed_sha": e.get("sha", "f" * 40), "catalog_sha": e.get("sha"),
                "catalog_version": e.get("version"), "update_available": False, "pinned_sha": e.get("sha", "f" * 40),
                "settings": {}, "schema": [], "tools": [], "skills": []}
        base.update(extra)
        return base
    rows = [
        plugin("davinci-resolve", "DaVinci Resolve", "community", "1.1", "Edit timelines in DaVinci Resolve.",
               servers=[{"name": "davinci-resolve", "state": "app_not_running", "sentence": "DaVinci Resolve isn't running on Studio Mac"}],
               tools=[f"resolve_{i}" for i in range(14)]),
        plugin("obsidian-memory", "Obsidian Memory", "community", "0.6", "Notes from your vault.", status="not enabled"),
        plugin("langfuse", "Langfuse", "official", "2.0", "Traces every turn.",
               schema=[{"key": "public_key", "type": "secret", "label": "Public key", "description": "", "required": True,
                        "env": "HERMES_LANGFUSE_PUBLIC_KEY"},
                       {"key": "secret_key", "type": "secret", "label": "Secret key", "description": "", "required": True,
                        "env": "HERMES_LANGFUSE_SECRET_KEY"}]),
        # Pulled: no longer in the feed's entries, so no catalog_sha; it's on the kill list.
        plugin("agent-ledger", "agent-ledger", "community", "1.1", "A ledger of every turn.", status="not enabled",
               catalog_sha=None, catalog_version=None, installed_sha="0" * 40, pinned_sha="0" * 40),
    ]
    with C.LOCK:
        keys = {p["key"] for p in C.STATE["plugins"]}
        C.STATE["plugins"] += [r for r in rows if r["key"] not in keys]


def install(backend_globals, connections, feed=True):
    global B, C
    B, C = backend_globals, connections
    STATE["feed"] = feed
    seed_installed()
    original = B["METHODS"]["plugins.manage"]
    error = B["RPCError"]

    def manage(params):
        action = params.get("action") or "list"
        profile = str(params.get("profile") or "").strip() or "default"
        if profile not in B["PROFILES"]:
            raise error(4064, f"profile '{profile}' not found")
        if action == "onboarding":
            installed = {p["catalog_name"] for p in C.STATE["plugins"]}
            rows = []
            for e in FEED["entries"]:
                if not e.get("onboarding") or not runs_here(e) or e["name"] in installed:
                    continue
                state, sentence = app_state(e["name"])
                rows.append({"name": e["name"], "title": e.get("title") or e["name"],
                             "description": (e.get("description") or "").split(". ")[0].rstrip(".") + ".",
                             "tier": e.get("tier", "community"), "platforms": e.get("platforms") or [],
                             "app_state": state, "sentence": sentence})
            return {"onboarding": rows}
        if action == "presence":
            rows = []
            for name in params.get("names") or []:
                e = entry(name)
                if e is None or not runs_here(e):
                    continue
                state, sentence = app_state(name)
                rows.append({"name": name, "title": e.get("title") or name, "state": state, "sentence": sentence,
                             "disclosure": disclosure(e)})
            return {"presence": rows}
        if action == "install" and params.get("catalog_name"):
            return install_catalog(params["catalog_name"], profile, params.get("enable", True) is not False, error)
        return original(params)

    def install_catalog(name, profile, enable, error):
        time.sleep(0.9)  # the clone and the scan
        removed = next((r for r in FEED["removed"] if r["name"] == name), None)
        if removed:
            raise error(5026, f"Plugin '{name}' was removed from the Hermes plugin catalog and is blocked from installation: "
                              f"{removed['reason']} (removed {removed['date']})")
        e = entry(name)
        if e is None:
            raise error(5026, f"'{name}' is not in the Hermes plugin catalog.")
        if not runs_here(e):
            raise error(5026, f"Plugin '{name}' is unavailable on darwin; supported platforms: {', '.join(e['platforms'])}.")
        spec = e.get("requires_hermes") or ""
        if spec.startswith(">=") and version_tuple(HERMES_VERSION) < version_tuple(spec[2:]):
            raise error(5026, f"Plugin '{name}' requires hermes {spec}, running {HERMES_VERSION} Run hermes update to update Hermes.")
        if STATE["failing"]:
            raise error(5026, f"Could not download the plugin from {e['repo']}.git. Check the address (browse the catalog with "
                              "`hermes plugins search`), check your internet connection, or, if the repository is private, sign "
                              "in first with `gh auth login` (or set GITHUB_TOKEN in your .env).\nDetails: git clone failed: "
                              "Could not resolve host: github.com")
        capabilities = e.get("capabilities") or {}
        env = capabilities.get("requires_env") or []
        with C.LOCK:
            done = STATE["profiles"].setdefault(profile, set())
            if profile == "default":
                if any(p["key"] == name for p in C.STATE["plugins"]):
                    raise error(5026, f"Plugin '{name}' already exists. Use force reinstall or run `hermes plugins update {name}`.")
                state, sentence = app_state(name)
                C.STATE["plugins"].append({
                    "name": e.get("title") or name, "key": name, "version": e.get("version") or "1.0",
                    "description": (e.get("description") or "").split(". ")[0], "source": "user",
                    "status": "enabled" if enable else "not enabled", "portable": True, "install_dir": f"~/.hermes/plugins/{name}",
                    "has_desktop_half": False,
                    "servers": [{"name": name, "state": "connected" if state != "missing_app" else state, "sentence": sentence}]
                    if capabilities.get("provides_tools") else [],
                    "catalog_name": name, "catalog_tier": e.get("tier", "community"), "installed_sha": e["sha"],
                    "catalog_sha": e["sha"], "catalog_version": e.get("version"), "update_available": False, "pinned_sha": e["sha"],
                    "settings": {}, "tools": list(capabilities.get("provides_tools") or []), "skills": [],
                    "schema": [{"key": k.lower(), "type": "secret", "label": k.replace("_", " ").title(), "description": "",
                                "required": True, "env": k} for k in env]})
            elif name in done:
                raise error(5026, f"Plugin '{name}' already exists. Use force reinstall or run `hermes plugins update {name}`.")
            done.add(name)
            missing = [k for k in env if not C.STATE["env"].get(k)]
        print(f"[mock-backend] installed catalog plugin {name} in {profile}", flush=True)
        hooks = capabilities.get("provides_hooks") or []
        tools = capabilities.get("provides_tools") or []
        warnings = [f"Known issue: {issue}" for issue in e.get("known_issues") or []]
        return {"ok": True, "plugin_name": e.get("title") or name, "warnings": warnings, "python_dependencies": [],
                "missing_env": missing, "after_install_path": None, "enabled": enable, "gateway_reloaded": enable,
                "restart_required": False, "known_issues": e.get("known_issues") or [],
                "activation": {"name": name, "key": name,
                               **({"activated_now": {"hooks": hooks}} if hooks else {"activated_now": {}}),
                               "deferred": {},
                               "live_now": {"mcp_servers": [{"name": name, "connected": True, "tools": tools}] if tools else [],
                                            "skills": []}} if enable else None}

    def reload_env(params):
        if params:
            raise error(4000, "invalid params for reload.env: " + ", ".join(params) + ": Extra inputs are not permitted")
        return {"updated": 0}

    def feed_route(query):
        if not STATE["feed"]:
            return 404, "application/json", b'{"detail": "Not Found"}'
        return 200, "application/json", json.dumps(FEED).encode()

    def system_stats(query, body):
        return 200, {"os": OS, "os_release": "25.0.0", "os_version": "", "platform": "macOS-27.0-arm64", "arch": "arm64",
                     "hostname": "studio-mac.local", "python_version": "3.12.8", "python_impl": "CPython",
                     "hermes_version": HERMES_VERSION, "cpu_count": 12}

    def mock_hub(query, body):
        body = body or {}
        if body.get("reset"):
            # Catalog installs since the start go again, with the keys they asked for.
            with C.LOCK:
                seeded = {"xcode", "blender", "homeassistant", "davinci-resolve", "obsidian-memory", "langfuse", "agent-ledger"}
                C.STATE["plugins"] = [p for p in C.STATE["plugins"] if p["key"] in seeded or entry(p["key"]) is None]
                for e in FEED["entries"]:
                    for key in (e.get("capabilities") or {}).get("requires_env") or []:
                        if e["name"] not in seeded:
                            C.STATE["env"].pop(key, None)
                STATE["profiles"] = {}
            STATE["failing"] = False
            STATE["feed"] = True
        if "failing" in body:
            STATE["failing"] = bool(body["failing"])
        if "feed" in body:
            STATE["feed"] = bool(body["feed"])
        return 200, {"ok": True, **{k: STATE[k] for k in ("failing", "feed")}}

    B["METHODS"]["plugins.manage"] = manage
    B["METHODS"]["reload.env"] = reload_env
    B["PUBLIC_ROUTES"]["/docs/api/plugin-catalog.json"] = feed_route
    B["HTTP_ROUTES"][("GET", "/api/system/stats")] = system_stats
    B["HTTP_ROUTES"][("POST", "/api/mock/plugin-hub")] = mock_hub
