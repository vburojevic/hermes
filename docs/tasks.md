# Tasks and Routines

Both are Hermes **cron jobs**: a prompt Hermes runs on a schedule, each run in a chat of its own.

- **Tasks** (Tasks in the sidebar, ⇧⌘1) are the gateway's jobs, read and changed over the API
  server.
- **Routines** belong to a Bot: jobs created in the Bot's profile, usually posting their results
  into its Bot Chat. They need Bot Mode and go over the backend's socket.

This document covers the calls behind each, the schedules and delivery targets Hermes understands,
and the layouts on each device. Design components: `Tasks.taskRow`, `Tasks.runRow`, `runRowFailed`,
`runRowRunning`, `tasks`, `taskDetail`, `newTask`, `ipadTasks`, `macTasks`, `macNewTask` and the
Mac's `macRoutines` sheet.

## 1. Calls

**Tasks** (`HermesClient`, Bearer `API_SERVER_KEY`, `docs/connecting-and-voice.md` §1):

| Action | Call | Notes |
|---|---|---|
| Tasks list | `GET /api/jobs?include_disabled=true` | Paused jobs only appear with `include_disabled`. Sorted active first by next run, paused last. Loaded when Tasks opens, again whenever the gateway comes online (Tasks opened before it connected, a reconnect, a new address), and on pull to refresh or Try Again. One read at a time: a new one replaces the read on its way, so the newest answer stands. Offline with nothing loaded, the list says why it couldn't load |
| New Task | `POST /api/jobs {name, schedule, prompt}` | Name, prompt and schedule are required. Hermes allows a name up to 200 characters and a prompt up to 5000, and sets `deliver: local` when none is given. Create closes the sheet at once; the task shows in the list, tagged "Adding…", until the gateway's job replaces it. A refusal (an invalid schedule) takes the row away and says why, with Edit Task to open New Task again with what was typed |
| Pause / Resume | `POST /api/jobs/{id}/pause`, `…/resume` | The row moves at once (Paused, or back among the active ones) and the job in the answer settles it, next run included. A refusal puts it back and says so |
| Run Now | `POST /api/jobs/{id}/run` | Hermes only marks the task due (`trigger_job` sets `next_run_at` and `manual_run_at` to now); its scheduler starts the run at its next tick, within a minute. VoiceOver hears "<task> started" once the gateway takes it, and the row says "Starting…" until the list shows the run: Tasks reads the list every 5 s until the run is under way, has finished, or couldn't start (`last_fire_error`), for up to 75 s |
| Running now | `live_execution` on the job (`status` `claimed` or `running`, `started_at`, else `claimed_at`) | Hermes has no running state for a job: a run in progress is a live execution row. The row says "Running now · 24 s" in a line that shimmers and counts up, and the detail's Recent runs leads with it ("Running now", a clock). While any task runs, the list is read every 10 s, so the line ends when the run does. A recurring task counts the run when it finishes, a finite one when it starts (`claim_dispatch`), so the run going on is counted once |
| Delete | `DELETE /api/jobs/{id}` | Asks first, in one alert ("Delete “<task>”?", "Hermes won't run it again."), from every place that deletes: swipe, the row's menu, the … menu and VoiceOver. Then removed from the list at once, and put back if the call fails |
| Recent runs | `GET /api/cron/jobs/{id}/runs?limit=100&profile?` | On the backend, so only with Bot Mode connected, in the task's detail on every device (§4). Each agent run is a chat with id `cron_<jobId>_<timestamp>` and source `cron`; script-only runs have output but no chat. Hermes's most (100), because most runs of a frequent task say nothing: runs with no messages, no output and no error are left out, and the rest show newest first (`ScheduledRuns.shown`, §5) |
| Open a run | `GET /api/sessions/{id}/messages` | The run opens in Chats like any other chat, and can be continued. It isn't listed among the chats: a run is found under Show → Scheduled Tasks, here, and Search's Tasks filter ([inbox.md](inbox.md) §5) |
| Last run failed | `state: error`, or `last_status` `error` or `blocked_config`, and `last_error` | A red tag in the list, the error in the detail |
| Results didn't arrive | `last_status: delivery_failed`, `last_delivery_error` | An orange tag in the list; the reason in the detail, with what it means (§6) |
| Last run didn't start | `last_fire_error.detail` (cleared by the next run that works) | An orange tag in the list; the reason in the detail (§6) |

Fields the app reads from a job (`CronJob`): `id`, `name`, `prompt`, `schedule_display` (else
`schedule.display`), `skills`, `enabled`, `state`, `paused_reason`, `created_at`, `next_run_at`,
`last_run_at`, `last_status`, `last_error`, `last_delivery_error`, `last_fire_error.detail`,
`deliver`, `model` (blank or absent means the gateway's default), `live_execution` (above), and
`repeat.times` / `repeat.completed`.

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
- Refreshing on the `cron.changed` event; the lists refresh when opened, when the gateway comes
  online and on pull to refresh.

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

- Pause, resume, run now and delete update the list without a reload, at once, on a slow gateway
  too (`--starve 5-30`): no spinner, and a list read from before the change doesn't undo it. A new
  task appears as New Task closes, then settles in order. Changes the gateway refuses go back with
  a note saying what was put back and why (`PendingChanges`, `docs/chat.md` §4a).
- A routine created for one Bot appears only in that Bot's routines and, with Post results in the
  Bot Chat on, posts there (try Run Now against the mock backend).
- A failed run shows "Last run failed" in the list and its error in the detail.
- Open Tasks with the gateway stopped ("Couldn't load tasks"), then start it: the list fills in
  by itself once the gateway connects, with no pull to refresh.
- On every device, a run row opens that run's chat in Chats.
- Run Now (or the mock's `--running-task`): the row says "Starting…" until the mock's scheduler
  starts the run (8 s on), then "Running now", counting up; the detail's Recent runs leads with
  the run, and both end by themselves when the run does. Nothing else on
  the screen moves; with Reduce Motion the line is still.
- Delete asks first, from swipe, both menus and VoiceOver's actions; Cancel leaves the task.
- At the largest accessibility text size the rows drop the icon tile and wrap, the detail's labels
  sit above their values, and Pause and Run Now stack full width.
- On the Mac, ⌘N opens New Task while Tasks is showing (File → New Task); Return in New Task
  creates the task and Escape cancels it.
- A Bot's Routines → Past runs (mock backend: Research Buddy) lists the digest, the MLX watch and the failed
  reading list newest first, with no empty run and no chevron; tapping the digest expands its whole
  reply, and the context menu copies it.

## 4. iPad and Mac

- **iPad** (regular width, `ipadTasks`): the task list (`Tasks.taskRow` with its status tags)
  beside the selected task's detail: prompt, schedule (runs, next run or Paused, where results
  go, and the model when the task names one), skills, last error, then recent runs
  (`Tasks.runRow`, `runRowFailed`, `runRowRunning`: when, how long, and what it said or why it
  failed). Pause and Run Now float in a bottom glass bar over the scroll-edge fade. + adds a task
  and sits over the list, after the sidebar button; the … menu deletes the selected one. With the
  sidebar hidden (portrait), the sidebar button sits top left, as in a chat, and the page's
  actions top right.
- The list takes half the room, between 240 and 360 pt, so the detail keeps its share in a narrow
  window (the iPad with its sidebar beside it). The rows select; they have no chevron.
- **Mac** (`macTasks`): the list, 340 pt wide (down to 240 pt in a narrow window, so the detail
  keeps its share), beside the detail. Rows select, light up under the
  pointer, and have no chevron. + (New Task, ⌘N) leads the toolbar, with no tasks too (loading,
  empty or not loaded, `macTasksEmpty`); Pause (or Resume), Run Now
  (the default button, Return) and the … menu (New Task…, Delete Task) follow it at the trailing
  end. New Task (`macNewTask`) is a form with its labels on the left, Name, Prompt and Schedule
  with its presets, Cancel and Create (Return) at the bottom, 460 to 520 pt wide and as tall as
  what it holds.
- On the Mac the first read draws the split already: skeleton rows in the list, the detail empty
  beside it (`macTasksLoading`).
- Each row has a menu (right-click, or touch and hold): Run Now, Pause or Resume, Delete. VoiceOver
  offers the same as actions on the row.
- A run row opens that run's chat. Runs without a chat can't be opened. Runs that said nothing
  aren't listed (§5).
- The selected task is restored per window (`SceneStorage("tasks.selected")`).
- Calls are the same as §1.

On iPhone (`tasks`, `taskDetail`), Tasks is a list; a tap pushes the task's detail (prompt,
schedule with runs, next run, last run and completed runs, skills, last error, then Recent runs as
on iPad and Mac), with Pause and Run Now in a bottom glass bar and Delete Task in the … menu. Swipe
left for Delete and Pause; the row's menu has Run Now, Pause and Delete. A run tapped there opens in
Chats. New Task (`newTask`) is a sheet with Cancel (×) and Create.

At accessibility text sizes (`tasksAx5`, `taskDetailAx5`) the rows drop their icon tile and wrap,
the detail's labels sit above their values, and Pause and Run Now stack full width.

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
  and the schedule in words under it. Save goes straight back to the list, where the routine shows
  "Adding…" until the gateway has made it. A refusal is announced and offers Edit Routine, which
  opens New Routine again with everything as it was.
- The Enabled switch, Pause, Resume and Delete show at once and settle when the gateway answers;
  Run Now shows "Starting…". A refusal puts the row back and says so ([chat.md](chat.md) §4a).
- **A routine's runs** (`ScheduledRuns`): Hermes makes a chat for every run, source `cron`, so a
  routine every 10 minutes makes 144 a day, most of them empty. A run with nothing in it shows
  nowhere. A run with something in it has two homes: Show → Scheduled Tasks in the chat list, and
  its task's recent runs (§4), newest first. Everything else that lists or counts
  chats leaves runs out ([inbox.md](inbox.md) §5).
- **Past runs** (`routineRuns`), a row under the routines: every routine's runs that said
  something, newest first, merged from each routine's `GET /api/cron/jobs/{id}/runs` (at most
  100 each). A row shows the routine, when it ran, how long it took, and what it said or its error,
  with "Tap a run to read all of it. Results post in the Bot Chat when the routine sends them
  there." under them. Hermes's row previews the prompt, so each row reads its run's reply from the
  run's chat as it shows (`ScheduledRuns.reply`), with a placeholder meanwhile.
- **A Bot's runs read in place; they don't open as chats.** Hermes runs a Bot's routine in the
  Bot's own profile and keeps the run's chat there (each row says `profile`). The app opens chats
  only through the gateway's profile, which can't open another profile's, so a run that would open
  would land on a chat that isn't there. Tapping one expands its whole reply in place, Copy is in
  its context menu, and it has no chevron. A run the gateway's own profile keeps (an older Hermes
  runs every Bot's routines there) opens as a chat, like a task's run (`CronRun.opensAsChat`).

## 6. Setup

Tasks run in the gateway's scheduler, so only while the gateway runs ([setup.md](setup.md) §4.11).
A task whose results didn't reach where they go (`last_status: delivery_failed`) is tagged Results
didn't arrive, and one whose run couldn't start (`last_fire_error`) Last run didn't start; the
detail shows Hermes's reason with what it means and the docs on delivery. `blocked_config` counts
as a failed run.
