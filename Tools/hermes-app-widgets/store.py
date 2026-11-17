"""The widget store: every revision of every widget, per gateway.

``<Hermes root>/widgets/<id>.json`` holds one widget: its revisions (oldest first), where it was made
(session, chat, producer, scheduled task), its warnings and its claims. Every Hermes process that runs
turns (the TUI gateway, the messaging gateway, cron workers, a Bot's own process) shares the root, so
writes take an ``fcntl`` lock and replace files atomically; that lock is what makes "first answer wins"
hold across processes. ``index.json`` maps chats and scheduled tasks to their widgets, ``keys.json``
holds the app's device signing keys (public keys only), and ``clients.json`` the app's turn markers
(``/app-widgets client``) and the client each chat's model was last told about.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import secrets
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Iterator

ID_ALPHABET = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ID_PATTERN = re.compile(r"^w_[A-Za-z0-9]{6,40}$")
INDEX_PER_CHAT = 200
MAX_KEYS = 32
# Turn markers (docs/widgets.md §11): a few per chat, briefly. The app sends one just before each
# turn, so a marker that waits longer than the TTL belongs to a turn that never ran.
CLIENT_MARKERS = 8
CLIENT_TTL = 600
MAX_CLIENT_SESSIONS = 2000


def _root_home() -> Path:
    """The Hermes root every profile shares (a Bot's process starts with HERMES_HOME =
    ``<root>/profiles/<bot>``; widgets are per gateway, so they all read the root)."""
    with contextlib.suppress(Exception):
        from hermes_constants import get_default_hermes_root
        return Path(get_default_hermes_root())
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home.parent.parent if home.parent.name == "profiles" else home


def data_dir() -> Path:
    return _root_home() / "widgets"


def new_id() -> str:
    return "w_" + "".join(secrets.choice(ID_ALPHABET) for _ in range(10))


class Store:
    def __init__(self, directory: Path | None = None):
        self._dir = Path(directory) if directory else None

    @property
    def dir(self) -> Path:
        return self._dir or data_dir()

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(self.dir / ".lock", "a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _path(self, widget_id: str) -> Path:
        if not ID_PATTERN.match(widget_id or ""):
            raise KeyError(widget_id)
        return self.dir / f"{widget_id}.json"

    def _load(self, path: Path) -> Any:
        try:
            return json.loads(path.read_text())
        except (FileNotFoundError, ValueError):
            return None

    def _save(self, path: Path, data: Any) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".w-")
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    # -- widgets

    def get(self, widget_id: str) -> dict | None:
        try:
            return self._load(self._path(widget_id))
        except KeyError:
            return None

    def latest(self, widget_id: str) -> dict | None:
        record = self.get(widget_id)
        return record["revisions"][-1] if record and record.get("revisions") else None

    def exists(self, widget_id: str) -> bool:
        try:
            return self._path(widget_id).exists()
        except KeyError:
            return False

    def unused_id(self) -> str:
        for _ in range(20):
            candidate = new_id()
            if not self.exists(candidate):
                return candidate
        raise RuntimeError("couldn't find an unused widget id")

    def put(self, record: dict) -> None:
        """Write a whole record (create); the caller holds ``locked()``."""
        self._save(self._path(record["id"]), record)
        self._index(record)

    def change(self, widget_id: str, fn: Callable[[dict], Any]) -> Any:
        """Run ``fn(record)`` under the lock and save it; returns what ``fn`` returned."""
        with self.locked():
            record = self.get(widget_id)
            if record is None:
                raise KeyError(widget_id)
            result = fn(record)
            self._save(self._path(widget_id), record)
            self._index(record)
            return result

    # -- index: chats and scheduled tasks

    def _index(self, record: dict) -> None:
        path = self.dir / "index.json"
        index = self._load(path) or {"chats": {}, "tasks": {}}
        for key in record.get("chat_keys") or []:
            ids = [i for i in index["chats"].get(key, []) if i != record["id"]] + [record["id"]]
            index["chats"][key] = ids[-INDEX_PER_CHAT:]
        task = record.get("task")
        if task and not record.get("parent"):
            entries = index["tasks"].setdefault(task, [])
            if record["id"] not in entries:
                entries.append(record["id"])
            index["tasks"][task] = entries[-INDEX_PER_CHAT:]
        self._save(path, index)

    def chat_widgets(self, chat_key: str) -> list[str]:
        index = self._load(self.dir / "index.json") or {}
        return list((index.get("chats") or {}).get(chat_key, []))

    def task_widgets(self, task_id: str) -> list[str]:
        index = self._load(self.dir / "index.json") or {}
        return list((index.get("tasks") or {}).get(task_id, []))

    def add_chat_key(self, widget_id: str, chat_key: str) -> None:
        """Note that a widget was delivered into another chat (a scheduled report's destination)."""
        def fn(record: dict) -> None:
            keys = record.setdefault("chat_keys", [])
            if chat_key not in keys:
                keys.append(chat_key)
        with contextlib.suppress(KeyError):
            self.change(widget_id, fn)

    # -- device keys (public keys only)

    def keys(self) -> dict[str, dict]:
        return (self._load(self.dir / "keys.json") or {}).get("devices", {})

    def put_key(self, device_id: str, entry: dict) -> None:
        with self.locked():
            data = self._load(self.dir / "keys.json") or {"devices": {}}
            devices = data["devices"]
            devices[device_id] = {**entry, "registered_at": time.time()}
            while len(devices) > MAX_KEYS:
                devices.pop(min(devices, key=lambda k: devices[k].get("registered_at", 0)))
            self._save(self.dir / "keys.json", data)

    def remove_key(self, device_id: str) -> bool:
        with self.locked():
            data = self._load(self.dir / "keys.json") or {"devices": {}}
            removed = data["devices"].pop(device_id, None) is not None
            self._save(self.dir / "keys.json", data)
            return removed

    # -- the app's turn markers and the client each chat was told about

    def _clients(self) -> dict:
        """``clients.json``, with anything malformed left out: a damaged file reads as empty."""
        data = self._load(self.dir / "clients.json")
        data = data if isinstance(data, dict) else {}
        pending = data.get("pending") if isinstance(data.get("pending"), dict) else {}
        told = data.get("told") if isinstance(data.get("told"), dict) else {}
        return {"pending": {k: [m for m in v if _marker(m)] for k, v in pending.items() if isinstance(v, list)},
                "told": {k: v for k, v in told.items() if isinstance(v, dict) and isinstance(v.get("client"), dict)}}

    def add_client_turn(self, session_ids: list[str], client: dict, sha: str, now: float) -> int:
        """File one marker under each of a chat's ids, keeping the newest ``CLIENT_MARKERS`` live ones
        per id. Returns how many wait under the first id."""
        with self.locked():
            data = self._clients()
            pending = {k: live for k, v in data["pending"].items() if (live := [m for m in v if _live(m, now)])}
            marker = {"id": secrets.token_hex(8), "sha": sha, "client": client, "at": now, "keys": list(session_ids)}
            for key in session_ids:
                pending[key] = (pending.get(key, []) + [marker])[-CLIENT_MARKERS:]
            while len(pending) > MAX_CLIENT_SESSIONS:
                pending.pop(min(pending, key=lambda k: pending[k][-1]["at"]))
            data["pending"] = pending
            self._save(self.dir / "clients.json", data)
            return len(pending[session_ids[0]])

    def client_turn_keys(self, sha: str, now: float) -> set[str]:
        """The ids a live marker for this text waits under (read without the lock: a hint only)."""
        return {k for k, v in self._clients()["pending"].items() if any(m["sha"] == sha and _live(m, now) for m in v)}

    def take_client_turn(self, session_id: str, candidates: list[str], sha: str, now: float) -> dict | None:
        """Consume the oldest live marker for this text under any candidate id (the chat's own, then
        the ones it was compacted from). Returns its client when the chat's model hasn't been told
        about that client yet, and records it as told; else None."""
        with self.locked():
            data = self._clients()
            found = [m for key in candidates for m in data["pending"].get(key, []) if m["sha"] == sha and _live(m, now)]
            if not found:
                return None
            match = min(found, key=lambda m: m["at"])
            for key in set(match.get("keys") or []) | set(candidates):
                left = [m for m in data["pending"].get(key, []) if m["id"] != match["id"] and _live(m, now)]
                if left:
                    data["pending"][key] = left
                else:
                    data["pending"].pop(key, None)
            client = match["client"]
            told = data["told"]
            changed = (told.get(session_id) or {}).get("client") != client
            if changed:
                told[session_id] = {"client": client, "at": now}
                while len(told) > MAX_CLIENT_SESSIONS:
                    told.pop(min(told, key=lambda k: told[k].get("at") if isinstance(told[k].get("at"), (int, float)) else 0))
            self._save(self.dir / "clients.json", data)
            return client if changed else None


def _marker(value: Any) -> bool:
    return (isinstance(value, dict) and isinstance(value.get("id"), str) and isinstance(value.get("sha"), str)
            and isinstance(value.get("client"), dict) and isinstance(value.get("at"), (int, float))
            and not isinstance(value.get("at"), bool) and isinstance(value.get("keys", []), list))


def _live(marker: dict, now: float) -> bool:
    # A minute of slack the other way: processes on one machine can read the clock a moment apart.
    return -60 <= now - marker["at"] <= CLIENT_TTL
