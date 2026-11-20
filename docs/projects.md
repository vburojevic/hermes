# Projects (workspaces)

A project is a named set of folders on the gateway, with a colour and a glyph. Chats started in a
project run in its primary folder, and Hermes reads that folder's context files (AGENTS.md and so
on) first. The app groups a project's chats by **lane**: the main checkout's branch, each linked git
worktree, and the Board's card worktrees. This is the same grouping the Hermes desktop app uses.

This doc covers the data behind projects, where they show in the app, starting and moving chats,
and creating and editing projects. Projects need Bot Mode: they come from the backend (`hermes
serve`) over its JSON-RPC socket, so a gateway without a linked backend, or a Hermes too old to know
`projects.tree`, shows no Projects section at all (`ProjectsModel.isAvailable`).

The code lives in `App/Model/ProjectsModel.swift` (one per gateway, owned by `BotWorkspace`),
`Packages/HermesKit/Sources/HermesKit/Projects/` (`ProjectsClient`, `ProjectModels`) and
`App/Views/Projects/`. The mock is `Tools/mock-hermes/projects.py`; its demo data and debug flags
are listed in [development.md](development.md).

Design component names used below (`projectTile*`, `projectRow*`, `projectChip*`, `laneHeader*`,
`laneChatRow`, `projectHeader`, `factsCard`, `folderRow*`, `repoSuggestionRow`, `projectPickRow*`,
`projectMenu`, `macProjectRow*`, `macLaneRow`) match the comments in the code.

## 1. Data

Hermes names come from the gateway source (`tui_gateway/methods_projects.py`, `methods_config.py`,
`project_tree.py`, `contracts/projects_pets.py`). Every call is scoped to the gateway's Hermes
profile (`profile` param): the projects database lives in that profile's home. The gateway rejects
parameters it doesn't know (error 4000), so `ProjectsClient` sends only documented keys.

| Need | Call | Notes |
|---|---|---|
| Sidebar list and project home | `projects.tree {preview_limit: 3, session_limit: 2000}` | Projects → repos → lanes (`groups`: lane key, label, path, main / worktree / kanban), `previewSessions`, `sessionIds`, `active_id`, `scoped_session_ids`. Lanes come back without chats or counts |
| One project's chats, fully loaded | `projects.project_sessions {project_id, session_limit: 5000}` | The same project node with every lane's session rows, for the project home and the Mac lane rows |
| Project rows (name, colour, glyph, folders) | `projects.list` | `ProjectInfo`: id, slug, name, description, icon, color, primary_path, archived, folders[], board_slug. Includes archived projects |
| Create | `projects.create {name, folders, primary_path, icon, color, use}` | Primary folder first. A primary folder that already belongs to a project is error 5063 |
| Edit | `projects.update {id, name?, description?, icon?, color?, board_slug?}`, `projects.add_folder {id, path, is_primary}`, `projects.remove_folder {id, path}`, `projects.set_primary {id, path}` | `update` sends only the fields that changed (§4.1) |
| Archive / restore / delete | `projects.archive {id, restore}`, `projects.delete {id}` | Both return the remaining list. Deleting keeps the chats; they fall back to the flat history |
| Which project is active | `projects.set_active {id}` (`null` for No Project) | Where new chats from anywhere start; Run In sets it |
| Folders Hermes found | `projects.discover_repos {scan: false}` | Git roots Hermes has worked in, with session counts ("Found on Studio Mac") |
| What Hermes knows | `project.facts {cwd}` | manifests, packageManagers, verifyCommands, contextFiles → `factsCard`. `nil` outside a recognisable workspace |
| Which project a folder is in | `projects.for_cwd {cwd}` | Also returns the branch. Without `cwd`, the gateway's default folder (used for "No Project" and to guess the gateway's home for `~/` paths) |
| Start a chat in a project | `session.create {…, cwd}` | The placement's folder (§3). Without `cwd` the gateway uses its default folder |
| Move a chat | `session.workspace.move {session_key, cwd}` | `session_key` is the stored session id. Returns cwd, branch, git_repo_root; a running agent follows, even mid-turn |
| Which chats are running | `session.active_list` | Polled every 30 s, as the desktop does: turns on other clients don't otherwise show. Every 2 minutes while the Mac app is behind other apps |
| Browse folders on the gateway | `complete.path {word}` | Folder picker (§4) |
| A repo's checkouts | `GET /api/git/worktrees?path=<repo>` (REST) | Branch picker in Run In. The protocol has no git calls; the dashboard's git routes do |
| A new worktree | `POST /api/git/worktree/add {path}` (REST) | "Work in a new worktree": a new branch under `<repo>/.worktrees/` |
| Refresh | `projects.changed`, `sessions.changed` events | Re-fetch `projects.tree` after 0.25 s; `projects.changed` also re-fetches `projects.list`. Open project homes reload their lanes. `sessions.changed` arrives through the roster's one tick (at most every 3 s, `docs/inbox.md` §1) |

Error codes (`ProjectsClient.Code`): 5061 failed, 5062 no such project, 5063 bad input (an empty
name, a missing `project_id`, or a primary folder that is already a project's). A gateway that
answers `projects.tree` with -32601 (method not found) has no projects.

### 1.1 Stored values

The app stores `icon` as an SF Symbol name and `color` as an accent name (`ocean`, `mint`, `ember`,
`violet`, `gold`, `rose`, `graphite`), so other clients get something readable. The desktop app
writes other values (`hsl(…)` swatches and codicon names): the app draws unknown colours as
graphite and unknown glyphs as the code glyph, and never overwrites them unless the person changes
that field (`ProjectAccent`, `ProjectGlyph` in `ProjectTile.swift`).

The eight glyphs are `chevron.left.forwardslash.chevron.right` (Code), `server.rack`, `pencil.line`,
`cpu`, `terminal`, `globe`, `hammer` and `sparkles`.

### 1.2 What the real gateway does

- `scoped_session_ids` covers every chat the tree placed, including the Home bucket and the repos
  Hermes grouped by itself. The flat history therefore hides only the chats of projects someone
  made (each project node's `sessionIds`), not every scoped id.
- The tree's lanes carry no counts; counts come from `projects.project_sessions`.
- `complete.path` stops at 30 entries, files and dot-entries included, so a busy folder (a home
  folder) would hide most of its folders. When a listing comes back full, `ProjectsClient.folders`
  asks again per first character and merges the results.
- `session.active_list` isn't profile-scoped.
- Chats started on this device are filed under their project locally (`placedSessions`) until the
  tree catches up, so a new chat doesn't flash into the flat history.
- Chats Board workers run (`source: kanban`) aren't in the tree; see `docs/board.md` §3.

## 2. Navigation

- **Chat list and sidebar (Chats mode):** Tasks, Skills, then **Projects** (collapsible; the
  collapsed state is remembered), then the chat history. Projects lists pinned projects first, then
  the rest by their time (below), newest first, at most five, then **All Projects** with the
  project count. The history
  lists only chats outside a project, except **Pinned**, which keeps any pinned chat. A search
  covers every chat. Bots mode removes the Projects section.
- **Project row** (`projectRow`): tile (colour + glyph), name, then a pulsing orange working dot if
  any chat in it is running, else the chat count. Tap opens the project home. Long-press (or
  right-click) opens `projectMenu`: Edit Project…, Add Folder…, Copy Path, Pin to Sidebar / Unpin
  from Sidebar, Archive, Delete Project…. Pins are kept on this device, per gateway and profile.
- **Mac sidebar:** each project is a disclosure row (`macProjectRow*`). The arrow expands it into
  its **Board** row (with the number of cards that need you) and its lanes (`macLaneRow`: branch or
  worktree in mono, and the chat count). Clicking a lane opens the project home scrolled to that
  lane. Card worktrees stay on the project home. Expansion is remembered per project id.
- **Project home** (`projectHome`, `ipadProjectHome`, `macProjectHome`):
  - Header (`projectHeader`): tile, name, primary folder and branch, then "9 chats · 2 branches ·
    3 cards · Studio Mac" (branches only when there is more than one, cards only when there are
    card-run chats).
  - The Board row (§4.2), on gateways with Bot Mode.
  - Lanes, in the gateway's order: main checkout first, then worktrees by recency, then "Card
    worktrees". Each lane (`laneHeader*`) shows its chats newest first (`laneChatRow`: title, first
    line, time, working dot, and a muted chat's slashed bell before the time, the chat list's
    mark), three at a time with "Show All N" / "Show Less". A chat's context
    menu has the chat list's row actions in its order, on every platform (`docs/inbox.md` §5):
    Mark as Read / Mark as Unread, Pin / Unpin, Mute, then Move to Project…, Checkpoints… (with
    Bot Mode), Copy Session ID, and on the Mac Archive. Pin is also what brings a project's chat
    into the flat chat list, which otherwise keeps project chats in the project; a pinned chat
    stays in its lane too. Hermes lists every pinned chat, so Pin reads right however old the
    chat, and a chat older than the chat list's loaded pages joins the list as it's pinned. A
    failed Pin or Archive puts the row back as it was and says why.
  - A lane chat swipes as a chat list row does from its trailing edge (`docs/inbox.md` §5), on
    iPhone and iPad: Mute / Unmute then Archive, both in `Theme.swipeActionQuiet`, and a full
    swipe mutes, the row showing the slashed bell at once (Unmute takes it away). The lanes aren't
    a `List`, so the swipe is the app's own (`TrailingSwipeActions` on `SidewaysSwipePan`, its
    numbers in `RowSwipe`): it takes only a drag that starts to the left, so a drag up or down
    scrolls the project and one from the screen's edge goes back. One
    row is open at a time; a tap on it, a scroll or another row's swipe shuts it. The Mac has no
    swipe and keeps Archive in the menu. VoiceOver offers Mute / Unmute and Archive as actions
    on the row on every platform.
  - On the Mac the lanes take the keyboard with Tab, which selects the first chat
    (`macLaneChatRowSelected`). Up and Down move the selection within its lane, Left and Right to
    the lane before or after it, at the same place or that lane's last row, and Return opens the
    chat. Only the rows shown count, so a lane collapsed to three offers three. The selection
    shows while the lanes have the keyboard, VoiceOver reads the row as selected, and the rows
    keep their order and labels. `LaneSelection` (HermesKit) holds the moves. iPhone and iPad
    have no selection.
  - Archive works as it does in the chat list (`docs/inbox.md` §5): the row leaves its lane at
    once and "Archived “title” Undo" shows above the composer for 5 s; Undo puts the row back in
    its lane at once, the lane too if it went with its last chat. The toast shows where the chat
    was archived from, so a window never shows two, and leaving the project ends its Undo. The app lays its archives and Undos over the
    gateway's answers until a read that started after the call landed, since a read from before it
    still has the old state; an archive whose Undo still shows stays laid over every read, so
    Undo has the row to put back however soon a read came in. Which chats the flat history leaves out is worked out from the
    project as shown, so a chat brought back with Undo stays out of it.
  - A project with no chats says "No chats yet" and where its chats will run.
  - `factsCard` ("What Hermes knows about this project": Built with, Checks Hermes runs before
    saying it's done, Reads first): at the end of the list on iPhone and narrow iPad layouts; in a
    right column on iPad landscape and Mac, with the folders (`folderRow*`) on Mac.
  - The composer at the bottom starts a new chat in the project (voice mode too). The trailing …
    holds `projectMenu`.
  - On iPhone a chat opened from the project home (a lane row, Show All, or a chat sent from its
    composer, also one waiting for the gateway) pushes over the home, and so does Talk's new chat,
    its draft, which is pushed right away, before anything is sent. Back, or the swipe from the
    screen's edge, returns to the project, which the back button names, and a second Back goes to
    the chat list. A chat or the Board opened again from the home after a Back stays open; the
    Board's back button names the project too. The chat you went back from is no longer open, so
    its replies count as unread (`docs/inbox.md`). A chat opened any other way (the chat list, a
    notification, search, Quick Open, a link) goes back to the chat list, and archiving or
    deleting the chat on screen goes back to the chat list too. On iPad and Mac the chat replaces
    the project home in the detail column, as before.
  - A project that was archived or deleted elsewhere shows "Project not found" with a way back to
    All Projects.
- **A project's time** and its place in both lists (`ProjectsModel.rowTime`, `RowTime.ofProject`)
  are the newest of its chats' row times ([inbox.md](inbox.md) §2: each chat's newest message, a
  running turn lifting it until the reply ends), over the chats the app has for it: the tree's
  newest three, its lanes once opened and its chats in the history. The tree's `lastActive` is
  Hermes' activity for its chats, which a heartbeat or a compaction moves, so it stands in only
  while none of its chats is known. A project with no chats takes its place by its creation time,
  but shows no time: its card and row say "0 chats" alone (`RowTime.shownForProject`).
- **All Projects** (`allProjects`): projects by their time, newest first, then "Found on <gateway>"
  (`repoSuggestionRow`: Add creates a project from that folder, named after it, with a colour picked
  from the name, without making it active), then Archived (Restore, Delete). Pull to refresh. On
  the Mac (`macAllProjects`) and iPad it is a grid of project cards (tile, name, folder in mono,
  chats, its time), the found folders, and New Project… in the toolbar; Archived is a link on the
  Mac and a row on iPad. While the list loads, card skeletons (Mac and iPad) or four row skeletons
  (iPhone) stand in, each read as one "Loading".
- Chats mode has no home row; a project home is reached from its row or the chip (§3).

## 3. Starting and moving chats

A new chat's **placement** (`ChatPlacement`) says where it runs: a project's primary folder, one of
its worktrees, a new worktree, or No Project (the gateway's default folder). It is resolved when the
first message is sent: a new worktree is made then, and the folder goes to `session.create` as
`cwd`.

- **New chat inside a project** (`projectNewChat`): the hero reads "New chat in Hermes App" and
  "Runs in ~/Code/hermes-app on main" (or "Runs in a new worktree of …"). Suggestions come from the
  project: "Run the tests" when `project.facts` has a verify command (it sends "Run `<command>` and
  fix anything that fails."), "Review my changes" when the folder is on a branch, and always
  "Explain the codebase".
- **Project chip** (`projectChip` in `composerProject`): shows the project the chat runs in, and on
  iPad (regular width) and Mac the branch; iPhone has no room for it. It doesn't show in Bot Chats.
  - On a new chat, tapping it opens **Run In** (`projectPicker`, a medium/large sheet): the
    projects, No Project, New Project…, and for a project with a folder a Branch section: a picker
    of its checkouts (`/api/git/worktrees`) and "Work in a new worktree" ("Keeps this chat's edits
    off main until you merge."). Done also makes the picked project the active one
    (`projects.set_active`), so the next new chat starts there too.
  - On a chat that has started, the chip appears only when the chat is in a project, and opens a
    menu: Open Project, Move to Project….
- **New Chat from the sidebar** starts in the active project, if one is set and not archived, else
  No Project. The chip shows which. On a project home, its New Chat button and ⌘N start the chat
  in that project.
- **Move to Project…** (`moveToProject`, from the chip, a lane chat's menu or a chat's menu in the
  sidebar):
  lists the projects and New Project…, says "Hermes moves its workspace; a running turn follows.",
  and calls `session.workspace.move` with the target's primary folder. Projects without a folder
  can't be picked.
  - Not built yet: moving a chat back to No Project. The gateway has no call that clears a chat's
    project, so the sheet doesn't offer it.

## 4. Creating and editing

- **New Project** (`newProject`, a full-height sheet on iPhone and iPad):
  - Live tile preview, then the name, 7 colours and 8 glyphs.
  - Folder: the git folders Hermes found (`discover_repos`); the one picked is the primary.
    Folders already in another project say "in <project>". "Choose Another Folder…" walks the
    gateway's folders with `complete.path`, starting at its home folder, and hides dot-folders
    except Hermes's own.
  - ✓ creates with `use: true`, makes it active, and opens the project home.
- **Mac, New Project** (`macNewProject`): a compact window sheet with the tile and what a project
  is, then name, colour, symbol and the folder on the gateway (Choose… browses the gateway's files,
  not the Mac's), then Cancel / Create Project.
- **Edit Project** (`editProject`):
  - The same identity card.
  - Folders: primary first, with a Primary tag. Swipe to remove; long-press for Make Primary (on
    the Mac, right-click for both).
  - Add Folder…
  - Archive and Delete…, paired. Delete confirms with an alert ("The chats stay in Chats.").
  - Folder changes apply together on ✓: additions, then the new primary, then removals.
- **When an action fails:** Archive, Restore, Delete and Add Folder, from a project's menu, the
  Archived list, Delete's confirmation or the editor, show "Something went wrong" with Hermes's own
  words (5061 is the gateway's generic failure). The editor stays open behind it, and nothing
  moves in the sidebar or the lists.
- Validation: a name is required. When the gateway refuses a primary folder that is already a
  project's (5063, "folder already belongs to project …"), the sheet says "That folder is already a
  project's primary folder. Open that project, or pick another folder." Other 5063 messages show as
  the gateway words them.

### 4.1 Saving only what changed

Edit Project sends `projects.update` only for the fields the person changed. Another client may
have stored a colour or glyph this app draws differently (§1.1); re-saving the drawn value would
overwrite it.

### 4.2 The Board row

The project home shows a Board row (`boardSummaryRow`: running, in review, done, and what needs
you) above the lanes; it opens the project's Board (`docs/board.md`). On the Mac the Board is also
the first row under an expanded project, and ⇧⌘B opens it from the project's home or any of its
chats (and goes back home from the Board). The "Card worktrees" lane lists the chats of card runs.

## 5. SwiftUI notes

- Sidebar: the Projects header is a plain button that collapses the section (`@AppStorage
  "sidebar.projectsExpanded"`). The chat list is one `List` on every platform, so rows get the
  system's swipe actions and the iPhone's push and back swipe. On Mac each project is a custom disclosure row
  (`MacProjectRows`), with its lanes loaded when it expands.
- Project home: a `NavigationStack` destination on iPhone. On iPad and Mac it is the detail column
  of the `NavigationSplitView`, with two columns where there is room. On iPhone a chat opened from
  the home is a `navigationDestination` over it, keyed on the chat, the way the Board is: the
  workspace remembers the project the chat came from (`CompactNavigation.parentProject`), the route
  becomes `DetailRoute.projectChat`, and the system back selects the project again
  (`DetailRoute.backSelection`). The home keeps `navigationTitle(name)` for the back button and
  hides the title until the header scrolls away. Back from a chat or the Board leaves the home on
  screen, but the collapsed split view reports that pop as going back to the list; showing the
  detail again then popped the next chat or Board as soon as it came. So the workspace remembers
  the home under the list (`CompactNavigation.homeUnderList`), and while it does the window leaves
  the split view's column alone, until a screen is pushed anywhere but over that home. The Board's
  edge swipe is taken by its paging lanes, so its back button is the way back.
- Tile (`ProjectTile`): a continuous rounded rectangle filled with the accent gradient and a white
  `Image(systemName:)`. The gradient starts part-way to the deep stop so the white glyph clears
  3.2:1 on every accent (the lighter design stops for gold, mint and dark-mode graphite didn't).
- Run In and Move to Project use `.presentationDetents([.medium, .large])`.
- Sizes on the Mac: New and Edit Project open 520 wide and grow with the text; the folder picker
  opens at 460×520. The editor's colour and glyph rows stay one row at every text size (the
  glyphs stop growing at xxLarge). On iPad, New and Edit Project keep their form layout.
- Two columns on the project home only where there's room (860 pt or more), and on iPad never at
  the accessibility text sizes, where the lanes need the whole width; the Mac keeps its columns
  and All Projects its grid at every size. The right column is 300 pt with
  a 28 pt gap inside 40 pt margins on the Mac, and 280, 24 and 32 on iPad, so iPad landscape keeps
  both columns.
- At the accessibility text sizes rows stack rather than truncate: an All Projects row puts its
  tile above and its working dot below the wrapped details; a found folder puts its glyph above
  and Add below; the home's header wraps the path without glyphs and gives the branch its own
  line; a lane header stacks; a lane chat (`laneChatRowLarge`) wraps its title and line and puts
  its marks and time below; the facts card gives each chip a line; a folder row drops its glyph
  and wraps the path; the Board row puts its tile above, what needs you under the counts, and
  drops the chevron. All Projects on iPad is then one column of readable width, and the new-chat
  hero scrolls, its chips stacked (they stop growing at accessibility1).
- Lane chats are cards on iPhone and iPad and plain rows on the Mac (body title, subheadline
  line); project cards and Mac rows lift to the hover surface under the pointer. Show All is ink
  on the Mac and grey on iPhone and iPad. Every text style is a Dynamic Type style.
- Reduce Motion: a lane chosen in the sidebar is jumped to rather than scrolled to, and the
  new-chat hero fades in without growing; with decorative motion paused it appears at once.
- One `ProjectsModel` per gateway holds the tree, the project list, loaded lanes, facts and
  branches, refreshed on `projects.changed` / `sessions.changed`. Pins and Mac expansion are stored
  per gateway and profile, keyed by project id (the desktop keys its own by these ids, so they stay
  stable).

## 6. Acceptance checks

- A chat started in a project runs in its primary folder (`session.info` cwd) and appears under the
  right lane without a manual refresh.
- Chats in a project don't appear again in the flat history, except under Pinned.
- Moving a running chat keeps it running and moves it to the new project's lane.
- On iPhone, Back (button or edge swipe) from a chat opened in a project home (a lane row, Show
  All, a chat sent from its composer, online or waiting for the gateway) shows the project home,
  and a second Back shows the chat list; VoiceOver reads the back button as the project's name.
  Opening another chat, or the Board, from the home after that Back keeps it open. A chat opened
  from the chat list still goes back to the list, and iPad and Mac are unchanged.
- Deleting a project never deletes chats.
- A refused Archive, Restore, Delete or Add Folder (the mock's "readonly" project) says "Something
  went wrong" with the gateway's message, from the menu, the Archived list and the editor, on
  iPhone, iPad and Mac, and the project stays where it was.
- Archiving a chat from a lane takes its row away at once, and it stays gone after a refresh; Undo
  brings it back at once, in its lane and still out of the flat history. One Undo toast shows, in
  the project home, on iPhone, iPad (both orientations) and Mac.
- A chat's menu in a lane reads as the chat list's: Mark as Read / Unread, Pin and Mute change at
  once, and a chat pinned there shows under Pinned in the flat list and stays in its lane.
- A lane chat's swipe matches the chat list's on iPhone and iPad: the same buttons, tints, order
  and full swipe, the row sliding back, and Undo; a drag up or down mid-lane still scrolls, and
  the back swipe still goes back on iPhone. The Mac's menu has Archive.
- On the Mac, Tab into a project home's lanes selects its first chat; Down and Up stop at the
  lane's ends, Right and Left move to the next and previous lane, and Return opens the selected
  chat. The selection scrolls into view, draws as `macLaneChatRowSelected` in light and dark, and
  clicking a row still opens it. iPhone and iPad are unchanged.
- A muted lane chat shows the chat list's slashed bell before its time, on iPhone, iPad and Mac,
  at every text size, and VoiceOver reads "muted" after its title. A full swipe shows it at once;
  Unmute from the swipe or the menu takes it away.
- A heartbeat or a compaction in a project's chat moves neither the project's time nor its place:
  seeded, dotfiles (a heartbeat 7 minutes ago) stays last, at its message 32 days ago, and Blog
  (compacted 25 minutes ago) stays at its last message, three days ago.
- Project colours render in light, dark and Increase Contrast, with the white glyph at 3:1 or
  better.
- VoiceOver reads a project row as "Hermes App, project, 9 chats" (or "working"), and a Mac lane
  row as "main, branch, 4 chats". A lane header reads "main, main checkout, 3 chats", a lane chat
  "Fix the build, muted, working, 2 hours ago" and then its last line, and a folder in the picker
  "hermes-app, folder" or "hermes-app, folder, in Hermes App".
- At the largest accessibility text size, All Projects, a project home, its lanes and Board row,
  the editor, the folder, Move and Run In pickers and the new-chat hero show every word with
  nothing clipped or overlapping, on iPhone, iPad (both orientations) and Mac. iPad landscape
  keeps two columns at the default size, and the Mac at every size.
- A project with a colour or glyph written by the desktop draws as graphite / code and keeps its
  stored values after the name is edited.

## 7. Setup

Projects need Bot Mode and a Hermes with projects ([setup.md](setup.md) §4.9). Without Bot Mode,
All Projects and a project's home show Bot Mode's setup; on a Hermes without projects (-32601) All
Projects gives the update step instead of "No projects yet"; a project's home waits for the list
before it says "Project not found".
