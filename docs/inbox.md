# Unread and live activity

How the chat lists and the chat itself show what's new and what's happening, in the spirit of
Telegram and Grok's Bots. The design's components live in `blocks/inbox.elyx`; the screens are
`inboxChats`, `inboxBots`, `inboxUnread`, `inboxCaughtUp`, `inboxSwipe`, `inboxRowMenu`,
`chatOpenedAtNew`, `chatReadingLive`, `chatNewBelow`, `botChatTyping`, `groupChatMention`,
`chatReplyQuote`, `chatReplyQuoteSent`, `ipadInbox` and `macInbox`.

| Code | What it is |
|---|---|
| `HermesKit/Inbox` | The rules, with tests: `ReadMark`, `UnreadCounter`, `NewMessagesMarker`, `MuteList`, `JumpPill`, `InboxTime`, `ActivityLine` / `ActivityTracker`, `LastLine`, `QuotedReply` |
| `UnreadStore` | One per gateway: each row's badge, Hermes' read marks, counts, mutes, how far each chat was read and where it was left |
| `LiveActivity` | One per gateway: each chat's activity line |
| `ReadRecheck` | When to ask Hermes again about read marks, shared by the chats and the Bots (`BotRoster`) |
| `Views/Inbox` | The rows, badges, activity line, filters, swipes, the New Messages line, the jump pill, the group chat's thinking line, the reply bar and the quote block |

## 1. Read state

Hermes keeps one read mark per chat, `last_read_at`, shared by every device and Hermes Desktop
(`hermes_state_sessions.py`: `set_session_read`, `session_unread`).

| Value | Meaning |
|---|---|
| `null` | Never tracked: read |
| `0` | Marked unread by hand: the row shows a dot, not a count |
| A time | Read up to then |

Unread means `last_active > last_read_at` (with half a second of slack for Hermes' clock). Any
activity counts, your own messages and turn heartbeats included, so the app marks a chat read
again after each turn it watched end.

| Need | Call | Notes |
|---|---|---|
| Read marks for the list | The dashboard's `GET /api/sessions?order=recent&limit=100` (`BackendClient.recentSessions`) | The API server's rows (`HermesClient.sessions`) carry no `unread` or `last_read_at`, nor does the JSON-RPC `session.list`; the dashboard's do. So with Bot Mode linked, chats get Hermes' marks; without it, a watermark kept on this device (seeded on first sight), and read state doesn't sync |
| Mark read | `PATCH /api/sessions/{id} {unread: false}` on the API server (`HermesClient.setSessionFlags`) | Stamps the mark at the gateway's now. Only when the chat was unread. A gateway older than the field answers `400 unsupported_session_field`; then the dashboard's fenced `markRead` (via `mutation-snapshot`, else the plain PATCH with `profile`) |
| Mark unread | The same with `{unread: true}` | Sets the mark to 0 |
| Read elsewhere | `sessions.changed` (no payload; it fires when any session column it watches moves, `last_read_at` included, at most every 2 s, and so all through a streaming turn). The app turns it into one tick for everything that follows it (project lanes, read marks, the roster, the chat list, live lines): a quarter second after the first change, then at most every 3 s while changes keep coming, every 30 s while the Mac app is behind other apps | `ReadRecheck`: ask at once, then at most every 3 s while changes keep coming; between changes every 15 s (60 s while the Mac app is behind other apps), backing off to 2 minutes while something stays unread. The chat list itself is fetched again too (at most every 3 s), so rows move to the top |
| A mark this device just set | | Holds until Hermes' rows agree, or for 10 s, so an older page can't undo it |
| Bots | The Bot Chat's own mark (`GET /api/sessions/{id}?profile` → `last_read_at`; `BackendClient.readMark`) | `BotRoster` as before (opening a Bot Chat marks it read), plus Mark as Unread and picking up a mark of 0 from other devices (read Bots are asked at most every 30 s) |
| Group chats | none | Rooms have no read mark for the person. This device keeps the last event seen per room (`groupSeen.<gateway>`); a room's count is its members' messages after it (`groups.log`), refreshed when `latest_seq` moves |

### Counting

The gateway has no count; the app counts (`UnreadCounter`).

- An unread row's newest 100 messages (`GET /api/sessions/{id}/messages?limit=100&order=latest`,
  the Bot Chat's from the dashboard) are folded with `TranscriptBuilder` and counted after the
  mark.
- **Counted:** each reply that ended a turn (an answer after the steps), each Bot's message in the
  chat (`message_agent`, a group member), each routine delivery, each command result.
- **Not counted:** narration, tool steps, reasoning, notices and your own messages. A chat whose
  only news is your own message (sent from another device) or a heartbeat shows nothing.
- Capped at "99+". With a mark of 0, the dot.
- A row is counted again when its `last_active` or its mark moves, at most every 2 s, and not while
  its turn runs (its row moves with every heartbeat; it's counted when the activity line ends). The
  rows are built and counted off the main actor. Counts are
  cached per gateway on the device (`inbox.<gateway>` in `UserDefaults`: ids, times and counts,
  never message text), so the list draws them at once on launch.
- A running turn shows no count until it ends (the activity line says what's happening).

### Muting

The gateway has no mute; it's on the device (`MuteList`), per gateway: For 1 Hour, For 8 Hours,
For 1 Week, Until I Turn It Back On. A swipe mutes until turned back on.

- A muted chat keeps a grey count and shows the slashed bell; it's left out of the drawer button,
  the mode switch and the app icon badge.
- The mutes are shared with the Notification Service (`PushShared.setMutes`, under the chat's key
  and its live session id). It delivers a muted chat's notices quietly (`interruptionLevel =
  .passive`, no sound). Approvals, questions, keys and mentions in group chats still alert
  (`PushNotice.quietWhenMuted`). See `docs/notifications.md`.
- Not done: syncing mutes between devices (`NSUbiquitousKeyValueStore` would need the iCloud
  key-value entitlement on every App ID).

### What this device remembers

Per chat: the last row it showed (`seenThrough`, for the New Messages line next time) and, when a
chat was left scrolled up, the row at the top (it opens there next time unless there's something
new). Each chat's last message is kept in memory only: Hermes' list rows carry the first message,
so the app fetches a chat's newest 8 rows when its row first shows without one (4 at a time,
once per activity).

## 2. The rows

Two lines: 62 pt on iPhone and iPad, 46 pt on the Mac with 13 pt type (`InboxMetrics`).

| State | Line 1 | Line 2 | Trailing |
|---|---|---|---|
| Read | Title, time grey | Last message ("You:" or a Bot's name before it) | – |
| Unread | Title semibold, time primary | Last message, brighter | Ink count |
| Marked unread | Semibold | Last message | Ink dot |
| Muted | Title, slashed bell, time | Last message | Grey count |
| Live | Still ink dot, semibold title | The activity line, shimmering | – |
| Needs you | Semibold | Orange hand + what it needs | Orange hand badge |
| Draft | Title | **Draft:** then the draft (a chat opened this launch) | – |
| Failed | Title | Red triangle + "Stopped: …" until opened | – |
| Mention (group chat) | Semibold | Last message or who's working | @ badge, then the count |

- Pinned first, then by activity, newest first; no date sections. The time on each row: "now",
  "2 min", "14:21", "Yesterday", "Thu", "12 Oct" (`InboxTime`). Rows from the last hour tick each
  minute; older ones don't wake anything.
- Projects stay above the chats, collapsed with their count ("Projects · 3").
- Bot rows (`BotInboxRow`) have the face at 44 pt (32 on the Mac) in the mood of what it's doing
  (`ActivityLine.faceMood`, `docs/bot-faces.md` §5.9). Group rows (`GroupInboxRow`) stack the
  members' faces with whoever is working in front.
- Line 2 is one line, cut at the tail.

### The activity line

One line per chat (`LiveActivity`), the same words on the row, the jump pill and the Live
Activity's first state.

| Source | Line |
|---|---|
| `session.active_list` status `starting` | "Starting…", shimmering |
| `working`, preview still the prompt | "Thinking…", shimmering |
| `working`, preview moved on | Writing: “the newest ~40 characters” |
| A tool running (chats the app is attached to) | The tool's glyph and what it does ("Running swift test"), with the plan's progress ("· 2 of 3") |
| Helpers running (`subagent.*`, attached chats) | "3 helpers working" |
| `waiting`, or an approval, question or key in an attached chat | Orange hand + "Waiting for your approval" / "Has a question" / "Needs a key" |
| The last turn failed (an attached chat's error, or a `failed_turn` row seen while counting) | Red triangle + "Stopped: …" until opened |
| A Bot answering another Bot (Hermes's one-shot `hermes -p <bot> chat`, not in `session.active_list`; read from its Bot Chat's stored rows, `BotRoster.runningElsewhere`) | The open call's glyph and what it does ("Running a command"), else "Thinking…" ([chat.md](chat.md), a turn going on elsewhere) |

- `session.active_list` lists the live sessions in the dashboard's gateway process (Bot Chats,
  chats run over Bot Mode, Hermes Desktop). Turns run on the API server (`/v1/runs`) by other
  devices don't appear; this device's own runs come from the chat itself. It's asked every 5 s
  while a list is on screen and 0.5 s after a `sessions.changed` tick (see below). One answer
  serves the chat list and the projects' running chats (`ProjectsModel.activeSessions`: a
  request under way is joined, an answer under 2 s old reused). A Mac app behind other apps asks
  every 30 s and not on changes (its list never leaves the screen, and the dashboard is often the
  busy process on that Mac); coming to the front asks at once. Hermes' `preview` is the prompt
  until the first words, then the reply; `ActivityTracker` tells them apart by watching it move.
- There is no `tool.progress` event and no step counts in Hermes' events: "212 of 240" isn't
  available; the plan's progress is.
- Attached chats update at most 4 times a second.
- Without Bot Mode the chat list is fetched again every 15 s while it's on screen.

## 3. Motion

Quiet and quick; with Reduce Motion only cross-fades. Only one thing moves in a row: the activity
line's shimmer (`ShimmerText`, [chat.md](chat.md) §4a); waiting for you and stopped are solid and
still. Decorative loops hold still when the window is behind, off screen and in Low Power Mode
(`pausesDecorativeMotion`). The shimmer is a Core Animation layer (`ShimmerLayer`): with a Bot
working and the list on screen the app's CPU went from about 8% of a core to 1%. Its moving part
exists only while it moves (`DecorativeLoop`):
a `repeatForever` doesn't stop when its value is set back without an animation, and a pulsing dot
in a list row hidden for reuse kept a Mac core at 100% with the window in the back. A hidden row gets
no `onDisappear`, so the Mac sidebar starts a new list when it swaps its rows (mode, filter,
search).

| Element | Motion |
|---|---|
| Count appears / changes | Scale 0.6 → 1 (spring 0.3 / 0.7), digits roll (`.numericText`) |
| Live dot | Still: an ink dot in a soft halo |
| Activity shimmer | A `thinking-shimmer` band sweeps across the words every 1.6 s (ease-in-out) |
| Activity text | Cross-fade, at most 4 updates a second |
| Rows | Spring to the top (0.4 / 0.85) |
| New Messages line | Fades in with the chat, out (0.3 s) |
| Jump pill | Rises 12 pt with scale 0.9 → 1; its content morphs |
| The live line before the first words | Fades in with the turn header; its words cross-fade into the running step, then "Worked for …" |
| Haptics | A tick when the pill's count goes up, a light impact on a jump |
| Sounds | Off; Settings → Chat → Sounds plays soft sent and received sounds |

## 4. In the chat

### Opening a chat

- Just before a chat opens (`BotWorkspace.selection` `willSet`), the store notes how far it was
  read (`UnreadStore.noteOpening`); a Bot Chat is marked read as it opens, so this comes first.
- Something new: the transcript finds the New Messages line (`NewMessagesMarker`): above the head
  of the first new turn (the message that started it, when that's new too), or the first new Bot
  message. A chat left half-way resumes after the last row this device showed.
- It opens with the line a quarter of the way down; when everything new fits on screen, at the
  end with the line in view. If the rows on the device stop short, it waits up to 1.2 s for the
  gateway's.
- Settings → Chat → Open Chats At: First Unread (default) or Latest (the line is still drawn).
- The line stays until the chat closes, and never appears for messages that arrive while it's
  open.
- Nothing new: where it was left scrolled up, else at the end.

### Marking read

- On the gateway when the newest message has been on screen for a second with the app active, or
  on a jump to the end (`TranscriptView.markRead`). After each turn that ends while you watch,
  again.
- Scrolled up with new messages below, the chat stays unread: Hermes' mark only means "read until
  now". This device remembers how far it got.
- Mark as Unread (menu, swipe, ⇧⌘U); opening the chat clears it.
- Bot Chats keep `BotRoster`'s rule: read as they open.

### The jump pill

A glass capsule 12 pt above the composer, shown once you scroll up (`JumpPillView`).

| Below | Pill | Tap |
|---|---|---|
| Nothing new | The round arrow | To the end |
| A turn running | "Hermes is writing…" or the running step, shimmering | To the end, following |
| New messages | ↓ "2 new messages" | To the first of them (a quarter down), then to the end |
| A mention (group chats) | Face + @ + "Ada mentioned you" | To the mention |
| A Bot chat | The Bot's face leads | As above |

Mentions come first, then new messages, then the running turn (`JumpPill.choose`). Messages count
as seen as they come on screen (`onScrollTargetVisibilityChange`).

### Before the first words

Every chat, a Bot's included, shows the turn header's live line ("Thinking…", shimmering) from the
moment the message goes until the reply's first words. No typing bubble, no dots, no face in the
transcript. The Bot Chat's toolbar face looks up; its subtitle keeps the handle. Group chats name
who's thinking (`BotThinkingLine`): the Bot's face thinking, without dots, and "Ada is thinking…"
shimmering, one line per Bot, at most two, then "+1 more" (`RoomTranscript.thinkingMembers`).
[chat.md](chat.md) §4a has the rules.

### Reply with a quote

- **Start:** the message menu's Reply (on replies and your messages), Reply to Words… (a sheet
  where you select the words), or a swipe left on a message. Replies with code blocks or tables
  scroll sideways themselves, so they take Reply from the menu.
  - SwiftUI has no way to add Reply to the text selection menu itself; Reply to Words… stands in.
  - On iPhone and iPad the swipe is a UIKit pan that begins only on a drag to the left
    (`SidewaysSwipe`), as the drawer's rows do (§5): a SwiftUI drag on each reply took the chat's
    vertical drags, and the chat stopped scrolling under a finger that started on a reply. A drag
    to the right from the screen's edge stays the drawer's.
- **Composing:** the reply bar ("Replying to Hermes", the quote, ✕) sits in the composer and the
  passage flashes where it is.
- **Sent:** `> quote` lines, a blank line, then your words (`QuotedReply`, at most 280 characters
  of quote). Hermes needs nothing new.
- **Shown:** a leading block quote is drawn as the quote block (`QuotedBlock`), never as ">". This
  device remembers each quote's author and row by a hash of the quote (`QuoteMemory`); tapping it
  goes back to the passage. Elsewhere the quote shows without an author.

### Mac

⌘↓ Jump to Latest, ⌥⌘↓ / ⌥⌘↑ Next / Previous Unread Chat, ⇧⌘U Mark as Read / Unread (Chat menu).
The design also gives ⌥⌘↓ to "next mention"; in group chats the mention pill does that.

## 5. Lists: filters, menus, swipes, counts

- **Filters** (Chats mode): All · Unread n · Needs You n · Running n. The Mac has no All; clicking
  the selected filter clears it. Filters cover project chats too. An empty filter shows "You're all
  caught up" (`CaughtUpState`).
- **Mark All as Read** at the end of the Unread list and on a long press (right-click) of the
  Unread chip: every badge clears at once, and the gateway hears of them 4 calls at a time. A mark
  this device set holds over the gateway's until its call is back and 10 s more (or the gateway
  agrees), so a busy Mac's list read meanwhile doesn't bring a badge back.
- **Swipes:** from the leading edge Read / Unread (the main one) and Pin; from the trailing edge
  Mute and Archive. The iPad and Mac lists use system swipe actions. The system draws their
  symbols white on the tint in both modes, so the main action is ink in Light Mode and a raised
  grey in Dark Mode (`Theme.swipeAction`; white ink hid its envelope), the others a quieter grey
  (`Theme.swipeActionQuiet`). The iPhone drawer isn't a `List`: from
  iOS 27 its rows use the system's swipe actions too, coordinated by `swipeActionsContainer()` (one
  row open at a time, closed by scrolling or a tap elsewhere). Before iOS 27, only `List` rows
  swipe, so the drawer's draw their own (`DrawerSwipeActions`): the row, opaque, slides over its
  actions, which share the room it uncovers and grow in; pulled past them the first fills the room
  and runs (a tap of haptics). Never both on one row: they fought over the drag, drew over each
  other and stopped the list scrolling.
  - The drag is a UIKit pan that begins only sideways, so vertical drags stay the list's (a
    SwiftUI drag on each row took them).
  - A row swiped toward the drawer's edge claims the drag (`RowSwipe`), so a leftward swipe on a row
    shows its actions instead of closing the drawer; the drawer still closes from its header, the
    chat beside it, or a tap. A press that ends as the drawer is swiped shut doesn't open the row.
- **Archive:** `PATCH /api/sessions/{id} {archived: true}` (the same as `session.archive`), with
  Undo for 5 s. Archived chats leave the list (Hermes' lists leave them out). The row goes and
  Undo shows at once; Undo brings the row back at once and sends its call after the archive's,
  never alongside it.
- **Menus:** Mark as Read / Unread, Pin, Mute ▸ first, then Rename…, Move to Project…, Branch,
  Checkpoints…, Copy Session ID, Delete…. The Mac adds Archive. Bot menus: Mark as Read / Unread,
  Pin, Mute ▸, then Edit Bot…, Routines…, Hide, Copy @handle.
- **Counts outside the list:**
  - The drawer and sidebar buttons: unread chats (not messages) elsewhere, muted and open ones
    left out (`unreadBadgeCutout`).
  - Chats / Bots: each segment shows the other mode's unread count.
  - App icon and Dock: Settings → Notifications → App Icon Badge (Dock Badge on the Mac): Needs
    You (default) or Unread Chats (those plus unread, unmuted chats). Set with
    `UNUserNotificationCenter.setBadgeCount` and `NSApp.dockTile.badgeLabel` whenever the app
    runs; between runs the Notification Service adds the last count the app saw. Open point: the
    push plugin would have to send an unread-chats count for it to stay exact.

## 6. Accessibility

- Rows read "Release notes for 1.3, 3 unread, 14:21, 23 merged PRs"; live "…, Hermes: Running
  swift test"; muted "…, muted, 12 unread"; needs you "…, waiting for your approval".
- Rows have custom actions: Mark as Read / Unread, Pin / Unpin, Mute / Unmute, Archive.
- The New Messages line is a header; an "Unread" rotor goes between it and the new messages.
- The pill is a button: "2 new messages. Jump to the first one."
- The open chat's activity line is announced at most every 10 s, never the words as they stream.
- Never colour alone: needs you has the hand, failed the triangle, muted the slashed bell, unread
  the weight and the count.

## 7. Checks

Against the mock (`Tools/mock-hermes/backend.py --gateway-port 18642`, `inbox.py`; add
`--inbox-demo` for a chat that keeps writing and one waiting on an approval) and a real Hermes:

- A reply that lands while you're away makes the row semibold with a count equal to the replies
  after `last_read_at` (seeded: Release prep 3, Morning briefing 1, Stand-up summary the dot).
- Reading it on one device clears it on the other within a few seconds (`sessions.changed`), and
  the reverse; Mark as Unread shows the dot on every device and opening clears it.
- A chat with unread opens at the New Messages line; reaching the end marks it read on the
  gateway (`curl` the dashboard's `GET /api/sessions/{id}?profile=default` for `last_read_at`).
- Scrolled up during a turn ("marathon"), the pill shows what Hermes is doing; when the turn ends
  it says "1 new message" and goes to it.
- In a group chat, a mention shows the @ on the row and the mention pill in the chat (`POST
  /api/mock/room-say`).
- A muted chat shows a grey count, isn't in the badges, and its pushes are quiet; approvals in it
  still alert.
- Rows move to the top when they get activity; pinned rows stay on top.
- The drawer button's count is the unread, unmuted chats other than the open one.
- Reduce Motion: no shimmer or slide. Light, dark and Increase Contrast match the renders.
- Fast flicks up and down that start on a reply's text, a message, a row or a row with its
  actions open all scroll the chat and the drawer; a swipe left on a reply still replies, and one
  right from the edge still opens the drawer.
- Unit tests: `InboxTests` (counting, read marks null / 0 / time, mute expiry, the line with partial
  reads, pill priority, activity, quotes, row times, Bot faces, group mentions), `SidewaysSwipeTests`
  (which drags a row's swipe takes).

## 8. Setup

Read marks shared between devices and Bots' unread need Bot Mode ([setup.md](setup.md) §4.1);
unread that arrives while the app is closed needs notifications and the push plugin (§4.13).
