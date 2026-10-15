"""What the plugin remembers between processes.

Hooks fire in whichever Hermes process runs the turn (the TUI gateway, the messaging gateway, a cron
worker), so everything shared lives in one JSON file under ``<Hermes root>/plugin-data/hermes-app-push``,
read and written under an ``fcntl`` lock with atomic replaces. The relay's installation secret lives in
its own owner-only file and is never logged or returned to a client.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Iterator

MAX_DEVICES = 32
RESOLVED_MEMORY = 30
# A presence report expires unless the app refreshes it (the app reports every 30 s while visible).
PRESENCE_TTL = 75


def _root_home() -> str:
    """The Hermes root every profile shares. Hooks can fire inside a Bot's profile scope, and a Bot's own
    process (``hermes -p <bot> chat``, a cron worker) even starts with HERMES_HOME set to
    ``<root>/profiles/<bot>``; devices register against the root, so every profile's notices must read
    the same state."""
    with contextlib.suppress(Exception):
        from hermes_constants import get_default_hermes_root
        return str(get_default_hermes_root())
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return str(home.parent.parent if home.parent.name == "profiles" else home)


# Read once at load.
_PROCESS_HOME = _root_home()


def data_dir() -> Path:
    """``<Hermes root>/plugin-data/hermes-app-push`` (created on first use)."""
    return Path(_PROCESS_HOME) / "plugin-data" / "hermes-app-push"


def _empty() -> dict:
    return {"version": 1, "devices": {}, "requests": {}, "resolved": [], "presence": {}, "activities": {},
            "installation": {}}


class Store:
    def __init__(self, directory: Path | None = None):
        self.dir = Path(directory) if directory else data_dir()
        self.path = self.dir / "state.json"
        self.secret_path = self.dir / "relay-secret"
        self.lock_path = self.dir / ".lock"

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        self.dir.mkdir(parents=True, exist_ok=True)
        with open(self.lock_path, "a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _read(self) -> dict:
        try:
            data = json.loads(self.path.read_text())
        except (FileNotFoundError, ValueError):
            return _empty()
        base = _empty()
        base.update(data if isinstance(data, dict) else {})
        return base

    def _write(self, data: dict) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".state-")
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=1, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def read(self) -> dict:
        with self._locked():
            return self._read()

    def update(self, change: Callable[[dict], Any]) -> Any:
        """Run ``change(state)`` under the lock and save; returns what ``change`` returned."""
        with self._locked():
            data = self._read()
            result = change(data)
            self._write(data)
            return result

    # -- relay credentials ---------------------------------------------------------------------

    def relay_secret(self) -> str | None:
        with contextlib.suppress(FileNotFoundError):
            return self.secret_path.read_text().strip() or None
        return None

    def save_relay_credentials(self, installation_id: str, secret: str, relay_url: str) -> None:
        fd = os.open(self.secret_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(secret)
        self.update(lambda s: s.__setitem__("installation", {"id": installation_id, "relay_url": relay_url,
                                                             "registered_at": time.time()}))

    def forget_relay_credentials(self) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.secret_path.unlink()
        self.update(lambda s: s.__setitem__("installation", {}))

    # -- devices ---------------------------------------------------------------------------------

    def devices(self) -> dict[str, dict]:
        return self.read()["devices"]

    def put_device(self, device_id: str, record: dict) -> None:
        def change(state: dict) -> None:
            devices = state["devices"]
            devices[device_id] = {**devices.get(device_id, {}), **record, "updated_at": time.time()}
            if len(devices) > MAX_DEVICES:  # drop the stalest
                oldest = min(devices, key=lambda key: devices[key].get("updated_at", 0))
                devices.pop(oldest, None)
        self.update(change)

    def remove_device(self, device_id: str) -> bool:
        def change(state: dict) -> bool:
            state["presence"].pop(device_id, None)
            state["activities"].pop(device_id, None)
            return state["devices"].pop(device_id, None) is not None
        return self.update(change)

    # -- open requests (the badge and withdrawals) ------------------------------------------------

    def open_request(self, request_id: str, info: dict) -> int:
        def change(state: dict) -> int:
            state["requests"][request_id] = {**info, "opened_at": time.time()}
            _expire(state)
            return len(state["requests"])
        return self.update(change)

    def close_requests(self, request_ids: list[str]) -> tuple[list[str], int]:
        """Mark requests resolved; returns (the ids that were open, the remaining count)."""
        def change(state: dict) -> tuple[list[str], int]:
            closed = [rid for rid in request_ids if state["requests"].pop(rid, None) is not None]
            now = time.time()
            state["resolved"] = ([[rid, now] for rid in closed] + state["resolved"])[:RESOLVED_MEMORY]
            _expire(state)
            return closed, len(state["requests"])
        return self.update(change)

    def open_requests(self, session_key: str | None = None) -> dict[str, dict]:
        requests = self.read()["requests"]
        return {rid: r for rid, r in requests.items() if session_key is None or r.get("session") == session_key}

    def recently_resolved(self) -> list[str]:
        return [rid for rid, _ in self.read()["resolved"]]

    # -- presence and Live Activities --------------------------------------------------------------

    def set_presence(self, device_id: str, state_name: str, session_key: str | None,
                     live: list[str] | None = None) -> None:
        entry = {"state": state_name, "session": session_key, "at": time.time()}
        if live is not None:
            entry["live"] = live
        self.update(lambda s: s["presence"].__setitem__(device_id, entry))

    def presence(self, device_id: str) -> dict | None:
        entry = self.read()["presence"].get(device_id)
        if not entry or time.time() - entry.get("at", 0) > PRESENCE_TTL:
            return None
        return entry

    def set_activity(self, device_id: str, record: dict | None) -> None:
        def change(state: dict) -> None:
            if record is None:
                state["activities"].pop(device_id, None)
            else:
                state["activities"][device_id] = {**record, "at": time.time()}
        self.update(change)

    def activities(self) -> dict[str, dict]:
        return self.read()["activities"]


def _expire(state: dict) -> None:
    """Forget requests past their deadline (a hook that never fired its close must not pin the badge)."""
    now = time.time()
    for rid in [rid for rid, r in state["requests"].items() if r.get("expires_at") and r["expires_at"] < now - 30]:
        state["requests"].pop(rid, None)
