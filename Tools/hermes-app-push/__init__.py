"""hermes-app-push: push notifications for the Hermes iPhone, iPad and Mac app.

Hermes Agent has no Apple push support, so this plugin listens to Hermes's documented plugin hooks
(approvals, questions, password prompts, finished turns, background work, group chats), seals each
notice for every registered device, and sends it through the Caffeinated Code push relay to APNs.
The relay sees only routing fields and the sealed envelope. Answers come back over the normal gateway
protocol (``approval.respond``, clarify responses); the plugin only reports.

The app talks to the plugin with ``command.dispatch {name: "app-push", arg: "<command> <json>"}``
(plugins can't add gateway RPC methods). Commands: register, unregister, preferences, presence,
activity, status, test. Each answers one line of JSON.

Scheduled tasks reach the app with ``deliver: apppush`` (and ``failure_deliver: apppush:fail``).
"""
from __future__ import annotations

import json
import logging
import os

from .core import Push, PushError

logger = logging.getLogger("hermes_app_push")

PLATFORM = "apppush"
HOOKS = ("pre_llm_call", "post_llm_call", "on_session_end", "pre_tool_call", "pre_approval_request",
         "post_approval_response", "on_human_input_request", "on_human_input_resolved",
         "on_room_member_activity", "kanban_task_completed", "kanban_task_blocked")

_push: Push | None = None


def _instance(ctx=None) -> Push:
    global _push
    if _push is None:
        config = (lambda key, default=None: ctx.get_config(key, default)) if ctx is not None else None
        _push = Push(config=config)
    return _push


def handle_command(raw: str) -> str:
    """``<command> <json>`` → one line of JSON. Never raises: ``command.dispatch`` turns an exception
    into "not a plugin command", which the app would read as "plugin missing"."""
    push = _instance()
    raw = (raw or "").strip()
    name, _, body = raw.partition(" ")
    if not name or name == "help":
        status = push.status({})
        return ("Hermes app push notifications.\n"
                f"Devices: {status['devices']} · relay: {status['relay_url']}"
                f"{' (registered)' if status['relay_registered'] else ''}\n"
                "The Hermes app manages this command; run `/app-push status {}` for details.")
    if name not in Push.COMMANDS:
        return json.dumps({"ok": False, "error": f"unknown command {name!r}"})
    try:
        args = json.loads(body) if body.strip() else {}
        if not isinstance(args, dict):
            raise PushError("arguments must be a JSON object")
        result = getattr(push, name)(args)
    except (PushError, ValueError) as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:  # report, never raise into command.dispatch
        logger.warning("app push: /app-push %s failed", name, exc_info=True)
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return json.dumps(result, separators=(",", ":"))


def _hook(name: str):
    def call(**kwargs):
        try:
            getattr(_instance(), f"on_{name}" if not name.startswith("on_") else name)(**kwargs)
        except Exception:
            logger.debug("app push: %s hook failed", name, exc_info=True)
    call.__name__ = f"app_push_{name}"
    return call


def _register_platform(ctx) -> None:
    """Cron delivery: ``deliver: apppush`` (all devices) or ``apppush:fail`` for failures."""
    try:
        from gateway.platforms.base import BasePlatformAdapter, SendResult
        from gateway.config import Platform
    except Exception:
        logger.debug("app push: gateway platform API unavailable; cron delivery off", exc_info=True)
        return

    class AppPushAdapter(BasePlatformAdapter):
        """Outbound only: the gateway's live lane for cron and send_message deliveries."""

        def __init__(self, config):
            super().__init__(config=config, platform=Platform(PLATFORM))

        async def connect(self, *, is_reconnect: bool = False) -> bool:
            # Only the gateway connects platforms: its process watches the boards for cards ready
            # for review or stopped (Hermes has no hook for those).
            _instance().watch_cards()
            return True

        async def disconnect(self) -> None:
            return None

        async def send(self, chat_id, content, reply_to=None, metadata=None):
            result = await _instance().send_cron(chat_id, content)
            if result.get("success"):
                return SendResult(success=True, message_id=result.get("message_id"))
            return SendResult(success=False, error=result.get("error"))

        async def get_chat_info(self, chat_id):
            return {"name": "Hermes app", "type": "dm"}

    async def standalone(pconfig, chat_id, message, *, thread_id=None, media_files=None, force_document=False):
        return await _instance().send_cron(chat_id, message)

    os.environ.setdefault("HERMES_APP_PUSH_HOME", "all")  # bare ``deliver: apppush`` → every device
    try:
        ctx.register_platform(
            name=PLATFORM, label="Hermes app", adapter_factory=lambda cfg: AppPushAdapter(cfg),
            check_fn=lambda: True, validate_config=lambda cfg: True,
            is_connected=lambda cfg: bool(_instance().store.devices()),
            cron_deliver_env_var="HERMES_APP_PUSH_HOME", standalone_sender_fn=standalone,
            emoji="📱", pii_safe=True, max_message_length=4000,
            platform_hint="Deliveries become push notifications in the Hermes app: keep them short.")
    except Exception:
        # ``plugins.isolation: host`` refuses platforms; hooks and the app commands still work.
        logger.info("app push: couldn't register the %s delivery platform", PLATFORM, exc_info=True)


def register(ctx) -> None:
    _instance(ctx)
    for name in HOOKS:
        ctx.register_hook(name, _hook(name))
    ctx.register_command("app-push", handler=handle_command, args_hint="<command> <json>",
                         description="Push notifications for the Hermes app (managed by the app).")
    _register_platform(ctx)
