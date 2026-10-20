"""Validation (payload-contract.md §10): every example passes as tool input, every examples/invalid/
payload fails for its stated reason, errors read as instructions, and the semantic rules hold."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from harness import as_input, call, plugin_module, session

SPEC = Path(__file__).resolve().parents[1] / "spec"
EXAMPLES = sorted((SPEC / "examples").glob("*.json"))
INVALID = sorted((SPEC / "examples" / "invalid").glob("*.json"))


def producer_of(example: dict) -> str:
    """The Bot that made an example: its producer, or the Bot its icon names."""
    bot = (example.get("producer") or {}).get("bot")
    icon = example.get("icon") or ""
    return bot or (icon[4:] if icon.startswith("bot:") else "") or "hermes"


def create(widgets, payload, profile="hermes", **binding):
    values = {"platform": "api_server", "session_id": "sess-app", "profile": profile, **binding}
    with session(**values):
        return call(widgets, {"op": "create", "payload": payload}, session_id=values["session_id"])


@pytest.mark.parametrize("path", EXAMPLES, ids=[p.stem for p in EXAMPLES])
def test_every_example_is_accepted(widgets, path):
    example = json.loads(path.read_text())
    result = create(widgets, as_input(example), profile=producer_of(example))
    assert "error" not in result, result["error"]
    payload = result["payload"]
    assert result["id"].startswith("w_") and result["rev"] == 1 and payload["id"] == result["id"]
    assert result["directive"].startswith(f'::widget{{id="{result["id"]}"')
    assert payload["producer"]["bot"] == producer_of(example)
    # The stored payload validates against the full schema, with every child against its own type.
    validate = plugin_module("validate")
    assert validate.schema_issues(widgets.spec, payload["type"], payload) == []
    for ref, child_id in result["children"].items():
        assert widgets.store.latest(child_id)["id"] == child_id


@pytest.mark.parametrize("path", EXAMPLES, ids=[p.stem for p in EXAMPLES])
def test_every_example_gets_a_generated_fallback(widgets, path):
    example = as_input(json.loads(path.read_text()))
    example.pop("fallback_text", None)
    for child in example.get("children") or []:
        child.pop("fallback_text", None)
    result = create(widgets, example, profile=producer_of(json.loads(path.read_text())))
    assert "error" not in result, result["error"]
    text = result["fallback_text"]
    cap = 4000 if example["type"] == "stack" else 2000
    assert 20 <= len(text) <= cap
    prose = re.sub(r"```.*?```", "", text, flags=re.S)  # code keeps its braces
    assert not re.search(r"\bnull\b|\bundefined\b|[{}]", prose), text


def stated_paths(comment: str) -> set[str]:
    """The field paths a fixture's $comment says it fails at ("consequences: 'cost' is a required
    property" → consequences.cost)."""
    reasons = comment.split("Must fail validation: ", 1)[1].split("; ")
    out = set()
    for reason in reasons:
        where, _, message = reason.partition(": ")
        parts = [] if where == "(root)" else where.split("/")
        missing = re.match(r"'([^']+)' is a required property", message)
        if missing:
            parts.append(missing.group(1))
        out.add(".".join(parts))
    return out


def dotted(path: str) -> str:
    return re.sub(r"\.(\d+)(?=\.|$)", r"[\1]", path)


@pytest.mark.parametrize("path", INVALID, ids=[p.stem for p in INVALID])
def test_every_invalid_payload_fails_for_its_reason(widgets, path):
    fixture = json.loads(path.read_text())
    payload = as_input(fixture["payload"])
    result = create(widgets, payload, profile=producer_of(fixture["payload"]))
    assert "error" in result, f"{path.name} was accepted"
    # The same validator the tool uses, on the full payload, names exactly the stated paths…
    validate = plugin_module("validate")
    raw = validate.raw_errors(widgets.spec, fixture["payload"]["type"], fixture["payload"])
    found = set()
    for error in raw:
        parts = [str(p) for p in error.absolute_path]
        missing = re.match(r"'([^']+)' is a required property", error.message)
        if missing:
            parts.append(missing.group(1))
        found.add(".".join(parts))
    for stated in stated_paths(fixture["$comment"]):
        assert stated in found or not stated, f"{path.name}: {stated} isn't among {found}"
    # …and the tool's error tells the agent where (unless the reason was an id the tool sets anyway).
    for stated in stated_paths(fixture["$comment"]):
        if stated and stated.split(".")[0] not in ("id", "rev", "producer") and not stated.startswith("children."):
            head = dotted(stated).split(".")[0].split("[")[0]
            assert head in result["error"], f"{path.name}: the error doesn't name {stated}: {result['error']}"


def test_errors_name_the_path_the_allowed_values_and_a_close_match(widgets):
    payload = {"type": "metric", "v": 1, "title": "Revenue", "as_of": "2026-10-16T09:41:00+02:00",
               "items": [{"label": "Today", "value": {"value": 3}, "delta": {"value": 0.1, "good": "upward"}}],
               "colour": "red"}
    error = create(widgets, payload)["error"]
    assert 'items[0].delta.good: "upward" isn\'t allowed; use up, down or neutral' in error
    assert 'unknown field "colour"' in error
    approval = {"type": "approval", "v": 1, "title": "Buy?", "as_of": "2026-10-16T11:12:00+02:00",
                "expires_at": "2026-10-16T11:30:00+02:00",
                "subject": {"kind": "purchase", "verb": "Buy"}, "consequences": {"affects": ["You"], "reversible": "no"}}
    assert "consequences.cost is required when subject.kind is purchase, spend, booking or transfer" in \
        create(widgets, approval)["error"]
    assert 'did you mean "metric"' in create(widgets, {**payload, "type": "metrik"})["error"]
    assert "id is set by the tool" in create(widgets, {**payload, "id": "w_mine123"})["error"]


def base(**fields):
    return {"type": "list", "v": 1, "title": "Tickets", "as_of": "2026-10-16T09:00:00+02:00",
            "items": [{"title": "One"}], **fields}


def test_semantic_rules(widgets):
    def error(payload, **kw):
        return create(widgets, payload, **kw).get("error", "")

    assert "reserved" in error(base(actions=[{"id": "approve", "label": "Approve"}]))
    assert "used twice" in error(base(actions=[{"id": "a", "label": "A"}, {"id": "a", "label": "B"}]))
    assert "two primary" in error(base(actions=[{"id": "a", "label": "A", "style": "primary"},
                                                {"id": "b", "label": "B", "style": "primary"}])).replace("2 primary", "two primary")
    assert "destructive action needs confirm" in error(base(actions=[{"id": "del", "label": "Delete", "style": "destructive"}]))
    assert "isn't after as_of" in error(base(expires_at="2026-10-16T08:00:00+02:00"))
    assert "card number" in error(base(items=[{"title": "Card 4242 4242 4242 4242"}]))
    assert "secret patterns" in error(base(items=[{"title": "key sk-FAKE-not-a-real-key-0000000000000000"}]))
    assert "names another Bot" in error(base(icon="bot:scout"))
    assert error(base(icon="bot:scout"), profile="scout") == ""
    group = {"chat_type": "group", "platform": "telegram", "chat_id": "-100", "user_name": "Maya"}
    assert "private widget in a group chat" in error(base(sensitivity="private"), **group)
    form = {"type": "form", "v": 1, "title": "Details", "as_of": "2026-10-16T09:00:00+02:00",
            "fields": [{"id": "who", "kind": "text", "label": "Who"}]}
    assert "needs for" in error(form, **group)
    assert error({**form, "for": {"name": "Maya"}}, **group) == ""
    assert "asks for a secret" in error({**form, "fields": [{"id": "pin", "kind": "text", "label": "Your PIN"}]})
    chart = {"type": "chart", "v": 1, "title": "Installs", "as_of": "2026-10-16T09:00:00+02:00", "kind": "line",
             "x": {"values": ["Mon", "Tue", "Wed"]}, "series": [{"label": "Installs", "values": [1, 2]}]}
    assert "series[0] has 2 values for 3 x values" in error(chart)
    table = {"type": "table", "v": 1, "title": "Apps", "as_of": "2026-10-16T09:00:00+02:00",
             "columns": [{"key": "app", "label": "App"}], "rows": [{"app": "x", "chang": 1}]}
    assert 'did you mean "app"' not in error(table) and "isn't a column" in error(table)


def test_warnings_are_returned_and_stored(widgets):
    payload = {"type": "metric", "v": 1, "title": "Growth", "as_of": "2026-10-16T09:00:00+02:00", "icon": "rocket.fill",
               "items": [{"label": "Growth", "value": {"value": 12, "format": "percent"}}],
               "fallback_text": "Growth is 12% tomorrow."}
    result = create(widgets, payload)
    assert "error" not in result
    joined = " ".join(result["warnings"])
    assert "send 0.12 for 12%" in joined and "isn't in the symbol allowlist" in joined and "tomorrow" in joined
    assert widgets.store.get(result["id"])["warnings"] == result["warnings"]


def test_signed_approvals_never_invite_a_text_answer(widgets):
    example = json.loads((SPEC / "examples" / "approval-1.json").read_text())
    result = create(widgets, as_input(example), profile="chef-remy")
    assert result["fallback_text"].endswith("Open the Hermes app to approve; this can't be approved by text.")
    assert "Reply" not in result["fallback_text"]
    free = {"type": "approval", "v": 1, "title": "Post the update?", "as_of": "2026-10-16T11:12:00+02:00",
            "expires_at": "2026-10-16T12:00:00+02:00",
            "subject": {"kind": "post", "verb": "Post", "message": {"to": {"name": "Team"}, "channel": "Slack", "text": "Shipped"}},
            "consequences": {"affects": ["The team channel"], "reversible": "yes"}}
    assert "Reply “approve”, “edit” or “reject”." in create(widgets, free)["fallback_text"]


def test_payloads_over_64_kb_are_refused(widgets):
    payload = {"type": "code", "v": 1, "title": "Log", "as_of": "2026-10-16T09:00:00+02:00", "kind": "log",
               "lines": [{"text": "x" * 1990} for _ in range(40)]}
    assert "at most 64 KB" in create(widgets, payload)["error"]


def test_examples_tool(widgets):
    result = json.loads(widgets.examples({"type": "checklist"}))
    assert result["examples"] and all("id" not in e and "producer" not in e for e in result["examples"])
    assert result["limits"] and result["fallback"]
    assert "did you mean" in json.loads(widgets.examples({"type": "checklst"}))["error"]


def test_a_private_widgets_directive_carries_only_its_title(widgets):
    example = json.loads((SPEC / "examples" / "meter-1.json").read_text())  # the October budget, private
    result = create(widgets, as_input(example))
    assert result["directive"].endswith('alt="October budget"}')


def test_a_types_own_built_in_may_be_an_envelope_action(widgets):
    alert = {"type": "alert", "v": 1, "title": "Checkout", "as_of": "2026-10-16T14:06:00+02:00", "severity": "critical",
             "headline": "Checkout is down", "next": "Switch to the backup provider", "actions": [{"id": "acknowledge", "label": "Acknowledge"}]}
    assert "error" not in create(widgets, alert)
    assert "reserved" in create(widgets, {**alert, "actions": [{"id": "approve", "label": "Approve"}]})["error"]
    form = {"type": "form", "v": 1, "title": "Details", "as_of": "2026-10-16T09:00:00+02:00",
            "fields": [{"id": "who", "kind": "text", "label": "Who"}],
            "actions": [{"id": "submit", "label": "Send"}, {"id": "cancel", "label": "Not Now"}]}
    assert "error" not in create(widgets, form)
    assert "reserved" in create(widgets, base(actions=[{"id": "acknowledge", "label": "Acknowledge"}]))["error"]
