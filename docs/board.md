# Board (kanban)

A board is a list of cards that Hermes and its Bots work through on their own. Each card can run in
its own worktree, can wait for other cards, asks a person when it's stuck, and can go through
review (a pull request with required checks) before it's done. The app shows a project's board,
lets people add and move cards, answer blocked ones, approve reviews, and watch or stop a run.

This doc covers the gateway calls behind the Board, the board and card screens on each platform,
adding cards, the card notifications, and what to check. The Board needs Bot Mode: it talks to the
backend's kanban plugin over REST and a WebSocket.

**Naming:** in the app these are **cards** on a **board**. "Tasks" already means scheduled jobs
(cron, `docs/tasks.md`). Never call a card a task in the UI. The gateway calls them tasks
(`t_<hex>`); the word stops at HermesKit, and `BoardCopy.cardWords` rewrites "task" to "card" in
any gateway message the app shows.

The code lives in `Packages/HermesKit/Sources/HermesKit/Board/` (`BoardAPI` on `BackendClient`,
`BoardModels`, `BoardEventStream`, `BoardActivity`, `BoardChatNote`), `App/Model/BoardModel.swift`
(one per project, owned by `BotWorkspace`), `App/Model/BoardCopy.swift` (the Board's words) and
`App/Views/Board/`. The mock is `Tools/mock-hermes/kanban.py`; its seeded board, mock-only routes
and debug flags are in [development.md](development.md). Card titles, bodies and comments are the
person's words and are never logged.

Design component names: `kanbanCard` and its variants (`Running`, `Stale`, `NeedsYou`, `Waiting`,
`Review`, `Failed`, `Done`, `Parent`), `kanbanColumnHeader`, `columnChip` (+ `Selected`,
`Attention`), `checksCard` (+ `Failing`), `kanbanRunRow` (+ `Crashed`), `kanbanEventRow`,
`needsInputCard`, `boardSummaryRow`, `cardsAddedNote`; screens `boardRunning`, `boardBlocked`,
`cardMenu`, `cardRunning`, `cardNeedsYou`, `cardReview`, `newCard`, `ipadBoard`, `macBoard`,
`macBoardCard`.

**Entry points:** the project home's Board row (`docs/projects.md` §4.2); on the Mac the Board row
under an expanded project and View → Board (⇧⌘B); "Open Board" on `cardsAddedNote`; a card
notification; and a card link (§3.1).

The source is the gateway's kanban plugin: `plugins/kanban/dashboard/plugin_api.py` (REST and
WebSocket under `/api/plugins/kanban/`), `hermes_cli/kanban_db.py`, `kanban_workflow.py`,
`kanban_db_dispatch.py`, `hermes_cli/kanban_pr_acceptance*.py` and `tools/kanban_tools_schemas.py`.
The Hermes desktop app's board (`apps/desktop/src/plugins/kanban/types.ts`) uses the same API, and
the app's shapes mirror it.

## 1. Calls

Paths are under `/api/plugins/kanban/`. Every card call takes `?board=<slug>`: the server's
"current" board is whatever someone last switched to on any device, so the app never relies on it.

| Need | Call | Notes |
|---|---|---|
| Boards | `GET /boards`, `POST /boards {slug, name, project_id, switch: false}` | One board per project (§1.1). `POST` is idempotent by slug: a taken slug answers with the board already there |
| Columns and allowed moves | `GET /workflow` | Columns: `key`, `label`, `drag_target`, plus the `manual` move matrix. **Every column list and Move menu comes from this, never from a list in the app.** Today the columns are triage, todo, scheduled, ready, running, blocked, review, done; running, scheduled and review are not drop targets. Triage and Scheduled are hidden while empty |
| The board | `GET /board` | `{columns: [{name, tasks}], assignees, latest_event_id, now}`. Each card: `title`, `body`, `assignee`, `status`, `priority`, `block_kind`, `latest_summary`, `current_run_started_at`, `last_heartbeat_at`, `comment_count`, `link_counts`, `consecutive_failures`, `last_failure_error`, `branch_name`, `workspace_kind`, `workspace_path`, `session_id` |
| Live updates | `WS /events?board=&since=<latest_event_id>` with `token=` or `ticket=` | §1.2 |
| Card detail | `GET /tasks/{id}` | `task`, `comments`, `events`, `attachments`, `links` (parents, children), `link_tasks`, `runs`. A 404 means the card is gone: it leaves the board |
| Worker output | `GET /tasks/{id}/log?tail=4096` | `exists`, `content`, `truncated`. The last lines for Latest; refreshed every 3 s while the card is open and running |
| Add a card | `POST /tasks` | `title`, `body`, `assignee`, `priority`, `parents[]`, `triage`, `workspace_kind`, `workspace_path`, `project_id`, `skills[]`. A `warning` in the reply means nothing will pick it up (no dispatcher, or no assignee): it shows under the card |
| Estimate | `POST /estimate {title, body}` | `{est_tokens, complexity: S/M/L}` under the New Card form, 1.2 s after typing pauses. Never money |
| Who new cards go to | `GET /orchestration` | `default_assignee`, else `resolved_default_assignee` |
| Who can be assigned | `GET /assignees` | Profiles (Hermes and the Bots), shown with their faces, Hermes first |
| How many run at once | `GET /api/config` → `kanban.max_in_progress` | The Running column's footnote |
| Edit, move, assign, priority | `PATCH /tasks/{id}` | `status` follows the move matrix; moving a running card away stops its run. `title`, `body`, `priority`, `assignee` |
| Approve a review | `PATCH /tasks/{id} {status: "done"}` | Refused while required PR checks fail (§3) |
| Reopen with a note | `POST /tasks/{id}/comments`, then `PATCH {status: "ready"}` | The gateway has no request-changes call for people; the comment carries the note |
| Answer a blocked card | `POST /tasks/{id}/comments {body, author: "dashboard"}`, then `PATCH {status: "ready"}` | The question is the latest `blocked` (or `block_loop_detected`) event's `reason`, else `latest_summary` |
| Stop a run | `POST /tasks/{id}/reclaim {reason}` | The app sends "Stopped from the Hermes app". The card goes back to Ready |
| Reassign | `POST /tasks/{id}/reassign {profile, reclaim_first}` | `reclaim_first` when the card is running. `""` gives it to nobody |
| Several at once (Mac) | `POST /tasks/bulk {ids, status?, assignee? + reclaim_first, archive?}` | Each card succeeds or fails on its own (`results[]`) |
| Archive / delete | `PATCH {status: "archived"}` / `DELETE /tasks/{id}` | Delete confirms |
| Split a card | `POST /tasks/{id}/decompose` | "Split into Cards", for triage cards. `{ok, reason, child_ids}`: not OK isn't an error, the reason shows |
| Write it up | `POST /tasks/{id}/specify` | "Let Hermes Write It Up", for triage cards: Hermes rewrites the title and body, then it moves to To Do |
| Run now | `POST /dispatch?max=1` | "Start Now" on a Ready card, instead of waiting for the dispatcher's next tick (60 s) |
| A run's chat (Watch) | `GET /api/sessions?source=kanban&cwd_prefix=<workspace_path>&order=recent&limit=1&profile=<assignee>` | §3 |

Never call `kanban.run` (JSON-RPC). It is for the gateway's own workers.

`estimate`, `specify` and `decompose` call the gateway's auxiliary model, which costs money. Tests
and checks use the mock for them, never a real gateway.

Refusals come back as HTTP errors with the gateway's reason; `BoardCopy.refusal` retells the
common ones ("It waits for cards that aren't done yet.", "Only Hermes starts runs. Move it to
Ready instead.", "The board doesn't allow that move.", "It's running. Stop it first."). A 404 on
the board itself is one of two things (§8): "Plugin not found" means the kanban plugin is turned
off on the gateway (Turn On), any other 404 a Hermes without the Board (update it).

### 1.1 Which board

Projects carry `board_slug` and boards carry `project_id`. The app finds a project's board by, in
order: the slug remembered on this device for that project, the project's `board_slug`, then the
board whose `project_id` is the project. It **creates** a board (slug from the project's slug or
name, made unique) only when someone opens the Board itself; the project home's row only looks.
After creating one it writes `board_slug` back with `projects.update`.

### 1.2 Live updates

The event socket sends `{events, cursor}` whenever cards change, and nothing while the board is
quiet, so the app pings every 25 s to notice a dead connection. It authenticates like `/api/ws`:
`?token=` for a session token, or a one-time `?ticket=` from `POST /api/auth/ws-ticket` for cookie
sign-ins. Each batch refetches the touched cards' details and patches them into the board in
place; heartbeats only move a card's "last heard" time. When the socket can't connect (a proxy
that drops it, an older gateway), the board polls `GET /board` every 5 s for half a minute, then
tries the socket again. The socket stays open while any board or card view is on screen, and closes
2 s after the last one goes.

### 1.3 What the real gateway does

- `decompose` links the split card as a **child** of every new card, so the root waits on them. The
  board's `progress` counts cards waiting on a card, not sub-cards: the app ignores it and reads a
  split card's progress from its detail (`BoardCardExtras`).
- Approve (`PATCH` to done from Review) re-collects PR acceptance. A failing result is a new
  `pr_acceptance` event plus `last_failure_error`, then a generic 409.
- Worker chats are `source: kanban`, run in the card's folder, live in the assignee's profile, and
  are left out of `projects.tree`.

## 2. The board

- **iPhone** (`boardRunning`, `boardBlocked`):
  - A large "Board" title with the project's tile and "Hermes App · 19 cards · Hermes and 3 Bots
    working".
  - One column at a time, swiping sideways between columns. The column switcher above
    (`columnChip`) shows counts; Blocked adds "· N needs you" in orange.
  - Opens on the most urgent column: Blocked when a card needs you, then Review, then Running.
  - + on a column header adds a card there (Triage starts it in triage); only drop-target columns
    have +.
  - Cards push their detail. Pull to refresh.
- **iPad:** columns side by side, scrolling sideways. In landscape (900 pt and wider) the selected
  card opens in an inspector on the right; in portrait two columns fit across and the card opens
  as a sheet.
- **Mac** (`macBoard`):
  - All columns side by side, scrolling sideways; the inspector on the right when a card is
    selected.
  - ⌘-click selects several; a bar then offers Move To, Assign To and Archive in bulk
    (`POST /tasks/bulk`).
  - New Card (⌘N) in the toolbar. On a board, File → New Card replaces New Chat.
- **iPad and Mac:** drag and drop between columns, limited by the move matrix; a drop the
  workflow doesn't allow snaps back. Columns a card can't go to dim during the drag (iOS 27 and
  macOS 26 and later, which report drag sessions). A filter menu shows one Bot's cards or
  everyone's. The header reads "Hermes App Board" with "19 cards · 2 running · 1 needs you".
- The Running column's footnote says how many cards run at once ("Hermes runs up to 3 cards at once
  on Studio Mac."), when the gateway sets a limit.
- **Cards** (`kanbanCard`): badge, title, latest summary (or the start of the body), then the
  assignee's face and name, sub-card progress, comment count and the short id.
  - **Running:** ink outline, "Running · 6 min", and the face in its working mood
    (`docs/bot-faces.md`).
  - **Stale:** no heartbeat for over 5 minutes: amber outline, "No word for 9 min". Workers touch
    their heartbeat with every streamed chunk; the dispatcher only reclaims after an hour, and the
    desktop dims after two minutes.
  - **Needs you:** orange badge, and the summary is the question.
  - **Blocked** (`block_kind: transient`, which may clear on its own): a grey "Blocked" badge.
  - **Waiting:** "After N cards" (parents in To Do that aren't done).
  - **Review:** the PR and its checks in the badge ("PR #142 · checks passed", "· 1 check failed",
    "· checks running"); "<Bot> reviewing".
  - **Gave up:** red, "Stopped after N tries", with the failure as the summary.
  - **Split** (`Parent`): "2 of 5" sub-card progress.
  - **Done:** muted, "Done · 2 h ago".
  - Only Running, Stale, Needs you and Gave up use colour (and a review's check result). Others
    stay grey.
- **Long-press** (or right-click, `cardMenu`):
  - The allowed moves, in plain words ("Move to Ready"), Ready first.
  - Assign To…, Raise Priority, Open Chat (when the card came from a chat, its `session_id`),
    Archive, Delete….
- A card the gateway warned about ("nothing will pick it up") shows the warning under it.
- An action the gateway refuses shows a dismissible notice over the board, in the app's words.

## 3. A card

The title wraps at the top. Then the state line (badge, then "Last heard 20 s ago · <branch>",
"Blocked 25 min ago", or "<Bot> reviewed · 10 min ago"). Then, by state:

- **Running** (`cardRunning`):
  - The assignee row (face, name, "Default profile" or the Bot's role, and the model), which opens
    the Bot.
  - Latest: `latest_summary` plus the last lines of the worker log.
  - Attempts (`runs`, `kanbanRunRow`): "Attempt 2 · now", when it started and was last heard, and
    the outcome (Running, Done, In review, Asked you, Crashed, Timed out, Gave up, Stopped).
  - Bottom glass bar: **Stop** (reclaim) and **Watch**.
  - **Watch** opens the run's chat, read-only and refreshed every 3 s: the newest `kanban` chat in
    the card's folder in the assignee's profile (§1). Without one (an older gateway, a run just
    starting) it shows the worker's output instead. For runs in this gateway's own profile, "Open
    in Chats" opens the chat among the chats.
- **Needs you** (`cardNeedsYou`):
  - `needsInputCard` first: "<Bot> is waiting for you", the question, a reply field and **Reply
    and Continue** (comment, then Ready).
  - Then the description.
- **Review** (`cardReview`):
  - The summary.
  - `checksCard`: the PR (opens it), its head commit and each required check from the latest
    `pr_acceptance` event (Passed, Failed, Running, Didn't run, Old commit, Couldn't read).
  - When Approve was refused, why: the failing checks by name ("Approve waits for the PR's required
    checks: Build didn't pass."), else the first sentence of `last_failure_error`.
  - Files changed (the latest run's `metadata.changed_files`, with +/− counts when given).
  - The reviewer's latest comment.
  - Bottom bar: **Reopen with Note…** (secondary) and **Approve** (primary). Approve is always
    sent; the gateway decides.
- **Gave up:** "Why it stopped" (`last_failure_error`), the description, and Attempts.
- **Other states:** the description and the latest summary.
- Every card then shows **Details** (Assigned to, Priority, Starts after, Blocks, Works in),
  **Comments** with an Add a comment field, and **Activity**.
- **Activity** (`kanbanEventRow`): events in plain words ("Hermes picked it up", "Asked for
  review", "Checks passed", "Stopped, back to Ready"), each with a symbol and a tone. The table
  from event kind to copy is `BoardActivityLine` in `BoardActivity.swift`; heartbeats and claim
  upkeep say nothing and are left out.
- **… menu:** Edit, Copy Link, then for triage cards Let Hermes Write It Up and Split into Cards, for
  Ready cards Start Now, then the `cardMenu` items, Archive and Delete….
- A card that was archived or deleted elsewhere says "This card is gone".

### 3.1 Card links

Copy Link copies `hermesapp://board/<project id>?card=<card id>&gateway=<gateway id>`. Opening it
selects that gateway (when this device has it), opens the project's Board and the card. Any app
or page can send such a link, and a Board that's missing is made when it opens, so a link opens
only one of the gateway's own projects, once the projects list is in (a few seconds at most), and
an id it doesn't know opens nothing.

## 4. Adding cards

- **New Card** (`newCard`, a large sheet on iOS, a 480 × 600 window sheet on the Mac):
  - Title ("What needs doing") and description.
  - "Who works on it": the Bots' faces, Hermes first. The default comes from
    `GET /orchestration` (`default_assignee`). Tapping the picked face again leaves it unassigned.
  - **Let Hermes Write It Up**: "Starts in Triage; Hermes turns your note into a full card". The card
    is added with `triage: true`, then `specify` runs.
  - Starts After: parents, picked from the board's other cards.
  - Works In: New worktree, Project folder or Scratch folder. The default is the board's
    `default_workspace_kind`.
  - The estimate line under the options, then what happens next ("Ada starts when a slot is
    free.", "It waits until the cards before it are done.", "Nobody picks it up until you give it to
    someone.").
- **From a chat:** when Hermes calls `kanban_create`, the finished turn shows `cardsAddedNote`
  ("Added 3 to the Hermes App board"), listing the cards with where they are now ("Ready · Ada",
  "After 2 cards"), and Open Board.

## 5. Notifications

Through the push plugin (`docs/notifications.md`, `Tools/hermes-app-push`). Hermes fires lifecycle
hooks only for a blocked card and a finished one (`kanban_task_blocked`, `kanban_task_completed`);
review requests and stops have none, so the plugin's gateway process also tails each board's
`task_events` (`poll_cards`): every 5 s while a card runs or the boards just changed, slowing to
30 s while they're quiet. Its per-board cursor moves under the store's lock, so each event is sent
once across processes, and a board seen for the first time starts from now, never the backlog.
Without the plugin, cards send nothing ([plugins.md](plugins.md)).

| Board event | Notice kind | Title | Level |
|---|---|---|---|
| `blocked` waiting on a person (not `dependency` or `transient`) | `card_needs_you` | "Ada needs you on “Write the App Store listing”", with the question | Time Sensitive; **Reply…** answers as in §3 (comment, then Ready) |
| `review_requested` | `card_review` | "Ready for review" | Active |
| `gave_up` / `crashed` | `card_stopped` | "Stopped" | Active |
| `completed` | `card_done` | "Done" | Passive |

One notice per card at a time (its id collapses them), threaded by board. Tapping a card notice
opens the card on its project's board. The relay only accepts titles and categories on its list,
so new card titles must be added there too (`Relay/convex/validate.ts`).

## 6. Accessibility

- A card reads: title, state ("Running for 6 minutes", "Running, no word for 9 minutes", "Needs
  you"), assignee, then "2 of 5 sub-cards done, 3 comments".
- On iPhone, the column switcher is a tab bar to VoiceOver ("Running, 2 cards, tab 4 of 7"), with
  "N needs you" where it applies.
- On Mac, drag and drop has a keyboard path: ⌘→ / ⌘← (View → Move Card Right / Left) move the open
  card to the next allowed column. They are off while typing in the card's reply or comment field,
  where the arrows move the cursor.

## 7. Acceptance checks

- Columns and moves match `GET /workflow`. Disallowed moves aren't offered and aren't droppable.
- The board updates live from the event socket without a refetch of the whole board, and falls
  back to polling when the socket can't connect.
- Opening a project's home never creates a board; opening its Board does, once.
- Answering a needs-input card posts the comment and returns it to Ready; the dispatcher picks it
  up.
- Approve is refused with the reason when required checks fail.
- Stop ends the run, and the card returns to Ready.
- The UI never says "task" for a card.
- Light, dark and Increase Contrast render correctly.

## 8. Setup

The Board needs Bot Mode and the kanban plugin turned on ([setup.md](setup.md) §4.8). Without Bot
Mode the Board shows Bot Mode's setup (Link Bot Mode, Sign In or Check Again). Turned off on the
gateway (404 "Plugin not found") it says so with Turn On, which takes `kanban` out of
`plugins.disabled`; a Hermes without it (any other 404) gets the update step. Cards wait in Ready
while the gateway is stopped.
