# Hermes for iPhone, iPad and Mac

A native SwiftUI client for [Hermes Agent](https://hermes-agent.nousresearch.com/) by Nous Research,
in the spirit of the Grok apps on Apple platforms: a monochrome canvas, one floating
Liquid Glass composer, user bubbles against full-width replies, a drawer on iPhone and a
split view on iPad and Mac.

## What it does

- **Gateways**: connect any number of Hermes gateways (`hermes gateway` with the API server
  enabled), including multiplexed profiles at `/p/<profile>`. Keys are kept in the Keychain.
- **Conversations**: server-side sessions from every surface (this app, Telegram, Discord,
  Slack, the CLI…), grouped by date, searchable, with rename, pin, branch and delete.
- **Live agent turns**: replies stream in with a timeline of what Hermes is doing (tool calls
  with previews and durations, narration, subagents, and reasoning once the turn is stored).
  Stop a turn, approve or deny commands inline, and pick the model and reasoning effort.
- **Resilient**: text turns run as detached `/v1/runs`, so leaving the app doesn't kill the
  agent; the app re-attaches to the event stream (`last_seq` replay) when it comes back.
- **Images**: attach from Photos, the camera, Files, paste or drag and drop.
- **Projects**: a project is a set of folders on the gateway with a colour and a glyph. Its chats
  run in its primary folder and group by branch, worktree and task worktree, as in Hermes Desktop;
  start a chat in a project, move chats between projects, and see what Hermes knows about it.
  Needs Bot Mode (the `projects.*` calls are on the backend's socket).
- **Helpers**: when Hermes splits a task across sub-agents, the turn shows the team live (what
  each helper is doing, numbered 1, 2… and 1.1 when nested), then folds into a summary. The Team
  page (iPhone, iPad portrait) or Team inspector (Mac, iPad landscape, ⌥⌘T) lets you stop or steer
  one helper, read its live transcript, and pause new helpers on the gateway. Finished runs are
  saved to the gateway's spawn-tree archive and reopen after a restart. Needs Bot Mode.
- **Apps and Tools** (Settings → Hermes on <gateway>; a tab in the Mac's Settings): apps
  connected through Nous (accounts, sign-in in the browser, which tools Hermes may use — writes
  and destructive tools tagged, destructive ones off when you connect), MCP servers (live status,
  add from the catalog or by command/URL, tested before they're saved), plugins (install from the
  catalog or a git link, settings, updates that ask before widening access) and the built-in
  toolsets. Keys are write-only: the app shows an env name and "Set", never the value. Needs Bot
  Mode.
- **Undo and checkpoints**: with checkpoints on, Hermes saves a chat's folder before a turn edits
  files. A reply that changed files ends with an undo bar: Review what changed, or Undo (the files
  go back, the turn leaves the chat, your message returns to the composer; it waits while Hermes
  works). Checkpoints… (a chat's menu; on the Mac the Chat menu, ⌥⌘Z for Undo) lists older points,
  restores one file at any time or all of them, and turns checkpoints on when they're off. Needs
  Bot Mode.
- **Memory**: what Hermes (or a Bot) remembers between chats — About You and Hermes's Notes — in
  Settings → Hermes on <gateway> → Memory, Edit Bot → What <Bot> Remembers, and the Mac's Settings
  → Memory. Edit, copy or forget any entry (Forget and Reset always ask: the gateway can't undo
  them), review saves staged while nobody could answer, switch either store off, turn on Ask
  Before Saving (the chat then asks "Save to memory?": Don't Save, Save, Save All in This Chat),
  and pick a ready memory provider. A reply that saved something ends with "Remembered: …"; tap it
  for the entry. Memory is read at the start of a chat, so changes apply from the next one. Entries
  are never logged, cached or indexed. Needs Bot Mode.
- **Board**: a project's cards that Hermes and its Bots work through on their own (the gateway's
  kanban), from the project home's Board row (on the Mac, under the project in the sidebar, or ⇧⌘B).
  One column at a time on iPhone, opening where something needs you; columns side by side on iPad
  and the Mac, the card in an inspector (a sheet on iPad in portrait). Columns and every move come
  from the gateway's workflow, and the board updates live. A card that needs you takes your answer
  (Reply and Continue sends it back to Ready); a review shows its PR checks, and Approve says which
  check failed when it's refused; Stop ends a run and Watch follows its chat. New Card picks who
  works on it, Hermes first, or lets Hermes write it up. On the Mac, drag cards between the columns
  they may go to, ⌘-click several for Move, Assign and Archive, ⌘N for New Card and ⌘→ / ⌘← to move
  the selected card. Cards Hermes adds from a chat are listed under its reply, with Open Board.
  They're always "cards": Tasks are scheduled jobs. Needs Bot Mode.
- **Inspector**: one panel beside the chat (a two-height sheet on iPhone and iPad in portrait, with
  a pill above the composer) where anything from the chat opens as a tab: Preview (pages,
  localhost, files on the gateway), Artifact (HTML, SVG and long code from a reply, versioned and
  sandboxed with no network unless allowed), File (edit and save, with "Hermes changed this file"
  when it changed meanwhile), Files (the project tree with git letters), Changes (This Turn,
  Branch, Uncommitted; stage, commit and push with a message Hermes drafts on request, create a
  pull request), Terminal (background processes and their output, Stop), Screen (the Bot Screen,
  Take Control and Hand Back), Team, Plan and Sources. Hermes opens Previews itself and drives
  them (reading, clicking, typing) with the target ringed for 0.6 s and a bar to Take Over or
  Stop; touching the page pauses it. A localhost page the device can't reach says where it runs
  and offers to have Hermes share it on the tailnet. Pinned tabs stay across chats; the others
  come back with the chat. ⌥⌘I shows it, ⌘L opens an address, ⌘⌥1–9 switch tabs, and on the
  Mac a tab drags out into its own window. Chats start as the gateway's desktop platform so
  Hermes has its Inspector tools. Needs Bot Mode.
- **Search**: the chat search finds words inside chats, not just titles (with Bot Mode; titles
  only without it): one row per chat with the matching words in bold, chips for Chats, Projects,
  Bots and Tasks, and where each chat lives. Opening a result jumps to the message and flashes it.
  On the Mac, ⌘K opens a keyboard-only palette (chats, projects, actions) and ⌘F finds in the open
  chat.
- **Tasks**: Hermes' scheduled jobs — create, run now, pause, resume, delete. On iPad and the Mac
  the list sits beside the selected task, with its recent runs (each one a chat).
- **Skills**: browse the gateway's skills (a grid of cards on iPad and the Mac); Use puts one in
  the composer's tray. Tools and Apps opens Settings → Apps and Tools.
- **Voice**: talk to Hermes or a Bot hands-free. Full screen on iPhone, the conversation beside it
  on iPad in landscape, a floating panel on the Mac (⌥⌘V).
- Markdown with tinted code blocks, tables, task lists and quotes; copy, share and read aloud.

## Bot Mode

Hermes Desktop's Bots, natively. Link a gateway to its Hermes backend (`hermes serve`, the
server Hermes Desktop and the dashboard use) and the sidebar gains a **Chats | Bots** switch:

- **Roster**: every profile is a Bot with a face (Desktop's seven shapes and colours, or a
  photo), name, role, latest line, "Active now" and unread state, polled every 5 s
  (`profiles.list`), pinned first then by recency. Hidden Bots fold away.
- **Bot Chat**: each Bot's one forever conversation (the session titled exactly "Bot Chat"),
  over the backend's JSON-RPC socket (`/api/ws`): streaming replies, tool calls, reasoning,
  approvals as server requests, stop, images, and catch-up after a reconnect. `/new` compacts
  instead of resetting, like Desktop. Lookups fail closed, so a hiccup never mints a second chat.
- **@mentions**: type `@` for the roster; the app adds Desktop's roster note so the Bot can
  `message_agent` its teammates. Messages from other Bots and routine results show as their own cards.
- **Routines**: a Bot's cron jobs: add (daily, weekdays, weekly, every few hours, once, or
  cron), pause, run now, delete, and have results posted into the Bot Chat.
- **New and edit Bot**: name, role and look with a live preview; creation clones your main
  profile's setup and says hello, exactly like Desktop.
- Faces are alive: they blink, glance at the composer while you type, look up while they
  think and squint happily when a reply lands. A Metal shader gives each Bot a drifting aura;
  poke a face for a ripple.

Sign-in: **Automatic** reads the token a local, ungated backend injects into its start page
(Desktop's way); **Session token** for a pasted token; **Username & password** for a gated
backend (its session cookies go to the Keychain and refresh themselves).

## Pairing another device

Once a gateway is connected, **Pair a Device…** (gateway menu, or File on the Mac; the Mac
offers it right after connecting) shows a QR code with the Hermes wing in the middle. Scan it
with the iPhone Camera app or **Scan Pairing Code** in Hermes (onboarding and Add Gateway) and
the phone connects to the same gateway and Bot Mode backend.

The code is a `hermesapp://connect?v=1&gateway=…&key=…&backend=…&signin=…` link
(`PairingLink` in HermesKit; Debug builds register `hermesapp-dev`). It carries the gateway's
API key, so it stays frosted until **Show Code**. A session token travels only for token
sign-in; cookies never do, and a password-gated backend asks for its password on the new
device. Loopback addresses (`127.0.0.1`) can't pair: use the machine's Tailscale or network
address, e.g. Tailscale Serve's `https://<mac>.<tailnet>.ts.net:8642`.

## Push notifications

Approvals, questions, password prompts, finished replies, scheduled tasks, board cards (one needs you,
ready for review, stopped, done; Reply answers a card that needs you) and Bot messages reach the
iPhone and iPad when Hermes isn't on screen, plus a Live Activity for long turns. Hermes Agent
can't push to Apple, so a gateway plugin seals each notice for each device and sends it through a relay:

```
gateway plugin (Tools/hermes-app-push, public: vburojevic/hermes-app-push)
  ──HTTPS──▶ push.hermesapp.dev (Relay/, Convex; holds the APNs key, sees no content)
  ──APNs──▶ Notification Service Extension (decrypts) ▶ notification / Live Activity
```

- App side: `Push/` (app layer, extensions, widget) and `Packages/HermesKit/Sources/HermesPush` (crypto,
  notices, categories, Live Activity state). The iPhone and iPad app embeds three extensions (service,
  content, widget) sharing the App Group `group.co.caffeinatedcode.hermes` (`.dev` for Hermes Dev); iOS
  releases sign them by hand with four App Store profiles (`Scripts/release.sh`). The Mac uses local
  notifications only.
- Set up a gateway: `hermes plugins install vburojevic/hermes-app-push --enable`, then restart it; or
  Settings → Notifications → Set Up… → Ask Hermes to Set It Up.
- Try it with the mock: `python3 Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642
  --push-relay https://push.hermesapp.dev` (real APNs sandbox to an Apple-silicon simulator; `simctl` is the
  default but never runs the service extension, and `none` plays a gateway without the plugin). In a Bot
  Chat: "approve", "ask", "sudo" and "long" (a Live Activity turn, "long … approve" asks mid-way).
- Simulator: use iOS 26.5. The iOS 27.0 simulator never shows the notification permission prompt.

## Requirements

- Xcode 27 (iOS 27 / macOS 27 SDKs). Deploys to iOS, iPadOS and macOS 26 or later.
- A Hermes Agent gateway with the API server enabled. On the machine running Hermes, add to
  `~/.hermes/.env`:

  ```bash
  API_SERVER_ENABLED=true
  API_SERVER_KEY=<a long random key, 16+ characters>
  API_SERVER_HOST=0.0.0.0   # so your phone can reach it; keep to a trusted network
  ```

  then `hermes gateway restart`. In the app, enter `your-mac.local:8642` (or an `https://`
  URL behind a reverse proxy or Tailscale) and the key. The add-gateway sheet can generate a
  key and copy the snippet for you.

## Project layout

```
project.yml               XcodeGen spec (one multiplatform target: iOS + macOS)
App/                      SwiftUI app
  Model/                  AppModel, BotWorkspace (per gateway), BotRoster (Bot Mode),
                          ConversationModel (turn engine for sessions and Bot Chats)
  Views/                  Chat, Composer, Sidebar, Bots, Markdown, Onboarding, Settings, Tasks, Skills
  Design/                 Theme, the Hermes wing mark, BotFace, Metal shaders, shared components
Packages/HermesKit/       Swift package, no UI
  HermesKit               API client, SSE parser, models, transcript folding, live-turn reducer,
                          backend client + JSON-RPC gateway socket, Bot models, @mentions
  HermesMarkdown          swift-markdown → render tree, code highlighter
Tools/IconGen/            Renders the app icons from the same path the UI draws
Tools/mock-hermes/        Stdlib-only mocks: the gateway (server.py) and the backend (backend.py)
```

The API contract was taken from the Hermes source (`gateway/platforms/api_server*.py`), not
guessed: SSE framings differ per route, session-stream disconnects cancel the turn while
`/v1/runs` survive them, images are stored only as `[screenshot]` placeholders (the app keeps
its own copy), and compression can rotate a session's id mid-turn.

## Building

```bash
xcodegen generate
open Hermes.xcodeproj
```

Everything is Caffeinated Code d.o.o. (team `29ZNGBT83H`).

| | Debug | Release |
|---|---|---|
| App | **Hermes Dev** (amber icon) | **Hermes** |
| Bundle id | `co.caffeinatedcode.hermes.dev` | `co.caffeinatedcode.hermes` |
| Mac data folder | `Application Support/co.caffeinatedcode.hermes.dev` | `Application Support/co.caffeinatedcode.hermes` |
| Keychain, settings | its own | its own |
| Demo bootstrap (`HERMES_BOOTSTRAP_*`) | yes | compiled out |
| Mac updates | off | Sparkle |

Dev builds can point at the mocks freely; they can never touch the real app's gateways or keys, and
both run at the same time on one Mac. (`Application Support/Hermes` belongs to Hermes Desktop; the app
never writes there, and moves its own files out of it if build 2610121617 put them there.)

## Releasing

`Scripts/release.sh` runs on the trusted studio Mac and ships both platforms:

- **iPhone and iPad → TestFlight**: App Store Connect app *Hermes Agent App* (`6822000332`), signed
  with the escrowed Apple Distribution identity and the *Hermes App Store* profile, validated, then
  uploaded. The *Internal Testers* group gets every build automatically.
- **Mac → notarized DMG with Sparkle**: Developer ID signed (Sparkle's nested code re-signed
  inside-out with Hardened Runtime), notarized and stapled, then published with its `appcast.xml`
  as a release on [vburojevic/hermes-releases](https://github.com/vburojevic/hermes-releases).
  The app reads `…/releases/latest/download/appcast.xml`.

```bash
Scripts/release.sh --dry-run        # sign, validate, notarize and package; publish nothing
Scripts/release.sh                  # ship iOS to TestFlight and the Mac DMG
Scripts/release.sh --mac-only       # or --ios-only
```

Signing identities come from Infisical prod `/shared/apple/signing-caf73-20261005-e4rd77v8r4`
into a temporary keychain that is deleted on exit (macOS can't import the escrow's AES PKCS#12, so
it is re-wrapped in a private temp folder first). Uploads and notarization use the studio ASC key.
Sparkle's EdDSA private key is Infisical prod `/hermes/ci/SPARKLE_ED_PRIVATE_KEY`; its public half
is baked into every Mac build, so it must never change. Build numbers are UTC `yyMMddHHmm`.

Tests (90 Swift Testing tests covering the client, SSE parser, transcript folding, live turns,
Markdown, highlighting, the gateway socket frames, Bot roster decoding, @mentions, routines and
backend event mapping):

```bash
cd Packages/HermesKit && swift test
# plus a round trip over a real WebSocket against the mock backend:
HERMES_MOCK_BACKEND=http://127.0.0.1:19119 swift test --filter BackendIntegrationTests
```

## Trying it without a real gateway

```bash
python3 Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef
```

Then add `localhost:18642` with that key, or launch a Debug build with
`HERMES_BOOTSTRAP_URL=http://127.0.0.1:18642` and `HERMES_BOOTSTRAP_KEY=…` in the environment.
Messages containing "approve" ask for permission, "slow" runs a long multi-tool turn, and
"fail" fails.

For Bot Mode, also run the mock backend (four Bots with Bot Chats, routines, a photo avatar,
an active worker and a routine that posts every couple of minutes):

```bash
python3 Tools/mock-hermes/backend.py --port 19119            # ungated: Automatic sign-in
python3 Tools/mock-hermes/backend.py --port 19119 --password pw   # gated: admin / pw
```

and turn on **Bot Mode** for the gateway with `127.0.0.1:19119`, or add
`HERMES_BOOTSTRAP_BACKEND=http://127.0.0.1:19119` to the Debug launch environment. "approve",
"slow" and "fail" work in Bot Chats too, and `@mentioning` another Bot drops a message in its chat.

With `--gateway-port 18642` the backend also has projects (`Tools/mock-hermes/projects.py`): the
design's Hermes App, Homelab, Blog, Hermes Agent fork and dotfiles, an archived Portfolio written
by the desktop app, and the found repos caffeinated-site and typedock. "Fix the reconnect after
sleep" runs a long test turn so Hermes App shows as working. Debug flags: `-HERMES_OPEN projects`,
`-HERMES_OPEN project:p_4f2a9c1e` (`-HERMES_PROJECT_LANE <lane id>`, `-HERMES_PROJECT_EXPAND <id>`),
`-HERMES_OPEN project-chat:<id>`, `-HERMES_PROJECT_SHEET new|edit:<id>|move:<session>|runin` and
`-HERMES_DRAWER YES`.

It also has helpers (`Tools/mock-hermes/helpers.py`), shaped like Hermes' background delegation. A
message with "helpers" (or "swift 6") runs a team of four: one auditing for over a minute, one done
in seconds, one timing out, one waiting for a free slot; "nested helpers" runs a lead with three
sub-helpers; add "slowly" for screenshots. A steer containing "late" lands after the helper's last
step (missed) and one containing "reject" is rejected. "Swift 6 readiness check" has a saved past
run. Debug flags, after `-HERMES_SEND`: `-HERMES_HELPERS team|helper:<n>|steer:<n>|stop:<n>`,
`-HERMES_HELPERS_AFTER <seconds>` and `-HERMES_HELPERS_NOTE <text>` (sends the steer).

And Apps and Tools (`Tools/mock-hermes/connections.py`): GitHub with two accounts and 38 tools
(one blocked by the organization), Gmail, Linear signed out, Slack; Notion, Google Calendar and
Figma to connect (the sign-in page returns to the app after a few seconds); MCP servers
filesystem, github (from a plugin), sentry failing with a 401 until its key changes, and postgres
starting when needed; presets Brave Search, PostgreSQL and Playwright; plugins Xcode, Blender (app
not running) and homeassistant with an update that asks for shell access; eight built-in toolsets
with image generation off. `mock.nous {"signed_in": false}` shows the Nous sign-in state and
`mock.connections.reset` puts everything back. Debug flags, after `-HERMES_OPEN settings`:
`-HERMES_APPS_TOOLS apps|mcp|plugins|builtin`, with `:<app slug>`, `:<server>`, `:<plugin key>`,
`mcp:add` or `plugins:update` (on the Mac the flag alone opens the Apps & Tools tab).

And checkpoints (`Tools/mock-hermes/checkpoints.py`), shaped like `hermes serve`: the chat "Reconnect
and backoff" in Hermes App has three turns that edited files and four checkpoints (14:31, 13:02,
yesterday 18:40 twice); a restore overwrites the files (files created later stay), drops the newest
turn and reports Models/weights.bin as too large to checkpoint; a whole restore mid-turn is refused
with 4009. New turns in a project folder save a checkpoint before their first edit. `--checkpoints
off` starts with them off (Turn On writes `PUT /api/config`; open chats keep the old setting until
reattached); `mock.checkpoints {"enabled", "now", "busy", "container"}` switches states and
`mock.checkpoints.reset` puts everything back. Debug flags: `-HERMES_OPEN chat:prj_undo` with
`-HERMES_CHECKPOINTS review|undo|timeline|detail[:n]|restore-all[:n]|off`.

And memory (`Tools/mock-hermes/memory.py`), shaped like the gateway's `/api/learning/*`,
`/api/memory*` and `/memory` command: six things about you, fourteen notes (94% full) and two saves
waiting for review; Research Buddy has its own. Edits over a store's cap and stale ids are refused
with the gateway's words. In a chat, "remember …" or "vegetarian" saves (asking "Save to memory?"
first while Ask Before Saving is on), "in a task" stages the save for review, "forget …" removes,
"beta 3" updates and "three things" saves a batch. `POST /api/mock/memory/reset` puts it all back.
Debug flags, with `-HERMES_OPEN settings`: `-HERMES_MEMORY about|notes|options|edit:<n>|reset|bot:<profile>`
(on the Mac it opens Settings → Memory).

And the Board (`Tools/mock-hermes/kanban.py`), shaped like the gateway's kanban plugin
(`/api/plugins/kanban/*` and its event socket): Hermes App's board as the design draws it (two
running, one quiet for 9 minutes, a card that needs Ada's answer, one that gave up, a review with its
PR checks, a split card). A pretend dispatcher picks up cards that become Ready while it runs, works
on them for 20 s with worker output, and finishes them; seeded cards stay put. Refusals use the
gateway's words. In a chat, "… as cards" adds three cards with `kanban_create`. `POST
/api/mock/kanban/act {card, action: needs_input|review|gave_up|complete|stale}` drives a card
(`review` takes `ok: false` for a failing check), `POST /api/mock/kanban/config {dispatcher, socket}`
pauses the dispatcher or refuses the socket (the app then polls every 5 s), and `POST
/api/mock/kanban/reset` puts it back. Debug flags: `-HERMES_OPEN board:<project id>` with
`-HERMES_BOARD_COLUMN <column>`, `-HERMES_BOARD_CARD <card id>` and
`-HERMES_BOARD_SHEET new|assign|reopen|watch|edit`.

And the Inspector (`Tools/mock-hermes/inspector.py`): a "Hermes Site" project
(`/Users/studio/Code/hermes-site`) with files (`/api/fs/*`), git status and review with four
changed files, staging, commits, pushes and pull requests (`/api/git/*`), a dev server on
`127.0.0.1:5173` (`--dev-port`) serving the beta sign-up page, `preview.restart`, `llm.oneshot`
drafts, and the Bot Screen over RFB (`display.*`, `WS /api/display/ws`) with the lease. Its chat
"Pricing card" has two versions of an HTML artifact. In a chat, "… sign-up" or "… beta" writes the
page, starts `npm run dev`, opens it in the Preview and drives it (`preview.act`, `preview.read`);
"pricing" adds an artifact version; "terminal" reads the Terminal. Mock-only: `POST
/api/mock/inspector/screen {action: evict|stop|start}` (close codes 4000 and 4001),
`…/gh {authenticated, available}`, `…/touch {path, text}` (a change on the gateway), `…/dev
{running}`, `…/pace {seconds}` (slower driving, for screenshots) and `…/turn {session, text}`.

And full-text search (`Tools/mock-hermes/search.py`), shaped like `hermes serve`'s
`/api/sessions/search`: "reconnect" matches seven chats across Hermes App's lanes, a task run of
Check NAS backups and Ada's "Release notes draft"; prefixes match ("reconn"), `source`/`profile`
filters work, and replies take 150 ms. Tasks have three recent runs, one failed
(`/api/cron/jobs/<id>/runs`). Debug flags: `-HERMES_SEARCH <text>` types into the chat search
(with `-HERMES_DRAWER YES` on iPhone), `-HERMES_PALETTE <text>` opens the Mac's ⌘K palette,
`-HERMES_OPEN chat:<session id>` opens a chat, and `-HERMES_VOICE_PREVIEW YES` shows Voice without
the microphone.
