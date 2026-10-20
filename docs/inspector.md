# The Inspector

One panel for everything a chat can show beside it: a page Hermes opened, an artifact from its
reply, a file, the project tree, the git changes, a running process's output, Hermes's own screen,
the helpers, the plan and the sources. The person opens things with Open on cards in the
transcript or from the panel's + menu; Hermes can open things itself, read them and act in them.

This doc covers the layout on each device, what each tab shows and the Hermes calls behind it, how
Hermes uses the Preview, how a device reaches a dev server on the gateway machine, artifacts, and
what to check.

The state lives in `App/Model/Inspector/` (`InspectorModel`, one per chat, owned by its
`ConversationModel`; `PreviewController` and `PreviewEngine` for Preview tabs; `FileModels`,
`ChangesModel`, `ScreenController`), the views in `App/Views/Inspector/`, and the protocol pieces in
`Packages/HermesKit/Sources/HermesKit/Inspector/` (`PreviewBridge`, `PreviewTarget`,
`PreviewFileAccess`, `Artifacts`, `WorkspaceAPI`, `WorkspaceModels`, `RFBClient`). The mock is
`Tools/mock-hermes/inspector.py`; its chat triggers and mock-only endpoints are in
[development.md](development.md).

Most of it needs Bot Mode: Files, File, Changes, Screen and gateway files use the backend's REST
API and socket, processes and helpers report over that socket, and Hermes's Inspector tools only
exist for sessions on it. Artifacts, the plan, the sources and web pages the person opens work
without it.

Design component names: `inspectorTab` (+ `Selected`, `Agent`, `Pinned`), `inspectorBar`,
`urlBar`, `agentHighlight`, `agentDrivingBar`, `reachNote`, `artifactCard` (+ `Preview`, `Open`),
`artifactBar`, `changeRow` (+ `Selected`, `Added`, `Unstaged`), `shipBar`, `fileTreeRow` (+ `File`,
`Selected`), `processHeader`, `screenBar`, `openMenu`, `inspectorPill`; screens
`macInspectorPreview`, `macInspectorArtifact`, `macInspectorChanges`, `macInspectorFiles`,
`ipadInspectorScreen`, `ipadInspectorTerminal`, `chatInspectorPill`, `inspectorSheet`,
`inspectorChanges`, `inspectorUnreachable`, `inspectorOpen`.

The Inspector replaces two side panels designed earlier: the Team inspector is the **Team** tab
([helpers.md](helpers.md)), and on iPad and Mac, Checkpoints' Review of the latest turn opens the
**Changes** tab on This Turn. The Board's card inspector stays on the Board, since it isn't about
one chat.

Hermes names come from the Hermes Agent source: the tools `tools/preview_tool.py`
(`desktop_preview`), `drive_preview_tool.py`, `annotate_preview_tool.py`, `focus_pane_tool.py`,
`read_terminal_tool.py` and `read_window_tool.py`; `tui_gateway/contracts/events.py` (`preview.*`,
`pane.reveal`) and `contracts/server_requests.py`; `tui_gateway/server_requests.py` (the 4404
decline); `methods_prompt.py` (`preview.restart`); `methods_display.py`; and the REST routers
`hermes_cli/web_routers/files.py` (`/api/fs/*`), `git.py` (`/api/git/*`) and `display.py` (the Bot
Screen socket). Hermes Desktop has the same panel (`apps/desktop/src/app/chat/right-rail/`); the app
follows its behaviour where this doc is silent.

## 1. Look and layout

- **The panel body is content**, so it uses solid fills (`Theme.canvas`, `Theme.surface`), never
  glass. Only the tab strip, the iPhone pill, the floating controls (the driving bar, the Screen
  bar) and the iPhone sheet at medium height are glass.
  - The Screen bar floats over live video, so it is clear glass over a `media-dim` fade.
- **Mac** (`InspectorPresentation`, SwiftUI's `.inspector`):
  - The panel is inset 8 pt with radius 18 and a hairline. It opens about 600 pt wide and resizes
    from 380 pt to 60% of the window.
  - Opening it collapses the sidebar when the window is narrower than 1,400 pt; closing it brings
    the sidebar back (`RootView`, `WindowRouter.inspectorIsOpen`).
  - In the Chat menu, Show Inspector (⌥⌘I) shows and hides it, Open Address… (⌘L) asks for an
    address and shows the panel, and Inspector Tabs (⌥⌘1–9) switches tabs. ⌘W closes the selected
    tab while the panel has focus, instead of the window.
  - A tab dragged out of the strip and dropped outside any window, or **Open in New Window** from
    the strip's … menu, gets its own window (`InspectorTabWindow`). Closing that window puts the tab
    back in the chat's Inspector.
- **iPad:**
  - In landscape with a regular width of at least 700 pt, the panel sits beside the chat with the
    same widths as on the Mac, and the sidebar hides while it's open (the toolbar's sidebar button
    brings it back).
  - In portrait and narrow windows it uses the iPhone sheet.
- **iPhone** (and iPad portrait):
  - A sheet with two heights. Medium (`inspectorSheet`) keeps the end of the chat and the composer
    in view and usable behind it; the sheet is glass and the tab's content sits in a solid card.
    Large (`inspectorChanges`) is full height on the sheet's solid fill, with a title bar.
  - `inspectorPill` above the composer shows the current tab, an ink dot while Hermes uses it, and
    "+N" for the others. Tapping it opens the sheet. It shows only while the chat has tabs and the
    sheet is closed.
  - When Hermes opens something, the sheet doesn't rise over the chat: the tab waits behind the
    pill. On the Mac and iPad landscape the panel opens.
- **Toolbar** (Mac, iPad): an Inspector button, ink-filled while the panel is open.
- **Tabs** (`inspectorTab`, `InspectorTabChip`): a kind glyph and a short title.
  - The selected tab shows ✕ (on the Mac, any tab under the pointer does).
  - **Ink dot:** Hermes opened the tab (`preview.open`) or acted in it and its turn is still
    running, or Hermes is driving it right now.
  - **Pin:** the tab stays across every chat on that gateway. Pin and unpin from the tab's context
    menu or the strip's … menu.
  - A tab that changes while unseen (new terminal output, a file a turn changed, Changes after a
    turn) bolds its title until it's shown.
  - A Changes tab reads "Changes · 4" once it has looked.
- **+** opens `openMenu` (a popover on Mac and iPad) or `inspectorOpen` (a grid in the iPhone sheet,
  and in an empty Inspector anywhere): everything this chat can show, with live counts, and Open
  Address…. Only kinds with something behind them appear: Files and Changes when the chat has a
  working folder, Terminal when it has processes, Screen when the gateway's Bot Screen is running,
  Plan, Team and Sources when the chat has them. Opening the menu asks the gateway how many files
  are uncommitted and whether the screen runs.
- **Persistence:** a chat's tabs, its selected tab and the commit its latest turn started from are
  kept on the device under its stored session id; pinned tabs are kept per gateway. Which artifact
  version a tab shows and which artifacts may reach the network are kept only while the app runs.
- **Memory:** two minutes after a chat leaves the screen, its Preview tabs let go of their web views
  (one WebContent process each). The tabs stay, and a page loads again when it's next shown. Tabs in
  their own window keep theirs.

## 2. What opens

| Tab | Opens from | Data |
|---|---|---|
| **Preview** (web page, localhost, gateway file: HTML, PDF, image) | `preview.open {url, label}` from Hermes; a page card in the reply (Hermes's `desktop_preview` open); Open Address… (⌘L) and the URL bar | The app's own `WKWebView` (`PreviewController`). Gateway files load through the `hermes-fs` scheme from `GET /api/fs/download` (§2.4). Links in replies open in the browser, not here |
| **Artifact** (HTML, SVG, code) | `artifactCard` in the reply | Found in the reply by the app (§4). Rendered offline in a sandboxed web view; Allow Network is a toggle per artifact |
| **File** | File pills (`fileRefChip`), Open on a diff card, the Files tree, Open File on a change, a file a reply names (a link to it, or a whole path in inline code: `GatewayFileLink`) | `GET /api/fs/read-text?path&profile` (`text`, `language`, `binary`, `truncated` over 512 KB). Save is `POST /api/fs/write-text {path, content}`, after reading the file again: if it changed on the gateway since it was opened, "Hermes changed this file" offers Reload or Keep Mine |
| **Files** | + menu | `GET /api/fs/list?path&profile`, folders loaded as they open; the app also hides `node_modules`, `.git` and `.DS_Store`. Git letters from `GET /api/fs/git-root` and `GET /api/git/status` |
| **Changes** | Review on the latest file-changing turn's `turnCheckpoint` (iPad and Mac; elsewhere Review is its own sheet, [checkpoints.md](checkpoints.md)), Show in Changes on a diff card, + menu, `pane.reveal review` | `GET /api/git/review/list?path&scope&base` with scope `lastTurn` (This Turn), `branch` or `uncommitted`; `GET /api/git/review/diff?path&file&scope&base&staged`; `POST /api/git/review/stage` / `unstage {path, file}`; `commit {path, message, push}`; `create-pr {path}`. `GET /api/git/review/ship-info` finds the branch's open pull request; `GET /api/git/gh-auth` says whether Create Pull Request can work (§2.5) |
| **Terminal** | A process step or the composer's process chip, + menu, `pane.reveal terminal`, ⌥⌘P | One tab for the chat's processes: running first with Stop, then Finished with Clear; a process's page with all its output ([background-processes.md](background-processes.md) §6). Live output from `agent.terminal.output {process_id, chunk}`; `process.list {session_id}` when the tab shows. Stop is `process.kill {session_id, process_id}` |
| **Screen** (the Bot Screen) | + menu | `display.status`, `display.observe` → a single-use ticket → `WS /api/display/ws?display_ticket=` (§2.6) |
| **Team** | `teamCard`, + menu | As in [helpers.md](helpers.md): the team, or one helper's transcript |
| **Plan** | + menu | The latest plan (`todo.updated`), the running turn's first |
| **Sources** | + menu | The latest turn's search results (no gateway call) |

Paths are the gateway machine's. A file path from a pill that isn't absolute is resolved against
the chat's working folder: the live session's `cwd`, else its project's folder, else the gateway's
default folder. A Bot's files are read through its profile (`?profile=`).

A file a reply names opens only here, in that chat's File tab, read through the gateway: never
through the system or another app, since the reply may quote a page or email Hermes read. The
gateway refuses `.env` files, credential stores (`auth.json`, `config.yaml`, `credentials`…) and
anything under `mcp-tokens/` or `pairing/` (`hermes_cli/web_routers/files.py`), and the tab says
so.

Not built yet: Revert in Changes (`POST /api/git/review/revert`), and opening links from replies in
the Preview (⌥-click on the Mac).

### 2.1 Hermes using the Inspector

Hermes's `desktop_ui` toolset exists only for sessions whose platform is `desktop`. The gateway
takes the client's `source` as given (`tui_gateway/methods_session.py`) and folds the toolset in for
desktop sessions (`toolsets.py`), so chats start (`session.create`) and resume (`session.resume`)
with `source: "desktop"` (`PreviewBridge.sessionSource`). Bot Chats keep the source their session
already has.

The tools reach the app as events, and as server requests on the backend socket that the app
answers with `{value: "<json text>"}` (the gateway's `ValueResult`):

| Tool | Reaches the app as | What the app does |
|---|---|---|
| `desktop_preview` `open` / `close` | `preview.open {url, label}`, `preview.close {url}` events | Opens or focuses a Preview tab with the ink dot; closes that tab, or every Preview tab for `url: ""` |
| `desktop_preview` `read` | `preview.read {start, count}` request | `{kind, url, title, text, start, end, total_chars}`: the page's visible text, paged by character (`count` defaults to 8,000, at most 20,000). `kind` is `file` for a gateway file, else `browser`. A page that hasn't loaded answers empty text with a `note` |
| `drive_preview` | `preview.act {action, ref, selector, text, key, submit, full, to, amount, max, allow_shortcut}` | Acts in the page (§2.2) |
| `annotate_preview` | `preview.act` with `action` `pin`, `hold` or `unpin` | Not built yet: answered `{success: false, error: "Unknown action."}` |
| `read_terminal` | `terminal.read {start, count}` | `{total_lines, start, end, viewport_rows, cursor_row, text}` for the process the Terminal's page shows, else the newest running one (40-line window) |
| `close_terminal` | `terminal.close {process_id}` event | Not an exit: the process keeps running. A page showing that process goes back to the list |
| `read_window_below` | `window.read` | Mac: the app, title and bounds of the window behind Hermes's (never pixels; titles need Screen Recording permission). iPhone and iPad answer an error: one app shows at a time |
| `focus_pane` | `pane.reveal {pane}` event | `files`, `terminal` and `review` (Changes) open that tab; `chat` and `sessions` do nothing |
| `preview.restart` (a gateway method, §3) | `preview.restart.progress`, `preview.restart.complete` events | Localhost Preview tabs load again on `complete` |

The app answers a request only while that chat's Inspector is on screen (the panel is open, or on
iPhone the sheet is). Otherwise it declines with error 4404 ("This chat's Inspector isn't on screen
in the Hermes app.", `server_requests.NOT_SHOWN_CODE`), so the gateway stops waiting at once; a
request for a session no chat in the app shows is declined with 4404 too. Hermes Desktop's other
GUI requests (`tour`) are declined as unsupported. `preview.read` and `preview.act` work on the tab
Hermes means: the selected Preview tab, else the newest one Hermes opened, else any. That tab comes
to the front first (a web view that isn't on screen stops running the page's scripts).

### 2.2 While Hermes drives the Preview

- Every Preview page runs `PreviewEngine`, an in-page script whose shapes follow Hermes Desktop's
  `lib/preview-act/types.ts`. `elements` lists up to 120 things that can be clicked or typed into
  under legible refs (`btn-join-the-beta`, `inp-email`) and answers later looks with a delta. An
  action resolves a ref or a CSS selector, acts, waits 220 ms and answers with a fresh look. Back,
  Forward and Reload are the web view's own. A page call that takes longer than 8 s answers that
  it may not have acted.
- A printable key pressed on the page itself is refused unless `allow_shortcut` is set: it would be
  a shortcut.
- The tab has the ink dot.
- `agentHighlight` rings the element for 0.6 s before a click, hover, type or key press, labelled
  "✦ Hermes · click" in ink.
- `agentDrivingBar` floats at the bottom while Hermes acts and for 8 s after its last action: the
  plan's current item (or "Hermes is using this page"), the action and step ("Clicking “Join the
  beta” · step 3 of 5"), Take Over (Hermes's actions are refused; the page stays) and Stop
  (interrupts the turn).
- A touch or key press of the person's own in that page (the page reports only trusted events)
  takes over too: "You're in control" with Hand Back. While the person is in control, `preview.act`
  answers that the person took over and nothing was done. The turn ending clears it.

### 2.3 Auto-refresh

When a `tool.complete` carries an `inline_diff`, localhost Preview tabs that have loaded reload (as
Hermes Desktop does), File tabs the person isn't editing read the file again, Changes tabs and the
Files tree refresh, and the tabs that changed bold until seen. A person's own save refreshes Files
and Changes.

### 2.4 Gateway files in the Preview

A path (`/…`, `~/…` or `file://…`) opens as `hermes-fs://gateway/<path>` (`GatewayFileScheme`). The
app's scheme handler loads each request through the gateway (below), so an HTML file's relative
images, scripts and styles resolve too; PDFs and images show as they would in a browser.

A page reads only from the folders of the files opened in its tab and what's below them, never a
hidden file or folder below them and never a path that steps up (`.` or `..`): `PreviewFileAccess`.
Anything else fails with a permission error, so a page's script can't fetch `~/.ssh` or another
project's files and send them away. The gateway follows symlinks, so the path's text isn't
trusted alone: each request first goes to `GET /api/fs/read-text`, whose `path` is where the file
really is, and that must lie inside where the opened file really is, with nothing hidden below it.
A link in the folder (`keys -> ../../.ssh`) therefore fails like any other path outside it. A text
file up to 512 KB is served from that answer; anything bigger or binary is then downloaded from
the resolved path. A file at the top of the disk (`/index.html`) doesn't open: its folder would be
the whole disk.

### 2.5 Shipping from Changes

- **This Turn** diffs from the commit HEAD pointed at when the chat's latest turn started (recorded
  with `GET /api/git/review/rev-parse?ref=HEAD`). With no turn since the app opened the chat, it
  shows what's uncommitted.
- Each row has a stage box, the status letter (A added or untracked, M, D, R, U conflicted), the
  path and the lines added and removed. Selecting a row shows its diff.
- `shipBar`: the commit message (a subject and a description), the branch ("feature/beta-page →
  main · 3 of 4 files staged"), and **Draft with Hermes**, which asks `llm.oneshot {template:
  "commit_message", variables: {diff, recent_commits, avoid}, session_id}` with the diff and recent
  subjects from `GET /api/git/review/commit-context`. Drafting is asked for, never automatic.
- **Commit and Push** commits what's staged with the message and pushes. **Create Pull Request**
  commits what's staged when there's a message, then `create-pr` (push and `gh pr create --fill`)
  and opens the pull request; when the branch has one already, the button is **Open Pull
  Request**.
- When `gh` is missing or signed out on the gateway, the bar says "Install the GitHub CLI (gh) on
  Studio Mac…" or "Sign in to GitHub on Studio Mac" (the gateway's name) and Create Pull Request is
  off. Errors show inline in git's or gh's words.

### 2.6 The Bot Screen

- `display.status {profile}` says whether the gateway can run Hermes's own desktop and whether it
  runs, and who holds the lease (`holder: agent | human`, `viewer_hash`).
- `display.observe` gives a ticket, a `viewer_id` and the socket path. The socket carries raw RFB
  3.8 (VNC) with security type None, since the ticket already authenticated the viewer; the app
  asks for Raw, CopyRect and DesktopSize (`RFBClient`) and draws the framebuffer itself.
- **Take Control** is `display.lease.acquire {viewer_id, reason}`, **Hand Back**
  `display.lease.release {viewer_id}`. `display.lease`, broadcast to every client, moves the
  controls on every device ("Live · Someone else is in control"). Taps, drags and keys reach the
  screen only while this device holds the lease.
- Close codes: 4000 someone else took control, 4001 the desktop stopped, 4401 the ticket expired
  (the app asks for another once), 4403 viewing isn't allowed from here. Each closed state offers
  Reconnect. The socket closes when the tab leaves the screen.

## 3. Reaching localhost

`preview.open localhost:5173` means the gateway machine's localhost (`localhost`, `127.0.0.1`,
`0.0.0.0`, `::1` and `*.localhost`; `PreviewTarget`). The gateway has no proxy for it.

- **When the gateway runs on this machine** (a Mac running Hermes, or a loopback gateway): loads it
  directly. A Mac recognises itself by host name, address, or a tailnet name that starts with the
  machine's name.
- **Another device:** rewrites the host to the backend's host (usually its tailnet name) and tries
  once. The URL bar still says `localhost:5173`, with "on Studio Mac" when there's room.
  - If that can't connect, the tab shows `reachNote`: "localhost:5173 is on Studio Mac", and why.
  - **Ask Hermes to Share It on the Tailnet** calls `preview.restart {session_id, url, cwd,
    context}`, which starts Hermes's hidden restart agent on the gateway; the context asks it to
    restart the server on the same port listening on all interfaces and to open no tunnels or other
    ports. `preview.restart.complete` reloads the page. If the call fails (an older gateway), the
    same request goes to Hermes as a chat message.
  - **Show a Screenshot Instead** asks Hermes in the chat for a screenshot with its browser tool.
  - **Try Again** reloads.
- Nothing opens a port or a tunnel without being asked.

### 3.1 Pages on this device's network

A web page Hermes opens on this device's own network (a private or link-local address, Tailscale's
100.64.0.0/10, `.local`, `.lan`, `.home.arpa`, `.internal`, `.ts.net` or a single-label name like
`nas`) doesn't load by itself: the tab asks "Open a page on your network?" with **Open <host>**
(`Reach.asks`). An address counts only when the whole host is one (`10.0.0.1.example.com` is a
name), IPv4 written as IPv6 (`::ffff:192.168.1.1`) and `0.0.0.0` count as local, and any other
name is looked up first (`HostAddresses.resolvesLocal`), since a public name (`192-168-1-1.nip.io`)
can point into this network. The gateway's own host is exempt, and an address the person typed in
the URL bar counts as their say-so. Answers last for that tab while the app runs. The check runs
when the tab loads an address (Hermes's `preview.open`, the URL bar, Try Again) and again for every
link, redirect or script navigation inside the page; a frame inside the page that would reach this
network doesn't load at all. A name that changes its answer between the lookup and the load (DNS
rebinding) isn't caught.

### 3.2 Web views

- Web pages load only over http and https (`WebLink.isWeb`); a bare domain gets https, a bare
  localhost address http.
- Each gateway's Preview pages keep their own cookies and storage
  (`WKWebsiteDataStore(forIdentifier:)` with the gateway's id): one gateway's pages never see
  another's.
- Safari's Web Inspector can attach to Preview pages only in Debug builds.
- Open in Browser (the URL bar's Safari button) is offered for http and https pages.

## 4. Artifacts

- **Detection** (`ArtifactDetector`, ported from Hermes Desktop's `lib/artifact-detect.ts` so both
  apps agree): a fenced block in a finished reply is an artifact when it is
  - `html` (or `htm`, `xhtml`): a full document of at least 160 characters, or a fragment with a tag
    of at least 1,200;
  - `svg` of at least 2,000 characters with an `<svg>` element;
  - code of 48 lines or 3,000 characters or more that doesn't read as prose. Untagged fences and
    fences tagged as text, Markdown, logs, output, diffs, patches or Mermaid never are.
- In the transcript the finished reply loses the fence and gets an `artifactCard` instead ("HTML ·
  version 3 · updated just now", Open, or Showing while it's the selected tab). Pages Hermes opened
  during the turn get a card of the same shape.
- **Title and versions:** the title comes from `<title>` or `<h1>`, a file name in a first-line
  comment (`// app.py`), or a named declaration. The same kind, language and title in a later reply
  of the chat, with new content, is a new version. The gateway has no artifact store: versions are
  found again from the transcript.
- **Header** (`artifactBar`): the version stepper, Preview / Code (HTML and SVG), Allow Network (HTML
  Preview), Copy, and Save to the Project…, which asks for a path on the gateway, suggested from the
  working folder and the title (`pricing-card.html`), and writes it with `POST /api/fs/write-text`.
  On a phone the actions fold into a … menu.
- **Rendering** (`SandboxedArtifactView`): a web view with no cookies or storage of its own. The
  artifact loads with `loadSimulatedRequest` from `https://artifact.hermes.invalid/`, a name that
  never resolves. With the network off (the default), the response carries a
  `Content-Security-Policy` header that allows only inline code and `data:`/`blob:` resources:
  `default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline' data:;
  script-src 'unsafe-inline'; font-src data:; frame-src data: blob: about:; form-action 'none'`.
  As a header it covers the page from its first byte, wherever the page's own head sits.
- Only the artifact's own first load is allowed in the main frame (plus jumps within the page), so a
  script or a meta refresh can't take the view elsewhere. A link the person taps to a web page opens
  in the browser. Allow Network reloads the artifact without the policy, for that artifact while
  the app runs.
- SVG renders centred on an empty page. A viewport tag is added when the HTML has none.
- **Code view** (`CodeTextView`, also the File tab's editor): monospaced, with line numbers and
  Xcode's colours (`syntax.*`), lines never wrapping, text selection and the system find bar (⌘F).
  It follows Dynamic Type on iPhone and iPad. In a File tab, lines changed since opening are tinted
  and the status line says "TypeScript · line 8 · you changed 1 line · Hermes sees your edit next
  turn"; a file over 512 KB opens its first 512 KB read only.

## 5. Accessibility

- The tab strip ("Inspector tabs") holds one button per tab, read as "localhost:5173, Hermes is
  using this, tab 1 of 4", with Close and Pin actions.
- The driving bar updates frequently and announces each new step.
- Code and terminal text support text selection; code follows Dynamic Type on iPhone and iPad.
- The Screen view reads "Hermes's screen, live", and Take Control / Hand Back is its own button.
- The URL bar reads as one "Address" button until it's being edited.
- The pill reads "Inspector, localhost:5173, Hermes is using this, 2 more tabs", hint "Opens the
  Inspector".

## 6. Acceptance checks

- `preview.open` from Hermes opens or focuses a Preview tab with the ink dot (behind the pill on
  iPhone); `preview.close` closes it.
- `preview.read` and `preview.act` answer while the Inspector is on screen and decline with 4404
  when it isn't. Hermes can fill and submit the beta sign-up form in the mock's Preview.
- A person's touch in the page while Hermes drives shows "You're in control", and Hermes's next
  action is refused until Hand Back.
- A localhost page from another device rewrites to the gateway's host, or shows `reachNote`; Ask
  Hermes to Share It reloads the page after `preview.restart.complete`.
- A page on this device's network asks before loading; a typed address doesn't.
- A gateway HTML file loads its relative assets, and its script can't read a hidden folder or a
  sibling project.
- An HTML artifact in a reply shows a card; opening it renders it with no network; a later version
  adds to the stepper.
- Editing and saving a file writes it, and a change made on the gateway meanwhile is caught.
- Changes stages files, commits with the message, pushes and creates a pull request, with errors
  shown inline.
- Terminal streams live output and Stop ends the process.
- Screen shows the live desktop, and Take Control / Hand Back move the lease (the mock's `POST
  /api/mock/inspector/screen` with `evict` and `stop` shows 4000 and 4001).
- Tabs come back with the chat; pinned tabs stay across chats; a tab dragged out on the Mac returns
  when its window closes.
- Light, dark and Increase Contrast match the design.

## 7. Setup

Most tabs need Bot Mode ([setup.md](setup.md) §4.1).
