"""Talking to the push relay.

The relay holds the APNs key and forwards to Apple; it never sees content (only the routing fields
APNs needs and the sealed envelope). This gateway authenticates with a per-installation secret the
relay issues on first contact (``POST /v1/installations``), then sends each push with
``POST /v1/push``. Sending happens on one background thread: hooks only enqueue, so a slow or
unreachable relay never delays an approval prompt or a turn.

Push request (JSON)::

    {"token": <APNs device or activity token, hex>, "environment": "development" | "production",
     "topic": <bundle id, + ".push-type.liveactivity" for Live Activities>,
     "push_type": "alert" | "background" | "liveactivity", "priority": 10 | 5,
     "collapse_id": <≤ 64 bytes, optional>, "expiration": <unix seconds, optional>,
     "payload": {"aps": {...}, "hermes": <envelope>}}

Response: ``{"status": <APNs HTTP status>, "reason": <APNs reason, optional>, "apns_id": ...}``.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass, field
from typing import Callable

logger = logging.getLogger("hermes_app_push")

DEFAULT_RELAY = "https://push.hermesapp.dev"
CLIENT = "hermes-app-push/1.0"
# APNs reasons that mean the token will never work again: forget the device.
DEAD_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"}


@dataclass
class Delivery:
    device_id: str
    request: dict
    attempts: int = 0
    on_done: Callable[[dict], None] | None = field(default=None, repr=False)


class RelayError(Exception):
    pass


class Relay:
    def __init__(self, store, url_provider: Callable[[], str], gateway_name: Callable[[], str]):
        self.store = store
        self._url = url_provider
        self._name = gateway_name
        self._queue: "queue.Queue[Delivery]" = queue.Queue(maxsize=500)
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self.last_error: str | None = None
        self.last_ok_at: float | None = None

    # -- installation -------------------------------------------------------------------------------

    @property
    def url(self) -> str:
        return (self._url() or DEFAULT_RELAY).rstrip("/")

    def installation_id(self) -> str | None:
        return self.store.read().get("installation", {}).get("id")

    def ensure_installation(self, client=None) -> str:
        """The relay's id for this gateway, registering once (the secret is stored owner-only)."""
        state = self.store.read().get("installation", {})
        if state.get("id") and self.store.relay_secret() and state.get("relay_url") == self.url:
            return state["id"]
        import httpx
        owns = client is None
        client = client or httpx.Client(timeout=10.0)
        try:
            response = client.post(f"{self.url}/v1/installations", json={"client": CLIENT, "name": self._name()[:64]})
        finally:
            if owns:
                client.close()
        if response.status_code >= 300:
            raise RelayError(f"relay refused registration: HTTP {response.status_code}")
        body = response.json()
        installation_id, secret = str(body.get("installation_id") or ""), str(body.get("secret") or "")
        if not installation_id or not secret:
            raise RelayError("relay registration answer is missing the installation id or secret")
        self.store.save_relay_credentials(installation_id, secret, self.url)
        return installation_id

    # -- sending ------------------------------------------------------------------------------------

    def post(self, request: dict, client=None) -> dict:
        """Send one push now (blocking). Re-registers once if the relay no longer knows us."""
        import httpx
        owns = client is None
        client = client or httpx.Client(timeout=10.0)
        try:
            for attempt in range(2):
                installation = self.ensure_installation(client)
                secret = self.store.relay_secret() or ""
                response = client.post(f"{self.url}/v1/push", json=request,
                                       headers={"Authorization": f"Bearer {secret}",
                                                "X-Hermes-Installation": installation, "User-Agent": CLIENT})
                if response.status_code == 401 and attempt == 0:
                    self.store.forget_relay_credentials()
                    continue
                if response.status_code == 429:
                    raise RelayError("relay rate limit")
                if response.status_code >= 500:
                    raise RelayError(f"relay HTTP {response.status_code}")
                try:
                    body = response.json()
                except ValueError:
                    body = {}
                body.setdefault("status", response.status_code)
                return body
            raise RelayError("relay refused this installation")
        finally:
            if owns:
                client.close()

    def enqueue(self, delivery: Delivery) -> None:
        try:
            self._queue.put_nowait(delivery)
        except queue.Full:
            logger.warning("app push: queue full, dropping a notification")
            return
        self._start()

    def _start(self) -> None:
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="hermes-app-push", daemon=True)
                self._thread.start()

    def _run(self) -> None:
        import httpx
        with httpx.Client(timeout=10.0) as client:
            while True:
                try:
                    delivery = self._queue.get(timeout=60)
                except queue.Empty:
                    return  # idle: the next enqueue starts a fresh worker
                try:
                    self._deliver(delivery, client)
                finally:
                    self._queue.task_done()

    def _deliver(self, delivery: Delivery, client) -> None:
        while True:
            try:
                result = self.post(delivery.request, client)
                break
            except Exception as exc:  # network, relay down, rate limit
                delivery.attempts += 1
                self.last_error = str(exc)
                if delivery.attempts >= 3:
                    logger.warning("app push: gave up on a notification: %s", exc)
                    return
                time.sleep(min(2 ** delivery.attempts, 8))
        self.last_ok_at, self.last_error = time.time(), None
        if delivery.on_done is not None:
            try:
                delivery.on_done(result)
            except Exception:
                logger.debug("app push: delivery callback failed", exc_info=True)

    def drain(self, timeout: float = 5.0) -> bool:
        """Wait for queued pushes (tests; short-lived processes such as cron workers). True when empty."""
        deadline = time.time() + timeout
        while self._queue.unfinished_tasks and time.time() < deadline:
            time.sleep(0.05)
        return not self._queue.unfinished_tasks
