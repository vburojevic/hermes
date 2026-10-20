"""Apps and Tools for the combined mock: connectors (apps), MCP servers, plugins and built-in toolsets,
shaped like Hermes Agent's gateway (tui_gateway/contracts/connectors.py, connectors_operation.py,
tools_mcp_plugins.py) and filled with the demo data of the Elyx designs (screens/iphone/connections.elyx).

Like the real gateway:
- Every call takes an optional `profile`; `reload.mcp` and `toolsets.list` don't (unknown keys answer 4000).
- Connector errors carry `data.reason` (`ConnectorErrorReason`).
- `connectors.connect` returns an operation with a `connect_url`; the browser page (served here) ends at
  `hermes://connections/done?op=…`, and `connectors.operation.wake` reads the result at once.
- Secrets are write-only: `mcp.servers.set_api_key` and `PUT /api/env` store values that nothing returns.
- `connectors.policy.set` checks `expected_revision` against the member layer (`POLICY_CONFLICT`).

Mock-only, to reach every state: `mock.nous {signed_in}` turns the Nous sign-in off (`available: false`,
`NEEDS_NOUS_AUTH`), and `mock.connections.reset` puts the demo data back.
"""

import copy
import random
import re
import struct
import threading
import time
import uuid
import zlib

B = None  # backend.py globals
LOCK = threading.RLock()
ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
ALIAS = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


def ulid():
    return "01J" + "".join(random.choice(ULID_ALPHABET) for _ in range(23))


def rpc_error(code, message, reason=None):
    return B["RPCError"](code, message, {"reason": reason} if reason else None)


# ---------------------------------------------------------------- demo data

CATALOG = [
    ("github", "GitHub", "Repositories, issues, pull requests and Actions.", "Developer tools", None),
    ("gmail", "Gmail", "Read, search and send email.", "Email", None),
    ("linear", "Linear", "Issues, projects and cycles.", "Project management", None),
    ("slack", "Slack", "Channels, messages and search.", "Communication", None),
    ("notion", "Notion", "Pages, databases and comments", "Docs", None),
    ("googlecalendar", "Google Calendar", "Events, free time and invites", "Calendar", None),
    ("figma", "Figma", "Files, comments and components", "Design", None),
    ("googledrive", "Google Drive", "Files and folders", "Files", None),
    ("jira", "Jira", "Issues, boards and sprints", "Project management", None),
    # One with a logo the mock serves, one whose logo is missing: the letter stays.
    ("dropbox", "Dropbox", "Files and shared folders", "Files", "/mock/logo/dropbox.png"),
    ("hubspot", "HubSpot", "Contacts, deals and tickets", "CRM", "/mock/logo/missing.png"),
    ("todoist", "Todoist", "Tasks and projects", "Productivity", None),
]

READ, WRITE, DESTRUCTIVE = "read", "write", "destructive"


def tool_rows(prefix, specs):
    return [{"slug": f"{prefix}_{name.upper().replace(' ', '_')}", "name": name, "description": desc, "facet": facet,
             "hints": [], "categories": [], "no_auth": False, "deprecated": False} for name, desc, facet in specs]


GITHUB_TOOLS = tool_rows("GITHUB", [
    ("List issues", "Issues in a repository, with filters", READ),
    ("Read a file", "Contents of a file at a branch or commit", READ),
    ("Create pull request", "Opens a PR from a branch", WRITE),
    ("Comment on an issue", "Posts as the account in use", WRITE),
    ("Delete repository", "Can't be undone", DESTRUCTIVE),
    ("Merge pull request", "Merges into the base branch", WRITE),
    ("List pull requests", "Open and closed PRs", READ),
    ("Search code", "Across the repositories it can see", READ),
    ("Get commit", "One commit with its diff", READ),
    ("List branches", "Branches of a repository", READ),
    ("List workflow runs", "Recent Actions runs", READ),
    ("Get workflow run logs", "Logs of one run", READ),
    ("List releases", "Releases and their assets", READ),
    ("Get issue", "One issue with comments", READ),
    ("Get pull request", "One PR with its checks", READ),
    ("List repositories", "Repositories of the account", READ),
    ("List notifications", "Unread notifications", READ),
    ("Get user", "A user's profile", READ),
    ("List labels", "Labels of a repository", READ),
    ("List milestones", "Milestones of a repository", READ),
    ("Get repository", "Settings and stats", READ),
    ("List commits", "History of a branch", READ),
    ("Compare commits", "Diff between two refs", READ),
    ("Create issue", "Opens an issue", WRITE),
    ("Update issue", "Title, body, labels, assignees", WRITE),
    ("Create branch", "From a ref", WRITE),
    ("Create or update file", "Commits one file", WRITE),
    ("Request review", "Asks people to review a PR", WRITE),
    ("Add label", "Labels an issue or PR", WRITE),
    ("Rerun workflow", "Runs a workflow again", WRITE),
    ("Create release", "Tags and publishes a release", WRITE),
    ("Close issue", "Closes an issue", WRITE),
    ("Delete branch", "Removes a branch", DESTRUCTIVE),
    ("Delete file", "Commits a deletion", DESTRUCTIVE),
    ("Delete release", "Removes a release", DESTRUCTIVE),
    ("Remove collaborator", "Revokes someone's access", DESTRUCTIVE),
    ("Delete organization webhook", "Stops webhook deliveries", DESTRUCTIVE),
    ("Archive repository", "Makes a repository read-only", WRITE),
])

TOOLS = {
    "github": GITHUB_TOOLS,
    "gmail": tool_rows("GMAIL", [
        ("Search email", "Messages matching a query", READ), ("Read a message", "One message with attachments", READ),
        ("List labels", "Labels and counts", READ), ("Read a thread", "Every message in a thread", READ),
        ("List drafts", "Unsent drafts", READ), ("Get attachment", "One attachment's content", READ),
        ("Send email", "Sends as the account in use", WRITE), ("Create draft", "Saves a draft", WRITE),
        ("Reply", "Replies in a thread", WRITE), ("Add label", "Labels a message", WRITE),
        ("Move to trash", "Can be restored for 30 days", DESTRUCTIVE), ("Delete forever", "Can't be undone", DESTRUCTIVE),
    ]),
    "linear": tool_rows("LINEAR", [(f"Linear tool {i}", "", READ if i < 14 else WRITE) for i in range(1, 21)]
                        + [("Delete issue", "Can't be undone", DESTRUCTIVE), ("Archive project", "", DESTRUCTIVE)]),
    "slack": tool_rows("SLACK", [
        ("Search messages", "Across channels it can see", READ), ("Read a channel", "Recent messages", READ),
        ("List channels", "Channels and members", READ), ("Read a thread", "Replies in a thread", READ),
        ("Get user", "A member's profile", READ), ("Send message", "Posts as the account in use", WRITE),
        ("Reply in thread", "Replies to a message", WRITE), ("Add reaction", "Reacts to a message", WRITE),
        ("Delete message", "Can't be undone", DESTRUCTIVE),
    ]),
}
for slug, *_ in CATALOG:
    TOOLS.setdefault(slug, tool_rows(slug.upper(), [("Search", "Find things", READ), ("Read", "Open one", READ),
                                                    ("Create", "Make a new one", WRITE), ("Delete", "Can't be undone", DESTRUCTIVE)]))


def initial_state():
    return {
        "nous": True,
        "accounts": [
            {"connection_id": "ca_gh_1", "connector": "github", "status": "active", "status_reason": None, "label": "sam-rivera",
             "alias": "personal", "active": True, "disabled": False, "created_at": "2026-09-02T08:10:00Z", "updated_at": "2026-10-10T08:10:00Z"},
            {"connection_id": "ca_gh_2", "connector": "github", "status": "active", "status_reason": None, "label": "northwind-studio",
             "alias": "work", "active": False, "disabled": False, "created_at": "2026-09-20T12:00:00Z", "updated_at": "2026-10-11T12:00:00Z"},
            {"connection_id": "ca_gm_1", "connector": "gmail", "status": "active", "status_reason": None, "label": "sam@example.com",
             "alias": None, "active": True, "disabled": False, "created_at": "2026-09-05T09:00:00Z", "updated_at": "2026-10-09T09:00:00Z"},
            {"connection_id": "ca_li_1", "connector": "linear", "status": "expired", "status_reason": "Linear signed Hermes out",
             "label": "sam-rivera", "alias": None, "active": True, "disabled": False, "created_at": "2026-08-30T10:00:00Z",
             "updated_at": "2026-10-12T07:42:00Z"},
            {"connection_id": "ca_sl_1", "connector": "slack", "status": "active", "status_reason": None, "label": "Northwind Studio",
             "alias": None, "active": True, "disabled": False, "created_at": "2026-09-10T14:00:00Z", "updated_at": "2026-10-08T14:00:00Z"},
        ],
        # An organization layer blocks one GitHub tool; the member blocks the rest of the destructive ones
        # and one write: 31 of 38 allowed, as designed.
        "org": {"revision": ulid(), "tools": {"github": ["GITHUB_DELETE_ORGANIZATION_WEBHOOK"]}, "disabled_connectors": []},
        "member": {"revision": ulid(), "disabled_connectors": [], "tools": {
            "github": ["GITHUB_DELETE_REPOSITORY", "GITHUB_DELETE_BRANCH", "GITHUB_DELETE_FILE", "GITHUB_DELETE_RELEASE",
                       "GITHUB_REMOVE_COLLABORATOR", "GITHUB_ARCHIVE_REPOSITORY"],
            "gmail": ["GMAIL_MOVE_TO_TRASH", "GMAIL_DELETE_FOREVER"],
            "linear": ["LINEAR_DELETE_ISSUE", "LINEAR_ARCHIVE_PROJECT"],
            "slack": ["SLACK_DELETE_MESSAGE"],
        }},
        "operations": {},
        "servers": {
            "filesystem": {"transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Developer"],
                           "env": [], "auth": None, "enabled": True, "source": "config", "plugin": None, "status": "connected", "tools": 14},
            "github": {"transport": "http", "url": "https://api.githubcopilot.com/mcp/", "args": [], "env": [], "auth": "header",
                       "enabled": True, "source": "plugin", "plugin": "github", "status": "connected", "tools": 26},
            "sentry": {"transport": "http", "url": "https://mcp.sentry.dev/sse", "args": [], "env": ["SENTRY_TOKEN"], "auth": "header",
                       "enabled": True, "source": "config", "plugin": None, "status": "failed", "tools": 0,
                       "error": "401 Unauthorized: the token was rejected"},
            "postgres": {"transport": "stdio", "command": "uvx", "args": ["mcp-server-postgres", "${DATABASE_URL}"], "env": ["DATABASE_URL"],
                         "auth": None, "enabled": True, "source": "config", "plugin": None, "status": "lazy", "tools": 0},
        },
        # Env keys with a value: names only, the values are never returned.
        "env": {"SENTRY_TOKEN": "stale-token", "DATABASE_URL": "postgres://localhost/hermes", "XCODE_CLOUD_TOKEN": "set"},
        "oauth": {},
        "plugins": [
            {"name": "Xcode", "key": "xcode", "version": "1.4", "description": "Build, test and read Xcode projects open on Studio Mac.",
             "source": "user", "status": "enabled", "portable": False, "install_dir": "~/.hermes/plugins/xcode", "has_desktop_half": True,
             "servers": [{"name": "xcode", "state": "connected", "sentence": ""}], "catalog_name": "xcode", "catalog_tier": "official",
             "installed_sha": "4f2a9c1", "catalog_sha": "4f2a9c1", "catalog_version": "1.4", "update_available": False, "pinned_sha": "4f2a9c1",
             "settings": {"default_scheme": "Hermes"},
             "schema": [{"key": "default_scheme", "type": "string", "label": "Default scheme", "description": "Used when a chat doesn't name one.",
                         "required": False, "default": None},
                        {"key": "xcode_cloud_token", "type": "secret", "label": "Xcode Cloud token", "description": "", "required": False,
                         "env": "XCODE_CLOUD_TOKEN"}],
             "tools": ["build_scheme", "run_tests", "read_build_log", "list_schemes", "list_destinations", "clean_build", "archive",
                       "read_test_results", "list_targets", "show_build_settings", "open_project", "read_diagnostics"],
             "skills": ["xcode-build-fix", "swift-testing"]},
            {"name": "Blender", "key": "blender", "version": "2.1", "description": "Model, render and script scenes in Blender.",
             "source": "user", "status": "enabled", "portable": False, "install_dir": "~/.hermes/plugins/blender", "has_desktop_half": True,
             "servers": [{"name": "blender", "state": "app_not_running", "sentence": "Blender isn't running on Studio Mac"}],
             "catalog_name": "blender", "catalog_tier": "official", "installed_sha": "9b1e77d", "catalog_sha": "9b1e77d",
             "catalog_version": "2.1", "update_available": False, "pinned_sha": "9b1e77d", "settings": {}, "schema": [],
             "tools": ["get_scene", "create_object", "modify_object", "delete_object", "set_material", "render", "run_script",
                       "import_asset", "export_scene"], "skills": []},
            {"name": "homeassistant", "key": "homeassistant", "version": "0.9", "description": "Lights, sensors and scenes in Home Assistant.",
             "source": "user", "status": "enabled", "portable": True, "install_dir": "~/.hermes/plugins/homeassistant", "has_desktop_half": False,
             "servers": [{"name": "homeassistant", "state": "connected", "sentence": ""}], "catalog_name": "homeassistant",
             "catalog_tier": "community", "installed_sha": "c3d0a12", "catalog_sha": "e81f4b0", "catalog_version": "1.0",
             "update_available": True, "pinned_sha": "c3d0a12", "settings": {"base_url": "http://homeassistant.local:8123"},
             "schema": [{"key": "base_url", "type": "string", "label": "Address", "description": "", "required": True, "default": None},
                        {"key": "token", "type": "secret", "label": "Access token", "description": "", "required": True, "env": "HASS_TOKEN"},
                        {"key": "area", "type": "enum", "label": "Default area", "description": "", "required": False,
                         "choices": ["Living room", "Office", "Bedroom"], "default": "Office"}],
             "tools": [f"hass_tool_{i}" for i in range(1, 19)], "skills": []},
        ],
        "toolsets": [
            ("terminal", "Run shell commands", 3, True), ("file", "Read and write files", 6, True),
            ("web", "Search the web and extract pages", 2, True), ("browser", "Drive a headless browser", 9, True),
            ("vision", "Analyze images", 2, True), ("image_gen", "Generate images", 1, False),
            ("memory", "Persistent memory", 3, True), ("delegation", "Delegate to parallel subagents", 2, True),
        ],
    }


STATE = initial_state()
CATALOG_PLUGINS = [
    {"name": "figma-desktop", "title": "Figma Desktop", "description": "Read and edit the open Figma file", "tier": "official",
     "platforms": ["macos"], "app_state": "present", "sentence": ""},
    {"name": "obsidian", "title": "Obsidian", "description": "Search and write notes in your vault", "tier": "community",
     "platforms": ["macos", "linux"], "app_state": "missing_app", "sentence": "Obsidian isn't installed on Studio Mac"},
]
PRESETS = [
    {"name": "brave-search", "description": "Web search", "requires": ["BRAVE_API_KEY"], "transport": "stdio",
     "config": {"command": "npx", "args": ["-y", "@brave/brave-search-mcp-server"]}, "tools": 2},
    {"name": "postgresql", "description": "Query a database", "requires": ["DATABASE_URL"], "transport": "stdio",
     "config": {"command": "uvx", "args": ["mcp-server-postgres", "${DATABASE_URL}"]}, "tools": 8},
    {"name": "playwright", "description": "Drive a browser", "requires": [], "transport": "stdio",
     "config": {"command": "npx", "args": ["-y", "@playwright/mcp"]}, "tools": 21},
    {"name": "notion", "description": "Notion workspace, signed in with OAuth", "requires": [], "transport": "http",
     "config": {"url": "https://mcp.notion.com/mcp", "auth": "oauth"}, "tools": 14},
    {"name": "filesystem", "description": "Files under a folder", "requires": [], "transport": "stdio",
     "config": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem"]}, "tools": 14},
    {"name": "sentry", "description": "Issues and releases", "requires": ["SENTRY_TOKEN"], "transport": "http",
     "config": {"url": "https://mcp.sentry.dev/sse", "auth": "header"}, "tools": 18},
]


# Toolsets whose keys aren't set (hermes_cli/tools_config.py `_toolset_has_keys`): on, but Hermes
# leaves their tools out until one is (docs/setup.md §4.5).
NO_KEYS = {"image_gen", "browser"}


def toolsets_rest(query, body):
    """GET /api/tools/toolsets: each configurable toolset with `enabled` and `configured`."""
    with LOCK:
        rows = list(STATE["toolsets"])
    return 200, [{"name": name, "label": name, "description": description, "platform": "cli", "platform_label": "CLI",
                  "enabled": enabled, "available": enabled, "configured": name not in NO_KEYS, "tools": []}
                 for name, description, _count, enabled in rows]


# Each toolset's providers as `hermes tools` lists them (GET /api/tools/toolsets/{name}/config).
TOOLSET_PROVIDERS = {
    "browser": [
        {"name": "Browserbase", "badge": "paid", "env_vars": [
            {"key": "BROWSERBASE_API_KEY", "prompt": "Browserbase API key", "url": "https://www.browserbase.com"},
            {"key": "BROWSERBASE_PROJECT_ID", "prompt": "Browserbase project ID", "url": None}]},
        {"name": "Local Chromium", "badge": "free", "env_vars": []},
    ],
    "image_gen": [
        {"name": "FAL", "badge": "paid", "env_vars": [{"key": "FAL_KEY", "prompt": "FAL API key", "url": "https://fal.ai"}]},
    ],
}
SET_KEYS = set()


def toolset_config(name):
    def route(query, body):
        with LOCK:
            providers = []
            for row in TOOLSET_PROVIDERS.get(name, []):
                env = [{**e, "default": None, "is_set": e["key"] in SET_KEYS} for e in row["env_vars"]]
                ready = bool(env) and all(e["is_set"] for e in env)
                providers.append({"name": row["name"], "badge": row["badge"], "tag": "", "env_vars": env, "post_setup": None,
                                  "requires_nous_auth": False, "managed_nous_feature": None,
                                  "is_active": ready, "status": "ready" if ready else ("needs_keys" if env else "needs_setup")})
        return 200, {"name": name, "has_category": True, "providers": providers,
                     "active_provider": next((p["name"] for p in providers if p["is_active"]), None)}
    return route


def toolset_env(name):
    def route(query, body):
        env = (body or {}).get("env") or {}
        allowed = {e["key"] for row in TOOLSET_PROVIDERS.get(name, []) for e in row["env_vars"]}
        unknown = sorted(k for k in env if k not in allowed)
        if unknown:
            return 400, {"detail": f"Unknown env var(s) for toolset {name}: {', '.join(unknown)}"}
        saved = [k for k, v in env.items() if (v or "").strip()]
        with LOCK:
            SET_KEYS.update(saved)
        return 200, {"ok": True, "saved": saved, "skipped": [k for k in env if k not in saved]}
    return route


def toolset_provider(name):
    def route(query, body):
        provider = (body or {}).get("provider")
        row = next((r for r in TOOLSET_PROVIDERS.get(name, []) if r["name"] == provider), None)
        if row is None:
            return 400, {"detail": f"Unknown provider for {name}: {provider}"}
        with LOCK:
            if all(e["key"] in SET_KEYS for e in row["env_vars"]):
                NO_KEYS.discard(name)
        return 200, {"ok": True, "name": name, "provider": provider}
    return route


CODEX_FLOW = {"polls": 0}


def codex_start(query, body):
    """Signing in to OpenAI Codex again (hermes_cli/web_routers/oauth.py device code): approved
    on the second poll. Providers without a device-code flow answer 400 like Hermes."""
    CODEX_FLOW["polls"] = 0
    return 200, {"session_id": "codex-mock", "flow": "device_code", "user_code": "CDX-7Q2M",
                 "verification_url": f"{base_url()}/mock/nous?code=CDX-7Q2M", "expires_in": 600, "poll_interval": 1}


def codex_poll(query, body):
    CODEX_FLOW["polls"] += 1
    return 200, {"session_id": "codex-mock", "status": "approved" if CODEX_FLOW["polls"] >= 2 else "pending"}


def oauth_providers(query, body):
    """GET /api/providers/oauth: Nous's sign-in state (hermes_cli/web_routers/oauth.py)."""
    with LOCK:
        signed_in = bool(STATE["nous"])
    return 200, {"providers": [{"id": "nous", "name": "Nous Portal", "flow": "device_code", "cli_command": "hermes portal",
                                "docs_url": "", "disconnect_hint": None, "disconnect_command": None, "disconnectable": True,
                                "status": {"logged_in": signed_in}}]}


def install(backend_globals):
    global B
    B = backend_globals
    B["HTTP_ROUTES"][("GET", "/api/providers/oauth")] = oauth_providers
    B["HTTP_ROUTES"][("GET", "/api/tools/toolsets")] = toolsets_rest
    for name in TOOLSET_PROVIDERS:
        B["HTTP_ROUTES"][("GET", f"/api/tools/toolsets/{name}/config")] = toolset_config(name)
        B["HTTP_ROUTES"][("PUT", f"/api/tools/toolsets/{name}/env")] = toolset_env(name)
        B["HTTP_ROUTES"][("PUT", f"/api/tools/toolsets/{name}/provider")] = toolset_provider(name)
    B["HTTP_ROUTES"][("POST", "/api/providers/oauth/openai-codex/start")] = codex_start
    B["HTTP_ROUTES"][("GET", "/api/providers/oauth/openai-codex/poll/codex-mock")] = codex_poll
    B["HTTP_ROUTES"][("POST", "/api/providers/oauth/anthropic/start")] = lambda q, b: (
        400, {"detail": "Provider anthropic does not support device-code flow"})
    original_configure = B["METHODS"]["profiles.configure"]

    def profiles_configure(params):
        # Whole MCP servers switch through `enabled_mcp_servers` (replace semantics).
        if "enabled_mcp_servers" in params:
            wanted = set(params["enabled_mcp_servers"] or [])
            with LOCK:
                for name, server in STATE["servers"].items():
                    server["enabled"] = name in wanted  # `mcp.servers.status` reports it as disabled
            rest = {k: v for k, v in params.items() if k not in ("enabled_mcp_servers", "profile")}
            if set(rest) <= {"name"}:
                return {"ok": True, "applied": {"mcp_servers": True}}
            params = rest
        return original_configure(params)

    B["METHODS"].update({
        "connectors.list": connectors_list, "connectors.catalog": connectors_catalog, "connectors.connect": connectors_connect,
        "connectors.operation.status": operation_status, "connectors.operation.wake": operation_wake,
        "connectors.accounts": accounts, "connectors.accounts.rename": accounts_rename, "connectors.accounts.remove": accounts_remove,
        "connectors.tools": connector_tools, "connectors.policy.get": policy_get, "connectors.policy.set": policy_set,
        "mcp.catalog": mcp_catalog, "mcp.servers.list": servers_list, "mcp.servers.status": servers_status,
        "mcp.servers.add": servers_add, "mcp.servers.set_api_key": servers_set_api_key, "mcp.servers.test": servers_test,
        "mcp.servers.remove": servers_remove, "mcp.servers.oauth.start": oauth_start, "mcp.servers.oauth.poll": oauth_poll,
        "mcp.servers.oauth.cancel": oauth_cancel, "reload.mcp": reload_mcp, "tools.configure": tools_configure,
        "toolsets.list": toolsets_list, "tools.list": tools_list, "plugins.manage": plugins_manage,
        "plugins.catalog.lookup": plugins_lookup, "profiles.configure": profiles_configure, "skills.manage": skills_manage,
        "mock.nous": mock_nous, "mock.connections.reset": mock_reset,
    })
    B["PUBLIC_ROUTES"].update({"/mock/connect": connect_page, "/mock/mcp-oauth": mcp_oauth_page,
                               "/mock/logo/dropbox.png": lambda q: (200, "image/png", png(0x00, 0x61, 0xFE))})
    B["HTTP_ROUTES"][("PUT", "/api/env")] = put_env
    # Nous sign-in by device code (hermes_cli/web_routers/oauth.py); one session id in this mock.
    B["HTTP_ROUTES"][("POST", "/api/providers/oauth/nous/start")] = nous_start
    B["HTTP_ROUTES"][("GET", "/api/providers/oauth/nous/poll/nous-mock")] = nous_poll
    B["PUBLIC_ROUTES"]["/mock/nous"] = nous_page


def unscoped(params, *allowed):
    """Params models are extra="forbid": a key the real gateway doesn't take answers 4000."""
    extra = set(params) - set(allowed)
    if extra:
        raise rpc_error(4000, f"unknown parameters: {sorted(extra)}")


def base_url():
    return f"http://127.0.0.1:{B['CONFIG'].get('port', 19119)}"


# ---------------------------------------------------------------- apps

def require_nous():
    if not STATE["nous"]:
        raise rpc_error(4032, "Sign in to use connectors.", "NEEDS_NOUS_AUTH")


def connector_rows():
    rows = {}
    for account in STATE["accounts"]:
        if account["disabled"]:
            continue
        row = rows.setdefault(account["connector"], {"connector": account["connector"], "enabled": True, "connected": True,
                                                     "connection_status": None, "status_reason": None, "gateway_disabled_tools": []})
        if account["active"] or row["connection_status"] is None:
            row["connection_status"] = account["status"]
            row["status_reason"] = account["status_reason"]
    for slug in STATE["member"]["disabled_connectors"]:
        if slug in rows:
            rows[slug]["enabled"] = False
    return list(rows.values())


def connectors_list(params):
    owner = params.get("owner") or {}
    if owner.get("type") not in ("account", "session"):
        raise rpc_error(4000, "owner required", "INVALID_PARAMS")
    with LOCK:
        if not STATE["nous"]:
            return {"available": False, "connectors": []}
        return {"available": True, "connectors": connector_rows()}


def connectors_catalog(params):
    require_nous()
    return {"connectors": [{"slug": slug, "name": name, "description": desc, "category": category,
                            "logo_url": (base_url() + logo) if logo else None} for slug, name, desc, category, logo in CATALOG]}


def target_for(op):
    return {"name": op["connector"], "kind": "connector", "action": "reconnect" if op["reconnect"] else "connect",
            "state": op["state"], "resolved": op["state"] in ("connected", "failed", "skipped"),
            "connect_url": f"{base_url()}/mock/connect?op={op['op_id']}" if op["state"] == "initiated" else None,
            "connection_id": op.get("connection_id"), "alias": op.get("alias"), "detail": op.get("detail")}


def snapshot(op):
    return {"op_id": op["op_id"], "seq": op["seq"], "deadline_at": op["deadline_at"], "settled": op["settled"],
            "settled_at": op.get("settled_at"), "settled_by": op.get("settled_by"), "targets": [target_for(op)]}


def connectors_connect(params):
    require_nous()
    names = params.get("connectors") or []
    if len(names) != 1:
        raise rpc_error(4000, "one connector per call in this mock", "INVALID_PARAMS")
    slug = names[0]
    if slug not in TOOLS:
        raise rpc_error(4040, "unknown connector", "UNKNOWN_TARGET")
    alias = params.get("alias")
    if alias is not None and not ALIAS.match(alias):
        raise rpc_error(4000, "alias format", "INVALID_PARAMS")
    with LOCK:
        if alias and not params.get("reconnect") and any(a["connector"] == slug and a["alias"] == alias and not a["disabled"]
                                                         for a in STATE["accounts"]):
            raise rpc_error(4090, "alias taken", "ALIAS_TAKEN")
        op = {"op_id": "op_" + uuid.uuid4().hex[:10], "seq": 1, "deadline_at": time.time() + 600, "settled": False,
              "connector": slug, "reconnect": bool(params.get("reconnect")), "alias": alias,
              "connection_id": params.get("connection_id"), "state": "initiated", "opened_at": None}
        STATE["operations"][op["op_id"]] = op
        return {**snapshot(op), "status": "initiated"}


def find_op(params):
    op = STATE["operations"].get(params.get("op_id") or "")
    if op is None:
        raise rpc_error(4040, "unknown operation", "UNKNOWN_OPERATION")
    return op


def settle(op):
    """The browser leg came back: the account is connected (or repaired)."""
    if op["settled"]:
        return
    accounts = STATE["accounts"]
    # Like the gateway, the account signed in to last is the one Hermes uses.
    signed_in = None
    if op["reconnect"]:
        for account in accounts:
            if account["connector"] == op["connector"] and (account["connection_id"] == op["connection_id"] or account["alias"] == op["alias"]
                                                            or (not op["connection_id"] and not op["alias"])):
                account.update(status="active", status_reason=None, updated_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
                signed_in = signed_in or account
    else:
        handle = {"github": "northwind-bot", "notion": "Northwind Studio", "googlecalendar": "sam@example.com",
                  "figma": "sam-rivera"}.get(op["connector"], "sam@example.com")
        accounts.append({"connection_id": "ca_" + uuid.uuid4().hex[:8], "connector": op["connector"], "status": "active",
                         "status_reason": None, "label": handle, "alias": op["alias"], "active": True, "disabled": False,
                         "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                         "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        signed_in = accounts[-1]
    if signed_in:
        for account in accounts:
            if account["connector"] == op["connector"]:
                account["active"] = account is signed_in
    op.update(state="connected", settled=True, settled_at=time.time(), settled_by="all_resolved", seq=op["seq"] + 1)


def operation_status(params):
    with LOCK:
        op = find_op(params)
        # The backend watcher notices a finished sign-in on its own a few seconds later.
        if op["opened_at"] and time.time() - op["opened_at"] > 4:
            settle(op)
        return snapshot(op)


def operation_wake(params):
    with LOCK:
        op = find_op(params)
        if op["opened_at"]:
            settle(op)
        return {"status": "ok"}


def connect_page(query):
    op_id = (query.get("op") or [""])[0]
    with LOCK:
        op = STATE["operations"].get(op_id)
        if op is None:
            return 404, "text/plain", b"Unknown sign-in"
        op["opened_at"] = op["opened_at"] or time.time()
        name = next((n for s, n, *_ in CATALOG if s == op["connector"]), op["connector"])
    done = f"hermes://connections/done?op={op_id}&status=success"
    html = f"""<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="2;url={done}">
<body style="font:17px -apple-system;padding:40px;text-align:center">
<h2>Allow Hermes to use {name}?</h2><p>Mock sign-in for the Hermes app.</p>
<p><a href="{done}" style="display:inline-block;padding:12px 22px;background:#111;color:#fff;border-radius:22px;text-decoration:none">Allow</a></p>
<p style="color:#888">Returning to Hermes…</p></body>"""
    return 200, "text/html; charset=utf-8", html.encode()


def accounts(params):
    require_nous()
    with LOCK:
        slug = params.get("connector")
        return {"accounts": [dict(a) for a in STATE["accounts"] if slug in (None, a["connector"])]}


def find_account(connection_id):
    account = next((a for a in STATE["accounts"] if a["connection_id"] == connection_id), None)
    if account is None:
        raise rpc_error(4040, "no such account", "CONNECTION_NOT_FOUND")
    return account


def accounts_rename(params):
    require_nous()
    alias = params.get("alias") or ""
    if not ALIAS.match(alias):
        raise rpc_error(4000, "alias format", "INVALID_PARAMS")
    with LOCK:
        account = find_account(params.get("connection_id"))
        if any(a is not account and a["connector"] == account["connector"] and a["alias"] == alias for a in STATE["accounts"]):
            raise rpc_error(4090, "alias taken", "ALIAS_TAKEN")
        account["alias"] = alias
        return dict(account)


def accounts_remove(params):
    require_nous()
    with LOCK:
        account = find_account(params.get("connection_id"))
        STATE["accounts"].remove(account)
        rest = [a for a in STATE["accounts"] if a["connector"] == account["connector"]]
        if account["active"] and rest:
            rest[0]["active"] = True
        return {"connection_id": account["connection_id"], "connector": account["connector"], "status": "removed"}


def connector_tools(params):
    require_nous()
    slug = params.get("slug") or ""
    if slug not in TOOLS:
        raise rpc_error(4040, "unknown connector", "CONNECTOR_NOT_FOUND")
    return {"connector": slug, "toolkit_version": "2026.10", "etag": "mock", "fetched_at": time.time(),
            "source": "network" if params.get("refresh") else "cache", "stale": False, "tools": TOOLS[slug]}


def layer_body(layer):
    return {"mode": "deny", "disabled_connectors": list(layer["disabled_connectors"]),
            "tools": {k: list(v) for k, v in layer["tools"].items()}, "tags": None}


def effective():
    org, member = STATE["org"], STATE["member"]
    tools = {}
    for layer in (org, member):
        for connector, names in layer["tools"].items():
            tools.setdefault(connector, [])
            tools[connector] += [n for n in names if n not in tools[connector]]
    return {"version": 1, "revision": member["revision"], "issued_at_ms": int(time.time() * 1000), "mode": "deny",
            "disabled_connectors": sorted(set(org["disabled_connectors"]) | set(member["disabled_connectors"])),
            "tools": tools, "tags": None}


def policy_get(params):
    require_nous()
    with LOCK:
        return {"layers": [{"kind": "org", "revision": STATE["org"]["revision"], "body": layer_body(STATE["org"])},
                           {"kind": "member", "revision": STATE["member"]["revision"], "body": layer_body(STATE["member"])}],
                "effective": effective()}


def policy_set(params):
    require_nous()
    change, expected = params.get("change") or {}, params.get("expected_revision") or ""
    if not re.match(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$", expected):
        raise rpc_error(4000, "expected_revision format", "INVALID_PARAMS")
    with LOCK:
        member = STATE["member"]
        if expected != member["revision"]:
            raise rpc_error(4090, "policy changed", "POLICY_CONFLICT")
        if change.get("type") == "tools":
            member["tools"][change["connector"]] = list(change.get("disabled_tools") or [])
        elif change.get("type") == "connector":
            disabled = set(member["disabled_connectors"])
            (disabled.discard if change.get("enabled") else disabled.add)(change["connector"])
            member["disabled_connectors"] = sorted(disabled)
        else:
            raise rpc_error(4000, "change type", "INVALID_POLICY")
        member["revision"] = ulid()
        return {"revision": member["revision"], "effective": effective()}


# ---------------------------------------------------------------- MCP servers

def summary(name, server):
    return {"name": name, "transport": server["transport"], "url": server.get("url"), "command": server.get("command"),
            "args": list(server.get("args") or []), "env": list(server.get("env") or []), "auth": server.get("auth"),
            "oauth_tokens_present": server.get("oauth_tokens") if server.get("auth") == "oauth" else None,
            "enabled": server["enabled"], "tools": None, "source": server["source"], "plugin": server.get("plugin")}


def mcp_catalog(params):
    with LOCK:
        return {"servers": [{"name": p["name"], "description": p["description"], "connector_slug": None,
                             "installed": p["name"] in STATE["servers"], "enabled": STATE["servers"].get(p["name"], {}).get("enabled", False),
                             "requires": p["requires"], "transport": p["transport"]} for p in PRESETS]}


def servers_list(params):
    with LOCK:
        return {"servers": [summary(n, s) for n, s in STATE["servers"].items()]}


def servers_status(params):
    with LOCK:
        return {"servers": [{"name": n, "transport": s["transport"], "tools": s["tools"], "connected": s["status"] == "connected",
                             "disabled": not s["enabled"], "status": s["status"] if s["enabled"] else "disabled",
                             "source": s["source"], "plugin": s.get("plugin")} for n, s in STATE["servers"].items()],
                "checked_at": int(time.time())}


def find_server(params, writable=False):
    name = params.get("name") or ""
    server = STATE["servers"].get(name)
    if server is None:
        raise rpc_error(4040, f"server '{name}' not found")
    if writable and server["source"] == "plugin":
        raise rpc_error(4091, f"server '{name}' comes from the {server['plugin']} plugin; change it there")
    return name, server


def servers_add(params):
    name = (params.get("name") or "").strip()
    if not name:
        raise rpc_error(4000, "name required")
    with LOCK:
        if name in STATE["servers"]:
            raise rpc_error(4090, f"server '{name}' already exists")
        config = dict(params.get("config") or {})
        preset = next((p for p in PRESETS if p["name"] == params.get("preset")), None)
        if params.get("preset") and preset is None and not (config.get("url") or config.get("command")):
            raise rpc_error(4063, f"Unknown MCP catalog entry or preset: {params['preset']}")
        if preset:
            for key, value in preset["config"].items():
                config.setdefault(key, value)
        if not config.get("url") and not config.get("command"):
            raise rpc_error(4063, "config must specify a 'url' (http) or 'command' (stdio), or a valid 'preset'")
        env = list(config.get("env") or []) if isinstance(config.get("env"), list) else list((config.get("env") or {}).keys())
        env += [k for k in (preset or {}).get("requires", []) if k not in env]
        server = {"transport": "http" if config.get("url") else "stdio", "url": config.get("url"), "command": config.get("command"),
                  "args": list(config.get("args") or []), "env": env, "auth": config.get("auth"), "enabled": True,
                  "source": "config", "plugin": None, "status": "configured", "tools": 0,
                  "preset_tools": (preset or {}).get("tools")}
        if params.get("bearer_token"):
            key = name.upper().replace("-", "_") + "_TOKEN"
            STATE["env"][key] = params["bearer_token"]
            server["env"].append(key)
            server["auth"] = "header"
        STATE["servers"][name] = server
        return {"ok": True, "name": name, "server": summary(name, server)}


def servers_set_api_key(params):
    if not params.get("value"):
        raise rpc_error(4000, "value required")
    with LOCK:
        name, server = find_server(params, writable=True)
        env_var = params.get("env_var") or (server["env"][0] if server["env"] else name.upper().replace("-", "_") + "_API_KEY")
        STATE["env"][env_var] = params["value"]  # stored, never returned
        if env_var not in server["env"]:
            server["env"].append(env_var)
        server.pop("error", None)
        return {"ok": True, "name": name, "env_var": env_var, "server": summary(name, server)}


def servers_test(params):
    time.sleep(0.8)  # connect, list tools, disconnect
    with LOCK:
        name, server = find_server(params)
        missing = [k for k in server["env"] if not STATE["env"].get(k)]
        tools_count = server.get("preset_tools") or {"filesystem": 14, "github": 26, "postgres": 8}.get(name) or (
            22 if "linear" in name else 6)
        if server.get("auth") == "oauth" and not server.get("oauth_tokens"):
            return {"ok": False, "tools": [], "error": "Sign in first", "oauth_needed": True, "oauth_tokens_present": False}
        if missing:
            server["status"] = "failed"
            server["error"] = f"{missing[0]} is not set"
            return {"ok": False, "tools": [], "error": server["error"], "oauth_needed": False}
        if name == "sentry" and STATE["env"].get("SENTRY_TOKEN") == "stale-token":
            server["status"] = "failed"
            server["error"] = "401 Unauthorized: the token was rejected"
            return {"ok": False, "tools": [], "error": server["error"], "oauth_needed": False}
        server.update(status="connected", tools=tools_count)
        server.pop("error", None)
        tools = [{"name": f"{name}_tool_{i}", "description": ""} for i in range(1, tools_count + 1)]
        return {"ok": True, "tools": tools, "error": None, "prompts": 0, "resources": 0, "oauth_needed": False}


def servers_remove(params):
    with LOCK:
        name, _server = find_server(params, writable=True)
        del STATE["servers"][name]
        return {"ok": True, "removed": True}


def oauth_start(params):
    with LOCK:
        name, server = find_server(params, writable=True)
        flow = "flow_" + uuid.uuid4().hex[:8]
        STATE["oauth"][flow] = {"server": name, "status": "pending", "opened": None}
        return {"ok": True, "session_id": flow, "auth_url": f"{base_url()}/mock/mcp-oauth?flow={flow}", "flow": "pkce"}


def mcp_oauth_page(query):
    flow = (query.get("flow") or [""])[0]
    with LOCK:
        entry = STATE["oauth"].get(flow)
        if entry is None:
            return 404, "text/plain", b"Unknown sign-in"
        entry["opened"] = time.time()
    html = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<body style="font:17px -apple-system;padding:40px;text-align:center"><h2>Signed in</h2>
<p>Hermes has access now. You can close this window.</p></body>"""
    return 200, "text/html; charset=utf-8", html.encode()


def oauth_poll(params):
    with LOCK:
        entry = STATE["oauth"].get(params.get("session_id") or "")
        if entry is None:
            return {"ok": False, "status": "error", "error_message": "unknown flow"}
        if entry["status"] == "pending" and entry["opened"] and time.time() - entry["opened"] > 1.5:
            entry["status"] = "approved"
            server = STATE["servers"].get(entry["server"])
            if server:
                server.update(oauth_tokens=True, status="connected", tools=server.get("preset_tools") or 6)
        if entry["status"] == "approved":
            server = STATE["servers"].get(entry["server"], {})
            return {"ok": True, "status": "approved", "session_id": params["session_id"],
                    "tools": [{"name": f"{entry['server']}_tool_{i}", "description": ""} for i in range(1, (server.get("tools") or 6) + 1)]}
        return {"ok": True, "status": entry["status"], "session_id": params["session_id"]}


def oauth_cancel(params):
    with LOCK:
        entry = STATE["oauth"].get(params.get("session_id") or "")
        if entry:
            entry["status"] = "error"
        return {"ok": True, "status": "cancelled"}


def reload_mcp(params):
    unscoped(params, "session_id", "confirm", "always", "rev")
    return {"status": "reloaded", "message": "MCP servers reloaded", "loaded_rev": uuid.uuid4().hex[:8]}


# ---------------------------------------------------------------- built-in toolsets

def toolset_rows(with_tools):
    rows = []
    for name, description, count, enabled in STATE["toolsets"]:
        row = {"name": name, "description": description, "tool_count": count, "enabled": enabled}
        if with_tools:
            row["tools"] = [f"{name}_{i}" for i in range(1, count + 1)]
        rows.append(row)
    for plugin in STATE["plugins"]:
        row = {"name": plugin["key"], "description": plugin["description"], "tool_count": len(plugin["tools"]),
               "enabled": plugin["status"] == "enabled"}
        if with_tools:
            row["tools"] = list(plugin["tools"])
        rows.append(row)
    return rows


def toolsets_list(params):
    unscoped(params, "session_id")
    with LOCK:
        return {"toolsets": [r for r in toolset_rows(False) if r["name"] in {t[0] for t in STATE["toolsets"]}]}


def tools_list(params):
    unscoped(params, "session_id")
    with LOCK:
        return {"toolsets": toolset_rows(True)}


def tools_configure(params):
    unscoped(params, "action", "names", "session_id", "profile")
    action, names = params.get("action"), params.get("names") or []
    if action not in ("enable", "disable"):
        raise rpc_error(4017, f"unknown tools action: {action}")
    if not names:
        raise rpc_error(4018, "names required")
    with LOCK:
        known = {t[0] for t in STATE["toolsets"]}
        unknown = [n for n in names if ":" not in n and n not in known]
        STATE["toolsets"] = [(n, d, c, (action == "enable") if n in names else e) for n, d, c, e in STATE["toolsets"]]
        enabled = sorted(n for n, _d, _c, e in STATE["toolsets"] if e)
        return {"changed": [n for n in names if n not in unknown], "enabled_toolsets": enabled, "info": None,
                "missing_servers": [], "reset": False, "unknown": unknown}


# ---------------------------------------------------------------- plugins

def plugin_row(plugin):
    row = {k: plugin[k] for k in ("name", "key", "version", "description", "source", "status", "portable", "install_dir",
                                  "has_desktop_half", "catalog_name", "catalog_tier", "installed_sha", "catalog_sha",
                                  "catalog_version", "update_available", "pinned_sha")}
    row["servers"] = copy.deepcopy(plugin["servers"]) if plugin["status"] == "enabled" else []
    schema = []
    for field in plugin["schema"]:
        out = {k: field.get(k) for k in ("key", "type", "label", "description", "required", "default")}
        out["choices"] = field.get("choices")
        if field["type"] == "secret":
            out.update(value=None, env=field["env"], has_value=bool(STATE["env"].get(field["env"])))
        else:
            out.update(value=plugin["settings"].get(field["key"]), env=None, has_value=None)
        schema.append(out)
    row["settings_schema"] = schema
    return row


def find_plugin(key):
    plugin = next((p for p in STATE["plugins"] if key in (p["key"], p["name"])), None)
    if plugin is None:
        raise rpc_error(4020, f"plugin '{key}' not found")
    return plugin


def activation(plugin):
    return {"name": plugin["name"], "key": plugin["key"], "activated_now": {},
            "live_now": {"mcp_servers": [{"name": plugin["key"], "connected": True, "tools": plugin["tools"]}],
                         "skills": [{"name": f"{plugin['key']}:{s}", "description": ""} for s in plugin["skills"]]},
            "deferred": {}}


def plugins_manage(params):
    action = params.get("action") or "list"
    with LOCK:
        if action == "list":
            rows = [plugin_row(p) for p in STATE["plugins"]]
            return {"plugins": rows, "user_count": sum(r["source"] == "user" for r in rows),
                    "bundled_count": sum(r["source"] == "bundled" for r in rows)}
        if action == "onboarding":
            installed = {p["catalog_name"] for p in STATE["plugins"]}
            return {"onboarding": [c for c in CATALOG_PLUGINS if c["name"] not in installed]}
        if action == "toggle":
            plugin = find_plugin(params.get("key") or params.get("name") or "")
            plugin["status"] = "enabled" if params.get("enable") else "not enabled"
            return {"ok": True, "unchanged": False, "restart_required": False, "gateway_reloaded": True, "name": plugin["key"],
                    "plugin": plugin_row(plugin), "activation": activation(plugin) if params.get("enable") else None}
        if action == "install":
            time.sleep(1.2)
            if params.get("catalog_name"):
                entry = next((c for c in CATALOG_PLUGINS if c["name"] == params["catalog_name"]), None)
                if entry is None:
                    raise rpc_error(4024, f"'{params['catalog_name']}' isn't in the Hermes catalog")
                plugin = {"name": entry["title"], "key": entry["name"], "version": "1.0", "description": entry["description"],
                          "source": "user", "status": "enabled", "portable": True, "install_dir": f"~/.hermes/plugins/{entry['name']}",
                          "has_desktop_half": True, "servers": [{"name": entry["name"], "state": entry["app_state"] if entry["app_state"] != "present" else "connected",
                                                                 "sentence": entry["sentence"]}],
                          "catalog_name": entry["name"], "catalog_tier": entry["tier"], "installed_sha": "a1b2c3d", "catalog_sha": "a1b2c3d",
                          "catalog_version": "1.0", "update_available": False, "pinned_sha": "a1b2c3d", "settings": {},
                          "schema": [{"key": "token", "type": "secret", "label": "Access token", "description": "", "required": True,
                                      "env": entry["name"].upper().replace("-", "_") + "_TOKEN"}],
                          "tools": [f"{entry['name']}_tool_{i}" for i in range(1, 7)], "skills": [f"{entry['name']}-basics"]}
                warnings, known = [], ["Comments sync every few minutes."] if entry["name"] == "figma-desktop" else []
            else:
                repo = (params.get("repo") or params.get("identifier") or "").strip()
                if not re.match(r"^(https://|git@|[\w.-]+/[\w.-]+$)", repo):
                    raise rpc_error(4022, "That isn't a git link Hermes can install from.")
                key = repo.rstrip("/").split("/")[-1].removesuffix(".git").lower()
                if any(p["key"] == key for p in STATE["plugins"]):
                    raise rpc_error(4023, f"'{key}' is already installed")
                plugin = {"name": key, "key": key, "version": "0.1.0", "description": f"Installed from {repo}", "source": "user",
                          "status": "enabled", "portable": True, "install_dir": f"~/.hermes/plugins/{key}", "has_desktop_half": False,
                          "servers": [], "catalog_name": None, "catalog_tier": None, "installed_sha": "0d1e2f3", "catalog_sha": None,
                          "catalog_version": None, "update_available": False, "pinned_sha": params.get("ref") or "0d1e2f3",
                          "settings": {}, "schema": [{"key": "api_key", "type": "secret", "label": "API key", "description": "",
                                                      "required": True, "env": key.upper().replace("-", "_") + "_API_KEY"}],
                          "tools": [f"{key}_tool_{i}" for i in range(1, 4)], "skills": []}
                warnings, known = ["Not from the Hermes catalog, so it wasn't scanned."], []
            STATE["plugins"].append(plugin)
            missing = [f["env"] for f in plugin["schema"] if f["type"] == "secret" and not STATE["env"].get(f["env"])]
            return {"ok": True, "name": plugin["key"], "plugin_name": plugin["name"], "plugin": plugin_row(plugin), "enabled": True,
                    "warnings": warnings, "missing_env": missing, "known_issues": known, "python_dependencies": [],
                    "restart_required": False, "gateway_reloaded": True, "activation": activation(plugin)}
        if action == "update":
            plugin = find_plugin(params.get("name") or "")
            if not plugin["update_available"]:
                return {"ok": True, "unchanged": True, "sha": plugin["installed_sha"]}
            if plugin["key"] == "homeassistant" and not params.get("accept_capabilities"):
                # Hermes's own wording (plugins_cmd_catalog.py `_SURFACE_LABELS`): "<label>: <items>".
                return {"ok": False, "consent_required": True, "name": plugin["catalog_name"], "sha": plugin["catalog_sha"],
                        "delta": {"tools": ["hass_shell"], "hooks": ["pre_llm_call"]},
                        "delta_lines": ["tools: hass_shell", "hooks: pre_llm_call"],
                        "error": f"Updating '{plugin['catalog_name']}' to {plugin['catalog_sha'][:8]} adds tools: hass_shell; hooks: "
                                 "pre_llm_call. Confirm to continue."}
            plugin.update(version=plugin["catalog_version"], installed_sha=plugin["catalog_sha"], pinned_sha=plugin["catalog_sha"],
                          update_available=False)
            return {"ok": True, "unchanged": False, "sha": plugin["installed_sha"], "plugin": plugin_row(plugin),
                    "gateway_reloaded": True, "activation": activation(plugin), "restart_required": False}
        if action == "remove":
            plugin = find_plugin(params.get("name") or "")
            if plugin["source"] != "user":
                raise rpc_error(4025, "bundled plugins can only be turned off")
            STATE["plugins"].remove(plugin)
            return {"ok": True, "name": plugin["key"]}
        if action == "settings":
            plugin = find_plugin(params.get("key") or params.get("name") or "")
            values = params.get("values")
            if not isinstance(values, dict):
                raise rpc_error(4019, "plugins.settings requires a 'key' and a 'values' mapping")
            kinds = {f["key"]: f["type"] for f in plugin["schema"]}
            for key in values:
                if kinds.get(key) == "secret":
                    raise rpc_error(4021, f"'{key}' is a secret; it is stored in .env, not config.yaml")
                if key not in kinds:
                    raise rpc_error(4021, f"'{key}' isn't one of this plugin's settings")
            plugin["settings"].update(values)
            return {"ok": True, "name": plugin["key"], "written": sorted(values), "plugin": plugin_row(plugin)}
        raise rpc_error(4000, f"unknown action {action}")


def skills_manage(params):
    """`list` only: skills by category; a plugin's skills are qualified `<plugin>:<skill>`."""
    if (params.get("action") or "list") != "list":
        raise rpc_error(4000, "mock: only list")
    with LOCK:
        skills = {"general": ["swift-concurrency", "release-notes", "ios-simulator"]}
        for plugin in STATE["plugins"]:
            if plugin["skills"] and plugin["status"] == "enabled":
                skills[plugin["key"]] = [f"{plugin['key']}:{s}" for s in plugin["skills"]]
        return {"skills": skills}


def plugins_lookup(params):
    name = params.get("name") or ""
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", name):
        return {"status": "invalid_name"}
    entry = next((c for c in CATALOG_PLUGINS if c["name"] == name), None)
    if entry is None:
        return {"status": "unknown"}
    return {"status": "found", "entry": {"name": name, "repo": f"https://github.com/hermes-plugins/{name}", "sha": "a1b2c3d", "subdir": ""}}


def put_env(query, body):
    """`PUT /api/env`: where plugin secrets go. Stored, never returned."""
    key, value = (body.get("key") or "").strip(), body.get("value")
    if not key or not isinstance(value, str):
        return 422, {"detail": "key and value required"}
    with LOCK:
        STATE["env"][key] = value
    return 200, {"ok": True, "key": key}


# ---------------------------------------------------------------- Nous sign-in

NOUS_FLOW = {"opened": None}


def nous_start(query, body):
    NOUS_FLOW["opened"] = None
    return 200, {"session_id": "nous-mock", "flow": "device_code", "user_code": "HRMS-4F2A",
                 "verification_url": f"{base_url()}/mock/nous?code=HRMS-4F2A", "expires_in": 600, "poll_interval": 1}


def nous_poll(query, body):
    with LOCK:
        if NOUS_FLOW["opened"] and time.time() - NOUS_FLOW["opened"] > 1.5:
            STATE["nous"] = True
            return 200, {"session_id": "nous-mock", "status": "approved"}
    return 200, {"session_id": "nous-mock", "status": "pending"}


def nous_page(query):
    NOUS_FLOW["opened"] = NOUS_FLOW["opened"] or time.time()
    html = """<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<body style="font:17px -apple-system;padding:40px;text-align:center"><h2>Signed in to Nous</h2>
<p>Code HRMS-4F2A approved. You can close this window.</p></body>"""
    return 200, "text/html; charset=utf-8", html.encode()


# ---------------------------------------------------------------- mock-only

def mock_nous(params):
    with LOCK:
        STATE["nous"] = bool(params.get("signed_in", True))
        return {"signed_in": STATE["nous"]}


def mock_reset(params):
    global STATE
    with LOCK:
        STATE = initial_state()
        return {"ok": True}


def png(r, g, b, size=96):
    """A plain square PNG, for the one catalog logo the mock serves."""
    raw = b"".join(b"\x00" + bytes((r, g, b)) * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
