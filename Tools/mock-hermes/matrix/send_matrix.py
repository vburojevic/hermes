"""The send matrix in the app, on the iPhone simulator or the Mac, against the mock (`docs/development.md`).

Each scenario launches Hermes Dev with launch flags, drives the mock through its endpoints and
the app through AXe, and records per cell: what the mock did (its log), what the app shows (the
accessibility tree and a screenshot), and pass or fail against the expected and forbidden lines.

    python3 -I send_matrix.py --udid <sim> --app <Hermes Dev.app> --out <dir> [--only lane|window|name,…] [--look light|dark]
    python3 -I send_matrix.py --mac --app <Hermes Dev.app> --out <dir> …

The Mac app is launched in the desktop session through `aqua-exec` (`HERMES_AQUA_EXEC` names
another launcher) and read through cua-driver.

Stdlib only. Starts its own mock on 40219/40742 and stops it at the end.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
BACKEND, GATEWAY, KEY = 40219, 40742, "dev-key-0123456789abcdef"
BUNDLE = "co.caffeinatedcode.hermes.dev"
BASE_FLAGS = ["-HERMES_PASTEBOARD", "none", "-HERMES_WHATS_NEW", "NO", "-HERMES_TIPS", "hide", "-push.primeDeclines", "2",
              "-HERMES_BOOTSTRAP_URL", f"http://127.0.0.1:{GATEWAY}", "-HERMES_BOOTSTRAP_KEY", KEY]
WITH_BACKEND = ["-HERMES_BOOTSTRAP_BACKEND", f"http://127.0.0.1:{BACKEND}"]

# Never "finished" while a turn runs, never the chat limit for another reason, never a bare code.
FORBIDDEN = ["as many chats at once", "finished before reading your note", "SESSION_", "permission_denied", "queue_full",
             "Lost track of this reply"]


class Run:
    def __init__(self, args):
        self.args = args
        self.udid = args.udid
        os.makedirs(args.out, exist_ok=True)
        self.results = []
        self.mock = None
        self.mock_log = os.path.join(args.out, "mock.log")

    # -------------------------------------------------------------- the mock

    def start_mock(self):
        log = open(self.mock_log, "a")
        self.mock = subprocess.Popen(
            [sys.executable, "-I", f"{REPO}/Tools/mock-hermes/backend.py", "--port", str(BACKEND),
             "--gateway-port", str(GATEWAY), "--gateway-key", KEY, "--push-relay", "none", "--app-plugins", "current"],
            stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{GATEWAY}/health", timeout=1)
                urllib.request.urlopen(f"http://127.0.0.1:{BACKEND}/", timeout=1)
                return
            except urllib.error.HTTPError:
                return
            except OSError:
                time.sleep(0.2)
        raise SystemExit("the mock didn't start")

    def stop_mock(self):
        if self.mock:
            self.mock.terminate()
            self.mock.wait(timeout=10)
            self.mock = None

    def restart_mock(self):
        self.stop_mock()
        self.start_mock()

    def post(self, path, body=None, port=BACKEND):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body or {}).encode(), method="POST")
        request.add_header("Content-Type", "application/json")
        request.add_header("Authorization", f"Bearer {KEY}")
        request.add_header("X-Hermes-Session-Token", self.token())
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return response.status, json.loads(response.read() or b"null")
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"null")

    def get(self, url, headers):
        request = urllib.request.Request(url)
        for name, value in headers.items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.loads(response.read() or b"null")
        except (urllib.error.URLError, OSError, ValueError):
            return None

    def stored_count(self, text, since=0):
        """What the gateway did: how many of the person's stored rows hold `text`, across every chat
        the app read since `since` (the chats in the mock's log) and the gateway's own list."""
        import re
        log = self.log_since(0)
        tokens = re.findall(r"token ([A-Za-z0-9_-]+)\)", log)
        headers = {"X-Hermes-Session-Token": tokens[-1] if tokens else "", "Authorization": f"Bearer {KEY}"}
        chats = set(re.findall(r"/api/sessions/([^/?\s]+)/messages\?[^\s\"]*?profile=(\w+)", self.log_since(since)))
        # Normal chats are read from the gateway, with no profile.
        chats |= {(chat, "") for chat in re.findall(r"GET /api/sessions/([^/?\s]+)/messages\?(?![^\s]*profile=)", self.log_since(since))}
        listed = self.get(f"http://127.0.0.1:{GATEWAY}/api/sessions?limit=200", headers) or {}
        chats |= {(row.get("id"), "") for row in listed.get("data", [])}
        count = 0
        for chat, profile in chats:
            query = f"?limit=300&offset=0&order=latest&include_compacted=true" + (f"&profile={profile}" if profile else "")
            port = BACKEND if profile else GATEWAY
            rows = self.get(f"http://127.0.0.1:{port}/api/sessions/{chat}/messages{query}", headers) or {}
            rows = rows.get("messages", rows.get("data", [])) if isinstance(rows, dict) else rows
            for row in rows or []:
                content = row.get("content")
                words = content if isinstance(content, str) else json.dumps(content)
                if row.get("role") == "user" and text in (words or "") and row.get("display_kind") != "hidden":
                    count += 1
        return count

    def token(self):
        """The backend's session token, which its own endpoints (the mock's included) ask for."""
        import re
        tokens = re.findall(r"token ([A-Za-z0-9_-]+)\)", self.log_since(0))
        return tokens[-1] if tokens else ""

    def log_mark(self):
        return os.path.getsize(self.mock_log)

    def log_since(self, mark):
        with open(self.mock_log, errors="replace") as handle:
            handle.seek(mark)
            return handle.read()

    # -------------------------------------------------------------- the app

    def sh(self, *command, check=False):
        return subprocess.run(command, capture_output=True, text=True, check=check)

    def launch(self, flags, backend=True):
        self.sh("xcrun", "simctl", "terminate", self.udid, BUNDLE)
        time.sleep(0.5)
        self.sh("xcrun", "simctl", "launch", self.udid, BUNDLE, *BASE_FLAGS, *(WITH_BACKEND if backend else []), *flags, check=True)

    def terminate(self):
        self.sh("xcrun", "simctl", "terminate", self.udid, BUNDLE)

    def reset_app(self):
        """A fresh install: no chats, queues or outboxes from an earlier scenario."""
        self.terminate()
        self.sh("xcrun", "simctl", "uninstall", self.udid, BUNDLE)
        self.sh("xcrun", "simctl", "install", self.udid, self.args.app, check=True)

    def ui(self):
        out = self.sh("axe", "describe-ui", "--udid", self.udid).stdout
        try:
            tree = json.loads(out)
        except json.JSONDecodeError:
            return [], []
        labels, frames = [], []

        def walk(node):
            if isinstance(node, list):
                for child in node:
                    walk(child)
                return
            if not isinstance(node, dict):
                return
            for key in ("AXLabel", "AXValue", "title"):
                value = node.get(key)
                if isinstance(value, str) and value.strip():
                    labels.append(value.strip())
                    frames.append((value.strip(), node.get("frame")))
            walk(node.get("children") or [])

        walk(tree)
        return labels, frames

    def shot(self, name):
        path = os.path.join(self.args.out, f"{name}.png")
        self.sh("axe", "screenshot", "--udid", self.udid, "--output", path)
        labels, _ = self.ui()
        with open(os.path.join(self.args.out, f"{name}.txt"), "w") as handle:
            handle.write("\n".join(labels))
        return labels

    def tap_label(self, label, fallback=None):
        # By the element's frame (a menu's rows don't always answer a tap by label), a few tries.
        for _ in range(3):
            _, frames = self.ui()
            for text, frame in frames:
                if text == label and frame:
                    x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
                    # A short touch: the system's context menu ignores a synthetic tap.
                    self.sh("axe", "touch", "-x", str(int(x)), "-y", str(int(y)), "--down", "--up", "--delay", "0.15", "--udid", self.udid)
                    return True
            time.sleep(0.7)
        if fallback:
            # The system's context menu isn't always in the tree; its rows sit in the same place each run.
            self.sh("axe", "touch", "-x", str(fallback[0]), "-y", str(fallback[1]), "--down", "--up", "--delay", "0.15", "--udid", self.udid)
            return True
        return False

    def long_press_label(self, label, contains=True):
        _, frames = self.ui()
        for text, frame in frames:
            if frame and ((label in text) if contains else text == label):
                x, y = frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
                self.sh("axe", "touch", "-x", str(int(x)), "-y", str(int(y)), "--down", "--up", "--delay", "1.2", "--udid", self.udid)
                return True
        return False

    # -------------------------------------------------------------- cells

    def record(self, scenario, cells, labels, gateway, expect=(), forbid=FORBIDDEN, gateway_expect=(), gateway_count=None, note="",
               stored=None):
        text = "\n".join(labels)
        # A tuple is any one of its lines (the iPhone's and the Mac's VoiceOver wording differ).
        def shown(line):
            return any(one in text for one in line) if isinstance(line, tuple) else line in text
        missing = [line for line in expect if not shown(line)]
        shown_forbidden = [line for line in forbid if line in text]
        gateway_missing = [line for line in gateway_expect if line not in gateway]
        count_wrong = []
        if gateway_count:
            line, count = gateway_count
            if gateway.count(line) != count:
                count_wrong = [f"{line!r} ×{gateway.count(line)}, expected ×{count}"]
        if stored:
            line, count = stored
            found = self.stored_count(line)
            gateway = f"{gateway}\nstored rows with {line!r}: {found}"
            if found != count:
                count_wrong.append(f"stored {line!r} ×{found}, expected ×{count}")
        passed = not (missing or shown_forbidden or gateway_missing or count_wrong)
        for cell in cells:
            self.results.append({
                "scenario": scenario, "cell": cell, "pass": passed,
                "app": [str(line) for line in expect if shown(line)][:4], "missing": missing, "forbidden": shown_forbidden,
                "gateway": [line for line in gateway.splitlines() if line.startswith(("stored rows", "owner:"))] or list(gateway_expect),
                "gateway_missing": gateway_missing, "count": count_wrong, "note": note,
            })
        print(f"{'PASS' if passed else 'FAIL'} {scenario} {cells} {missing or ''} {shown_forbidden or ''} {gateway_missing or ''} {count_wrong or ''}", flush=True)

    def write(self):
        # Merged with earlier runs into the same folder: a re-run of a scenario replaces its rows.
        path = os.path.join(self.args.out, "results.json")
        earlier = []
        if os.path.exists(path):
            with open(path) as handle:
                earlier = json.load(handle)
        mine = {r["scenario"] for r in self.results}
        if not hasattr(self, "_earlier"):
            self._earlier = [r for r in earlier if r["scenario"] not in mine]
        else:
            self._earlier = [r for r in self._earlier if r["scenario"] not in mine]
        with open(path, "w") as handle:
            json.dump(self._earlier + self.results, handle, indent=1)


class MacRun(Run):
    """The same scenarios on the Mac: Hermes Dev launched in the desktop session (aqua-exec), read
    and driven through cua-driver with one session label. Its data folder is kept aside first and
    put back at the end, byte for byte."""

    AQUA = os.environ.get("HERMES_AQUA_EXEC") or os.path.expanduser("~/.local/bin/aqua-exec")
    DATA = os.path.expanduser("~/Library/Application Support/co.caffeinatedcode.hermes.dev")
    SESSION = "matrix-532"

    def __init__(self, args):
        super().__init__(args)
        self.saved = os.path.join(args.out, "saved-data")
        self.window = None
        # A session label lasts until it's ended (or the driver restarts): start it for this run.
        self.sh("cua-driver", "call", "start_session", json.dumps({"session": self.SESSION}))

    def aqua(self, *command, timeout=30):
        return self.sh(self.AQUA, "--timeout", str(timeout), "--", *command)

    def cua(self, tool, **params):
        out = self.sh("cua-driver", "call", tool, json.dumps({**params, "session": self.SESSION})).stdout
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return {}

    def save_data(self):
        if os.path.exists(self.DATA) and not os.path.exists(self.saved):
            self.sh("ditto", self.DATA, self.saved, check=True)

    def restore_data(self):
        if os.path.exists(self.saved):
            self.sh("rm", "-rf", self.DATA)
            self.sh("ditto", self.saved, self.DATA, check=True)

    def launch(self, flags, backend=True):
        self.terminate()
        # The system is dark here: light needs the app held to Aqua.
        look = ["-AppleInterfaceStyle", "Dark"] if self.args.look == "dark" else ["-NSRequiresAquaSystemAppearance", "YES"]
        self.aqua("open", "-n", "-a", self.args.app, "--args", *BASE_FLAGS, *(WITH_BACKEND if backend else []), *look, *flags)
        self.window = None

    def terminate(self):
        self.aqua("osascript", "-e", f'tell application id "{BUNDLE}" to quit')
        for _ in range(40):
            if not self.find_window(any_window=True):
                break
            time.sleep(0.25)
        self.window = None

    def reset_app(self):
        self.terminate()
        self.sh("rm", "-rf", self.DATA)

    def find_window(self, any_window=False):
        windows = self.cua("list_windows").get("windows") or []
        mine = [w for w in windows if w.get("app_name") in ("Hermes Dev", "Hermes") and w.get("layer") == 0
                and (any_window or w.get("is_on_screen"))]
        mine = [w for w in mine if (w.get("bounds") or {}).get("width", 0) > 400] or mine
        return mine[0] if mine else None

    def state(self, screenshot=None):
        self.window = self.window or self.find_window()
        if not self.window:
            return {}
        params = {"pid": self.window["pid"], "window_id": self.window["window_id"], "include_screenshot": bool(screenshot),
                  "max_depth": 80, "max_elements": 6000, "timeout_ms": 20000}
        if screenshot:
            params["screenshot_out_file"] = screenshot
        result = self.cua("get_window_state", **params)
        state = result.get("structuredContent", result)
        if state.get("truncated"):
            print(f"  (the window's tree was cut short: {state.get('truncation_reason')})", flush=True)
        return state

    def ui(self):
        state = self.state()
        elements = state.get("elements") or []
        # Text with no action of its own is only in the Markdown rendering of the tree.
        labels, frames = [line.strip() for line in (state.get("tree_markdown") or "").splitlines() if line.strip()], []
        for element in elements:
            for key in ("label", "value"):
                value = element.get(key)
                if isinstance(value, str) and value.strip():
                    labels.append(value.strip())
                    frames.append((value.strip(), element))
        return labels, frames

    def shot(self, name):
        path = os.path.join(self.args.out, f"{name}.png")
        state = self.state(screenshot=path)
        elements = state.get("elements") or []
        labels = [e.get(k).strip() for e in elements for k in ("label", "value") if isinstance(e.get(k), str) and e.get(k).strip()]
        labels += [line.strip() for line in (state.get("tree_markdown") or "").splitlines() if line.strip()]
        with open(os.path.join(self.args.out, f"{name}.txt"), "w") as handle:
            handle.write("\n".join(labels))
        return labels

    def act(self, tool, label, contains=False):
        _, frames = self.ui()
        for text, element in frames:
            if (label in text) if contains else text == label:
                token = element.get("element_token")
                self.cua(tool, pid=self.window["pid"], window_id=self.window["window_id"], element_token=token)
                return True
        return False

    def tap_label(self, label, fallback=None):
        return self.act("click", label)

    def long_press_label(self, label, contains=True):
        # The Mac's message menu is the context menu.
        return self.act("right_click", label, contains=True)


# ------------------------------------------------------------------ scenarios
# Each one: launch, drive, wait, look. `r` is the Run.

def idle_send(r):
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "hello there", "-HERMES_SEND_AFTER", "6"])
    time.sleep(14)
    labels = r.shot("idle-send")
    r.record("idle_send", [("send", "idle"), ("talk", "idle")], labels, r.log_since(mark), expect=["hello there"],
             forbid=FORBIDDEN + ["Up next", "Sending…"], stored=("hello there", 1))


def running_steer(r):
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "slow walk through the logs", "-HERMES_SEND_AFTER", "6",
              "-HERMES_FOLLOWUP", "also note the time", "-HERMES_FOLLOWUP_MODE", "steer", "-HERMES_FOLLOWUP_SEND", "YES",
              "-HERMES_FOLLOWUP_AFTER", "5"])
    time.sleep(20)
    labels = r.shot("running-steer")
    r.record("running_steer", [("steer", "turnRunning"), ("steer", "toolRunning")], labels, "", expect=["also note the time", ("Steer ·", "Steer, read")])


def running_upnext(r):
    mark = r.log_mark()
    r.launch(["-HERMES_SEND", "snapshot the dashboard", "-HERMES_FOLLOWUP", "and after that, the logs",
              "-HERMES_FOLLOWUP_MODE", "sendNext", "-HERMES_FOLLOWUP_SEND", "YES", "-HERMES_FOLLOWUP_AFTER", "4"])
    time.sleep(10)
    labels = r.shot("running-upnext")
    r.record("running_upnext_tray", [("upNext", "turnRunning"), ("upNext", "toolRunning")], labels, "",
             expect=["sends when this reply is done"])
    time.sleep(30)
    labels = r.shot("running-upnext-drained")
    r.record("running_upnext_drained", [("upNext", "idle")], labels, r.log_since(mark), expect=["Sent from the queue"],
             forbid=FORBIDDEN + ["sends when this reply is done"], stored=("and after that, the logs", 1))


def starting_steer(r):
    r.launch(["-HERMES_SEND", "cold start: snapshot the dashboard", "-HERMES_FOLLOWUP", "use the staging one",
              "-HERMES_FOLLOWUP_MODE", "steer", "-HERMES_FOLLOWUP_SEND", "YES", "-HERMES_FOLLOWUP_AFTER", "1.5"])
    time.sleep(8)
    labels = r.shot("starting-steer")
    r.record("starting_steer", [("steer", "turnRunning·starting")], labels, "",
             expect=["Hermes was still starting the reply, so it sends next"])


def stop_running(r):
    mark = r.log_mark()
    r.launch(["-HERMES_SEND", "snapshot the dashboard"])
    time.sleep(9)
    r.tap_label("Stop")
    time.sleep(4)
    labels = r.shot("stop")
    r.record("stop", [("stop", "toolRunning")], labels, r.log_since(mark), expect=["Stopped"])


def background_process(r):
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "start the background tasks", "-HERMES_SEND_AFTER", "6",
              "-HERMES_FOLLOWUP", "how are they going?", "-HERMES_FOLLOWUP_SEND", "YES", "-HERMES_FOLLOWUP_AFTER", "14"])
    time.sleep(18)
    # The finished process's notice starts a turn of Hermes's own a moment before the send.
    r.post("/api/mock/turn-elsewhere", {"profile": "default", "seconds": 8, "text": "A background process finished.",
                                        "reply": "The tests failed; the rest passed."})
    time.sleep(4)
    labels = r.shot("background-process")
    time.sleep(16)
    labels_after = r.shot("background-process-after")
    r.record("background_process", [("send", "backgroundProcess"), ("upNext", "backgroundProcess")], labels + labels_after,
             r.log_since(mark), expect=["how are they going?"], stored=("how are they going?", 1),
             note="the send landed while Hermes's notice turn ran; it waits and runs once")


def owner(r, mode, name, cells, expect, gateway_count=None, seconds=25, ack=0, stored=None):
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", f"{name}: are you there?", "-HERMES_SEND_AFTER", "8"])
    time.sleep(4)
    r.post("/api/mock/owner", {"profile": "default", "mode": mode, "seconds": seconds, "ack": ack})
    time.sleep(8)
    labels = r.shot(name)
    # A held chat is asked again 30 s after the refusal: the after frame waits past that.
    time.sleep(max(seconds, 30) + 12)
    labels_after = r.shot(f"{name}-after")
    r.post("/api/mock/owner", {"profile": "default", "mode": "off"})
    r.record(name, cells, labels + labels_after, r.log_since(mark), expect=expect, gateway_count=gateway_count, stored=stored)


def owner_busy(r):
    owner(r, "busy", "owner-busy", [("send", "ownerBusy"), ("retry", "ownerBusy")],
          ["The gateway is running a turn in this chat.", "sends when that turn ends"], stored=("owner-busy: are you there?", 1))


def owner_forward(r):
    owner(r, "forward", "owner-forward", [("send", "ownerBusy·forwarded")], ["sends when the gateway's turn ends"],
          gateway_count=("owner: ran a forwarded message", 1))


def owner_unconfirmed(r):
    owner(r, "unconfirmed", "owner-unconfirmed", [("send", "ownerUnconfirmed"), ("retry", "ownerUnconfirmed")],
          ["didn't confirm your message in time"], gateway_count=("owner: ran a forwarded message", 1))


def slow_ack(r):
    """The gateway's owner answers past 30 s: SESSION_OWNER_UNCONFIRMED while the message still runs there.
    The chat says it may be queued there, then finds it ran: never sent a second time."""
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "slow-ack: are you there?", "-HERMES_SEND_AFTER", "8"])
    time.sleep(4)
    r.post("/api/mock/owner", {"profile": "default", "mode": "forward", "seconds": 40, "ack": 35})
    time.sleep(12)
    labels = r.shot("slow-ack-sending")
    time.sleep(26)
    labels_late = r.shot("slow-ack-answered")
    time.sleep(20)
    labels_after = r.shot("slow-ack-after")
    r.post("/api/mock/owner", {"profile": "default", "mode": "off"})
    r.record("slow-ack", [("send", "ownerUnconfirmed·slowAck")], labels + labels_late + labels_after, r.log_since(mark),
             expect=[("didn't confirm your message in time", "The gateway ran this after its own turn")],
             gateway_count=("owner: ran a forwarded message", 1))


def lost_answer(r):
    """prompt.submit's answer is lost with the prompt taken: the chat finds the turn, and nothing goes twice."""
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "lost answer: count the logs", "-HERMES_SEND_AFTER", "8"])
    time.sleep(4)
    r.post("/api/mock/lose-answer", {"method": "prompt.submit", "taken": True})
    time.sleep(30)
    labels = r.shot("lost-answer")
    r.record("lost_answer", [("send", "turnRunning·lostAnswer")], labels, r.log_since(mark),
             expect=["lost answer: count the logs"], forbid=FORBIDDEN + ["Send Again"], stored=("lost answer: count the logs", 1))


def another_bot(r):
    mark = r.log_mark()
    r.post("/api/mock/message-agent", {"from": "researcher", "to": "writer", "text": "Can you tighten the intro?"})
    r.launch(["-HERMES_OPEN", "bot:writer", "-HERMES_SEND", "when you're free, the outro too", "-HERMES_SEND_AFTER", "6"])
    time.sleep(10)
    labels = r.shot("another-bot")
    time.sleep(30)
    labels_after = r.shot("another-bot-after")
    r.record("another_bot", [("toAnotherBot", "notOwned"), ("send", "notOwned")], labels + labels_after, r.log_since(mark),
             expect=["is answering", "when you're free, the outro too"], stored=("when you're free, the outro too", 1))


def routine(r):
    mark = r.log_mark()
    r.post("/api/mock/routine-elsewhere", {"profile": "ops", "title": "Disk report", "seconds": 25})
    r.launch(["-HERMES_OPEN", "bot:ops", "-HERMES_SEND", "anything else on the disks?", "-HERMES_SEND_AFTER", "6"])
    time.sleep(10)
    labels = r.shot("routine")
    time.sleep(28)
    labels_after = r.shot("routine-after")
    r.record("routine", [("routineFollowUp", "notOwned")], labels + labels_after, r.log_since(mark),
             expect=["following up on its routine", "anything else on the disks?"], stored=("anything else on the disks?", 1))


def limit(r):
    mark = r.log_mark()
    r.post("/api/mock/limit", {"seconds": 20, "active": 3, "limit": 3})
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "limit: are you there?", "-HERMES_SEND_AFTER", "6"])
    time.sleep(9)
    labels = r.shot("limit")
    r.record("limit", [("send", "ownerBusy·chatLimit")], labels, r.log_since(mark), expect=["(3 of 3)"], forbid=FORBIDDEN[1:])


def reconnecting_steer(r):
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "slow marathon through the logs", "-HERMES_SEND_AFTER", "6",
              "-HERMES_FOLLOWUP", "skip the old ones", "-HERMES_FOLLOWUP_MODE", "steer", "-HERMES_FOLLOWUP_SEND", "YES",
              "-HERMES_FOLLOWUP_AFTER", "6"])
    time.sleep(10)
    r.post("/api/mock/drop-sockets", {"outage": 50})
    time.sleep(48)
    labels = r.shot("reconnecting-steer")
    r.record("reconnecting_steer", [("steer", "reconnecting"), ("talk", "reconnecting")], labels, "",
             expect=["skip the old ones", "sends when Hermes is back"], note="a steer that couldn't reach the gateway goes next, saying so")


def offline_send(r):
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "offline: keep this one", "-HERMES_SEND_AFTER", "8"])
    time.sleep(5)
    r.post("/api/mock/drop-sockets", {"outage": 20})
    time.sleep(6)
    labels = r.shot("offline-send")
    time.sleep(30)
    labels_after = r.shot("offline-send-after")
    r.record("offline_send", [("send", "offline"), ("retry", "offline"), ("toAnotherBot", "offline")], labels + labels_after,
             r.log_since(mark), expect=["Waiting for", "offline: keep this one"], stored=("offline: keep this one", 1))


def relaunch_queue(r):
    mark = r.log_mark()
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "slow marathon: read every log", "-HERMES_SEND_AFTER", "6",
              "-HERMES_FOLLOWUP", "then sum it up", "-HERMES_FOLLOWUP_MODE", "sendNext", "-HERMES_FOLLOWUP_SEND", "YES",
              "-HERMES_FOLLOWUP_AFTER", "4"])
    time.sleep(14)
    r.shot("relaunch-before-quit")
    r.terminate()
    time.sleep(2)
    r.launch(["-HERMES_OPEN", "bot:default"])
    time.sleep(8)
    labels = r.shot("relaunch-reopened")
    time.sleep(50)
    labels_after = r.shot("relaunch-drained")
    r.record("relaunch_queue", [("upNext", "relaunch"), ("send", "relaunch")], labels + labels_after, r.log_since(mark),
             expect=["then sum it up"], stored=("then sum it up", 1))


def maybe_sent(r, tag=""):
    """Shot 1: the Maybe sent row, a relaunch with a message still in the outbox."""
    r.launch(["-HERMES_OPEN", "bot:default", "-HERMES_SEND", "did this one go?", "-HERMES_SEND_AFTER", "10"])
    time.sleep(6)
    r.post("/api/mock/drop-sockets", {"outage": 35})
    # Quit once the message waits for the gateway in the outbox.
    for _ in range(30):
        time.sleep(1)
        labels, _ = r.ui()
        if any("Waiting for" in label for label in labels):
            break
    r.shot(f"maybe-sent-waiting{tag}")
    r.terminate()
    time.sleep(32)
    r.launch(["-HERMES_OPEN", "bot:default"])
    time.sleep(12)
    labels = r.shot(f"shot-maybe-sent{tag}")
    r.record(f"maybe_sent{tag}", [("send", "relaunch·outbox")], labels, "", expect=[] if "before" in tag else ["Maybe sent"],
             stored=None if "before" in tag else ("did this one go?", 0))


def queued_run(r, tag=""):
    """Shot 2: "Queued behind another turn", an API-server-only chat with a run in front."""
    r.launch(["-HERMES_OPEN_SESSION", "api_1760_welcome", "-HERMES_SEND", "and then this, please", "-HERMES_SEND_AFTER", "8"],
             backend=False)
    time.sleep(5)
    r.post("/v1/runs", {"session_id": "api_1760_welcome", "input": "slow: another client's long question"}, port=GATEWAY)
    time.sleep(6)
    labels = r.shot(f"shot-queued-run{tag}")
    # The before build has no such header: its frame is the before, not a cell.
    r.record(f"queued_run{tag}", [("send", "turnRunning·apiServer")], labels, "",
             expect=[] if "before" in tag else ["Queued behind another turn"])


def edit_resend(r, tag=""):
    """Shot 3: the Edit and Resend strip, from a long press on a message (a normal chat: Bot Chats
    don't have it)."""
    r.launch(["-HERMES_SEND", "Rename the build step"])
    # The menu offers Edit and Resend once the reply has ended (about 45 s in the mock).
    for _ in range(40):
        time.sleep(3)
        labels, _ = r.ui()
        if any(label.startswith("Worked for") for label in labels):
            break
    if r.long_press_label("You: Rename the build step", contains=False):
        time.sleep(1.5)
        r.tap_label("Edit and Resend", fallback=(262, 306))
        time.sleep(1.5)
        r.tap_label("Continue")  # the simulator keyboard's one-time slide-to-type tip
        time.sleep(0.8)
    labels = r.shot(f"shot-edit-resend{tag}")
    r.record(f"edit_resend{tag}", [("editAndResend", "idle")], labels, "", expect=["Editing"])


def api_queue_full(r):
    r.post("/api/mock/run-caps", {"queue_max": 1}, port=GATEWAY)
    r.launch(["-HERMES_OPEN_SESSION", "api_1760_welcome", "-HERMES_SEND", "one more, please", "-HERMES_SEND_AFTER", "10"],
             backend=False)
    time.sleep(5)
    r.post("/v1/runs", {"session_id": "api_1760_welcome", "input": "slow: first"}, port=GATEWAY)
    r.post("/v1/runs", {"session_id": "api_1760_welcome", "input": "second"}, port=GATEWAY)
    time.sleep(9)
    labels = r.shot("api-queue-full")
    r.post("/api/mock/run-caps", {"queue_max": 32}, port=GATEWAY)
    r.record("api_queue_full", [("send", "ownerBusy·apiServerQueueFull")], labels, "",
             expect=["as many messages waiting in this chat"])


SCENARIOS = {f.__name__: f for f in [
    idle_send, running_steer, running_upnext, starting_steer, stop_running, background_process, owner_busy, owner_forward,
    owner_unconfirmed, slow_ack, lost_answer, another_bot, routine, limit, reconnecting_steer, offline_send, relaunch_queue, maybe_sent, queued_run,
    edit_resend, api_queue_full,
]}
SHOTS = ["maybe_sent", "queued_run", "edit_resend"]
LANE = ["idle_send", "running_steer", "running_upnext", "starting_steer", "stop_running", "background_process", "owner_busy",
        "owner_forward", "owner_unconfirmed", "another_bot", "routine", "limit", "api_queue_full"]
WINDOW = ["offline_send", "reconnecting_steer", "slow_ack", "lost_answer"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", default="")
    parser.add_argument("--mac", action="store_true")
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--only", default="")
    parser.add_argument("--look", default="light")
    parser.add_argument("--tag", default="")
    args = parser.parse_args()
    r = MacRun(args) if args.mac else Run(args)
    if args.mac:
        r.save_data()
    else:
        subprocess.run(["xcrun", "simctl", "ui", args.udid, "appearance", args.look])
    sets = {"lane": LANE, "window": WINDOW}
    names = [m for n in args.only.split(",") if n for m in sets.get(n, [n])] or list(SCENARIOS)
    r.start_mock()
    try:
        for name in names:
            # A fresh app and mock for each: nothing carried from one cell to the next.
            r.reset_app()
            r.restart_mock()
            try:
                if name in SHOTS:
                    SCENARIOS[name](r, args.tag)
                else:
                    SCENARIOS[name](r)
            except Exception as error:  # a scenario that breaks is recorded, the rest run
                print(f"ERROR {name}: {error!r}", flush=True)
                r.results.append({"scenario": name, "error": repr(error), "pass": False})
            r.write()
    finally:
        r.terminate()
        r.stop_mock()
        if args.mac:
            r.restore_data()
        r.write()


if __name__ == "__main__":
    main()
