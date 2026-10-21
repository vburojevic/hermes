"""Passwords for the combined mock (`docs/web.md` §1, §3), shaped like Hermes Agent's
`tui_gateway/methods_vault.py`, `agent/vault_store.py` and `agent/vault_backends/`:

  - vault.sources {profile}: Hermes vault (always on), 1Password (op) and Bitwarden (bw), each
    {name, display_name, enabled, needs_unlock, unlocked, installed}. A manager is enabled only when
    its CLI is installed and not turned off.
  - vault.list {profile}: metadata only, from Hermes's vault and every unlocked manager, each with
    `backend`. A locked manager adds nothing. Listing a manager's logins keeps it unlocked (like
    `get_session_token`), and an unlock expires after the idle time (30 minutes; see below).
  - vault.source.set {name, enabled}: unknown names answer 5095 "unknown vault source: <name>";
    turning one off also locks it.
  - vault.unlock {name, password}: 5095 "<name> is not an enabled password manager", "master password
    is required", or the manager's own failure ("1Password unlock failed: [ERROR] … Unauthorized")
    for a master password containing "wrong"; one containing "slow" waits 20 s and times out like
    the CLI ("op unlock timed out after 20s"). Any other unlocks. The password is never kept or logged.
  - vault.lock {name?}: one manager, or every one.
  - vault.add {kind, label, origin, secret} -> {id}: Hermes's checks and VaultError wording; logins
    move identifier/identifier_type into the metadata, cards and addresses keep only the canonical
    fields. vault.remove {id} -> {removed}.

Mock switches (POST /api/mock/vault): {"idle": <seconds>} shortens the idle lock (to watch logins
disappear), {"onepassword": "missing"|"off"|"locked"|"unlocked"} and the same for "bitwarden",
{"older": true} answers every vault.* with -32601 like a Hermes from before Passwords, {"reset":
true} puts the demo data back. Demo data is Sam's (US): Hermes's vault holds Vercel, Example Cloud
(with an authenticator key), a Visa test card and a home address; 1Password (locked) holds GitHub,
Linear and Amazon; Bitwarden isn't installed. A card number is only ever the 4242 test number.
"""

import threading
import time
import uuid
from datetime import datetime, timezone

B = None  # backend.py's module globals

LOCK = threading.Lock()
IDLE = {"seconds": 30 * 60}
OLDER = {"on": False}
VAULTS = {}     # profile -> [record] (Hermes's vault)
MANAGERS = {}   # profile -> {name: {"installed", "enabled", "token_at"}}

DISPLAY = {"onepassword": "1Password", "bitwarden": "Bitwarden"}
PAYMENT_FIELDS = ("card_number", "cardholder_name", "exp_month", "exp_year", "cvc", "billing_postal_code")
ADDRESS_FIELDS = ("address_line1", "address_line2", "city", "state", "postal_code", "country")
REQUIRED = {"payment": ("card_number", "exp_month", "exp_year", "cvc"),
            "address": ("address_line1", "city", "postal_code", "country")}

MANAGER_ITEMS = {
    "onepassword": [
        {"id": "op:k3v9github", "kind": "login", "label": "GitHub", "origin": "https://github.com",
         "created_at": "2025-03-04T09:12:00Z", "identifier": "sam-k", "identifier_type": "username", "has_otp": True},
        {"id": "op:q8linear", "kind": "login", "label": "Linear", "origin": "https://linear.app",
         "created_at": "2025-05-19T16:40:00Z", "identifier": "sam@example.com", "identifier_type": "email"},
        {"id": "op:a2amazon", "kind": "login", "label": "Amazon", "origin": "https://www.amazon.com",
         "created_at": "2024-11-02T12:00:00Z", "identifier": "sam@example.com", "identifier_type": "email",
         "allowed_origins": ["https://www.amazon.com", "https://amazon.com"]},
    ],
    "bitwarden": [
        {"id": "bw:n4notion", "kind": "login", "label": "Notion", "origin": "https://www.notion.so",
         "created_at": "2025-02-11T08:00:00Z", "identifier": "sam@example.com", "identifier_type": "email"},
    ],
}


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def seed_vault():
    return [
        {"id": "vault_7c1e0a9b2d4f", "kind": "login", "label": "Vercel", "origin": "https://vercel.com",
         "created_at": "2025-06-02T18:20:00.412233+00:00", "identifier": "sam-k", "identifier_type": "username",
         "secret": {"password": "mock-password-vercel"}},
        {"id": "vault_3e5a7c9d1b2f", "kind": "login", "label": "Example Cloud", "origin": "https://accounts.example.com",
         "created_at": "2025-08-14T07:05:00.000000+00:00", "identifier": "ops@example.com", "identifier_type": "email",
         "secret": {"password": "mock-password-cloud", "otp_secret": "JBSWY3DPEHPK3PXP"}},
        {"id": "vault_9f2b4d6e8a0c", "kind": "payment", "label": "Personal Visa", "origin": "https://www.amazon.com",
         "created_at": "2025-01-20T10:00:00.000000+00:00", "identifier": None, "identifier_type": None,
         "secret": {"card_number": "4242424242424242", "exp_month": "08", "exp_year": "2028", "cvc": "123"}},
        {"id": "vault_1a3c5e7b9d0f", "kind": "address", "label": "Home", "origin": "https://www.amazon.com",
         "created_at": "2025-01-20T10:02:00.000000+00:00", "identifier": None, "identifier_type": None,
         "secret": {"address_line1": "12 Orchard Street", "city": "Portland", "state": "OR",
                    "postal_code": "97201", "country": "United States"}},
    ]


def seed_managers():
    return {"onepassword": {"installed": True, "enabled": True, "token_at": None},
            "bitwarden": {"installed": False, "enabled": True, "token_at": None}}


def profile_key(params):
    return (params or {}).get("profile") or "default"


def state(params):
    profile = profile_key(params)
    with LOCK:
        VAULTS.setdefault(profile, seed_vault())
        MANAGERS.setdefault(profile, seed_managers())
        return VAULTS[profile], MANAGERS[profile]


def live(manager, touch):
    """Like `unlock._live`: the token expires after the idle time; a real manager call refreshes it."""
    at = manager["token_at"]
    if at is None:
        return False
    if time.monotonic() - at > IDLE["seconds"]:
        manager["token_at"] = None
        return False
    if touch:
        manager["token_at"] = time.monotonic()
    return True


def enabled(manager):
    return manager["installed"] and manager["enabled"]


def rpc_error(code, message):
    return B["RPCError"](code, message)


def guard_older(method):
    if OLDER["on"]:
        raise rpc_error(-32601, f"unknown method: {method}")


def meta(record, backend):
    out = {"id": record["id"], "kind": record["kind"], "label": record["label"], "origin": record.get("origin"),
           "created_at": record.get("created_at", ""), "backend": backend}
    if record.get("identifier"):
        out["identifier"] = record["identifier"]
        out["identifier_type"] = record.get("identifier_type")
    if record.get("has_otp") or (record.get("secret") or {}).get("otp_secret"):
        out["has_otp"] = True
    if len(record.get("allowed_origins") or []) > 1:
        out["allowed_origins"] = list(record["allowed_origins"])
    return out


def method_sources(params):
    guard_older("vault.sources")
    _, managers = state(params)
    rows = [{"name": "local", "display_name": "Hermes vault", "enabled": True, "needs_unlock": False,
             "unlocked": True, "installed": True}]
    with LOCK:
        for name in ("onepassword", "bitwarden"):
            manager = managers[name]
            rows.append({"name": name, "display_name": DISPLAY[name], "enabled": enabled(manager),
                         "needs_unlock": True, "unlocked": enabled(manager) and live(manager, touch=False),
                         "installed": manager["installed"]})
    return {"sources": rows}


def method_list(params):
    guard_older("vault.list")
    vault, managers = state(params)
    with LOCK:
        items = [meta(record, "local") for record in vault]
        for name in ("onepassword", "bitwarden"):
            manager = managers[name]
            if enabled(manager) and live(manager, touch=True):
                items.extend(meta(record, name) for record in MANAGER_ITEMS[name])
    return {"items": items}


def method_source_set(params):
    guard_older("vault.source.set")
    _, managers = state(params)
    name = str(params.get("name") or "")
    if name not in DISPLAY:
        raise rpc_error(5095, f"unknown vault source: {name}")
    on = bool(params.get("enabled"))
    with LOCK:
        managers[name]["enabled"] = on
        if not on:
            managers[name]["token_at"] = None
    return {"name": name, "enabled": on}


def method_unlock(params):
    guard_older("vault.unlock")
    _, managers = state(params)
    name = str(params.get("name") or "")
    password = str(params.get("password") or "")
    manager = managers.get(name)
    if manager is None or not enabled(manager):
        raise rpc_error(5095, f"{name} is not an enabled password manager")
    if not password:
        raise rpc_error(5095, "master password is required")
    cli = "op" if name == "onepassword" else "bw"
    try:
        if "slow" in password:
            time.sleep(20)
            raise rpc_error(5095, f"{cli} unlock timed out after 20s")
        time.sleep(0.6)
        if "wrong" in password:
            if name == "bitwarden":
                raise rpc_error(5095, "Bitwarden unlock failed: Invalid master password.")
            raise rpc_error(5095, "1Password unlock failed: [ERROR] 2026/10/21 09:41:00 authentication: (401) Unauthorized")
        with LOCK:
            manager["token_at"] = time.monotonic()
    finally:
        del password
    return {"name": name, "unlocked": True}


def method_lock(params):
    guard_older("vault.lock")
    _, managers = state(params)
    name = params.get("name")
    with LOCK:
        for key, manager in managers.items():
            if not name or key == name:
                manager["token_at"] = None
    return {"locked": True}


def normalize_origin(value):
    from urllib.parse import urlsplit
    value = (value or "").strip()
    if not value:
        raise rpc_error(5095, "origin is required")
    if "://" not in value:
        raise rpc_error(5095, f"origin must include a scheme (got {value!r})")
    parts = urlsplit(value)
    scheme, host = (parts.scheme or "").lower(), (parts.hostname or "").lower()
    if not scheme or not host:
        raise rpc_error(5095, f"could not parse origin from {value!r}")
    port = parts.port
    if port is None or port == {"http": 80, "https": 443}.get(scheme):
        return f"{scheme}://{host}"
    return f"{scheme}://{host}:{port}"


def method_add(params):
    guard_older("vault.add")
    vault, _ = state(params)
    secret = params.get("secret")
    if not isinstance(secret, dict) or not secret:
        raise rpc_error(5095, "secret payload is required")
    kind = str(params.get("kind") or "")
    label = str(params.get("label") or "").strip()
    origin = params.get("origin")
    if kind not in ("login", "payment", "address"):
        raise rpc_error(5095, f"unknown vault kind {kind!r} (expected one of ('login', 'payment', 'address'))")
    if not label:
        raise rpc_error(5095, "label is required")
    record = {"id": f"vault_{uuid.uuid4().hex[:12]}", "kind": kind, "label": label, "origin": None,
              "created_at": now_iso(), "identifier": None, "identifier_type": None}
    secret = dict(secret)
    if kind == "login":
        if not origin:
            raise rpc_error(5095, "origin is required for login items")
        record["origin"] = normalize_origin(origin)
        id_type = secret.pop("identifier_type", None)
        if id_type not in ("email", "phone", "username"):
            raise rpc_error(5095, "identifier_type must be one of ('email', 'phone', 'username')")
        identifier = str(secret.pop("identifier", "") or "").strip()
        if not identifier or not secret.get("password"):
            raise rpc_error(5095, "login items require identifier and password")
        otp = str(secret.get("otp_secret") or "").strip()
        if otp and not otp.lower().startswith("otpauth://totp") and any(
                c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=" for c in otp.replace(" ", "").replace("-", "").upper()):
            raise rpc_error(5095, "authenticator key must be a base32 secret or an otpauth:// URI")
        record.update(identifier=identifier, identifier_type=id_type,
                      secret={"password": secret["password"], **({"otp_secret": otp} if otp else {})})
    else:
        allowed = PAYMENT_FIELDS if kind == "payment" else ADDRESS_FIELDS
        kept = {k: str(v) for k, v in secret.items() if k in allowed and str(v or "").strip()}
        missing = [f for f in REQUIRED[kind] if f not in kept]
        if missing:
            raise rpc_error(5095, f"{kind} items require {', '.join(missing)}")
        if origin:
            record["origin"] = normalize_origin(origin)
        record["secret"] = kept
    with LOCK:
        vault.append(record)
    return {"id": record["id"]}


def method_remove(params):
    guard_older("vault.remove")
    vault, _ = state(params)
    item_id = str(params.get("id") or "")
    if not item_id:
        raise rpc_error(5095, "id is required")
    with LOCK:
        before = len(vault)
        vault[:] = [record for record in vault if record["id"] != item_id]
        return {"removed": len(vault) != before}


def mock_switch(query, body):
    body = body or {}
    with LOCK:
        if "idle" in body:
            IDLE["seconds"] = float(body["idle"])
        if "older" in body:
            OLDER["on"] = bool(body["older"])
        if body.get("reset"):
            VAULTS.clear()
            MANAGERS.clear()
    for name in ("onepassword", "bitwarden"):
        wanted = body.get(name)
        if not wanted:
            continue
        _, managers = state({"profile": body.get("profile")})
        with LOCK:
            manager = managers[name]
            manager["installed"] = wanted != "missing"
            manager["enabled"] = wanted not in ("missing", "off")
            manager["token_at"] = time.monotonic() if wanted == "unlocked" else None
    return 200, {"ok": True, "idle": IDLE["seconds"], "older": OLDER["on"]}


def install(backend_globals):
    global B
    B = backend_globals
    methods = B["METHODS"]
    methods["vault.sources"] = method_sources
    methods["vault.list"] = method_list
    methods["vault.source.set"] = method_source_set
    methods["vault.unlock"] = method_unlock
    methods["vault.lock"] = method_lock
    methods["vault.add"] = method_add
    methods["vault.remove"] = method_remove
    B["HTTP_ROUTES"][("POST", "/api/mock/vault")] = mock_switch
