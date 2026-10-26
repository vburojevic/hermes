"""Hermes's browser in the app (`docs/web.md` §6), for the combined mock: the browser-control broker
(`gateway/browser_control_broker.py`) with Hermes Agent's two ways in, refusals and deadlines included.

Bot Mode's socket (`tui_gateway/methods_browser_control.py`):
  - browser.controller.register {session_id, controller_id, browser_profile_id, capabilities,
    protocol_version} -> {scope}. 4403 in Hermes's order and words: the flag
    (`browser.extension_control.enabled`, browser.py's config for the session's profile) off, a
    protocol other than 1, no signed-in identity (a mock without --password signs in automatically,
    like Hermes's ungated dashboard, whose internal identity may not drive a browser), the session
    not on this socket, missing ids, no allowed capability.
  - browser.controller.result {session_id, command_id, ok, result | error} -> {accepted};
    heartbeat -> {ok: true}; detach -> {detached: true}.
  Commands reach the socket that registered as events: browser.controller.command {command_id,
  action, arguments, controller_id, browser_profile_id, tool_call_id}, and browser.controller.cancel
  {command_id, tool_call_id} when Hermes stops waiting.

The gateway (`gateway/platforms/api_server.py`), for chats that run on the API server:
  - POST /v1/browser-control/register (Bearer) -> 201 {protocol_version, ticket, ticket_expires_at,
    ticket_expires_in_seconds: 30, ws_path, scope}. 404 browser_control_disabled, 403
    browser_control_auth_required (a gateway without a key: switch "no_key"), 401 a wrong key, 400
    browser_control_protocol_unsupported / browser_control_invalid_registration /
    browser_control_no_capabilities, 403 browser_control_session_forbidden (not a stored session).
  - GET /v1/browser-control/ws with the protocols hermes-browser-control-v1 and
    hermes-browser-control-ticket.<ticket> (one use, 30 s; a ticket in the query, a missing or a
    spent one is a 401 before the upgrade). Frames are {method, params} both ways; a heartbeat's
    nonce comes back.

A command waits 30 s for its result, then fails the tool the way Hermes does ("Tool execution
failed: ControllerTimeout: …") and sends a cancel. A chat that never registered uses Hermes's own
browser; one whose app gave the browser back (detach) does too; one whose socket dropped without
detaching fails closed (ControllerUnavailable) until the app registers again.

Turns (socket chats and /v1/runs): "in the app" opens the mock's Acme Cloud dashboard in the app's
browser. Signed out, it lands on the sign-in page: Passwords can't fill there (supervisor_required),
so the reply asks the person to sign in and say "carry on"; the next turn reads the deploys, a step
at a time (Take Over in between gets Hermes's human_has_control refusal). "in the app slow" opens a
page that never finishes loading; "in the app router" asks for 192.168.1.1, a page on the person's
network; "checkout in the app" opens a card form the person fills (Passwords can't fill it), and
"carry on" checks Hermes sees only "(filled)" there. Pages (no key): /mock-web/sign-in,
/mock-web/dashboard, /mock-web/checkout, /mock-web/slow on the gateway.

Hermes's split, mirrored: a registration is checked against the launch profile's switch (the
register handler isn't profile scoped), a browser step against the chat's own profile's.

Mock switches (POST /api/mock/browser-control): {"no_key": true} makes the register route answer
as a gateway without API_SERVER_KEY; {"reset": true} drops every controller.
"""

import base64
import hashlib
import json
import secrets
import threading
import time
import uuid

B = None        # backend.py's module globals
G = None        # server.py, when it runs alongside
BROWSER = None  # browser.py: the flag lives in its config

PROTOCOL_VERSION = 1
WS_PROTOCOL = "hermes-browser-control-v1"
TICKET_PREFIX = "hermes-browser-control-ticket."
TICKET_TTL = 30.0
COMMAND_TIMEOUT = 30.0
CAPABILITIES = {"controller.noop", "browser_back", "browser_click", "browser_navigate", "browser_press", "browser_screenshot",
                "browser_scroll", "browser_snapshot", "browser_tab_activate", "browser_tabs", "browser_type",
                "browser_artifact_download", "browser_artifact_upload"}

LOCK = threading.Lock()
LANES = {}     # session id -> {"send", "owner", "connected", "scope", "transport"}
PENDING = {}   # command id -> {"event", "ok", "result", "session", "tool_call_id"}
TICKETS = {}   # ticket -> {"scope", "expires"}
SWITCHES = {"no_key": False}
WAITING = {}  # session -> "sign-in" | "checkout": the turn asked the person to do it first
GATEWAY_URL = ["http://127.0.0.1:18642"]


class Refused(Exception):
    pass


def flag_on(profile):
    browser = BROWSER.state(profile)["browser"] if BROWSER else {}
    control = browser.get("extension_control") or {}
    return control.get("enabled") is True


def filter_capabilities(value):
    if not isinstance(value, list):
        return []
    return sorted({c for c in value if isinstance(c, str) and c in CAPABILITIES})


# ── The broker ──────────────────────────────────────────────────────────────

def attach(session_id, scope, send, owner, transport):
    with LOCK:
        LANES[session_id] = {"send": send, "owner": owner, "connected": True, "scope": scope, "transport": transport}


def detach(session_id, owner):
    """Removes the lane: later browser steps use Hermes's own browser, and waiting commands fail."""
    with LOCK:
        lane = LANES.get(session_id)
        if lane is None or lane["owner"] is not owner:
            return False
        del LANES[session_id]
        pendings = [p for p in PENDING.values() if p["session"] == session_id]
    for pending in pendings:
        pending["cancelled"] = True
        pending["event"].set()
    return True


def live(lane):
    owner = lane["owner"]
    alive = getattr(owner, "alive", True)
    if lane["transport"] == "socket":
        alive = alive and owner in B["CLIENTS"]
    return lane["connected"] and alive


def complete(session_id, command_id, ok, result):
    with LOCK:
        pending = PENDING.get(command_id)
        if pending is None or pending["session"] != session_id or pending["event"].is_set():
            return False
        pending.update(ok=ok, result=result)
        pending["event"].set()
        return True


def failed(kind, message):
    # tools/registry.py's tool_error after model_tools._sanitize_tool_error.
    return json.dumps({"error": f"[TOOL_ERROR] Tool execution failed: {kind}: {message}"})


def dispatch(session_id, action, arguments, tool_call_id, stop=lambda: False, profile=None):
    """One browser tool through the app (`route_browser_tool` → `broker.dispatch`); None when the chat
    has no controller or its profile's switch is off, so Hermes's own browser does it."""
    with LOCK:
        lane = LANES.get(session_id)
    if lane is None or not flag_on(profile or lane["scope"].get("profile_id") or "default"):
        return None
    if not live(lane) or action not in lane["scope"]["capabilities"]:
        return failed("ControllerUnavailable", f"bound browser controller cannot execute {action}")
    command_id = secrets.token_hex(16)
    pending = {"event": threading.Event(), "ok": False, "result": None, "session": session_id,
               "tool_call_id": tool_call_id, "cancelled": False}
    with LOCK:
        PENDING[command_id] = pending
    try:
        lane["send"]({"method": "browser.controller.command", "params": {
            "command_id": command_id, "action": action, "arguments": arguments,
            "controller_id": lane["scope"]["controller_id"], "browser_profile_id": lane["scope"]["browser_profile_id"],
            "tool_call_id": tool_call_id}})
        deadline = time.time() + COMMAND_TIMEOUT
        while not pending["event"].wait(0.2):
            if stop() or time.time() >= deadline:
                break
    finally:
        with LOCK:
            PENDING.pop(command_id, None)
    if not pending["event"].is_set():
        try:
            lane["send"]({"method": "browser.controller.cancel", "params": {"command_id": command_id, "tool_call_id": tool_call_id}})
        except Exception:  # noqa: BLE001 — a gone socket takes no cancel
            pass
        if stop():
            return failed("ControllerCancelled", f"command {command_id!r} was cancelled")
        return failed("ControllerTimeout", f"controller did not complete command {command_id!r} within {COMMAND_TIMEOUT}s")
    if pending["cancelled"]:
        return failed("ControllerCancelled", f"command {command_id!r} was cancelled")
    if not pending["ok"]:
        return failed("ControllerRejected", f"controller rejected command {command_id!r}: {pending['result']!r}")
    result = pending["result"]
    return result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)


# ── Bot Mode's socket ───────────────────────────────────────────────────────

def socket_writer(peer, session_id):
    def send(frame):
        peer.send({"jsonrpc": "2.0", "method": "event", "params": {
            "type": frame.get("method"), "session_id": session_id, "payload": frame.get("params")}})
        if not peer.alive:
            raise ConnectionError("browser controller event write failed")
    return send


def gate(params, identity_message="authenticated controller identity required"):
    """`_controller_method`'s gates: a signed-in identity, then the session on this socket."""
    peer = getattr(B["CURRENT"], "peer", None)
    if not B["CONFIG"]["password"]:
        raise B["RPCError"](4403, identity_message)
    session_id = str(params.get("session_id") or "")
    runtime = B["RUNTIME"].get(session_id)
    if runtime is None or peer not in runtime["peers"]:
        raise B["RPCError"](4403, "session is not owned by this transport")
    return peer, session_id, runtime


def method_register(params):
    # Like Hermes: the handler isn't profile scoped, so it reads the launch profile's switch.
    if not flag_on("default"):
        raise B["RPCError"](4403, "browser.extension_control.enabled is not set")
    version = params.get("protocol_version")
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise B["RPCError"](4403, f"unsupported browser-control protocol version; expected {PROTOCOL_VERSION}")
    peer, session_id, runtime = gate(params, "browser.controller.register requires an authenticated non-internal identity")
    controller_id = str(params.get("controller_id") or "").strip()
    browser_profile_id = str(params.get("browser_profile_id") or "").strip()
    profile_id = str(runtime.get("profile") or "default").strip()
    if not controller_id or not browser_profile_id or not profile_id:
        raise B["RPCError"](4403, "controller_id, browser_profile_id, and server session profile are required")
    capabilities = filter_capabilities(params.get("capabilities"))
    if not capabilities:
        raise B["RPCError"](4403, "no permitted controller capabilities requested")
    scope = {"principal_id": "principal:dashboard:" + hashlib.sha256(B["CONFIG"]["username"].encode()).hexdigest()[:32],
             "profile_id": profile_id, "session_id": session_id, "controller_id": controller_id,
             "browser_profile_id": browser_profile_id, "transport_family": "cloud-ticket-ws", "capabilities": capabilities}
    attach(session_id, scope, socket_writer(peer, session_id), peer, "socket")
    return {"scope": scope}


def owned_lane(params, missing="no controller registered for this session"):
    peer, session_id, _ = gate(params)
    with LOCK:
        lane = LANES.get(session_id)
    if lane is None:
        raise B["RPCError"](4403, missing)
    if lane["owner"] is not peer:
        raise B["RPCError"](4403, "controller is not owned by this transport")
    return peer, session_id


def method_result(params):
    _, session_id = owned_lane(params)
    command_id = str(params.get("command_id") or "")
    if not command_id:
        raise B["RPCError"](4403, "command_id required")
    ok = params.get("ok") is True
    return {"accepted": complete(session_id, command_id, ok, params.get("result") if ok else params.get("error"))}


def method_heartbeat(params):
    owned_lane(params)
    return {"ok": True}


def method_detach(params):
    peer, session_id = owned_lane(params, missing="controller is not owned by this transport")
    detach(session_id, peer)
    return {"detached": True}


# ── The gateway's controller route and socket ──────────────────────────────

def error_body(message, code=None, kind="invalid_request_error"):
    return {"error": {"message": message, "type": kind, "param": None, "code": code}}


def http_register(handler, query):
    """POST /v1/browser-control/register: 404 off, 403 no key, 401 bad key, 400s, 403 unknown session, 201."""
    body = handler.body()
    session_id = str((body or {}).get("session_id") or "").strip()
    profile = "default"
    if not flag_on(profile):
        handler.send_json(404, error_body("Browser control is not enabled on this server.", "browser_control_disabled"))
        return True
    if SWITCHES["no_key"]:
        handler.send_json(403, error_body("Browser control registration requires a configured API key.",
                                          "browser_control_auth_required", "gateway_auth_error"))
        return True
    if not handler.authorized():
        return True
    if not isinstance(body, dict):
        handler.send_json(400, error_body("Request body must be a JSON object."))
        return True
    version = body.get("protocol_version")
    if type(version) is not int or version != PROTOCOL_VERSION:
        handler.send_json(400, error_body("Unsupported browser-control protocol version.", "browser_control_protocol_unsupported"))
        return True
    controller_id = str(body.get("controller_id") or "").strip()
    browser_profile_id = str(body.get("browser_profile_id") or "").strip()
    if not controller_id or not browser_profile_id or not session_id:
        handler.send_json(400, error_body("controller_id, browser_profile_id, and session_id are required.",
                                          "browser_control_invalid_registration"))
        return True
    if session_id not in G.SESSIONS:
        handler.send_json(403, error_body("Browser control may register only for an existing server session.",
                                          "browser_control_session_forbidden", "gateway_auth_error"))
        return True
    capabilities = filter_capabilities(body.get("capabilities"))
    if not capabilities:
        handler.send_json(400, error_body("At least one permitted browser-control capability is required.",
                                          "browser_control_no_capabilities"))
        return True
    family = "local-api" if handler.client_address[0] in ("127.0.0.1", "::1") else "remote-api"
    scope = {"principal_id": f"principal:{profile}:" + hashlib.sha256(f"{profile}\0{handler.key}".encode()).hexdigest()[:32],
             "profile_id": profile, "session_id": session_id, "controller_id": controller_id,
             "browser_profile_id": browser_profile_id, "transport_family": family, "capabilities": capabilities}
    ticket = secrets.token_urlsafe(32)
    with LOCK:
        TICKETS[ticket] = {"scope": scope, "expires": time.monotonic() + TICKET_TTL}
    handler.send_json(201, {"protocol_version": PROTOCOL_VERSION, "ticket": ticket, "ticket_expires_at": time.time() + TICKET_TTL,
                            "ticket_expires_in_seconds": TICKET_TTL, "ws_path": "/v1/browser-control/ws", "scope": scope})
    return True


def http_socket(handler, query):
    """GET /v1/browser-control/ws: the ticket rides in Sec-WebSocket-Protocol, never the query."""
    if not flag_on("default"):
        handler.send_json(404, {"detail": "Not Found"})
        return True
    offered = [p.strip() for p in (handler.headers.get("Sec-WebSocket-Protocol") or "").split(",") if p.strip()]
    tickets = [p for p in offered if p.startswith(TICKET_PREFIX)]
    if query.get("ticket") or WS_PROTOCOL not in offered or len(tickets) != 1:
        handler.send_json(401, {"detail": "Unauthorized"})
        return True
    with LOCK:
        entry = TICKETS.pop(tickets[0][len(TICKET_PREFIX):], None)
    if entry is None or entry["expires"] < time.monotonic():
        handler.send_json(401, {"detail": "Unauthorized"})
        return True
    key = handler.headers.get("Sec-WebSocket-Key")
    if not key or (handler.headers.get("Upgrade") or "").lower() != "websocket":
        handler.send_json(400, {"detail": "Expected a WebSocket upgrade"})
        return True
    accept = base64.b64encode(hashlib.sha1((key + B["WS_GUID"]).encode()).digest()).decode()
    handler.wfile.write((f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: {WS_PROTOCOL}\r\n\r\n").encode())
    handler.wfile.flush()
    handler.close_connection = True
    peer = B["Peer"](handler)
    scope = entry["scope"]
    session_id = scope["session_id"]
    attach(session_id, scope, lambda frame: peer.send(frame), peer, "api")
    try:
        while True:
            text = peer.recv()
            if text is None:
                break
            try:
                frame = json.loads(text)
            except ValueError:
                continue
            if isinstance(frame, dict):
                reply = api_frame(session_id, peer, frame)
                if reply is not None:
                    peer.send(reply)
    except (OSError, ValueError):
        pass
    finally:
        # A dropped socket marks the controller offline; its lane stays (fails closed) until it comes back.
        with LOCK:
            lane = LANES.get(session_id)
            if lane is not None and lane["owner"] is peer:
                lane["connected"] = False
        peer.alive = False
    return True


def api_frame(session_id, peer, frame):
    method, params = frame.get("method"), frame.get("params")
    with LOCK:
        lane = LANES.get(session_id)
    if not isinstance(params, dict) or lane is None or lane["owner"] is not peer:
        return None
    if method == "browser.controller.heartbeat":
        nonce = str(params.get("nonce") or "").strip()
        if not nonce or len(nonce) > 128:
            return None
        return {"method": "browser.controller.heartbeat", "params": {"nonce": nonce, "ok": True}}
    if method == "browser.controller.detach":
        detach(session_id, peer)
        return {"method": "browser.controller.detach", "params": {"ok": True}}
    if method == "browser.controller.result":
        command_id = params.get("command_id")
        if isinstance(command_id, str) and command_id:
            ok = params.get("ok") is True
            complete(session_id, command_id, ok, params.get("result") if ok else params.get("error"))
    return None


def mock_switch(query, body):
    body = body or {}
    if "no_key" in body:
        SWITCHES["no_key"] = bool(body["no_key"])
    if body.get("reset"):
        with LOCK:
            LANES.clear()
            TICKETS.clear()
            WAITING.clear()
        SWITCHES["no_key"] = False
    with LOCK:
        lanes = {sid: {"transport": lane["transport"], "connected": live(lane)} for sid, lane in LANES.items()}
    return 200, {"ok": True, **SWITCHES, "lanes": lanes}


# ── The mock's pages (US demo data) ────────────────────────────────────────

PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title><style>
body{{font:16px -apple-system,system-ui,sans-serif;margin:0;background:#f6f7f9;color:#1d1f23}}
header{{background:#1d1f23;color:#fff;padding:14px 20px;font-weight:600}}
main{{max-width:520px;margin:28px auto;padding:0 20px}}
.card{{background:#fff;border:1px solid #e3e5e8;border-radius:12px;padding:20px}}
label{{display:block;font-size:14px;margin:14px 0 6px}}
input{{width:100%;box-sizing:border-box;font-size:16px;padding:10px;border:1px solid #c9ccd1;border-radius:8px}}
button{{margin-top:18px;width:100%;font-size:16px;padding:11px;border:0;border-radius:8px;background:#2f6fde;color:#fff}}
li{{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid #eceef1}}
.failed{{color:#c4321f;font-weight:600}} .ready{{color:#1f8a4c;font-weight:600}}
@media (prefers-color-scheme: dark){{body{{background:#16171a;color:#eceef1}}.card{{background:#202226;border-color:#2c2f34}}li{{border-color:#2c2f34}}input{{background:#16171a;color:#eceef1;border-color:#3a3d43}}}}
</style></head><body><header>Acme Cloud</header><main>{body}</main></body></html>"""

SIGN_IN = """<div class="card"><h1>Sign in</h1><form method="post" action="/mock-web/session">
<label for="email">Email</label><input id="email" name="email" type="email" autocomplete="username" value="sam@example.com">
<label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password">
<button type="submit">Sign In</button></form></div>"""

DASHBOARD = """<h1>Deploys</h1><div class="card"><ul style="list-style:none;padding:0;margin:0">
<li><a href="#web-app">web-app</a><span class="ready">Ready · 2 min ago</span></li>
<li><a href="#api">api</a><span class="failed">Failed · next build ran out of memory</span></li>
<li><a href="#docs">docs</a><span class="ready">Ready · yesterday</span></li></ul></div>
<p>Signed in as sam@example.com</p>"""


CHECKOUT = """<h1>Checkout</h1><div class="card"><p>Acme Supply · 2 items · $48.20</p><form method="post" action="/mock-web/session">
<label for="name">Name on card</label><input id="name" name="cc-name" autocomplete="cc-name">
<label for="number">Card number</label><input id="number" name="cardnumber" autocomplete="cc-number" inputmode="numeric">
<label for="exp">Expires</label><input id="exp" name="exp" autocomplete="cc-exp" placeholder="MM/YY">
<label for="cvc">Security code</label><input id="cvc" name="cvc" autocomplete="cc-csc" inputmode="numeric">
<label for="note">Note for the seller</label><input id="note" name="note">
<button type="button">Place Order</button></form></div>"""


def page(handler, title, body, status=200, extra=None):
    data = PAGE.format(title=title, body=body).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    for key, value in (extra or {}).items():
        handler.send_header(key, value)
    handler.end_headers()
    handler.wfile.write(data)
    return True


def redirect(handler, location, cookie=None):
    handler.send_response(303)
    handler.send_header("Location", location)
    if cookie:
        handler.send_header("Set-Cookie", cookie)
    handler.send_header("Content-Length", "0")
    handler.end_headers()
    return True


def signed_in(handler):
    return "acme_session=demo" in (handler.headers.get("Cookie") or "")


def web_sign_in(handler, query):
    return page(handler, "Sign in · Acme Cloud", SIGN_IN)


def web_session(handler, query):
    # The form's body (the password) is read and dropped, never logged or kept.
    length = int(handler.headers.get("Content-Length") or 0)
    if length:
        handler.rfile.read(length)
    return redirect(handler, "/mock-web/dashboard", "acme_session=demo; Path=/mock-web; HttpOnly; SameSite=Lax")


def web_dashboard(handler, query):
    if not signed_in(handler):
        return redirect(handler, "/mock-web/sign-in")
    return page(handler, "Deploys · Acme Cloud", DASHBOARD)


def web_checkout(handler, query):
    return page(handler, "Checkout · Acme Supply", CHECKOUT)


def web_slow(handler, query):
    time.sleep(45)
    return page(handler, "Slow · Acme Cloud", "<p>Finally.</p>")


# ── Scripted turns ─────────────────────────────────────────────────────────

def matches(text):
    return "in the app" in (text or "").lower()


def own_browser(action, args):
    """What Hermes's own browser answers when no controller is bound."""
    if action == "browser_navigate":
        url = args.get("url", "")
        if "/mock-web/" in url:
            return json.dumps({"success": True, "url": GATEWAY_URL[0] + "/mock-web/sign-in", "title": "Sign in · Acme Cloud"})
        return json.dumps({"success": True, "url": url, "title": ""})
    if action == "browser_snapshot":
        return json.dumps({"success": True, "snapshot": '- heading "Sign in" [level=1]\n- textbox "Email" [@e1]\n- textbox "Password" (password) [@e2]\n- button "Sign In" [@e3]',
                           "element_count": 3})
    return json.dumps({"success": True})


class Steps:
    """A turn's browser steps on either transport, through the app when it's the chat's browser."""

    def __init__(self, session_id, start, done, stop):
        self.session_id, self.start, self.done, self.stop = session_id, start, done, stop
        self.used_own = False

    def run(self, action, args):
        call = f"call_{uuid.uuid4().hex[:8]}"
        self.start(call, action, args)
        started = time.time()
        result = dispatch(self.session_id, action, args, call, self.stop)
        if result is None:
            self.used_own = True
            time.sleep(0.6)
            result = own_browser(action, args)
        self.done(call, action, args, result, time.time() - started)
        try:
            return json.loads(result)
        except ValueError:
            return {"success": True, "text": result}


def script(steps, text):
    """The browse itself; returns the reply."""
    lower = text.lower()
    base = GATEWAY_URL[0]
    held = "You have the browser right now. Hand it back when you're done and tell me to carry on."
    if "router" in lower:
        result = steps.run("browser_navigate", {"url": "http://192.168.1.1/"})
        if result.get("code") == "human_has_control":
            return held
        if result.get("success") is False:
            return "Your router's page is on your own network, so I need you to open it in the browser here first. Then ask me again."
        return "Your router's page is open."
    if "checkout" in lower:
        return checkout(steps)
    if "slow" in lower:
        result = steps.run("browser_navigate", {"url": base + "/mock-web/slow"})
        if result.get("code") == "human_has_control":
            return held
        if result.get("success") is False or "error" in result:
            return "That page didn't finish loading, so I stopped. Want me to try again in a bit?"
        return "The page loaded."
    result = steps.run("browser_navigate", {"url": base + "/mock-web/dashboard"})
    if result.get("code") == "human_has_control":
        return held
    if "error" in result and result.get("success") is not False:
        return "I couldn't use the browser in the app just now, so I didn't open Acme Cloud."
    snapshot = steps.run("browser_snapshot", {})
    if snapshot.get("code") == "human_has_control":
        return held
    if snapshot.get("sign_in") or "(password" in str(snapshot.get("snapshot", "")):
        fill = {"success": False, "error_type": "supervisor_required",
                "error": "Vault fill needs Hermes's own supervised browser; this page is in the user's app browser. Ask the user to sign in themselves."}
        steps.vault(fill)
        WAITING[steps.session_id] = "sign-in"
        return ("Acme Cloud wants you to sign in, and Passwords can't fill a page in the app's browser. "
                "Sign in there, then tell me to carry on.")
    return deploys(steps)


def checkout(steps):
    """A checkout the person fills: Hermes never sees the card, only that it's filled."""
    base = GATEWAY_URL[0]
    result = steps.run("browser_navigate", {"url": base + "/mock-web/checkout"})
    if result.get("code") == "human_has_control":
        return "You have the browser right now. Hand it back when you're done and tell me to carry on."
    snapshot = str(steps.run("browser_snapshot", {}).get("snapshot", ""))
    if "(filled)" not in snapshot:
        steps.vault({"success": False, "error_type": "supervisor_required",
                     "error": "Vault fill needs Hermes's own supervised browser; this page is in the user's app browser. Ask the user to enter the card themselves."})
        WAITING[steps.session_id] = "checkout"
        return "Your order is ready at Acme Supply. Enter your card in the app's browser yourself, then tell me to carry on."
    return paid(steps)


def paid(steps):
    WAITING.pop(steps.session_id, None)
    snapshot = steps.run("browser_snapshot", {})
    text = str(snapshot.get("snapshot", ""))
    if snapshot.get("code") == "human_has_control":
        return "You took over the browser. Hand it back and tell me to carry on."
    if text.count("(filled)") >= 2:
        return "The card is in, and I can't see it. I stopped before Place Order: that tap is yours."
    return "The card fields still look empty, so I didn't go on."


def deploys(steps):
    WAITING.pop(steps.session_id, None)
    time.sleep(0.8)
    steps.run("browser_scroll", {"direction": "down"})
    time.sleep(0.8)
    full = steps.run("browser_snapshot", {"full": True})
    if full.get("code") == "human_has_control":
        return "You took over the browser, so I stopped reading. Hand it back and tell me to carry on."
    text = str(full.get("snapshot", ""))
    if "api" in text or steps.used_own:
        return ("Two of your three deploys are fine. **api** failed: `next build` ran out of memory. "
                "web-app went out 2 minutes ago, and docs yesterday.")
    return "I'm on the dashboard, but I couldn't read the deploys."


def vault_step(start, done, result):
    # Hermes's browser_vault in a page its supervisor doesn't hold (`tools/browser_vault_tool.py`).
    call, args = f"call_{uuid.uuid4().hex[:8]}", {"action": "fill", "handle": "vault_2a4c6e8f0b1d"}
    start(call, "browser_vault", args)
    time.sleep(0.2)
    done(call, "browser_vault", args, json.dumps(result), 0.2)


def carries_on(session_id, text):
    lower = (text or "").lower()
    return session_id in WAITING and any(k in lower for k in ("carry on", "continue", "signed in", "done"))


def carry_on(steps):
    return paid(steps) if WAITING.get(steps.session_id) == "checkout" else deploys(steps)


def socket_turn(sid, text):
    runtime = B["RUNTIME"][sid]
    kind_chat = runtime.get("kind") == "chat"
    stored = runtime["stored"] if kind_chat else B["ensure_row"](sid)
    B["store_row"](sid, stored, "user", text)
    B["emit"](sid, "session.info", {"running": True})
    B["emit"](sid, "message.start", {})

    def start(call, name, args):
        B["store_row"](sid, stored, "assistant", "", finish_reason="tool_calls",
                       tool_calls=[{"id": call, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}])
        B["emit"](sid, "tool.start", {"tool_id": call, "name": name, "context": args.get("url") or "", "args": args})

    def done(call, name, args, result, seconds):
        B["store_row"](sid, stored, "tool", result, tool_call_id=call, tool_name=name)
        B["emit"](sid, "tool.complete", {"tool_id": call, "name": name, "args": args, "duration_s": round(seconds, 2),
                                         **B["tool_complete_fields"](name, result, seconds)})

    steps = Steps(sid, start, done, lambda: bool(B["RUNTIME"][sid].get("interrupt")))
    steps.vault = lambda result: vault_step(start, done, result)
    time.sleep(0.3)
    answer = carry_on(steps) if carries_on(sid, text) else script(steps, text)
    if kind_chat:
        C_HOOKS["stream"](sid, answer)
    else:
        B["stream"](sid, answer)
    B["finish_any"](sid, stored, answer)


C_HOOKS = {}


def run_turn(run):
    """/v1/runs (server.py): the same browse with the run's events."""
    sid = run.session_id
    G.add_message(sid, "user", run.text)
    run.status = "running"

    def start(call, name, args):
        run.emit("tool.started", tool=name, preview=args.get("url") or "")

    def done(call, name, args, result, seconds):
        failed_step = '"error"' in result and '"success": true' not in result
        run.emit("tool.completed", tool=name, duration=round(seconds, 3), error=failed_step, preview=result[:500])

    steps = Steps(sid, start, done, run.stop.is_set)
    steps.vault = lambda result: vault_step(start, done, result)
    answer = carry_on(steps) if carries_on(sid, run.text) else script(steps, run.text)
    out, _ = G.stream_text(run, answer)
    G.add_message(sid, "assistant", out, finish_reason="stop")
    run.output = out
    run.status = "completed"
    run.emit("run.completed", completed=True, partial=False, interrupted=False, output=out,
             usage={"input_tokens": 1830, "output_tokens": 212, "total_tokens": 2042})


def install(backend_globals, browser_module, gateway_module=None, chats_module=None, gateway_port=None):
    global B, G, BROWSER
    B, G, BROWSER = backend_globals, gateway_module, browser_module
    methods = B["METHODS"]
    methods["browser.controller.register"] = method_register
    methods["browser.controller.result"] = method_result
    methods["browser.controller.heartbeat"] = method_heartbeat
    methods["browser.controller.detach"] = method_detach
    B["HTTP_ROUTES"][("POST", "/api/mock/browser-control")] = mock_switch
    original_start = B["start_turn"]

    def start_turn(sid, text, runner):
        if matches(text) or carries_on(sid, text):
            return original_start(sid, text, socket_turn)
        return original_start(sid, text, runner)

    B["start_turn"] = start_turn
    if chats_module is not None:
        C_HOOKS["stream"] = chats_module.stream
    if G is None:
        return
    GATEWAY_URL[0] = f"http://127.0.0.1:{gateway_port}"
    G.ROUTES[("POST", "/v1/browser-control/register")] = http_register
    G.ROUTES[("GET", "/v1/browser-control/ws")] = http_socket
    G.ROUTES[("GET", "/mock-web/sign-in")] = web_sign_in
    G.ROUTES[("POST", "/mock-web/session")] = web_session
    G.ROUTES[("GET", "/mock-web/dashboard")] = web_dashboard
    G.ROUTES[("GET", "/mock-web/slow")] = web_slow
    G.ROUTES[("GET", "/mock-web/checkout")] = web_checkout
    original_turn = G.agent_turn

    def agent_turn(run):
        if not (matches(run.text) or carries_on(run.session_id, run.text)):
            return original_turn(run)
        try:
            run_turn(run)
        finally:
            run.finish()

    G.agent_turn = agent_turn
