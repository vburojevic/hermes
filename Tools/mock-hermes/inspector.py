"""The Inspector (`docs/inspector.md`): what a chat shows beside it, for the combined mock.

- Files: `/api/fs/list`, `read-text`, `write-text`, `download`, `git-root`, `default-cwd` over an
  in-memory project, "hermes-site" (`/Users/studio/Code/hermes-site`, project "Hermes Site").
  `download` also serves the project's pictures (`PICTURES`, PNGs drawn here, no real image) and
  media (`MEDIA`: a short real clip, a 60 MB picture, a "video" that isn't one and a recording
  under `pairing/`), which `/api/files/stream` (audio.py) streams too; 404
  `File not found` for a missing file and 403 `Path is outside the managed read boundary` outside
  the project, as a locked deployment answers.
- Git: `/api/git/status`, `/api/git/review/{list,diff,rev-parse,stage,unstage,commit,push,create-pr,
  ship-info,commit-context}`, `/api/git/gh-auth`, against that project's committed copy.
- `llm.oneshot` (template `commit_message`) drafts a fixed message; `preview.restart` starts the dev
  server and reports `preview.restart.complete`.
- The Bot Screen: `display.status`, `display.start`, `display.observe` (a single-use ticket),
  `display.lease.acquire` / `release` (broadcast as `display.lease`), and `WS
  /api/display/ws?display_ticket=` speaking RFB 3.8 with a drawn desktop. Pointer input from the
  lease holder leaves dots. Keys from the lease holder are logged and typed into the sign-in form's
  field that was clicked last (BackSpace deletes, Tab moves on), drawn as a block per character.
  Starting and stopping broadcast `display.status`, as Hermes's watcher does. It runs from the start, so a chat with no Inspector tabs has a Screen to open.
- A dev server on `127.0.0.1:5173` (`--dev-port`) serving the beta sign-up page.

Scripted chat turns (on top of chats.py) by message content:
  "preview <address>"  -> opens that address in the Preview (`preview.open`), nothing more
  "sign-up" or "beta"  -> writes the page, starts `npm run dev`, opens it in the Preview
                          (`preview.open`), then drives it with `preview.act` (elements, type, click)
                          and reads it back with `preview.read`
  "pricing"            -> an HTML artifact; asking again adds a version
  "terminal"           -> reads the Terminal (`terminal.read`)
  "where is it"        -> names files the way Hermes does: a path in inline code and a link to a
                          file, which open in the Inspector's File tab (`GatewayFileLink`)
  "rewrite"            -> writes a brief, reads it back and writes it again with three lines
                          changed: one card folded, the second write's change opened
  "attachments"        -> sends files the way Hermes does, a `MEDIA:<path>` line each
                          (`ATTACHMENTS`, docs/chat.md §3a): two pictures, a video, a PDF, Markdown
                          notes, an HTML page with a relative picture, a zip, a 60 MB picture, one
                          that's gone (404) and one Hermes keeps private (403); a line in a code
                          block stays code. server.py answers the same words without Bot Mode.
  "broken attachments" -> only the ones that don't show: the 60 MB picture, a picture and a PDF
                          that are gone, the private one and a ".mp4" that isn't a video. Both
                          in a Bot Chat too.
  "drawings"           -> a Mermaid flowchart, `$$` and `\[` display math, an SVG fence (with a
                          script and a remote picture that never run or load) and an SVG in the
                          prose, then a diagram Mermaid can't read (`DRAWINGS`, docs/chat.md §3b).
                          server.py and a Bot Chat answer the same.
  "live page"          -> a `::preview` page whose buttons send hidden messages, and a Markdown file
                          (docs/chat.md §3c); "Plan picked on the page: …" is answered
  "office files"       -> a docx, xlsx, pptx and rtf made here, which open in Quick Look, and an odt, ods
                          and odp, which save where it can't draw them (docs/chat.md §3a)
  "video links"        -> links to YouTube, Vimeo, Spotify, SoundCloud, GitHub and Bilibili that show
                          as cards, and links that stay words (docs/chat.md §3d)

Mock-only:
  POST /api/mock/inspector/screen {action: evict|stop|start}   4000 control taken, 4001 desktop gone
                                  {action: uninstall|install}   the host without TigerVNC and Xfce, or with
                                  {action: unsupported|supported} a macOS host (no Screen), or Linux again
  GET  /api/mock/inspector/screen/keys                         the keys the screen received, and its fields
  POST /api/mock/inspector/screen/keys                         clears both
  POST /api/mock/inspector/gh {authenticated: bool, available: bool}
  POST /api/mock/inspector/touch {path, text}                  a change on the "gateway" (conflicts)
  POST /api/mock/inspector/dev {running: bool}                 stop or start the dev server
  POST /api/mock/inspector/pace {seconds}                      wait between Hermes's actions in the Preview
  POST /api/mock/inspector/turn {session, text}                a turn in a chat, as if the person sent it
"""

import base64
import difflib
import hashlib
import json
import pathlib
import re
import secrets
import struct
import threading
import time
import uuid
import zlib
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
    B["PROJECT_MEDIA"] = project_media
    B["MEDIA_SHOTS"] = [(path, alt) for path, alt, _top, _bottom in SHOTS]
    B["SENSITIVE_PATH"] = sensitive
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
    routes[("GET", "/api/mock/inspector/screen/keys")] = lambda q, b: (200, key_log())
    routes[("POST", "/api/mock/inspector/screen/keys")] = clear_keys
    routes[("POST", "/api/mock/inspector/gh")] = mock_gh
    routes[("POST", "/api/mock/inspector/touch")] = mock_touch
    routes[("POST", "/api/mock/inspector/dev")] = mock_dev
    routes[("POST", "/api/mock/inspector/turn")] = mock_turn
    routes[("POST", "/api/mock/inspector/pace")] = lambda q, b: (200, {"pace": STATE.update(pace=float(b.get("seconds") or 0)) or STATE["pace"]})
    B["WS_ROUTES"]["/api/display/ws"] = display_socket
    methods = B["METHODS"]
    methods["llm.oneshot"] = llm_oneshot
    methods["preview.restart"] = preview_restart
    methods["display.status"] = lambda params: display_snapshot()
    methods["display.start"] = display_start
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
        if lower.startswith("preview http://") or lower.startswith("preview https://"):
            return run_open_turn(sid, text)
        if "sign-up" in lower or "sign up" in lower or "beta" in lower:
            return run_preview_turn(sid, text)
        if "pricing" in lower:
            return run_artifact_turn(sid, text)
        if "terminal" in lower:
            return run_terminal_turn(sid, text)
        if "where is it" in lower:
            return run_file_paths_turn(sid, text)
        if "rewrite" in lower:
            return run_rewrite_turn(sid, text)
        if "attachments" in lower:
            return run_attachments_turn(sid, text, ATTACHMENTS_BROKEN if "broken" in lower else ATTACHMENTS)
        if (reply := formats_reply(lower)) is not None:
            return run_attachments_turn(sid, text, reply)
        return original(sid, text)

    C.run_chat_turn = run_chat_turn
    # A Bot Chat sends files the same way.
    original_bot = B["run_turn"]

    def run_bot_turn(sid, text):
        lower = text.lower()
        answer = formats_reply(lower)
        if "attachments" in lower:
            answer = ATTACHMENTS_BROKEN if "broken" in lower else ATTACHMENTS
        if answer is None:
            return original_bot(sid, text)
        stored = B["ensure_row"](sid)
        B["add_message"](stored, "user", text)
        B["emit"](sid, "session.info", {"running": True})
        B["emit"](sid, "message.start", {})
        B["stream"](sid, answer)
        return B["finish"](sid, stored, answer)

    B["run_turn"] = run_bot_turn


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
    # Hermes expands a home path before it checks the read boundary.
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
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
            "png": "image/png", "mp4": "video/mp4", "mov": "video/quicktime", "pdf": "application/pdf",
            "zip": "application/zip"}.get(ext, "text/plain")


def q(query, name, default=""):
    return (query.get(name) or [default])[0]


def fs_list(query, body):
    base = rel(q(query, "path"))
    if base is None:
        return 200, {"entries": [], "error": "Not a folder Hermes can read."}
    prefix = base + "/" if base else ""
    folders, files = set(), set()
    with LOCK:
        for path in list(STATE["work"]) + list(PICTURES) + list(MEDIA):
            if not path.startswith(prefix) or sensitive(path):
                continue   # Hermes leaves sensitive files out of a listing too
            rest = path[len(prefix):]
            if "/" in rest:
                folders.add(rest.split("/", 1)[0])
            else:
                files.add(rest)
    entries = [{"name": n, "path": f"{ROOT}/{prefix}{n}", "isDirectory": True} for n in sorted(folders, key=str.lower)]
    entries += [{"name": n, "path": f"{ROOT}/{prefix}{n}", "isDirectory": False} for n in sorted(files, key=str.lower)]
    return 200, {"entries": entries}


SENSITIVE_NAMES = {"auth.json", "auth.lock", "credentials", "config.yaml", ".anthropic_oauth.json", ".git-credentials"}


def sensitive(path):
    """Hermes' read guard (`_is_sensitive_path` in hermes_cli/web_routers/files.py): `.env` files,
    credential stores, and anything under `mcp-tokens/` or `pairing/`."""
    parts = [p.lower() for p in path.split("/") if p]
    name = parts[-1] if parts else ""
    return (name == ".env" or name.startswith(".env.") or name == ".envrc" or name in SENSITIVE_NAMES
            or any(p in ("mcp-tokens", "pairing") for p in parts))


def fs_read_text(query, body):
    path = q(query, "path")
    if sensitive(path):
        return 403, {"detail": "Access to sensitive files is not allowed"}
    key = rel(path)
    with LOCK:
        text = STATE["work"].get(key) if key is not None else None
    if text is None and (key in MEDIA or key in PICTURES):
        # Hermes reads any file: one that isn't UTF-8 text comes back `binary`.
        data = media_bytes(key) if key in MEDIA else PICTURES[key]
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return 200, {"path": path, "text": "", "language": "text", "mimeType": mime_of(path),
                         "byteSize": len(data), "truncated": False, "binary": True}
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


def png(width, height, top, bottom, boxes):
    """A PNG drawn here: a vertical gradient from `top` to `bottom` (RGB) with white boxes
    (x, y, w, h as fractions), so a widget's picture is a real image without shipping one."""
    rects = [(int(x * width), int(y * height), int((x + w) * width), int((y + h) * height)) for x, y, w, h in boxes]
    rows = bytearray()
    for y in range(height):
        t = y / max(1, height - 1)
        shade = bytes(round(a + (b - a) * t) for a, b in zip(top, bottom))
        row = bytearray(shade * width)
        for x0, y0, x1, y1 in rects:
            if y0 <= y < y1:
                row[x0 * 3:x1 * 3] = b"\xff" * ((x1 - x0) * 3)
        rows += b"\x00" + row

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


# The project's pictures (relative path -> bytes), apart from the text files so Git and the
# File tab stay as they are. `widgets.py` "widget gateway image" names them.
PICTURES = {
    "diagrams/launch-flow.png": png(960, 640, (139, 92, 246), (47, 140, 246),
                                    [(0.08, 0.38, 0.22, 0.24), (0.39, 0.38, 0.22, 0.24), (0.70, 0.38, 0.22, 0.24),
                                     (0.30, 0.48, 0.09, 0.04), (0.61, 0.48, 0.09, 0.04)]),
    "diagrams/hinge-step.png": png(800, 500, (16, 185, 129), (13, 148, 136),
                                   [(0.15, 0.20, 0.70, 0.12), (0.15, 0.44, 0.48, 0.12), (0.15, 0.68, 0.60, 0.12)]),
    "diagrams/orbit-card.png": png(600, 600, (249, 115, 22), (236, 72, 153),
                                   [(0.40, 0.40, 0.20, 0.20), (0.12, 0.12, 0.10, 0.10), (0.78, 0.70, 0.10, 0.10)]),
}


# Pictures for the media scenario ("widget media" in widgets.py): twelve shots of the site.
SHOTS = [
    ("photos/home-hero.png", "The homepage hero in light mode", (96, 165, 250), (37, 99, 235)),
    ("photos/home-hero-dark.png", "The homepage hero in dark mode", (30, 41, 59), (15, 23, 42)),
    ("photos/pricing.png", "The pricing table with three plans", (52, 211, 153), (5, 150, 105)),
    ("photos/sign-up.png", "The beta sign-up form", (251, 191, 36), (217, 119, 6)),
    ("photos/changelog.png", "The changelog page", (244, 114, 182), (219, 39, 119)),
    ("photos/docs.png", "The docs landing page", (167, 139, 250), (124, 58, 237)),
    ("photos/footer.png", "The footer with the newsletter field", (148, 163, 184), (71, 85, 105)),
    ("photos/mobile-nav.png", "The navigation menu on a phone", (45, 212, 191), (13, 148, 136)),
    ("photos/404.png", "The page-not-found screen", (248, 113, 113), (220, 38, 38)),
    ("photos/blog.png", "The blog index", (163, 230, 53), (101, 163, 13)),
    ("photos/team.png", "The team page", (251, 146, 60), (234, 88, 12)),
    ("photos/press-kit.png", "The press kit download page", (129, 140, 248), (79, 70, 229)),
]
for _index, (_path, _alt, _top, _bottom) in enumerate(SHOTS):
    PICTURES[_path] = png(640, 480, _top, _bottom,
                          [(0.08, 0.10, 0.84, 0.10), (0.08, 0.30, 0.40 + 0.04 * (_index % 4), 0.30), (0.56, 0.30, 0.36, 0.08),
                           (0.56, 0.44, 0.30, 0.08), (0.08, 0.72, 0.84, 0.12)])

# The project's videos and the oversized files (relative path -> a function giving the bytes),
# made on first use: a picture over the app's 50 MB limit for pictures, and a ".mp4" that isn't
# one. `audio.py`'s /api/files/stream serves them too.
_MADE = {}


def _clip():
    return (pathlib.Path(__file__).parent / "media" / "sample-clip.mp4").read_bytes()


def _pdf(lines):
    """A one-page PDF with `lines` of text, built here so the Preview has a real one to show."""
    text = "BT /F1 18 Tf 72 720 Td 26 TL " + " ".join(
        "(" + line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ") '" for line in lines) + " ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(text) + text.encode() + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


def _zip(files):
    import io
    import zipfile
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return buffer.getvalue()


# Office files the mock sends with "office files" (docs/chat.md §3a), made with the standard library:
# just enough of each format for Quick Look to draw the launch plan.

OFFICE_ROWS = [("Week", "Sign-ups", "Pro"), ("1", "312", "14"), ("2", "468", "29"), ("3", "504", "36")]
OFFICE_POINTS = ["Beta opens to the waiting list on Monday", "Pro launches at $8 a month",
                 "Team adds shared Boards in week three"]


def _x(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _docx():
    body = "".join(f'<w:p><w:pPr><w:pStyle w:val="{style}"/></w:pPr><w:r><w:t xml:space="preserve">{_x(t)}</w:t></w:r></w:p>'
                   for style, t in [("Title", "Launch plan")] + [("Normal", p) for p in OFFICE_POINTS])
    cells = "".join("<w:tr>" + "".join(f"<w:tc><w:p><w:r><w:t>{_x(c)}</w:t></w:r></w:p></w:tc>" for c in row) + "</w:tr>"
                    for row in OFFICE_ROWS)
    table = ('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
             + "".join(f'<w:{b} w:val="single" w:sz="4" w:space="0" w:color="999999"/>' for b in ("top", "left", "bottom", "right", "insideH", "insideV"))
             + "</w:tblBorders></w:tblPr>" + cells + "</w:tbl>")
    W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    styles = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles {W}>'
              '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:sz w:val="24"/></w:rPr></w:style>'
              '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style></w:styles>')
    return _zip({
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>',
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
        "word/_rels/document.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
        "word/styles.xml": styles,
        "word/document.xml": f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document {W}><w:body>{body}{table}<w:sectPr/></w:body></w:document>',
    })


def _xlsx():
    def cell(ref, value):
        return f'<c r="{ref}"><v>{value}</v></c>' if value.isdigit() else f'<c r="{ref}" t="inlineStr"><is><t>{_x(value)}</t></is></c>'
    rows = "".join(f'<row r="{i + 1}">' + "".join(cell(f"{'ABC'[j]}{i + 1}", v) for j, v in enumerate(row)) + "</row>"
                   for i, row in enumerate(OFFICE_ROWS))
    return _zip({
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Beta" sheetId="1" r:id="rId1"/></sheets></workbook>',
        "xl/worksheets/sheet1.xml": f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>{rows}</sheetData></worksheet>',
    })


def _pptx():
    P = ('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
         'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
         'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"')
    R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    rels = lambda items: ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                          + "".join(f'<Relationship Id="{i}" Type="{R}/{t}" Target="{g}"/>' for i, t, g in items) + "</Relationships>")
    tree = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>'

    def box(n, y, h, size, text, bold=False):
        weight = ' b="1"' if bold else ""
        runs = "".join(f'<a:p><a:r><a:rPr lang="en-US" sz="{size}"{weight}/><a:t>{_x(t)}</a:t></a:r></a:p>' for t in text)
        return (f'<p:sp><p:nvSpPr><p:cNvPr id="{n}" name="Text {n}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
                f'<p:spPr><a:xfrm><a:off x="457200" y="{y}"/><a:ext cx="8229600" cy="{h}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
                f'<p:txBody><a:bodyPr wrap="square"/><a:lstStyle/>{runs}</p:txBody></p:sp>')
    slide = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld {P}><p:cSld><p:spTree>{tree}'
             + box(2, 457200, 1143000, 4000, ["Launch plan"], True) + box(3, 1828800, 3200400, 2400, OFFICE_POINTS)
             + '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')
    clr = '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
    master = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldMaster {P}><p:cSld><p:spTree>{tree}</p:spTree></p:cSld>{clr}'
              '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>')
    layout = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldLayout {P} type="blank"><p:cSld name="Blank"><p:spTree>{tree}</p:spTree></p:cSld>'
              '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>')
    colors = "".join(f'<a:{n}><a:srgbClr val="{v}"/></a:{n}>' for n, v in [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F2937"), ("lt2", "F3F4F6"), ("accent1", "2563EB"), ("accent2", "16A34A"), ("accent3", "D97706"), ("accent4", "DC2626"), ("accent5", "7C3AED"), ("accent6", "0891B2"), ("hlink", "2563EB"), ("folHlink", "7C3AED")])
    font = '<a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/>'
    fill = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    line = '<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
    theme = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Plain"><a:themeElements>'
             f'<a:clrScheme name="Plain">{colors}</a:clrScheme><a:fontScheme name="Plain"><a:majorFont>{font}</a:majorFont><a:minorFont>{font}</a:minorFont></a:fontScheme>'
             f'<a:fmtScheme name="Plain"><a:fillStyleLst>{fill * 3}</a:fillStyleLst><a:lnStyleLst>{line * 3}</a:lnStyleLst>'
             '<a:effectStyleLst>' + '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3 + f'</a:effectStyleLst><a:bgFillStyleLst>{fill * 3}</a:bgFillStyleLst></a:fmtScheme>'
             '</a:themeElements></a:theme>')
    ct = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
          '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
          '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
          '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
          '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>')
    presentation = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation {P}>'
                    '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
                    '<p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="9144000" cy="5143500"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>')
    return _zip({
        "[Content_Types].xml": ct,
        "_rels/.rels": rels([("rId1", "officeDocument", "ppt/presentation.xml")]),
        "ppt/presentation.xml": presentation,
        "ppt/_rels/presentation.xml.rels": rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "slide", "slides/slide1.xml"), ("rId3", "theme", "theme/theme1.xml")]),
        "ppt/slides/slide1.xml": slide,
        "ppt/slides/_rels/slide1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
        "ppt/slideLayouts/slideLayout1.xml": layout,
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
        "ppt/slideMasters/slideMaster1.xml": master,
        "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]),
        "ppt/theme/theme1.xml": theme,
    })


def _odf(kind):
    """An OpenDocument text, spreadsheet or presentation: its mimetype first and unpacked, as the format asks."""
    import io
    import zipfile
    mime = f"application/vnd.oasis.opendocument.{kind}"
    NS = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
          'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
          'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
          'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.3"')
    paragraphs = "".join(f"<text:p>{_x(p)}</text:p>" for p in OFFICE_POINTS)
    if kind == "text":
        body = f'<office:text><text:h text:outline-level="1">Launch plan</text:h>{paragraphs}</office:text>'
    elif kind == "spreadsheet":
        def cell(v):
            if v.isdigit():
                return f'<table:table-cell office:value-type="float" office:value="{v}"><text:p>{v}</text:p></table:table-cell>'
            return f'<table:table-cell office:value-type="string"><text:p>{_x(v)}</text:p></table:table-cell>'
        rows = "".join("<table:table-row>" + "".join(cell(v) for v in row) + "</table:table-row>" for row in OFFICE_ROWS)
        body = f'<office:spreadsheet><table:table table:name="Beta">{rows}</table:table></office:spreadsheet>'
    else:
        body = ('<office:presentation><draw:page draw:name="Launch plan" draw:master-page-name="Default">'
                '<draw:frame svg:x="2cm" svg:y="1.5cm" svg:width="24cm" svg:height="3cm"><draw:text-box><text:p>Launch plan</text:p></draw:text-box></draw:frame>'
                f'<draw:frame svg:x="2cm" svg:y="5cm" svg:width="24cm" svg:height="10cm"><draw:text-box>{paragraphs}</draw:text-box></draw:frame>'
                '</draw:page></office:presentation>')
    styles = ""
    if kind == "presentation":
        styles = ('<office:master-styles><style:master-page style:name="Default" style:page-layout-name="PM1"/></office:master-styles>')
    content = f'<?xml version="1.0" encoding="UTF-8"?><office:document-content {NS}><office:body>{body}</office:body></office:document-content>'
    styles_xml = (f'<?xml version="1.0" encoding="UTF-8"?><office:document-styles {NS}><office:automatic-styles>'
                  '<style:page-layout style:name="PM1"><style:page-layout-properties fo:page-width="28cm" fo:page-height="15.75cm"/></style:page-layout>'
                  f'</office:automatic-styles>{styles}</office:document-styles>')
    manifest = ('<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">'
                f'<manifest:file-entry manifest:full-path="/" manifest:media-type="{mime}"/>'
                '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
                '<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/></manifest:manifest>')
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), mime, compress_type=zipfile.ZIP_STORED)
        for name, data in [("content.xml", content), ("styles.xml", styles_xml), ("META-INF/manifest.xml", manifest)]:
            archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    return buffer.getvalue()


def _rtf():
    points = "".join(f"\\bullet  {p}\\par\n" for p in OFFICE_POINTS)
    return ("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24\n{\\b\\fs40 Launch brief}\\par\n"
            + points + "}\n").encode()

LAUNCH_NOTES = """# Launch notes

- The beta form goes live on Monday at 09:00.
- Pricing stays at $8 for Pro; Free keeps three projects.
- The walkthrough video replaces the hero animation on mobile.

## Still open

1. Who answers the beta inbox over the weekend
2. Whether the changelog gets its own RSS feed
"""

LAUNCH_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Launch summary</title>
<style>body{font:16px -apple-system,system-ui,sans-serif;margin:32px;color:#111;max-width:640px}
h1{font-size:26px}img{width:100%;border-radius:12px}.note{color:#666}</style></head>
<body><h1>Launch summary</h1>
<p>The beta opens Monday. The flow below is the one the form follows.</p>
<img src="launch-flow.png" alt="The launch flow">
<p class="note">This picture is a file next to the page, read through the gateway.</p>
</body></html>
"""

# A page "live page" shows in its reply (docs/chat.md §3c): the app's colours through Hermes
# Desktop's variables, buttons that send with `data-hermes-send` and with `hermes.send`, and a
# request out that the page's policy stops.
PLAN_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Plan picker</title>
<style>
body{font:15px -apple-system,system-ui,sans-serif;padding:16px}
h2{margin:0 0 4px;font-size:17px}
p{margin:0 0 12px;color:var(--muted-foreground)}
.plans{display:flex;gap:8px;flex-wrap:wrap}
button{font:inherit;padding:8px 14px;border-radius:10px;border:1px solid var(--border);
  background:var(--card);color:var(--foreground);cursor:pointer}
button.main{background:var(--accent);color:#fff;border-color:transparent}
#status{margin-top:12px;font-size:13px;color:var(--muted-foreground)}
</style></head>
<body>
<h2>Pick a plan</h2>
<p>Free keeps three projects; Pro is $8 a month; Team adds shared Boards.</p>
<div class="plans">
  <button data-hermes-send="Plan picked on the page: Free">Free</button>
  <button class="main" data-hermes-send="Plan picked on the page: Pro">Pro</button>
  <button id="team">Team</button>
</div>
<div id="status">Network: checking…</div>
<script>
var note = document.getElementById("status");
document.getElementById("team").addEventListener("click", function () {
  hermes.send("Plan picked on the page: Team").then(function (ack) {
    note.textContent = ack.ok ? "Sent to Hermes." : "Not sent: " + ack.error + (ack.reason ? " (" + ack.reason + ")" : "");
  });
});
// What a page can't do: reach the network, by a request, a call or a frame, or use the microphone
// or camera (both missing, or refused without the person being asked).
var open = [];
function tell() { note.textContent = (open.length ? "Open: " + open.join(", ") : "Network: blocked, as it should be.") + capture; }
var capture = "";
if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
  navigator.mediaDevices.getUserMedia({ audio: true, video: true }).then(
    function () { open.push("capture"); tell(); },
    function (e) { capture = " Capture: " + e.name + "."; tell(); });
} else { capture = " Capture: missing."; }
if (window.RTCPeerConnection || window.webkitRTCPeerConnection) open.push("calls");
var frame = document.createElement("iframe");
frame.style.display = "none";
frame.src = "data:text/html,<script>parent.postMessage('frame','*')<\/script>";
addEventListener("message", function (e) { if (e.data === "frame") { open.push("frames"); tell(); } });
document.body.appendChild(frame);
var bare = document.createElement("iframe");
bare.style.display = "none";
document.body.appendChild(bare);
try { if (bare.contentWindow.RTCPeerConnection) open.push("calls in a frame"); } catch (e) {}
fetch("https://example.com/track").then(function () { open.push("requests"); tell(); }, tell);
</script>
</body></html>
"""

MEDIA = {
    "media/walkthrough.mp4": _clip,
    "media/broken.mp4": lambda: b"This is not a video. " * 200,
    "pairing/screen.mp4": _clip,   # refused as sensitive, once found
    "photos/print-scan.png": lambda: PICTURES["diagrams/orbit-card.png"] + bytes(60_000_000),
    # The files "attachments" sends (docs/chat.md §3a), outside Git like the pictures.
    "exports/launch-report.pdf": lambda: _pdf(["Launch report", "", "Beta sign-ups: 1,284", "Pro conversions: 6.1%",
                                               "Open questions: 2"]),
    "exports/launch-notes.md": lambda: LAUNCH_NOTES.encode(),
    "exports/launch-summary.html": lambda: LAUNCH_PAGE.encode(),
    "exports/plan-picker.html": lambda: PLAN_PAGE.encode(),
    "exports/launch-flow.png": lambda: PICTURES["diagrams/launch-flow.png"],   # the page's own picture
    "exports/launch-assets.zip": lambda: _zip({"hero.png": PICTURES["photos/home-hero.png"], "notes.md": LAUNCH_NOTES}),
    "pairing/device-qr.png": lambda: PICTURES["diagrams/orbit-card.png"],   # refused as sensitive
    # The office files "office files" sends, which open in Quick Look (docs/chat.md §3a).
    "exports/launch-plan.docx": _docx,
    "exports/beta-numbers.xlsx": _xlsx,
    "exports/launch-deck.pptx": _pptx,
    "exports/launch-brief.rtf": _rtf,
    "exports/launch-plan.odt": lambda: _odf("text"),
    "exports/beta-numbers.ods": lambda: _odf("spreadsheet"),
    "exports/launch-deck.odp": lambda: _odf("presentation"),
}

# A Hermes reply that sends files (docs/chat.md §3a): each `MEDIA:` line on its own, as the agent
# writes them, a picture missing since and one under `pairing/`, which Hermes keeps private.
ATTACHMENTS = f"""Here's the launch pack.

MEDIA:{ROOT}/diagrams/launch-flow.png
MEDIA:{ROOT}/photos/pricing.png
MEDIA:{ROOT}/media/walkthrough.mp4

The report, my notes, the summary page and the assets:

MEDIA:{ROOT}/exports/launch-report.pdf
MEDIA:`{ROOT}/exports/launch-notes.md`
MEDIA:{ROOT}/exports/launch-summary.html
MEDIA:{ROOT}/exports/launch-assets.zip

The print scan is too big to show here, and two files didn't make it:

MEDIA:{ROOT}/photos/print-scan.png
MEDIA:{ROOT}/exports/old-chart.png
MEDIA:{ROOT}/pairing/device-qr.png

A line in a code block is only an example:

```
MEDIA:/tmp/example.png
```"""

# "broken attachments": only the files that don't show, so their states fit on one screen.
ATTACHMENTS_BROKEN = f"""Here's what I could find from the old launch.

MEDIA:{ROOT}/photos/print-scan.png
MEDIA:{ROOT}/exports/old-chart.png
MEDIA:{ROOT}/pairing/device-qr.png
MEDIA:{ROOT}/exports/old-report.pdf
MEDIA:{ROOT}/media/broken.mp4

The scan is too big to show, the chart and the report are gone, and Hermes keeps the pairing code private."""


# "drawings" (docs/chat.md §3b): a Mermaid flowchart, display math both ways, an SVG fence and an
# SVG written in the prose, which the app draws; inline dollars stay words, and a diagram Mermaid
# can't read shows its code.
DRAWINGS = r"""Here's how a sign-up moves through the launch, with the numbers behind it.

```mermaid
flowchart LR
  A[Visitor] --> B{Signed up?}
  B -- yes --> C[Beta invite]
  B -- no --> D[Reminder in 3 days]
  C --> E((Pro))
  D --> B
```

The conversion rate after $n$ reminders, at $5 a seat and $10 for teams:

$$
P(n) = 1 - \prod_{k=1}^{n} \left(1 - \frac{p}{k}\right)
$$

and the time to the first reply follows

\[
\int_0^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
\]

The badge for the page:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 80" width="240" height="80">
  <rect x="2" y="2" width="236" height="76" rx="18" fill="#7c3aed"/>
  <circle cx="40" cy="40" r="18" fill="#fde68a"/>
  <text x="70" y="48" font-family="-apple-system, sans-serif" font-size="22" fill="#ffffff">Beta 2026</text>
  <image href="https://example.com/tracker.png" width="1" height="1"/>
  <script>alert('never runs')</script>
</svg>
```

<svg width="120" height="24" xmlns="http://www.w3.org/2000/svg"><rect width="120" height="24" rx="12" fill="#10b981"/><text x="60" y="17" text-anchor="middle" font-size="13" fill="#fff" font-family="-apple-system">6.1% Pro</text></svg>

This one has a mistake in it:

```mermaid
flowchart LR
  A --> 
  ((( 
```"""


LIVE_PAGE = f"""Here's a page to pick a plan with.

::preview{{file="{ROOT}/exports/plan-picker.html" height="240"}}

And the notes it's based on:

::preview{{file="{ROOT}/exports/launch-notes.md"}}"""


OFFICE_FILES = f"""The plan as a document, the numbers and the deck:

MEDIA:{ROOT}/exports/launch-plan.docx
MEDIA:{ROOT}/exports/beta-numbers.xlsx
MEDIA:{ROOT}/exports/launch-deck.pptx

And the same in OpenDocument, with the brief in rich text:

MEDIA:{ROOT}/exports/launch-plan.odt
MEDIA:{ROOT}/exports/beta-numbers.ods
MEDIA:{ROOT}/exports/launch-deck.odp
MEDIA:{ROOT}/exports/launch-brief.rtf"""


LINK_CARDS = """The launch talk, then the same one by its address:

[The launch talk](https://www.youtube.com/watch?v=dQw4w9WgXcQ)

https://youtu.be/dQw4w9WgXcQ

https://vimeo.com/76979871

https://open.spotify.com/album/4cOdK2wGLETKBW3PvgPWqT

https://soundcloud.com/forss/flickermood

https://github.com/NousResearch/hermes-agent

[Fix the launch checklist](https://github.com/NousResearch/hermes-agent/pull/12)

https://www.bilibili.com/video/BV1xx411c7mD

These stay words: https://youtu.be/dQw4w9WgXcQ in a sentence, and

- https://github.com/NousResearch/hermes-agent

https://example.com/launch"""


def formats_reply(lower):
    """The reply for a Round 3 format word, or None (docs/development.md, mock words)."""
    if "drawings" in lower:
        return DRAWINGS
    if "live page" in lower:
        return LIVE_PAGE
    if "office files" in lower:
        return OFFICE_FILES
    if "video links" in lower:
        return LINK_CARDS
    if lower.startswith("plan picked on the page:"):
        # What a page's button sent, as a hidden message: Hermes answers it as any other.
        plan = lower.split(":", 1)[1].strip().title() or "That"
        return f"Noted: **{plan}**. I'll draft the upgrade note for that plan next."
    return None


def media_bytes(key):
    """The bytes of one of `MEDIA`, made once."""
    with LOCK:
        if key not in _MADE:
            _MADE[key] = MEDIA[key]()
        return _MADE[key]


def project_media(path):
    """A picture or video file in the project, for /api/files/stream; None when there's none."""
    key = rel(path)
    if key in MEDIA:
        return media_bytes(key)
    return PICTURES.get(key)


def fs_download(query):
    path = q(query, "path")
    if not path:
        return 400, "application/json", b'{"detail": "Path is required"}'
    if sensitive(path):
        return 403, "application/json", b'{"detail": "Access to sensitive files is not allowed"}'
    key = rel(path)
    if key is None and (path.startswith("/") or path.startswith("~")):
        return 403, "application/json", b'{"detail": "Path is outside the managed read boundary"}'
    with LOCK:
        text = STATE["work"].get(key) if key is not None else None
    if text is not None:
        return 200, mime_of(key), text.encode()
    if key in PICTURES:
        return 200, mime_of(key), PICTURES[key]
    if key in MEDIA:
        return 200, mime_of(key), media_bytes(key)
    return 404, "application/json", b'{"detail": "File not found"}'


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


def mock_turn(query, body):
    stored = body.get("session") or ""
    with B["LOCK"]:
        sid = next((k for k, r in B["RUNTIME"].items() if r.get("stored") == stored), None)
    if sid is None:
        return 404, {"detail": "That chat isn't open on the socket."}
    B["start_turn"](sid, body.get("text") or "Test the beta sign-up.", C.run_chat_turn)
    return 200, {"ok": True, "session_id": sid}


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


def run_open_turn(sid, text):
    """`preview <address>`: opens that address in the Preview and nothing else, for pages the
    mock doesn't serve itself (the access gateway's `/__mock/leave`, say)."""
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.title_later(sid, stored, text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    url = text.split(None, 1)[1].strip()
    call = f"call_{uuid.uuid4().hex[:8]}"
    args = {"action": "open", "url": url, "label": "Page"}
    G.add_message(stored, "assistant", "", finish_reason="tool_calls",
                  tool_calls=[{"id": call, "type": "function", "function": {"name": "desktop_preview", "arguments": json.dumps(args)}}])
    C.emit(sid, "tool.start", {"tool_id": call, "name": "desktop_preview", "context": url, "args": args})
    C.emit(sid, "preview.open", {"url": url, "label": "Page"})
    G.add_message(stored, "tool", json.dumps({"success": True, "opened": url}), tool_call_id=call, tool_name="desktop_preview")
    C.emit(sid, "tool.complete", {"tool_id": call, "name": "desktop_preview", "args": args, "duration_s": 0.1,
                                  "result": json.dumps({"success": True, "opened": url}), "summary": None})
    answer = "I opened the page beside the chat."
    C.stream(sid, answer)
    C.finish(sid, stored, answer)


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


def run_file_paths_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    answer = (f"I've written the form to `{ROOT}/src/components/BetaForm.tsx`, and the setup notes are in "
              f"[the README]({ROOT}/README.md). Run `npm run dev` and open `/beta` to try it.")
    C.stream(sid, answer)
    C.finish(sid, stored, answer)


def run_attachments_turn(sid, text, answer):
    """Hermes sends files: a `MEDIA:` line each, streamed a few characters at a time so a line
    arrives in pieces (docs/chat.md §3a)."""
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    C.stream(sid, answer)
    C.finish(sid, stored, answer)


def run_rewrite_turn(sid, text):
    stored = B["RUNTIME"][sid]["stored"]
    G.add_message(stored, "user", text)
    C.emit(sid, "session.info", {"running": True})
    C.emit(sid, "message.start", {})
    path = f"{HOME}/.hermes/cache/scratch/widgets-brief.md"
    lines = [f"Section {n}: what the widget shows and when." for n in range(1, 41)]
    first = "\n".join(["# Widget brief", ""] + lines)
    revised = lines[:]
    revised[9] = "Section 10: what the widget shows, and when it hides."
    revised[24] = "Section 25: loading, stale and error states."
    second = "\n".join(["# Widget brief", ""] + revised + ["", "Ship the eight most used first."])
    for name, args, result in (
        ("write_file", {"path": path, "content": first}, json.dumps({"bytes_written": len(first)})),
        ("read_file", {"path": path}, json.dumps({"content": first})),
        ("write_file", {"path": path, "content": second}, json.dumps({"bytes_written": len(second)})),
    ):
        if not C.tool(sid, stored, name, args, 0.4, context="widgets-brief.md", result=result):
            return
    answer = "I've written the brief and tightened two sections after reading it back."
    C.stream(sid, answer)
    C.finish(sid, stored, answer)


# ---------------------------------------------------------------- the Bot Screen

DISPLAY = {"running": True, "installed": True, "supported": True, "lease": {"holder": "agent", "viewer_id": None, "reason": "", "epoch": 0, "since": time.time()},
           "tickets": {}, "viewers": set(), "sockets": [], "dots": [], "keys": [], "fields": ["", ""], "field": 0}
WIDTH, HEIGHT = 1280, 800


def lease_view():
    lease = DISPLAY["lease"]
    vid = lease.get("viewer_id")
    return {"holder": lease["holder"], "viewer_id": None, "reason": lease.get("reason") or "", "epoch": lease["epoch"],
            "since": lease["since"], "viewer_hash": hashlib.sha256(vid.encode()).hexdigest()[:12] if vid else None}


SCREEN_BINARIES = ["Xvnc", "xfwm4", "xfce4-panel", "xfdesktop", "xfsettingsd", "dbus-run-session"]
INSTALL_COMMAND = ("sudo apt-get install -y --no-install-recommends tigervnc-standalone-server xfce4-panel xfwm4 "
                   "xfdesktop4 xfce4-settings xfce4-terminal dbus-x11 x11-xserver-utils x11-utils xauth fonts-dejavu-core")


def display_snapshot():
    """`tools/bot_desktop/runtime.py` DesktopStatus.as_dict(), with the lease."""
    supported, installed, running = DISPLAY["supported"], DISPLAY["supported"] and DISPLAY["installed"], DISPLAY["running"]
    missing = [] if installed else list(SCREEN_BINARIES)
    return {"profile": "default", "supported": supported, "installed": installed, "missing": missing, "running": running,
            "pid": 51234 if running else None, "display": ":1" if running else None,
            "socket": "/tmp/.X11-unix/X1" if running else None, "geometry": f"{WIDTH}x{HEIGHT}",
            "install_command": INSTALL_COMMAND if supported and not installed else None,
            "browser": "chromium" if supported else None, "blocker": None,
            "memory_available_mb": 6144, "memory_limit_mb": None,
            "placement": "gateway", "lease": lease_view(), "profile_key": f"{HOME}/.hermes"}


def display_start(params):
    """`display.start`: refusals in `runtime.start()`'s words, as error 5300."""
    if not DISPLAY["supported"]:
        raise B["RPCError"](5300, "Bot Desktop runs on Linux gateway hosts only")
    if not DISPLAY["installed"]:
        raise B["RPCError"](5300, f"Bot Desktop needs {', '.join(SCREEN_BINARIES)} on the gateway host. Install: {INSTALL_COMMAND}")
    if not DISPLAY["running"]:
        time.sleep(1.5)
        DISPLAY["running"] = True
        broadcast_status()
    return display_snapshot()


def broadcast_status():
    """`display.status`, as Hermes's runtime watcher sends it when a screen starts or stops."""
    broadcast("display.status", display_snapshot())


def display_observe(params):
    if not DISPLAY["running"]:
        raise B["RPCError"](5300, "this profile's Bot Desktop is not running; call display.start first")
    viewer = params.get("viewer_id") or f"viewer_{secrets.token_hex(6)}"
    DISPLAY["viewers"].add(viewer)
    ticket = secrets.token_urlsafe(18)
    DISPLAY["tickets"][ticket] = (time.time() + 30, viewer)
    return {"ticket": ticket, "path": "/api/display/ws", "viewer_id": viewer, **display_snapshot()}


def broadcast_lease():
    broadcast("display.lease", {"profile_key": f"{HOME}/.hermes", "lease": lease_view()})


def broadcast(kind, payload):
    frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": "", "payload": payload}}
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
    if action in ("stop", "uninstall", "unsupported"):
        was_running = DISPLAY["running"]
        DISPLAY["running"] = False
        DISPLAY["installed"] = DISPLAY["installed"] and action != "uninstall"
        DISPLAY["supported"] = DISPLAY["supported"] and action != "unsupported"
        close_sockets(4001, "Bot Desktop is not running")
        if was_running:
            broadcast_status()
    elif action == "start":
        DISPLAY.update(running=True, installed=True, supported=True)
        broadcast_status()
    elif action == "install":
        DISPLAY["installed"] = True
    elif action == "supported":
        DISPLAY["supported"] = True
    elif action == "evict":
        DISPLAY["lease"] = {"holder": "human", "viewer_id": "viewer_someone_else", "reason": "", "epoch": DISPLAY["lease"]["epoch"] + 1, "since": time.time()}
        broadcast_lease()
        close_sockets(4000, "control-taken")
    return 200, display_snapshot()


# Keysym names for the key log (X11's keysymdef.h).
KEYSYM_NAMES = {0xFF08: "BackSpace", 0xFF09: "Tab", 0xFF0D: "Return", 0xFF1B: "Escape", 0xFFFF: "Delete",
                0xFF50: "Home", 0xFF51: "Left", 0xFF52: "Up", 0xFF53: "Right", 0xFF54: "Down", 0xFF55: "Prior",
                0xFF56: "Next", 0xFF57: "End", 0xFFE1: "Shift_L", 0xFFE3: "Control_L", 0xFFE9: "Alt_L"}
FIELD_TOPS = (200, 252)


def keysym_name(keysym):
    if keysym in KEYSYM_NAMES:
        return KEYSYM_NAMES[keysym]
    if 0xFFBE <= keysym <= 0xFFC9:
        return f"F{keysym - 0xFFBE + 1}"
    code = keysym - 0x01000000 if keysym >= 0x01000000 else keysym
    return chr(code) if 0x20 <= code < 0x110000 else hex(keysym)


def key_event(keysym, down):
    """A KeyEvent from the lease holder: logged, and typed into the focused field on the way down."""
    DISPLAY["keys"].append({"keysym": f"0x{keysym:04x}", "name": keysym_name(keysym), "down": down, "at": round(time.time(), 3)})
    del DISPLAY["keys"][:-500]
    if keysym in (0xFFE3, 0xFFE4):
        DISPLAY["control"] = down
    if not down or DISPLAY.get("control"):
        return
    fields, focus = DISPLAY["fields"], DISPLAY["field"]
    if keysym == 0xFF08:
        fields[focus] = fields[focus][:-1]
    elif keysym == 0xFF09:
        DISPLAY["field"] = (focus + 1) % len(fields)
    elif keysym < 0xFF00 or keysym >= 0x01000000:
        code = keysym - 0x01000000 if keysym >= 0x01000000 else keysym
        if code >= 0x20:
            fields[focus] = (fields[focus] + chr(code))[:48]


def key_log():
    return {"keys": DISPLAY["keys"], "fields": DISPLAY["fields"], "field": DISPLAY["field"]}


def clear_keys(query, body):
    DISPLAY.update(keys=[], fields=["", ""], field=0)
    return 200, key_log()


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
    # What was typed: a block per character, a space as a gap.
    for index, top in enumerate(FIELD_TOPS):
        for i, character in enumerate(DISPLAY["fields"][index]):
            if not character.isspace():
                rect(182 + i * 8, top + 12, 6, 16, (0x22, 0x22, 0x22, 0xFF))
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
                    # The caret, after the focused field's text.
                    full = bytearray(full)
                    top = FIELD_TOPS[DISPLAY["field"]]
                    x = min(182 + len(DISPLAY["fields"][DISPLAY["field"]]) * 8, 584)
                    for row in range(top + 14, top + 30):
                        start = (row * WIDTH + x) * 4
                        full[start:start + 8] = b"\x11\x11\x11\xff" * 2
                    full = bytes(full)
                peer.send(frame_update(170, 200, 440, 160, full))
        elif kind == 4:
            down, keysym = struct.unpack(">BxxI", peer.read(7))
            lease = DISPLAY["lease"]
            if lease["holder"] == "human" and lease.get("viewer_id") == viewer:
                key_event(keysym, bool(down))
        elif kind == 5:
            buttons, x, y = struct.unpack(">BHH", peer.read(5))
            lease = DISPLAY["lease"]
            if buttons & 1 and lease["holder"] == "human" and lease.get("viewer_id") == viewer:
                DISPLAY["dots"].append((x, y))
                # A click in a field focuses it.
                for index, top in enumerate(FIELD_TOPS):
                    if 170 <= x < 590 and top <= y < top + 40:
                        DISPLAY["field"] = index
        elif kind == 6:
            length = struct.unpack(">xxxI", peer.read(7))[0]
            peer.read(length)
        else:
            break
    if peer in DISPLAY["sockets"]:
        DISPLAY["sockets"].remove(peer)
