"""End-to-end tests for hermes-app-push against the real Hermes Agent code.

Run with the Hermes venv from this folder's parent:

    HERMES_SOURCE=~/.hermes/hermes-agent ~/.hermes/hermes-agent/.venv/bin/python -m pytest Tools/hermes-app-push/tests --import-mode=importlib

Each test session gets a throwaway HERMES_HOME with only this plugin enabled, a fake relay on
localhost, and a device key pair; nothing touches ~/.hermes.
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent")).expanduser()
SECRET = "sk-FAKE-not-a-real-key-0000000000000000"  # test fixture, never a real key

HOME = Path(tempfile.mkdtemp(prefix="hermes-app-push-test-"))
# The real install's data (the plugin runs on this Mac's gateway): the tests must leave it as it was.
REAL_DATA = Path.home() / ".hermes" / "plugin-data" / "hermes-app-push"


def _snapshot(folder: Path) -> dict[str, float]:
    """Files and their mtimes, minus the running gateway's in-flight atomic writes (``.state-*``)."""
    found = {}
    for p in folder.rglob("*") if folder.exists() else []:
        if p.name.startswith(".state-"):
            continue
        try:
            if p.is_file():
                found[str(p)] = p.stat().st_mtime
        except FileNotFoundError:
            continue
    return found


REAL_BEFORE = _snapshot(REAL_DATA)
os.environ["HERMES_HOME"] = str(HOME)
sys.path.insert(0, str(SOURCE))


class FakeRelay(BaseHTTPRequestHandler):
    pushes: list[dict] = []
    raw: list[str] = []
    installations = 0
    dead_tokens: set[str] = set()

    def log_message(self, *args):
        pass

    def _json(self, status: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        if self.path == "/v1/installations":
            FakeRelay.installations += 1
            return self._json(201, {"installation_id": f"inst-{FakeRelay.installations}", "secret": "relay-secret-1"})
        if self.path == "/v1/push":
            if self.headers.get("Authorization") != "Bearer relay-secret-1":
                return self._json(401, {"error": "unknown installation"})
            FakeRelay.raw.append(body)
            request = json.loads(body)
            FakeRelay.pushes.append(request)
            if request["token"] in FakeRelay.dead_tokens:
                return self._json(200, {"status": 410, "reason": "Unregistered"})
            return self._json(200, {"status": 200, "apns_id": f"apns-{len(FakeRelay.pushes)}"})
        self._json(404, {})


@pytest.fixture(scope="session")
def relay_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeRelay)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


@pytest.fixture(scope="session")
def hermes(relay_url):
    """Install the plugin into the throwaway home and load it through Hermes's plugin manager."""
    target = HOME / "plugins" / "hermes-app-push"
    shutil.copytree(PLUGIN_DIR, target, ignore=shutil.ignore_patterns("tests", "__pycache__"))
    (HOME / "config.yaml").write_text(
        "plugins:\n  enabled: [hermes-app-push]\n  entries:\n    hermes-app-push:\n      settings:\n"
        f"        relay_url: {relay_url}\n        gateway_name: Test Mac\n"
        "approvals:\n  timeout: 3\n")
    from hermes_cli import plugins
    plugins.discover_plugins(force=True)
    handler = plugins.get_plugin_command_handler("app-push")
    assert handler is not None, "the /app-push command wasn't registered"
    return plugins, handler


def make_device(handler, name="iphone", **prefs):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    key = X25519PrivateKey.generate()
    public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,
                                                            serialization.PublicFormat.Raw)).decode()
    token = os.urandom(32).hex()
    answer = json.loads(handler("register " + json.dumps({
        "device_id": f"dev-{name}", "token": token, "topic": "co.caffeinatedcode.hermes.dev",
        "environment": "development", "public_key": public, "platform": "ios", "name": name,
        "preferences": prefs})))
    assert answer["ok"], answer
    return key, token


def relay_allowlists() -> tuple[set[str], set[str]]:
    """The relay's own kind-only titles and categories (``Relay/convex/validate.ts``): a notice the
    plugin sends that the relay doesn't list never reaches a phone."""
    import re
    path = PLUGIN_DIR.parents[1] / "Relay" / "convex" / "validate.ts"
    if not path.is_file():  # a standalone checkout of the plugin, without the app's relay beside it
        pytest.skip(f"the relay's allowlists aren't checked out beside the plugin ({path})")
    source = path.read_text()
    titles = re.search(r"ALERT_TITLES = new Set\(\[(.*?)\]\)", source, re.S).group(1)
    categories = re.search(r"CATEGORIES = new Set\(\[(.*?)\]\)", source, re.S).group(1)
    return set(re.findall(r'"([^"]+)"', titles)), set(re.findall(r'"([^"]+)"', categories))


def test_every_notice_kind_is_one_the_relay_forwards(hermes):
    module = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    titles, categories = relay_allowlists()
    for kind, (category, _level, _relevance, fallback) in module.KINDS.items():
        assert fallback in titles, f"{kind}: the relay refuses {fallback!r}"
        assert category in categories, f"{kind}: the relay refuses category {category!r}"
    assert module.MEMORY in categories


def wait_for(predicate, timeout=6.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = predicate()
        if found:
            return found
        time.sleep(0.05)
    raise AssertionError("timed out waiting")


def pushes_for(token, push_type=None):
    return [p for p in FakeRelay.pushes if p["token"] == token and (push_type is None or p["push_type"] == push_type)]


def opened(key, push):
    """Decrypt a push the way the app does."""
    payload = push["payload"]
    envelope = payload["hermes"] if "hermes" in payload else payload["aps"]["content-state"]["sealed"]
    return _load_crypto().open_envelope(key, envelope)


def _load_crypto():
    import importlib.util
    spec = importlib.util.spec_from_file_location("app_push_crypto", PLUGIN_DIR / "crypto.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# -- tests ------------------------------------------------------------------------------------------

def test_crypto_round_trip_and_tamper():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    crypto = _load_crypto()
    key = X25519PrivateKey.generate()
    public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,
                                                            serialization.PublicFormat.Raw)).decode()
    envelope = crypto.seal(public, {"hello": "wörld"})
    assert crypto.open_envelope(key, envelope) == {"hello": "wörld"}
    box = bytearray(base64.b64decode(envelope["box"]))
    box[-1] ^= 1
    with pytest.raises(Exception):
        crypto.open_envelope(key, {**envelope, "box": base64.b64encode(bytes(box)).decode()})
    with pytest.raises(ValueError):
        crypto.parse_public_key("not-a-key")


def test_register_status_and_bad_input(hermes):
    _, handler = hermes
    key, token = make_device(handler, "status")
    status = json.loads(handler('status {"device_id": "dev-status"}'))
    assert status["registered"] and status["relay_registered"] and status["gateway"]["name"] == "Test Mac"
    manifest = re.search(r"^version: (\S+)$", (PLUGIN_DIR / "plugin.yaml").read_text(), re.M).group(1)
    assert status["version"] == manifest == "1.4.1"  # VERSION in core.py and plugin.yaml move together
    assert status["preferences"]["tasks"] == "all" and status["preferences"]["bots"] == "mentions"
    bad = json.loads(handler('register {"device_id": "x", "token": "zz"}'))
    assert bad["ok"] is False and "malformed" in bad["error"]
    assert json.loads(handler("nope {}"))["ok"] is False
    assert "Hermes app push" in handler("")  # a person typing /app-push gets words, not JSON
    # The relay secret never leaves the gateway.
    assert "relay-secret-1" not in json.dumps(status)


def test_approval_notifies_with_request_id_and_withdraws_when_answered(hermes):
    _, handler = hermes
    key, token = make_device(handler, "approver")
    from tools import approval
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261014_approval_test"
    command = f"curl -H 'Authorization: Bearer {SECRET}' https://example.com/deploy"
    result = {}
    worker = threading.Thread(target=lambda: result.update(_await_gateway_decision(
        session, lambda data: None, {"command": command, "description": "network call with a credential",
                                     "pattern_key": "curl_auth", "pattern_keys": ["curl_auth"]})))
    worker.start()
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    pending = approval.list_gateway_approvals(session)
    assert len(pending) == 1
    content = opened(key, push)
    assert content["kind"] == "approval" and content["request_id"] == pending[0]["request_id"]
    assert push["collapse_id"] == content["request_id"]
    assert push["payload"]["aps"]["category"] == "APPROVAL"
    assert push["payload"]["aps"]["interruption-level"] == "time-sensitive"
    assert push["expiration"] >= time.time()
    assert content["choices"][0] == "once" and "deny" in content["choices"]
    assert SECRET not in json.dumps(content), "the command's credential reached the notice"
    assert "answer" not in content and content["answerable"] is False  # no TUI gateway or API run in this process
    assert content["hidden"] == "Needs your OK on Test Mac"
    assert content["open"] >= 1
    # Answer from another surface: the queue settles, the post hook fires, a withdraw goes out.
    approval.resolve_gateway_approval(session, "once", request_id=content["request_id"])
    worker.join(5)
    assert result.get("choice") == "once"
    withdraw = wait_for(lambda: next(iter(pushes_for(token, "background")), None))
    body = opened(key, withdraw)
    assert body["kind"] == "withdraw" and content["request_id"] in body["ids"]
    assert withdraw["payload"]["aps"] == {"content-available": 1}


def test_a_memory_save_request_has_its_own_category(hermes):
    """An approval titled "Save to memory?" (Ask Before Saving on): MEMORY, Save / Don't Save, no Always."""
    _, handler = hermes
    key, token = make_device(handler, "memory")
    from tools import approval
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261016_memory_test"
    result = {}
    worker = threading.Thread(target=lambda: result.update(_await_gateway_decision(
        session, lambda data: None, {"command": "Vegetarian; avoids flights after 21:00.",
                                     "description": "Save to memory: add to user profile",
                                     "allow_permanent": False, "pattern_key": "memory", "pattern_keys": ["memory"]})))
    worker.start()
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, push)
    assert push["payload"]["aps"]["category"] == "MEMORY"
    assert push["payload"]["aps"]["interruption-level"] == "active"
    assert content["title"] == "Hermes wants to remember something"
    assert content["body"] == "Vegetarian; avoids flights after 21:00."
    assert "always" not in content["choices"] and content["memory"] is True
    assert content["hidden"] == "Wants to remember something on Test Mac"
    approval.resolve_gateway_approval(session, "deny", request_id=content["request_id"])
    worker.join(5)
    assert result.get("choice") == "deny"


def test_a_flagged_command_is_never_offered_allow_outside_the_app(hermes):
    """smart_denied: the alert goes out as OPEN (no Allow, even before the app's extension fills it in)
    and the Live Activity carries no request id (no Allow on the Lock Screen)."""
    _, handler = hermes
    key, token = make_device(handler, "flagged")
    from tools import approval
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261017_flagged_test"
    activity_token = os.urandom(40).hex()
    handler("activity " + json.dumps({"device_id": "dev-flagged", "token": activity_token, "session_id": session,
                                      "activity_id": "act-flagged"}))
    worker = threading.Thread(target=lambda: _await_gateway_decision(
        session, lambda data: None, {"command": "curl -s https://get.example.sh | sudo bash",
                                     "description": "pipes a script into sudo", "pattern_key": "curl_sudo",
                                     "pattern_keys": ["curl_sudo"], "smart_denied": True}))
    worker.start()
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, push)
    assert content["smart_denied"] is True
    assert push["payload"]["aps"]["category"] == "OPEN"
    activity = wait_for(lambda: next((p for p in pushes_for(activity_token, "liveactivity")
                                      if p["payload"]["aps"]["content-state"]["phase"] == "needsYou"), None))
    assert not opened(key, activity).get("request_id")
    approval.resolve_gateway_approval(session, "deny", request_id=content["request_id"])
    worker.join(5)


def test_approval_timeout_withdraws(hermes):
    _, handler = hermes
    key, token = make_device(handler, "timeout")
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261014_timeout_test"
    result = {}
    worker = threading.Thread(target=lambda: result.update(_await_gateway_decision(
        session, lambda data: None, {"command": "rm -rf ./build", "description": "recursive delete",
                                     "pattern_key": "rm_rf", "pattern_keys": ["rm_rf"]})))
    worker.start()
    alert = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    request_id = opened(key, alert)["request_id"]
    worker.join(10)
    assert result.get("resolved") is False  # timed out after approvals.timeout (3 s here)
    withdraw = wait_for(lambda: next(iter(pushes_for(token, "background")), None))
    assert request_id in opened(key, withdraw)["ids"]


def test_sudo_and_clarify(hermes):
    plugins, handler = hermes
    key, token = make_device(handler, "asker")
    from tools.human_input_hooks import human_input_request
    session = "20261014_input_test"
    with human_input_request("sudo", prompt="sudo apt-get install ripgrep", session_key=session) as human:
        alert = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
        content = opened(key, alert)
        assert content["kind"] == "password" and content["category"] == "OPEN"
        assert alert["payload"]["aps"]["alert"]["title"] == "Hermes needs a password"
        human.outcome = "provided"
    withdraw = wait_for(lambda: next(iter(pushes_for(token, "background")), None))
    assert content["request_id"] in opened(key, withdraw)["ids"]

    plugins.invoke_hook("pre_tool_call", tool_name="clarify", session_id=session, args={"questions": [
        {"question": "Which branch should I ship?", "choices": ["main", "release/1.3", "hotfix", "other"]}]})
    with human_input_request("clarify", prompt="Which branch should I ship?", session_key=session) as human:
        alert = wait_for(lambda: next((p for p in pushes_for(token, "alert")
                                       if opened(key, p)["kind"] == "question"), None))
        content = opened(key, alert)
        assert content["choices"] == ["main", "release/1.3", "hotfix"]  # at most three as actions
        assert content["questions"][0]["choices"][-1] == "other"          # the content extension shows all
        assert alert["payload"]["aps"]["category"] == "QUESTION"
        human.outcome = "submitted"


def test_reply_respects_presence_and_duration(hermes):
    plugins, handler = hermes
    key, token = make_device(handler, "replier", reply_after=0)
    session = "20261014_reply_test"
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-1")
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="turn-1",
                        assistant_response="**Done.** Freed 12 GB.\n\nDetails follow.")
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-1", completed=True)
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, push)
    assert content["kind"] == "reply" and content["body"].startswith("Done. Freed 12 GB.")
    assert push["payload"]["aps"]["category"] == "REPLY" and push["payload"]["aps"]["interruption-level"] == "active"

    # The same chat on screen: no notice.
    handler('presence ' + json.dumps({"device_id": "dev-replier", "state": "foreground", "session_id": session}))
    before = len(pushes_for(token))
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-2")
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="turn-2", assistant_response="Again.")
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-2", completed=True)
    time.sleep(0.5)
    assert len(pushes_for(token)) == before
    # A short turn with the default 30 s threshold: no notice either.
    key2, token2 = make_device(handler, "default-threshold")
    plugins.invoke_hook("pre_llm_call", session_id="other", turn_id="turn-3")
    plugins.invoke_hook("post_llm_call", session_id="other", turn_id="turn-3", assistant_response="Quick.")
    plugins.invoke_hook("on_session_end", session_id="other", turn_id="turn-3", completed=True)
    time.sleep(0.5)
    assert not pushes_for(token2, "alert")


def test_live_activity_updates(hermes):
    plugins, handler = hermes
    key, token = make_device(handler, "activity")
    session = "20261014_activity_test"
    activity_token = os.urandom(40).hex()
    handler("activity " + json.dumps({"device_id": "dev-activity", "token": activity_token, "session_id": session,
                                      "activity_id": "act-1"}))
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-la")
    first = wait_for(lambda: next(iter(pushes_for(activity_token, "liveactivity")), None))
    assert first["topic"] == "co.caffeinatedcode.hermes.dev.push-type.liveactivity"
    assert first["payload"]["aps"]["content-state"]["phase"] == "working"
    assert opened(key, first)["step"] == "Thinking"
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-la", completed=False, interrupted=True)
    end = wait_for(lambda: next((p for p in pushes_for(activity_token) if p["payload"]["aps"]["event"] == "end"), None))
    assert end["payload"]["aps"]["content-state"]["phase"] == "done" and "dismissal-date" in end["payload"]["aps"]


def test_cron_delivery_and_dead_tokens(hermes):
    _, handler = hermes
    key, token = make_device(handler, "cron", tasks="failures")
    push = None
    for name, module in list(sys.modules.items()):
        if name.endswith("hermes_app_push") or name.endswith("hermes-app-push"):
            push = getattr(module, "_instance")()
    assert push is not None
    import asyncio
    ok = asyncio.run(push.send_cron("all", "Cronjob Response: Nightly backup\n(job_id: job_9)\n-------------\n\nAll good."))
    assert ok["success"]
    assert not pushes_for(token, "alert")  # failures only
    failed = asyncio.run(push.send_cron("fail", "Cronjob Response: Nightly backup\n(job_id: job_9)\n----\n\ndisk full"))
    assert failed["success"]
    alert = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, alert)
    assert content["kind"] == "task_failed" and content["title"] == "Nightly backup" and content["job_id"] == "job_9"
    assert alert["payload"]["aps"]["category"] == "TASK" and alert["payload"]["aps"]["interruption-level"] == "active"
    # APNs says the token is gone: the device is forgotten.
    FakeRelay.dead_tokens.add(token)
    asyncio.run(push.send_cron("fail", "Cronjob Response: Again\n(job_id: job_9)\n----\n\nstill full"))
    assert "dev-cron" not in push.store.devices()


def test_relay_never_sees_content():
    """Every request the relay received: no command, prompt, reply or secret in the clear."""
    blob = "\n".join(FakeRelay.raw)
    assert FakeRelay.raw, "no pushes were sent"
    for needle in (SECRET, "curl", "rm -rf", "apt-get", "Which branch", "Freed 12 GB", "Nightly backup", "disk full",
                   "Test Mac", "Vegetarian"):
        assert needle not in blob, f"{needle!r} reached the relay"
    allowed_titles, allowed_categories = relay_allowlists()
    for push in FakeRelay.pushes:
        aps = push["payload"].get("aps", {})
        alert = aps.get("alert")
        if alert:
            assert alert["title"] in allowed_titles, f"the relay refuses the title {alert['title']!r}"
            if push["push_type"] == "liveactivity":
                assert "category" not in aps, "the relay refuses a category on a Live Activity"
            else:
                assert aps["category"] in allowed_categories, f"the relay refuses the category {aps['category']!r}"



def _core_module():
    """The plugin as Hermes loaded it from the throwaway home (never the source tree's copy, which was
    imported before HERMES_HOME pointed at the throwaway home)."""
    home = os.path.realpath(HOME)
    return next(m for m in list(sys.modules.values())
                if os.path.realpath(str(getattr(m, "__file__", "") or "")).startswith(home)
                and str(m.__file__).endswith(os.path.join("hermes-app-push", "core.py")))


def test_answer_routes_and_live_presence(hermes, monkeypatch):
    plugins, handler = hermes
    core = _core_module()
    monkeypatch.setitem(sys.modules, "gateway.platforms.api_server", types.ModuleType("api_server"))
    assert core._answer_route("run_0123abcd") == {"via": "run", "run_id": "run_0123abcd"}
    assert core._answer_route("20261014_x") is None
    monkeypatch.setitem(sys.modules, "tui_gateway", types.ModuleType("tui_gateway"))
    assert core._answer_route("20261014_x") == {"via": "socket", "session_id": "20261014_x"}

    # A Mac that hears some chats over its own socket gets pushes only for the others.
    key, token = make_device(handler, "mac-live", reply_after=0)
    handler("presence " + json.dumps({"device_id": "dev-mac-live", "state": "running", "live": ["chat-live"]}))
    for session in ("chat-live", "chat-other"):
        plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=f"t-{session}")
        plugins.invoke_hook("post_llm_call", session_id=session, turn_id=f"t-{session}", assistant_response="Done.")
        plugins.invoke_hook("on_session_end", session_id=session, turn_id=f"t-{session}", completed=True)
    wait_for(lambda: pushes_for(token, "alert"))
    time.sleep(0.5)
    assert [opened(key, p)["session_id"] for p in pushes_for(token, "alert")] == ["chat-other"]


def test_a_bots_own_turns_skip_the_reply_threshold(hermes):
    """A routine's output and another Bot's message start turns in a Bot Chat that nobody waits on:
    however quick, a routine's notifies (Scheduled tasks), a Bot-to-Bot exchange only when it
    mentions the person (Bots: mentions, the default)."""
    plugins, handler = hermes
    key, token = make_device(handler, "bot-chats")  # default 30 s threshold
    session = "20261017_bot_chat"

    def turn(turn_id, user_message, answer):
        plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=turn_id, platform="tui",
                            user_message=user_message)
        plugins.invoke_hook("post_llm_call", session_id=session, turn_id=turn_id, assistant_response=answer)
        plugins.invoke_hook("on_session_end", session_id=session, turn_id=turn_id, completed=True)

    turn("routine-1", '[Cronjob "growth-summary" output — scheduled job, not the user. Review it, act on '
         'anything that needs action, and summarize for the chat.]\n\nInstalls: 12', "📊 Pulse: two decisions wait for you.")
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, push)
    assert content["kind"] == "reply" and content["body"] == "📊 Pulse: two decisions wait for you."
    assert push["payload"]["aps"]["category"] == "REPLY"

    # Another Bot's message: Bots among themselves stay quiet unless the person is mentioned.
    before = len(pushes_for(token, "alert"))
    turn("dm-1", [{"type": "text", "text": "Message from 🤖 Cofounder (@cofounder): status?"}], "All green.")
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == before
    turn("dm-2", "Message from 🤖 Cofounder (@cofounder): status?", "All green, @everyone can ship.")
    wait_for(lambda: len(pushes_for(token, "alert")) == before + 1)

    # The person's own quick question still waits for the threshold (or for them to walk away).
    turn("own-1", "What's the status?", "All green.")
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == before + 1

    # Scheduled tasks off: a routine's turn is quiet too.
    key2, token2 = make_device(handler, "no-tasks", tasks="off")
    turn("routine-2", '[Cronjob "growth-summary" output — scheduled job, not the user.]\n\nInstalls: 13', "Pulse.")
    wait_for(lambda: len(pushes_for(token, "alert")) == before + 2)
    time.sleep(0.3)
    assert not pushes_for(token2, "alert")


def test_silence_markers_notify_nothing(hermes):
    """A turn that ends in Hermes' silence marker is the agent choosing to say nothing: Hermes
    delivers nothing for it (a routine's "[SILENT] note" included), and neither does the push, though
    a routine's turn otherwise always notifies."""
    plugins, handler = hermes
    key, token = make_device(handler, "silence")
    session = "20261019_bot_chat"

    def turn(turn_id, user_message, answer):
        plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=turn_id, platform="tui",
                            user_message=user_message)
        plugins.invoke_hook("post_llm_call", session_id=session, turn_id=turn_id, assistant_response=answer)
        plugins.invoke_hook("on_session_end", session_id=session, turn_id=turn_id, completed=True)

    routine = '[Cronjob "uptime-watch" output — scheduled job, not the user.]\n\nAll services up.'
    turn("routine-silent", routine, "[SILENT]")
    turn("routine-note", routine, "[SILENT] Nothing changed since the last run.")
    turn("routine-no-reply", routine, "NO_REPLY")
    time.sleep(0.5)
    assert not pushes_for(token, "alert")

    # A routine with something to say still notifies.
    turn("routine-real", routine, "Disk on node 3 is 92% full.")
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    assert opened(key, push)["body"] == "Disk on node 3 is 92% full."


def test_reply_after_walking_away_and_kanban_jobs(hermes):
    plugins, handler = hermes
    key, token = make_device(handler, "walker")  # default 30 s threshold
    session = "20261014_walk_away"
    # Watching the chat when the turn starts, then gone: the reply notifies even though it was quick.
    handler("presence " + json.dumps({"device_id": "dev-walker", "state": "foreground", "session_id": session}))
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="walk-1", platform="api_server")
    handler("presence " + json.dumps({"device_id": "dev-walker", "state": "away"}))
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="walk-1",
                        assistant_response="Freed 42 GB.\nKept the last 7 days.\nNothing else touched.\nMore.")
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="walk-1", completed=True)
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    body = opened(key, push)["body"]
    assert body == "Freed 42 GB.\nKept the last 7 days.\nNothing else touched.\nMore."  # its lines, as lines
    # A subagent's turn and a Telegram chat's turn never notify here.
    before = len(pushes_for(token, "alert"))
    for turn, extra in (("sub-1", {"parent_session_id": session}), ("tg-1", {"platform": "telegram"})):
        handler("presence " + json.dumps({"device_id": "dev-walker", "state": "foreground", "session_id": session}))
        plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=turn, **extra)
        handler("presence " + json.dumps({"device_id": "dev-walker", "state": "away"}))
        plugins.invoke_hook("post_llm_call", session_id=session, turn_id=turn, assistant_response="Done.")
        plugins.invoke_hook("on_session_end", session_id=session, turn_id=turn, completed=True)
    # Nor does a helper finishing on its own, however long it ran: the results turn's reply does.
    plugins.invoke_hook("subagent_stop", parent_session_id=session, child_role="Audit the targets",
                        child_summary="Done.", child_status="completed", duration_ms=600_000)
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == before
    # A board card done (passive) and one that needs you (Time Sensitive, with Reply), on by
    # default. Cards, never tasks: in the app, tasks are scheduled jobs.
    plugins.invoke_hook("kanban_task_completed", task_id="t_1", board="ops", assignee="ada", summary="Rotated the keys.")
    plugins.invoke_hook("kanban_task_blocked", task_id="t_2", board="ops", assignee="ada", reason="Needs the VPN password.")
    wait_for(lambda: len(pushes_for(token, "alert")) >= before + 2)
    done_push, blocked_push = pushes_for(token, "alert")[-2:]
    done, blocked = opened(key, done_push), opened(key, blocked_push)
    assert done["kind"] == "card_done" and done["title"] == "Done" and done["body"] == "Rotated the keys."
    assert done["card_id"] == "t_1" and done["board"] == "ops" and done["thread"] == "board:ops"
    assert blocked["kind"] == "card_needs_you" and blocked["title"].startswith("Ada needs you on")
    assert blocked["body"] == "Needs the VPN password." and blocked["category"] == "CARD"
    assert done_push["payload"]["aps"]["interruption-level"] == "passive"
    assert blocked_push["payload"]["aps"]["interruption-level"] == "time-sensitive"
    for notice in (done, blocked):
        assert "task" not in (notice["title"] + notice.get("subtitle", "") + notice.get("hidden", "")).lower()


def test_held_while_on_screen_then_sent_on_leaving(hermes):
    _, handler = hermes
    key, token = make_device(handler, "holder")
    from tools import approval
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261014_held"
    handler("presence " + json.dumps({"device_id": "dev-holder", "state": "foreground", "session_id": session}))
    worker = threading.Thread(target=lambda: _await_gateway_decision(
        session, lambda data: None, {"command": "rm -rf ./tmp", "description": "recursive delete",
                                     "pattern_key": "rm_rf", "pattern_keys": ["rm_rf"]}))
    worker.start()
    wait_for(lambda: approval.list_gateway_approvals(session))
    time.sleep(0.5)
    assert not pushes_for(token, "alert"), "the chat on screen got a push"
    handler("presence " + json.dumps({"device_id": "dev-holder", "state": "away"}))
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    pending = approval.list_gateway_approvals(session)
    assert opened(key, push)["request_id"] == pending[0]["request_id"]
    approval.resolve_gateway_approval(session, "deny", request_id=pending[0]["request_id"])
    worker.join(5)
    # Leaving again sends nothing more: it was answered.
    handler("presence " + json.dumps({"device_id": "dev-holder", "state": "foreground", "session_id": "x"}))
    handler("presence " + json.dumps({"device_id": "dev-holder", "state": "away"}))
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == 1


def test_chats_kept_current_while_away(hermes, monkeypatch):
    """A device that left the app keeping a chat current gets a background sync when a turn ends there, at
    most once a minute (a change meanwhile goes after it), and nothing for other chats or once it's back."""
    plugins, handler = hermes
    key, token = make_device(handler, "syncer")
    store = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".store"]
    monkeypatch.setattr(store, "SYNC_MIN_INTERVAL", 1)
    session, other = "20261018_sync", "20261018_sync_other"
    handler("presence " + json.dumps({"device_id": "dev-syncer", "state": "away", "sync": [session, other]}))

    def turn(sid, n):
        plugins.invoke_hook("pre_llm_call", session_id=sid, turn_id=f"sync-{n}")
        plugins.invoke_hook("post_llm_call", session_id=sid, turn_id=f"sync-{n}", assistant_response="Done.")
        plugins.invoke_hook("on_session_end", session_id=sid, turn_id=f"sync-{n}", completed=True)

    def syncs():
        return pushes_for(token, "background")

    turn(session, 1)
    push = wait_for(lambda: next(iter(syncs()), None))
    body = opened(key, push)
    assert body["kind"] == "sync" and body["sessions"] == [session] and body["gateway"]["name"] == "Test Mac"
    assert push["payload"]["aps"] == {"content-available": 1} and push["priority"] == 5
    # Another chat changes within the minute: it waits for the minute, then goes.
    turn(other, 2)
    time.sleep(0.3)
    assert len(syncs()) == 1
    held = wait_for(lambda: syncs()[1] if len(syncs()) > 1 else None, timeout=4)
    assert opened(key, held)["sessions"] == [other]
    # A chat it doesn't keep, or the device back in the app: nothing.
    time.sleep(1.1)
    turn("20261018_not_kept", 3)
    handler("presence " + json.dumps({"device_id": "dev-syncer", "state": "foreground", "session_id": "x"}))
    turn(session, 4)
    time.sleep(0.5)
    assert len(syncs()) == 2
    # Unregistering forgets what it kept.
    handler("unregister " + json.dumps({"device_id": "dev-syncer"}))
    assert "dev-syncer" not in _core_module().Store().read()["sync"]


def test_bot_chat_notices_carry_the_profile(hermes, monkeypatch):
    plugins, handler = hermes
    key, token = make_device(handler, "profiles")
    from hermes_cli import profiles
    monkeypatch.setattr(profiles, "get_active_profile_name", lambda: "writer")
    from tools.human_input_hooks import human_input_request
    session = "20261014_bot_chat"
    plugins.invoke_hook("pre_tool_call", tool_name="clarify", session_id=session,
                        args={"questions": [{"question": "Which tone?", "choices": ["Warm", "Dry"]}]})
    with human_input_request("clarify", prompt="Which tone?", session_key=session) as human:
        push = wait_for(lambda: next((p for p in pushes_for(token, "alert")), None))
        human.outcome = "submitted"
    assert opened(key, push)["profile"] == "writer"
    # The store is the gateway process's, whatever profile a hook runs in.
    core = _core_module()
    assert str(core.Store().dir).startswith(os.environ["HERMES_HOME"])


def test_a_bots_own_process_reads_the_roots_devices(monkeypatch):
    """`hermes -p <bot> chat` and cron workers start with HERMES_HOME at the Bot's profile: their
    notices still go to the devices registered with the root."""
    store = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".store"]
    monkeypatch.setenv("HERMES_HOME", str(HOME / "profiles" / "writer"))
    assert Path(store._root_home()).resolve() == HOME.resolve()


def test_never_touches_the_real_hermes_home():
    # The gateway's own plugin may write there meanwhile; a test device never does.
    after = _snapshot(REAL_DATA)
    added = set(after) - set(REAL_BEFORE)
    assert not added, f"tests wrote to {REAL_DATA}: {sorted(added)}"
    # Test devices are "dev-<word>"; a real one is "dev-<uuid>".
    test_device = re.compile(r'"dev-[a-z]+(?:-[a-z]+)*"')
    for path in after:
        if path in REAL_BEFORE and after[path] != REAL_BEFORE[path]:
            assert not test_device.search(Path(path).read_text(errors="ignore")), f"a test device reached {path}"


def test_cards_ready_for_review_and_stopped_once_each(hermes):
    """Hermes fires no hook for a review request or a run that gave up: the gateway's watcher reads
    the boards' events for them, starting from now, and each is sent once, whichever process looks."""
    import sys
    _, handler = hermes
    key, token = make_device(handler, name="board-watch")
    # The copy Hermes's plugin manager loaded (configured with the relay): the one behind /app-push.
    push = sys.modules[handler.__module__]._instance()
    from hermes_cli import kanban_db
    from hermes_cli.kanban_db_boards import create_board
    from hermes_cli.kanban_db_connect import connect_closing
    create_board("cards", name="Cards")
    with connect_closing(board="cards") as conn:
        tid = kanban_db.create_task(conn, title="Ship 1.3 to TestFlight", assignee="default", board="cards")
    push.poll_cards()  # first sight: from now on, no backlog
    assert push.store.read()["card_cursors"]["cards"] >= 1

    def cards():
        return [n for n in (opened(key, p) for p in pushes_for(token, "alert")) if n.get("card_id") == tid]

    with connect_closing(board="cards") as conn:
        assert kanban_db.request_review(conn, tid, summary="Uploaded; notes are in.", force=True)
    push.poll_cards()
    review = wait_for(lambda: cards() and cards()[-1])
    assert review["kind"] == "card_review" and review["title"] == "Ready for review"
    assert review["subtitle"] == "Ship 1.3 to TestFlight" and review["category"] == "BOARD"
    with connect_closing(board="cards") as conn:
        kanban_db._append_event(conn, tid, "gave_up", {"failures": 3, "error": "Build fails: no signing identity."})
        conn.commit()
    push.poll_cards()
    stopped = wait_for(lambda: len(cards()) >= 2 and cards()[-1])
    assert stopped["kind"] == "card_stopped" and stopped["title"] == "Stopped"
    assert stopped["body"] == "Build fails: no signing identity."
    push.poll_cards()
    time.sleep(CARD_SETTLE)
    assert [n["kind"] for n in cards()] == ["card_review", "card_stopped"]  # each once


CARD_SETTLE = 0.5


def test_a_tidy_that_changed_something_notifies_once(hermes):
    """The curator fires no hook: the watcher reads each profile's new run reports, from now on, and
    sends one quiet notice for the newest tidy that changed something."""
    import sys
    from hermes_constants import get_hermes_home
    _, handler = hermes
    key, token = make_device(handler, name="tidy-watch")
    push = sys.modules[handler.__module__]._instance()
    root = get_hermes_home() / "logs" / "curator"

    def write(run: str, report: dict):
        (root / run).mkdir(parents=True, exist_ok=True)
        (root / run / "run.json").write_text(json.dumps(report))

    write("20261001-030000", {"consolidated": [{"name": "old", "into": "new"}], "archived": ["old"]})
    push.poll_tidies()  # first sight: the old report says nothing
    assert push.store.read()["tidy_cursors"]["default"] == "20261001-030000"

    def tidies():
        return [n for n in (opened(key, p) for p in pushes_for(token, "alert")) if n.get("kind") == "tidied"]

    assert not tidies()
    write("20261016-030000", {"consolidated": [], "archived": [], "auto_transitions": {"marked_stale": 0}})
    push.poll_tidies()
    time.sleep(CARD_SETTLE)
    assert not tidies()  # nothing changed, nothing sent
    write("20261016-040000", {
        "consolidated": [{"name": "xcode-test-runner", "into": "ios-testing"}, {"name": "snapshot-tests", "into": "ios-testing"}],
        "pruned": [{"name": "docker-cleanup"}], "archived": ["xcode-test-runner", "snapshot-tests", "docker-cleanup"],
        "auto_transitions": {"archived": 2, "marked_stale": 1}})
    push.poll_tidies()
    notice = wait_for(lambda: tidies() and tidies()[-1])
    assert notice["title"] == "Hermes tidied its skills" and notice["category"] == "OPEN"
    assert notice["body"] == "Merged 2 overlapping skills, archived 3 unused ones and marked 1 as stale."
    assert (notice["merged"], notice["archived"], notice["stale"]) == (2, 3, 1) and "profile" not in notice
    request = [p for p in pushes_for(token, "alert") if opened(key, p).get("kind") == "tidied"][-1]
    assert request["payload"]["aps"]["interruption-level"] == "passive" and "sound" not in request["payload"]["aps"]
    push.poll_tidies()
    time.sleep(CARD_SETTLE)
    assert len(tidies()) == 1  # once


# -- the board watcher: one per process, cheap while quiet ---------------------------------------------------
# A multiplexed gateway imports the plugin once per profile, each copy under its own module name.

def _import_copy(name: str):
    """Import the plugin the way Hermes's loader does, under ``name`` (a profile's module name)."""
    import importlib.util
    for stale in [m for m in sys.modules if m == name or m.startswith(name + ".")]:
        del sys.modules[stale]
    spec = importlib.util.spec_from_file_location(name, PLUGIN_DIR / "__init__.py",
                                                  submodule_search_locations=[str(PLUGIN_DIR)])
    module = importlib.util.module_from_spec(spec)
    module.__package__, module.__path__ = name, [str(PLUGIN_DIR)]
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def copies(monkeypatch):
    """Plugin copies under distinct module names, a fresh process registry, and a watcher let go after."""
    imported: list[str] = []

    def load(name: str):
        imported.append(name)
        return sys.modules[_import_copy(name).__name__ + ".core"]

    monkeypatch.delattr(sys, "_hermes_app_push_watcher", raising=False)
    yield load
    registry = vars(sys).get("_hermes_app_push_watcher")
    if registry is not None:
        thread = registry.get("thread")
        registry["thread"] = None
        registry["wake"].set()
        if thread is not None:
            thread.join(3)
            assert not thread.is_alive(), "the watcher didn't let go"
    for name in imported:
        for stale in [m for m in sys.modules if m == name or m.startswith(name + ".")]:
            del sys.modules[stale]


def _watchers() -> list[threading.Thread]:
    return [t for t in threading.enumerate() if t.name == "app-push-cards" and t.is_alive()]


def test_one_board_watcher_for_every_profile_copy(copies, tmp_path):
    before = set(_watchers())
    core_a, core_b = copies("app_push_profile_a"), copies("app_push_profile_b__home_0123456789ab")
    assert core_a is not core_b and core_a.Push is not core_b.Push
    a = core_a.Push(store=core_a.Store(tmp_path))
    b = core_b.Push(store=core_b.Store(tmp_path))
    a.watch_cards()
    a.watch_cards()  # a reconnect
    b.watch_cards()
    registry = vars(sys)["_hermes_app_push_watcher"]
    started = set(_watchers()) - before
    assert started == {registry["thread"]}, "one watcher per process, whichever copy starts it"
    assert list(registry["members"]) == ["app_push_profile_a", "app_push_profile_b__home_0123456789ab"]
    # Both profiles share the root's store: one look serves both.
    assert core_a._leaders(registry) == [a]
    # A reload imports the copy again: it takes its predecessor's seat, the watcher carries on.
    core_a2 = copies("app_push_profile_a")
    assert core_a2 is not core_a
    a2 = core_a2.Push(store=core_a2.Store(tmp_path))
    a2.watch_cards()
    assert set(_watchers()) - before == started
    assert registry["members"]["app_push_profile_a"] is a2 and len(registry["members"]) == 2
    # A profile whose state lives elsewhere gets its own look.
    other = core_b.Push(store=core_b.Store(tmp_path / "elsewhere"))
    other.watch_cards(key="elsewhere")
    assert core_b._leaders(registry) == [a2, other]


def test_reads_never_take_the_write_lock(copies, tmp_path, monkeypatch):
    import fcntl
    core = copies("app_push_reads")
    store_module = sys.modules["app_push_reads.store"]
    store = core.Store(tmp_path, lock_timeout=0.3)
    store.put_device("dev-reader", {"token": "ab" * 16, "preferences": {}})
    store.open_request("req-1", {"kind": "approval", "session": "s"})
    calls = []
    real_flock = fcntl.flock
    recording = types.SimpleNamespace(LOCK_EX=fcntl.LOCK_EX, LOCK_SH=fcntl.LOCK_SH, LOCK_NB=fcntl.LOCK_NB,
                                      LOCK_UN=fcntl.LOCK_UN,
                                      flock=lambda fd, op: (calls.append(op), real_flock(fd, op))[1])
    monkeypatch.setattr(store_module, "fcntl", recording)
    # Another process (or a stuck thread) holds the write lock.
    with open(store.lock_path, "a+") as holder:
        real_flock(holder, fcntl.LOCK_EX)
        started = time.monotonic()
        assert "dev-reader" in store.devices() and "req-1" in store.open_requests()
        assert store.read()["devices"] and store.presence("dev-reader") is None
        assert time.monotonic() - started < 0.2
        assert calls == [], "a read touched the lock"
        # A write gives up after its deadline instead of parking the thread.
        started = time.monotonic()
        with pytest.raises(store_module.StoreBusy):
            store.put_device("dev-blocked", {"token": "cd" * 16})
        assert 0.25 <= time.monotonic() - started < 2
        assert calls and all(op & fcntl.LOCK_NB for op in calls if op != fcntl.LOCK_UN)
        real_flock(holder, fcntl.LOCK_UN)
    store.put_device("dev-after", {"token": "ef" * 16})
    assert set(store.devices()) == {"dev-reader", "dev-after"}
    # Readers racing a busy writer only ever see a whole file.
    stop = threading.Event()
    bad: list = []

    def churn():
        for i in range(150):
            store.update(lambda s, i=i: s.__setitem__("card_cursors", {"b": i}))
        stop.set()

    worker = threading.Thread(target=churn)
    worker.start()
    while not stop.is_set():
        state = store.read()
        if not isinstance(state.get("devices"), dict) or "dev-after" not in state["devices"]:
            bad.append(state)
    worker.join()
    assert not bad and store.read()["card_cursors"] == {"b": 149}


def test_an_unchanged_state_is_never_rewritten(copies, tmp_path, monkeypatch):
    core = copies("app_push_writes")
    store = core.Store(tmp_path)
    store.update(lambda s: s.__setitem__("card_cursors", {"default": 7}))
    first = store.path.stat()
    writes = []
    real_write = store._write
    monkeypatch.setattr(store, "_write", lambda text: (writes.append(text), real_write(text))[1])
    assert store.update(lambda s: len(s["devices"])) == 0
    store.update(lambda s: s.setdefault("card_cursors", {}).__setitem__("default", 7))  # same value
    store.update(lambda s: s["presence"].pop("nobody", None))
    assert writes == [] and store.path.stat().st_ino == first.st_ino
    store.update(lambda s: s["card_cursors"].__setitem__("default", 8))
    assert len(writes) == 1 and store.read()["card_cursors"]["default"] == 8
    assert store.path.stat().st_ino != first.st_ino  # an atomic replace


def test_quiet_boards_and_tidies_cost_no_lock_and_no_write(hermes, monkeypatch):
    """The watcher's steady state: a lock-free read per look, no flock, no rewrite of the state file."""
    _, handler = hermes
    make_device(handler, name="quiet-watch")
    push = sys.modules[handler.__module__]._instance()
    from hermes_cli import kanban_db
    from hermes_cli.kanban_db_boards import create_board
    from hermes_cli.kanban_db_connect import connect_closing
    create_board("quiet", name="Quiet")
    with connect_closing(board="quiet") as conn:
        tid = kanban_db.create_task(conn, title="Nothing to see", assignee="default", board="quiet")
    push.poll_cards()
    push.poll_tidies()  # cursors for every board and profile now exist
    locks, writes = [], []
    real_locked, real_write = push.store._locked, push.store._write
    monkeypatch.setattr(push.store, "_locked", lambda: (locks.append(1), real_locked())[1])
    monkeypatch.setattr(push.store, "_write", lambda text: (writes.append(1), real_write(text))[1])
    for _ in range(3):
        sent, busy = push._poll_cards()
        push.poll_tidies()
    assert (sent, busy, locks, writes) == (0, False, [], [])
    # A running card keeps the watcher fast, still without a write.
    with connect_closing(board="quiet") as conn:
        conn.execute("UPDATE tasks SET status = 'running' WHERE id = ?", (tid,))
        conn.commit()
    assert push._poll_cards() == (0, True) and writes == []
    with connect_closing(board="quiet") as conn:
        conn.execute("UPDATE tasks SET status = 'todo' WHERE id = ?", (tid,))
        conn.commit()
    assert push._poll_cards() == (0, False)
    # A new event moves the cursor: one locked write, and the boards count as busy.
    with connect_closing(board="quiet") as conn:
        kanban_db._append_event(conn, tid, "commented", {"text": "hi"})
        conn.commit()
    assert push._poll_cards() == (0, True) and len(locks) == 1 and len(writes) == 1
    assert push._poll_cards() == (0, False) and len(writes) == 1


def test_profiles_are_listed_without_reading_each_one(hermes, monkeypatch):
    core = _core_module()
    from hermes_cli import profiles

    def expensive(**_):
        raise AssertionError("list_profiles reads every profile's config")

    monkeypatch.setattr(profiles, "list_profiles", expensive)
    homes = core._profile_homes()
    assert homes[0][0] == "default" and Path(homes[0][1]).resolve() == HOME.resolve()


def test_the_watcher_backs_off_while_idle_and_speeds_up_on_activity(copies):
    core = copies("app_push_pace")
    pace = core.Pace(5, 30)
    assert [pace.after(False) for _ in range(4)] == [10, 20, 30, 30]
    assert pace.after(True) == 5 and pace.after(False) == 10
    pace.configure(2, 8)
    assert pace.interval == 8 and pace.after(True) == 2
    # Settings come from the plugin's config, clamped to sane bounds.
    settings = {"card_poll_seconds": "0.1", "card_idle_poll_seconds": 9999, "tidy_poll_seconds": "soon"}
    push = core.Push(store=core.Store(Path(tempfile.mkdtemp())), config=lambda k, d=None: settings.get(k, d))
    assert push.watch_settings() == (1.0, 600.0, 30.0)
    assert core.Push(store=push.store).watch_settings() == (5.0, 30.0, 30.0)


def test_the_running_watcher_paces_itself(copies):
    """The real watcher loop with a scripted board: fast while busy, doubling while quiet, fast again on
    activity, and a wake (a device registered, a card moved) cuts an idle wait short."""
    core = copies("app_push_loop")
    script = [True, False, False, False, False, True, False]
    looks: list[float] = []
    done = threading.Event()

    class Board:
        store = types.SimpleNamespace(path="board-state", devices=lambda: {"dev-x": {}})

        def watch_settings(self):
            return 0.05, 0.4, 3600

        def _poll_cards(self):
            looks.append(time.monotonic())
            if len(looks) > len(script):
                done.set()
                return 0, False
            return 0, script[len(looks) - 1]

        def poll_tidies(self):
            return 0

    board = Board()
    core.Push.watch_cards(board, key="board")
    assert done.wait(10), "the watcher stopped looking"
    gaps = [b - a for a, b in zip(looks, looks[1:])]
    # Waits after each look: busy 0.05, quiet 0.1, 0.2, 0.4, 0.4 (the cap), busy 0.05, quiet 0.1.
    assert gaps[0] < 0.2 and gaps[1] >= 0.08 and gaps[2] >= 0.15, gaps
    assert gaps[3] >= 0.3 and gaps[4] >= 0.3 and gaps[5] < 0.25, gaps
    # Idle with a long cap: a wake (a device registered, a card moved) brings the next look within the
    # fast pace instead of the idle wait.
    board.watch_settings = lambda: (0.05, 30.0, 3600)
    start = len(looks)

    def wait_looks(count: int, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while len(looks) < count and time.monotonic() < deadline:
            time.sleep(0.002)
        assert len(looks) >= count, "the watcher stopped looking"

    wait_looks(start + 2, 5)  # the idle wait is now 0.8 s and growing
    core._wake()
    wait_looks(start + 3, 3)
    assert looks[start + 2] - looks[start + 1] < 0.5, "a wake didn't bring the next look forward"


def test_widgets_read_as_text_in_notices(hermes):
    """hermes-app-widgets: a scheduled task's inline block reads as its plain text, a reply's directive as
    its alt, and a private widget only as "Hermes sent a widget." (payload-contract.md §9)."""
    notices = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    block = json.dumps({"type": "metric", "v": 1, "id": "w_rev2026a1", "title": "Revenue",
                        "fallback_text": "Revenue: €1,284 so far today (+12% vs last Tuesday)."})
    task = notices.task(job_id="j1", name="Morning brief", gateway_name="Mac", failed=False,
                        text=f"Your brief.\n\n```widget\n{block}\n```")
    assert task.body == "Your brief.\nRevenue: €1,284 so far today (+12% vs last Tuesday)."
    private = json.dumps({"type": "meter", "id": "w_budget26", "sensitivity": "private", "fallback_text": "€1,840 spent"})
    assert "1,840" not in notices.first_lines(f"Budget.\n```widget\n{private}\n```", 4, 400, breaks=True)
    reply = 'Two price drops tonight.\n::widget{id="w_3kq9x2ab" alt="Apartments in Brooklyn: 3 new, 2 price drops"}'
    assert notices.first_lines(reply, 4, 400, breaks=True) == "Two price drops tonight.\nApartments in Brooklyn: 3 new, 2 price drops"


def test_reply_text_reads_in_one_pass(hermes):
    """Replies, room messages and cron output are the agent's words: no pattern may go quadratic on them
    (runs of "[", a long word inside ::widget{…}, unclosed widget fences, blank lines; F28)."""
    notices = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    started = time.monotonic()
    for text in ("[" * 40_000, "::widget{" + "a" * 40_000 + "}", "```widget\n" * 20_000, "\n" * 60_000 + "- x"):
        notices.first_lines(text, 4, 400, breaks=True)
        notices.widget_requests(text)
    assert time.monotonic() - started < 5
    assert notices.plain("Hi [there](http://x.y)\n- item") == "Hi there\n• item"


def test_a_widget_request_notifies_like_an_approval(hermes):
    """hermes-app-widgets: a reply that asks with an approval, a question or a form notifies at once,
    whatever the reply threshold, Open only: "<Bot> needs your OK" with the widget's title, a private
    one only "sent a request". Its claim (an answer from anywhere) withdraws it (docs/notifications.md §2)."""
    plugins, handler = hermes
    key, token = make_device(handler, "widget-requests")  # the default 30 s: a plain short reply stays quiet
    session = "20261018_widget_request"
    approval = json.dumps({"type": "approval", "v": 1, "id": "w_publish01", "rev": 1, "title": "Publish the changelog?",
                           "expires_at": "2099-01-01T00:00:00+00:00", "subject": {"kind": "post", "verb": "Publish"},
                           "consequences": {"affects": ["Blog readers"], "reversible": "yes"}})
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-w1")
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="turn-w1",
                        assistant_response=f"The notes are ready.\n\n```widget\n{approval}\n```")
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-w1", completed=True)
    push = wait_for(lambda: next(iter(pushes_for(token, "alert")), None))
    content = opened(key, push)
    assert content["kind"] == "widget" and content["request_id"] == "w_publish01"
    assert content["title"] == "Hermes needs your OK" and content["body"] == "Publish the changelog?"
    aps = push["payload"]["aps"]
    assert aps["category"] == "OPEN" and aps["interruption-level"] == "time-sensitive"
    assert aps["alert"]["title"] == "Hermes needs your OK" and push["collapse_id"] == "w_publish01"

    # Answered (claimed) on any device: the notice goes.
    plugins.invoke_hook("pre_tool_call", tool_name="widget", session_id=session,
                        args={"op": "claim", "id": "w_publish01", "rev": 1, "action": "approve", "mid": "m1"})
    withdraw = wait_for(lambda: next(iter(pushes_for(token, "background")), None))
    assert "w_publish01" in opened(key, withdraw)["ids"]

    # A private question the widgets plugin stored, named by its directive: no title, only that it came.
    store = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".store"]
    folder = Path(store._root_home()) / "widgets"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "w_slots2026a.json").write_text(json.dumps({"revisions": [
        {"type": "choice", "v": 1, "id": "w_slots2026a", "rev": 1, "title": "Which dentist slot?", "sensitivity": "private",
         "options": [{"id": "a", "label": "Tue 9:00"}, {"id": "b", "label": "Thu 14:00"}]}]}))
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-w2")
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="turn-w2",
                        assistant_response='Two slots are free.\n\n::widget{id="w_slots2026a" alt="Which dentist slot?"}')
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-w2", completed=True)
    second = wait_for(lambda: next((p for p in pushes_for(token, "alert") if opened(key, p).get("request_id") == "w_slots2026a"), None))
    content = opened(key, second)
    assert content["title"] == "Hermes sent a request" and "dentist" not in json.dumps(content).lower()
    assert second["payload"]["aps"]["interruption-level"] == "active"

    # Suggested follow-ups aren't requests: a short reply with them stays quiet.
    suggestions = json.dumps({"type": "choice", "v": 1, "id": "w_suggest01", "title": "Ask next", "style": "suggestions",
                              "options": [{"id": "a", "label": "More"}]})
    before = len(pushes_for(token, "alert"))
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id="turn-w3")
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id="turn-w3",
                        assistant_response=f"Done.\n\n```widget\n{suggestions}\n```")
    plugins.invoke_hook("on_session_end", session_id=session, turn_id="turn-w3", completed=True)
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == before


# -- reading: a chat read anywhere leaves no notifications behind (docs/notifications.md §2, Reading) ------

class Later:
    """Holds the read and badge pushes' timers: each flush waits until the test runs it."""

    def __init__(self):
        self.waiting: list[tuple[float, object, tuple]] = []

    def __call__(self, delay, run, key):
        self.waiting.append((delay, run, key))

    def delays(self, key) -> list[float]:
        return [delay for delay, _run, waiting in self.waiting if waiting == key]

    def run(self) -> int:
        waiting, self.waiting = self.waiting, []
        for _delay, run, _key in waiting:
            run()
        return len(waiting)


@pytest.fixture()
def reading(hermes, monkeypatch):
    """The plugin Hermes loaded, with its read and badge timers held (``Later``)."""
    plugins, handler = hermes
    push = sys.modules[handler.__module__]._instance()
    later = Later()
    monkeypatch.setattr(push, "_later", later)
    yield plugins, handler, push, later
    push._due.clear()


def presence(handler, name, **fields):
    return json.loads(handler("presence " + json.dumps({"device_id": f"dev-{name}", **fields})))


def read(handler, name, chats=(), rooms=()):
    return json.loads(handler("read " + json.dumps({"device_id": f"dev-{name}", "chats": list(chats),
                                                    "rooms": list(rooms)})))


def finish_turn(plugins, session, turn_id, text="Done."):
    plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=turn_id)
    plugins.invoke_hook("post_llm_call", session_id=session, turn_id=turn_id, assistant_response=text)
    plugins.invoke_hook("on_session_end", session_id=session, turn_id=turn_id, completed=True)


def notices_for(key, token):
    """The sealed notices a device was sent (alerts, not badge-only pushes)."""
    return [opened(key, p) for p in pushes_for(token, "alert") if "hermes" in p["payload"]]


def badges_for(token):
    return [p for p in pushes_for(token, "alert") if "hermes" not in p["payload"]]


def reads_for(key, token):
    """The read pushes a device was sent (not withdrawals or syncs)."""
    return [p for p in pushes_for(token, "background") if opened(key, p).get("kind") == "read"]


def read_times(body, kind="chats") -> dict:
    """A read push's (or notice's) ``read`` list of ``kind`` as {id: when it was read}."""
    return {key: at for key, at in body["read"][kind]}


def test_a_read_elsewhere_clears_another_devices_reply(reading):
    plugins, handler, push, later = reading
    key, token = make_device(handler, "read-phone", reply_after=0)
    ipad_key, ipad = make_device(handler, "read-ipad", reply_after=0)
    session, root = "20261021_read_chat", "20261021_read_root"
    presence(handler, "read-phone", state="away")
    presence(handler, "read-ipad", state="away")
    finish_turn(plugins, session, "read-1")
    wait_for(lambda: pushes_for(token, "alert") and pushes_for(ipad, "alert"))
    assert push.store.read()["delivered"]["dev-read-phone"]["chats"][session] <= time.time()

    # Read on the iPad (the chat's id and its lineage root): the phone owes a read push, the iPad nothing.
    before = time.time()
    answer = read(handler, "read-ipad", chats=[session, root])
    assert answer == {"ok": True, "open": len(push.store.read()["requests"])}
    assert ("read", "dev-read-phone") in push._due and ("read", "dev-read-ipad") not in push._due
    assert later.delays(("read", "dev-read-phone")) == [3.0]
    state = push.store.read()
    assert session not in state["delivered"]["dev-read-phone"]["chats"]
    assert list(state["cleared"]["dev-read-phone"]["chats"]) == [session]
    assert session in state["delivered"]["dev-read-ipad"]["chats"]

    later.run()
    sent = wait_for(lambda: next(iter(reads_for(key, token)), None))
    body = opened(key, sent)
    assert body["kind"] == "read" and list(read_times(body)) == [session] and body["read"]["rooms"] == []
    read_at = read_times(body)[session]  # when it was read, not when the push went
    assert before - 0.01 <= read_at <= time.time() and round(read_at, 3) == read_at
    assert "sessions" not in body and "rooms" not in body
    assert body["gateway"]["name"] == "Test Mac" and body["open"] == answer["open"] and body["v"] == 1
    assert sent["payload"]["aps"] == {"content-available": 1} and set(sent["payload"]) == {"aps", "hermes"}
    assert (sent["priority"], sent["collapse_id"]) == (5, "read")
    assert time.time() < sent["expiration"] <= time.time() + 3601
    time.sleep(0.3)
    assert not reads_for(ipad_key, ipad), "the device that read got a read push"


def test_a_room_read_elsewhere_clears_its_bot_messages(reading, monkeypatch):
    plugins, handler, push, later = reading
    monkeypatch.setattr(_core_module(), "ROOM_MESSAGE_SETTLE", 0.05)
    key, token = make_device(handler, "room-phone", bots="all")
    presence(handler, "room-phone", state="away")
    room = "room-launch-crew-0021"
    plugins.invoke_hook("on_room_member_activity", room_id=room, member_id="ada", turn_id="room-1",
                        kind="message.delta", payload={"text": "The build is green."})
    wait_for(lambda: pushes_for(token, "alert"))
    assert room in push.store.read()["delivered"]["dev-room-phone"]["rooms"]
    read(handler, "room-reader", rooms=[room])  # a Mac: never registered, still a reader
    later.run()
    body = opened(key, wait_for(lambda: next(iter(reads_for(key, token)), None)))
    assert list(read_times(body, "rooms")) == [room] and body["read"]["chats"] == []


def test_no_read_push_for_what_a_device_was_never_sent(reading):
    plugins, handler, push, later = reading
    key, token = make_device(handler, "unsent-phone", reply_after=0)
    presence(handler, "unsent-phone", state="away")
    finish_turn(plugins, "20261021_sent_chat", "unsent-1")
    wait_for(lambda: pushes_for(token, "alert"))
    read(handler, "unsent-reader", chats=["20261021_never_sent"], rooms=["room-never-sent"])
    assert ("read", "dev-unsent-phone") not in push._due
    later.run()
    time.sleep(0.3)
    assert not reads_for(key, token)
    assert "20261021_sent_chat" in push.store.read()["delivered"]["dev-unsent-phone"]["chats"]


def test_devices_in_the_app_get_no_read_push(reading):
    plugins, handler, push, later = reading
    devices = [make_device(handler, name, reply_after=0) for name in ("front-phone", "running-mac", "back-phone")]
    front, running, back = (token for _key, token in devices)
    session = "20261021_in_app_chat"
    presence(handler, "front-phone", state="foreground", session_id="20261021_other_chat")
    presence(handler, "running-mac", state="running", live=[])
    presence(handler, "back-phone", state="away")
    finish_turn(plugins, session, "in-app-1")
    wait_for(lambda: all(pushes_for(t, "alert") for t in (front, running, back)))
    read(handler, "in-app-reader", chats=[session])
    assert ("read", "dev-front-phone") not in push._due and ("read", "dev-running-mac") not in push._due
    delivered = push.store.read()["delivered"]
    assert session in delivered["dev-front-phone"]["chats"] and session in delivered["dev-running-mac"]["chats"]
    # Owed one, but back in the app before it went: none, and what it was owed is forgotten.
    assert ("read", "dev-back-phone") in push._due
    presence(handler, "back-phone", state="foreground", session_id=session)
    state = push.store.read()
    assert "dev-back-phone" not in state["cleared"] and "dev-back-phone" not in state["delivered"]
    later.run()
    time.sleep(0.3)
    for key, token in devices:
        assert not reads_for(key, token)


def test_reads_inside_the_window_go_as_one_push(reading):
    plugins, handler, push, later = reading
    key, token = make_device(handler, "window-phone", reply_after=0)
    presence(handler, "window-phone", state="away")
    first, second, third = "20261021_window_a", "20261021_window_b", "20261021_window_c"
    for n, session in enumerate((first, second, third)):
        finish_turn(plugins, session, f"window-{n}")
    wait_for(lambda: len(pushes_for(token, "alert")) == 3)
    owed = ("read", "dev-window-phone")
    read(handler, "window-reader", chats=[first])
    read(handler, "window-reader", chats=[second])
    assert later.delays(owed) == [3.0]  # the second read rides with the first's push
    later.run()
    wait_for(lambda: reads_for(key, token))
    time.sleep(0.3)
    reads = reads_for(key, token)
    first_push = opened(key, reads[0])
    assert len(reads) == 1 and sorted(read_times(first_push)) == sorted([first, second])
    assert read_times(first_push)[first] <= read_times(first_push)[second]  # each its own read time

    # Inside 30 s of that one: the next waits for the window, then names everything read since the
    # device left, so it replaces the first.
    read(handler, "window-reader", chats=[third])
    assert later.delays(owed)[0] > 25
    later.run()  # early: it waits out the rest of the window
    assert later.delays(owed)[0] > 25 and len(reads_for(key, token)) == 1
    push.store.update(lambda s: s["read_pushes"]["dev-window-phone"].__setitem__("sent", time.time() - 31))
    later.run()
    latest = wait_for(lambda: reads_for(key, token)[1:] and reads_for(key, token)[1])
    times = read_times(opened(key, latest))
    assert sorted(times) == sorted([first, second, third])
    # The earlier reads keep their own times (a reply after one of them must stay), the newest is newest.
    assert times[first] == read_times(first_push)[first] and times[second] == read_times(first_push)[second]
    assert times[third] > times[second] and [c for c, _at in opened(key, latest)["read"]["chats"]][0] == third
    assert latest["collapse_id"] == "read"


def test_the_badge_follows_reads_and_new_replies(reading):
    plugins, handler, push, later = reading
    key, token = make_device(handler, "badge-phone", reply_after=0)
    _other_key, other = make_device(handler, "plain-phone", reply_after=0)
    unread, still_unread, muted, fresh = ("20261021_badge_a", "20261021_badge_b", "20261021_badge_muted",
                                          "20261021_badge_fresh")
    presence(handler, "badge-phone", state="away", unread={"chats": [unread, still_unread], "rooms": ["room-badge"]},
             muted={"chats": [muted], "rooms": []})
    presence(handler, "plain-phone", state="away")  # it doesn't count unread chats: no record, no badge pushes
    state = push.store.read()
    record = state["badges"]["dev-badge-phone"]
    shown = record["shown"]
    assert shown == len(state["requests"]) + 3 and "dev-plain-phone" not in state["badges"]
    assert record["muted_chats"] == [muted]

    # Read on another device: one fewer, sent as a badge-only push.
    read(handler, "badge-reader", chats=[unread])
    assert later.delays(("badge", "dev-badge-phone")) == [3.0]
    assert ("read", "dev-badge-phone") not in push._due  # it was sent nothing for that chat
    later.run()
    first = wait_for(lambda: badges_for(token) and badges_for(token)[0])
    assert first["payload"] == {"aps": {"badge": shown - 1}}
    assert (first["push_type"], first["priority"], first["collapse_id"]) == ("alert", 5, "badge")
    assert time.time() < first["expiration"] <= time.time() + 3601

    # A reply in a new chat: one more. A muted chat's reply counts nothing.
    finish_turn(plugins, fresh, "badge-1")
    finish_turn(plugins, muted, "badge-2")
    wait_for(lambda: len(notices_for(key, token)) == 2)
    later.run()
    second = wait_for(lambda: badges_for(token)[1:] and badges_for(token)[1])
    assert second["payload"] == {"aps": {"badge": shown}}
    record = push.store.read()["badges"]["dev-badge-phone"]
    assert record["chats"] == [still_unread, fresh] and record["rooms"] == ["room-badge"]

    # A group chat read elsewhere comes off too (the app marks it read when it hears), and a count that
    # didn't move sends nothing.
    read(handler, "badge-reader", rooms=["room-badge"])
    later.run()
    third = wait_for(lambda: badges_for(token)[2:] and badges_for(token)[2])
    assert third["payload"] == {"aps": {"badge": shown - 1}}
    push._flush_badge("dev-badge-phone")
    read(handler, "badge-reader", chats=[fresh, still_unread])
    later.run()
    fourth = wait_for(lambda: badges_for(token)[3:] and badges_for(token)[3])
    assert fourth["payload"] == {"aps": {"badge": shown - 3}}
    push._flush_badge("dev-badge-phone")
    time.sleep(0.3)
    assert len(badges_for(token)) == 4

    # The device without a record never gets one, and coming back to the app forgets the record.
    assert not badges_for(other)
    presence(handler, "badge-phone", state="foreground", session_id=fresh)
    assert "dev-badge-phone" not in push.store.read()["badges"]

    # What the person's other gateways add to the badge rides along, so a push from this one doesn't
    # overwrite theirs.
    presence(handler, "badge-phone", state="away", unread={"chats": [unread], "rooms": []}, muted={"chats": [], "rooms": []},
             badge_others=4)
    record = push.store.read()["badges"]["dev-badge-phone"]
    assert record["others"] == 4 and record["shown"] == len(push.store.read()["requests"]) + 1 + 4
    read(handler, "badge-reader", chats=[unread])
    later.run()
    fifth = wait_for(lambda: badges_for(token)[4:] and badges_for(token)[4])
    assert fifth["payload"] == {"aps": {"badge": len(push.store.read()["requests"]) + 4}}
    presence(handler, "badge-phone", state="away")
    assert "dev-badge-phone" not in push.store.read()["badges"]


def test_notices_list_the_latest_reads(reading):
    plugins, handler, push, later = reading
    key, token = make_device(handler, "read-list", reply_after=0)
    before = time.time()
    read(handler, "read-list-reader", chats=["20261021_listed_chat"], rooms=["room-listed"])
    finish_turn(plugins, "20261021_listing_reply", "listing-1")
    content = wait_for(lambda: notices_for(key, token) and notices_for(key, token)[0])
    chats, rooms = dict(map(tuple, content["read"]["chats"])), dict(map(tuple, content["read"]["rooms"]))
    assert before - 1 <= chats["20261021_listed_chat"] <= time.time() and "room-listed" in rooms
    assert len(content["read"]["chats"]) <= 12 and len(content["read"]["rooms"]) <= 12
    times = [at for _id, at in content["read"]["chats"]]
    assert times == sorted(times, reverse=True) and all(round(at, 3) == at for at in times)

    store = sys.modules[type(push).__module__.rsplit(".", 1)[0] + ".store"]
    notices = sys.modules[type(push).__module__.rsplit(".", 1)[0] + ".notices"]
    now = time.time()
    state = {"reads": {"chats": {**{f"20261021_0225{i:02d}_a1b2c3": now - i for i in range(20)},
                                 "20261021_old": now - 7 * 3600}}}
    listed = store.recent_reads(state)
    assert [c for c, _at in listed["chats"]] == [f"20261021_0225{i:02d}_a1b2c3" for i in range(12)]
    assert listed["rooms"] == []
    assert store.recent_reads({"reads": {"chats": {"20261021_old": now - 7 * 3600}}}) == {}
    assert store.recent_reads({}) == {}
    plain = notices.Notice(kind="test", id="t", title="Push notifications are on", body="Hi.")
    assert "read" not in plain.content({}, 0, [], {}) and "read" not in plain.content({}, 0, [], None)
    assert plain.content({}, 0, [], {"chats": [["c", 1.5]], "rooms": []})["read"] == {"chats": [["c", 1.5]], "rooms": []}


def _device_key():
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    return X25519PrivateKey.generate()


def _public_key(key) -> str:
    from cryptography.hazmat.primitives import serialization
    return base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,
                                                          serialization.PublicFormat.Raw)).decode()


def test_the_longest_approval_and_a_full_read_list_fit_the_relay(hermes):
    """The relay refuses payloads over 4096 bytes. The read list gives way, oldest first, before the
    notice does: the longest approval keeps every one of its own fields, a reply the whole list."""
    import uuid
    notices = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    key = _device_key()
    device = {"token": "ab" * 32, "topic": "co.caffeinatedcode.hermes", "environment": "production",
              "public_key": _public_key(key)}
    gateway = {"id": "inst_" + "k" * 27, "name": "Home Server"}
    session = "20261021_022501_a1b2c3"
    resolved = [uuid.uuid4().hex for _ in range(20)]
    command = ("rsync -av --delete --exclude '.DS_Store' /Volumes/Work/Projects/hermes/build/snapshots/ "
               "/Volumes/Backup/hermes/snapshots/ && ") * 8
    now = time.time()

    def full(chat_id, room_id):
        return {"chats": [[chat_id(i), round(now - 2 * i, 3)] for i in range(12)],
                "rooms": [[room_id(i), round(now - 2 * i - 1, 3)] for i in range(12)]}

    def size(request) -> int:
        return len(json.dumps(request["payload"], ensure_ascii=False, separators=(",", ":")).encode())

    approval = notices.approval(request_id=uuid.uuid4().hex, session_id=session, chat="Clean up the old build snapshots",
                                gateway_name=gateway["name"], command=command, description="d" * 300,
                                choices=["once", "session", "always", "deny"], expires_at=now + 300, surface="gateway")
    approval.extra.update(answer={"via": "socket", "session_id": session}, answerable=True)
    reads = full(lambda i: f"20261021_0225{i:02d}_a1b2c3", lambda i: f"room-{uuid.UUID(int=i)}")
    bare = notices.apns_request(device, approval, gateway, 3, resolved)
    request = notices.apns_request(device, approval, gateway, 3, resolved, reads)
    content = opened(key, request)
    assert size(bare) <= size(request) <= 4096, (size(bare), size(request))
    assert notices.payload_size(request["payload"]["aps"], content) == size(request)
    assert len(content["command"].encode()) == 600 and content["command"].endswith("…")
    assert content["resolved"] == resolved and content["choices"][-1] == "deny"
    kept = content.get("read", {"chats": [], "rooms": []})
    assert kept["chats"] == reads["chats"][:len(kept["chats"])] and kept["rooms"] == reads["rooms"][:len(kept["rooms"])]
    assert len(kept["chats"]) + len(kept["rooms"]) >= 6, kept  # the newest reads still go with it

    # The longest reply with 20 settled requests keeps nearly all of them, an everyday one the whole list.
    reply = notices.reply(session_id=session, turn_id="t", chat="Clean up the old build snapshots",
                          gateway_name=gateway["name"], text="Freed space on the build volume. " * 40, seconds=45)
    request = notices.apns_request(device, reply, gateway, 3, resolved, reads)
    kept = opened(key, request)["read"]
    assert size(request) <= 4096 and len(kept["chats"]) + len(kept["rooms"]) >= 20, (size(request), kept)
    reply = notices.reply(session_id=session, turn_id="t", chat="Clean up the old build snapshots",
                          gateway_name=gateway["name"], text="Freed 42 GB.\nKept the last 7 days.", seconds=45)
    request = notices.apns_request(device, reply, gateway, 0, resolved[:3], reads)
    assert size(request) <= 4096 and opened(key, request)["read"] == reads

    # Ids at their 120-character limit: fewer reads, still under the limit.
    longest = full(lambda i: f"{i:02d}" + "c" * 118, lambda i: f"{i:02d}" + "r" * 118)
    request = notices.apns_request(device, approval, gateway, 3, resolved, longest)
    assert size(request) <= 4096 and len(opened(key, request)["command"].encode()) == 600


def test_text_is_clipped_by_bytes_between_characters(hermes):
    """The relay counts UTF-8 bytes: a character outside ASCII takes two to four, so text is clipped by
    bytes, never through a character, and marked "…" (security scan F7: a clipped command offers no Allow)."""
    notices = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    assert notices.clip("rm -rf ./build", 600) == "rm -rf ./build"
    assert notices.clip("é" * 10, 9) == "ééé…" and len(notices.clip("é" * 10, 9).encode()) == 9
    assert notices.clip("😀" * 5, 10) == "😀…"
    assert notices.clip("ab  \n cd" + "x" * 50, 10) == "ab cdxx…"
    for text in ("ファイル" * 300, "é" * 700, "a😀" * 400):
        clipped = notices.clip(text, 600)
        assert len(clipped.encode()) <= 600 and clipped.endswith("…") and text.startswith(clipped[:-1])
    assert notices.first_lines("Fertig: " + "ü" * 600, 4, 480, breaks=True).endswith("…")


def test_a_long_non_ascii_approval_or_question_fits_the_relay(hermes):
    """An approval whose command, description, chat and gateway name are long and outside ASCII still
    fits in 4096 bytes, and its clipped command is marked so it offers no Allow. So do four long
    questions with every choice."""
    import uuid
    notices = sys.modules[_core_module().__name__.rsplit(".", 1)[0] + ".notices"]
    key = _device_key()
    device = {"token": "ab" * 32, "topic": "co.caffeinatedcode.hermes", "environment": "production",
              "public_key": _public_key(key)}
    gateway = {"id": "inst_" + "k" * 27, "name": "Café Ünïcode Server" * 3}
    session = "20261021_022501_a1b2c3"
    resolved = [uuid.uuid4().hex for _ in range(20)]
    now = time.time()

    def size(request) -> int:
        return len(json.dumps(request["payload"], ensure_ascii=False, separators=(",", ":")).encode())

    reads = {"chats": [[f"20261021_0225{i:02d}_a1b2c3", round(now - i, 3)] for i in range(12)], "rooms": []}
    approval = notices.approval(request_id=uuid.uuid4().hex, session_id=session, chat="Ünïcödé snapshot cleanup " * 12,
                                gateway_name=gateway["name"], command="ファイルを削除 " * 120 + "é" * 600,
                                description="Löscht die alten Snapshots " * 20, choices=["once", "session", "always", "deny"],
                                expires_at=now + 300, surface="gateway")
    request = notices.apns_request(device, approval, gateway, 3, resolved, reads)
    content = opened(key, request)
    assert size(request) <= 4096, size(request)
    assert content["command"].endswith("…") and len(content["command"].encode()) <= 600
    assert content["description"] and content["body"].startswith("Run ")

    questions = [{"question": "どのバックアップを残しますか? " * 30, "choices": ["最新のスナップショット " * 6] * 8,
                  "multi_select": False} for _ in range(4)]
    question = notices.question(request_id=uuid.uuid4().hex, session_id=session, chat="Ünïcödé snapshot cleanup " * 12,
                                gateway_name=gateway["name"], questions=questions, prompt="", expires_at=now + 3600)
    request = notices.apns_request(device, question, gateway, 3, resolved, reads)
    content = opened(key, request)
    assert size(request) <= 4096, size(request)
    assert len(content["questions"]) >= 1 and all(q["question"] for q in content["questions"])


def test_read_and_presence_check_their_ids(copies, tmp_path):
    core = copies("app_push_ids")
    push = core.Push(store=core.Store(tmp_path), later=Later())
    with pytest.raises(core.PushError):
        push.read({"device_id": "dev-reader", "chats": "20261021_x"})
    with pytest.raises(core.PushError):
        push.read({"chats": ["20261021_x"]})
    assert push.read({"device_id": "dev-reader"}) == {"ok": True, "open": 0}
    push.read({"device_id": "dev-reader", "chats": ["c" * 200, "c" * 200, 7, "", *[f"chat-{i}" for i in range(80)]],
               "rooms": [None, "room-1"]})
    reads = push.store.read()["reads"]
    assert "c" * 120 in reads["chats"] and len(reads["chats"]) == 50 and list(reads["rooms"]) == ["room-1"]
    push.store.put_device("dev-away", {"token": "ab" * 32, "topic": "co.caffeinatedcode.hermes", "preferences": {}})
    push.presence({"device_id": "dev-away", "state": "away",
                   "unread": {"chats": [f"chat-{i}" for i in range(300)] + ["x" * 300], "rooms": "nope"},
                   "muted": ["not", "a", "set"]})
    record = push.store.read()["badges"]["dev-away"]
    assert len(record["chats"]) == 200 and record["rooms"] == [] and record["muted_chats"] == []
    push.presence({"device_id": "dev-away", "state": "away", "unread": ["not", "a", "set"]})
    assert "dev-away" not in push.store.read()["badges"]


def test_an_older_state_file_still_loads(copies, tmp_path):
    """A state file from before 1.4.0 (no reads, delivered, cleared or badge records) loads and works."""
    core = copies("app_push_old_state")
    old = {"version": 1, "devices": {"dev-old": {"token": "ab" * 32, "topic": "co.caffeinatedcode.hermes",
                                                 "environment": "production", "preferences": {}}},
           "requests": {"req-1": {"kind": "approval", "session": "s", "opened_at": time.time()}},
           "resolved": [], "presence": {}, "activities": {}, "installation": {}, "sync": {}}
    (tmp_path / "state.json").write_text(json.dumps(old))
    store = core.Store(tmp_path)
    state = store.read()
    assert state["reads"] == {"chats": {}, "rooms": {}} and state["badges"] == {} and state["delivered"] == {}
    assert sys.modules["app_push_old_state.store"].recent_reads(state) == {}
    later = Later()
    push = core.Push(store=store, later=later)
    push.presence({"device_id": "dev-old", "state": "away", "unread": {"chats": ["20261021_old_chat"]}})
    assert store.read()["badges"]["dev-old"]["shown"] == 2  # the open request and the chat
    assert push.read({"device_id": "dev-new", "chats": ["20261021_old_chat"]}) == {"ok": True, "open": 1}
    assert store.claim_badge("dev-old") == 1 and store.claim_badge("dev-old") is None
    assert store.claim_read_push("dev-old") == (None, 0.0)
    assert push.store.remove_device("dev-old") and store.read()["badges"] == {}

    # A file whose reads came from an older shape still lists what it can.
    (tmp_path / "state.json").write_text(json.dumps({"devices": {}, "reads": {"chats": []}}))
    assert sys.modules["app_push_old_state.store"].recent_reads(store.read()) == {}
    assert push.read({"device_id": "dev-new", "rooms": ["room-1"]})["ok"]
