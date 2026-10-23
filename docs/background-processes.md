# Background processes

Hermes starts processes that keep running after its turn ends: a dev server, a release build, a
test run, a log it watches, or a message to another Bot. The `terminal` tool does this with
`background: true`, and `message_agent` delivers a message to another Bot the same way.

A process lives in three places, and never piles up under the chat:

1. **In the turn that started it:** one step on the steps rail (`processStep`). It shows a plain
   name, the live state (running, finished, failed, stopped), the command and its latest line. It
   keeps its place in the history, so new messages arrive below it like any others.
2. **In the composer:** one chip after Think (`processChip`) while anything runs, has just
   finished, or has failed. It opens the Terminal.
3. **In the Inspector's Terminal tab:** the chat's processes (`processRow`), with their output
   (`processLog`) and Stop. iPhone shows it in the Inspector sheet; iPad and Mac in the panel.

Before this, every process was a card after the last turn (`ProcessCard`, removed): new messages
went in above the cards, finished ones stayed until dismissed one by one, the title was the raw
command cut in the middle, the output showed raw JSON and Hermes's `__HERMES_CWD_…__` marker, and a
tab closing (`terminal.close`) read as the process ending.

**Code:** `Packages/HermesKit/Sources/HermesKit/Processes/` holds what can be tested:
`ProcessNaming` (§2), `ProcessOutput` (§3), `BackgroundProcess` and `ProcessTracker` (§1, §4) and
`ProcessChip` (§5), with `BackgroundProcessTests`. `ConversationModel` keeps a `ProcessTracker`
(live, for the Terminal) and `processes` (what steps and the chip show). The views:
`ProcessStepLine` (`AssistantTurnView.swift`), `ProcessChipView` (`ProcessViews.swift`) and
`TerminalTabView` (`InspectorTabs.swift`). The design: `blocks/processes.elyx`,
`screens/iphone/processes.elyx`, `screens/ipad/processes.elyx`, `screens/mac/processes.elyx`, and
`chatSafety` in `screens/iphone/chat-rich.elyx`.

## 1. Gateway calls

| Need | Call | Notes |
|---|---|---|
| The chat's processes | `process.list {session_id}` | Only this chat's (rows whose `session_key` is the chat's). Per process: `session_id` (the process id, `proc_` + 12 hex), `command` (its first 200 characters), `cwd`, `pid`, `started_at` (local time, no zone: the app uses `uptime_seconds`), `status` (`running` or `exited`), `output_preview`, `output_tail` (the last 4,000 characters, raw), and once exited `exit_code`, `exited_at` (epoch) and `completion_reason` (`exited`, `killed`, `lost`, `failed_start`). `notify_on_complete` when set. Exited rows stay until a later spawn prunes them (30 min after they started, at most 64) |
| Live output | Event `agent.terminal.output {process_id, chunk}` | Raw output, ANSI included. Batched every 100 ms for the Terminal; steps and the chip catch up at most twice a second |
| It ended | `process.list` says `status: exited` | **No exit event** for most processes. The app polls `process.list` every 5 s while one runs and the chat is on screen, every 30 s while the app is in use and the chat isn't (iPhone and iPad: not in the background) |
| Hermes was told it ended | `status.update {kind: "process", text}` | Only for processes with `notify_on_complete`, watch patterns or a heartbeat. The text carries no process id: the app looks at `process.list` again. Text about a background process isn't shown (Hermes answers in its next turn); other `process` statuses ("Resuming interrupted turn…") still show as the turn's status |
| Hermes closed the Terminal tab | `terminal.close {process_id}` | **Not an exit.** The `close_terminal` tool only drops the tab; the process keeps running, in the list and the chip. If the Terminal shows that process's page, it goes back to the list |
| Stop one | `process.kill {session_id, process_id}` | `status`: `killed`, `already_exited`, or `error` (an ok result, not an RPC error); 4044 when it isn't this chat's, 4012 without an id. "Stopping…" until the list says exited; the app asks the list again at once |
| Never | `process.stop` | It stops every process on the gateway, every chat's. Never wired to anything (the mock refuses it) |
| A delivery to another Bot outlives the sender's chat | `process.list` lists `persist_on_release: true` (only when set) on `message_agent`'s runner (`… bot_mode_dm.py --run-delivery …`) | Hermes 0.22 starts it without the flag, so closing the sender's chat stops the receiving Bot's turn (upstream #134898, #136220). Each look at the list records what this Hermes version does (`DeliveryProtection`, per gateway, dropped on a new version), for Settings → Setup ([setup.md](setup.md)) |
| Which turn started it | `terminal` with `background: true`: `tool.complete`'s `result` is `{output: "Background process started", session_id, pid, exit_code: 0, error: null}`. `message_agent`: `{status: "queued", to, process_id, …}` | The app finds the id in the result (`ToolActivity.startedProcessID`), live and in stored chats. A failed start has no id and stays an ordinary failed step. A process with no matching call (started before the app connected, or by a task) shows only in the Terminal and the chip |

## 2. Naming a process

People see a name, not the command (`ProcessNaming`). After cleaning, the first rule that matches:

- **Cleaning:** drop leading `cd … &&`, `VAR=value` pairs, `nohup`, `exec` and `env`, redirections
  (`> log 2>&1`) and a trailing `&`. A JSON argv is joined into a command line first. Hermes's
  own delivery of a Bot message (`python …/bot_mode_dm.py … hermes -p <bot> chat …`) shows from
  its `hermes` part; when the list's 200 characters end before it, as `python bot_mode_dm.py
  --run-delivery …`.

| Command | Name |
|---|---|
| `npm/pnpm/yarn/bun run dev`, `vite`, `next dev`, `astro dev` | Dev server (Docs site when the script name says docs) |
| `python -m http.server`, `caddy`, `serve`, `php -S` | Web server |
| `npm test`, `swift test`, `pytest`, `go test`, `cargo test`, `xcodebuild test`, `make test` | Tests |
| `make release`, `xcodebuild archive`, `swift build -c release`, `cargo build --release` | Release build |
| Other builds (`make`, `swift build`, `cargo build`, `npm run build`, `xcodebuild`) | Build |
| `docker compose up`, `docker run` | Docker: <service or image> |
| `tail -f <file>`, `journalctl -f` | Watching <file name> (or the unit) |
| `hermes [-p <profile>] chat …`, Hermes's Bot delivery | Message to <Bot name> (the profile's display name; "a Bot" when the command was cut before it). `message_agent`'s `to` names it first |
| `hermes cron …`, `hermes gateway …` | Hermes: <subcommand> |
| Anything else | The program and its first argument when that isn't an option (`rsync backups`, `ffmpeg`), at most 24 characters; a script run by an interpreter is named for the script |

- **The command** still shows, in mono, in the step, the row and the output, cut at the **end**
  with "…", never in the middle. Home folders read `~`.

## 3. Cleaning the output

Done once per chunk, before anything is drawn or kept (`ProcessOutput`):

- ANSI escape codes go, even when a chunk ends inside one; `\r` progress lines keep their last
  state; backspaces and other control characters go.
- Lines with Hermes's working-folder marker (`__HERMES_CWD_<hex>__`) go. Hermes strips it from
  foreground output; it isn't in the background stream today, but the app strips it anyway.
- **Errors:** when the whole output is one JSON object with `error` (or `message`), that string
  shows: a leading code (`target_busy: `) dropped, the first sentence only, and `profile '<name>'`
  as the Bot's name ("Ada is busy with another message.").
- The step and the row show the latest line: the last non-empty one, on one line.
- Each process keeps its last 64,000 characters, from a line's start.

## 4. The step in the turn (`processStep`)

It sits on the steps rail where its `terminal` (or `message_agent`) call was, in place of that
call's step. A folded turn ("Worked for 1m 12s · 5 tools") keeps its process steps in view, on
their rail, under the header. The step shows the name; the state with how long ("Running · 3 min",
"Finished · 4 min", "Failed · exit 1", "Stopped · 12 min", "Stopping…"); the command (`$ …`) and
the latest line.

When a process finishes, Hermes tells the chat with a notice the app shows as one line saying which
and how ("Tests failed · exit 1", "Engineer replied"); notices in a row fold into one, and each
opens to its command and output, with Show Step back to this step ([chat.md](chat.md) §2a).

| State | From | Look |
|---|---|---|
| Running | `status: running` | Green dot, still (only the chat's live line moves, [chat.md](chat.md) §4a) |
| Finished | exited with `exit_code` 0 | Green check |
| Failed | exited with another code, or `completion_reason` `lost` / `failed_start` | Red node with ×, red label, the error line in red |
| Stopped | `completion_reason: killed` (exit −15) | Grey stop square |
| Ended | no longer listed, and nobody here saw how it ended | "Ended", no time |

- Tap: the Terminal on this process (its page). Long-press: Copy Command, Copy Output, Stop (while
  it runs).
- **Old chats:** the steps show their last known state from `process.list`, asked once the chat is
  attached. Once the gateway no longer lists one, it says "Ended".

## 5. The composer chip (`processChip`)

In the controls row after Think (or after the send-mode chip while a turn runs), part of the
composer's glass. In a Bot Chat, which has no Think, it sits next to +.

| Situation | Chip |
|---|---|
| Nothing running, nothing new | Hidden |
| One running | Dot + its name and time: "Docs site · 3 min" |
| Several running | Dot + "2 running" |
| One just finished (exit 0) | Green check + its name, for 4 s, then what still runs, or hidden |
| One or more failed | Red triangle + "1 failed", until the Terminal has shown it |

- **Tap:** the Terminal tab (iPhone: the Inspector sheet at medium height). **Long-press:** Stop
  for each running process, and Show Terminal.
- It's the first thing in the row to shrink: the label truncates at the end and never pushes the
  trailing buttons. It hides while dictating (the row becomes the dictation row).

## 6. The Terminal tab

- **One tab:** "Terminal · n" while n run, with the ink dot while a process is writing. Tabs saved
  from before (one per process) become this one.
- **The list:** running processes first, newest first, each with Stop ("Stopping…" once asked).
  The newest running one has its output open under it (`processLog`, the last 8 lines); tap
  another row to open its output instead, and the open output to see all of it. Then
  **Finished** (failed first, then newest), with Clear (iPad, Mac) or Clear Finished (iPhone).
  Clearing is per device (kept with the chat); the gateway forgets exited processes by itself.
- **One process's page:** `processHeader` (state, name, command, time, folder, pid, Stop), then
  the whole output (selectable, following the newest line, error lines in red), Copy Output, and
  **Ask Hermes About This**, which puts the last 40 lines in the composer as a quote (on iPhone
  the sheet steps aside).
- **Mac:** ⌥⌘P (Chat → Show Terminal) shows the tab. ⌘. stops the turn while one runs; with none
  running and the Terminal showing a running process (its page, or the open row), it becomes
  Stop Process… and asks first. One command: UIKit refuses two menu commands with the same keys.
- `read_terminal` (`terminal.read`) reads the process the Terminal's page shows, else the newest
  running one.

## 7. Notifications

- In the app: no banner. The chip and the step show it, with an error haptic on iPhone when a
  process fails while its chat is on screen.
- Pushes stay as [notifications.md](notifications.md) says: the plugin sends none for processes
  yet.

## 8. Motion

- **The chip** grows in from the leading edge (spring 0.3 s); its label changes with
  `.interpolate`, and counts roll (`.numericText`).
- **Finished:** the dot gives way to the check, which holds 4 s; then the chip shrinks away or goes
  back to what runs.
- **Failed:** one gentle wiggle of the triangle (`.symbolEffect(.wiggle)`).
- **The step's state** cross-fades; the running dot holds still.
- **Reduce Motion:** cross-fades only.

## 9. Accessibility

- **The step** reads "Release build, running for 3 minutes, make release, latest: Signing
  Hermes.app", with the actions Show Output, Copy Command and Stop (while it runs).
- **The chip:** "2 background processes running", hint "Shows the Terminal"; failed: "1 background
  process failed".
- **Never colour alone:** the dot, check, ×, triangle and square, always with words.

## 10. Acceptance checks

Against `Tools/mock-hermes` ("release" with "docs", or "processes"; "trailhead" or "deploy log";
[development.md](development.md)):

- A chat with two running processes shows them as steps in their turn and "2 running" in the
  composer. New messages appear below the steps, never between a process and the composer
  (`ProcessesUITests`).
- When a process exits with no event, the step and the chip update within 5 s while the chat is
  open.
- `terminal.close` doesn't end a process (the mock closes the Docs site's tab mid-build).
- A failed process shows its error in plain words, never raw JSON. No `__HERMES_CWD_` text shows
  anywhere.
- A finished process clears from the chip after 4 s and stays in the Terminal under Finished until
  cleared.
- Stop calls `process.kill` for that process only.
- `hermes -p engineer chat …` is named "Message to Engineer".
- Light, dark and Increase Contrast match the Elyx renders, on iPhone, iPad and Mac.

## 11. Setup

Nothing to set up: processes come with the chat. Their output and Stop go through Bot Mode like the
rest of the Inspector ([setup.md](setup.md) §4.1).
