"""The widget store: every revision of every widget, per gateway.

``<Hermes root>/widgets/<id>.json`` holds one widget: its revisions (oldest first), where it was made
(session, chat, producer, scheduled task), its warnings and its claims. Every Hermes process that runs
turns (the TUI gateway, the messaging gateway, cron workers, a Bot's own process) shares the root, so
writes take an ``fcntl`` lock and replace files atomically; that lock is what makes "first answer wins"
hold across processes. ``index.json`` maps chats and scheduled tasks to their widgets, and ``keys.json``
holds the app's device signing keys (public keys only).
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
