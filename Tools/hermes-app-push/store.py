"""What the plugin remembers between processes.

Hooks fire in whichever Hermes process runs the turn (the TUI gateway, the messaging gateway, a cron
worker), so everything shared lives in one JSON file under ``<Hermes root>/plugin-data/hermes-app-push``.
Writes take an exclusive ``fcntl`` lock (with a deadline, never an indefinite wait), skip the disk when
nothing changed, and land with an atomic replace, so reads need no lock at all: a reader sees the old
file or the new one, never half of either. The relay's installation secret lives in its own owner-only
file and is never logged or returned to a client.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Iterator

logger = logging.getLogger("hermes_app_push")

MAX_DEVICES = 32
# How long a write waits for another process (or thread) to finish its own before giving up. A write
# holds the lock for a read, a small change and a replace: milliseconds. A holder that never lets go
# must not park the gateway's threads behind it.
LOCK_TIMEOUT = 5.0
RESOLVED_MEMORY = 30
# A presence report expires unless the app refreshes it (the app reports every 30 s while visible).
PRESENCE_TTL = 75
# The chats a device that left the app keeps current (``presence away`` with ``sync``): a change in one
# wakes the app with a background push, at most every SYNC_MIN_INTERVAL (iOS rations them), and the
# list is forgotten after a day.
SYNC_TTL = 86_400
SYNC_MIN_INTERVAL = 60
# Reading (docs/notifications.md §2, Reading). Each read is kept six hours, and every notice lists the
# newest NOTICE_READS of each kind. A device away from the app is told what was read since it was last in
# front (at most CLEARED_MAX of each), at most every READ_MIN_INTERVAL, and only for what it was sent: the
# newest DELIVERED_MAX chats and rooms per device are remembered for that.
READ_TTL = 6 * 3600
READ_MEMORY = 200
NOTICE_READS = 12
READ_MIN_INTERVAL = 30
CLEARED_MAX = 40
DELIVERED_MAX = 100
UNREAD_MAX = 400
MAX_BADGE = 9999  # the relay's ceiling for a badge-only push
KINDS = ("chats", "rooms")


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
            "installation": {}, "sync": {}, "reads": {"chats": {}, "rooms": {}}, "delivered": {}, "cleared": {},
            "badges": {}, "read_pushes": {}}


class StoreBusy(TimeoutError):
    """Another writer held the state lock past ``LOCK_TIMEOUT``; the write was skipped."""


def _canonical(data: dict) -> str:
    return json.dumps(data, indent=1, sort_keys=True)


class Store:
    def __init__(self, directory: Path | None = None, lock_timeout: float = LOCK_TIMEOUT):
        self.dir = Path(directory) if directory else data_dir()
        self.path = self.dir / "state.json"
        self.secret_path = self.dir / "relay-secret"
        self.lock_path = self.dir / ".lock"
        self.lock_timeout = lock_timeout

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        """The exclusive write lock, polled without blocking until ``lock_timeout``; raises ``StoreBusy``."""
        self.dir.mkdir(parents=True, exist_ok=True)
        with open(self.lock_path, "a+") as handle:
            deadline = time.monotonic() + self.lock_timeout
            pause = 0.002
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        logger.warning("app push: the state lock stayed busy for %.0f s; skipping a write",
                                       self.lock_timeout)
                        raise StoreBusy(f"state lock busy for {self.lock_timeout:.0f} s") from None
                    time.sleep(pause)
                    pause = min(pause * 2, 0.05)
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

    def _write(self, text: str) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".state-")
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(text)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise

    def read(self) -> dict:
        """A snapshot of the state, without the lock: every write is an atomic replace."""
        return self._read()

    def update(self, change: Callable[[dict], Any]) -> Any:
        """Run ``change(state)`` under the lock and save when it changed something; returns what
        ``change`` returned."""
        with self._locked():
            data = self._read()
            before = _canonical(data)
            result = change(data)
            after = _canonical(data)
            if after != before:
                self._write(after)
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
                _forget(state, oldest)
        self.update(change)

    def remove_device(self, device_id: str) -> bool:
        return self.update(lambda state: _forget(state, device_id))

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

    def set_sync(self, device_id: str, sessions: list[str]) -> None:
        def change(state: dict) -> None:
            if not sessions:
                state["sync"].pop(device_id, None)
                return
            previous = state["sync"].get(device_id, {})
            state["sync"][device_id] = {"sessions": sessions, "at": time.time(), "sent": previous.get("sent", 0)}
        self.update(change)

    def claim_sync(self, session_key: str) -> tuple[list[str], list[tuple[str, float]]]:
        """The devices that keep ``session_key`` current: those to wake now (marked as woken), and those
        woken less than SYNC_MIN_INTERVAL ago with how long until they may be, the chat held for then."""
        def change(state: dict) -> tuple[list[str], list[tuple[str, float]]]:
            now = time.time()
            wake, later = [], []
            for device_id, entry in list(state["sync"].items()):
                if now - entry.get("at", 0) > SYNC_TTL or device_id not in state["devices"]:
                    state["sync"].pop(device_id, None)
                    continue
                if session_key not in entry.get("sessions", []):
                    continue
                wait = entry.get("sent", 0) + SYNC_MIN_INTERVAL - now
                if wait <= 0:
                    entry.update(sent=now, held=[])
                    wake.append(device_id)
                else:
                    held = entry.setdefault("held", [])
                    if session_key not in held:
                        held.append(session_key)
                    later.append((device_id, wait))
            return wake, later
        return self.update(change)

    def claim_held_sync(self, device_id: str) -> list[str]:
        """The chats held for ``device_id`` once it may be woken again (marked as woken), else none."""
        def change(state: dict) -> list[str]:
            entry = state["sync"].get(device_id)
            now = time.time()
            if not entry or not entry.get("held") or now - entry.get("sent", 0) < SYNC_MIN_INTERVAL:
                return []
            held = entry["held"]
            entry.update(sent=now, held=[])
            return held
        return self.update(change)

    def set_activity(self, device_id: str, record: dict | None) -> None:
        def change(state: dict) -> None:
            if record is None:
                state["activities"].pop(device_id, None)
            else:
                state["activities"][device_id] = {**record, "at": time.time()}
        self.update(change)

    def activities(self) -> dict[str, dict]:
        return self.read()["activities"]

    # -- reading (docs/notifications.md §2, Reading and Badge) --------------------------------------------

    def reset_reading(self, device_id: str) -> None:
        """Back in the app, which knows best what's read while it's in front: forget what this device was
        sent, cleared and counted while it was away."""
        def change(state: dict) -> None:
            for key in ("delivered", "cleared", "badges"):
                state[key].pop(device_id, None)
            (state["read_pushes"].get(device_id) or {}).pop("pending", None)
        self.update(change)

    def set_badge(self, device_id: str, unread: dict | None, muted: dict | None, others: int = 0,
                  listed: dict | None = None) -> None:
        """Leaving the app, a device that counts unread chats in its badge names them (``unread``), the muted
        ones, every chat its list shows (``listed``: only those may count) and what the person's other
        gateways add to its badge (``others``); it showed the open requests plus those. None: it doesn't
        count them."""
        def change(state: dict) -> None:
            if unread is None:
                state["badges"].pop(device_id, None)
                return
            _expire(state)
            record = {"chats": list(unread["chats"]), "rooms": list(unread["rooms"]),
                      "muted_chats": list((muted or {}).get("chats") or []),
                      "muted_rooms": list((muted or {}).get("rooms") or []), "others": max(0, int(others)),
                      "listed_chats": list((listed or {}).get("chats") or []),
                      "listed_rooms": list((listed or {}).get("rooms") or []), "at": time.time()}
            record["shown"] = _badge(state, record)
            state["badges"][device_id] = record
        self.update(change)

    def record_delivered(self, device_ids: list[str], kind: str, key: str) -> list[str]:
        """A notice for ``key`` (a chat or a room, ``kind`` "chats" or "rooms") went to these devices:
        remembered, so a read elsewhere clears it there, and counted unread on those that count unread chats
        (unless it's muted there). Returns the devices whose count moved."""
        def change(state: dict) -> list[str]:
            now = time.time()
            moved = []
            for device_id in device_ids:
                sent = state["delivered"].setdefault(device_id, {}).setdefault(kind, {})
                sent[key] = now
                _keep_newest(sent, DELIVERED_MAX)
                record = state["badges"].get(device_id)
                if record is None or key in record.get(f"muted_{kind}", []) or key in record.get(kind, []):
                    continue
                # Only a chat the app lists counts: a routine's run, a Bot-to-Bot one-shot chat or a helper's
                # session is news the person can't open, and counted for ever (a badge of 120 for 2 unread).
                if key not in record.get(f"listed_{kind}", []):
                    continue
                record[kind] = (record.get(kind, []) + [key])[-UNREAD_MAX:]
                moved.append(device_id)
            return moved
        return self.update(change)

    def record_read(self, reader: str, chats: list[str], rooms: list[str]) -> dict:
        """Chats and rooms read on ``reader``: kept for the notices (``recent_reads``), and on every other
        device away from the app what it was sent for them is cleared and its unread count drops. Returns
        ``{"open", "read": [(device, seconds until a read push may go)], "badge": [devices whose count
        moved]}``."""
        def change(state: dict) -> dict:
            now = time.time()
            reads = _reads(state)
            read = {"chats": chats, "rooms": rooms}
            for kind in KINDS:
                for key in read[kind]:
                    reads[kind][key] = now
                _keep_newest(reads[kind], READ_MEMORY, now - READ_TTL)
            owed, moved = [], []
            for device_id in state["devices"]:
                if device_id == reader or _in_app(state, device_id, now):
                    continue
                sent = state["delivered"].get(device_id) or {}
                matched = False
                for kind in KINDS:
                    hits = [key for key in read[kind] if (sent.get(kind) or {}).get(key, now + 1) <= now]
                    if not hits:
                        continue
                    matched = True
                    cleared = state["cleared"].setdefault(device_id, {}).setdefault(kind, {})
                    for key in hits:
                        sent[kind].pop(key, None)
                        cleared[key] = now  # when it was read: the newest read of it counts
                    _keep_newest(cleared, CLEARED_MAX)
                # Off its count too: the app marks a room read here when it hears another device read it
                # (group chats have no read mark on the gateway, docs/inbox.md §1).
                record = state["badges"].get(device_id)
                if record:
                    before = {kind: list(record.get(kind) or []) for kind in KINDS}
                    for kind in KINDS:
                        record[kind] = [key for key in before[kind] if key not in set(read[kind])]
                    if any(record[kind] != before[kind] for kind in KINDS):
                        moved.append(device_id)
                if matched:
                    entry = state["read_pushes"].setdefault(device_id, {})
                    entry["pending"] = True
                    owed.append((device_id, entry.get("sent", 0) + READ_MIN_INTERVAL - now))
            return {"open": len(state["requests"]), "read": owed, "badge": moved}
        return self.update(change)

    def claim_read_push(self, device_id: str) -> tuple[dict | None, float]:
        """When ``device_id`` is owed a read push and may get one now: what was read since it was last in
        front, with when (``read: {chats: [[id, at], …], rooms}``, newest first), and the open count, marked as
        sent. Else None, with how long until one may go (0 when none is owed: back in the app, or nothing
        to say)."""
        def change(state: dict) -> tuple[dict | None, float]:
            now = time.time()
            entry = state["read_pushes"].get(device_id)
            if not entry or not entry.get("pending"):
                return None, 0.0
            if device_id not in state["devices"] or _in_app(state, device_id, now):
                entry.pop("pending", None)
                return None, 0.0
            wait = entry.get("sent", 0) + READ_MIN_INTERVAL - now
            if wait > 0.5:
                return None, wait  # another process sent one meanwhile
            entry.pop("pending", None)
            cleared = state["cleared"].get(device_id) or {}
            read = {kind: [[key, round(at, 3)] for key, at in _newest_items(cleared.get(kind) or {}, CLEARED_MAX)]
                    for kind in KINDS}
            if not read["chats"] and not read["rooms"]:
                return None, 0.0
            entry["sent"] = now
            return {"read": read, "open": len(state["requests"])}, 0.0
        return self.update(change)

    def claim_badge(self, device_id: str) -> int | None:
        """The count to send ``device_id`` when it's away from the app, counts unread chats and last showed
        (or was sent) a different one, marked as sent; else None."""
        def change(state: dict) -> int | None:
            record = state["badges"].get(device_id)
            if record is None or device_id not in state["devices"] or _in_app(state, device_id, time.time()):
                return None
            _expire(state)
            count = _badge(state, record)
            if count == record.get("shown"):
                return None
            record["shown"] = count
            return count
        return self.update(change)


def recent_reads(state: dict, limit: int = NOTICE_READS) -> dict:
    """What every notice lists of the last six hours' reads: ``{"chats": [[id, at], …], "rooms": […]}``,
    the newest ``limit`` of each, newest first, times in unix seconds; empty when there are none."""
    reads = _reads(state)
    since = time.time() - READ_TTL
    listed = {kind: [[key, round(at, 3)] for key, at in _newest_items(reads[kind], limit) if at >= since]
              for kind in KINDS}
    return listed if listed["chats"] or listed["rooms"] else {}


def _forget(state: dict, device_id: str) -> bool:
    for key in ("presence", "activities", "sync", "delivered", "cleared", "badges", "read_pushes"):
        state[key].pop(device_id, None)
    return state["devices"].pop(device_id, None) is not None


def _reads(state: dict) -> dict:
    """``state["reads"]``, whole whatever an older file held."""
    reads = state["reads"] if isinstance(state.get("reads"), dict) else state.setdefault("reads", {})
    for kind in KINDS:
        if not isinstance(reads.get(kind), dict):
            reads[kind] = {}
    return reads


def _in_app(state: dict, device_id: str, now: float) -> bool:
    """In front (``foreground``) or open behind other apps (``running``, the Mac), by a fresh report."""
    entry = state["presence"].get(device_id) or {}
    return entry.get("state") in ("foreground", "running") and now - entry.get("at", 0) <= PRESENCE_TTL


def _badge(state: dict, record: dict) -> int:
    count = len(state["requests"]) + len(record.get("chats") or []) + len(record.get("rooms") or [])
    return min(count + int(record.get("others") or 0), MAX_BADGE)


def _newest_items(times: dict, limit: int) -> list[tuple[str, float]]:
    items = [(key, at) for key, at in times.items() if isinstance(at, (int, float))]
    return sorted(items, key=lambda item: item[1], reverse=True)[:limit]


def _keep_newest(times: dict, limit: int, since: float | None = None) -> None:
    """Trims ``{key: time}`` to its newest ``limit`` (and to those at ``since`` or later)."""
    keep = {key for key, at in _newest_items(times, limit) if since is None or at >= since}
    for key in [key for key in times if key not in keep]:
        times.pop(key, None)


def _expire(state: dict) -> None:
    """Forget requests past their deadline (a hook that never fired its close must not pin the badge)."""
    now = time.time()
    for rid in [rid for rid, r in state["requests"].items() if r.get("expires_at") and r["expires_at"] < now - 30]:
        state["requests"].pop(rid, None)
