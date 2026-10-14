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
- **Tasks**: Hermes' scheduled jobs — create, run now, pause, resume, delete.
- **Skills**: browse the gateway's skills and tool sets; start a chat with a skill.
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

Approvals, questions, password prompts, finished replies, scheduled tasks, Kanban cards and Bot messages
reach the iPhone and iPad when Hermes isn't on screen, plus a Live Activity for long turns. Hermes Agent
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
