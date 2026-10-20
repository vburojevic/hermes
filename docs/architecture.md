# How Hermes is built

## The pieces

```
project.yml               XcodeGen spec: one multiplatform app target (iOS + macOS) and three iOS extensions
App/                      The SwiftUI app
  Model/                  AppModel (gateways), BotWorkspace (one per gateway), BotRoster (Bot Mode),
                          ConversationModel (the turn engine for chats and Bot Chats), Inspector, Board, …
  Views/                  One folder per area: Chat, Composer, Sidebar, Bots, Board, Inspector, Settings, …
  Design/                 Theme, the Hermes wing mark, Bot faces, Metal shaders, shared components
Packages/HermesKit/       Swift package, no UI
  HermesKit               Gateway and backend clients, the JSON-RPC socket, models, transcript folding,
                          the live-turn reducer, Bot Mode, pairing links, link and preview safety
  HermesPush              Push crypto, notices, notification categories, Live Activity state
                          (shared with the extensions, so it stays small)
  HermesMarkdown          swift-markdown → render tree, code highlighting
Packages/HermesMacSupport Sparkle updates (Mac only)
Push/                     The app's push layer, Notification Service and Content extensions, widget
Relay/                    The push relay (Convex + Vercel)
Tools/mock-hermes/        Stdlib-only mocks: the gateway (server.py) and the backend (backend.py)
Tools/hermes-app-push/    The Hermes Agent plugin that sends notices to the relay
Tools/hermes-app-widgets/ The Hermes Agent plugin for widgets agents send to the app (in progress)
Tools/IconGen/            Renders the app icons from the same path the UI draws
```

## Talking to Hermes Agent

The API contract was taken from the Hermes Agent source, not guessed. Hermes has two servers, and
the app speaks to both:

- **The gateway** (`hermes gateway` with the API server on, port 8642): sessions, models, tasks,
  skills and agent turns. Text turns run as detached `/v1/runs`, so leaving the app doesn't stop
  the agent; the app re-attaches to the event stream (`last_seq` replay) when it comes back. SSE
  framings differ per route, session-stream disconnects cancel the turn while runs survive them,
  images are stored only as placeholders (the app keeps its own copy), and compression can rotate a
  session's id mid-turn.
- **The backend** (`hermes serve`, what Hermes Desktop and the dashboard use): Bot Mode, projects,
  helpers, the Board, memory, files and git, checkpoints, connections, and the Inspector's bridge,
  over REST and a JSON-RPC WebSocket (`/api/ws`). Chats start as the gateway's desktop platform so
  Hermes has its Inspector tools.

Bot Mode signs in to the backend in one of three ways: **Automatic** reads the token a local,
ungated backend puts in its start page (Hermes Desktop's way), **Session token** takes a pasted
token, and **Username & password** keeps a gated backend's session cookies in the Keychain and
refreshes them.

## Pairing another device

A connected gateway's **Pair a Device…** shows a QR code holding a
`hermesapp://connect?v=1&gateway=…&key=…&backend=…&signin=…` link (`PairingLink`; Debug builds also
answer `hermesapp-dev` links). It carries the gateway's API key, so it stays frosted until **Show Code** and hides
again when the app leaves the front. A session token travels only for token sign-in; cookies never
do, and a password-gated backend asks for its password on the new device. Loopback addresses can't
pair: use the machine's Tailscale or network address.

Opening a link always asks first, shows the full address, and warns about plain HTTP over the
internet or a name that a saved gateway already uses at another address.

## Push notifications

Hermes Agent can't talk to Apple's push service, so a gateway plugin seals each notice for each
device and sends it through a relay. The plugin runs in the person's Hermes, installed in the root
and every profile ([plugins.md](plugins.md)):

```
gateway plugin (Tools/hermes-app-push)
  ──HTTPS──▶ push relay (Relay/; holds the APNs key, sees no content)
  ──APNs──▶ Notification Service Extension (decrypts) ▶ notification / Live Activity
```

Each notice is sealed with X25519, HKDF and ChaCha20-Poly1305 for the device's key, which never
leaves its Keychain; the relay only sees routing fields and an encrypted envelope. Approvals in a
notification need Face ID or the passcode, offer Allow only for a command the notification shows
whole, and never for one Hermes's safety check flagged.

App side: `Push/` and `Packages/HermesKit/Sources/HermesPush`. The iPhone and iPad app embeds three
extensions (service, content, widget) sharing an App Group. The Mac uses local notifications only.

## Safety rules the code keeps

The gateway is trusted; what flows through it isn't. Pages Hermes read, project files, tool output
and other Bots' messages can all carry injected instructions, so:

- links from chats, results and the Board open only web pages and mail (`WebLink`);
- pictures in replies from the internet wait for a tap;
- approval text shows invisible and reordering characters as their codes (`VisibleText`), and
  answers go to the request the person saw;
- Preview pages read only the folder of the file they opened, and pages on the device's own network
  open only when the person says so;
- HTML artifacts run with no network unless the person allows it;
- keys live in the Keychain on this device only, never follow a redirect, and never reach a log.
