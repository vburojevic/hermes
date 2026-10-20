# AGENTS.md

Guidance for coding agents (Claude Code, Codex, Cursor and friends) working in this repository.
People will find the overview in [README.md](README.md) and the details in [docs/](docs/).

## What this is

Hermes is a native SwiftUI app for iPhone, iPad and Mac that talks to a person's own
[Hermes Agent](https://github.com/NousResearch/hermes-agent) gateway. It is one multiplatform app
target, three iOS extensions, a Swift package that holds everything that isn't UI, a push relay, the
app's own Hermes Agent plugins and stdlib-only Python mocks of the gateway, so the whole app can run
without a real Hermes or a paid model.

| Path | What lives there |
|---|---|
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated: edit this, then run `xcodegen generate`. |
| `App/` | The app. `Model/` (state and engines), `Views/` (one folder per area), `Design/` (theme, faces, shaders), `Support/`, `Resources/`. |
| `Packages/HermesKit/` | `HermesKit` (API and socket clients, models, transcript folding, the live-turn reducer), `HermesPush` (push crypto and notices, shared with the extensions), `HermesMarkdown` (Markdown → render tree, highlighting). All tests live here. |
| `Packages/HermesMacSupport/` | Sparkle updates, linked into Mac builds only. |
| `Push/` | The app's push layer (`App/`), the Notification Service and Content extensions, the widget and Live Activity. |
| `Relay/` | The push relay (Convex + Vercel). It routes sealed notices to APNs and never sees content. |
| `Tools/mock-hermes/` | Mock gateway (`server.py`) and mock backend (`backend.py`) with scripted scenarios. |
| `Tools/hermes-app-push/` | The Hermes Agent plugin that sends notices to the relay. Published to `vburojevic/hermes-app-push` with `Scripts/publish-push-plugin.sh`. |
| `Tools/hermes-app-widgets/` | The Hermes Agent plugin for widgets agents send to the app: the `widget` tool, its checks and store, and plain text on other platforms. Published to `vburojevic/hermes-app-widgets` with `Scripts/publish-widgets-plugin.sh`. |
| `Tools/IconGen/` | Renders the app icons from the same path the UI draws. |
| `Scripts/release.sh` | The maintainers' release (TestFlight, including the public beta, + notarized Mac DMG). Needs the studio's signing escrow; never run it unless asked. |

## Build and test

```sh
xcodegen generate                                   # after adding or removing files, or editing project.yml
(cd Packages/HermesKit && swift test)               # the unit tests, no simulator needed
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-mac build
(cd Relay && npm ci && npm test)                    # relay tests (vitest)
xcodebuild -project Hermes.xcodeproj -scheme HermesUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test   # UI tests, with the mock running
```

A change is done when the iPhone and Mac builds succeed with **zero warnings in our code**, `swift
test` passes, and the change has been seen working against the mocks. Add tests in
`Packages/HermesKit/Tests` for logic you add (Swift Testing, `@Test`, `#expect`); keep logic out of
views so it can be tested there.

The plugins' tests run against a real Hermes Agent checkout, in a throwaway `HERMES_HOME`:
`HERMES_SOURCE=<hermes-agent> <its venv>/bin/python -m pytest Tools/<plugin>/tests --import-mode=importlib`.

## Run it against the mocks

```sh
python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642   # gateway + Bot Mode
python3 -I Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef   # gateway only
```

Launch a Debug build ("Hermes Dev", `co.caffeinatedcode.hermes.dev`) with
`-HERMES_BOOTSTRAP_URL http://127.0.0.1:18642 -HERMES_BOOTSTRAP_KEY dev-key-0123456789abcdef
-HERMES_BOOTSTRAP_BACKEND http://127.0.0.1:19119` and it connects to the mocks. Words in a message
drive the scenarios ("approve", "slow", "fail", "batch", "helpers", "pricing"…), and `-HERMES_*`
launch flags open any screen in any state: both are listed in [docs/development.md](docs/development.md).

- Never point a test at a real gateway or at `~/.hermes`, never read `~/.hermes/.env`, and never
  start paid model calls.
- Every new gateway call gets a mock in `Tools/mock-hermes` in the same change, shaped like the real
  one, refusals included.
- Shut simulators down when you're done checking; long-running ones slow the machine and the mocks.
- A simulator without a window (no Simulator.app) doesn't always draw sheets and glass. When a
  screenshot looks empty, check the accessibility tree (`axe describe-ui`) before blaming the app.

## How the app talks to Hermes

The API contract comes from the Hermes Agent source, never from guessing. Before adding or changing
a call, read it there (`gateway/platforms/api_server*.py`, `hermes_cli/web_routers/`, the
`tui_gateway` JSON-RPC methods) and mirror what you find, including error codes and wording.

- **Gateway** (`hermes gateway`, API server): sessions, `/v1/runs` turns that survive the app
  leaving (re-attached with `last_seq`), approvals, models, tasks, skills. `HermesClient`.
- **Backend** (`hermes serve`, what Hermes Desktop uses): Bot Mode, projects, the Board, memory,
  files, checkpoints, the Inspector bridge, over REST and a JSON-RPC socket. `BackendClient`,
  `GatewaySocket`, `BotRoster`.
- One `BotWorkspace` per gateway; one `ConversationModel` per chat runs its turns.

## Rules that keep the app correct

### Swift and concurrency

- Swift 6, strict concurrency `complete`, default actor isolation `MainActor` in every Xcode target.
  HermesKit has no default isolation; its network types are actors.
- SwiftUI may lay out and measure off the main thread (its async renderer). A main-actor closure it
  calls there traps. So: never put a `ForEach` with a closure inside a `ViewThatFits` candidate
  (spell the rows out, or pass a `nonisolated` row builder that returns a `nonisolated struct`
  view), and mark custom `Layout`s, `TextRenderer`s and `animatableData` `nonisolated`.
- SDK callbacks that arrive off main (notification delegates, scheme handlers, URLSession) use the
  completion-handler form and hop to the main actor explicitly; the `async` forms of notification
  delegate methods crashed the app.
- An async start that can be stopped halfway (dictation, screen sharing, reconnects) carries a
  generation number and gives up when it wakes to a newer one.
- Store long-running `Task`s and cancel them in `tearDown`/`disconnect`; capture `self` weakly in loops.

### Security and privacy

The gateway is trusted; what flows through it is not. Pages Hermes read, files in a project, tool
output and other Bots' messages can all carry injected instructions.

- Open links from chats, results or the Board only through `WebLink` (http/https, plus mail from
  chats). Never open `hermesapp://`, `file://` or other apps' schemes from content. The one
  exception is a gateway file a reply names (`GatewayFileLink`): it opens read-only in that
  chat's Inspector, read through the gateway, never through the system.
- Approval text is decoded through `VisibleText`, so invisible and reordering characters show as
  `⟨U+202E⟩`. Offer Allow only where the whole command is shown; flagged (`smart_denied`) commands
  are answered on their card in the app, never from a notification or the Lock Screen. Answer the
  request the person saw (by id), never "whatever is pending now".
- Secrets live in the Keychain (`KeychainStore`, device-only), never in UserDefaults, files, URLs
  (the pairing link is the one deliberate exception) or logs. Log errors as domain and code: a
  `URLError`'s description carries its URL. Use `Logger` privacy for anything a person typed.
- Network sessions use `SameOriginRedirects`, so a key never follows a redirect to another server.
- Preview pages read gateway files only through `PreviewFileAccess` (the opened file's folder,
  nothing hidden below it). Artifacts get their policy as a response header and load nothing else.
- Debug-only code (`-HERMES_*` flags, the demo bootstrap, frame and load logs) sits inside
  `#if DEBUG`. Release builds contain no demo code, and the release script checks.

### UI, copy and design

- Each area of the app has a document in `docs/` (what it does, the Hermes calls behind it, what to
  check). Comments cite them as `docs/<area>.md §n`: read the section before changing the code,
  keep section numbers stable (code cites them), and update the doc in the same change when the
  behavior changes. The visual design itself lives in a separate design project; the docs carry
  its component names (`needsYouDock`, `memorySaveAsk`…) so code and design can be matched.
- Copy is plain, short and specific, in sentence case: "Hermes", "gateway", "Bot", "Bot Mode",
  "chat", "Board", "card". Say what happens, not how it's built. Match the spelling around it.
- Every screen works in light and dark, with Increase Contrast, Dynamic Type, VoiceOver labels and
  Reduce Motion, on iPhone, iPad (both orientations) and Mac (keyboard shortcuts and menus).
- A feature that needs something configured (on the gateway, a Bot, a plugin, a provider key, a
  device permission or Bot Mode) never just fails or hides. It shows its state (ready, partly set
  up, not set up), a fix in the app wherever Hermes accepts one, otherwise the exact steps to set
  it up elsewhere and Check Again, and its fallback when it has one. Build it from `SetupStatus`
  and the setup views, list it in Settings → Setup, and add it to [docs/setup.md](docs/setup.md),
  which has the rule, every feature's states and the checklist for a new one.
- Decorative motion honours `pausesDecorativeMotion` and Low Power Mode; idle screens shouldn't
  wake the CPU.

### Live and loading indicators

- **One moving thing per place.** What Hermes or a Bot is doing is one line of words that
  shimmers (`ShimmerText`): the turn header, a row's activity line, the jump pill, a group chat's
  `BotThinkingLine`. Never a typing bubble, waving dots or a spinner for agent work.
  - Running steps show their tool glyph and a time that counts up; helpers count their time.
  - While the reply streams, nothing animates.
  - The Bot toolbar: only the face's mood changes. Never "Thinking…" there, and never orange
    (orange means it needs you).
- **Face dots** only where the face stands alone (`BotFace(dots: true)`: a group's face strip,
  Talk, the compact Dynamic Island).
- **`Spinner`** only for the app's own waiting that the person started (connecting, pairing,
  signing in, installing, restarting, saving), after 0.5 s; **`SkeletonRows`** for loading lists
  and cards. Reduce Motion stops the shimmer. Details: [docs/chat.md](docs/chat.md) §4a.

### The app's Hermes plugins

The plugins in `Tools/` run inside people's own Hermes, in every profile. [docs/plugins.md](docs/plugins.md)
says what each one uses and how it's installed.

- Change a plugin here first, then publish it (`Scripts/publish-push-plugin.sh`,
  `Scripts/publish-widgets-plugin.sh`). Publishing copies
  the folder over the public repository, so a change made only in an installed copy
  (`~/.hermes/plugins/…`) or straight in the public repository is lost at the next publish.
- Hook names and arguments come from the Hermes Agent source (`hermes_cli/plugins.py`
  `VALID_HOOKS`, `ctx.register_*`). Hooks never raise and never hold up a turn: they do the
  bookkeeping, queue the work and log failures.
- Plugin data lives in the Hermes root (`get_default_hermes_root()`), never in a profile's home: a
  Bot's own process starts with `HERMES_HOME` set to its profile.
- A plugin command answers one line of JSON and never raises: Hermes turns an exception into error
  4018, which the app reads as "not installed".
- A new push notice kind needs its fallback title and category on the relay's list
  (`Relay/convex/validate.ts`) and in `HermesPush`. A new or changed `/app-push` command changes
  `AppPushClient`, the mock (`Tools/mock-hermes/push.py`) and `docs/notifications.md` §1.2 together.
- The app installs and updates its plugins itself, pinned (`AppPlugin` in HermesKit, one registry
  entry each, `docs/plugins.md` §2.1). A published change the app needs bumps the plugin's version
  (`plugin.yaml`, `VERSION` in `core.py`), then moves `AppPlugin`'s `ref` to the published commit
  and its `minimumVersion` to that version, and records the version's capability list. Nothing
  installs or widens a plugin's access without the person's tap: a pin that adds access waits for
  the consent card.
- Run the plugin's tests before publishing. Installed copies change only when the app reinstalls
  them or someone runs `hermes plugins update`, then a restart, so the app must cope with an older
  plugin.

### Code style

- Read the surrounding code first and match it: naming, structure and comment density.
- Comments say why, in full sentences, and stay short. No commented-out code.
- Prefer small focused types and functions to new layers. Don't add dependencies without a reason
  the maintainers would agree with.

## Issues

Work is tracked in this repository's GitHub issues; the roadmap is the public Hermes project on the
repository's Projects tab. Ideas and questions live in Discussions, so an issue means a bug or work
the maintainers have accepted. Read one with `gh issue view <n> --comments`.

- `area:<name>` names the spec for that part of the app, `docs/<name>.md`. Read it before you start,
  and update it when the behavior it describes changes.
- `platform:iphone`, `platform:ipad` and `platform:mac` say where it happens; none means everywhere.
- Triage labels say who can pick an issue up. Take only `triage:ready-for-agent`.
  `triage:ready-for-human` needs a person (a real device, signing, a design decision);
  `triage:needs-triage` and `triage:needs-info` aren't ready for anyone yet.
- `upstream` means the cause is in Hermes Agent. Link the Nous issue rather than working around it
  in the app, unless the issue says otherwise.
- When you find a bug you aren't fixing, file it with `gh issue create`, labelled `bug`,
  `triage:needs-triage` and its area. The repository is public: leave out keys, addresses, names and
  anything from a real gateway.
- Security problems never go in an issue; see [SECURITY.md](SECURITY.md).

## Commits

One change per commit. The subject is what changed for the person using the app, area first:
`Chat: sending glides your message to the top and the reply fills in below it`. The body lists the
changes as short bullets, with the cause when it's a fix, and ends with `Fixes #<n>` for each issue
it resolves, so the issue closes when the commit reaches `main` (keep issue numbers out of the
subject, which should read as a release note). Each release's notes and its CHANGELOG section are
built from these subjects (docs/releasing.md); subjects in `Docs`, `Tests`, `Mock`, `README`,
`Release` and the other tooling areas are left out of them. Never commit secrets, `.env` files,
signing material or build output.
