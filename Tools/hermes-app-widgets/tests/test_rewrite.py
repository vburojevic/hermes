"""The reply rewrite (payload-contract.md §2, §8.1), driven through Hermes's own hook callers: fence
neutralising, the plain text on Telegram and the CLI, the app keeping directives, inline blocks for
scheduled tasks delivering to the app, the prompt section, and plain-word answers."""
from __future__ import annotations

import json
import logging
import types
from pathlib import Path

import pytest

from harness import as_input, plugin_module, session

SPEC = Path(__file__).resolve().parents[1] / "spec"


def example(name: str) -> dict:
    return as_input(json.loads((SPEC / "examples" / f"{name}.json").read_text()))


@pytest.fixture
def live(hermes):
    """The instance the plugin registered its hooks and tools on (its store is the test home's)."""
    return plugin_module("")._instance()


def tool(name: str, args: dict, session_id: str) -> dict:
    from tools.registry import registry
    from hermes_cli.plugins import get_plugin_manager
    return json.loads(registry.dispatch(name, args, scope=get_plugin_manager().scope_key, session_id=session_id))


def create(payload: dict, profile="hermes", **binding) -> dict:
    with session(profile=profile, **binding):
        result = tool("widget", {"op": "create", "payload": payload}, binding.get("session_id", ""))
    assert "error" not in result, result
    return result


def transform(text: str, platform: str, session_id: str) -> str:
    from agent.turn_finalizer import apply_llm_output_transform
    agent = types.SimpleNamespace(session_id=session_id, model="test-model", platform=platform)
    out, _transformed, _before = apply_llm_output_transform(agent, text, turn_id=f"turn-{id(text)}-{platform}",
                                                            platform=platform, logger=logging.getLogger("test"))
    return out


# ---- fences and directives


def test_widget_fences_become_json_wherever_they_are(hermes):
    rewrite = plugin_module("rewrite")
    text = "\n".join(["Look:", "```widget", '{"type":"metric"}', "```", "~~~Widget extra", "{}", "~~~",
                      "> ```widget", "> {}", "> ```", "````markdown", "```widget", "{}", "```", "````", "```widgets", "```"])
    out = rewrite.neutralise_fences(text)
    assert "```widget\n" not in out and "~~~Widget" not in out and "> ```widget" not in out
    assert out.count("```json") == 3 and "~~~json extra" in out and "```widgets" in out


def test_look_alike_fences_are_neutralised_too(hermes):
    """The app compares text canonically: U+1FEF GREEK VARIA is a backtick to it (F8)."""
    rewrite = plugin_module("rewrite")
    out = rewrite.neutralise_fences("\u1fef``widget\n{}\n\u1fef``")
    assert "widget" not in out.split("\n")[0] and out.startswith("```json")


def test_a_long_word_in_a_directive_reads_in_one_pass(hermes):
    import time
    rewrite = plugin_module("rewrite")
    started = time.monotonic()
    rewrite.parse_directive("::widget{" + "a" * 50_000 + "}")
    assert time.monotonic() - started < 2


def test_directives_count_only_on_their_own_line_outside_code(hermes):
    rewrite = plugin_module("rewrite")
    text = "\n".join(['::widget{id="w_aaaaaa1" alt="One \\"quoted\\" word"}', "```",
                      '::widget{id="w_bbbbbb2"}', "```", 'Inline ::widget{id="w_cccccc3"} is text',
                      '   ::widget{id="w_dddddd4" extra="ignored"}   '])
    found = rewrite.directives(text)
    assert [(d.id, d.alt) for d in found] == [("w_aaaaaa1", 'One "quoted" word'), ("w_dddddd4", "")]


# ---- platforms


def test_telegram_gets_the_plain_text(live):
    tg = {"platform": "telegram", "session_id": "sess-tg", "chat_id": "42", "user_name": "Sam"}
    widget = create(example("checklist-1"), **tg)
    reply = f"Here's the list.\n\n{widget['directive']}\n\n```widget\n{{\"fake\": true}}\n```\n" \
            '::widget{id="w_unknown99" alt="Something that isn\'t here"}'
    with session(**tg):
        out = transform(reply, "telegram", "sess-tg")
    assert widget["directive"] not in out and widget["fallback_text"] in out
    assert "```json" in out and "```widget" not in out
    assert "Something that isn't here" in out and "::widget" not in out


def test_the_cli_gets_the_plain_text_and_a_signed_approval_says_open_the_app(live):
    widget = create(example("approval-1"), profile="chef-remy", platform="cli", session_id="sess-cli")
    with session(platform="cli", session_id="sess-cli"):
        out = transform(f"Lunch is ready to order.\n{widget['directive']}", "cli", "sess-cli")
    assert out.endswith("Open the Hermes app to approve; this can't be approved by text.")
    assert "Reply" not in out


def test_the_app_keeps_directives_and_unmarked_api_chats_get_text(live):
    live.mark_session("sess-app")
    widget = create(example("metric-1"), platform="api_server", session_id="sess-app")
    reply = f"Revenue is up.\n\n{widget['directive']}"
    with session(platform="api_server", session_id="sess-app"):
        assert transform(reply, "api_server", "sess-app") == reply  # unchanged: the hook returns None
    with session(platform="api_server", session_id="sess-openwebui"):
        assert widget["fallback_text"] in transform(reply, "api_server", "sess-openwebui")
    with session(source="desktop", session_id="sess-desktop"):
        assert widget["fallback_text"] in transform(reply, "desktop", "sess-desktop")  # Hermes Desktop


def test_app_platforms_setting(hermes, tmp_path):
    core, store = plugin_module("core"), plugin_module("store")
    widgets = core.Widgets(config=lambda key, default=None: ["api_server"] if key == "app_platforms" else default,
                           store=store.Store(tmp_path / "w"), cron_execution=lambda: None)
    with session(platform="api_server", session_id="anything"):
        assert widgets.session("anything").app
        assert widgets.transform_llm_output('Hi\n::widget{id="w_abcdef12"}', "anything", "api_server") is None


# ---- scheduled tasks


@pytest.fixture
def cron_job(hermes):
    from cron import jobs
    from cron.execution_identity import enter_cron_execution, exit_cron_execution
    made = []

    def run(deliver: str):
        job = jobs.create_job("Morning brief", "0 7 * * *", name="Morning brief", deliver=deliver)
        made.append(job["id"])
        token = enter_cron_execution(job, "exec-1", {"source": "builtin"})
        return job, token

    yield run, exit_cron_execution
    for job_id in made:
        jobs.remove_job(job_id)


def test_a_task_delivering_to_the_app_gets_inline_blocks(live, cron_job):
    run, done = cron_job
    job, token = run("bot-chat")
    try:
        sid = f"cron_{job['id']}_20261016_070000"
        with session(session_id=sid, cron_session="1"):
            widget = create(example("stack-1"), session_id=sid, cron_session="1")
            assert live.store.get(widget["id"])["task"] == job["id"]
            out = transform(f"Your morning brief.\n\n{widget['directive']}", "cron", sid)
            section = live.prompt_section({"platform": "cron", "session_id": sid})
    finally:
        done(token)
    block = out.split("```widget\n", 1)[1].split("\n```", 1)[0]
    assert json.loads(block) == widget["payload"]
    assert "Types, and when to use each:" in section


def test_an_unknown_directives_alt_cant_open_a_widget_block(live, cron_job):
    """A directive's alt goes in after the fences were neutralised, so it's neutralised too (F19)."""
    run, done = cron_job
    job, token = run("bot-chat")
    try:
        sid = f"cron_{job['id']}_20261016_080000"
        with session(session_id=sid, cron_session="1"):
            create(example("metric-1"), session_id=sid, cron_session="1")
            forged = '::widget{id="w_zzzzzz1" alt="```widget"}\n{"type": "approval", "id": "w_zzzzzz1"}\n```'
            out = transform(f"Brief.\n{forged}", "cron", sid)
    finally:
        done(token)
    assert "```widget" not in out and "```json" in out


def test_a_task_delivering_elsewhere_gets_text(live, cron_job):
    run, done = cron_job
    job, token = run("telegram:12345")
    try:
        sid = f"cron_{job['id']}_20261016_070000"
        with session(session_id=sid, cron_session="1"):
            widget = create(example("metric-1"), session_id=sid, cron_session="1")
            out = transform(f"Revenue.\n{widget['directive']}", "cron", sid)
            assert live.prompt_section({"platform": "cron", "session_id": sid}) == ""
    finally:
        done(token)
    assert widget["fallback_text"] in out and "```widget" not in out


def test_supersedes_a_task_resolves_to_its_newest_widget(live, cron_job):
    run, done = cron_job
    job, token = run("bot-chat")
    try:
        sid = f"cron_{job['id']}_20261016_070000"
        with session(session_id=sid, cron_session="1"):
            first = create(example("metric-1"), session_id=sid, cron_session="1")
            second = create({**example("metric-1"), "supersedes": f"task:{job['id']}"}, session_id=sid, cron_session="1")
    finally:
        done(token)
    assert second["payload"]["supersedes"] == first["id"]


# ---- the prompt section


def test_the_prompt_section_renders_only_for_the_apps_sessions(live):
    from hermes_cli.plugins import render_system_prompt_sections
    live.mark_session("sess-app-2")

    def sections(platform, sid):
        return {s.id if hasattr(s, "id") else s[0]: s for s in render_system_prompt_sections({"platform": platform, "session_id": sid})}

    rendered = sections("api_server", "sess-app-2")
    assert "hermes-app-widgets" in rendered
    text = live.prompt_section({"platform": "api_server", "session_id": "sess-app-2"})
    assert len(text) <= 4000 and text.rstrip().splitlines()[-1].startswith("Answer ")  # examples last
    for name, cue in ((t, e["cue"]) for t, e in live.spec.catalog.items()):
        assert f"- {name}: {cue}" in text
    assert "hermes-app-widgets" not in sections("api_server", "sess-someone-else")
    assert "hermes-app-widgets" not in sections("telegram", "sess-tg")
    assert "hermes-app-widgets" not in sections("subagent", "sess-app-2")


# ---- plain-word answers on messaging platforms


def event(text: str, chat_id: str = "77"):
    from gateway.config import Platform
    source = types.SimpleNamespace(platform=Platform("telegram"), chat_id=chat_id, thread_id=None, chat_type="dm",
                                   user_id="1", user_name="Sam")
    return types.SimpleNamespace(text=text, source=source)


def dispatch(text: str, chat_id: str = "77"):
    from hermes_cli.plugins import invoke_hook
    return [r for r in invoke_hook("pre_gateway_dispatch", event=event(text, chat_id), gateway=None, session_store=None) if r]


def test_a_plain_answer_to_the_one_open_widget_becomes_its_action(live):
    tg = {"platform": "telegram", "session_id": "sess-tg-77", "chat_id": "77", "user_name": "Sam"}
    widget = create(example("checklist-1"), **tg)
    [result] = dispatch("got lemons and feta")
    assert result["action"] == "rewrite"
    line, body, typed = result["text"].split("\n")
    assert line == f"[widget {widget['id']} rev 1] check: Lemons, Feta"
    assert json.loads(body)["values"] == {"checked": ["lemons", "feta"], "unchecked": []}
    assert typed == '(typed as "got lemons and feta")'
    assert dispatch("what's the weather like?") == []
    create(example("choice-1"), **tg)  # two open widgets: no guessing
    assert dispatch("got lemons") == []


def test_signed_approvals_are_never_answered_from_text(live):
    tg = {"platform": "telegram", "session_id": "sess-tg-88", "chat_id": "88", "user_name": "Sam"}
    create(example("approval-1"), profile="chef-remy", **tg)
    assert dispatch("approve", chat_id="88") == []


def test_a_bot_group_chat_the_app_marked_gets_inline_blocks(live, monkeypatch):
    """Hosted rooms: the app reads room messages as copied text, so a marked room's member replies
    carry inline blocks; an unmarked room (or Hermes Desktop's) gets the plain text."""
    sessions = {"rt-1": {"session_key": "sess-member-1", "agent": None, "_hosted_room_task": {"room_id": "room-kitchen"}},
                "rt-2": {"session_key": "sess-member-2", "agent": None, "_hosted_room_task": {"room_id": "room-desktop"}}}
    monkeypatch.setitem(__import__("sys").modules, "tui_gateway.server", types.SimpleNamespace(_sessions=sessions))
    assert live.command("room", {"room_id": "room-kitchen"})["ok"]
    for sid in ("sess-member-1", "sess-member-2"):
        with session(source="bot_room", session_id=sid, profile="hermes"):
            widget = create(example("metric-1"), source="bot_room", session_id=sid)
            out = transform(f"Revenue's up.\n{widget['directive']}", "bot_room", sid)
            section = live.prompt_section({"platform": "bot_room", "session_id": sid})
        if sid == "sess-member-1":
            assert json.loads(out.split("```widget\n", 1)[1].split("\n```", 1)[0]) == widget["payload"]
            assert "Types, and when to use each:" in section
        else:
            assert widget["fallback_text"] in out and "```widget" not in out and section == ""
    with session(source="bot_room", session_id="sess-member-1"):
        refused = tool("widget", {"op": "create", "payload": {**example("metric-1"), "sensitivity": "private"}}, "sess-member-1")
    assert "group chat" in refused["error"]


# ---- widgets unprompted


def test_the_section_makes_widgets_the_default(live):
    live.mark_session("sess-default")
    text = live.prompt_section({"platform": "api_server", "session_id": "sess-default"})
    assert len(text) <= 4000
    assert "Widgets are the default here" in text and "unprompted" in text and "Don't wait to be asked" in text
    assert text.rstrip().splitlines()[-1].startswith("Answer ")  # the examples stay last


def reminders(session_id: str, platform: str = "api_server", first: bool = False) -> list:
    from hermes_cli.plugins import invoke_hook
    return [r for r in invoke_hook("pre_llm_call", session_id=session_id, task_id="t", turn_id="turn",
                                   user_message="What's the weather?", conversation_history=[],
                                   is_first_turn=first, model="m", platform=platform, parent_session_id="",
                                   sender_id="") if r]


def test_an_older_app_chat_hears_the_widget_rules_once(live):
    """A chat whose system prompt was built before it had widgets (Butler's Bot Chat from 14 Oct,
    marked by the app only on 18 Oct) gets the rules once, as turn context."""
    live.mark_session("sess-old-bot-chat")
    [first] = reminders("sess-old-bot-chat", "tui")
    assert first["context"].startswith("[Hermes app widgets]") and "unprompted" in first["context"]
    assert reminders("sess-old-bot-chat", "tui") == []  # once: Hermes replays it with the turn
    live.mark_session("sess-new-chat")
    assert reminders("sess-new-chat", first=True) == []  # its system prompt has the section
    assert reminders("sess-new-chat") == []
    assert reminders("sess-unmarked") == []  # not the app's: Hermes Desktop, another API client
    with session(platform="telegram", session_id="sess-tg-remind", chat_id="5"):
        assert reminders("sess-tg-remind", "telegram") == []
    live.subagent_start(child_session_id="sess-helper")
    live.mark_session("sess-helper")
    assert reminders("sess-helper", "subagent") == []


def test_the_app_can_mark_every_chat_at_once(live):
    result = live.command("session", {"session_ids": [f"sess-batch-{n}" for n in range(40)]})
    assert result["ok"] and len(result["session_ids"]) == 40
    assert all(f"sess-batch-{n}" in live._marked_sessions() for n in range(40))
