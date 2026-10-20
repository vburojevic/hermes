"""A Mac too loaded to run Hermes: its processes get a moment of CPU now and then.

Measured on 2026-10-19 at load 440-570 on 10 cores: neither the gateway's /health (8642) nor the
dashboard (9119) answered within 20 s, the Bot Mode socket went quiet, and the app's own main thread
sat idle, waiting. The kernel still takes connections meanwhile (they wait in the listen backlog), so
a client sees its connection taken and its question unanswered: busy, not offline.

While starving, nothing is answered between slices: HTTP requests on both mocks (the gateway's
health check too, unless `health` is "prompt"), socket answers, events and pongs. Every `gap`
seconds (picked at random in the range) the process runs for `slice` seconds, and everything that
waited goes out at once, as a starved Python process sends it.

    POST /api/mock/starve {"seconds": 600, "gap": [5, 30], "slice": 0.6, "health": "late"}
    POST /api/mock/starve {"seconds": 0}                          # back to normal
    --starve 5-30                                                 # from launch, until stopped

Both mocks load this file once per process, under one name (`mock_starve`), so the gateway and the
backend starve together, as processes on one machine do.
"""

import random
import threading
import time

LOCK = threading.Lock()
STATE = {"until": 0.0, "gap": (5.0, 30.0), "slice": 0.6, "window": 0.0, "health": "late"}


def start(seconds, gap=(5.0, 30.0), slice_=0.6, health="late"):
    with LOCK:
        STATE["until"] = time.time() + float(seconds) if seconds else 0.0
        STATE["gap"] = (float(gap[0]), float(gap[1]))
        STATE["slice"] = float(slice_)
        STATE["health"] = health
        # The first slice comes after a gap, not at once.
        STATE["window"] = time.time() + random.uniform(*STATE["gap"])


def configure(body):
    """`POST /api/mock/starve`'s body."""
    gap = body.get("gap") or [5, 30]
    start(float(body.get("seconds") or 0), gap=(gap[0], gap[1]), slice_=body.get("slice") or 0.6,
          health=body.get("health") or "late")
    return describe()


def parse_gap(text):
    """`--starve 5-30`."""
    low, _, high = text.partition("-")
    return float(low), float(high or low)


def describe():
    with LOCK:
        return {"starving": STATE["until"] > time.time(), "until": STATE["until"], "gap": list(STATE["gap"]),
                "slice": STATE["slice"], "health": STATE["health"]}


def runs_at():
    """When the starved process next runs: now while it runs (in its slice) or isn't starved."""
    with LOCK:
        now = time.time()
        if now >= STATE["until"]:
            return now
        start_at = STATE["window"]
        if start_at <= now < start_at + STATE["slice"]:
            return now
        if start_at <= now:
            start_at = now + random.uniform(*STATE["gap"])
            STATE["window"] = start_at
        return min(start_at, STATE["until"])


def wait(health=False):
    """Blocks until the starved process runs (returns at once when it isn't starved). A health
    check waits too unless the starve was started with `health: "prompt"` (the gateway answering
    its health check at once while everything else crawls, as `--busy` does)."""
    if health and STATE["health"] == "prompt":
        return
    while True:
        at = runs_at()
        now = time.time()
        if at <= now:
            return
        time.sleep(min(0.2, at - now))
