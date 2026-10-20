"""hermes-app-widgets: widgets agents send to the Hermes iPhone, iPad and Mac app.

An agent creates a widget with the ``widget`` tool. The plugin validates it against the bundled
schemas and rules, fills its plain-text version, stores every revision and returns the payload and a
one-line directive (``::widget{id="w_…" alt="…"}``) for the reply. The app reads the payload from the
tool result and draws the card where the directive is; every other platform gets the plain text in
its place (``transform_llm_output``, before the reply is stored). Answers come back as messages, and
``widget(op: "claim")`` is the gate before acting on one. Contract: docs/widgets/payload-contract.md
in the design project; the bundled copy is in ``spec/``.

The app talks to the plugin with ``command.dispatch {name: "app-widgets", arg: "<command> <json>"}``
(plugins can't add gateway RPC methods): session, room, get, keys.register, keys.remove, keys.list, status.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

logger = logging.getLogger("hermes_app_widgets")

HERE = Path(__file__).resolve().parent
# Hermes gives register() 10 s, and a busy gateway reloads every profile's plugins at once. So
# register() imports nothing heavy: the engine (core and the validator) loads on first use.
_widgets = None
_ctx = None
RESOLUTIONS = ("done", "failed", "rejected", "cancelled", "expired", "elsewhere")
COMMANDS = ("session", "room", "get", "keys.register", "keys.remove", "keys.list", "status")

WIDGET_SCHEMA = {
    "name": "widget",
    "description": (
        "Show structured, glanceable or actionable content as a widget in the Hermes app (numbers, lists, "
        "schedules, statuses, choices, approvals). create returns a `directive`: put it on its own line in your "
        "reply, after one plain sentence. Other platforms get the widget's plain text automatically. update sends "
        "the whole payload again; resolve closes a request; claim is the gate before acting on an answer "
        "(act only on ok); get reads a widget. The `widgets` skill has the full guide; widget_examples(type) "
        "shows complete payloads."),
    "parameters": {
        "type": "object",
        "properties": {
            "op": {"type": "string", "enum": ["create", "update", "resolve", "claim", "get"]},
            "payload": {"type": "object", "description": (
                "create / update: the widget, as schemas/input/<type>.input.schema.json: type, v (1), title, "
                "as_of (RFC 3339 with offset) and the type's fields. No id, rev or producer; fallback_text is "
                "optional (the tool writes it). from_file {path, parser} fills fields from a file a tool wrote.")},
            "id": {"type": "string", "description": "update, resolve, claim, get: the widget id (w_…)."},
            "rev": {"type": "integer", "description": "claim: the revision the answer is for."},
            "action": {"type": "string", "description": "claim: the action id from the answer's first line."},
            "mid": {"type": "string", "description": "claim: the mid from the answer's JSON line."},
            "values": {"type": "object", "description": "claim: the values object from the answer's JSON line."},
            "sig": {"type": "string", "description": "claim: the sig from the answer's JSON line, when there is one."},
            "device": {"type": "string", "description": "claim: the device from the answer's JSON line."},
            "state": {"type": "string", "enum": list(RESOLUTIONS), "description": "resolve: what happened."},
            "message": {"type": "string", "description": "resolve: one line, ≤ 120 characters: “Ordered · arrives 12:30”."},
            "answer": {"type": "object", "description": "resolve: a choice's answer {selected, other?}."},
            "submitted": {"type": "object", "description": "resolve: a form's submitted values."},
            "undo": {"type": "object", "description": "resolve: {action, until} when it can be undone."},
            "undone": {"type": "object", "description": "resolve: a receipt's undone block."},
        },
        "required": ["op"],
    },
}

EXAMPLES_SCHEMA = {
    "name": "widget_examples",
    "description": "Complete example payloads, limits and the text-fallback rule for one widget type. Call it "
                   "before using a type for the first time.",
    "parameters": {"type": "object", "properties": {"type": {"type": "string", "description": "metric, list, approval…"}},
                   "required": ["type"]},
}


def _instance():
    global _widgets
    if _widgets is None:
        from .core import Widgets
        ctx = _ctx
        config = (lambda key, default=None: ctx.get_config(key, default)) if ctx is not None else None
        cron = getattr(ctx, "current_cron_execution", None) if ctx is not None else None
        profile = getattr(ctx, "profile_name", None) if ctx is not None else None
        _widgets = Widgets(config=config, cron_execution=cron, profile=profile if isinstance(profile, str) else None)
    return _widgets


def _handle(args, **kwargs):
    return _instance().handle(args, **kwargs)


def _examples(args, **kwargs):
    return _instance().examples(args, **kwargs)


def _section(info):
    try:
        return _instance().prompt_section(info)
    except Exception:
        logger.debug("widgets: prompt section failed", exc_info=True)
        return ""


def handle_command(raw: str) -> str:
    """``<command> <json>`` → one line of JSON. Never raises (``command.dispatch`` would turn an
    exception into "not a plugin command", which the app reads as "plugin missing")."""
    widgets = _instance()
    raw = (raw or "").strip()
    name, _, body = raw.partition(" ")
    if not name or name == "help":
        status = widgets.command("status", {})
        return (f"Hermes app widgets {status.get('version')}: {status.get('widgets')} widgets, "
                f"{status.get('keys')} signing keys.\nThe Hermes app manages this command; run "
                "`/app-widgets status {}` for details.")
    if name not in COMMANDS:
        return json.dumps({"ok": False, "error": f"unknown command {name!r}"})
    try:
        args = json.loads(body) if body.strip() else {}
        if not isinstance(args, dict):
            raise ValueError("arguments must be a JSON object")
        result = widgets.command(name, args)
    except ValueError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:
        logger.warning("widgets: /app-widgets %s failed", name, exc_info=True)
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return json.dumps(result, ensure_ascii=False, separators=(",", ":"))


def _hook(name: str):
    def call(**kwargs):
        try:
            return getattr(_instance(), name)(**kwargs)
        except Exception:
            logger.debug("widgets: %s hook failed", name, exc_info=True)
            return None
    call.__name__ = f"app_widgets_{name}"
    return call


def _pin_results() -> None:
    """Widget results are stored whole: Hermes spills a large tool result to a file and stores a
    1,500-character preview instead, and the app reads the payload from the stored result. Payloads
    are capped at 64 KB, so pinning the tool the way Hermes pins read_file costs at most that."""
    try:
        from tools.budget_config import PINNED_THRESHOLDS
        PINNED_THRESHOLDS.setdefault("widget", float("inf"))
    except Exception:
        logger.info("widgets: couldn't pin widget results; large payloads may be stored as a preview")


def _frontmatter(path: Path) -> dict:
    text = path.read_text()
    if not text.startswith("---"):
        return {}
    block = text.split("---", 2)[1]
    try:
        import yaml
        data = yaml.safe_load(block)
        return data if isinstance(data, dict) else {}
    except Exception:
        out = {}
        for line in block.splitlines():
            key, _, value = line.partition(":")
            if key.strip() and value.strip():
                out[key.strip()] = value.strip()
        return out


def register(ctx) -> None:
    global _ctx, _widgets
    _ctx, _widgets = ctx, None
    ctx.register_tool("widget", "widgets", WIDGET_SCHEMA, _handle,
                      description=WIDGET_SCHEMA["description"], emoji="🧩")
    ctx.register_tool("widget_examples", "widgets", EXAMPLES_SCHEMA, _examples,
                      description=EXAMPLES_SCHEMA["description"], emoji="🧩")
    _pin_results()
    ctx.register_system_prompt_section("hermes-app-widgets", _section)
    skill = HERE / "skills" / "widgets" / "SKILL.md"
    try:
        meta = _frontmatter(skill)
        ctx.register_skill("widgets", skill, description=str(meta.get("description") or ""), frontmatter=meta)
    except Exception:
        logger.info("widgets: couldn't register the widgets skill", exc_info=True)
    for name in ("pre_llm_call", "transform_llm_output", "pre_gateway_dispatch", "subagent_start"):
        ctx.register_hook(name, _hook(name))
    ctx.register_command("app-widgets", handler=handle_command, args_hint="<command> <json>",
                         description="Widgets for the Hermes app (managed by the app).")
