"""Full-text chat search for the combined mock (`docs/search.md`): GET /api/sessions/search on the
backend REST API, shaped like hermes_cli/web_routers/sessions.py.

  - q is required (empty -> no results); each word is prefix-matched, quoted phrases match exactly.
  - ID matches first, then message content, then titles; one result per chat; limit (20, at most 100).
  - The snippet is about 40 words around the match with matched words between >>> and <<<.
  - Every result carries its chat's last_active from the session row (the newer of the heartbeat and
    the newest stored row, compaction summaries included), else its start; none says when the matched
    message was written. session_started is the matched row's.
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
    seed_runs()
    seed_bot_runs()


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


def seed_runs():
    """Each task's recent runs: chats with id cron_<job>_<timestamp>, source cron."""
    day = 86400
    midnight = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
    for job_id, job in list(G.JOBS.items()):
        if job_id in G.JOB_RUNS:
            # The routines' own runs (server.py seed_routine_runs), at most `limit` (20, at most 100).
            B["HTTP_ROUTES"][("GET", f"/api/cron/jobs/{job_id}/runs")] = lambda q, body, runs=G.JOB_RUNS[job_id]: (
                200, {"runs": runs[:run_limit(q)], "limit": run_limit(q)})
            continue
        runs = []
        for i, (ago, seconds, answer, error) in enumerate([
            (0, 41, "3 events, 2 PRs waiting, backup finished at 04:12.", None),
            (1, 38, "4 events, no PRs, backup finished at 04:09.", None),
            (3, 12, "", "Calendar sign-in expired. Nothing was sent."),
        ]):
            start = midnight - ago * day + 7.5 * 3600
            sid = f"cron_{job_id}_{int(start)}"
            G.session_row(sid, job["name"], "cron", start, start + seconds, job.get("prompt", "")[:60])
            G.SESSIONS[sid]["ended_at"] = start + seconds
            G.add_message(sid, "user", job.get("prompt", ""), timestamp=start)
            if answer:
                G.add_message(sid, "assistant", answer, timestamp=start + seconds)
            runs.append({"id": sid, "source": "cron", "title": job["name"], "started_at": start, "ended_at": start + seconds,
                         "last_active": start + seconds, "message_count": 2 if answer else 1, "preview": answer or None,
                         "end_reason": "error" if error else "completed", "error": error, "profile": "default"})
        B["HTTP_ROUTES"][("GET", f"/api/cron/jobs/{job_id}/runs")] = lambda q, body, runs=runs: (200, {"runs": runs, "limit": 20})


# A Bot's routines run in the Bot's own profile and keep their chats there (docs/tasks.md §5):
# (job id, days ago, seconds, reply, error). None for days ago means the job's last run, so the
# run agrees with its delivery in the Bot Chat; "friday" means the last Friday. Hermes's row
# previews the prompt, never the reply.
BOT_RUNS = [
    ("job_digest", None, 41, "Three new papers on speculative decoding and one on KV cache reuse. The KV cache paper "
     "is the one to read: it reuses prefixes across requests and cuts time to first token by 38% on long prompts. "
     "The decoding papers agree that a draft model a tenth the size is enough, and two of them share code you can "
     "run on a laptop. Want summaries of each?", None),
    ("job_digest", 1, 37, "Two new papers on long-context evaluation.", None),
    ("job_digest", 2, 6, None, None),
    ("job_watch", 0, 18, "MLX 0.31 is out: faster quantized matmul on M4.", None),
    ("job_reading", "friday", 9, None, "The reading list folder was moved. Nothing was sent."),
    ("job_disks", None, 12, "tank 71% · backup 41%. The last scrub repaired 0B.", None),
]


def seed_bot_runs():
    """Run chats of the Bots' routines, stored in each Bot's profile, and their runs routes, shaped
    like `_list_cron_job_runs_sync`: newest first, at most `limit`, each row stamped with the
    profile that holds it."""
    import datetime
    day = 86400
    now = time.time()
    midnight = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
    rows = {}
    for job_id, ago, seconds, answer, error in BOT_RUNS:
        profile, job = next(((p, jobs[job_id]) for p, jobs in B["CRON"].items() if job_id in jobs), (None, None))
        if job is None:
            continue
        if ago is None:
            start = datetime.datetime.fromisoformat(job["last_run_at"]).timestamp() - 3
        else:
            if ago == "friday":
                ago = (time.localtime().tm_wday - 4) % 7
            start = midnight - ago * day + {"job_watch": 6, "job_reading": 17}.get(job_id, 8) * 3600
            if job_id == "job_digest":
                # The same time of day as its last run: the digest runs daily.
                start = datetime.datetime.fromisoformat(job["last_run_at"]).timestamp() - 3 - ago * day
            while start + seconds > now:
                start -= day
        sid = f"cron_{job_id}_{time.strftime('%Y%m%d_%H%M%S', time.localtime(start))}"
        name = job["name"].split("] ", 1)[-1]
        B["add_session"](profile, name, source="cron", started=start, sid=sid)
        if answer or error:
            B["add_message"](sid, "user", job["prompt"], start)
        if answer:
            B["add_message"](sid, "assistant", answer, start + seconds)
        count = len(B["STORED"][sid]["messages"])
        rows.setdefault(job_id, []).append({
            "id": sid, "source": "cron", "title": name if count else None, "started_at": start, "ended_at": start + seconds,
            "last_active": start + seconds, "message_count": count, "preview": job["prompt"][:60] if count else "",
            "end_reason": "error" if error else "cron_complete", "error": error, "cron_job_id": job_id,
            "is_active": False, "scheduler_owned": True, "profile": profile})
    for job_id in (job_id for jobs in B["CRON"].values() for job_id in jobs):
        runs = rows.setdefault(job_id, [])
        runs.sort(key=lambda r: r["started_at"], reverse=True)
        B["HTTP_ROUTES"][("GET", f"/api/cron/jobs/{job_id}/runs")] = lambda q, body, runs=runs: (
            200, {"runs": runs[:run_limit(q)], "limit": run_limit(q)})


def run_limit(query):
    """`limit` as Hermes clamps it (`_list_cron_job_runs_sync`): 1 to 100, else 20."""
    try:
        return max(1, min(int((query.get("limit") or ["20"])[0]), 100))
    except ValueError:
        return 20


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
                                  "started_at": s["started_at"], "last_active": B["freshest"](s), "preview": "",
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

    def add(s, messages, snip, role):
        if s["id"] in seen or len(results) >= limit:
            return
        # As add_lineage_result: the session's rich row overrides the hit's own last_active.
        last_active = s["last_active"] or s["started_at"]
        seen.add(s["id"])
        results.append({
            "session_id": s["id"], "id": s["id"], "lineage_root": s["id"], "title": s["title"], "preview": s["preview"],
            "snippet": snip, "role": role, "source": s["source"], "model": s["model"], "session_started": s["started_at"],
            "last_active": last_active, "message_count": len(messages), "archived": bool(s["archived"]),
            "profile": profile or "default", "is_default_profile": not profile or profile == "default"})

    for s, messages in rows:  # pasted ids
        if s["id"].startswith(q.strip()):
            add(s, messages, s["preview"] or f"Session ID: {s['id']}", None)
    hits = []
    for s, messages in rows:
        for m in messages:
            if m["role"] in ("user", "assistant") and isinstance(m.get("content"), str) and matches(m["content"], terms):
                hits.append((m.get("timestamp") or 0, s, messages, m))
    for _, s, messages, m in sorted(hits, key=lambda h: h[0], reverse=True):
        add(s, messages, snippet(m["content"], terms), m["role"])
    for s, messages in rows:  # titles fill the rest
        if matches(s["title"] or "", terms):
            add(s, messages, snippet(s["title"], terms), None)
    return 200, {"results": results}
