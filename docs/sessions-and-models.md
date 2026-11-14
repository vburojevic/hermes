# Chats, models and background processes

This document covers the chat list (the sidebar on iPad and Mac, the first screen on iPhone), the chat
and message menus, context use and compacting, the model picker and reasoning level, and the card
for background processes. For each action it names the Hermes call the app makes. Design component
names (`sessionMenu`, `replyMenu`, `contextNotice`…) are in backticks so code and
design can be matched.

**Two transports.** The chat list and each chat's metadata always come from the gateway's API
server (`HermesClient`, REST under `/api/sessions`). Turns run over the API server's detached runs
(`/v1/runs`) unless the gateway has Bot Mode linked and its socket is connected; then normal chats
run over the backend's JSON-RPC socket (`GatewaySocket`, `prompt.submit`), which is also the only
place commands, branching from a point, compacting and background processes exist. In the code this
is `ConversationModel.usesGateway`. See `docs/connecting-and-voice.md` §1.

**Two ids per chat.**

- On the API server a chat's row id (`HermesSession.id`) changes when Hermes compresses the chat.
  `_lineage_root_id` stays the same, so the app keys chats by `stableID` (the lineage root, else
  the id).
- On the socket, `session.create` and `session.resume` return a runtime `session_id` (8 hex
  characters) and the stored id (`stored_session_id`). Resume takes the stored id; turns,
  interrupts, steers, commands and process calls take the runtime id. When the backend has
  forgotten a runtime id (error 4001, after a restart), the app resumes again and resends.

## 1. Chat list and lifecycle

A chat's menu (`sessionMenu`) is its context menu in the list: Rename…, Pin, Move to Project…,
Branch, Checkpoints…, Copy Session ID and Delete…. Rows also have the system's swipe actions on
every platform (Read / Unread and Pin leading, Mute and Archive trailing; `docs/inbox.md` §5). On
iPhone the list is the first screen and a chat pushes over it, with the system back button and
swipe back; on iPad and the Mac it is the sidebar beside the chat (`docs/design-to-swiftui.md` §6).

| Action | Call | Notes |
|---|---|---|
| Chat list | `GET /api/sessions?limit&offset` | Refreshes ask for at least 50 rows (more once the list has grown, at most 200); scrolling to the end loads 50 more while `has_more`. Pinned rows are back-filled outside the page. Rows with `is_internal_child` are left out, and Hermes leaves out archived ones. Refreshed on connect, when the app comes to the front, on pull to refresh, after `sessions.changed` (at most every 3 s), and every 15 s while the list is on screen without Bot Mode |
| Order | local | Pinned first, then by activity, newest first; no date sections (`BotWorkspace.inboxSessions`). Chats that belong to a project are left out of the list unless pinned, an Only filter is on or Show is Other Platforms or Scheduled Tasks (`docs/projects.md` §2) |
| Which chats | local | By the row's `source` (`SessionOrigin`): the list starts with this app's chats (no source, `api_server`, `desktop`, `hermes_app`) and the ones the person pinned. The filter's Show section picks All Chats, Other Platforms (`cli`, `tui`, `telegram`, `discord`, `acp`, `kanban`…) or Scheduled Tasks (`cron`) instead (`docs/inbox.md` §5). Search finds every chat |
| Row | local | Two lines: title and time, then the last message or what's happening, then what's new (count, dot, needs-you hand). Read state, counts, the activity line, filters and swipes: `docs/inbox.md` |
| Read state | The dashboard's `GET /api/sessions?order=recent` | `unread`, `last_read_at` and `last_active` are only on the dashboard's rows (Bot Mode); without it the device keeps its own watermarks (`docs/inbox.md` §1) |
| Mark as Read / Unread | `PATCH /api/sessions/{id} {unread}` | One mark per chat, shared by every device; menu, leading swipe, ⇧⌘U (`docs/inbox.md` §1) |
| Mute | none | On the device, per gateway, with an end (`docs/inbox.md` §1) |
| Archive | `PATCH /api/sessions/{id} {archived: true}` | Trailing swipe (and the Mac's menu), with Undo for 5 s |
| Prefetch | `GET /api/sessions/{id}/messages` | The three most recent chats are fetched ahead into the on-device transcript cache, once per launch, two seconds after the list loads, and not in Low Power Mode |
| New Chat (⌘N) | nothing until the first send | API server: `POST /api/sessions {source: "api_server"}`, then the run. Gateway: `session.create {source: "desktop", idempotency_key, profile?, model?, provider?, reasoning_effort?, cwd?}`. A project's chat passes its folder as `cwd` (`docs/projects.md` §3). `source: "desktop"` gives Hermes its Inspector tools (`docs/inspector.md` §2) |
| Open a chat | `GET /api/sessions/{id}/messages?limit=150&offset=0&order=latest` | With rows already shown or cached, `limit=24` instead: what's new, put after them (`SessionTranscript.catchUpPage`), followed by bigger pages until it meets them. A busy Mac answers it much sooner. Earlier pages load 200 at a time while scrolling up. A Bot Chat reads the backend's copy instead (`GET /api/sessions/{id}/messages?profile&include_compacted=true`). Over the gateway the chat is also attached with `session.resume {session_id: <stored id>, omit_messages: true, profile?, source: "desktop"}` |
| What the resume snapshot gives | | The runtime `session_id`, `running` (a turn this device didn't start shows as live, with its message from `inflight.user`, its start from `turn_started_at` and the reply so far: `docs/chat.md` §2), `info` (folder, branch, project), the prompt Hermes holds for the next turn, `pending_connection`, and `open_requests` (approvals and questions still waiting) |
| Reconnect | `session.events.since {session_id, last_seen}` | After the socket drops, the chat resumes and replays the events it missed before applying new ones. With no turn running it reloads the transcript instead |
| Window restore | `SceneStorage("window.selection")` | Each window reopens on what it showed. There is no "open last chat" call |
| Rename… | `PATCH /api/sessions/{id} {title}` | Trimmed, at most 100 characters; an empty title clears it. `/title <text>` does the same |
| Auto-titles | `session.title` event, or a refetch | Over the gateway, the event triggers `GET /api/sessions/{id}`. Over the API server the app refetches the row 0.3 s and 6 s after each turn, because Hermes writes a quick title and then a better one without announcing either |
| Pin / Unpin | `PATCH /api/sessions/{id} {pinned}` | Shown at once and reverted if the call fails. Context menu, and the leading swipe |
| Move to Project… | see `docs/projects.md` | Only with projects (Bot Mode) |
| Branch | `POST /api/sessions/{id}/fork` | The whole chat. Hermes ends the original with `end_reason: branched`. Hidden when `/v1/capabilities` says `session_fork: false` |
| Checkpoints… | see `docs/checkpoints.md` | Only while Bot Mode is connected |
| Copy Session ID | local | |
| Delete… | `DELETE /api/sessions/{id}` | After "The conversation is removed from Hermes on every device." Hermes answers 409 `session_active_turn` while a turn runs in it. The app also drops the chat's cached transcript |
| Stop | API server: `POST /v1/runs/{run_id}/stop`. Gateway: `session.interrupt {session_id}` | A run that is still queued answers 409; the app asks again every second, up to 12 times. If no end arrives, the app stops waiting after 15 s (API server) or marks the turn stopped after 12 s (gateway) |

Not built yet:

- **Archive.** Rows decode `archived` and `HermesClient.setSessionFlags(archived:)` exists, but no
  control uses them.
- **Hiding chats.** Chats have no Hide; Bots are hidden through their profile
  (`docs/bots-groups-skills.md`).

**Bot Chats** are one continuous chat per Bot. The app finds it with `session.list {profile,
title: "Bot Chat", include_hidden: true, limit: 200}` and, if there is none, creates it with
`session.create {profile, title: "Bot Chat", hidden: true, follow_profile_config: true}`. A lookup
error never creates a second one. Bot Chats can't be branched, and `/new` compacts them instead of
starting over (§3). See `docs/bots-groups-skills.md`.

## 2. Message actions

The message menus are `Overlays.userMessageMenu` and `Overlays.replyMenu`. A message that hasn't
reached Hermes yet offers only Copy and Share.

| Menu | Items |
|---|---|
| Your message | Reply, Copy (the plain form: `@writer`, `@file:path`, `/skill` prefixes), Edit and Resend, Send Again, Branch from Here, Share |
| A reply | Reply, Reply to Words…, Copy, Listen (the Bot's voice), Share…, Try Again and Try Again with… (newest reply only), Branch from Here, Undo File Changes… (`docs/checkpoints.md`), Show Usage. Reply with a quote: `docs/inbox.md` §4 |

| Action | Call | Notes |
|---|---|---|
| **Edit and Resend** (a new chat with the edited message; the original is kept) | `session.branch {session_id: <runtime id>, count, idempotency_key, omit_messages: true}` | Gateway only. The app first loads every earlier page, then counts the stored user and assistant rows with text before the edited message. The result's `stored_session_id` and `title` open the branch, and the edited text is sent once it has loaded. If branching fails, the text goes back to the composer |
| **Branch from Here** | `session.branch` as above | `count` runs to the end of that exchange (up to the next message from the person). Without the gateway, the reply menu's Branch from Here forks the whole chat (`POST /api/sessions/{id}/fork`) and your message's menu doesn't offer it |
| **Send Again** | a new turn | The same text, images and skills. Held in the queue if a turn is running |
| **Try Again** | a new turn | Sends the last message sent from this device again, or, in a chat opened from history, the chat's last message from the person (as text). The earlier reply stays; nothing is truncated |
| **Try Again with…** | sets the chat's model, then Try Again | Up to eight models: each usable provider's featured models (else its first four) |
| Listen | backend | `WS /api/audio/speak-stream?profile=` (the device's voice when there's none) |

Not built yet: truncating retries (`prompt.submit {truncate_before_row_id, confirm_truncate}` or
`session.undo {intent: "retry"}`) and reactions. Undo for files uses `session.undo {intent:
"undo"}` (`docs/checkpoints.md`).

## 3. Context, compacting, usage, goal

| Action | Call | Notes |
|---|---|---|
| Usage | the turn's `usage` | Over the gateway, `message.complete` carries `input`, `output`, `total`, `cost_usd`, `context_used`, `context_max` and `context_percent`. API server runs report token counts only. Show Usage in the reply menu opens the usage footer (a setting shows it under every reply) |
| "This chat is 86% full" (`contextNotice`) | `context_percent` of the newest reply | Shown under the newest finished reply at 80% or more, so only for gateway turns. Its Compact button runs `/compress` |
| Compact (normal chat) | `slash.exec {session_id, command: "compress"}` | Like any gateway command, it shows a command card with Hermes's answer. `/compact` is an alias |
| Compact Chat (Bot Chat) | `session.compress {session_id}` | From the Bot's … menu, `/compact`, `/compress`, `/new` or `/reset`. Waits up to 300 s, reloads the transcript and shows `summary.headline` as a quiet line |
| `/status` and other gateway commands | `slash.exec`, else `command.dispatch` | See `docs/commands-and-references.md`. Without the gateway, a command card says it runs over Bot Mode |
| Goal bar | `/goal <text>` runs on the gateway; ✕ sends `slash.exec {command: "goal clear"}` | The bar shows what was set on this device, stored per chat in `UserDefaults`. `/goal clear`, `stop`, `off` or `done` clears it |

Not built yet:

- The context breakdown (`session.context_breakdown`).
- Reading the gateway's goal state (`session.control.read`, the `session.control.update` event).
  The bar doesn't know about goals set elsewhere.
- Exporting a whole chat. Share on a message shares that message's text.

## 4. Model picker and provider keys

The chat's title is the model picker (`modelPicker`): the chosen model, else the model the chat's
row reports, else the gateway default, else the gateway's name. iPhone and iPad show a sheet with
search, the Mac a compact popover (`macModelPicker`). Bot Chats have no picker; a Bot's model is
part of its profile (`docs/bots-groups-skills.md`).

| Action | Call | Notes |
|---|---|---|
| Model list | `GET /api/model/options?include_unconfigured=false` | Loaded on connect and cached. The refresh button adds `refresh=1`. The list shows "Gateway default" first, then each provider with `authenticated` not false and at least one model: its featured models (else the first six), "Show all N", a "Default" badge on `is_current`, the provider's `warning` as a footer, `unavailable_models` disabled, and `pricing` as "Free" or "$3.00 in · $15.00 out per 1M" (the Mac: "$3.00 / $15.00") |
| Empty list | | "Hermes didn't report any other models. Configure providers with `hermes model` on the gateway." |
| Pick a model | stored on the chat | Also remembered as this gateway's model for new chats on this device (`UserDefaults` `model.<gateway id>`, `effort.<gateway id>`). `/model <name>` and `/model <name> --provider <slug>` pick by id, short name or display name |
| Over the API server | the run's body | Each `POST /v1/runs` carries `model`, `provider` and `model_options.reasoning_effort`. Turns with images (`POST /api/sessions/{id}/chat/stream`) add `require_model_lock: true` |
| Over the gateway | `session.create`, then `config.set` | A new chat passes `model`, `provider` and `reasoning_effort` to `session.create`. Later changes go before the next turn, only when they changed: `config.set {session_id, key: "model", value: "<model> --provider <slug>"}` and `config.set {session_id, key: "reasoning", value}` |
| Think (reasoning level) | the composer's Think chip | Auto (the gateway decides), Off, Minimal, Low, Medium, High, XHigh, Max: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` on the wire. `/reasoning <level>` (alias `/effort`) does the same |
| Thinking block | `reasoning.delta` and `reasoning.available` events | See `docs/chat.md` |

When the chat's model fails, Hermes answers with its fallback model (`fallback_model` in its
config) and goes back to the chosen one as the next turn starts. The chat says so once per switch
and never says it went back ([chat.md](chat.md) §2, "Model switches").

A model picked for a chat on another device is the one this device's next message uses. Hermes
reports a session's model in its info (`model` and `provider` in `session.create`, `session.resume`
and the `session.info` event, `tui_gateway/server.py` `_session_info`), and a `config.set` model
switch both keeps it on the session's row and sends `session.info` to every client on the session
(`model_switch.py` `_commit_agent_switch`). So the app learns it when a chat opens or reattaches,
while it is open, and from the chat list's rows when the app comes back to the foreground. The chat
takes the reported model silently (the title shows it, the next turn sends it) only when it differs
from what this device last sent or took and what Hermes last reported, and the person hasn't picked
a model on this device since: a pick made here wins for this device's next turn. Reports while a
turn runs are ignored, and so is the fallback model Hermes moved a turn to. A row names no provider
and keeps the session's first model while API server turns run on others (each `POST /v1/runs`
names its own), so a row counts only when it moves. So without Bot Mode, where turns go over
`/v1/runs`, a pick on another device is followed only once a switch over the socket (a device with
Bot Mode on) moves the row. The model remembered for new chats doesn't change. The logic is
`ChatModelFollow` in HermesKit; the mock keeps each chat's model and logs the model each turn runs
on.

Provider keys are entered during setup, not in the picker: `model.save_key {slug, api_key}` with
4003 (a provider that signs in, such as an OAuth one: run `hermes model` on the gateway) and 4006
(a managed install) explained (`docs/onboarding.md` §3).

Not built yet:

- "Not set up" providers, pasting a key, and Disconnect (`model.disconnect`) in the picker.

### 4.1 Expensive models

`config.set {key: "model"}` can answer `confirm_required` with a `confirm_message` (Hermes's
selection guards: a much pricier model, or a switch that would re-send a large cached context).
Hermes keeps the old model until the client confirms, so the app keeps the chat's model too and
asks: "Switch to <model>?" with Hermes's message, **Switch** (`config.set` again with
`confirm_expensive_model: true`) or **Keep Current Model**. The mock asks for Opus models.

## 5. Background processes

Background processes exist only for gateway turns. They have their own document:
[background-processes.md](background-processes.md) (the step in its turn, the composer's chip, the
Inspector's Terminal, and the calls behind them: `process.list`, `process.kill`, never
`process.stop`).

## 6. Setup

Models need a provider and its key on the gateway ([setup.md](setup.md) §4.3). Settings → Setup →
Models says when there's none and opens the provider step. The picker lists providers without a key
under Needs a key, with Add Key… (`model.save_key`, Bot Mode), and a list that didn't load says why
with Try Again.
