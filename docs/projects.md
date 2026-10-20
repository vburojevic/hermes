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

- **Sidebar / drawer (Chats mode):** New Chat, Tasks, Skills, then **Projects** (collapsible; the
  collapsed state is remembered), then the chat history. Projects lists pinned projects first, then
  the most recently active, at most five, then **All Projects** with the project count. The history
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
    line, time, working dot), three at a time with "Show All N" / "Show Less". A chat's context
    menu has Move to Project…, Checkpoints… and Copy Session ID.
  - A project with no chats says "No chats yet" and where its chats will run.
  - `factsCard` ("What Hermes knows about this project": Built with, Checks Hermes runs before
    saying it's done, Reads first): at the end of the list on iPhone and narrow iPad layouts; in a
    right column on iPad landscape and Mac, with the folders (`folderRow*`) on Mac.
  - The composer at the bottom starts a new chat in the project (voice mode too). The trailing …
    holds `projectMenu`.
  - A project that was archived or deleted elsewhere shows "Project not found" with a way back to
    All Projects.
- **All Projects** (`allProjects`): projects by last activity, then "Found on <gateway>"
  (`repoSuggestionRow`: Add creates a project from that folder, named after it, with a colour picked
  from the name, without making it active), then Archived (Restore, Delete). Pull to refresh. On
  the Mac (`macAllProjects`) it is a grid of project cards (tile, name, folder in mono, chats, last
  activity), the found folders, and New Project… in the toolbar.
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
  No Project. The chip shows which.
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
  "sidebar.projectsExpanded"`). On iPhone the drawer is a `LazyVStack` in a `ScrollView`, not a
  `List`, for scrolling performance. On Mac each project is a custom disclosure row
  (`MacProjectRows`), with its lanes loaded when it expands.
- Project home: a `NavigationStack` destination on iPhone. On iPad and Mac it is the detail column
  of the `NavigationSplitView`, with two columns where there is room.
- Tile (`ProjectTile`): a continuous rounded rectangle filled with the accent gradient and a white
  `Image(systemName:)`. The gradient starts part-way to the deep stop so the white glyph clears
  3.2:1 on every accent (the lighter design stops for gold, mint and dark-mode graphite didn't).
- Run In and Move to Project use `.presentationDetents([.medium, .large])`.
- One `ProjectsModel` per gateway holds the tree, the project list, loaded lanes, facts and
  branches, refreshed on `projects.changed` / `sessions.changed`. Pins and Mac expansion are stored
  per gateway and profile, keyed by project id (the desktop keys its own by these ids, so they stay
  stable).

## 6. Acceptance checks

- A chat started in a project runs in its primary folder (`session.info` cwd) and appears under the
  right lane without a manual refresh.
- Chats in a project don't appear again in the flat history, except under Pinned.
- Moving a running chat keeps it running and moves it to the new project's lane.
- Deleting a project never deletes chats.
- Project colours render in light, dark and Increase Contrast, with the white glyph at 3:1 or
  better.
- VoiceOver reads a project row as "Hermes App, project, 9 chats" (or "working"), and a Mac lane
  row as "main, branch, 4 chats".
- A project with a colour or glyph written by the desktop draws as graphite / code and keeps its
  stored values after the name is edited.

## 7. Setup

Projects need Bot Mode and a Hermes with projects ([setup.md](setup.md) §4.9). Without Bot Mode,
All Projects and a project's home show Bot Mode's setup; on a Hermes without projects (-32601) All
Projects gives the update step instead of "No projects yet"; a project's home waits for the list
before it says "Project not found".
