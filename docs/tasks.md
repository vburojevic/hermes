# Tasks and Routines

Both are Hermes **cron jobs**: a prompt Hermes runs on a schedule, each run in a chat of its own.

- **Tasks** (Tasks in the sidebar, ⇧⌘1) are the gateway's jobs, read and changed over the API
  server.
- **Routines** belong to a Bot: jobs created in the Bot's profile, usually posting their results
  into its Bot Chat. They need Bot Mode and go over the backend's socket.

This document covers the calls behind each, the schedules and delivery targets Hermes understands,
and the iPad and Mac layouts. Design components: `Tasks.taskRow`, `Tasks.runRow`, `runRowFailed`,
`ipadTasks`, `macTasks` and the Mac's `macRoutines` sheet.

## 1. Calls

**Tasks** (`HermesClient`, Bearer `API_SERVER_KEY`, `docs/connecting-and-voice.md` §1):

| Action | Call | Notes |
|---|---|---|
| Tasks list | `GET /api/jobs?include_disabled=true` | Paused jobs only appear with `include_disabled`. Sorted active first by next run, paused last. Loaded when Tasks opens and on pull to refresh |
| New Task | `POST /api/jobs {name, schedule, prompt}` | Name, prompt and schedule are required. Hermes allows a name up to 200 characters and a prompt up to 5000, and sets `deliver: local` when none is given |
| Pause / Resume | `POST /api/jobs/{id}/pause`, `…/resume` | The row updates from the job in the answer |
| Run Now | `POST /api/jobs/{id}/run` | |
| Delete | `DELETE /api/jobs/{id}` | Removed from the list at once and put back if the call fails. No confirmation |
| Recent runs | `GET /api/cron/jobs/{id}/runs?limit=20&profile?` | On the backend, so only with Bot Mode connected, and only on iPad and Mac (§4). Each agent run is a chat with id `cron_<jobId>_<timestamp>` and source `cron`; script-only runs have output but no chat |
| Open a run | `GET /api/sessions/{id}/messages` | The run opens in Chats like any other chat, and can be continued |
| Last run failed | `state: error`, or `last_status` `error` or `blocked_config`, and `last_error` | A red tag in the list, the error in the detail |
| Results didn't arrive | `last_status: delivery_failed`, `last_delivery_error` | An orange tag in the list; the reason in the detail, with what it means (§6) |
| Last run didn't start | `last_fire_error.detail` (cleared by the next run that works) | An orange tag in the list; the reason in the detail (§6) |

Fields the app reads from a job (`CronJob`): `id`, `name`, `prompt`, `schedule_display` (else
`schedule.display`), `skills`, `enabled`, `state`, `paused_reason`, `created_at`, `next_run_at`,
`last_run_at`, `last_status`, `last_error`, `last_delivery_error`, `last_fire_error.detail`,
`deliver`, and `repeat.times` / `repeat.completed`.

**Routines** (`BotRoster`, over the socket with `profile: <bot>`):

| Action | Call | Notes |
|---|---|---|
| A Bot's routines | `cron.manage {action: "list", profile, include_disabled: true}` | Hermes adds `scoped: <profile>` when it honoured the profile. Without it (an older gateway) the app keeps only jobs named `[bot:<name>] …` |
| New Routine | `cron.manage {action: "add", profile, name: "[bot:<name>] <title>", schedule, prompt, deliver}` | `deliver` is `bot-chat` with Post results in the Bot Chat on, else `local` |
| Pause / Resume / Delete | `cron.manage {action: "pause" \| "resume" \| "remove", profile, name: <job id>}` | `name` takes the job id; a bare name can be ambiguous. Delete asks first |
| Run Now | `POST /api/cron/jobs/{id}/trigger?profile=<bot>` | Backend REST; the socket has no call for it |
| Failures | `success: false` with `error` | Shown in an alert |

A routine's row reads `job_id` (or `id`), `name` (the `[bot:…]` tag removed), `prompt_preview`,
`schedule`, `deliver`, `enabled`, `state`, `next_run_at`, `last_run_at`, `last_status` (`error` or
`delivery_failed` count as failed), and the first of `last_fire_error`, `last_delivery_error`,
`last_error` and `paused_reason` as the problem to show.

Not built yet:

- **Editing** a task or routine. Hermes has `PATCH /api/jobs/{id}` (name, schedule, prompt,
  deliver, skills, repeat, enabled) and `PUT /api/cron/jobs/{id}` on the backend; the app has no
  editor.
- Choosing skills, a model, where results go, or a repeat count in New Task.
- Refreshing on the `cron.changed` event; the lists refresh when opened and on pull to refresh.
- Recent runs in the iPhone task detail.

## 2. Schedules and delivery

**Schedules** Hermes accepts (`cron/jobs.py` `parse_schedule`):

| Form | Example | Kind |
|---|---|---|
| Interval | `30m`, `every 2h`, `every 1d` | Repeats |
| One-shot delay | `in 30m`, `in 2h` | Runs once |
| Day and time | `every day at 9am`, `every monday 9am`, `weekdays at 07:30` | Repeats (stored as cron) |
| Cron | `0 9 * * 1` (5–6 fields) | Repeats |
| Timestamp | `2026-11-03T14:00:00` | Runs once, in Hermes's configured time zone |

- **New Task** takes the schedule as text, with presets `in 30m`, `every 1h`, `every 1d at 09:00`
  and `0 9 * * 1`. Hermes rejects `every 1d at 09:00`: it reads `1d at 09:00` as a duration and
  answers "Invalid duration". The working form is `every day at 09:00`. The same applies to the
  sheet's default schedule and to setup's morning briefing (`every 1d at 07:30`,
  `docs/onboarding.md` §3).
- **New Routine** builds the expression from pickers: Every day (`M H * * *`), Weekdays
  (`M H * * 1-5`), Every week (`M H * * D`), Every few hours (`every Nh`), Once (`in 15m`, `30m`,
  `1h`, `3h` or `24h`), or Custom (a cron expression).
- **Showing a schedule.** The app shows `schedule_display` in words (`ScheduleText`): "Every day
  at 07:30", "Mondays at 09:00", "Every 6 hours". Hermes stores intervals as minutes ("every
  120m", shown as "Every 120 minutes"); forms the app doesn't recognise are shown as they came. Next and last runs come from
  the gateway's `next_run_at` and `last_run_at`; the app never computes them.

**Delivery** (`deliver`), comma-separated for several targets (`cron/scheduler_delivery.py`):

| Target | Meaning |
|---|---|
| `local` | Save only. The default for jobs created over the API server, so every task made in the app |
| `origin` | Back to where the job was made |
| `bot-chat`, `bot-chat:<profile>` | A turn in a Bot's chat. Routines use it ("Post results in the Bot Chat") |
| `<platform>:<chat_id>` | Telegram, Slack and the other messaging platforms |
| `apppush`, `apppush:fail` | The Hermes app, through the push plugin (`Tools/hermes-app-push`): a notification to every device, or only for failures as a job's `failure_deliver` (`docs/notifications.md`). Needs the plugin in the profile the task runs in ([plugins.md](plugins.md)) |

The task detail on iPad and Mac shows "Results go to": "Kept on the gateway" for `local`, "Where
it was made" for `origin`, else the target's platform name.

## 3. Checks

- Pause, resume, run now and delete update the list without a reload; a new task appears in
  order.
- A routine created for one Bot appears only in that Bot's routines and, with Post results in the
  Bot Chat on, posts there (try Run Now against the mock backend).
- A failed run shows "Last run failed" in the list and its error in the detail.
- On iPad and Mac, a run row opens that run's chat in Chats.

## 4. iPad and Mac

- **iPad** (regular width, `ipadTasks`): the task list (`Tasks.taskRow` with its status tags)
  beside the selected task's detail: prompt, schedule (runs, next run or Paused, where results
  go), skills, last error, then recent runs (`Tasks.runRow`, `runRowFailed`: when, how long, and
  what it said or why it failed). Pause and Run Now float in a bottom glass bar over the
  scroll-edge fade. + adds a task; the … menu deletes the selected one.
- **Mac** (`macTasks`): the same list and detail in the window. Pause (or Resume) and Run Now move
  to the toolbar, Run Now as the default button (Return); the … menu holds New Task… and Delete
  Task.
- A run row opens that run's chat. Runs without a chat can't be opened.
- The selected task is restored per window (`SceneStorage("tasks.selected")`).
- Calls are the same as §1.

On iPhone, Tasks is a list; a tap opens the detail as a sheet (prompt, schedule, skills, last error,
Run Now and Pause), swipe left for Delete and Pause, and a context menu adds Run Now.

## 5. Routines on screen

- A Bot Chat's alarm button or Routines chip, the Bot's context menu in the sidebar, or Chat →
  Routines… (⌥⌘R) opens its routines in a sheet (`macRoutines` on the Mac): the Bot's face and
  "Routines run on a schedule, even when this device is asleep.", then one row per routine.
- A row shows the title, the schedule in words, the prompt, and a status: "Last run failed" (with
  the problem), Paused, or "Runs in 2 hours"; "Posts here" when it delivers to the Bot Chat; and an
  Enabled switch.
- Swipe for Delete and Run Now; the context menu has Run Now, Pause or Resume, and Delete….
- With none: "No routines yet" and New Routine.
- New Routine: Name, "What should it do?", When (the pickers in §2), Post results in the Bot Chat,
  and the schedule in words under it. Errors appear in place and are announced.

## 6. Setup

Tasks run in the gateway's scheduler, so only while the gateway runs ([setup.md](setup.md) §4.11).
A task whose results didn't reach where they go (`last_status: delivery_failed`) is tagged Results
didn't arrive, and one whose run couldn't start (`last_fire_error`) Last run didn't start; the
detail shows Hermes's reason with what it means and the docs on delivery. `blocked_config` counts
as a failed run.
