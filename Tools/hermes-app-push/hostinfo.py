"""How the gateway's computer schedules Hermes, for the app's Settings → Setup → Priority.

On macOS, launchd runs a LaunchAgent with no ``ProcessType`` as a background job ("spawn type =
background"): the system throttles its CPU and I/O, so on a busy Mac Hermes answers late or not at
all while the person's apps carry on (``man launchd.plist``, ProcessType). ``Interactive`` gives a job
the same resource limits as apps, none. Hermes's own gateway plist has no ProcessType, and
``hermes gateway start``/``restart``/``update`` write it again without one.

``report()`` lists Hermes's launchd jobs on this Mac: its gateways (``ai.hermes.gateway*``, the labels
Hermes writes), any other ``ai.hermes.*`` job that runs a dashboard (``hermes dashboard``/``serve``, or
a proxy in front of one), and the job this process runs in (``XPC_SERVICE_NAME``). For each: the
ProcessType in its plist, the spawn type launchd loaded it with, and the process's priority. It
never raises and runs only when the app asks, never at load.
"""

from __future__ import annotations

import hashlib
import os
import platform
import plistlib
import re
import subprocess
from pathlib import Path
from typing import Callable

Runner = Callable[[list[str]], str]


def _run(argv: list[str]) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=5, check=False).stdout
    except Exception:
        return ""


def machine_id(system: str, run: Runner = _run) -> str | None:
    """A hash of the machine's hardware id, so the Mac app can tell it's on the same Mac without
    the id itself leaving it (the app hashes its own the same way)."""
    raw = ""
    if system == "darwin":
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"]))
        raw = match.group(1) if match else ""
    elif system == "linux":
        try:
            raw = Path("/etc/machine-id").read_text().strip()
        except OSError:
            raw = ""
    return hashlib.sha256(raw.encode()).hexdigest()[:16] if raw else None


def _role(label: str, arguments: list[str]) -> str | None:
    if label.startswith("ai.hermes.gateway"):
        return "gateway"
    joined = " ".join(arguments).lower()
    if label.startswith("ai.hermes.") and ("dashboard" in joined or " serve" in f" {joined}"):
        return "dashboard"
    return None


def _job(label: str, role: str, plist: Path, data: dict, uid: int, run: Runner) -> dict:
    printed = run(["/bin/launchctl", "print", f"gui/{uid}/{label}"])
    spawn = re.search(r"spawn type = (\w+)", printed)
    pid = re.search(r"^\s*pid = (\d+)", printed, re.MULTILINE)
    priority = None
    if pid:
        value = run(["/bin/ps", "-o", "pri=", "-p", pid.group(1)]).strip()
        priority = int(value) if value.isdigit() else None
    process_type = data.get("ProcessType")
    return {
        "label": label, "role": role, "plist": str(plist),
        "process_type": process_type if isinstance(process_type, str) else None,
        "spawn_type": spawn.group(1) if spawn else None,
        "pid": int(pid.group(1)) if pid else None,
        "priority": priority,
    }


def report(*, agents: Path | None = None, environ: dict | None = None, system: str | None = None,
           uid: int | None = None, run: Runner = _run) -> dict:
    system = (system or platform.system()).lower()
    out: dict = {"os": system, "machine_id": machine_id(system, run), "jobs": []}
    if system != "darwin":
        return out
    environ = os.environ if environ is None else environ
    agents = agents or Path.home() / "Library" / "LaunchAgents"
    uid = os.getuid() if uid is None else uid
    own = environ.get("XPC_SERVICE_NAME", "")
    seen: set[str] = set()
    try:
        plists = sorted(agents.glob("ai.hermes.*.plist")) + ([agents / f"{own}.plist"] if own and own != "0" else [])
    except OSError:
        plists = []
    for plist in plists:
        try:
            data = plistlib.loads(plist.read_bytes())
        except Exception:
            continue
        label = data.get("Label")
        if not isinstance(label, str) or label in seen:
            continue
        arguments = [a for a in data.get("ProgramArguments") or [] if isinstance(a, str)]
        role = _role(label, arguments) or ("own" if label == own else None)
        if role is None:
            continue
        seen.add(label)
        out["jobs"].append(_job(label, role, plist, data, uid, run))
    return out
