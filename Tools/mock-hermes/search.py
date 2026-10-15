"""Full-text chat search for the combined mock (`docs/search.md`): GET /api/sessions/search on the
backend REST API, shaped like hermes_cli/web_routers/sessions.py.

  - q is required (empty -> no results); each word is prefix-matched, quoted phrases match exactly.
  - ID matches first, then message content, then titles; one result per chat; limit (20, at most 100).
  - The snippet is about 40 words around the match with matched words between >>> and <<<.
  - last_active is null on content hits (only ID and title hits carry it), session_started is set.
  - profile=<bot> searches that Bot's chats; sources / exclude_sources filter by source (cron for
    scheduled task runs).

Demo content (the designs' drawerSearch): "reconnect" is said in Fix the reconnect after sleep and
Push notifications plugin (Hermes App), in Ada's Release notes draft, and in a Check NAS backups
task run.
"""

import re
import time

B = None  # backend.py's module globals
G = None  # server.py


def install(backend_globals, gateway_module):
    global B, G
    B, G = backend_globals, gateway_module
    B["HTTP_ROUTES"][("GET", "/api/sessions/search")] = search
    seed()


def seed():
    now = time.time()
    with G.LOCK:
        if "prj_reconnect" in G.SESSIONS:
            G.add_message("prj_reconnect", "assistant",
                          "Fixed: the socket now reconnects with backoff when the Mac wakes, and a new test covers it.",
                          timestamp=now - 80)
        if "prj_pushplugin" in G.SESSIONS:
            G.add_message("prj_pushplugin", "assistant",
                          "On launch and after a reconnect the plugin re-registers the device token with push.register, "
                          "so a Mac that slept still gets pushes.", timestamp=now - 5 * 3600)
        G.session_row("cron_nas_1012", "Check NAS backups", "cron", now - 3 * 86400, now - 3 * 86400 + 60,
                      "Verify last night's backups finished")
        G.add_message("cron_nas_1012", "user", "Verify last night's backups finished and report failures.",
                      timestamp=now - 3 * 86400)
        G.add_message("cron_nas_1012", "assistant",
                      "All good. The NAS was unreachable for 2 min; the job waited for the reconnect and finished. "
                      "212 GB, 0 errors.", timestamp=now - 3 * 86400 + 60)
    draft = B["add_session"]("writer", "Release notes draft", started=now - 86400 - 3600)
    B["add_message"](draft, "user", "Draft the release notes for 1.3", now - 86400 - 3600)
    B["add_message"](draft, "assistant", "Here's a draft: typed throws, Bot Chat routine cards and faster reconnects. "
                                         "Want the post too?", now - 86400 - 3500)


def words_of(q):
    """Tokens and quoted phrases, as the gateway splits them."""
    return [t.strip('"').lower() for t in re.findall(r'"[^"]*"|\S+', q.strip()) if t.strip('"')]


def matches(text, terms):
    low = (text or "").lower()
    for term in terms:
        if " " in term:
            if term not in low:
                return False
        elif not re.search(r"(?<!\w)" + re.escape(term), low):
            return False
    return True


def snippet(text, terms):
    """About 40 words around the first match, each match wrapped in >>> <<<."""
    words = (text or "").split()
    first = 0
    for i, w in enumerate(words):
        if any(w.lower().strip(".,;:!?\"'()").startswith(t.split()[0]) for t in terms):
            first = i
            break
    start = max(0, first - 8)
    window = words[start:start + 40]
    out = " ".join(window)
    # Like FTS5 with a prefix query: the whole word that matched is highlighted.
    for term in sorted(set(t for t in terms if " " not in t), key=len, reverse=True):
        out = re.sub(r"(?<!\w)(" + re.escape(term) + r"\w*)", lambda m: ">>>" + m.group(1) + "<<<", out, flags=re.IGNORECASE)
    for phrase in (t for t in terms if " " in t):
        out = re.sub(re.escape(phrase), lambda m: ">>>" + m.group(0) + "<<<", out, flags=re.IGNORECASE)
    prefix = "…" if start > 0 else ""
    suffix = "…" if start + 40 < len(words) else ""
    return prefix + out + suffix


def search(query, body):
    q = (query.get("q") or [""])[0]
    if not q.strip():
        return 200, {"results": []}
    time.sleep(0.15)  # a real FTS query takes a moment; the app debounces and cancels
    limit = max(1, min(int((query.get("limit") or ["20"])[0] or 20), 100))
    profile = (query.get("profile") or [None])[0]
    include = set(filter(None, ((query.get("sources") or [""])[0] or "").split(","))) or None
    if (query.get("source") or [None])[0]:
        include = {query["source"][0]}
    exclude = set(filter(None, ((query.get("exclude_sources") or [""])[0] or "").split(",")))
    terms = words_of(q)

    rows = []  # (session row, messages)
    if profile and profile != "default":
        with B["LOCK"]:
            for s in B["STORED"].values():
                if s["profile"] == profile and not s.get("hidden"):
                    rows.append(({"id": s["id"], "title": s.get("title"), "source": s.get("source"), "model": None,
                                  "started_at": s["started_at"], "last_active": s["last_active"], "preview": "",
                                  "archived": False}, list(s["messages"])))
    else:
        with G.LOCK:
            for sid, s in G.SESSIONS.items():
                rows.append(({"id": sid, "title": s.get("title"), "source": s.get("source"), "model": s.get("model"),
                              "started_at": s.get("started_at"), "last_active": s.get("_last"), "preview": s.get("_preview"),
                              "archived": s.get("archived", False)}, list(G.MESSAGES.get(sid, []))))
    rows = [(s, m) for s, m in rows
            if (include is None or s["source"] in include) and s["source"] not in exclude]

    results, seen = [], set()

    def add(s, messages, snip, role, last_active):
        if s["id"] in seen or len(results) >= limit:
            return
        seen.add(s["id"])
        results.append({
            "session_id": s["id"], "id": s["id"], "lineage_root": s["id"], "title": s["title"], "preview": s["preview"],
            "snippet": snip, "role": role, "source": s["source"], "model": s["model"], "session_started": s["started_at"],
            "last_active": last_active, "message_count": len(messages), "archived": bool(s["archived"]),
            "profile": profile or "default", "is_default_profile": not profile or profile == "default"})

    for s, messages in rows:  # pasted ids
        if s["id"].startswith(q.strip()):
            add(s, messages, s["preview"] or f"Session ID: {s['id']}", None, s["last_active"])
    hits = []
    for s, messages in rows:
        for m in messages:
            if m["role"] in ("user", "assistant") and isinstance(m.get("content"), str) and matches(m["content"], terms):
                hits.append((m.get("timestamp") or 0, s, messages, m))
    for _, s, messages, m in sorted(hits, key=lambda h: h[0], reverse=True):
        add(s, messages, snippet(m["content"], terms), m["role"], None)
    for s, messages in rows:  # titles fill the rest
        if matches(s["title"] or "", terms):
            add(s, messages, snippet(s["title"], terms), None, s["last_active"])
    return 200, {"results": results}
