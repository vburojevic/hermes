# Bots, group chats and skills

This document maps the Bots features (the roster, New Bot and Edit Bot, Bot Chats, routines),
hosted group chats and the Skills page to the Hermes calls behind them, and says what the app
does with each answer. Faces are in [bot-faces.md](bot-faces.md), memory in
[memory.md](memory.md), and What Hermes Learned in [learned.md](learned.md).

Bots and group chats run over Bot Mode: the backend's JSON-RPC socket (`/api/ws`, `GatewaySocket`)
and a few REST routes (`BackendClient`). One socket serves every Bot on a gateway; each call names
the Bot with `profile`. The code is `App/Model/BotRoster.swift` (roster, editing, routines, unread),
`App/Model/GroupChats.swift` (`GroupRooms`, `GroupChatModel`), the Bot Chat parts of
`App/Model/ConversationModel.swift`, `Packages/HermesKit/Sources/HermesKit/BotMode/` (`BotProfile`,
`BotMeta`, `BotRoutine`, `BotMentions`, `GroupRoom`, `RoomTranscript`), and the views in
`App/Views/Bots/`, `App/Views/Groups/` and `App/Views/Skills/`. The mock backend
(`Tools/mock-hermes/backend.py`, group chats in `chats.py`) implements every call listed here; its
Bots are Hermes, Research Buddy, Ops and Ada, plus one hidden Bot.

The protocol comes from Hermes Agent: the contracts in `tui_gateway/contracts/`
(`profiles_vault_complete_foreign_subagents.py`, `groups_bot_relay.py`, `tools_commands.py`,
`tools_mcp_plugins.py`), their handlers in `tui_gateway/methods_*.py`,
`gateway/hosted_room_discussion.py`, and `website/docs/user-guide/bot-mode.md`. Hermes Desktop's
`hermes-bots` plugin is the reference client.

## 1. Bots

**A Bot is a Hermes profile.** There's no separate Bot object. The primary profile (`default`) is
the Bot "Hermes", with the handle `@hermes`. A Bot's look and organisation live in its profile's
`ui_meta["hermes-bots"]` block (`BotMeta`). `agents.list` lists background processes, not Bots.

| Action | Call | Notes |
|---|---|---|
| Roster, grid, "Active now", last active | `profiles.list` | `include_sessions` defaults to true. The app reads name, `is_default`, display_name, description, model, provider, previous_names, has_avatar, `ui_meta` and `ui_meta_revisions`, `last_session`, `worker_session` and `canonical_session` (id, resolved_id, title, preview, last_active). Polled: every 5 s while the roster changes, 10 s after half a minute without changes, 30 s after five quiet minutes or while a Mac window is in the back, 15 s in Low Power Mode, never in the background. Each poll also refreshes the group chat list. |
| New Bot | `profiles.create {name, description, soul, no_skills: false, share_auth: true, clone_from?}`, then `profiles.configure` (look), then `setup.runtime_check {profile}` | `name` is a slug of the title, unique against current and previous names (`research-buddy`, `research-buddy-2`). `description` is "<title> — <role>". `soul` is a short SOUL.md naming the Bot and its role (`BotRoster.soul`). "Start from Hermes's setup" (on by default) sends `clone_from: "default"`. `share_auth` shares the launch profile's sign-ins instead of copying them. The app waits up to 120 s for `profiles.create`. When `setup.runtime_check` doesn't answer `ok: false`, the app sends the hello (below). |
| Look, title, hide, pin | `profiles.configure {name, ui_meta: {"hermes-bots": {...}}, ui_meta_expected_revisions: {"hermes-bots": n}}` | Read, merge, compare-and-swap (`BotRoster.saveMeta`): the app re-reads the row with `profiles.list {include_sessions: false}`, merges its change into the whole stored object, and sends it with the revision it read. A conflict (`applied.ui_meta_conflicts`) retries, up to three times. The dead legacy `chat` key is dropped. Hermes caps the block at 64 KB. Fields the app writes: `title`, `shape`, `color` (`hsl(H 68% 58%)`), `imageKind` (`shape`, or kept as `photo`), `custom`, `created` (ms), `hidden`, `pinned`. |
| Edit Bot: role | `profiles.configure {name, description}` | Only when the role changed: "<title> — <role>". |
| Photo avatars | `profiles.get_asset {name, asset: "avatar"}` | Fetched when `has_avatar` is set and the meta revision changed. Desktop also stores a 160 × 160 PNG raster of every drawn face; the app skips those (unless `imageKind` is `photo`) so the native face can animate. Photos are decoded and downsampled off the main thread (`FaceImageCache`). |
| Open a Bot's chat | `canonical_session.resolved_id` from the roster, else `session.list {profile, title: "Bot Chat", include_hidden: true, limit: 200}`, then resume; if there is none, `session.create {profile, title: "Bot Chat", hidden: true, follow_profile_config: true}` and `session.title` | **The title "Bot Chat" is the chat's identity.** The lookup fails closed: an error never reads as "no chat", so the app never mints a second one. |
| Bot hello | `prompt.submit` with "Hey, tell me about yourself!" | Sent once, right after creation, so the Bot introduces itself. |
| Compact | `session.compress {session_id}` | In a Bot Chat, `/new`, `/reset`, `/compact` and `/compress` all compact. The transcript reloads and a note says what happened ("Bot Chats are one continuous conversation, so this one was compacted instead."). |
| Routines | `cron.manage` with `profile` | See §1.3. |
| Bot-to-Bot messages | No client call | The agent uses its `message_agent` tool (`target`, `message`; tools/bot_mode_dm.py). Its step in the sender's chat shows the words it sent and, once the delivery's background process finishes, the reply it carried back ([chat.md](chat.md) §2a). The receiving Bot Chat stores `Message from 🤖 Name (@handle): …`; the app shows it as the sender's card (`AgentMessageRow`, `botMessageCard`), long text folded and a machine-style handoff as a one-line brief. The receiving Bot answers in a one-shot `hermes -p <bot> chat` that sends no events: its row, tile, face and chat show it working from its stored rows ([chat.md](chat.md), a turn going on elsewhere). |
| Mark a Bot Chat read on every device | `GET /api/sessions/<id>/mutation-snapshot?profile=`, then `PATCH /api/sessions/<id> {unread: false, request_id, expected_revision, expected_generation, profile}`; read back with `GET /api/sessions/<id>?profile=` (`last_read_at`) | See §1.2. |

Not built yet:

- Edit Bot's model (`profiles.configure {model, provider}`, with the `confirm_expensive_model`
  retry), skills, toolsets, MCP servers and personality (`profiles.describe`, then
  `profiles.configure {disabled_skills, enabled_toolsets, enabled_mcp_servers, soul}`).
- Uploading a photo (`profiles.set_asset`). Photos set in Hermes Desktop show.
- Roster sections (Desktop's `groups`, `sectionId`, `sectionName`).
- A "Sign-in needed" state for a Bot whose provider has no login.
- Bots on other gateways (`bot_relay.*`).

### 1.1 Bot Chats

A Bot Chat is the Bot's one continuous chat. It runs over the socket rather than the API server:
the app resumes the stored session, sends with `prompt.submit`, receives the turn's events through
the roster, and treats `session.info {running: false}` as the turn having settled.

- **@mentions.** When the person mentions other Bots, the prompt gets a note naming the profiles
  behind them (`BotMentions.prompt`), as Desktop's composer middleware does: the Bot then decides
  whether to message them with `message_agent`. The note is stripped from the message when shown.
  `all`, `everyone`, `user`, `default` and `hermes` are never a Bot's friendly handle.
- **Routine deliveries** arrive as stored user rows starting `[Cronjob "<name>" output …]`
  (`[Cron delivery: <name>]` when mirrored into the chat that made the routine). The app shows them
  in full as `RoutineDeliveryRow`, their output as Markdown; the routine's name opens Routines on
  that routine, and the Bot's reply right after says it's replying to the routine. Anything else
  Hermes tags `internal_notification` (a script's `hermes peer dm`, a plugin's message) is the same
  card tagged "Automation", never the person's bubble ([chat.md](chat.md) §2a). Hermes asks the Bot to summarize each one, and some
  Bots answer with the delivery again: a reply straight after a delivery that used no tools and
  repeats it (30 words or more, most of its three-word runs from the delivery,
  `BotMentions.repeats`) shows only the lines it adds (a note under the brief), and nothing when it
  adds none, since the card has the rest. A fenced block counts whole, by what it holds: the brief
  repeated with its widget as JSON (the widgets plugin turns a widget fence it didn't write into
  `json`) goes entirely, where trimming it line by line once left an empty code frame. Replies of
  their own, and replies that act on it, show as usual.
- **Bots messaging Bots.** Everything one Bot sends another is attributed, never in the
  person's style: the sender's card with its face, name and @handle (its text as Markdown, six
  lines and Show More), "Replying to Engineer" over the turn that answers it, and a handoff brief
  (a bracketed tag, headings, labelled fields or a long list) as one line under a "Brief" tag that
  opens to the whole text (`HandoffBrief`). The sender's side is the "Message to Engineer" step,
  with what it said and the reply, and a notice when the reply comes back ("Engineer replied").
  Group chats already draw each member's message with its face and name (`memberMessage`).
- **Resting chats.** When the gateway puts an idle chat to sleep (`session.reclaimed`), the face
  sleeps and a note says the chat was resting; the next message resumes it.
- **The hello screen** (`BotHelloView`) shows before the first message: the face, the role and
  suggestion chips, including the Bot's routines.

### 1.2 The roster, the grid and unread

- **Order:** pinned first, then by the row's time, then by title. The row's time is its last
  line's message ([inbox.md](inbox.md) §2, `RowTime`): the Bot Chat's newest message, else its
  activity until that's read, else when the Bot was made. A routine's run in a session of its own,
  opening the chat or a compaction moves neither the time nor the place; a turn running in the Bot
  Chat lifts the row until its reply ends.
  Hidden Bots fold under "Hidden · N" in the sidebar. The sidebar's "Your Bots" lists group chats
  first, then Bots. The context menu offers Edit Bot…, Routines…, Pin or Unpin, Hide from Roster
  or Show in Roster, and Copy @handle. Pin and Hide move the Bot at once; roster reads keep the
  change while `saveMeta` takes it to the gateway, and a failure moves it back with the error.
- **Names:** Desktop's precedence: the meta `title`, then `display_name`, then "Hermes" for the
  primary profile, then the profile name title-cased. The role line is the meta `description`,
  else the profile description without its "<title> — " prefix.
- **"Active now":** the Bot wrote in the last 90 s (in any of its sessions, a routine's run
  included), or one of its background workers beat in the last 150 s. "Working" (and a working face) is the Bot Chat's turn running here, or a worker beat
  in the last 150 s.
- **Grid tiles** (`BotsHomeView`) show the face, title, @handle, role and one status line:
  "Working: <step>", "New: <preview>", "Active now", "Last active <time>" (the row's time) or
  "Say hi to start".
- **Previews** describe the Bot Chat when there is one. Hermes's control frames read as what they
  mean ("Steered the reply", "Used the <name> skill") or are hidden, messages from other Bots read
  "Name: text", and routine deliveries read "⏰ <routine>: <output>". A compaction's summary is
  never a preview or a last line (`CompactionSummary`), nor are Hermes's own notes; a routine's or a
  webhook's mirrored delivery reads "⏰ <name>: <output>" too.
- **Fresh:** the roster is read on its poll and again on `sessions.changed` (at once, then at most
  every 3 s while changes keep coming), so a Bot that wrote where nothing streamed here (a
  routine's result, another Bot's message, a turn on another device) shows on its tile and in its
  open chat within seconds.
- **Unread** is kept per device as a watermark of the Bot Chat's activity (seeded on first sight;
  other sessions, a routine's runs included, don't count) and shared through
  Hermes's own read mark, the one Desktop keeps (`last_read_at`). Opening a Bot Chat marks it read
  on the server, but only while the app is in front, so a Mac that keeps a Bot open all day doesn't
  mark everything read for the iPhone. A Bot unread here asks the server whether another device
  read it: every 15 s at first, backing off to every 2 minutes. A stale revision answers 409
  `revision_conflict`; the app retries once with a fresh snapshot.

### 1.3 Routines

A Bot's routines are cron jobs in its profile (`RoutinesView`, `RoutinesModel`, `BotRoutine`).
Every change shows at once and settles when the gateway answers (`PendingChanges`,
[chat.md](chat.md) §4a); a refusal puts it back and says what and why.

| Action | Call | Notes |
|---|---|---|
| List | `cron.manage {action: "list", profile, include_disabled: true}` | A backend that ignores `profile` answers without a `scoped` key; the app then keeps only jobs named `[bot:<name>] …`. |
| Add | `cron.manage {action: "add", profile, name: "[bot:<name>] <title>", schedule, prompt, deliver}` | `deliver` is `bot-chat` ("Post results in the Bot Chat") or `local`. Schedules: every day, weekdays or every week at a time, every N hours, once after a delay, or a cron expression. Save goes back to the list at once; the routine shows "Adding…" until the `job` in the answer replaces it. A refusal takes it away and offers Edit Routine with what was chosen. |
| Pause, resume | `cron.manage {action: "pause" \| "resume", profile, name: <job id>}` | The switch flips at once; the `job` in the answer settles the row. |
| Delete | `cron.manage {action: "remove", profile, name: <job id>}` | Asks first; past results stay in the chat. The row goes once confirmed. |
| Run now | `POST /api/cron/jobs/<id>/trigger?profile=` | REST only; there is no RPC for it. The row says "Starting…" until it's answered. |

`success: false` with an `error` is shown as the gateway's words. Opened from a delivery's name in a
chat, Routines scrolls to that routine and picks it out (matched by title, `RoutinesView(focus:)`).
Scheduled tasks outside Bots are in [tasks.md](tasks.md).

## 2. Group chats (rooms)

A group chat is a room hosted by the gateway (`groups.*`): two to six Bots who take turns on the
person's message, server-side. The first round asks every member, or only the members the message
@mentions (`@all` and `@everyone` ask everyone); later rounds give a turn only to members another
member cited. A discussion ends when a round is silent ("Room settled"), or at the driver's limit
of three rounds or its message cap ("Room paused · reached its limit").

**There are no push events for rooms on the socket.** An open room polls `groups.log {since_seq}`
(paging while `has_more`) and then `groups.state`: every 1.2 s while Bots are replying or an
approval waits, every 5 s otherwise, and every 15 s while the app isn't in front.

| Action | Call | Notes |
|---|---|---|
| Feature check | `groups.capabilities` | Asked once. `driver: true` means rooms run on the gateway; a gateway without it isn't asked for rooms again on each poll. |
| Rooms in the sidebar | `groups.list {limit: 100}` | `room_id`, `name`, `members`, `revision`, `updated_at`, `latest_seq`, `disbanded_at`. Disbanded rooms are left out. Refreshed with every roster poll. |
| New Group Chat → Create | `groups.create {room_id, name, members: [{member_id, profile, handle, display_name, target: {kind: "local", profile}}]}` | The app makes `room_id` (the name as a slug plus six random hex digits). `member_id` is the profile name, `handle` the Bot's mention tag, `display_name` its title. Hermes requires 2–6 members, unique handles, and refuses `all` and `everyone` as handles. The call is idempotent on `room_id`. |
| Send (with @mentions, @all) | `groups.send {room_id, event_id, payload: {text, thread_id: "main"}}` | `event_id` is a fresh UUID, the idempotency key (Hermes appends a person's message once per id). `thread_id` is required. Members picked from the `@` menu are drawn as pills and sent as `@handle`. The message shows at once, with "Sending…" and after 1.5 s "Waiting for <Mac>…" under it, until the log has it; with the Bots away it waits for them, and a timeout or a dropped socket sends it again under the same `event_id`. Only a refusal puts it back in the field, and its menu has Don't Send meanwhile. |
| Timeline | `groups.log` events | `message.user`; `message.member`; `turn.started`; `turn.settled` (with `passed: true`, "<Bot> passed"); `turn.failed` ("<Bot> couldn't reply · <error>"); `turn.cancelled`, `turn.deferred` and `turn.reassigned` (end the member's turn); `room.activity {status: "settled" \| "bounded" \| "stopped"}`; `room.renamed`. Events carry `round_index` (0–2), shown as "Round 2 of 3" dividers. |
| A member wants to run a command | `groups.state` → `driver_status.pending_actions`, `kind: "approval"` | Shown as an approval card naming the member. |
| Approve | `groups.approve {room_id, member_id, task_id, execution_generation, choice, request_id}` | The app offers Allow once and Deny only. It answers the request the card showed, by `request_id`. |
| Retry a failed member | `pending_actions` with `kind: "retry"`, then `groups.retry {room_id, task_id}` | "A Bot's turn didn't finish." with Retry; tapping Retry is the confirmation Hermes asks for. |
| Stop | `groups.stop {room_id, cancel_id}` | **Stops the whole room.** There's no per-member stop on the gateway. The send button turns into Stop while Bots reply. |
| Rename | `groups.rename {room_id, event_id, name}` | Group Settings. Renaming keeps the history. |
| Delete Group | `groups.disband {room_id, cancel_id}` | Permanent for every member; confirmed with an alert. |

The sidebar row shows a room's latest line and "Needs you" only for rooms opened since the app
started (their chat model holds the log). Notifications for room messages, all or only those that
mention the person, are sent by the gateway plugin ([notifications.md](notifications.md)).

### What the app does about members, the lead and pausing

- **Members are fixed at creation.** Hermes has no method to change them (`room.members_changed`
  exists only as an event kind). Group Settings lists the members and says "Hermes fixes a room's
  members when it's created. To change them, start a new group chat."
- **"Lead"** is not a protocol role, and the speaking order rotates each round. The app tags the
  first member, the first Bot picked in New Group Chat, as Lead in messages, Group Settings and
  Activity. Not built yet: "Hand off to the lead".
- **Pausing one member** isn't possible on the gateway, and the app doesn't offer it. Activity
  shows each member as Replying…, Waiting, Replied, Passed or (after a failure) Paused.
- Not built yet: counting an @mention of the person in a member's text as "Needs you". Only a
  pending approval does.

## 3. Skills

| Action | Call | Notes |
|---|---|---|
| Skills page (by category) | `GET /v1/skills` (the API server, `HermesClient.skills()`) | Name, description and category, grouped by category, with search. |
| Use | none | Puts the skill in the composer's skill tray of the chat that was open last, or of a new chat. A chat that only talks to the API server gets "Use the <name> skill to " typed instead. |
| "/" menu skills | `commands.catalog {profile}` for names, `complete.slash {profile, text: "/"}` for descriptions | Over the socket only (`SlashCatalog`). |
| Run with skills | `command.dispatch {name: <first skill>, arg: "/<other skills> <message>", session_id}`, then `prompt.submit` with the expanded message | The gateway expands the skills into the message. See [commands-and-references.md](commands-and-references.md). |
| Skills from plugins | `skills.manage {action: "list"}` (names qualified `<plugin>:<skill>`) | Shown in the plugin's "What it adds" ([connections.md](connections.md)). |
| Archive a learned skill | `DELETE /api/learning/node {id}` | Restorable. See [learned.md](learned.md). |

Not built yet: hub search, browse, inspect and install (`skills.manage {action: "search" |
"browse" | "inspect" | "install"}`; a failed install answers 5031 with a log), turning a skill on or
off per Bot (`profiles.configure {disabled_skills}`; `skills.manage` has no enable action), and
Rescan (`skills.reload`).

### Skills on iPad and Mac

- iPhone shows rows (`skillRow`: glyph, name, description, Use). iPad (regular width) and the Mac
  show a grid of `Skills.skillCard` (glyph tile, name, two-line description, Use), with search in
  the toolbar.
- Skills starts with a "Tools and Apps" row that opens Settings → Apps and Tools
  ([connections.md](connections.md)). Toolsets are not switched from Skills.
- The top of Skills links to What Hermes Learned. On the Mac, Skills has a Library | Learned
  picker in the toolbar (`macLearned`).

## 4. Acceptance checks

- The roster matches `profiles.list`: pinned first, hidden Bots folded away, titles and roles as
  Desktop shows them.
- A new Bot appears with the shape and colour picked, its Bot Chat says hello, and Desktop shows
  the same face.
- Two clients editing the same Bot's look at once both land, or the second gets "Someone else
  changed this Bot at the same time."
- A Bot Chat lookup that fails never creates a second "Bot Chat".
- `/new` in a Bot Chat compacts instead of starting over.
- Reading a Bot Chat on one device clears its unread dot on the others within about 15 s, but
  only when it was read with the app in front.
- A group chat runs its rounds, shows passes, failures and the settled divider, takes an approval,
  stops the whole room, renames and deletes after confirmation.
- Use on a skill puts it in the tray of the last chat, or of a new chat.

Edit Bot shows a Bot's colour at its nearest swatch (345° is red, not pink) but writes colour and
shape only when the person picks another one, with `custom: true`. A hex colour, a hue between
swatches or the colour Hermes derives from the name stays as it was when only the title or role
changes (`BotDraft.changesColor`, `BotRoster.updateBot`).

## 5. Setup

Bots need Bot Mode ([setup.md](setup.md) §4.1). Group chats need the room service, two Bots and
turn isolation off (§4.12): with it on, the room shows a note with Turn Off… above the composer,
and New Group Chat a setup section; with one Bot, New Group Chat says to make another.
