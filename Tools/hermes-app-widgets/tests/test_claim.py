"""claim (payload-contract.md §6.3): first answer wins, idempotent per mid, the gateway's clock,
signatures for approvals that must be signed, and for in group chats. Then resolve and update."""
from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

from harness import as_input, call, plugin_module, session

SPEC = Path(__file__).resolve().parents[1] / "spec"
APP = {"platform": "api_server", "session_id": "sess-app"}


def example(name: str) -> dict:
    return as_input(json.loads((SPEC / "examples" / f"{name}.json").read_text()))


def make(widgets, payload, profile="hermes", binding=APP):
    widgets.mark_session(binding["session_id"]) if binding.get("platform") in ("api_server", "desktop") else None
    with session(**binding, profile=profile):
        result = call(widgets, {"op": "create", "payload": payload}, session_id=binding["session_id"])
    assert "error" not in result, result
    return result


def claim(widgets, binding=APP, profile="hermes", **args):
    with session(**binding, profile=profile):
        return call(widgets, {"op": "claim", **args}, session_id=binding["session_id"])


def choice(widgets):
    return make(widgets, example("choice-1"))


def test_first_answer_wins_and_a_retry_replays(widgets, clock):
    widget = choice(widgets)
    first = claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-1", values={"selected": ["ua1187"]}, device="iPhone")
    assert first["result"] == "ok" and first["by"] == "iPhone" and first["at"] == "2026-10-16T11:12:30-04:00"
    clock.advance(seconds=5)
    second = claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-2", values={"selected": ["ba861"]}, device="Mac")
    assert second["result"] == "already_answered"
    assert (second["mid"], second["by"], second["at"]) == ("m-1", "iPhone", "2026-10-16T11:12:30-04:00")
    again = claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-1", values={"selected": ["ua1187"]})
    assert again["result"] == "ok" and again["replay"] is True and "already acted" in again["message"]
    assert claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-2", values={})["replay"] is True


def test_claims_from_two_processes_never_both_win(widgets):
    """Two Widgets over one store (two Hermes processes): the lock makes one answer the first."""
    core, store = plugin_module("core"), plugin_module("store")
    other = core.Widgets(store=store.Store(widgets.store.dir), clock=widgets.clock, cron_execution=lambda: None)
    widget = choice(widgets)
    results = [claim(w, id=widget["id"], rev=1, action="answer", mid=f"m-{n}", values={"selected": ["ua1187"]})
               for n, w in enumerate((widgets, other, widgets, other))]
    assert [r["result"] for r in results].count("ok") == 1


def test_stale_and_unknown_revisions(widgets):
    widget = choice(widgets)
    with session(**APP, profile="hermes"):
        updated = call(widgets, {"op": "update", "id": widget["id"], "payload": example("choice-1")}, session_id="sess-app")
    assert updated["rev"] == 2
    stale = claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-old", values={"selected": ["ua1187"]})
    assert stale["result"] == "stale_rev" and stale["current_rev"] == 2
    assert claim(widgets, id=widget["id"], rev=7, action="answer", mid="m-7", values={})["result"] == "stale_rev"
    assert "no action" in claim(widgets, id=widget["id"], rev=2, action="buy", mid="m-x", values={})["error"]
    assert "no widget" in claim(widgets, id="w_nothere1", rev=1, action="answer", mid="m-y")["error"]


def test_expiry_uses_the_gateway_clock(widgets, clock):
    payload = example("approval-2")  # a message, can't be undone: signed
    widget = make(widgets, payload)
    clock.now = clock.now.replace(day=17, hour=12, minute=0, second=1)  # past expires_at 12:00 on the 17th
    result = claim(widgets, id=widget["id"], rev=1, action="reject", mid="m-late", values={})
    assert result["result"] == "expired" and result["expires_at"] == "2026-10-17T12:00:00-04:00"


def p256_key():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return key, base64.b64encode(point).decode()


def sign(key, message: bytes) -> str:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    return base64.b64encode(key.sign(message, ec.ECDSA(hashes.SHA256()))).decode()


def test_signed_approvals(widgets):
    signing = plugin_module("signing")
    widget = make(widgets, example("approval-1"), profile="chef-remy")
    wid = widget["id"]
    # Before any device registers a key, the app's own Face ID is the only gate.
    interim = claim(widgets, profile="chef-remy", id=wid, rev=1, action="approve", mid="m-0", values={})
    assert interim["result"] == "ok" and interim["signature"] == "unavailable"

    widget = make(widgets, example("approval-1"), profile="chef-remy")
    wid = widget["id"]
    key, public = p256_key()
    registered = widgets.command("keys.register", {"device_id": "dev-iphone", "name": "iPhone", "public_key": public})
    assert registered["ok"] and registered["devices"] == 1
    assert claim(widgets, id=wid, rev=1, action="approve", mid="m-1", values={})["reason"] == "missing"
    bad = sign(key, signing.signing_input(wid, 1, "approve", {"x": 1}, "m-2"))  # signed other values
    assert claim(widgets, id=wid, rev=1, action="approve", mid="m-2", values={}, sig=bad)["reason"] == "invalid"
    telegram = {"platform": "telegram", "session_id": "sess-tg", "chat_id": "42", "user_name": "Sam"}
    text = claim(widgets, binding=telegram, id=wid, rev=1, action="approve", mid="m-3", values={})
    assert text["result"] == "unsigned" and text["reason"] == "text_answer"
    good = sign(key, signing.signing_input(wid, 1, "approve", {}, "m-4"))
    ok = claim(widgets, id=wid, rev=1, action="approve", mid="m-4", values={}, sig=good)
    assert ok["result"] == "ok" and ok["signature"] == "verified" and ok["by"] == "iPhone"
    # Rejecting costs nothing and needs no signature; it's simply too late now.
    assert claim(widgets, id=wid, rev=1, action="reject", mid="m-5", values={})["result"] == "already_answered"


def test_signing_input_is_stable():
    signing = plugin_module("signing")
    message = signing.signing_input("w_lunch1011", 1, "edit", {"text": "No onions / extra lime", "b": 2, "a": "é"}, "0b7f")
    canonical = '{"a":"é","b":2,"text":"No onions / extra lime"}'
    import hashlib
    assert message == f"hermes-widgets-v1|w_lunch1011|1|edit|{hashlib.sha256(canonical.encode()).hexdigest()}|0b7f".encode()


def test_raw_signatures_and_der_keys_verify():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    signing = plugin_module("signing")
    key = ec.generate_private_key(ec.SECP256R1())
    der_public = base64.b64encode(key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    message = signing.signing_input("w_abcdef12", 3, "approve", {}, "m")
    r, s = decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    raw = base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode()
    assert signing.verify(der_public, raw, message)
    assert not signing.verify(der_public, raw, message + b"x")


def test_group_widgets_answer_only_for_their_person(widgets):
    group = {"platform": "telegram", "session_id": "sess-group", "chat_id": "-100", "chat_type": "group",
             "user_id": "7", "user_name": "Maya"}
    payload = {**example("choice-1"), "for": {"name": "Maya", "user": "7"}}
    widget = make(widgets, payload, binding=group)
    other = {**group, "user_id": "8", "user_name": "Eli"}
    refused = claim(widgets, binding=other, id=widget["id"], rev=1, action="answer", mid="m-eli", values={"selected": ["ua1187"]})
    assert refused["result"] == "not_for_you" and refused["for"]["name"] == "Maya"
    assert claim(widgets, binding=group, id=widget["id"], rev=1, action="answer", mid="m-ana",
                 values={"selected": ["ua1187"]})["result"] == "ok"


def test_a_name_anyone_can_take_isnt_who_answers(widgets):
    """`for` is matched by platform user id: a Telegram or Discord display name is anyone's (F9)."""
    group = {"platform": "telegram", "session_id": "sess-group2", "chat_id": "-101", "chat_type": "group",
             "user_id": "7", "user_name": "Maya"}
    widget = make(widgets, {**example("choice-1"), "for": {"name": "Maya"}}, binding=group)
    impostor = {**group, "user_id": "9", "user_name": "Maya"}
    refused = claim(widgets, binding=impostor, id=widget["id"], rev=1, action="answer", mid="m-x", values={"selected": ["ua1187"]})
    assert refused["result"] == "not_for_you"
    assert claim(widgets, binding=group, id=widget["id"], rev=1, action="answer", mid="m-ana2",
                 values={"selected": ["ua1187"]})["result"] == "ok"


def test_a_discord_thread_is_a_group(widgets):
    """Hermes calls Discord's threads "thread": every chat but a person's own is a group (F25)."""
    thread = {"platform": "discord", "session_id": "sess-thread", "chat_id": "t-1", "chat_type": "thread",
              "user_id": "7", "user_name": "Maya"}
    widget = make(widgets, {**example("choice-1"), "for": {"name": "Maya", "user": "7"}}, binding=thread)
    other = {**thread, "user_id": "8", "user_name": "Eli"}
    assert claim(widgets, binding=other, id=widget["id"], rev=1, action="answer", mid="m-ivo2",
                 values={"selected": ["ua1187"]})["result"] == "not_for_you"


def test_resolve_records_the_answer_and_only_the_producer_changes_a_widget(widgets):
    widget = make(widgets, example("approval-1"), profile="chef-remy")
    claim(widgets, profile="chef-remy", id=widget["id"], rev=1, action="approve", mid="m-1", values={}, device="Mac")
    with session(**APP, profile="hermes"):
        refused = call(widgets, {"op": "resolve", "id": widget["id"], "state": "done"}, session_id="sess-app")
    assert "only Chef Remy can change" in refused["error"]
    with session(**APP, profile="chef-remy"):
        done = call(widgets, {"op": "resolve", "id": widget["id"], "state": "done", "message": "Ordered · arrives 12:30",
                              "undo": {"action": "cancel_order", "until": "2026-10-16T11:40:00-04:00"}}, session_id="sess-app")
    assert "error" not in done, done
    resolution = done["payload"]["resolution"]
    assert done["rev"] == 2 and resolution["state"] == "done" and resolution["action"] == "approve" and resolution["by"] == "Mac"
    assert done["fallback_text"].startswith("Order lunch?: Ordered · arrives 12:30.")
    assert "Open the Hermes app" not in done["fallback_text"]
    # The resolution's Undo is still answerable; another approve isn't.
    assert claim(widgets, profile="chef-remy", id=widget["id"], rev=2, action="cancel_order", mid="m-u", values={})["result"] == "ok"
    assert claim(widgets, profile="chef-remy", id=widget["id"], rev=2, action="approve", mid="m-a", values={})["result"] == "already_answered"


def test_retry_after_a_failure(widgets):
    widget = choice(widgets)
    claim(widgets, id=widget["id"], rev=1, action="answer", mid="m-1", values={"selected": ["ua1187"]})
    with session(**APP, profile="hermes"):
        failed = call(widgets, {"op": "resolve", "id": widget["id"], "state": "failed", "message": "Sold out"},
                      session_id="sess-app")
    assert claim(widgets, id=widget["id"], rev=2, action="retry", mid="m-r", values={})["result"] == "ok"
    assert failed["payload"]["state"] == "critical"


def test_stack_children_are_widgets_of_their_own(widgets):
    stack = make(widgets, example("stack-1"))
    child_id = stack["children"]["c3"]
    child = widgets.store.latest(child_id)
    assert child["type"] == "checklist" and widgets.store.get(child_id)["parent"] == stack["id"]
    payload = example("stack-1")["children"][2]
    payload.pop("ref")
    payload["items"][0]["checked"] = True
    with session(**APP, profile="hermes"):
        updated = call(widgets, {"op": "update", "id": child_id, "payload": payload}, session_id="sess-app")
    assert "error" not in updated, updated
    assert updated["id"] == child_id and updated["rev"] == 2
    stored_stack = widgets.store.latest(stack["id"])
    assert stored_stack["rev"] == 2
    assert next(c for c in stored_stack["children"] if c["id"] == child_id)["items"][0]["checked"] is True


def test_get_and_the_app_command(widgets):
    widget = choice(widgets)
    with session(**APP, profile="hermes"):
        got = call(widgets, {"op": "get", "id": widget["id"]}, session_id="sess-app")
    assert got["payload"] == widget["payload"]
    fetched = widgets.command("get", {"id": widget["id"]})
    assert fetched["ok"] and fetched["payload"] == widget["payload"]
    assert widgets.command("status", {})["version"] == plugin_module("core").VERSION
    with session(source="desktop", session_id="20261016_101500_ab12cd", session_key="20261016_101500_ab12cd"):
        marked = widgets.command("session", {"session_id": "ui-7"})
    assert marked["session_ids"] == ["ui-7", "20261016_101500_ab12cd"]
    assert widgets.session("20261016_101500_ab12cd", "desktop").app
    with session(platform="telegram", session_id="sess-tg", chat_id="1"):
        assert widgets.command("keys.register", {"device_id": "x", "public_key": "AA"})["ok"] is False
        assert widgets.command("session", {"session_id": "sess-tg"})["ok"] is False


def test_helpers_get_nothing(widgets):
    widgets.subagent_start(child_session_id="sess-child")
    with session(platform="api_server", session_id="sess-child"):
        refused = call(widgets, {"op": "create", "payload": example("metric-1")}, session_id="sess-child")
    assert "helper" in refused["error"]
    assert widgets.prompt_section({"platform": "subagent", "session_id": "x"}) == ""
