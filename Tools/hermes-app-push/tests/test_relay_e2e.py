"""Plugin → Convex relay → APNs, end to end, with a fake APNs.

Needs a running relay and the fake APNs (see Relay/README.md), then:

    HERMES_PUSH_RELAY_URL=http://127.0.0.1:3211 FAKE_APNS_LOG=/tmp/fake-apns.jsonl \
    APNS_TEST_PUBLIC_KEY=/tmp/test-apns.pub \
    ~/.hermes/hermes-agent/.venv/bin/python -m pytest Tools/hermes-app-push/tests/test_relay_e2e.py --import-mode=importlib

Skipped unless those variables are set.
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

RELAY = os.environ.get("HERMES_PUSH_RELAY_URL")
LOG = os.environ.get("FAKE_APNS_LOG")
PUBLIC_KEY = os.environ.get("APNS_TEST_PUBLIC_KEY")
pytestmark = pytest.mark.skipif(not (RELAY and LOG and PUBLIC_KEY), reason="needs a local relay and fake APNs")

PLUGIN_DIR = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent")).expanduser()
HOME = Path(tempfile.mkdtemp(prefix="hermes-app-push-e2e-"))
if RELAY and LOG and PUBLIC_KEY:  # only when this module runs: the unit tests set their own home
    os.environ["HERMES_HOME"] = str(HOME)
    sys.path.insert(0, str(SOURCE))


def crypto_module():
    spec = importlib.util.spec_from_file_location("app_push_crypto_e2e", PLUGIN_DIR / "crypto.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apns_log() -> list[dict]:
    try:
        return [json.loads(line) for line in Path(LOG).read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        return []


def wait_for(predicate, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = predicate()
        if found:
            return found
        time.sleep(0.1)
    raise AssertionError("timed out waiting")


def verify_jwt(authorization: str) -> dict:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
    token = authorization.split(" ", 1)[1]
    head, claims, signature = token.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)
    raw = base64.urlsafe_b64decode(pad(signature))
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key = serialization.load_pem_public_key(Path(PUBLIC_KEY).read_bytes())
    key.verify(der, f"{head}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))  # raises if forged
    return {**json.loads(base64.urlsafe_b64decode(pad(head))), **json.loads(base64.urlsafe_b64decode(pad(claims)))}


@pytest.fixture(scope="module")
def handler():
    target = HOME / "plugins" / "hermes-app-push"
    shutil.copytree(PLUGIN_DIR, target, ignore=shutil.ignore_patterns("tests", "__pycache__"))
    (HOME / "config.yaml").write_text(
        "plugins:\n  enabled: [hermes-app-push]\n  entries:\n    hermes-app-push:\n      settings:\n"
        f"        relay_url: {RELAY}\n        gateway_name: E2E Mac\napprovals:\n  timeout: 5\n")
    from hermes_cli import plugins
    plugins.discover_plugins(force=True)
    return plugins.get_plugin_command_handler("app-push")


def register(handler, token: str):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    key = X25519PrivateKey.generate()
    public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,
                                                            serialization.PublicFormat.Raw)).decode()
    answer = json.loads(handler("register " + json.dumps({
        "device_id": f"dev-{token[:8]}", "token": token, "topic": "co.caffeinatedcode.hermes.dev",
        "environment": "development", "public_key": public, "platform": "ios"})))
    assert answer["ok"] and answer["relay"] == "ok", answer
    assert answer["gateway"]["id"].startswith("inst_")
    return key


def test_approval_reaches_apns_and_withdraws(handler):
    token = os.urandom(32).hex()
    key = register(handler, token)
    from tools import approval
    from tools.approval_gateway_wait import _await_gateway_decision
    session = "20261014_e2e"
    worker = threading.Thread(target=lambda: _await_gateway_decision(
        session, lambda data: None, {"command": "git push --force origin main", "description": "force push",
                                     "pattern_key": "git_force", "pattern_keys": ["git_force"]}))
    worker.start()
    alert = wait_for(lambda: next((r for r in apns_log() if token in r["path"]
                                   and r["headers"]["apns-push-type"] == "alert"), None))
    headers = alert["headers"]
    assert alert["path"] == f"/3/device/{token}"
    assert headers["apns-topic"] == "co.caffeinatedcode.hermes.dev"
    assert headers["apns-priority"] == "10" and int(headers["apns-expiration"]) > time.time()
    claims = verify_jwt(headers["authorization"])
    assert claims["alg"] == "ES256" and claims["kid"] == "TESTKEY123" and claims["iss"] == "TESTTEAM12"
    content = crypto_module().open_envelope(key, alert["body"]["hermes"])
    pending = approval.list_gateway_approvals(session)
    assert content["kind"] == "approval" and content["request_id"] == pending[0]["request_id"]
    assert headers["apns-collapse-id"] == content["request_id"]
    assert "git push" not in json.dumps(alert["body"]["aps"])

    approval.resolve_gateway_approval(session, "deny", request_id=content["request_id"])
    worker.join(5)
    withdraw = wait_for(lambda: next((r for r in apns_log() if token in r["path"]
                                      and r["headers"]["apns-push-type"] == "background"), None))
    assert withdraw["headers"]["apns-priority"] == "5"
    assert content["request_id"] in crypto_module().open_envelope(key, withdraw["body"]["hermes"])["ids"]


def test_dead_token_is_forgotten(handler):
    token = "dead" + os.urandom(30).hex()
    register(handler, token)
    answer = json.loads(handler("test " + json.dumps({"device_id": f"dev-{token[:8]}"})))
    assert answer == {"ok": False, "status": 410, "reason": "Unregistered"}
    assert json.loads(handler("status " + json.dumps({"device_id": f"dev-{token[:8]}"})))["registered"] is False


def test_relay_refuses_a_forged_installation():
    import httpx
    response = httpx.post(f"{RELAY}/v1/push", json={}, headers={"X-Hermes-Installation": "inst_fake",
                                                                 "Authorization": "Bearer nope"})
    assert response.status_code == 401
