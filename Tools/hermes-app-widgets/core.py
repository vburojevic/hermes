"""The widget tool, the claim gate and the reply rewrite (payload-contract.md §5, §6.3, §8, §9).

One ``Widgets`` per process. Tool calls, hooks and the ``/app-widgets`` command all come here; the
store under the Hermes root is shared by every process and profile.
"""
from __future__ import annotations

import copy
import json
import logging
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import fallback, parsers, rewrite, signing
from .store import Store
from .validate import MAX_PAYLOAD, Checks, Spec, WidgetError, schema_issues

logger = logging.getLogger("hermes_app_widgets")

VERSION = "1.3.0"
# Bumped when the one-time reminder (prompt.REMINDER) changes enough to send again.
REMINDER_VERSION = 2
OPS = ("create", "update", "resolve", "claim", "get")
RESOLUTIONS = ("done", "failed", "rejected", "cancelled", "expired", "elsewhere")
# The answers each primitive has without declaring them (payload-contract.md §6.1).
BUILT_IN = {"choice": {"answer"}, "form": {"submit", "cancel"}, "checklist": {"check"}, "control": {"set"},
            "approval": {"approve", "edit", "reject"}, "receipt": {"undo"}, "flashcard": {"rate"},
            "alert": {"acknowledge"}, "compare": {"answer"}}
# Platforms that are a person reading text (the reply's directives become fallback_text there).
APP_SOURCES = ("api_server", "desktop", "tui")
# One person's own chats. Every other chat type is a group (Discord's "thread" and "guild" and any
# type Hermes adds later included), so `for` is never skipped where others can answer.
PRIVATE_CHAT_TYPES = ("dm", "private", "")
MAX_SESSIONS = 5000
# Sessions whose compression ancestors were read, kept per process: a session's ancestors never change.
MAX_LINEAGES = 2000


def _session_env(name: str) -> str:
    try:
        from gateway.session_context import get_session_env
        return get_session_env(name, "") or ""
    except Exception:
        return os.environ.get(name, "") or ""


def now_local() -> datetime:
    return datetime.now(timezone.utc).astimezone()


def rfc3339(moment: datetime) -> str:
    return moment.isoformat(timespec="seconds")


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    except ValueError:
        return None
    return moment if moment.tzinfo else None


def _dump(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


@dataclass
class Session:
    """Who is asking: the session, its platform and chat, the sender and the Bot (profile)."""
    id: str = ""
    platform: str = ""
    chat_id: str = ""
    thread_id: str = ""
    chat_type: str = ""
    user_id: str = ""
    user_name: str = ""
    profile: str = ""
    cron_job: str | None = None
    subagent: bool = False
    app: bool = False
    producer: dict = field(default_factory=dict)

    @property
    def group(self) -> bool:
        return self.chat_type not in PRIVATE_CHAT_TYPES or self.platform == "bot_room"

    @property
    def messaging(self) -> bool:
        return bool(self.platform) and self.platform not in APP_SOURCES + ("cron", "subagent", "cli", "bot_room", "")

    @property
    def chat_keys(self) -> list[str]:
        keys = [f"session:{self.id}"] if self.id else []
        if self.messaging and self.chat_id:
            keys.append(chat_key(self.platform, self.chat_id, self.thread_id))
        return keys


def chat_key(platform: Any, chat_id: Any, thread_id: Any = "") -> str:
    name = getattr(platform, "value", platform)
    return f"chat:{str(name or '').lower()}:{chat_id or ''}:{thread_id or ''}"


class Widgets:
    def __init__(self, config: Callable[[str, Any], Any] | None = None, store: Store | None = None,
                 spec: Spec | None = None, clock: Callable[[], datetime] = now_local,
                 cron_execution: Callable[[], Any] | None = None, profile: str | None = None):
        self._config = config or (lambda key, default=None: default)
        self.store = store or Store()
        self.spec = spec or Spec()
        self.checks = Checks(self.spec)
        self.clock = clock
        self._cron_execution = cron_execution
        self._profile = profile
        self._subagents: set[str] = set()
        self._ancestors: dict[str, tuple[str, ...]] = {}

    # ---- settings

    def setting(self, key: str, default: Any = None) -> Any:
        try:
            value = self._config(key, default)
        except Exception:
            value = default
        return default if value is None else value

    def app_platforms(self) -> set[str]:
        raw = self.setting("app_platforms", [])
        if isinstance(raw, str):
            raw = [p.strip() for p in raw.split(",")]
        return {str(p).strip().lower() for p in raw or [] if str(p).strip()}

    # ---- sessions

    def _cron_job(self) -> str | None:
        execution = None
        try:
            if self._cron_execution is not None:
                execution = self._cron_execution()
            else:
                from cron.execution_identity import current_cron_execution
                execution = current_cron_execution()
        except Exception:
            execution = None
        job = getattr(execution, "job_id", None)
        return str(job) if job else None

    def _profile_name(self) -> str:
        name = _session_env("HERMES_SESSION_PROFILE") or self._profile or ""
        if not name:
            try:
                from hermes_cli.profiles import get_active_profile_name
                name = get_active_profile_name() or ""
            except Exception:
                name = ""
        return name

    def producer_for(self, profile: str) -> dict:
        """The Bot a profile is: the root is Hermes (``bot:hermes``), a profile is its own handle."""
        if profile in ("", "default", "root", "hermes"):
            return {"name": "Hermes", "bot": "hermes"}
        handle = re.sub(r"[^a-z0-9-]+", "-", profile.lower()).strip("-")[:40] or "bot"
        name = ""
        try:
            from hermes_cli.profiles import read_profile_meta
            from hermes_constants import get_default_hermes_root
            name = read_profile_meta(Path(get_default_hermes_root()) / "profiles" / profile).get("display_name") or ""
        except Exception:
            name = ""
        return {"name": (name or profile.replace("-", " ").title())[:40], "bot": handle}

    def session(self, session_id: str = "", platform: str = "") -> Session:
        sid = session_id or _session_env("HERMES_SESSION_ID")
        plat = (platform or _session_env("HERMES_SESSION_PLATFORM") or _session_env("HERMES_SESSION_SOURCE")).lower()
        job = self._cron_job()
        if job or _session_env("HERMES_CRON_SESSION") == "1" or (sid or "").startswith("cron_"):
            plat = "cron"
            job = job or _job_from_session(sid)
        profile = self._profile_name()
        s = Session(id=sid, platform=plat, chat_id=_session_env("HERMES_SESSION_CHAT_ID"),
                    thread_id=_session_env("HERMES_SESSION_THREAD_ID"),
                    chat_type=_session_env("HERMES_SESSION_CHAT_TYPE").lower(),
                    user_id=_session_env("HERMES_SESSION_USER_ID"), user_name=_session_env("HERMES_SESSION_USER_NAME"),
                    profile=profile, cron_job=job, producer=self.producer_for(profile))
        s.subagent = plat == "subagent" or (sid in self._subagents if sid else False)
        s.app = self.is_app_session(s)
        return s

    def is_app_session(self, s: Session) -> bool:
        if s.subagent:
            return False
        if s.platform == "cron":
            return self.delivers_to_app(s.cron_job)
        if s.platform == "bot_room":
            return self.in_marked_room(s.id)
        if s.platform in self.app_platforms():
            return True
        if not s.id:
            return False
        marked = self._marked_sessions()
        if s.id in marked:
            return True
        # Hermes compacts a long chat into a new session with a new id (a Bot Chat never ends, so it
        # compacts often), often in the middle of a turn. The app marked the chat under an earlier id,
        # so the new one is the app's too, and is marked for the next time.
        if s.messaging or not any(a in marked for a in self.ancestors(s.id)):
            return False
        self.mark_session(s.id, inherited=True)
        return True

    def ancestors(self, session_id: str) -> tuple[str, ...]:
        """The sessions Hermes compacted into this one, oldest first, from its session store (the
        profile's, then the root's). Empty when Hermes can't say: then only marks count."""
        if session_id in self._ancestors:
            return self._ancestors[session_id]
        found: tuple[str, ...] | None = None
        for path in _state_dbs():
            lineage = _compression_lineage(path, session_id)
            if lineage:
                found = tuple(lineage[:lineage.index(session_id)]) if session_id in lineage else ()
                break
        if found is None:
            return ()  # not stored yet: asked again next time
        if len(self._ancestors) >= MAX_LINEAGES:
            self._ancestors.pop(next(iter(self._ancestors)))
        self._ancestors[session_id] = found
        return found

    def _marks(self, kind: str = "sessions") -> dict:
        try:
            return json.loads((self.store.dir / "sessions.json").read_text()).get(kind, {})
        except (FileNotFoundError, ValueError):
            return {}

    def _marked_sessions(self) -> dict:
        return self._marks("sessions")

    def mark_session(self, session_id: str, kind: str = "sessions", **fields: Any) -> None:
        self.mark_sessions([session_id], kind, **fields)

    def mark_sessions(self, session_ids: list[str], kind: str = "sessions", **fields: Any) -> None:
        with self.store.locked():
            path = self.store.dir / "sessions.json"
            try:
                data = json.loads(path.read_text())
            except (FileNotFoundError, ValueError):
                data = {"sessions": {}}
            marks = data.setdefault(kind, {})
            for session_id in session_ids:
                marks[session_id] = {"at": time.time(), **fields}
            while len(marks) > MAX_SESSIONS:
                marks.pop(min(marks, key=lambda k: marks[k].get("at", 0)))
            self.store._save(path, data)

    def in_marked_room(self, session_id: str) -> bool:
        """A Bot group chat (a hosted room) the app marked: its members' replies carry inline blocks,
        because the app reads room messages as copied text and never sees the members' tool rows."""
        room = room_of(session_id)
        return bool(room) and room in self._marks("rooms")

    # ---- scheduled tasks

    def job(self, job_id: str | None) -> dict | None:
        if not job_id:
            return None
        try:
            from cron.jobs import get_job
            return get_job(job_id)
        except Exception:
            return None

    def delivers_to_app(self, job_id: str | None) -> bool:
        """A task's output goes to the Hermes app when every target is the app: ``apppush`` (the push
        plugin's platform), a Bot Chat (``bot-chat``), or an origin chat the app marked."""
        job = self.job(job_id)
        if not job:
            return False
        targets = [t.strip() for t in str(job.get("deliver") or "local").split(",") if t.strip()]
        return bool(targets) and all(self._app_target(t, job) for t in targets)

    def _app_target(self, target: str, job: dict) -> bool:
        name = target.split(":", 1)[0].lower()
        if name in ("apppush", "bot-chat", "bot_chat"):
            return True
        if name == "origin":
            origin = job.get("origin") or {}
            platform = str(origin.get("platform") or "").lower()
            marked = self._marked_sessions()
            ids = [str(origin.get(k) or "") for k in ("session_id", "chat_id", "session_key")]
            return platform in self.app_platforms() or any(i and i in marked for i in ids)
        return name in self.app_platforms()

    # ---- the tool

    def handle(self, args: Any, session_id: str = "", **_: Any) -> str:
        """The ``widget`` tool. Always answers JSON; errors are ``{"error": …}`` the model can act on."""
        try:
            if not isinstance(args, dict):
                raise WidgetError("arguments must be an object with op")
            op = args.get("op")
            if op not in OPS:
                raise WidgetError(f"op {json.dumps(op)} isn't one of {', '.join(OPS)}")
            s = self.session(session_id)
            if s.subagent:
                raise WidgetError("widgets are for replies a person reads; a helper reports to Hermes in text")
            result = getattr(self, f"op_{op}")(args, s)
        except WidgetError as exc:
            result = {"error": _cap("; ".join(exc.issues)), "stored": False}
        except ImportError as exc:
            result = {"error": f"the widget tool needs {exc.name or 'jsonschema'} (pip install jsonschema referencing)"}
        except Exception as exc:  # never raise into the agent loop
            logger.warning("widgets: %s failed", args.get("op") if isinstance(args, dict) else "?", exc_info=True)
            result = {"error": f"{type(exc).__name__}: {exc}"}
        return _dump(result)

    # -- create / update

    def _workspace(self) -> str:
        """The session's workspace: its declared cwd, else the terminal's, else the agent's."""
        try:
            from agent import runtime_cwd
            for value in (runtime_cwd.scoped_session_cwd(), runtime_cwd.scope_terminal_cwd()):
                if value and Path(value).expanduser().is_dir():
                    return value
            return str(runtime_cwd.resolve_agent_cwd())
        except Exception:
            return os.environ.get("TERMINAL_CWD") or os.getcwd()

    def _fill_from_file(self, payload: dict, notes: list[str]) -> dict:
        source = payload.pop("from_file", None)
        if source is None:
            return payload
        if not isinstance(source, dict):
            raise WidgetError("from_file must be an object with path and parser")
        try:
            path = parsers.resolve_path(source.get("path"), self._workspace())
            fields, more = parsers.parse(path, source, payload.get("type"), payload)
        except parsers.ParseError as exc:
            raise WidgetError(f"from_file: {exc}") from None
        conflicts = _merge(payload, fields)
        if conflicts:
            raise WidgetError([f"{c} is filled from {source.get('path')}; leave it out of the payload" for c in conflicts])
        if "source" in payload and payload["source"].get("kind") != "file":
            raise WidgetError(f"source is set from {source.get('path')}; leave it out of the payload")
        payload["source"] = {"name": str(source.get("path"))[:80], "kind": "file",
                             **({"url": f"hermes-file:{source['path']}"} if _relative_file(source.get("path")) else {})}
        if not payload.get("as_of"):
            payload["as_of"] = rfc3339(datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).astimezone())
        notes.extend(f"from_file: {n}" for n in more)
        return payload

    def _prepare(self, raw: Any, s: Session, existing: dict | None = None) -> tuple[dict, list[str], dict]:
        """Agent input → the stored payload (without id and rev). Returns (payload, warnings, refs)."""
        if not isinstance(raw, dict):
            raise WidgetError("payload must be an object")
        payload = copy.deepcopy(raw)
        wtype = payload.get("type")
        if wtype not in self.spec.catalog:
            from .validate import _did_you_mean
            raise WidgetError(f"type {json.dumps(wtype)} isn't a widget type" + _did_you_mean(wtype, self.spec.catalog)
                              + f"; the types are {', '.join(self.spec.catalog)}")
        if existing is not None and existing.get("type") != wtype:
            raise WidgetError(f"an update keeps the type: this widget is a {existing.get('type')}")
        for key in ("id", "rev", "producer"):
            if key in payload:
                raise WidgetError(f"{key} is set by the tool; leave it out")
        children = payload.get("children") if wtype == "stack" else None
        notes: list[str] = []
        payload = self._fill_from_file(payload, notes)
        for child in children or []:
            if isinstance(child, dict):
                self._fill_from_file(child, notes)
        issues = schema_issues(self.spec, wtype, payload, "input")
        for n, child in enumerate(children or []):
            if isinstance(child, dict) and child.get("type") in self.spec.catalog and child.get("type") != "stack":
                issues += [f"children[{n}] ({child['type']}): {i}" for i in schema_issues(self.spec, child["type"], child, "input")]
        if issues:
            raise WidgetError(issues[:12])
        for key, value in (self.spec.catalog[wtype].get("defaults") or {}).items():
            payload.setdefault(key, value)
        refs: dict[str, str] = {}
        if wtype == "stack":
            known = dict((existing or {}).get("children") or {})
            for child in payload.get("children") or []:
                ref = child.pop("ref", None)
                for key, value in (self.spec.catalog.get(child.get("type"), {}).get("defaults") or {}).items():
                    child.setdefault(key, value)
                child_id = known.get(ref) if ref else None
                child["id"] = child_id or self.store.unused_id()
                if ref:
                    refs[ref] = child["id"]
                child.setdefault("as_of", payload.get("as_of"))
                child["producer"] = dict(s.producer)
            for section in payload.get("sections") or []:
                section["children"] = [refs.get(name, name) for name in section.get("children") or []]
            if any(c.get("sensitivity") == "private" for c in payload.get("children") or []):
                payload["sensitivity"] = "private"
        payload["producer"] = dict(s.producer)
        # Who may answer is matched by platform user id at the claim: a name is whatever the sender
        # calls themself. The person whose message started this turn is the one id known here.
        for target in [payload] + [c for c in payload.get("children") or [] if isinstance(c, dict)]:
            who = target.get("for")
            if not isinstance(who, dict) or who.get("user"):
                continue
            if s.user_id and s.user_name and str(who.get("name") or "").strip().lower() == s.user_name.strip().lower():
                who["user"] = s.user_id
            elif s.group:
                notes.append(f"for: {who.get('name')} isn't the person whose message started this turn, so no one "
                             "can answer it from the chat; ask them to write to you first")
        supersedes = payload.get("supersedes")
        if isinstance(supersedes, str) and supersedes.startswith("task:"):
            previous = [i for i in self.store.task_widgets(supersedes[5:]) if not existing or i != existing.get("id")]
            if previous:
                payload["supersedes"] = previous[-1]
            else:
                payload.pop("supersedes")
                notes.append(f"supersedes: no earlier widget from task {supersedes[5:]}; left out")
        return payload, notes, refs

    def _finish(self, payload: dict, s: Session, agent_fallback: bool) -> tuple[dict, list[str]]:
        """Fallback text, full validation, the semantic rules and the size cap."""
        if payload["type"] == "stack":
            for child in payload.get("children") or []:
                self._fallback(child)
        generated = self._fallback(payload)
        context = {"producer": s.producer, "group": s.group, "agent_fallback": agent_fallback and not generated}
        issues = schema_issues(self.spec, payload["type"], payload, "full")
        if issues:
            raise WidgetError(issues[:12])
        errors, warnings = self.checks.run(payload, context)
        for child in payload.get("children") or []:
            child_errors, child_warnings = self.checks.run(child, {**context, "agent_fallback": False})
            errors += [f"children ({child.get('type')} {child.get('id')}): {e}" for e in child_errors]
            warnings += [f"children ({child.get('type')}): {w}" for w in child_warnings]
        if errors:
            raise WidgetError(errors[:12])
        size = len(_dump(payload).encode())
        if size > MAX_PAYLOAD:
            raise WidgetError(f"the payload is {size // 1024} KB; at most 64 KB (send fewer rows, or split it)")
        return payload, warnings

    def _fallback(self, payload: dict) -> bool:
        """Fill a missing fallback_text; a signed approval's never invites a text answer. True when generated."""
        generated = not payload.get("fallback_text")
        if generated:
            payload["fallback_text"] = fallback.generate(payload)
        if fallback.requires_signature(payload) and not payload.get("resolution"):
            payload["fallback_text"] = fallback.signed_fallback(payload["fallback_text"])
        return generated

    def _media(self, payload: dict, warnings: list[str]) -> dict:
        if not self.setting("store_media", False):
            return {}
        from . import media
        stored = {}
        for url in media.media_urls(payload):
            try:
                stored[url] = media.store(media.fetch(url), self.store.dir / "media")
            except Exception as exc:
                warnings.append(f"media {url[:80]}: not stored ({exc})")
        return stored

    def _result(self, record: dict, payload: dict, warnings: list[str], refs: dict | None = None) -> dict:
        directive = f'::widget{{id="{payload["id"]}" alt="{_alt(payload)}"}}'
        result = {"id": payload["id"], "rev": payload["rev"], "directive": directive,
                  "fallback_text": payload["fallback_text"], "children": refs or {}, "payload": payload}
        if warnings:
            result["warnings"] = warnings[:12]
        return result

    def op_create(self, args: dict, s: Session) -> dict:
        payload, notes, refs = self._prepare(args.get("payload"), s)
        agent_fallback = bool((args.get("payload") or {}).get("fallback_text"))
        payload["rev"] = 1
        payload["id"] = self.store.unused_id()
        payload, warnings = self._finish(_order(payload), s, agent_fallback)
        warnings = notes + warnings
        stored_media = self._media(payload, warnings)
        with self.store.locked():
            if self.store.exists(payload["id"]):
                raise WidgetError("the widget id was taken; try again")
            record = self._record(payload, s, warnings, refs)
            record["media"] = stored_media
            self.store.put(record)
            for child in payload.get("children") or []:
                self.store.put({**self._record({**child, "rev": 1}, s, [], {}), "parent": payload["id"]})
        return self._result(record, payload, warnings, refs)

    def _record(self, payload: dict, s: Session, warnings: list[str], refs: dict) -> dict:
        return {"id": payload["id"], "type": payload["type"], "created_at": time.time(),
                "producer": payload.get("producer"), "session_id": s.id, "platform": s.platform,
                "chat_keys": s.chat_keys, "group": s.group, "task": s.cron_job, "app": s.app,
                "generated_fallback": False, "revisions": [payload], "warnings": warnings,
                "children": refs, "claims": {}, "answered": {}}

    def _owned(self, widget_id: Any, s: Session) -> dict:
        record = self.store.get(str(widget_id or ""))
        if record is None:
            raise WidgetError(f"no widget {json.dumps(widget_id)} on this gateway")
        producer = (record.get("producer") or {}).get("bot")
        if producer and producer != s.producer.get("bot"):
            raise WidgetError(f"only {record['producer'].get('name') or producer} can change {widget_id}: it made it")
        return record

    def op_update(self, args: dict, s: Session) -> dict:
        record = self._owned(args.get("id"), s)
        payload, notes, refs = self._prepare(args.get("payload"), s, existing=record)
        agent_fallback = bool((args.get("payload") or {}).get("fallback_text"))
        payload["id"] = record["id"]

        def change(rec: dict) -> tuple[dict, list[str]]:
            current = rec["revisions"][-1]
            payload["rev"] = current["rev"] + 1
            built, warnings = self._finish(_order(payload), s, agent_fallback)
            rec["revisions"].append(built)
            rec["children"] = {**(rec.get("children") or {}), **refs}
            rec["warnings"] = notes + warnings
            return built, notes + warnings

        built, warnings = self.store.change(record["id"], change)
        for child in built.get("children") or []:
            self._put_child(child, built["id"], s)
        if record.get("parent"):
            self._replace_in_parent(record["parent"], built)
        return self._result(record, built, warnings, refs)

    def _put_child(self, child: dict, parent: str, s: Session) -> None:
        existing = self.store.get(child["id"])
        if existing is None:
            with self.store.locked():
                self.store.put({**self._record({**child, "rev": 1}, s, [], {}), "parent": parent})
            return

        def change(rec: dict) -> None:
            rev = rec["revisions"][-1]["rev"] + 1
            rec["revisions"].append({**child, "rev": rev})
        self.store.change(child["id"], change)

    def _replace_in_parent(self, parent_id: str, child: dict) -> None:
        """A child updated on its own: the stack takes the new child in place (and a new revision)."""
        def change(rec: dict) -> None:
            stack = copy.deepcopy(rec["revisions"][-1])
            stack["children"] = [{k: v for k, v in child.items() if k != "rev"} if c.get("id") == child["id"] else c
                                 for c in stack.get("children") or []]
            stack["rev"] += 1
            rec["revisions"].append(stack)
        try:
            self.store.change(parent_id, change)
        except KeyError:
            pass

    # -- resolve

    def op_resolve(self, args: dict, s: Session) -> dict:
        record = self._owned(args.get("id"), s)
        state = args.get("state")
        if state not in RESOLUTIONS:
            from .validate import _did_you_mean
            raise WidgetError(f"state {json.dumps(state)} isn't allowed; use {', '.join(RESOLUTIONS)}"
                              + _did_you_mean(state, RESOLUTIONS))
        message = args.get("message")
        if message is not None and (not isinstance(message, str) or len(message) > 120):
            raise WidgetError("message is one line of at most 120 characters")

        def change(rec: dict) -> tuple[dict, list[str]]:
            latest = copy.deepcopy(rec["revisions"][-1])
            answer = (rec.get("answered") or {}).get(str(latest["rev"])) or {}
            resolution = {"state": state, "at": rfc3339(self.clock())}
            action = args.get("action") or answer.get("action")
            if action:
                resolution["action"] = action
            by = args.get("by") or answer.get("by")
            if by:
                resolution["by"] = str(by)[:40]
            if message:
                resolution["message"] = message
            if args.get("undo") is not None:
                resolution["undo"] = args["undo"]
            latest["resolution"] = resolution
            if args.get("answer") is not None:
                latest["answer"] = args["answer"]
            if args.get("submitted") is not None:
                latest["submitted"] = args["submitted"]
            if args.get("undone") is not None:
                latest["undone"] = args["undone"]
                latest.pop("undo", None)
            latest["state"] = {"done": "ok", "failed": "critical"}.get(state, "info")
            latest.pop("state_label", None)
            latest["rev"] += 1
            latest["fallback_text"] = _resolved_fallback(latest, rec["revisions"][-1].get("fallback_text") or "")
            built, warnings = self._finish(latest, s, agent_fallback=False)
            rec["revisions"].append(built)
            return built, warnings

        built, warnings = self.store.change(record["id"], change)
        if record.get("parent"):
            self._replace_in_parent(record["parent"], built)
        return self._result(record, built, warnings)

    # -- claim

    def op_claim(self, args: dict, s: Session) -> dict:
        widget_id = str(args.get("id") or "")
        mid = args.get("mid")
        action = args.get("action")
        if not isinstance(mid, str) or not 1 <= len(mid) <= 100:
            raise WidgetError("mid is required: copy it from the answer's JSON line")
        if not isinstance(action, str) or not action:
            raise WidgetError("action is required: the word after the ] on the answer's first line")
        try:
            rev = int(args.get("rev"))
        except (TypeError, ValueError):
            raise WidgetError("rev is required: the number after rev on the answer's first line") from None
        values = args.get("values") if args.get("values") is not None else {}
        if not isinstance(values, dict):
            raise WidgetError("values must be the object from the answer's JSON line")
        if self.store.get(widget_id) is None:
            raise WidgetError(f"no widget {json.dumps(widget_id)} on this gateway")
        return self.store.change(widget_id, lambda rec: self._claim(rec, rev, action, mid, values, args, s))

    def _claim(self, rec: dict, rev: int, action: str, mid: str, values: dict, args: dict, s: Session) -> dict:
        now = self.clock()
        base = {"id": rec["id"], "rev": rev, "action": action, "mid": mid}
        first = (rec.get("claims") or {}).get(mid)
        if first is not None:
            latest = rec["revisions"][-1]
            replay = {**first, "replay": True}
            if latest.get("resolution"):
                replay["resolution"] = latest["resolution"].get("state")
            replay["message"] = ("This answer was claimed before" + (f" ({first['result']})" if first["result"] != "ok" else "")
                                 + ". Check whether you already acted on it before doing anything"
                                 + ("; the widget is resolved, so don't act again." if latest.get("resolution") else "."))
            return replay
        revisions = {r["rev"]: r for r in rec["revisions"]}
        latest = rec["revisions"][-1]
        target = revisions.get(rev)

        def record(result: dict) -> dict:
            rec.setdefault("claims", {})[mid] = {k: v for k, v in result.items() if k != "message"}
            return result

        answered = (rec.get("answered") or {}).get(str(rev))
        follow_up = target is not None and self._follow_up(target, action, now)
        if answered and not follow_up:
            return record({**base, "result": "already_answered", "action": answered["action"], "mid": answered["mid"],
                           "by": answered.get("by"), "at": answered.get("at"),
                           "message": f"Already answered ({answered['action']}) by {answered.get('by') or 'someone'} "
                                      f"at {answered.get('at')}. Don't act on this one."})
        if target is None or rev < latest["rev"]:
            resolution = latest.get("resolution") or {}
            if target is not None and resolution and resolution.get("state") != "expired":
                return record({**base, "result": "already_answered", "by": resolution.get("by"), "at": resolution.get("at"),
                               "action": resolution.get("action") or action,
                               "message": "This request was already answered and resolved. Don't act on it."})
            return record({**base, "result": "stale_rev", "current_rev": latest["rev"],
                           "message": f"The person answered revision {rev}; the widget is at revision {latest['rev']}. "
                                      "For an approval, show the current terms and ask again; otherwise re-check "
                                      "and say what changed."})
        if target.get("resolution") and not follow_up:
            resolution = target["resolution"]
            return record({**base, "result": "already_answered", "by": resolution.get("by"), "at": resolution.get("at"),
                           "action": resolution.get("action") or action,
                           "message": "This request is already resolved. Don't act on it."})
        expires = _parse_time(target.get("expires_at"))
        undo_until = _parse_time(((target.get("resolution") or {}).get("undo") or {}).get("until"))
        if action == ((target.get("resolution") or {}).get("undo") or {}).get("action"):
            expires = undo_until
        elif action == "undo" and target.get("type") == "receipt":
            expires = _parse_time((target.get("undo") or {}).get("until")) or expires
        if expires is not None and now >= expires:
            return record({**base, "result": "expired", "expires_at": rfc3339(expires), "now": rfc3339(now),
                           "message": f"The answer came after the request expired ({rfc3339(expires)}). Don't act; "
                                      "tell the person and ask again if it still matters."})
        allowed = self.actions_of(target, now)
        if action not in allowed:
            raise WidgetError(f"{rec['id']} has no action {json.dumps(action)}; its actions are {', '.join(sorted(allowed)) or 'none'}")
        signature_state = None
        by = None
        if self.needs_signature(target, action):
            outcome = self._check_signature(rec["id"], rev, action, values, mid, args.get("sig"), s)
            if outcome["result"] != "ok":
                return {**base, **outcome}
            signature_state = outcome.get("signature")
            by = outcome.get("by")
        who = target.get("for")
        if s.group and isinstance(who, dict) and (s.user_id or s.user_name):
            if not _same_person(who, s.user_id, s.user_name):
                return record({**base, "result": "not_for_you", "for": who,
                               "message": f"This widget is for {who.get('name')}; someone else answered. Don't act."})
        by = by or (str(args.get("device"))[:40] if args.get("device") else None) or s.user_name or _platform_word(s.platform)
        at = rfc3339(now)
        rec.setdefault("answered", {})[str(rev)] = {"mid": mid, "action": action, "by": by, "at": at,
                                                    "values": signing.canonical(values)[:2000]}
        result = {**base, "result": "ok", "at": at, "by": by,
                  "message": "Claimed: act on it now, then resolve the widget with what happened."}
        if signature_state:
            result["signature"] = signature_state
        return record(result)

    def _follow_up(self, target: dict, action: str, now: datetime) -> bool:
        """Answers a resolved request still takes: Retry after a failure, the resolution's Undo."""
        resolution = target.get("resolution") or {}
        if action == "retry" and resolution.get("state") == "failed":
            return True
        undo = resolution.get("undo") or {}
        return bool(undo) and action == undo.get("action")

    def actions_of(self, payload: dict, now: datetime) -> set[str]:
        allowed = set(BUILT_IN.get(payload.get("type"), set()))
        if (payload.get("refresh") or {}).get("mode") == "agent":
            allowed.add("refresh")
        for path, action in _all_actions(payload):
            if (action.get("kind") or "reply") == "reply" and action.get("id"):
                allowed.add(action["id"])
        resolution = payload.get("resolution") or {}
        if resolution.get("state") == "failed":
            allowed.add("retry")
        if (resolution.get("undo") or {}).get("action"):
            allowed.add(resolution["undo"]["action"])
        if payload.get("type") == "receipt" and (not payload.get("undo") or payload.get("undone")):
            allowed.discard("undo")
        return allowed

    def needs_signature(self, payload: dict, action: str) -> bool:
        if action == "approve" and fallback.requires_signature(payload):
            return True
        return any(a.get("id") == action and a.get("requires") == "authentication" for _, a in _all_actions(payload))

    def _check_signature(self, widget_id: str, rev: int, action: str, values: dict, mid: str, sig: Any,
                         s: Session) -> dict:
        if not s.app:
            return {"result": "unsigned", "reason": "text_answer",
                    "message": "This approval can only be answered in the Hermes app, with Face ID. A text answer "
                               "never approves it: don't act, and tell the person to open the app."}
        keys = self.store.keys()
        if not keys:
            # No device has registered a key yet: the app's Face ID check is the only gate (§6.3).
            return {"result": "ok", "signature": "unavailable"}
        if not sig:
            return {"result": "unsigned", "reason": "missing",
                    "message": "This approval needs the app's signature and the answer has none. Don't act; ask the "
                               "person to approve it in the Hermes app."}
        message = signing.signing_input(widget_id, rev, action, values, mid)
        for device_id, entry in keys.items():
            if signing.verify(entry.get("public_key", ""), str(sig), message):
                return {"result": "ok", "signature": "verified", "by": entry.get("name") or device_id}
        return {"result": "unsigned", "reason": "invalid",
                "message": "The signature doesn't match this answer. Don't act."}

    # -- get

    def op_get(self, args: dict, s: Session) -> dict:
        record = self.store.get(str(args.get("id") or ""))
        if record is None:
            raise WidgetError(f"no widget {json.dumps(args.get('id'))} on this gateway")
        latest = record["revisions"][-1]
        result = {"id": record["id"], "rev": latest["rev"], "payload": latest}
        answered = (record.get("answered") or {}).get(str(latest["rev"]))
        if answered:
            result["answered"] = {k: answered[k] for k in ("action", "by", "at", "mid") if k in answered}
        return result

    # ---- widget_examples

    def examples(self, args: Any, **_: Any) -> str:
        wtype = (args or {}).get("type") if isinstance(args, dict) else None
        entry = self.spec.catalog.get(wtype)
        if entry is None:
            from .validate import _did_you_mean
            return _dump({"error": f"type {json.dumps(wtype)} isn't a widget type" + _did_you_mean(wtype, self.spec.catalog),
                          "types": {k: v.get("cue") for k, v in self.spec.catalog.items()}})
        examples = []
        budget = 14000
        for relative in entry.get("examples") or []:
            try:
                example = _as_input(json.loads((self.spec.root / relative).read_text()))
            except (FileNotFoundError, ValueError):
                continue
            text = _dump(example)
            if examples and len(text) > budget:
                break
            budget -= len(text)
            examples.append(example)
        return _dump({"type": wtype, "summary": entry.get("summary"), "use": entry.get("use"),
                      "avoid": entry.get("avoid"), "limits": entry.get("limits"), "fallback": entry.get("fallback"),
                      "examples": examples,
                      "note": "Examples are tool input: no id, rev or producer; fallback_text is optional."})

    # ---- prompt section

    def prompt_section(self, info: Any) -> str:
        try:
            platform = str((info or {}).get("platform") or "").lower()
            session_id = str((info or {}).get("session_id") or "")
            if platform == "subagent" or session_id in self._subagents:
                return ""
            s = self.session(session_id, platform)
            if not s.app:
                return ""
            from .prompt import render
            return render(self.spec.catalog)
        except Exception:
            logger.debug("widgets: prompt section failed", exc_info=True)
            return ""

    # ---- hooks

    def pre_llm_call(self, session_id: str = "", platform: str = "", is_first_turn: bool = False,
                     **_: Any) -> dict | None:
        """Once per app chat, the widget rules as turn context. Hermes builds a chat's system prompt
        at its first turn and keeps it, so a chat that started before it had widgets (a long-lived
        Bot Chat, or one the app marked after its first message) never sees the prompt section."""
        if not session_id:
            return None
        s = self.session(session_id, str(platform or "").lower())
        if not s.app or s.platform == "cron":
            return None
        seen = self._marks("reminded").get(session_id) or {}
        if seen.get("version", 0) >= REMINDER_VERSION:
            return None
        self.mark_session(session_id, "reminded", version=REMINDER_VERSION)
        if is_first_turn:
            return None  # the prompt section was built with this turn
        from .prompt import REMINDER
        return {"context": REMINDER}

    def transform_llm_output(self, response_text: str = "", session_id: str = "", platform: str = "",
                             **_: Any) -> str | None:
        """Runs before the reply is stored and sent. Neutralise ```widget fences, then by platform: the
        app keeps directives; a scheduled task delivering to the app gets inline blocks; everyone else
        gets each widget's fallback_text."""
        if not response_text:
            return None
        text = rewrite.neutralise_fences(response_text)
        s = self.session(session_id, str(platform or "").lower())
        if s.platform in ("cron", "bot_room") and s.app:
            text = rewrite.replace_directives(text, self._inline)
        elif not s.app:
            text = rewrite.replace_directives(text, self._as_text)
        return text if text != response_text else None

    # A directive's alt and a widget's fallback_text are the agent's words put in after the fences
    # were neutralised, so they're neutralised too: otherwise alt="```widget" puts back the opener
    # the first pass took out, and the app draws what follows as a plugin-written widget.
    def _inline(self, directive: rewrite.Directive) -> str:
        payload = self.store.latest(directive.id)
        if payload is None:
            return rewrite.neutralise_fences(directive.alt)
        return rewrite.inline_block(payload)

    def _as_text(self, directive: rewrite.Directive) -> str:
        payload = self.store.latest(directive.id)
        if payload is None:
            return rewrite.neutralise_fences(directive.alt)
        return rewrite.neutralise_fences(payload.get("fallback_text") or directive.alt)

    def subagent_start(self, child_session_id: Any = None, **_: Any) -> None:
        if child_session_id:
            self._subagents.add(str(child_session_id))

    def pre_gateway_dispatch(self, event: Any = None, **_: Any) -> dict | None:
        """On messaging platforms, a plain answer ("check tomatoes") to the one open widget in the chat
        becomes the action message. Never for approvals that must be signed."""
        if not self.setting("text_answers", True) or event is None:
            return None
        text = getattr(event, "text", None)
        source = getattr(event, "source", None)
        if not isinstance(text, str) or source is None or not text.strip() or len(text) > 200 or text.lstrip().startswith(("/", "[widget")):
            return None
        key = chat_key(getattr(source, "platform", ""), getattr(source, "chat_id", ""), getattr(source, "thread_id", ""))
        now = self.clock()
        open_widgets = []
        for widget_id in reversed(self.store.chat_widgets(key)[-30:]):
            record = self.store.get(widget_id)
            if record is None or record.get("parent"):
                continue
            payload = record["revisions"][-1]
            if _open(payload, now, self) and str(payload["rev"]) not in (record.get("answered") or {}):
                open_widgets.append(payload)
        if len(open_widgets) != 1 or fallback.requires_signature(open_widgets[0]):
            return None
        answer = match_answer(open_widgets[0], text)
        if answer is None:
            return None
        action, values, words = answer
        payload = open_widgets[0]
        line = f"[widget {payload['id']} rev {payload['rev']}] {action}" + (f": {words}" if words else "")
        body = _dump({"mid": str(uuid.uuid4()), "values": values, "via": "text"})
        quoted = json.dumps(text.strip(), ensure_ascii=False)
        return {"action": "rewrite", "text": f"{line}\n{body}\n(typed as {quoted})"}

    # ---- the /app-widgets command

    COMMANDS = ("session", "room", "get", "keys.register", "keys.remove", "keys.list", "status")  # as in __init__

    def command(self, name: str, args: dict) -> dict:
        platform = (_session_env("HERMES_SESSION_PLATFORM") or "").lower()
        if name in ("session", "room", "keys.register", "keys.remove") and platform and platform not in ("cli", "api_server"):
            return {"ok": False, "error": f"/app-widgets {name} is for the Hermes app, not {platform}"}
        if name == "session":
            # A Bot Mode chat has a runtime id (session.create's session_id) and the stored one its
            # agent runs under (stored_session_id); the call's bound session gives the stored one.
            many = args.get("session_ids") if isinstance(args.get("session_ids"), list) else []
            ids = [str(v) for v in (args.get("session_id"), args.get("stored_session_id"), *many[:500],
                                    _session_env("HERMES_SESSION_ID"), _session_env("HERMES_SESSION_KEY")) if v]
            ids = [i for i in dict.fromkeys(ids) if re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", i)]
            if not ids:
                return {"ok": False, "error": "session_id is required"}
            self.mark_sessions(ids)
            return {"ok": True, "session_ids": ids}
        if name == "room":
            room_id = str(args.get("room_id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", room_id):
                return {"ok": False, "error": "room_id is required"}
            self.mark_session(room_id, "rooms")
            return {"ok": True, "room_id": room_id}
        if name == "get":
            record = self.store.get(str(args.get("id") or ""))
            if record is None:
                return {"ok": False, "error": "unknown widget"}
            latest = record["revisions"][-1]
            rev = args.get("rev")
            if rev is not None:
                latest = next((r for r in record["revisions"] if r.get("rev") == rev), None)
                if latest is None:
                    return {"ok": False, "error": "unknown revision"}
            return {"ok": True, "id": record["id"], "rev": latest["rev"], "payload": latest}
        if name == "keys.register":
            device_id = str(args.get("device_id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", device_id):
                return {"ok": False, "error": "device_id is required"}
            public_key = str(args.get("public_key") or "")
            try:
                signing.load_public_key(public_key)
            except Exception:
                return {"ok": False, "error": "public_key must be a base64 P-256 key (x963 or DER)"}
            self.store.put_key(device_id, {"public_key": public_key, "name": str(args.get("name") or "")[:40],
                                           "fingerprint": signing.fingerprint(public_key)})
            return {"ok": True, "device_id": device_id, "fingerprint": signing.fingerprint(public_key),
                    "devices": len(self.store.keys())}
        if name == "keys.remove":
            return {"ok": True, "removed": self.store.remove_key(str(args.get("device_id") or ""))}
        if name == "keys.list":
            return {"ok": True, "devices": [{"device_id": k, "name": v.get("name"), "fingerprint": v.get("fingerprint"),
                                             "registered_at": v.get("registered_at")} for k, v in self.store.keys().items()]}
        if name == "status":
            try:
                import jsonschema  # noqa: F401
                validator = True
            except ImportError:
                validator = False
            count = len([p for p in self.store.dir.glob("w_*.json")]) if self.store.dir.exists() else 0
            return {"ok": True, "version": VERSION, "spec": _spec_version(self.spec), "widgets": count,
                    "keys": len(self.store.keys()), "validator": validator,
                    "app_platforms": sorted(self.app_platforms()), "store_media": bool(self.setting("store_media", False)),
                    "text_answers": bool(self.setting("text_answers", True))}
        return {"ok": False, "error": f"unknown command {name!r}"}


# ---- helpers


def _cap(text: str, limit: int = 2000) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _alt(payload: dict) -> str:
    """The directive's alt: the summary, else the plain text's opening sentences (≤ 140). A private
    widget's is only its title: the reply text reaches previews and notifications."""
    text = payload.get("title") if payload.get("sensitivity") == "private" else payload.get("summary") or ""
    if not text:
        for part in fallback.sentences(" ".join(str(payload.get("fallback_text") or "").split())):
            if text and len(text) + len(part) > 140:
                break
            text += part
    text = " ".join((text or payload.get("title") or "").split())
    if len(text) > 140:
        text = text[:139].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"
    return text.replace("\\", "\\\\").replace('"', '\\"')


def room_of(session_id: str) -> str | None:
    """The hosted room a member session's current turn belongs to. The backend keeps the room's
    coordinates on the session while a room turn runs (tui_gateway/methods_prompt.py,
    ``_hosted_room_task``); only the process running that turn has them."""
    server = sys.modules.get("tui_gateway.server")
    sessions = getattr(server, "_sessions", None)
    if not session_id or not isinstance(sessions, dict):
        return None
    for session in list(sessions.values()):
        if not isinstance(session, dict):
            continue
        agent = session.get("agent")
        if session_id not in (session.get("session_key"), getattr(agent, "session_id", None)):
            continue
        task = session.get("_hosted_room_task")
        if isinstance(task, dict) and task.get("room_id"):
            return str(task["room_id"])
    return None


def _state_dbs() -> list[Path | None]:
    """The session stores to look in: this profile's (``None``, Hermes's default), then the root's."""
    paths: list[Path | None] = [None]
    try:
        from hermes_constants import get_default_hermes_root, get_hermes_home
        root = Path(get_default_hermes_root()) / "state.db"
        if root.resolve() != (Path(get_hermes_home()) / "state.db").resolve() and root.exists():
            paths.append(root)
    except Exception:
        pass
    return paths


def _compression_lineage(path: Path | None, session_id: str) -> list[str]:
    """``SessionDB.get_compression_lineage``: the compression chain through this session, oldest
    first. Empty when the session isn't in that store or Hermes has no such call."""
    db = None
    try:
        from hermes_state_registry import acquire, release_or_close
        db = acquire(path)
        lineage = db.get_compression_lineage(session_id)
        return [str(i) for i in lineage] if isinstance(lineage, list) else []
    except Exception:
        logger.debug("widgets: couldn't read the compression lineage", exc_info=True)
        return []
    finally:
        if db is not None:
            try:
                release_or_close(db)
            except Exception:
                pass


def _job_from_session(session_id: str) -> str | None:
    match = re.fullmatch(r"cron_(.+)_\d{8}_\d{6}", session_id or "")
    return match.group(1) if match else None


def _relative_file(path: Any) -> bool:
    return isinstance(path, str) and not path.startswith("/") and ".." not in path and not re.search(r"\s", path)


def _merge(payload: dict, fields: dict, prefix: str = "") -> list[str]:
    """Merge file fields into the payload. Objects merge; a value both set is a conflict. Arrays of
    objects of the same length merge item by item (a meter item's target next to its value)."""
    conflicts: list[str] = []
    for key, value in fields.items():
        here = f"{prefix}.{key}" if prefix else key
        if key not in payload:
            payload[key] = value
        elif isinstance(payload[key], dict) and isinstance(value, dict):
            conflicts += _merge(payload[key], value, here)
        elif isinstance(payload[key], list) and isinstance(value, list) and len(payload[key]) == len(value) \
                and all(isinstance(a, dict) and isinstance(b, dict) for a, b in zip(payload[key], value)):
            for n, (mine, theirs) in enumerate(zip(payload[key], value)):
                conflicts += _merge(mine, theirs, f"{here}[{n}]")
        elif payload[key] != value:
            conflicts.append(here)
    return conflicts


_ORDER = ("type", "v", "id", "rev", "title", "subtitle", "icon", "state", "state_label", "as_of", "stale_after",
          "expires_at", "refresh", "producer")


def _order(payload: dict) -> dict:
    """Envelope fields first, so a stored payload reads like the examples."""
    head = {k: payload[k] for k in _ORDER if k in payload}
    return {**head, **{k: v for k, v in payload.items() if k not in head}}


def _resolved_fallback(payload: dict, previous: str) -> str:
    resolution = payload.get("resolution") or {}
    words = {"done": "Done", "failed": "Failed", "rejected": "Rejected", "cancelled": "Cancelled",
             "expired": "Expired", "elsewhere": "Answered elsewhere"}
    head = fallback.sentence(f"{payload.get('title')}: {resolution.get('message') or words.get(resolution.get('state'), '')}")
    body = fallback.drop_reply_invites(previous.replace(fallback.SIGNED_SENTENCE, ""), re.compile(r".", re.S))
    text = f"{head} {body}".strip()
    cap = 4000 if payload.get("type") == "stack" else 2000
    return text if len(text) <= cap else text[:cap - 1].rsplit(" ", 1)[0] + "…"


def _all_actions(payload: dict):
    from .validate import _actions
    return _actions(payload)


def _same_person(who: dict, user_id: str, user_name: str) -> bool:
    """By platform user id only: a Telegram or Discord name is anyone's to take (security scan F9)."""
    return bool(who.get("user")) and bool(user_id) and str(who["user"]) == str(user_id)


def _platform_word(platform: str) -> str:
    return {"api_server": "the Hermes app", "desktop": "the Hermes app", "tui": "the terminal", "cli": "the terminal",
            "bot_room": "the group chat"}.get(platform, platform.title() if platform else "someone")


def _spec_version(spec: Spec) -> str:
    try:
        return (spec.root / "VERSION").read_text().strip()
    except FileNotFoundError:
        return "unknown"


def _as_input(example: dict) -> dict:
    """An example payload as the agent sends it (what gen.py validates as input)."""
    out = {k: v for k, v in example.items() if k not in ("id", "rev", "producer")}
    if "children" in out:
        refs = {}
        kids = []
        for n, child in enumerate(out["children"]):
            ref = f"c{n + 1}"
            refs[child.get("id")] = ref
            kids.append({**{k: v for k, v in child.items() if k not in ("id", "rev", "producer")}, "ref": ref})
        out["children"] = kids
        if "sections" in out:
            out["sections"] = [{**s, "children": [refs.get(c, c) for c in s.get("children") or []]} for s in out["sections"]]
    return out


def _open(payload: dict, now: datetime, widgets: Widgets) -> bool:
    if payload.get("resolution"):
        return False
    expires = _parse_time(payload.get("expires_at"))
    if expires is not None and now >= expires:
        return False
    actions = widgets.actions_of(payload, now) - {"refresh"}
    return bool(actions)


# ---- plain-word answers (pre_gateway_dispatch)

_YES = {"approve", "approved", "yes", "ok", "okay", "go ahead", "do it", "confirm", "send it", "sure"}
_NO = {"reject", "rejected", "no", "don't", "dont", "cancel", "stop", "nope"}


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[“”\"'.!?,]", "", text)).strip().lower()


def match_answer(payload: dict, text: str) -> tuple[str, dict, str] | None:
    """(action, values, words for line 1) for a plain answer to ``payload``, or None."""
    said = _norm(text)
    wtype = payload.get("type")
    if wtype == "approval":
        if said in _YES:
            return "approve", {}, ""
        if said in _NO:
            return "reject", {}, ""
        if said.startswith("edit "):
            note = text.strip()[5:].strip()
            return "edit", {"text": note}, json.dumps(note[:200], ensure_ascii=False)
        return None
    if wtype == "choice" and payload.get("style") != "suggestions":
        options = payload.get("options") or []
        picks = []
        for token in re.split(r"\s*(?:,|\band\b|&)\s*", said):
            token = token.strip()
            if not token:
                continue
            option = None
            if token.isdigit() and 1 <= int(token) <= len(options):
                option = options[int(token) - 1]
            else:
                option = next((o for o in options if _norm(o.get("label", "")) == token or o.get("id") == token), None) \
                    or next((o for o in options if token and _norm(o.get("label", "")).startswith(token)), None)
            if option is None:
                return None
            picks.append(option)
        if not picks or (len(picks) > 1 and payload.get("select") != "many"):
            return None
        return "answer", {"selected": [o["id"] for o in picks]}, " · ".join(o.get("label", "") for o in picks)
    if wtype == "checklist":
        match = re.match(r"^(un ?check|uncheck|not|check|got|done|bought|ticked?|took)\s+(.+)$", said)
        if not match:
            return None
        undo = match.group(1).replace(" ", "") in ("uncheck", "not")
        names = [n.strip() for n in re.split(r"\s*(?:,|\band\b|&)\s*", match.group(2)) if n.strip()]
        items = payload.get("items") or []
        found = []
        for name in names:
            item = next((i for i in items if _norm(i.get("label", "")) == name), None) or \
                next((i for i in items if name in _norm(i.get("label", ""))), None)
            if item is None:
                return None
            found.append(item)
        values = {"checked": [] if undo else [i["id"] for i in found], "unchecked": [i["id"] for i in found] if undo else []}
        words = ("uncheck: " if undo else "") + ", ".join(i.get("label", "") for i in found)
        return "check", values, words
    if wtype == "alert" and said in ("ack", "acknowledge", "acknowledged", "seen", "got it", "ok"):
        return "acknowledge", {}, ""
    if wtype == "receipt" and said == "undo" and payload.get("undo") and not payload.get("undone"):
        return "undo", {}, ""
    for _, action in _all_actions(payload):
        if (action.get("kind") or "reply") == "reply" and _norm(action.get("label", "")) == said:
            return action["id"], {}, ""
    return None
