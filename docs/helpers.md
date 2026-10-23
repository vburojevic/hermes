# Helpers (sub-agents and parallel work)

Hermes can split a task across delegated children (`delegate_task`) that run in parallel, and a
child can have children of its own when `delegation.max_spawn_depth` is 2 or more (the default is
1: no nested helpers). The app calls them **helpers**. The person can see each one live, steer or
stop it, stop Hermes from starting more, and reopen a finished run.

This doc covers the Hermes calls and events behind helpers, the team card in the chat, the Team
tab, one helper's detail, and what to check. Helpers need Bot Mode: their calls and events go over
the backend's JSON-RPC socket.

The code lives in `Packages/HermesKit/Sources/HermesKit/Helpers/` (`HelperTracker`, the pure state
machine; `HelpersClient`; `HelperModels`), `App/Model/HelperStore.swift` (one per chat, owned by
its `ConversationModel`) and `App/Views/Helpers/`. The mock is `Tools/mock-hermes/helpers.py`; its
chat triggers and debug flags are in [development.md](development.md).

Design component names: `helperBadge*`, `helperRow*` (running, done, failed, waiting), `teamCard`,
`teamSummary`, `helperCard*`, `nestedHelperRow*`, `helperHeader`, `metricTile`, `helperTranscript`,
`helperDetail`, `helperSteer`, `macTeamInspector`.

## 1. Data

Hermes names come from the gateway source: `tui_gateway/contracts/events.py`
(`SubagentEventPayload`), `methods_subagents.py` (`subagent.list`, `subagent.interrupt`,
`subagent.tail`) and `methods_session.py` (`delegation.status`, `delegation.pause`,
`subagent.steer`, `spawn_tree.*`).

| Need | Source | Fields used |
|---|---|---|
| The delegation | `tool.start` / `tool.complete` of `delegate_task` in the parent turn | The result: `{status: "dispatched", delegation_id, goals[], subagent_ids[], count}`. Helpers it names that haven't started yet show as waiting |
| Helper appears | `subagent.start` | `subagent_id` (`sa-<index>-<hex>`), `parent_id`, `depth`, `goal`, `task_index` (0-based) / `task_count`, `model`, `delegation_id`, `child_session_id` |
| Live line, tools | `subagent.tool`, `subagent.progress` | `tool_name`, `tool_preview`, `tool_count` |
| Thinking | `subagent.thinking` | `text`; a running row's live line when no tool is running, and part of the saved tree |
| Finished | `subagent.complete` | `status` (completed / failed / error / timeout / interrupted), `summary`, `text` (the reason when it failed), `duration_seconds`, `input_tokens`, `output_tokens`, `reasoning_tokens`, `api_calls`, `files_read`, `files_written`, `output_tail[]` (`tool`, `preview`, `is_error`) |
| Snapshot on open or resume | `subagent.list {session_id}` | `subagents[]`: live helpers (`status`, `started_at`, `tool_count`, `last_tool`, `accepting_steer`); `delegations[]`: failed background delegations of the last day (`delegation_id`, `task_index`, `goal`, `status`, `error`, `dispatched_at`, `completed_at`) |
| Live transcript | `subagent.tail {session_id, subagent_id}` | `available`, `text` (the last 16 KB, may start mid-line), `truncated`. Polled every 2 s while a live helper's detail is open |
| Stop or cancel one | `subagent.interrupt {session_id, subagent_id}` | `found: false` means it had already finished: the app says "It had already finished." |
| Steer one | `subagent.steer {session_id, subagent_id, text}` | `status`: `queued` or `rejected` (§4) |
| Pause new helpers | `delegation.pause {paused}`, `delegation.status` | `paused`, `max_concurrent_children` (default 10), `max_spawn_depth`, `active[]` |
| A finished run | `spawn_tree.save`, `spawn_tree.list {session_id, limit: 50}`, `spawn_tree.load {path}` | §1.2 |

`session_id` in `subagent.*` calls is the parent's **runtime** session, and the socket that owns
it must make the call (4001 "session not found or not owned by this transport" otherwise).
`delegation.*` and `spawn_tree.*` are gateway-wide and take no profile. Unknown parameters are
rejected (4000). A gateway without `subagent.list` (-32601) simply has no snapshot.

**Waiting:** a helper the delegation named that hasn't started yet, usually because
`max_concurrent_children` are already running, shows "Waiting for a free slot".

### 1.1 What the real gateway does

- Top-level `delegate_task` runs in the **background**. The call returns `dispatched` at once and
  the turn ends; `subagent.*` events keep arriving on the parent's session; the results come back
  as a new turn that starts with an `async_delegation_complete` row. It reads as the helpers it
  names and how they did ("2 helpers finished: Research pricing pages, Review the draft · 1
  failed"), opening to each one's goal and result ([chat.md](chat.md) §2a).
- `subagent.*` events carry no timestamps; the app stamps arrival. Falsy keys are left out, not
  sent as `null`.
- Nested helpers report only `start` and `complete` (Hermes relays nothing else from depth 1).
- `subagent.spawn_requested` is built by Hermes but dropped by its relay, so it never reaches
  clients. The app handles it (only the mock sends it); the waiting state comes from the
  delegation result instead.
- A waiting helper isn't in `subagent.list` (it is registered once it runs). After a snapshot,
  helpers the app thought live that aren't listed are marked "Finished" (they ended while nobody
  watched), and waiting helpers of a team with nothing listed stop waiting too.
- `queued` from `subagent.steer` isn't "delivered". There is no `missed_steer` event: a helper that
  finished before reading a note gets "[steer did not land — …: <text>]" appended to its summary.
  The app strips that note from the summary it shows and marks the note missed (§4).
- `delegation.pause` is process-wide on the gateway and isn't saved.

### 1.2 Spawn trees

Hermes never saves spawn trees itself (the TUI saves its own). The app saves each team when it
finishes, with `spawn_tree.save {subagents, session_id, label, started_at, finished_at}`:

- `subagents` uses the TUI's `SubagentProgress` rows (camelCase: `id`, `goal`, `status`, `depth`,
  `parentId`, `index`, `taskCount`, `toolCount`, `summary`, `outputTail`, …), so trees the app
  saves open in the TUI's tree viewer and the other way round.
- `session_id` is the chat's stored session id and `label` is the delegation id, so a past turn
  finds its run again after a restart.
- A team known only from `subagent.list`'s failed delegations (`isPartial`) is never saved: it
  would overwrite the full tree. A team where some helpers ended unseen is saved only when no
  record of it exists yet (another device may have watched it to the end).

Past turns list the chat's trees once (`spawn_tree.list`), keep the fullest record per label (then
the newest), and load one with `spawn_tree.load` when it comes on screen. A saved tree is over:
any helper still marked live in it reads as stopped.

## 2. In the chat

- **Team card** (`teamCard`) in the turn, where the delegation happened, after any narration.
  Teams no `delegate_task` in the transcript claims (events seen before the call returned, or a
  chat opened mid-run) show with the latest reply.
  - Header: "4 helpers · 1 running" and "1 of 4 done".
  - One `helperRow` per helper, in `task_index` order: badge number (ink while running, grey
    otherwise), goal, a live line (the current tool in mono while running, or its latest thinking;
    the summary when done; the reason in red when failed; "Waiting for a free slot"), and the
    state (elapsed time counting up while running, ✓ + duration, ✕ + duration, hourglass). No
    spinner: the turn header is the turn's one live line ([chat.md](chat.md) §4a).
  - Footer "Open Team" opens the Team tab; tapping a row opens that helper.
  - More than 5 helpers: the running ones first, then "+N more".
- **When the team is done**, the card folds into `teamSummary`: "Worked with 4 helpers · 6 min",
  with a red "1 failed" tag if any failed. It folds when every helper has finished and the turn
  has ended; because delegation runs in the background (§1.1), that is usually well after the
  dispatching turn ended. Tapping it opens the Team tab of that run, loaded from its saved tree
  when it is no longer live. A past run with no saved tree (the app wasn't open for it) shows the
  summary from the stored `delegate_task` result, disabled.
- The turn header reads "Working with 4 helpers…" while any helper runs.
- Updates are coalesced: the views see helper state at most every 0.25 s, so ten busy helpers
  don't redraw the transcript on every tool.

## 3. Team page (iPhone, iPad) and Team inspector (Mac)

The Team is a tab of the Inspector (§7a): beside the chat on Mac and iPad landscape, in the
Inspector's sheet on iPhone and iPad portrait. Chat → Show Team / Hide Team (⌥⌘T) toggles it for
the chat's latest team.

- **Team** ("Team · 4 helpers"): "Hermes can start more helpers" at the top (`delegation.pause`),
  with the footer "Turn off to stop new helpers on <gateway>; running ones finish. Up to 10 run at
  once." Then sections Running, Waiting and Finished, each with its count.
- **Opening a helper:** on iPhone (compact width), a helper tapped in the team card pushes its own
  page onto the chat (`helperDetail`, with its own composer for Steer). On iPad and Mac, and from
  the Team tab everywhere, the helper opens inside the Team tab, with a back row to the team.
- **`helperCard`:** badge, goal, status line, metrics line (model, tools, tokens, files read), the
  last three tool lines in mono, then Stop (red) and Steer… (secondary).
  - Done: the summary replaces the tail, and files written appear as file chips. No actions.
  - Failed: the tail ends with the error in red, and "Ask Hermes to Retry" sends the parent chat
    "Retry helper 3: <goal>". The gateway has no retry call. Only top-level helpers offer it.
  - Waiting: only Cancel (`subagent.interrupt`).
  - Notes the helper never read show on its card (§4).
- **Nested:** a helper leading others shows them indented under its card with a tree line
  (`nestedHelperRow`, numbered 1.1, 1.2…), and its status reads "Running · leading 3 helpers".

## 4. One helper

- `helperDetail`: `helperHeader` with "Helper 1 of 4" and a status tag ("Running · 1:42", "Done ·
  0:58", "Waiting", "Stopped", "Timed out", "Failed"), the goal as the title, and four metric tiles:
  model, tools, tokens, files read. Hermes reports tokens and files only when a helper finishes;
  until then they read "—".
- Below it, `helperTranscript` ("What it's doing", or "What it did" once it ends, with a Live tag
  while it streams) shows `subagent.tail` in mono, newest at the bottom, following the newest line
  unless the person scrolls up. Hermes lets the transcript go when a helper ends, so a finished or
  waiting helper shows what the events said instead (its last tools, then the summary or the
  failure; "It starts when a slot is free.").
- Stop (glass, red) and Steer (ink) float in a bottom glass bar; a waiting helper has Cancel, a
  failed top-level one Ask Hermes to Retry. The page's … menu has Copy Transcript, Copy Goal, Open
  Team, and Stop Helper / Cancel Helper.
- **Steer** (`helperSteer`): the composer shows a strip "To helper 1 · it reads this after its
  current step" (placeholder "Note for helper 1") and sends with `subagent.steer`. The note then
  shows in the helper's transcript the way a steer shows in the main chat (`docs/follow-ups.md`):
  "To helper 1 · waiting for its next step", then "To helper 1 · read" once the helper takes its
  next step.
- A note is **missed** when the gateway answers `rejected`, when the helper finishes while the
  note is still waiting, or when its summary says the steer didn't land. It then shows
  `steerMissed` titled "Helper 1 finished before reading your note", with **Send to Hermes** (the
  note goes to the parent chat as a message) and Discard.
- Steer is hidden when `accepting_steer` is false, after a rejection, and once the helper has
  finished.

## 5. Elsewhere

- Not built yet: the Live Activity step line "4 helpers · 1 running" (`docs/notifications.md`).
  Because delegation runs in the background (§1.1), the dispatching turn's Live Activity ends
  before the helpers do; showing it needs a change on the gateway side.
- Notifications: helpers send none of their own. The turn that brings their results back is a
  normal reply.

## 6. Accessibility

- A helper row reads "Helper 1 of 4, Audit the app targets for strict concurrency, running,
  1 minute 42" (waiting: "waiting for a free slot"; done; stopped).
- Live lines update for VoiceOver at most every 2 s, with `.updatesFrequently`; a finished helper's
  line holds still.
- Stop on a helper asks for confirmation only if it has written files (a write tool such as
  `write_file` or `patch` ran): "Stop helper 1?", "It has written files. What it wrote so far
  stays."

## 7. Acceptance checks

- The team card matches `subagent.*` events live, in `task_index` order, with correct states
  including waiting and every terminal status.
- The card stays live after the dispatching turn ends, and folds only when the team is done.
- Stop, Steer and Pause call the right methods and the UI reflects the results (`found: false`,
  `rejected`, a steer that didn't land).
- A finished turn's Team opens from the saved spawn tree after the app restarts.
- Reopening a chat whose helpers finished while the app was away shows them finished, and never
  overwrites the saved tree with a partial one.
- Nested helpers render at depth 2 without breaking the numbering.
- Light, dark and Increase Contrast render correctly.

## 7a. In the Inspector

The Team inspector is the **Team** tab of the Inspector (`docs/inspector.md`). It opens from the
team card, its summary, Open Team, ⌥⌘T, or the Inspector's + menu (which offers "Team" with "2
helpers working" or the team size). Closing the tab clears the shown team and helper.

## 8. iPad

The Team tab docks on the right of the chat in landscape, as on the Mac, with the same rows, Stop /
Steer and the pause switch; in portrait it is in the Inspector's sheet. A full-screen iPad has regular width in
both orientations, so a helper opens inside the Team tab there, and Steer uses the chat's
composer; in compact width (Split View, Slide Over) it pushes its own page, as on iPhone.

## 9. Setup

Helpers need Bot Mode ([setup.md](setup.md) §4.1).
