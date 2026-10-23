# Memory

This document covers what Hermes remembers between chats and how the app shows it: the calls
behind the Memory page, the notes and the "Save to memory?" card in chats, the review queue for
saves made while Ask Before Saving is on, and the Mac and iPad layouts.

Hermes keeps what it learns in two small stores per Bot (profile):

- **About You** (`USER.md`, graph source `profile`, memory-tool target `user`): who you are and how
  you like things done.
- **Hermes's Notes** (`MEMORY.md`, source `memory`, target `memory`): your setup, projects,
  conventions.

Both are read **once, at the start of a chat** (a frozen snapshot). A save mid-chat is on disk at
once, but the open chat keeps the old snapshot. Every screen says so: "changes apply from your
next chat". The copy never says a change affects the open chat.

In the app, people can see everything Hermes (or a Bot) remembers, edit or forget any entry, turn
the stores and Ask Before Saving on and off, switch the memory provider, reset memory, review saves
waiting for approval, and answer "Save to memory?" in the chat.

Memory is read over Bot Mode's backend, so it needs Bot Mode for the gateway. Code:
`App/Model/MemoryModel.swift`, `App/Views/Memory/` (`MemoryView`, `MemoryParts`,
`MemoryEditViews`, `MemoryChatViews`, `MacMemoryPane`), and in HermesKit
`Packages/HermesKit/Sources/HermesKit/Memory/` (`MemoryList`, `MemorySettings`, `MemoryStatus`,
`MemoryPendingParser`, `MemoryChange`) and the memory calls in `BackendClient`. The mock is
`Tools/mock-hermes/memory.py` (Sam's six things and fourteen notes, two saves waiting; Research
Buddy has its own).

The protocol comes from Hermes Agent: `tools/memory_tool.py`, `agent/learning_graph.py`,
`agent/learning_mutations.py`, `tools/write_approval.py`, `hermes_cli/write_approval_commands.py`,
and `hermes_cli/web_routers/status.py` (`/api/learning/*`) and `ops.py` (`/api/memory*`).

Entry points:

- Settings → the gateway's section → **Memory**. The row's summary reads "6 things about you · 14
  notes · 2 to review".
- Edit Bot → **What <Bot> Remembers** (that Bot's own memory).
- Tapping a memory note in a chat.
- A memory tapped on the map in What Hermes Learned ([learned.md](learned.md)).
- Mac: Settings → Memory (⌘,).

## 1. Calls

Every call names the Bot's `profile`: the Bot's for a Bot, the gateway's own profile for Hermes.

| Need | Call | Notes |
|---|---|---|
| List entries | `GET /api/learning/graph` | Uses `memory[]` (cards: `source` `profile` = About You, `memory` = Hermes's Notes, `title`, `body` (the first 1,200 characters), `fingerprint`) and the ids of the `nodes[]` with `kind: "memory"`. Skill nodes are ignored here. Cards come MEMORY.md first, then USER.md, each in file order (newest last). |
| An entry's id | `memory:<source>:<index>:<fingerprint>` | The index names the occurrence, the fingerprint (a digest of the text) its identity. If the entry changed since it was loaded, edit and delete fail with "memory node id is stale — refresh the graph". The app reloads and shows the new text. When a node id is missing, the app mints the id the same way. |
| Full text for editing | `GET /api/learning/node?id=` | `content` is the whole entry. Only fetched when the listed text was cut at 1,200 characters. |
| Edit | `PUT /api/learning/node {id, content, profile}` | Size caps apply across all entries of a store. A refusal ("Replacement would put memory at X/Y chars…") is shown inline and the text stays in the field. |
| Forget | `DELETE /api/learning/node {id, profile}` | Removes the entry. Hermes has no undo, so Forget asks once ("Forget this?", "<Bot> won't remember it in new chats."). |
| Add an entry | none | "Tell Hermes Something to Remember…" opens a new chat (for a Bot, its Bot Chat) with "Remember that " typed. Hermes saves it with its `memory` tool. Not built yet: a direct add call (Hermes has none). |
| Switches, limits, Ask Before Saving | `GET /api/config?profile=` → `memory` section | `memory_enabled`, `user_profile_enabled`, `write_approval`, `memory_char_limit` (default 2,200), `user_char_limit` (default 1,375), `provider`. |
| Turn a store, or Ask Before Saving, on or off | `PUT /api/config {config: {memory: {<key>: bool}}, profile}` (deep-merged) | Keys: `memory_enabled` (Keep Notes About Your Setup), `user_profile_enabled` (Remember Things About You), `write_approval` (Ask Before Saving). `config.set` has no memory keys (it answers 4002 "unknown config key"), and `/memory approval on` through `command.dispatch` acts on the session's profile, not the one named, so a Bot's switch would land on the launch profile. |
| Provider and file sizes | `GET /api/memory` | `active` provider ("" is built-in), `providers[]` (`name`, `description`, `status`: `ready`, `needs_config`, `unavailable` or `missing`), `builtin_files` sizes. |
| Switch provider | `PUT /api/memory/provider {provider}` | Only providers marked ready; "" switches back to built-in. Setting a provider up happens on the gateway; the app doesn't build those forms. |
| Reset | `POST /api/memory/reset {target: "all"}` | Deletes both files. Destructive: always confirmed. The backend refuses an unnamed profile while it serves several, so the app names `default`. Hermes also accepts `memory` and `user`; the app only resets both. |
| Saves waiting for review | `command.dispatch {name: "memory", arg: "pending", profile, session_id?}` | Returns **formatted text** only, parsed in one place (`MemoryPendingParser`). Each record has a hex id, an `[auto]` tag for background review, a summary ("add to user profile: …", "replace in memory: …", "patch in …", "remove from …", "apply N op(s) to …", "background review consolidation (…)") and, for a replace or removal, the whole entry it applies to. There are no times and nothing names the chat or task. Hermes lists the oldest first; the app shows the newest first. |
| Save or discard one | `command.dispatch {name: "memory", arg: "approve <id>"}` / `"reject <id>"` | Approving a replace swaps the **whole** matched entry; the reply lists what was overwritten, shown as a toast ("Saved. It replaced: …"). |

`command.dispatch` acts on the profile of the session it runs in. For a Bot other than the primary
one, the app passes a session of that Bot (its Bot Chat, created if it doesn't exist yet,
`ConversationModel.runtimeForCommands()`); for Hermes it runs without a session. The Edit Bot row
therefore leaves the review list out of its summary; the Memory page loads it.

**Meters:** the gateway counts a store as the code points of its entries joined by `\n§\n`, against
the store's limit. The app counts the same way, and uses the file's size when an entry was cut
at 1,200 characters. When the limits can't be read, the defaults above apply.

## 2. In the chat

- **When Hermes saves** (a successful step of the `memory` tool in the turn, live or stored,
  `ToolActivity.memoryChanges`):
  - One quiet line after the reply (`memoryNote`): "Remembered: …".
  - `memoryNoteUpdated` "Updated memory: …" (a replace or patch) and `memoryNoteForgot`
    "Forgot: …".
  - Several in one turn (a batch's `operations`) fold into "Remembered 3 things" (or "Forgot 3
    things").
  - Tapping it opens `memoryNoteSheet`: the entry as it is on the gateway now, which store it's in
    ("About you · saved in this chat"), Forget and Edit…, and the brain button opens Memory. An
    entry that's gone says "It isn't in memory anymore."
- **Staged saves** (the tool's result says `staged: true`): `memoryNoteWaiting` "1 memory waiting
  for your review", which opens Hermes's Notes.
- **Ask Before Saving on, and Hermes asks:**
  - The gateway sends an approval request titled "Save to memory?" with
    `allow_permanent: false`. The request has no kind field: the title tells it apart, or, for an
    untitled request, a description starting "Save to memory: " (`ApprovalRequest.isMemorySave`).
    A request with its own title can't pass for a memory save, and a smart-denied one never does.
  - The text to keep (`ApprovalRequest.memoryText`): for an add, the request's `command` as it
    stands. Only the gateway's own replace and patch layouts ("entry matching: …\nwhole entry
    becomes: …", "…span '…' becomes: … (rest of the entry is kept)"), as the description names
    them ("Save to memory: replace in …", "patch in …"), are cut down to the new text. A marker the
    model wrote into an added entry is just words, so it can't hide what comes before it.
  - The app docks `memorySaveAsk` above the composer instead of the command approval card: the text
    to keep, which store, and **Don't Save** (deny, Esc), **Save** (once, Return) and, when the
    request offers it, **Save All in This Chat** (session). Never Always.
  - Push: "Wants to remember something", carrying the one entry, with Save and Don't Save (both
    need the device unlocked) ([notifications.md](notifications.md)).
- **Ask Before Saving on, and nobody can answer:** Hermes asks inline only where the turn has an
  interactive approval channel. Otherwise (tasks, background review, and on current gateways Bot
  Mode and API-server chats) it stages the save, and the chat shows the waiting note. Settings
  shows the count, and so does the tab it belongs to on the Memory page. The mock asks, so the card
  can be tried there.

## 3. The Memory page

- **Header:** "What Hermes on <gateway> remembers" beside the gateway's avatar, or the Bot's face
  and "What <Bot> remembers".
- **Tabs:** About You · Hermes's Notes, with a badge for the saves to review in each. A record that
  doesn't name its store counts as Hermes's Notes.
- **Waiting for Review** (top of the tab it belongs to): one `memoryPendingRow` per staged save,
  labelled Add, Update or Forget, "Background review" or "While you were away", the text, then
  Discard / Save; for a removal, Keep / Forget.
- **Meter** (`memoryMeter`): how many entries and how full the store is. From 90% it turns orange:
  "nearly full, Hermes will merge older ones".
- **Entries** (`memoryEntry`):
  - In file order, newest last.
  - "New in this chat" tags entries the memory tool saved or updated in the chat the person came
    from.
  - Each entry's … menu (or a long press) offers Edit…, Copy and Forget.
- **Footer:** "Hermes reads this at the start of every chat, so changes apply from your next one."
  A Bot's page adds that each Bot keeps its own memory, separate from Hermes and other Bots.
- **Tell <Hermes or the Bot> Something to Remember…**: see Add in §1.
- **Options** (below the entries, `memoryOptions`):
  - Saving: Remember Things About You, Keep Notes About Your Setup, Ask Before Saving ("Review each
    change before it's kept").
  - What <Hermes or the Bot> Learned (§3a).
  - Where Memory Lives: Memory Provider (Built-in, or a ready provider; others say "Needs setting
    up on the gateway", "Not found on the gateway" or "Unavailable").
  - Reset Memory…, confirmed with an alert that counts what goes.
- **Edit** (`memoryEdit`, a sheet at medium or large height):
  - A plain-text field, kept as typed, and the room left in that store ("room for N more
    characters", or "N characters over").
  - Forget This.
  - ✓ saves and closes the sheet at once; the list shows the new text while the gateway takes
    it. An empty entry is refused ("Use Forget This to remove it.").
  - A refusal puts the entry back and opens the sheet again with every character typed and the
    gateway's words. If the entry changed on the gateway meanwhile, the sheet shows what it says
    now beside the person's text; if it was forgotten, the text stays to copy. On the Mac the
    editor opens again in place.
- **Empty** (`memoryEmpty`): what memory is, and Tell Hermes Something. **Off** (`memoryOff`, both
  stores off): Turn On Memory, which turns both on. One store off says so in its tab.
- **Not available:** "Turn on Bot Mode for <gateway>", "<gateway> is offline", or "Couldn't read
  memory" with the reason.
- **iPad:** in landscape (regular width, 900 pt and wider) both stores sit side by side and the
  options move behind the … button. Portrait uses the iPhone layout.
- **Mac** (Settings → Memory, `macSettingsMemory`):
  - The current gateway's Hermes memory. Left: About You and Hermes's Notes. Right: Waiting for
    Review, the Saving switches, the provider picker and Reset Memory….
  - The arrow keys move the selection. Return or a double-click edits in place. Delete forgets the
    selected entry after a confirmation. ⌘C copies it.

The page loads entries, settings, provider and the review list together, and pulls to refresh;
the stores show `SkeletonRows` until the entries arrive, on the Mac too. Every change shows at once
and settles when the gateway answers ([chat.md](chat.md) §4a, `PendingChanges`): an edit's text, a
forgotten entry gone, a review row gone (a saved addition already in its store), a switch or the
provider's checkmark moved, Reset's empty stores. Then it re-reads what it touched. A refusal puts
it back and says what and why. Install and provider setup wait for the gateway's answer, which is
what they show, with a `Spinner` and words.

## 3a. What Hermes Learned

Memory links to What Hermes Learned ([learned.md](learned.md)), which shows memories and skills
together over time and on the map. A memory tapped on the map opens Memory for the same Bot on the
entry's store.

## 4. Privacy

- Memory lives on the gateway. The app keeps it only for the open screen: `MemoryModel` is made
  when the page opens and dropped when it closes. It is never written to disk, never indexed in
  Spotlight, and never sent in push payloads beyond the one entry in a "Save to memory?" request.
- An entry can hold anything Hermes heard, including secrets. Entry text is never logged. The app
  shows text the way Hermes stores it; the memory tool already rejects obvious secrets
  (`_scan_memory_content`).

## 5. Accessibility

- An entry reads "<text>. About you" (or "Hermes's notes"), with ", new in this chat" when tagged,
  and the actions Edit, Copy and Forget.
- The meter reads "6 things about you, 62% full".
- A tab reads its count to review ("2 to review").
- A pending row reads its action ("Add to Hermes's notes"), the text, then the Save and Discard
  buttons.
- The "Save to memory?" card reads "To remember: <text>".

## 6. Acceptance checks

- The page lists exactly the entries in `USER.md` and `MEMORY.md` for the chosen Bot, in order.
- Editing an entry that changed on the gateway meanwhile fails cleanly, and the page reloads it.
- Edits over the size cap are refused with the gateway's message, and nothing is lost from the
  field.
- With Ask Before Saving on, a save in a chat that can be asked shows `memorySaveAsk`; a save in a
  task shows up under Waiting for Review.
- Save and Discard on a pending row update the list and the badge at once.
- On a slow gateway (`--starve 5-30`) no change waits behind a spinner or keeps its sheet open.
- Reset needs the confirmation and empties both tabs.
- A Bot's switches and review list change that Bot, not the primary profile.
- The copy never says a change affects the open chat.
- Light, dark and Increase Contrast read well.

## 7. Setup

Memory needs Bot Mode; without it the page says so with Link Bot Mode. A provider in use that isn't
set up runs on the built-in memory: the page marks it "not set up" with its setup command. A
provider that needs its settings is set up from the provider list (Set Up a Provider on the Mac),
with Hermes's own fields for it. One that's unavailable installs what it needs from there (Install
a Provider on the Mac), after showing the commands Hermes will run ([setup.md](setup.md) §4.4).
