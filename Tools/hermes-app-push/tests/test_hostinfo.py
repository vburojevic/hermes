"""``/app-push host``: Hermes's launchd jobs and how launchd schedules them (``hostinfo.report``).

Runs against a temporary LaunchAgents folder and fake ``launchctl``/``ps``/``ioreg`` output, never the
real launchd.
"""

from __future__ import annotations

import hashlib
import importlib.util
import plistlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("app_push_hostinfo", HERE.parent / "hostinfo.py")
hostinfo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hostinfo)


def _plist(folder: Path, label: str, arguments: list[str], process_type: str | None = None) -> None:
    data = {"Label": label, "ProgramArguments": arguments}
    if process_type:
        data["ProcessType"] = process_type
    (folder / f"{label}.plist").write_bytes(plistlib.dumps(data))


def _runner(spawn: dict[str, tuple[str, int]], priorities: dict[int, int]):
    def run(argv: list[str]) -> str:
        if argv[0].endswith("ioreg"):
            return '  "IOPlatformUUID" = "11111111-2222-3333-4444-555555555555"\n'
        if argv[0].endswith("launchctl"):
            label = argv[2].rsplit("/", 1)[-1]
            if label not in spawn:
                return ""
            kind, pid = spawn[label]
            return f"{argv[2]} = {{\n\tstate = running\n\tpid = {pid}\n\tspawn type = {kind} (5)\n}}\n"
        if argv[0].endswith("ps"):
            return f"  {priorities.get(int(argv[-1]), 31)}\n"
        return ""
    return run


def test_lists_gateways_dashboards_and_their_proxies(tmp_path):
    _plist(tmp_path, "ai.hermes.gateway", ["/usr/bin/osascript", "-e", "exec hermes gateway run"])
    _plist(tmp_path, "ai.hermes.dashboard", ["/bin/hermes", "dashboard", "--port", "9119"], "Interactive")
    _plist(tmp_path, "ai.hermes.dashboard-proxy", ["/usr/bin/python3", "/x/hermes-dashboard-proxy.py"])
    _plist(tmp_path, "ai.hermes.browser-cdp", ["/bin/chrome", "--remote-debugging-port=9222"])
    _plist(tmp_path, "com.example.other", ["/bin/other"])
    run = _runner({"ai.hermes.gateway": ("background", 40), "ai.hermes.dashboard": ("interactive", 41),
                   "ai.hermes.dashboard-proxy": ("background", 42)}, {40: 20, 41: 31, 42: 20})
    report = hostinfo.report(agents=tmp_path, environ={"XPC_SERVICE_NAME": "ai.hermes.dashboard"},
                             system="Darwin", uid=501, run=run)
    assert report["os"] == "darwin"
    assert report["machine_id"] == hashlib.sha256(b"11111111-2222-3333-4444-555555555555").hexdigest()[:16]
    jobs = {job["label"]: job for job in report["jobs"]}
    assert set(jobs) == {"ai.hermes.gateway", "ai.hermes.dashboard", "ai.hermes.dashboard-proxy"}
    assert jobs["ai.hermes.gateway"] == {"label": "ai.hermes.gateway", "role": "gateway",
                                         "plist": str(tmp_path / "ai.hermes.gateway.plist"), "process_type": None,
                                         "spawn_type": "background", "pid": 40, "priority": 20}
    assert jobs["ai.hermes.dashboard"]["process_type"] == "Interactive"
    assert jobs["ai.hermes.dashboard"]["spawn_type"] == "interactive"
    assert jobs["ai.hermes.dashboard-proxy"]["role"] == "dashboard"


def test_own_job_with_another_label_is_listed(tmp_path):
    _plist(tmp_path, "com.me.hermes", ["/bin/hermes", "gateway", "run"])
    report = hostinfo.report(agents=tmp_path, environ={"XPC_SERVICE_NAME": "com.me.hermes"}, system="darwin",
                             uid=501, run=_runner({"com.me.hermes": ("background", 7)}, {7: 20}))
    assert [(job["label"], job["role"]) for job in report["jobs"]] == [("com.me.hermes", "own")]


def test_an_unloaded_job_has_no_spawn_type_and_a_bad_plist_is_skipped(tmp_path):
    _plist(tmp_path, "ai.hermes.gateway", ["/bin/hermes", "gateway", "run"])
    (tmp_path / "ai.hermes.gateway-broken.plist").write_text("not a plist")
    report = hostinfo.report(agents=tmp_path, environ={}, system="darwin", uid=501, run=_runner({}, {}))
    assert report["jobs"] == [{"label": "ai.hermes.gateway", "role": "gateway",
                               "plist": str(tmp_path / "ai.hermes.gateway.plist"), "process_type": None,
                               "spawn_type": None, "pid": None, "priority": None}]


def test_other_systems_have_no_launchd_jobs(tmp_path):
    report = hostinfo.report(agents=tmp_path, environ={}, system="Linux", uid=1000, run=lambda argv: "")
    assert report["os"] == "linux"
    assert report["jobs"] == []
