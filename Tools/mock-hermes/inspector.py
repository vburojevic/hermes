"""The Inspector (`docs/inspector.md`): what a chat shows beside it, for the combined mock.

- Files: `/api/fs/list`, `read-text`, `write-text`, `download`, `git-root`, `default-cwd` over an
  in-memory project, "hermes-site" (`/Users/studio/Code/hermes-site`, project "Hermes Site").
- Git: `/api/git/status`, `/api/git/review/{list,diff,rev-parse,stage,unstage,commit,push,create-pr,
  ship-info,commit-context}`, `/api/git/gh-auth`, against that project's committed copy.
- `llm.oneshot` (template `commit_message`) drafts a fixed message; `preview.restart` starts the dev
  server and reports `preview.restart.complete`.
- The Bot Screen: `display.status`, `display.observe` (a single-use ticket), `display.lease.acquire` /
  `release` (broadcast as `display.lease`), and `WS /api/display/ws?display_ticket=` speaking RFB 3.8
  with a drawn desktop. Pointer input from the lease holder leaves dots.
- A dev server on `127.0.0.1:5173` (`--dev-port`) serving the beta sign-up page.

Scripted chat turns (on top of chats.py) by message content:
  "sign-up" or "beta"  -> writes the page, starts `npm run dev`, opens it in the Preview
                          (`preview.open`), then drives it with `preview.act` (elements, type, click)
                          and reads it back with `preview.read`
  "pricing"            -> an HTML artifact; asking again adds a version
  "terminal"           -> reads the Terminal (`terminal.read`)

Mock-only:
  POST /api/mock/inspector/screen {action: evict|stop|start}   4000 control taken, 4001 desktop gone
  POST /api/mock/inspector/gh {authenticated: bool, available: bool}
  POST /api/mock/inspector/touch {path, text}                  a change on the "gateway" (conflicts)
  POST /api/mock/inspector/dev {running: bool}                 stop or start the dev server
  POST /api/mock/inspector/pace {seconds}                      wait between Hermes's actions in the Preview
"""

import base64
import difflib
import hashlib
import json
import re
import secrets
import struct
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

B = None   # backend.py's globals
G = None   # server.py (regular chats)
C = None   # chats.py
P = None   # projects.py
LOCK = threading.RLock()
HOME = "/Users/studio"
ROOT = f"{HOME}/Code/hermes-site"
BRANCH = "feature/beta-page"
PROJECT_ID = "p_5e17ab90"

BETA_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hermes · Beta</title>
<style>
  body { margin: 0; font-family: -apple-system, system-ui, sans-serif; color: #111; background: #fff; }
  nav { display: flex; align-items: center; gap: 10px; padding: 18px 24px; }
  nav .logo { width: 22px; height: 22px; border-radius: 6px; background: #8b5cf6; }
  nav b { flex: 1; } nav a { color: #555; font-size: 12px; margin-left: 14px; text-decoration: none; }
  main { padding: 18px 24px; }
  .tag { color: #8b5cf6; font-size: 10px; font-weight: 700; letter-spacing: .02em; }
  h1 { font-size: 34px; line-height: 1.12; margin: 10px 0 12px; letter-spacing: -0.02em; }
  p { color: #333; font-size: 13px; }
  form { display: flex; gap: 6px; margin: 18px 0; }
  input { flex: 1; padding: 11px 12px; border: 1px solid #ccc; border-radius: 10px; font-size: 13px; }
  button { padding: 0 16px; border: 0; border-radius: 10px; background: #8b5cf6; color: #fff; font-weight: 700; font-size: 13px; }
  .hero { height: 190px; border-radius: 18px; background: linear-gradient(120deg, #8b5cf6, #2f8cf6); }
  .error { color: #d70015; font-size: 12px; min-height: 16px; }
  .thanks { font-size: 15px; font-weight: 600; padding: 14px 0; }
</style></head>
<body>
<nav><span class="logo"></span><b>Hermes</b><a href="#">Features</a><a href="#">Pricing</a><a href="#"><b>Beta</b></a></nav>
<main>
  <div class="tag">PUBLIC BETA · iOS 27</div>
  <h1>Your agent,<br>in your pocket.</h1>
  <p>Chat with Hermes, approve commands and run your Bots from your iPhone.</p>
  <form id="join" onsubmit="event.preventDefault(); join();">
    <input id="email" name="email" type="email" placeholder="you@example.com" aria-label="Email">
    <button id="join-button" type="submit">Join the beta</button>
  </form>
  <div class="error" id="error"></div>
  <div class="hero"></div>
</main>
<script>
function join() {
  var email = document.getElementById('email').value;
  if (email.indexOf('@') < 0) { document.getElementById('error').textContent = 'Enter an email address with an @.'; return; }
  document.getElementById('join').outerHTML = '<div class="thanks">You\\'re on the list. Check ' + email + ' for the TestFlight link.</div>';
  document.getElementById('error').textContent = '';
}
</script>
</body></html>
"""

HEAD_FILES = {
    "package.json": '{\n  "name": "hermes-site",\n  "version": "0.4.0",\n  "scripts": { "dev": "vite", "build": "vite build" }\n}\n',
    "README.md": "# hermes-site\n\nThe Hermes website. `npm run dev` serves it on :5173.\n",
    "src/pages/Home.tsx": "export default function Home() {\n  return <Hero tag=\"Hermes\" />\n}\n",
    "src/pages/Beta.tsx": "export default function Beta() {\n  return <ComingSoon />\n}\n",
    "src/components/Hero.tsx": "export function Hero({ tag }: { tag: string }) {\n  return <section className=\"hero\">{tag}</section>\n}\n",
    "src/api/beta.ts": "export async function joinBeta(email: string) {\n  return fetch('/api/beta', { method: 'POST', body: email })\n}\n",
    "package-lock.json": '{\n  "name": "hermes-site",\n  "lockfileVersion": 3\n}\n',
    "public/beta.html": BETA_PAGE,
}

WORK_FILES = dict(HEAD_FILES)
WORK_FILES.update({
    "src/pages/Beta.tsx": "export default function Beta() {\n  return (\n    <Hero tag=\"Public beta\" />\n    <BetaForm />\n  )\n}\n",
    "src/components/BetaForm.tsx": "import { useState } from 'react'\n\nexport function BetaForm() {\n  const [email, setEmail] = useState('')\n  const [sent, setSent] = useState(false)\n\n  async function join() {\n    if (!email.includes('@')) return\n    await fetch('/api/beta', { method: 'POST' })\n    setSent(true)\n  }\n\n  // Success replaces the form\n  if (sent) return <Thanks />\n  return <form onSubmit={join}>…</form>\n}\n",
    "src/api/beta.ts": "export async function joinBeta(email: string) {\n  if (!email.includes('@')) throw new Error('invalid email')\n  return fetch('/api/beta', { method: 'POST', body: JSON.stringify({ email }) })\n}\n",
    "package-lock.json": '{\n  "name": "hermes-site",\n  "lockfileVersion": 3,\n  "packages": {}\n}\n',
})

STATE = {
    "head": dict(HEAD_FILES),     # committed copy (relative path -> text)
    "work": dict(WORK_FILES),     # working tree
    "staged": {"src/pages/Beta.tsx", "src/components/BetaForm.tsx", "src/api/beta.ts"},
    "commits": [("4be1c9a", "Add the hero"), ("9f02d17", "Home page copy"), ("1c3e88b", "Set up Vite")],
    "pushed": False,
    "pr": None,
    "gh": {"available": True, "authenticated": True},
    "artifact_versions": {},      # stored session -> versions sent
    "pace": 0.0,                  # seconds between drive_preview calls
}

PROCESSES = {}  # process id -> {command, cwd, pid, started, running, exit_code, exited_at, output}


def install(backend_globals, gateway_module, chats_module, projects_module, dev_port=5173):
    global B, G, C, P
    B, G, C, P = backend_globals, gateway_module, chats_module, projects_module
    P.REPOS[ROOT] = BRANCH
    P.add_project(PROJECT_ID, "Hermes Site", [ROOT], "globe", "violet", time.time() - 20 * 86400)
    seed_chat()
    routes = B["HTTP_ROUTES"]
    raw = B["RAW_ROUTES"]
    routes[("GET", "/api/fs/list")] = fs_list
    routes[("GET", "/api/fs/read-text")] = fs_read_text
    routes[("POST", "/api/fs/write-text")] = fs_write_text
    routes[("GET", "/api/fs/git-root")] = fs_git_root
    routes[("GET", "/api/fs/default-cwd")] = lambda q, b: (200, {"cwd": ROOT})
    raw[("GET", "/api/fs/download")] = fs_download
    routes[("GET", "/api/git/status")] = git_status
    routes[("GET", "/api/git/review/list")] = review_list
    routes[("GET", "/api/git/review/diff")] = review_diff
    routes[("GET", "/api/git/review/rev-parse")] = lambda q, b: (200, {"sha": head_sha()})
    routes[("POST", "/api/git/review/stage")] = lambda q, b: stage(b, True)
    routes[("POST", "/api/git/review/unstage")] = lambda q, b: stage(b, False)
    routes[("POST", "/api/git/review/commit")] = commit
    routes[("POST", "/api/git/review/push")] = push
    routes[("POST", "/api/git/review/create-pr")] = create_pr
    routes[("GET", "/api/git/review/ship-info")] = ship_info
    routes[("GET", "/api/git/review/commit-context")] = commit_context
    routes[("GET", "/api/git/gh-auth")] = lambda q, b: (200, dict(STATE["gh"]))
    routes[("POST", "/api/mock/inspector/screen")] = mock_screen
    routes[("POST", "/api/mock/inspector/gh")] = mock_gh
    routes[("POST", "/api/mock/inspector/touch")] = mock_touch
    routes[("POST", "/api/mock/inspector/dev")] = mock_dev
    routes[("POST", "/api/mock/inspector/pace")] = lambda q, b: (200, {"pace": STATE.update(pace=float(b.get("seconds") or 0)) or STATE["pace"]})
    B["WS_ROUTES"]["/api/display/ws"] = display_socket
    methods = B["METHODS"]
    methods["llm.oneshot"] = llm_oneshot
    methods["preview.restart"] = preview_restart
    methods["display.status"] = lambda params: display_snapshot()
    methods["display.observe"] = display_observe
    methods["display.lease.acquire"] = lease_acquire
    methods["display.lease.release"] = lease_release
    methods["process.list"] = process_list
    methods["process.kill"] = process_kill
    DEV["port"] = dev_port
    start_dev_server()
    original = C.run_chat_turn

    def run_chat_turn(sid, text):
        lower = text.lower()
        if "sign-up" in lower or "sign up" in lower or "beta" in lower:
            return run_preview_turn(sid, text)
        if "pricing" in lower:
            return run_artifact_turn(sid, text)
        if "terminal" in lower:
            return run_terminal_turn(sid, text)
        return original(sid, text)

    C.run_chat_turn = run_chat_turn


# ---------------------------------------------------------------- the seeded chat


def seed_chat():
    """"Pricing card" in Hermes Site: two versions of an HTML artifact, and a page Hermes opened."""
    stored = "20261013_141500_site01"
    now = time.time()
    with G.LOCK:
        G.session_row(stored, "Pricing card", "desktop", now - 3 * 3600, now - 2 * 3600, "Design a pricing card")
        G.add_message(stored, "user", "Design a pricing card for Free and Pro. Make Pro stand out, but keep it calm.", timestamp=now - 3 * 3600)
        G.add_message(stored, "assistant", "Here's version 1:\n\n```html\n" + pricing_html(1) + "\n```\n\nTell me what to change.", timestamp=now - 3 * 3600 + 30)
        G.add_message(stored, "user", "Make Pro ink with a violet button.", timestamp=now - 2 * 3600 - 60)
        G.add_message(stored, "assistant", "Here's version 2: Pro in ink with the violet button, Free kept quiet.\n\n```html\n" + pricing_html(2) + "\n```", timestamp=now - 2 * 3600)
        P.place(G.SESSIONS[stored], ROOT, BRANCH)
    STATE["artifact_versions"][stored] = 2


def pricing_html(version):
    price = {1: "$8", 2: "$8", 3: "$9"}.get(version, f"${6 + version}")
    pro = "#111113" if version >= 2 else "#ffffff"
    pro_text = "#ffffff" if version >= 2 else "#111111"
    return f"""<!doctype html>
<html><head><title>Pricing card</title>
<style>
  body {{ margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; gap: 16px;
         background: #f0f0f2; font-family: -apple-system, system-ui, sans-serif; }}
  .card {{ width: 220px; padding: 20px; border-radius: 18px; background: #fff; }}
  .pro {{ background: {pro}; color: {pro_text}; }}
  h2 {{ font-size: 12px; margin: 0 0 8px; }} .price {{ font-size: 34px; font-weight: 800; }}
  p {{ font-size: 11px; opacity: .8; }}
  a {{ display: block; text-align: center; padding: 10px; border-radius: 10px; background: #333; color: #fff;
       text-decoration: none; font-size: 12px; font-weight: 700; }}
  .pro a {{ background: #8b5cf6; }}
</style></head>
<body>
  <div class="card"><h2>Free</h2><div class="price">$0</div><p>Chat, approvals and one gateway.</p><a href="#">Get started</a></div>
  <div class="card pro"><h2>Pro</h2><div class="price">{price}</div><p>Bots, the Board, push and every gateway.</p><a href="#">Start Pro</a></div>
</body></html>"""


# ---------------------------------------------------------------- files


def rel(path):
    path = (path or "").rstrip("/")
    if path == ROOT:
        return ""
    if path.startswith(ROOT + "/"):
        return path[len(ROOT) + 1:]
    return None


def language_of(path):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return {"ts": "typescript", "tsx": "tsx", "js": "javascript", "json": "json", "md": "markdown",
            "html": "html", "css": "css", "py": "python", "swift": "swift"}.get(ext, "text")


def mime_of(path):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return {"html": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json",
            "md": "text/markdown", "ts": "text/typescript", "tsx": "text/typescript", "svg": "image/svg+xml",
            "png": "image/png"}.get(ext, "text/plain")


def q(query, name, default=""):
    return (query.get(name) or [default])[0]


def fs_list(query, body):
    base = rel(q(query, "path"))
    if base is None:
        return 200, {"entries": [], "error": "Not a folder Hermes can read."}
    prefix = base + "/" if base else ""
    folders, files = set(), set()
    with LOCK:
        for path in STATE["work"]:
            if not path.startswith(prefix):
                continue
            rest = path[len(prefix):]
            if "/" in rest:
                folders.add(rest.split("/", 1)[0])
            else:
                files.add(rest)
    entries = [{"name": n, "path": f"{ROOT}/{prefix}{n}", "isDirectory": True} for n in sorted(folders, key=str.lower)]
    entries += [{"name": n, "path": f"{ROOT}/{prefix}{n}", "isDirectory": False} for n in sorted(files, key=str.lower)]
    return 200, {"entries": entries}


def fs_read_text(query, body):
    path = q(query, "path")
    key = rel(path)
    with LOCK:
        text = STATE["work"].get(key) if key is not None else None
    if text is None:
        return 404, {"detail": "File not found"}
    return 200, {"path": path, "text": text, "language": language_of(path), "mimeType": mime_of(path),
                 "byteSize": len(text.encode()), "truncated": False, "binary": False}


def fs_write_text(query, body):
    path = body.get("path") or ""
    key = rel(path)
    if not key:
        return 400, {"detail": "Path outside the project"}
    parent = key.rsplit("/", 1)[0] if "/" in key else ""
    with LOCK:
        if parent and not any(p.startswith(parent + "/") for p in STATE["work"]):
            return 400, {"detail": f"Folder does not exist: {parent}"}
        STATE["work"][key] = body.get("content") or ""
        STATE["staged"].discard(key)
    return 200, {"ok": True, "path": path}


def fs_download(query):
    key = rel(q(query, "path"))
    with LOCK:
        text = STATE["work"].get(key) if key is not None else None
    if text is None:
        return 404, "application/json", b'{"detail": "File not found"}'
    return 200, mime_of(key), text.encode()


def fs_git_root(query, body):
    return 200, {"root": ROOT if rel(q(query, "path")) is not None else None}


# ---------------------------------------------------------------- git


def head_sha():
    return STATE["commits"][0][0]


def changed():
    """Relative path -> status letter (M, A, D) for the working tree against the committed copy."""
    with LOCK:
        head, work = STATE["head"], STATE["work"]
        out = {}
        for path in sorted(set(head) | set(work)):
            if path not in head:
                out[path] = "A"
            elif path not in work:
                out[path] = "D"
            elif head[path] != work[path]:
                out[path] = "M"
        return out


def counts(path):
    with LOCK:
        a = STATE["head"].get(path, "").splitlines()
        b = STATE["work"].get(path, "").splitlines()
    added = removed = 0
    for line in difflib.unified_diff(a, b, lineterm="", n=0):
        if line.startswith("+") and not line.startswith("+++"):
            added += 1
        elif line.startswith("-") and not line.startswith("---"):
            removed += 1
    return added, removed


def git_status(query, body):
    if rel(q(query, "path")) is None:
        return 200, None
    files = []
    for path, letter in changed().items():
        staged = path in STATE["staged"]
        files.append({"path": path, "staged": staged, "unstaged": not staged, "untracked": letter == "A" and not staged,
                      "conflicted": False})
    return 200, {"branch": BRANCH, "defaultBranch": "main", "ahead": 2 if not STATE["pushed"] else 0, "behind": 0,
                 "staged": sum(f["staged"] for f in files), "unstaged": sum(f["unstaged"] for f in files),
                 "untracked": sum(f["untracked"] for f in files), "conflicted": 0, "changed": len(files),
                 "added": 0, "removed": 0, "files": files}


def review_list(query, body):
    if rel(q(query, "path")) is None:
        return 400, {"detail": "not a git repository"}
    scope = q(query, "scope", "uncommitted")
    base = q(query, "base") or None
    if scope == "lastTurn" and not base:
        return 200, {"files": [], "base": None}
    files = []
    for path, letter in changed().items():
        added, removed = counts(path)
        files.append({"path": path, "added": added, "removed": removed, "status": "?" if letter == "A" and path not in STATE["staged"] else letter,
                      "staged": path in STATE["staged"]})
    return 200, {"files": files, "base": base or ("main" if scope == "branch" else None)}


def review_diff(query, body):
    file = q(query, "file")
    key = file if not file.startswith("/") else rel(file)
    with LOCK:
        a = STATE["head"].get(key, "").splitlines()
        b = STATE["work"].get(key, "").splitlines()
    diff = "\n".join(difflib.unified_diff(a, b, fromfile=f"a/{key}", tofile=f"b/{key}", lineterm=""))
    return 200, {"diff": diff}


def stage(body, on):
    file = body.get("file")
    with LOCK:
        paths = [file] if file else list(changed())
        for path in paths:
            if on:
                STATE["staged"].add(path)
            else:
                STATE["staged"].discard(path)
    return 200, {"ok": True}


def commit(query, body):
    message = (body.get("message") or "").strip()
    with LOCK:
        if not STATE["staged"]:
            return 400, {"detail": "nothing to commit (use \"git add\" to stage files)"}
        if not message:
            return 400, {"detail": "Aborting commit due to empty commit message."}
        for path in STATE["staged"]:
            if path in STATE["work"]:
                STATE["head"][path] = STATE["work"][path]
            else:
                STATE["head"].pop(path, None)
        STATE["staged"] = set()
        sha = hashlib.sha1(f"{message}{time.time()}".encode()).hexdigest()[:7]
        STATE["commits"].insert(0, (sha, message.splitlines()[0]))
        if body.get("push"):
            STATE["pushed"] = True
    return 200, {"ok": True, "sha": sha}


def push(query, body):
    STATE["pushed"] = True
    return 200, {"ok": True}


def create_pr(query, body):
    if not STATE["gh"]["available"]:
        return 400, {"detail": "gh: command not found"}
    if not STATE["gh"]["authenticated"]:
        return 400, {"detail": "gh: To get started with GitHub CLI, please run:  gh auth login"}
    STATE["pushed"] = True
    STATE["pr"] = {"url": "https://github.com/studio/hermes-site/pull/42", "state": "OPEN", "number": 42}
    return 200, {"url": STATE["pr"]["url"]}


def ship_info(query, body):
    ready = STATE["gh"]["available"] and STATE["gh"]["authenticated"]
    return 200, {"ghReady": ready, "pr": STATE["pr"] if ready else None}


def commit_context(query, body):
    with LOCK:
        staged = sorted(STATE["staged"])
    diffs = [review_diff({"file": [p]}, {})[1]["diff"] for p in staged]
    recent = "\n".join(f"{sha} {subject}" for sha, subject in STATE["commits"][:5])
    return 200, {"diff": "\n".join(diffs), "recent": recent}


def llm_oneshot(params):
    if params.get("template") == "commit_message":
        if "Add the beta sign-up page" in str((params.get("variables") or {}).get("avoid") or ""):
            return {"text": "Beta sign-up page with validation\n\nThe form checks the address before posting and thanks people with the TestFlight link."}
        return {"text": "Add the beta sign-up page\n\nForm with email validation, success state and a TestFlight link."}
    return {"text": "Done."}


def mock_gh(query, body):
    for key in ("available", "authenticated"):
        if key in body:
            STATE["gh"][key] = bool(body[key])
    return 200, dict(STATE["gh"])


def mock_touch(query, body):
    key = rel(body.get("path") or "")
    if not key:
        return 400, {"detail": "path"}
    with LOCK:
        STATE["work"][key] = body.get("text") or (STATE["work"].get(key, "") + "// changed on the gateway\n")
    return 200, {"ok": True}


# ---------------------------------------------------------------- processes


def process_entry(pid, p):
    entry = {"session_id": pid, "command": p["command"], "cwd": p["cwd"], "pid": p["pid"],
             "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(p["started"])),
             "uptime_seconds": int(time.time() - p["started"]), "status": "running" if p["running"] else "exited",
             "output_preview": p["output"][-200:], "output_tail": p["output"][-4000:]}
    if not p["running"]:
        entry.update(exit_code=p.get("exit_code", 0), exited_at=p.get("exited_at"), completion_reason="exited")
    return entry


def process_list(params):
    with LOCK:
        rows = [process_entry(pid, p) for pid, p in PROCESSES.items()]
    legacy = [{"session_id": pid, "command": p["command"], "cwd": ROOT, "pid": 40000 + i, "uptime_seconds": int(time.time() - p["started"]),
               "status": "running" if p["running"] else "exited"} for i, (pid, p) in enumerate(C.PROCESSES.items())]
    return {"processes": rows + legacy}


def process_kill(params):
    pid = params.get("process_id") or ""
    with LOCK:
        if pid in PROCESSES:
            PROCESSES[pid].update(running=False, exit_code=-15, exited_at=time.time())
    if pid in C.PROCESSES:
        C.PROCESSES[pid]["running"] = False
    return {"status": "killed", "session_id": pid}


def start_process(sid, command, lines, *, keep=True, exit_code=0, finished_ago=None):
    pid = f"proc_{uuid.uuid4().hex[:6]}"
    with LOCK:
        PROCESSES[pid] = {"command": command, "cwd": ROOT, "pid": 48213 if keep else 48190, "started": time.time() - (finished_ago or 0) - 20,
                          "running": True, "output": ""}

    def run():
        for line in lines:
            with LOCK:
                PROCESSES[pid]["output"] += line
            C.emit(sid, "agent.terminal.output", {"process_id": pid, "chunk": line})
            time.sleep(0.25)
        if not keep:
            with LOCK:
                PROCESSES[pid].update(running=False, exit_code=exit_code, exited_at=time.time() - (finished_ago or 0))
            C.emit(sid, "terminal.close", {"process_id": pid})
            return
        n = 0
        while PROCESSES[pid]["running"] and n < 400:
            time.sleep(4)
            stamp = time.strftime("%H:%M:%S")
            line = f"{stamp} [vite] hmr update /src/components/BetaForm.tsx\n" if n % 3 == 0 else f"{stamp} GET /beta 200 in {3 + n % 5} ms\n"
            with LOCK:
                PROCESSES[pid]["output"] += line
            C.emit(sid, "agent.terminal.output", {"process_id": pid, "chunk": line})
            n += 1
        C.emit(sid, "terminal.close", {"process_id": pid})

    threading.Thread(target=run, daemon=True).start()
    return pid


# ---------------------------------------------------------------- dev server (localhost:5173)

DEV = {"port": 5173, "server": None}


class DevHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        page = STATE["work"].get("public/beta.html", BETA_PAGE).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(page)


def start_dev_server():
    if DEV["server"] is not None:
        return True
    try:
        server = ThreadingHTTPServer(("127.0.0.1", DEV["port"]), DevHandler)
    except OSError as error:
        print(f"[mock-inspector] dev server :{DEV['port']} not started: {error}", flush=True)
        return False
    server.daemon_threads = True
    DEV["server"] = server
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return True


def stop_dev_server():
    server = DEV["server"]
    DEV["server"] = None
    if server is not None:
        server.shutdown()
        server.server_close()


def mock_dev(query, body):
    if body.get("running", True):
        return 200, {"running": start_dev_server()}
    stop_dev_server()
    return 200, {"running": False}


def preview_restart(params):
    sid = params.get("session_id") or ""
    task = f"preview_{uuid.uuid4().hex[:6]}"

    def run():
        C.emit(sid, "preview.restart.progress", {"task_id": task, "text": "Restarting the dev server on 0.0.0.0"})
        time.sleep(1.5)
        start_dev_server()
        C.emit(sid, "preview.restart.complete", {"task_id": task, "text": f"The server listens on 0.0.0.0:{DEV['port']} now."})

    threading.Thread(target=run, daemon=True).start()
    return {"task_id": task, "status": "started"}


# ---------------------------------------------------------------- scripted turns


def act(sid, stored, action, **fields):
    """One `drive_preview` call: a tool step, the `preview.act` request, its answer."""
    args = {"action": action, **fields}
    call = f"call_{uuid.uuid4().hex[:8]}"
    G.add_message(stored, "assistant", "", finish_reason="tool_calls",
                  tool_calls=[{"id": call, "type": "function", "function": {"name": "drive_preview", "arguments": json.dumps(args)}}])
    C.emit(sid, "tool.start", {"tool_id": call, "name": "drive_preview", "context": f"{action} {fields.get('ref') or ''}".strip(), "args": args})
    if STATE["pace"]:
        time.sleep(STATE["pace"])
    print(f"[mock-inspector] {time.strftime('%H:%M:%S')} preview.act {action} {fields.get('ref') or ''}", flush=True)
    result = B["server_request"](sid, "preview.act", args, timeout=45)
    print(f"[mock-inspector] {time.strftime('%H:%M:%S')} answered {action}: {'yes' if result else 'declined'}", flush=True)
    value = None
    if isinstance(result, dict) and result.get("value"):
        try:
            value = json.loads(result["value"])
        except ValueError:
            value = None
    text = json.dumps(value) if value else "No GUI window answered with a page."
    G.add_message(stored, "tool", text, tool_call_id=call, tool_name="drive_preview")
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "drive_preview", "args": args, "duration_s": 0.4, "result": text[:400], "summary": None})
    return value


def run_preview_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.title_later(sid, stored, text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    plan = [("1", "Write the beta page"), ("2", "Start the dev server"), ("3", "Test the sign-up"), ("4", "Try a bad address"), ("5", "Report back")]

    def todos(current):
        rows = [{"id": i, "content": c, "status": "completed" if n < current else ("in_progress" if n == current else "pending")}
                for n, (i, c) in enumerate(plan)]
        C.emit(sid, "todo.updated", {"todos": rows, "revision": current})

    todos(0)
    diff = "\n".join(difflib.unified_diff(HEAD_FILES["src/pages/Beta.tsx"].splitlines(), WORK_FILES["src/pages/Beta.tsx"].splitlines(),
                                          fromfile="a/src/pages/Beta.tsx", tofile="b/src/pages/Beta.tsx", lineterm=""))
    C.tool(sid, stored, "write_file", {"path": f"{ROOT}/src/pages/Beta.tsx"}, 0.8, context="src/pages/Beta.tsx",
           result=json.dumps({"bytes_written": 120}), extra={"inline_diff": diff})
    todos(1)
    start_dev_server()
    start_process(sid, "npm run dev", ["> hermes-site@0.4.0 dev\n", "> vite\n", "\n", "  VITE v6.2.0  ready in 412 ms\n",
                                        f"  ➜  Local:   http://localhost:{DEV['port']}/\n", "  ➜  Network: use --host to expose\n", "\n"])
    C.tool(sid, stored, "terminal", {"command": "npm run dev", "background": True}, 0.6, context="npm run dev",
           result=json.dumps({"output": "started", "exit_code": None}))
    url = f"http://localhost:{DEV['port']}/beta"
    call = f"call_{uuid.uuid4().hex[:8]}"
    args = {"action": "open", "url": url, "label": "Beta sign-up page"}
    G.add_message(stored, "assistant", "", finish_reason="tool_calls",
                  tool_calls=[{"id": call, "type": "function", "function": {"name": "desktop_preview", "arguments": json.dumps(args)}}])
    C.emit(sid, "tool.start", {"tool_id": call, "name": "desktop_preview", "context": url, "args": args})
    C.emit(sid, "preview.open", {"url": url, "label": "Beta sign-up page"})
    G.add_message(stored, "tool", json.dumps({"success": True, "opened": url}), tool_call_id=call, tool_name="desktop_preview")
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "desktop_preview", "args": args, "duration_s": 0.1,
                                  "result": json.dumps({"success": True, "opened": url}), "summary": None})
    interim = "The page is up on the dev server. I opened it beside the chat and I'm going through the sign-up as a visitor."
    C.stream(sid, interim)
    C.emit(sid, "message.interim", {"text": interim, "already_streamed": True})
    todos(2)
    time.sleep(1.5)
    looked = act(sid, stored, "elements")
    if not looked:
        answer = "The Preview isn't on screen in the app, so I couldn't try the form. Open the Inspector and ask me again."
        C.stream(sid, "\n\n" + answer)
        return C.finish(sid, stored, interim + "\n\n" + answer)
    elements = looked.get("elements") or []
    email = next((e["ref"] for e in elements if e["ref"].startswith("inp")), None)
    button = next((e["ref"] for e in elements if e["ref"].startswith("btn") and "join" in e["ref"]), None)
    notes = []
    if email and button:
        todos(3)
        act(sid, stored, "type", ref=email, text="not-an-address")
        bad = act(sid, stored, "click", ref=button) or {}
        notes.append("an address without an @ is refused with a message" if bad.get("success") else "the empty-address click didn't land")
        act(sid, stored, "type", ref=email, text="ada@example.com")
        act(sid, stored, "click", ref=button)
    read = B["server_request"](sid, "preview.read", {"start": 0, "count": 2000}, timeout=30) or {}
    page = {}
    try:
        page = json.loads(read.get("value") or "{}")
    except ValueError:
        pass
    thanked = "on the list" in (page.get("text") or "")
    todos(5)
    answer = ("Done. " + ("A real address goes through and the page thanks you with the TestFlight link" if thanked else "The form didn't confirm the sign-up")
              + (f"; {notes[0]}." if notes else ".") + f" I read the page back: “{(page.get('title') or 'the page')}”.")
    C.stream(sid, "\n\n" + answer)
    C.finish(sid, stored, interim + "\n\n" + answer)


def run_artifact_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.title_later(sid, stored, text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    version = STATE["artifact_versions"].get(stored, 0) + 1
    STATE["artifact_versions"][stored] = version
    time.sleep(0.5)
    lead = f"Here's version {version}: Pro in ink with the violet button, Free kept quiet." if version > 1 else "Here's a first pass at the pricing card."
    answer = lead + "\n\n```html\n" + pricing_html(version) + "\n```\n\nEarlier versions are in the Inspector if you want to compare."
    C.stream(sid, answer, chunk=60, delay=0.01)
    C.finish(sid, stored, answer)


def run_terminal_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    call = f"call_{uuid.uuid4().hex[:8]}"
    C.emit(sid, "tool.start", {"tool_id": call, "name": "read_terminal", "context": "", "args": {}})
    result = B["server_request"](sid, "terminal.read", {}, timeout=30) or {}
    value = {}
    try:
        value = json.loads(result.get("value") or "{}")
    except ValueError:
        pass
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "read_terminal", "args": {}, "duration_s": 0.2, "result": "read", "summary": None})
    lines = [l for l in (value.get("text") or "").splitlines() if l.strip()]
    answer = (f"The terminal shows {value.get('total_lines', 0)} lines; the last one is `{lines[-1]}`." if lines
              else "The Terminal isn't on screen in the app, so I couldn't read it.")
    C.stream(sid, answer)
    C.finish(sid, stored, answer)


# ---------------------------------------------------------------- the Bot Screen

DISPLAY = {"running": True, "lease": {"holder": "agent", "viewer_id": None, "reason": "", "epoch": 0, "since": time.time()},
           "tickets": {}, "viewers": set(), "sockets": [], "dots": []}
WIDTH, HEIGHT = 1280, 800


def lease_view():
    lease = DISPLAY["lease"]
    vid = lease.get("viewer_id")
    return {"holder": lease["holder"], "viewer_id": None, "reason": lease.get("reason") or "", "epoch": lease["epoch"],
            "since": lease["since"], "viewer_hash": hashlib.sha256(vid.encode()).hexdigest()[:12] if vid else None}


def display_snapshot():
    return {"profile": "default", "supported": True, "installed": True, "missing": [], "running": DISPLAY["running"],
            "pid": 51234 if DISPLAY["running"] else None, "display": ":1", "socket": "/tmp/.X11-unix/X1",
            "geometry": f"{WIDTH}x{HEIGHT}", "install_command": None, "browser": "chromium", "blocker": None,
            "placement": "gateway", "lease": lease_view(), "profile_key": f"{HOME}/.hermes"}


def display_observe(params):
    if not DISPLAY["running"]:
        raise B["RPCError"](5300, "this profile's Bot Desktop is not running; call display.start first")
    viewer = params.get("viewer_id") or f"viewer_{secrets.token_hex(6)}"
    DISPLAY["viewers"].add(viewer)
    ticket = secrets.token_urlsafe(18)
    DISPLAY["tickets"][ticket] = (time.time() + 30, viewer)
    return {"ticket": ticket, "path": "/api/display/ws", "viewer_id": viewer, **display_snapshot()}


def broadcast_lease():
    frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": "display.lease", "session_id": "",
                                                             "payload": {"profile_key": f"{HOME}/.hermes", "lease": lease_view()}}}
    with B["LOCK"]:
        peers = list(B["CLIENTS"])
    for peer in peers:
        try:
            peer.send(frame)
        except OSError:
            pass


def lease_acquire(params):
    viewer = params.get("viewer_id") or ""
    if viewer not in DISPLAY["viewers"]:
        raise B["RPCError"](5300, "viewer_id was not minted for this connection; call display.observe first")
    DISPLAY["lease"] = {"holder": "human", "viewer_id": viewer, "reason": params.get("reason") or "", "epoch": DISPLAY["lease"]["epoch"] + 1, "since": time.time()}
    broadcast_lease()
    return {"lease": lease_view()}


def lease_release(params):
    DISPLAY["lease"] = {"holder": "agent", "viewer_id": None, "reason": "", "epoch": DISPLAY["lease"]["epoch"] + 1, "since": time.time()}
    DISPLAY["dots"] = []
    broadcast_lease()
    return {"lease": lease_view()}


def mock_screen(query, body):
    action = body.get("action")
    if action == "stop":
        DISPLAY["running"] = False
        close_sockets(4001, "Bot Desktop is not running")
    elif action == "start":
        DISPLAY["running"] = True
    elif action == "evict":
        DISPLAY["lease"] = {"holder": "human", "viewer_id": "viewer_someone_else", "reason": "", "epoch": DISPLAY["lease"]["epoch"] + 1, "since": time.time()}
        broadcast_lease()
        close_sockets(4000, "control-taken")
    return 200, display_snapshot()


def close_sockets(code, reason):
    for sock in list(DISPLAY["sockets"]):
        sock.close(code, reason)
    DISPLAY["sockets"] = []


class BinaryPeer:
    """A WebSocket for raw RFB: binary frames both ways."""

    def __init__(self, handler):
        self.handler = handler
        self.lock = threading.Lock()
        self.alive = True
        self.buffer = b""

    def send(self, data):
        header = bytearray([0x82])
        if len(data) < 126:
            header.append(len(data))
        elif len(data) < 65536:
            header += bytes([126]) + struct.pack(">H", len(data))
        else:
            header += bytes([127]) + struct.pack(">Q", len(data))
        with self.lock:
            if not self.alive:
                return
            try:
                self.handler.wfile.write(bytes(header) + data)
                self.handler.wfile.flush()
            except OSError:
                self.alive = False

    def close(self, code, reason=""):
        payload = struct.pack(">H", code) + reason.encode()[:120]
        with self.lock:
            try:
                self.handler.wfile.write(bytes([0x88, len(payload)]) + payload)
                self.handler.wfile.flush()
            except OSError:
                pass
            self.alive = False

    def read(self, count):
        while len(self.buffer) < count:
            frame = self.frame()
            if frame is None:
                return None
            self.buffer += frame
        out, self.buffer = self.buffer[:count], self.buffer[count:]
        return out

    def frame(self):
        while True:
            head = self.handler.rfile.read(2)
            if len(head) < 2:
                return None
            opcode = head[0] & 0x0F
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.handler.rfile.read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.handler.rfile.read(8))[0]
            mask = self.handler.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
            payload = bytearray(self.handler.rfile.read(length))
            for i in range(len(payload)):
                payload[i] ^= mask[i % 4]
            if opcode == 0x8:
                return None
            if opcode in (0x9, 0xA):
                continue
            return bytes(payload)


def draw_desktop():
    """BGRA pixels: a dark desktop, a browser window with a sign-in form, and the person's dots."""
    pixels = bytearray(b"\x2a\x26\x24\xff" * (WIDTH * HEIGHT))

    def rect(x, y, w, h, bgra):
        row = bytes(bgra) * w
        for yy in range(max(0, y), min(HEIGHT, y + h)):
            start = (yy * WIDTH + max(0, x)) * 4
            pixels[start:start + len(row)] = row[: max(0, (min(WIDTH, x + w) - max(0, x))) * 4]

    rect(0, 0, WIDTH, 28, (0x18, 0x16, 0x15, 0xFF))
    rect(110, 70, 1060, 650, (0xFF, 0xFF, 0xFF, 0xFF))
    rect(110, 70, 1060, 36, (0xD8, 0xD4, 0xD2, 0xFF))
    rect(170, 150, 380, 24, (0x22, 0x22, 0x22, 0xFF))
    for top in (200, 252):
        rect(170, top, 420, 40, (0x9A, 0x96, 0x94, 0xFF))
        rect(172, top + 2, 416, 36, (0xFF, 0xFF, 0xFF, 0xFF))
    rect(170, 312, 160, 40, (0xF6, 0x8C, 0x2F, 0xFF))
    for x, y in DISPLAY["dots"][-40:]:
        rect(x - 4, y - 4, 8, 8, (0x2D, 0x15, 0xD7, 0xFF))
    return bytes(pixels)


def frame_update(x, y, w, h, full):
    """One FramebufferUpdate with a raw rectangle cut from `full`."""
    out = bytearray(struct.pack(">BxH", 0, 1))
    out += struct.pack(">HHHHi", x, y, w, h, 0)
    for row in range(y, y + h):
        start = (row * WIDTH + x) * 4
        out += full[start:start + w * 4]
    return bytes(out)


def display_socket(handler, query):
    key = handler.headers.get("Sec-WebSocket-Key")
    if not key:
        return handler.send_json(400, {"detail": "Expected a WebSocket upgrade"})
    accept = base64.b64encode(hashlib.sha1((key + B["WS_GUID"]).encode()).digest()).decode()
    handler.wfile.write((f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    handler.wfile.flush()
    handler.close_connection = True
    peer = BinaryPeer(handler)
    ticket = (query.get("display_ticket") or [""])[0]
    entry = DISPLAY["tickets"].pop(ticket, None)
    if entry is None or entry[0] < time.time():
        return peer.close(4401, "display ticket missing, expired or used")
    if not DISPLAY["running"]:
        return peer.close(4001, "Bot Desktop is not running")
    viewer = entry[1]
    DISPLAY["sockets"].append(peer)
    peer.send(b"RFB 003.008\n")
    if peer.read(12) is None:
        return
    peer.send(bytes([1, 1]))          # one security type: None
    if peer.read(1) is None:
        return
    peer.send(struct.pack(">I", 0))   # OK
    if peer.read(1) is None:           # ClientInit
        return
    name = b"hermes-bot"
    pixel_format = bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    peer.send(struct.pack(">HH", WIDTH, HEIGHT) + pixel_format + struct.pack(">I", len(name)) + name)
    sent_full = False
    while peer.alive:
        kind = peer.read(1)
        if kind is None:
            break
        kind = kind[0]
        if kind == 0:
            peer.read(19)
        elif kind == 2:
            count = struct.unpack(">xH", peer.read(3))[0]
            peer.read(4 * count)
        elif kind == 3:
            incremental, x, y, w, h = struct.unpack(">BHHHH", peer.read(9))
            if not incremental or not sent_full:
                peer.send(frame_update(0, 0, WIDTH, HEIGHT, draw_desktop()))
                sent_full = True
            else:
                time.sleep(0.5)
                blink = int(time.time() * 2) % 2
                full = draw_desktop()
                if blink:
                    full = bytearray(full)
                    for row in range(214, 230):
                        start = (row * WIDTH + 182) * 4
                        full[start:start + 8] = b"\x11\x11\x11\xff" * 2
                    full = bytes(full)
                peer.send(frame_update(170, 200, 440, 160, full))
        elif kind == 4:
            peer.read(7)
        elif kind == 5:
            buttons, x, y = struct.unpack(">BHH", peer.read(5))
            lease = DISPLAY["lease"]
            if buttons & 1 and lease["holder"] == "human" and lease.get("viewer_id") == viewer:
                DISPLAY["dots"].append((x, y))
        elif kind == 6:
            length = struct.unpack(">xxxI", peer.read(7))[0]
            peer.read(length)
        else:
            break
    if peer in DISPLAY["sockets"]:
        DISPLAY["sockets"].remove(peer)
