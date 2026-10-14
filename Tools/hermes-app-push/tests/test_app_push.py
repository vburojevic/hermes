"""End-to-end tests for hermes-app-push against the real Hermes Agent code.

Run with the Hermes venv from this folder's parent:

    HERMES_SOURCE=~/.hermes/hermes-agent ~/.hermes/hermes-agent/.venv/bin/python -m pytest Tools/hermes-app-push/tests

Each test session gets a throwaway HERMES_HOME with only this plugin enabled, a fake relay on
localhost, and a device key pair; nothing touches ~/.hermes.
"""
from __future__ import annotations

import base64
import json
import os
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
SECRET = "sk-live-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c"

HOME = Path(tempfile.mkdtemp(prefix="hermes-app-push-test-"))
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
                   "Test Mac"):
        assert needle not in blob, f"{needle!r} reached the relay"
    allowed_titles = {"Hermes needs your OK", "Hermes has a question", "Hermes needs a password", "Hermes replied",
                      "A scheduled task finished", "A scheduled task failed", "New message",
                      "Background work finished", "Push notifications are on"}
    for push in FakeRelay.pushes:
        alert = push["payload"].get("aps", {}).get("alert")
        if alert:
            assert alert["title"] in allowed_titles



def _core_module():
    return next(m for m in list(sys.modules.values())
                if str(getattr(m, "__file__", "") or "").endswith(os.path.join("hermes-app-push", "core.py")))


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
    assert body == "Freed 42 GB. Kept the last 7 days. Nothing else touched."
    # A subagent's turn and a Telegram chat's turn never notify here.
    before = len(pushes_for(token, "alert"))
    for turn, extra in (("sub-1", {"parent_session_id": session}), ("tg-1", {"platform": "telegram"})):
        handler("presence " + json.dumps({"device_id": "dev-walker", "state": "foreground", "session_id": session}))
        plugins.invoke_hook("pre_llm_call", session_id=session, turn_id=turn, **extra)
        handler("presence " + json.dumps({"device_id": "dev-walker", "state": "away"}))
        plugins.invoke_hook("post_llm_call", session_id=session, turn_id=turn, assistant_response="Done.")
        plugins.invoke_hook("on_session_end", session_id=session, turn_id=turn, completed=True)
    time.sleep(0.5)
    assert len(pushes_for(token, "alert")) == before
    # A Kanban card done (passive) and one blocked (active), on by default.
    plugins.invoke_hook("kanban_task_completed", task_id="t_1", board="ops", assignee="ada", summary="Rotated the keys.")
    plugins.invoke_hook("kanban_task_blocked", task_id="t_2", board="ops", assignee="ada", reason="Needs the VPN password.")
    wait_for(lambda: len(pushes_for(token, "alert")) >= before + 2)
    done, blocked = [opened(key, p) for p in pushes_for(token, "alert")[-2:]]
    assert done["kind"] == "task" and done["body"] == "Rotated the keys." and done["subtitle"] == "Done · ada"
    assert blocked["kind"] == "task_failed" and blocked["subtitle"] == "Blocked · ada"
    assert pushes_for(token, "alert")[-1]["payload"]["aps"]["interruption-level"] == "active"


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
