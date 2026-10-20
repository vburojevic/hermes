"""Setup after pairing (docs/onboarding.md §3), shaped like the gateway's calls.

- `setup.status {profile}`: `provider_configured` (is any model provider set up) and `ready` (the
  boot check has settled), like tui_gateway/methods_config.py.
- `model.options {include_unconfigured}`: provider rows (slug, name, auth_type, authenticated,
  free_tier), Nous Portal with its free tier.
- `model.save_key {slug, api_key}`: 4001 without both, 4002 unknown provider, 4003 for a provider
  that signs in (OAuth). The key is never printed.
- `free_tier.provision`: mints the free-tier guest (`has_guest: true`).

Mock-only: `--no-model` starts the gateway without a model provider; `POST /api/mock/onboarding
{provider_configured, jobs: "clear"|"seed"}` changes it while running ("clear" empties Tasks, so
setup offers the morning briefing).
"""

import copy

B = None
G = None

STATE = {"provider_configured": True, "guest": False}

PROVIDERS = [
    {"slug": "nous", "name": "Nous Portal", "auth_type": "oauth_device_code", "free_tier": True},
    {"slug": "openrouter", "name": "OpenRouter", "auth_type": "api_key", "key_env": "OPENROUTER_API_KEY"},
    {"slug": "anthropic", "name": "Anthropic", "auth_type": "api_key", "key_env": "ANTHROPIC_API_KEY"},
    {"slug": "openai", "name": "OpenAI", "auth_type": "api_key", "key_env": "OPENAI_API_KEY"},
    {"slug": "gemini", "name": "Google Gemini", "auth_type": "api_key", "key_env": "GEMINI_API_KEY"},
    {"slug": "deepseek", "name": "DeepSeek", "auth_type": "api_key", "key_env": "DEEPSEEK_API_KEY"},
    {"slug": "ollama", "name": "A model on Studio Mac", "auth_type": "none"},
]
AUTHENTICATED = set()
SAVED_JOBS = {}


def setup_status(params):
    return {"provider_configured": STATE["provider_configured"], "ready": True,
            "free_tier_account": STATE["guest"], "free_tier_route": STATE["guest"],
            "other_providers": bool(AUTHENTICATED), "inference_provider": "nous" if STATE["guest"] else (next(iter(AUTHENTICATED), None)),
            **({"profile": params["profile"]} if params.get("profile") else {})}


def model_options(params):
    rows = []
    for provider in PROVIDERS:
        row = copy.deepcopy(provider)
        row["authenticated"] = provider["slug"] in AUTHENTICATED or (provider["slug"] == "nous" and STATE["guest"])
        row["models"] = []
        if row["authenticated"] or params.get("include_unconfigured"):
            rows.append(row)
    return {"providers": rows, "model": "", "provider": ""}


def model_save_key(params):
    slug, key = (params.get("slug") or "").strip(), (params.get("api_key") or "").strip()
    if not slug or not key:
        raise B["RPCError"](4001, "slug and api_key are required")
    provider = next((p for p in PROVIDERS if p["slug"] == slug), None)
    if provider is None:
        raise B["RPCError"](4002, f"unknown provider: {slug}")
    if provider["auth_type"] != "api_key":
        raise B["RPCError"](4003, f"{provider['name']} uses {provider['auth_type']} auth — run `hermes model` to configure")
    AUTHENTICATED.add(slug)
    STATE["provider_configured"] = True
    print(f"[onboarding] saved a key for {slug} ({len(key)} characters)", flush=True)
    row = copy.deepcopy(provider)
    row.update(authenticated=True, models=[])
    return {"provider": row}


def free_tier_provision(params):
    STATE["guest"] = True
    STATE["provider_configured"] = True
    return {"has_guest": True, "enabled": True}


def mock_control(query, body):
    body = body or {}
    if "provider_configured" in body:
        STATE["provider_configured"] = bool(body["provider_configured"])
        if not STATE["provider_configured"]:
            AUTHENTICATED.clear()
            STATE["guest"] = False
    jobs = getattr(G, "JOBS", None)
    if jobs is not None and body.get("jobs") == "clear":
        SAVED_JOBS.update(jobs)
        jobs.clear()
    if jobs is not None and body.get("jobs") == "seed":
        jobs.update(SAVED_JOBS)
    return 200, {"ok": True, **STATE}


def install(backend_globals, gateway_module, no_model=False):
    global B, G
    B, G = backend_globals, gateway_module
    STATE["provider_configured"] = not no_model
    methods = B["METHODS"]
    methods["setup.status"] = setup_status
    methods["model.options"] = model_options
    methods["model.save_key"] = model_save_key
    methods["free_tier.provision"] = free_tier_provision
    B["HTTP_ROUTES"][("POST", "/api/mock/onboarding")] = mock_control
