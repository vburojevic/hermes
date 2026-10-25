# Search

Search finds chats by what was said in them, not only by title. Results show one row per chat,
with the matching words highlighted, and open the chat at that message. This document covers the
call, the results in the drawer and sidebar, the Mac's ⌘K palette, and find in a chat.

Where it lives:

- **iPhone:** the drawer's search field (`drawerSearch`): filter chips, a count line, then one
  row per chat with a highlighted snippet and where it lives. The results replace the history
  while the field has text.
- **iPad and Mac:** the sidebar's search field shows the same results in the sidebar column.
  Search Chats (⌥⌘F) focuses it. In Bots mode the same field filters the Bots instead.
- **Mac:** ⌘K (File → Open Quickly…) opens a glass palette over the window (`macSearch`) with
  Chats, Projects and Actions. On iPhone and iPad, ⌘K opens Quick Open, which jumps to chats, Bots
  and places by name.
- **In a chat:** Find in Chat (⌘F) searches the loaded transcript (§2).

The code: `ChatSearch` (`App/Model/ChatSearch.swift`), `SessionSearch.swift` in HermesKit,
`App/Views/Search/`, and the mock in `Tools/mock-hermes/search.py`.

## 1. Call

`GET /api/sessions/search` on the backend (`hermes serve`, `BackendClient.searchSessions`), the
server Bot Mode connects to (`docs/connecting-and-voice.md` §1). The API server that serves the chat
list has no search, so full-text search needs Bot Mode connected and the gateway online. Hermes's
source: `hermes_cli/web_routers/sessions.py`.

| Param | Use |
|---|---|
| `q` | The typed text, trimmed. Never sent empty. Each word is prefix-matched ("reconn" finds "reconnect"); quoted phrases match exactly |
| `limit` | Hermes defaults to 20 and allows at most 100. The app asks for 40 (All, Chats, Tasks), 60 (Projects, filtered afterwards) and 10 per Bot |
| `profile` | Whose chats: the gateway's own profile (from a `/p/<profile>` address) or none for the active one; a Bot's name for that Bot's chats |
| `sources` / `exclude_sources` | Comma-separated sources (`cron`, `telegram`, `cli`…). Tasks uses `sources=cron`, Chats and Projects `exclude_sources=cron`. Hermes stores scheduled task runs with source `cron` (`SessionSearch.taskSource`) |

Hermes finds ID matches first (a pasted chat id finds that chat), then message content, then
titles to fill the remaining places. Results are folded by compression lineage, so a compressed chat
is one row; branches stay separate rows. Each result (`SessionSearchResult`):

- `session_id`: the live chat to open (the newest segment), and `lineage_root`: the first segment,
  which stays the same.
- `title` and `preview`.
- `snippet`: about 40 tokens around the match, with matched words between `>>>` and `<<<`. The
  app draws them in `text-primary` semibold and the rest in `text-secondary`, and removes every
  marker, even unbalanced ones (`SnippetRun.parse`). Markers never show.
- `role`: who wrote the matched message (`user`, `assistant`); empty for ID and title matches.
  When it's `assistant` the snippet starts with "Hermes:" or the Bot's name.
- `source`, `model`, `session_started`, `last_active`, `message_count`, `archived`, `profile`.
  `last_active` comes from the chat's session row on every result Hermes finds a row for (else it
  is the start): the newer of the turn heartbeat and the newest stored row, so a heartbeat or a
  compaction moves it ([inbox.md](inbox.md) §2). No result says when the matched message was
  written (the content search isn't asked for its `timestamp`). Neither is the time a row shows.

## 2. Behaviour

- **Typing** waits 250 ms after each change, then searches; the request before it is cancelled. A
  new filter searches at once. The previous results stay, dimmed, while the next ones load. With
  full text, a search the gateway hasn't answered in 0.4 s shows the chats whose title matches,
  from the list on the device ("Titles that match · searching what was said…"), and the gateway's
  results replace them when they come: a busy Mac takes its time over a search.
- **Filter chips** (All / Chats / Projects / Bots / Tasks). Projects shows only with projects (Bot
  Mode), Bots only with Bot Mode linked.

  | Chip | Search |
  |---|---|
  | All | The gateway's profile, plus one search per Bot (in parallel), newest first by the time each row shows. Matching projects first |
  | Chats | The gateway's profile, without task runs |
  | Projects | Project names that contain every typed word (local, from `projects.list`), then chats that belong to a project |
  | Bots | One search per Bot; each row shows the Bot's face |
  | Tasks | Task runs only (`sources=cron`) |

- **Count line:** "4 chats mention “reconnect”". A failed search shows the error there instead.
- **Row** (`searchResultRow`): title (else the preview, else "Untitled chat") and time, the
  highlighted snippet, then where it lives: the project tile and lane, the Bot's face and name, or
  "Task run · *task name*".
- **The time** (`ChatSearch.time(of:)`, `SessionSearchResult.time(row:)`) is the one the chat's
  row shows (`RowTime`, [inbox.md](inbox.md) §2) for a chat the app lists: in the chat list, among
  a project's chats, or a Bot's own Bot Chat. A result the app doesn't list shows when its chat
  started. Never `last_active`: a title hit for a chat last spoken in yesterday doesn't read
  "7 min" because Hermes' heartbeat moved, and a result agrees with its chat's row.
- **Matching projects** come before the chat rows, with their tile and folder; tapping one opens
  the project.
- **Opening a result** opens the chat (a Bot's result opens that Bot's chat) and lands on the first
  message that has the snippet's phrase (all its matched words without one). If the message isn't
  loaded yet, the app loads up to five older pages to find it, and only then settles for a message
  with all the words, else any of them: a chat's latest rows often have the words but aren't the
  result. It scrolls the message to the middle and flashes it once (`surface` → `canvas`, fading
  over 0.8 s).
- **Empty** (`drawerNoResults`): "No chats mention “…”", with **Search All** when a chip narrowed it, else "Try a
  different word, or a shorter one."
- **Without full text,** chats match by title only (the first message for untitled chats), every
  word as a prefix, ignoring case and accents (`SessionSearch.titleMatches`), over the chats the
  list has loaded:
  - offline: "Showing saved chats only. Connect to search everything.";
  - online without Bot Mode: "Searching titles only. Bot Mode searches what was said.";
  - the count line then reads "3 chat titles have “…”".
- **Mac palette** (⌘K, `SearchPalette`): typing uses the same search.
  - With nothing typed it shows Recent Chats (three).
  - Sections: Chats · *n* (at most three, then **Show All Results**, which puts the text in the
    sidebar's search), Projects (at most three), and Actions: New Chat (in the active project) and,
    with a chat open, Find “…” in This Chat.
  - ↑ and ↓ move the selection, Return opens it, ⌘Return opens it in a new window, ⌘1 to ⌘3 open a
    listed project, Esc or a click outside closes it.
- **Find in Chat** (⌘F on the Mac and on iPad with a keyboard): a bar at the top of the chat with
  the field, "2 of 5", previous and next (wrapping around), and Done; Esc closes it. It searches the
  loaded transcript: your messages, the replies and what Hermes said between steps, ignoring case
  and accents. It opens on the newest match, and each match scrolls to the middle and flashes.

## 3. Accessibility

- Each row reads as one button: title, time, "matched: Hermes: *snippet without markers*", then
  where it lives.
- The count line (or "No chats mention “…”") is announced when results change, at most once a
  second (`AccessibilityNotification.Announcement`).
- Selected chips carry the selected trait. The palette is a modal container labelled "Search" with
  its section titles as headers.

## 4. Acceptance checks

With the mocks (`docs/development.md`: "reconnect" matches seven chats, a task run and a Bot's
chat; `-HERMES_SEARCH` and `-HERMES_PALETTE` type for you):

- Typing "reconn" finds chats that say "reconnect" in any message, not only in titles.
- One row per chat even after the chat was compressed.
- The highlight matches the `>>>` and `<<<` markers, and the markers never show.
- Opening a result lands on the message and flashes it, also when it's older than the first page.
- Tasks lists only task runs; Bots shows faces; Search All clears a chip.
- "zsh" finds zsh startup time (dotfiles) by its title, at its last message 32 days ago, not the
  heartbeat 7 minutes ago; "outline" finds the blog post's chat at its last message, not its
  compaction 25 minutes ago.
- With Bot Mode off the status line says titles only; offline it says saved chats only.
- ⌘K opens the palette from any Mac window, and it works with the keyboard alone.

## 5. Setup

Searching what was said needs Bot Mode; without it search finds chats by title
([setup.md](setup.md) §4.7). The line under the results says why: no Bot Mode, a sign-in it waits
for, or Bot Mode not answering. A full-text search that fails shows the titles that match, with the
reason.
