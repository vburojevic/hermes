"""Where Hermes browses, for the combined mock (`docs/web.md` §5), shaped like Hermes Agent's
`tui_gateway/methods_tools.py` (`browser.manage`), `methods_browser.py` and the `browser` and
`security.website_blocklist` config sections (`hermes_cli/config_defaults.py`):

  - browser.manage {action, url?, enabled?, profile?}:
      status -> {connected, url, browser_use}; use {enabled} -> the same, after writing
      `browser.backend` (browser-use / off); connect -> about 2 s, then {connected: true, url:
      "http://127.0.0.1:9222", messages: [...]}; disconnect -> {connected: false}. An unknown
      action answers 4015 "unknown action: <action>". The window lives as long as the mock (like
      BROWSER_CDP_URL in Hermes's process).
  - GET /api/config adds `browser` (cloud_provider only once chosen, use_real_profile, engine,
    auto_local_for_private_urls, record_sessions, backend, extension_control) and
    `security.website_blocklist`; PUT /api/config deep-merges them like Hermes (lists replace).
  - PUT /api/tools/toolsets/browser/provider also writes `browser.cloud_provider` (Browserbase ->
    browserbase, Local Chromium -> local), as Hermes's tools config does.

Mock switches (POST /api/mock/browser): {"connect": "fails"} makes connect answer connected:
false with Hermes's hint lines, {"connect": "unreachable"} answers 5031, {"older": true} answers
browser.manage with -32601, {"reset": true} puts the defaults back.
"""

import copy
import threading
import time

B = None

LOCK = threading.Lock()
SWITCHES = {"connect": "ok", "older": False}
PROFILES = {}   # profile -> {"browser": {...}, "blocklist": {...}, "window": url or None}
PROVIDER_KEYS = {"Browserbase": "browserbase", "Local Chromium": "local"}


def defaults():
    return {
        "browser": {"use_real_profile": False, "engine": "auto", "auto_local_for_private_urls": True,
                    "record_sessions": False, "backend": "", "extension_control": {"enabled": False, "developer_mode": False}},
        "blocklist": {"enabled": True, "domains": ["ads.example.com", "*.tracker.example.net"], "shared_files": []},
        "window": None,
    }


def state(profile):
    profile = profile or "default"
    with LOCK:
        return PROFILES.setdefault(profile, defaults())


def deep_merge(base, override):
    result = dict(base)
    for key, value in override.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        elif not (isinstance(result.get(key), dict) and value is None):
            result[key] = value
    return result


def profile_of(query, body):
    named = (body or {}).get("profile") if isinstance(body, dict) else None
    return named or ((query or {}).get("profile") or [None])[0]


def method_manage(params):
    if SWITCHES["older"]:
        raise B["RPCError"](-32601, "unknown method: browser.manage")
    profile = state(params.get("profile"))
    action = params.get("action", "status")
    if action in ("status", "use"):
        with LOCK:
            if action == "use":
                profile["browser"]["backend"] = "browser-use" if params.get("enabled", True) is not False else "off"
            backend = profile["browser"]["backend"]
            return {"connected": bool(profile["window"]), "url": profile["window"] or "",
                    "browser_use": backend != "off"}
    if action == "disconnect":
        with LOCK:
            profile["window"] = None
        return {"connected": False}
    if action == "connect":
        time.sleep(2)
        if SWITCHES["connect"] == "unreachable":
            raise B["RPCError"](5031, "could not reach browser CDP at http://127.0.0.1:9222")
        if SWITCHES["connect"] == "fails":
            return {"connected": False, "url": "http://127.0.0.1:9222", "messages": [
                "Chromium-family browser isn't running with remote debugging — attempting to launch...",
                "No supported Chromium-family browser executable was found in this environment.",
                "Install one or start a Chromium-family browser with --remote-debugging-port=9222, then retry /browser connect.",
                "Browser not connected — start a Chromium-family browser with remote debugging and retry /browser connect"]}
        with LOCK:
            profile["window"] = "http://127.0.0.1:9222"
        return {"connected": True, "url": "http://127.0.0.1:9222",
                "messages": ["Chromium-family browser launched and listening on port 9222"]}
    raise B["RPCError"](4015, f"unknown action: {action}")


def mock_switch(query, body):
    body = body or {}
    with LOCK:
        if "connect" in body:
            SWITCHES["connect"] = str(body["connect"])
        if "older" in body:
            SWITCHES["older"] = bool(body["older"])
        if body.get("reset"):
            PROFILES.clear()
            SWITCHES.update(connect="ok", older=False)
    return 200, {"ok": True, **SWITCHES}


def install(backend_globals):
    global B
    B = backend_globals
    B["METHODS"]["browser.manage"] = method_manage
    routes = B["HTTP_ROUTES"]
    routes[("POST", "/api/mock/browser")] = mock_switch

    previous_get, previous_put = routes.get(("GET", "/api/config")), routes.get(("PUT", "/api/config"))

    def get_config(query, body):
        status, config = previous_get(query, body) if previous_get else (200, {})
        if status != 200:
            return status, config
        profile = state(profile_of(query, body))
        with LOCK:
            config = dict(config or {})
            config["browser"] = deep_merge(config.get("browser") or {}, copy.deepcopy(profile["browser"]))
            security = dict(config.get("security") or {})
            security["website_blocklist"] = copy.deepcopy(profile["blocklist"])
            config["security"] = security
        return 200, config

    def put_config(query, body):
        incoming = dict((body or {}).get("config") or {})
        profile = state(profile_of(query, body))
        browser = incoming.pop("browser", None)
        security = incoming.get("security")
        with LOCK:
            if isinstance(browser, dict):
                profile["browser"] = deep_merge(profile["browser"], browser)
            if isinstance(security, dict) and isinstance(security.get("website_blocklist"), dict):
                profile["blocklist"] = deep_merge(profile["blocklist"], security["website_blocklist"])
                security = {k: v for k, v in security.items() if k != "website_blocklist"}
                if security:
                    incoming["security"] = security
                else:
                    incoming.pop("security", None)
        if previous_put and incoming:
            return previous_put(query, {**(body or {}), "config": incoming})
        return 200, {"ok": True}

    routes[("GET", "/api/config")] = get_config
    routes[("PUT", "/api/config")] = put_config

    previous_provider = routes.get(("PUT", "/api/tools/toolsets/browser/provider"))

    def put_provider(query, body):
        status, answer = previous_provider(query, body) if previous_provider else (200, {"ok": True})
        key = PROVIDER_KEYS.get((body or {}).get("provider"))
        if status == 200 and key:
            profile = state(profile_of(query, body))
            with LOCK:
                profile["browser"]["cloud_provider"] = key
        return status, answer

    routes[("PUT", "/api/tools/toolsets/browser/provider")] = put_provider
