# Connecting to a gateway, and voice

This document covers how the app reaches Hermes Agent: the two servers it talks to, pairing a
device with a QR code or a `hermesapp://connect` link, setting a gateway up by hand, where keys and
sign-ins are kept, how connections stay up, and how voice maps onto Hermes. The welcome tour, setup after pairing and the first chat are in `docs/onboarding.md`.

## 1. Two transports

The app talks to two Hermes Agent servers. A gateway works with the first alone; Bot Mode adds the
second.

1. **The API server** (`hermes gateway` with `API_SERVER_ENABLED=true`, port 8642;
   `HermesClient`). REST with `Authorization: Bearer <API_SERVER_KEY>`, the "API key" field in
   Add Gateway. The app uses it for:
   - `GET /health` (no key, 15 s timeout: it alone decides "offline") and `GET /v1/capabilities`;
   - the chat list, transcripts, rename, pin, fork and delete (`docs/sessions-and-models.md` §1);
   - turns as detached runs: `POST /v1/runs`, `GET /v1/runs/{id}/events` (SSE, resumed with
     `last_seq` and `Last-Event-ID`), stop, steer and approval; turns with images use
     `POST /api/sessions/{id}/chat/stream`;
   - `GET /api/model/options`, `GET /v1/skills`, `GET /v1/toolsets`;
   - Tasks: `/api/jobs` (`docs/tasks.md` §1).

   The app needs `session_resources`, `run_submission` and `run_events_sse` in
   `/v1/capabilities`; without them it says the gateway is too old and to run `hermes update`.
   A gateway address may end in `/p/<profile>` (the API server's per-profile mirror); that
   profile is then passed as `profile` to Bot Mode calls.

2. **The backend** (`hermes serve`, the server Hermes Desktop and the dashboard use; port 9119 by
   default; `BackendClient` for REST, `GatewaySocket` for the JSON-RPC WebSocket at `/api/ws`).
   This is Bot Mode: Bots, projects, the Board, memory, checkpoints, the Inspector, search, and
   every `session.*`, `prompt.*` and `command.*` call. While it's connected, normal chats run over
   it too. It doesn't accept `API_SERVER_KEY`. The app signs in one of three ways
   (`BackendLink.SignIn`):

   | Sign-in | How | REST | Socket |
   |---|---|---|---|
   | Automatic | Reads `window.__HERMES_SESSION_TOKEN__` from the backend's start page, as Hermes Desktop does. Only an ungated backend on the same machine hands it out; a refused socket reads it again once (the token changes when the backend restarts) | `X-Hermes-Session-Token` header | `?token=` |
   | Session token | A pasted token (`hermes serve` prints it) | `X-Hermes-Session-Token` | `?token=` |
   | Username & password | `POST /auth/password-login {provider: "basic", username, password}`; the app keeps the `hermes_session_at` / `_rt` cookies itself and takes refreshed ones from every response | `Cookie` | a one-time ticket: `POST /api/auth/ws-ticket` (30 s, single use), then `?ticket=` |

   `GET /api/status` (no sign-in) says whether the address is a Hermes backend and whether it
   needs a sign-in. A socket closed with 4401 means the sign-in was refused; 4403 means the host
   or origin isn't allowed. Connecting never waits for `/api/status`: on a busy Mac it's the
   dashboard's slowest call (it asks the gateway, every profile, memory and disk), and a proxy in
   front of it answers 502 after its own timeout. The roster reads it once the socket is open, for
   the version, and again only after the backend restarts (a new `replay_epoch`).

After the socket opens, the app waits for the `gateway.ready` event (up to 60 s; a busy Mac can
take most of a minute), notes its `replay_epoch` and `heartbeat`, then sends
`client.capabilities {server_requests: true}` once. Without that, approvals and questions are never
delivered. The app doesn't call `gateway.capabilities`.

Server requests for a chat that isn't open on this device are declined with 4404 ("This chat isn't
open in the Hermes app."), so another client can answer them.

Both clients refuse redirects to another host, scheme or port (`SameOriginRedirects`; http to https
on the same host is allowed), so a key or session never follows a redirect elsewhere.

## 2. Pairing (QR)

Hermes has no device-pairing protocol: no pairing call, code or URI scheme. (`pairing.changed` is
about messaging-platform DM pairing and is unrelated.) The QR code is defined by the app
(`PairingLink`):

```
https://hermesapp.dev/connect#v=1&name=<gateway name>&gateway=<API server URL>&key=<API_SERVER_KEY>
    [&backend=<backend URL>&signin=automatic|token|password[&user=<username>][&token=<session token>]]
```

- It's a universal link: the release app's Associated Domains entitlement claims
  `applinks:hermesapp.dev`, and the site's `/.well-known/apple-app-site-association` names only
  `29ZNGBT83H.co.caffeinatedcode.hermes` for `/connect`, so the system hands it to Hermes and no
  other app. The details ride in the fragment, which a browser never sends: on a device without
  Hermes, the Camera opens hermesapp.dev's page and the key reaches no server. A
  `hermesapp://connect?…` code, which older builds made, could be handed to any app that claims
  the scheme; it still connects (security scan F10, F17).
- `user` travels only with password sign-in, `token` only with token sign-in. Passwords and
  cookies never travel: a password-gated backend asks for its password on the new device.
- Values are percent-encoded except unreserved characters, so `&`, `=` and `+` in a key or name
  survive any parser.
- Codes are always the universal link. Debug builds register `hermesapp-dev` for opening their other
  links, aren't named by the site's association file, and like the release accept every form when
  scanning.

**Showing a code.** Pair a Device… is in the gateway menu at the top of the sidebar, in the Mac's
File menu and Settings → Gateways, and in Quick Open. The sheet (`macPairShown`, `macPairFrosted`):

- The code starts frosted, a mosaic too coarse to scan, until **Show Code**; it then resolves
  outwards from the Hermes badge. It hides again whenever the app leaves the front (the app
  switcher's snapshot, another window in front on the Mac).
- Below it: the gateway, "Bot Mode included" (and "asks for the password" for password sign-in),
  and "Anyone who scans this code can use your Hermes. Show it only to devices you own."
- A gateway on a loopback address (`localhost`, `127.*`, `::1`) can't pair: the sheet says other
  devices can't reach it and offers Edit Gateway… to give it a Tailscale or network address. A Bot
  Mode backend on a loopback address is left out of the code; the gateway still pairs and the sheet
  says Bot Mode stays on this device.

**Scanning.** Scan Pairing Code uses VisionKit's `DataScannerViewController` where it's supported;
elsewhere the sheet says to use the Camera app, which opens the link in Hermes. A code that isn't a
Hermes link says "That isn't a Hermes pairing code."; a `hermesapp` link that isn't a `v=1`
`connect` link says "This code needs a newer Hermes. Update the app, then scan again."

**Connecting from a code or link** (`PairingConnectView`):

- A link opened from elsewhere (the Camera app, Messages) always asks first: "Connect to <name>?",
  or "Update <name>?" when a gateway at that address is already saved. A code scanned in Hermes
  connects at once unless it needs a password or a warning applies.
- It shows the whole address, scheme included, since whoever made the link chose the name.
- Warnings: plain `http` to an address that isn't local ("the API key and your chats would travel
  readable"), and a saved gateway with the same name at another address ("Connect only if you made
  this code yourself"). Either stops a scanned code from connecting by itself.
- What it will add: chats, tasks and skills; Bot Mode when included; "The API key is saved in this
  device's Keychain".
- Nothing is saved until it works. "Checking the gateway…" runs the same probe as Add Gateway
  (§6) with a 12 s deadline, and tries once more after 1.5 s when the first attempt failed fast
  (iOS fails the first try while it asks for Local Network access). "Signing in to Bot Mode…" has
  20 s and reads the roster once. If only Bot Mode fails, **Connect Without Bot Mode** saves the
  gateway alone.
- An update keeps the saved gateway's Bot Mode when the code has none.

Not built yet:

- **New Key** (rotating `API_SERVER_KEY`). Hermes has no call for it.
- Codes that expire after a few minutes. Instead the code is frosted until asked for and hides when
  the app leaves the front.

## 3. Setup and status

| Need | Call | Notes |
|---|---|---|
| Is this Hermes, and new enough? | `GET /health`, then `GET /v1/capabilities` | See §1. Pairing and Add Gateway run it before saving a gateway (`AppModel.probe`) |
| Is the backend there, and does it need a sign-in? | `GET /api/status` | `auth_required`, `auth_providers` (`basic` = password), `version` |
| Is a model provider set up? | `setup.status {profile?}` | Bot Mode only. `provider_configured`; `ready` is true or absent. Not configured → setup's model step (`docs/onboarding.md` §3) |
| Can a new Bot answer? | `setup.runtime_check {profile}` | After New Bot: `ok: false` skips the Bot's hello |
| Gateway status | local | The sidebar's gateway shows its state ("Connected to Hermes 0.21.6", "Connected · Studio Mac is busy, replies are slow", "Offline"). In the gateway menu the one in front says "Connected · Bot Mode" or similar; the others show their address |

Not used: `machine.facts`, `verification.status` (whether tests ran in a chat) and `onboarding.*`
(Hermes Desktop's guided first chat and trial claim, not this app's onboarding).

## 4. Voice

Hermes Agent's own voice calls use the **gateway host's** microphone and speaker (`voice.record`,
`voice.tts`), which doesn't help a phone in the person's hand, so the app hears on the device and
uses the gateway for the Bot's voice and Realtime. The details are in [voice.md](voice.md).

- **Hearing.** `SpeechAnalyzer` on the device, fed from the audio coordinator's microphone tap
  ([voice.md](voice.md) §4.2, §7).
- **Speaking.** The Bot's profile voice from the gateway (`WS /api/audio/speak-stream`), the
  device's best voice when the gateway can't speak.
- **Talk turns** go as voice turns (`prompt.submit {voice_turn, surface: "voice-live",
  voice_context, interrupted}`) over the backend's socket; Realtime runs over WebRTC set up
  through `POST /api/audio/voice-live/session`.
- All the audio routes are on the backend (`hermes serve`), not the API server: without Bot Mode,
  Talk uses the device's voice and runs its turns as normal messages.

Not built yet:

- Using the host pipeline (`voice.record`, `voice.transcript`) when the Mac runs the gateway.

## 5. Talk on iPad and Mac

See [voice.md](voice.md) §4.5.

## 6. Setting up a gateway by hand

Set Up Manually (Add Gateway, `BotEditorView`) takes:

- **Address.** Without a scheme, hosts that look local (`localhost`, single-label names such as
  `nas`, `*.local`, `*.lan`, `*.home.arpa`, `*.internal`, `*.ts.net`, private and link-local
  addresses, Tailscale's 100.64.0.0/10) get `http`, others `https`. A local `http` address
  without a port gets 8642. A trailing `/v1` or `/v1/chat/completions` is removed.
- **API key**, with a reveal button. When editing, an empty field keeps the saved key.
- **Bot Mode** (optional): the backend's address (a local one without a port gets 9119) and the
  sign-in from §1.
- **Appearance**: name (defaults to the agent's name from `/v1/capabilities`) and colour.

Saving checks first: the API server probe (§3), then, with Bot Mode, the backend's status, sign-in,
socket and `profiles.list`. Cancelling during the check saves nothing. Plain `http` to an address
that isn't local shows a warning under the address and under Bot Mode.

The sheet also explains how to turn the API server on: a snippet for `~/.hermes/.env`
(`API_SERVER_ENABLED=true`, `API_SERVER_KEY=<40 random characters made on the device>`,
`API_SERVER_HOST=0.0.0.0`) with Copy and New Key (a fresh random key for the snippet), then
`hermes gateway restart`. When adding a gateway on iPhone or iPad it also offers Scan Pairing Code.

## 7. Keys and sign-ins on the device

- API keys and Bot Mode credentials (a session token, or the session cookies) live in the Keychain
  (`KeychainStore`), service `<bundle id>.api-key`, account `<gateway id>` and
  `<gateway id>.backend`. Debug and Release builds have different bundle ids, so they never share
  keys.
- Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after the first unlock
  (background refresh, answering from a notification) and never restored onto another device from
  a backup. A new device pairs again. Items saved before this protection class move to it the first
  time they're read.
- On the Mac the app uses the data-protection keychain; ad-hoc signed development builds, which
  can't, fall back to the login keychain.
- The list of gateways (names, addresses, Bot Mode links, no secrets) is `bots.json` in the app's
  Application Support folder, written with complete-until-first-authentication protection.
- Removing a gateway deletes its key, its Bot Mode credential, its cached transcripts and sent
  images, its Inspector tabs and its web data on this device. Its chats stay on the gateway.
- Keys never go into `UserDefaults`, files, logs or URLs. The pairing link is the one deliberate
  exception (§2).

## 8. Staying connected

**API server** (`BotWorkspace`). Only the gateway in front keeps checking.

- Requests wait up to 120 s (a busy Mac can be slow over a chat list while its health check answers
  at once). A request still running after 8 s while `/health` answers marks the gateway busy: the
  status line says replies are slow, and the app keeps going rather than calling it offline.
- The backend's reads (`BackendClient`) that come back 502, 503 or 504 are asked again after 2 s
  and 5 s. A proxy in front of the dashboard answers those when the dashboard doesn't answer in
  time: Tailscale Serve, or a Mac's own local proxy with its own timeout. Hermes's dashboard runs
  Bot turns in the same process, and under load its event loop stalls for seconds ("event loop
  stalled … GIL pressure"). A read that still fails says "Hermes didn't answer in time: it's busy
  right now".
- Online, a health check runs every 30 s (every 2 minutes while the Mac app is behind other apps,
  and once more as it comes to the front). Two misses 3 s apart turn the gateway Offline.
- **A health check the gateway took but didn't answer is no miss** (`HermesClient.liveness`,
  `GatewayLiveness`). A machine that's off, asleep or out of reach never takes the connection,
  and a gateway that isn't running refuses it; one that took the connection and the question and
  said nothing for 15 s is running on a Mac too loaded to get to it (at load 500 Hermes left
  `/health` on both ports unanswered for over 20 s). That's busy: the status says replies are
  slow, the Bot Mode socket is kept, and a connect that couldn't finish tries again every few
  seconds. The task's metrics say how far the connection got; each check has a session, and so a
  connection, of its own, so the silence of a pooled link that died meanwhile never reads as busy
  (HTTP/2 would share one whatever the request asked). One limit: behind a proxy on the device
  that takes every connection itself, a Mac that's asleep reads busy. A starved Mac answers
  quickly for the moment it gets to run, then goes quiet again: a request still running after 8 s,
  an answer that took over 5 s or a health check it took and didn't answer all say busy, and only
  quick answers with nothing slow under way clear it, half a minute after the last sign (on the
  Bots too, from their roster reads). Mock: `--starve 5-30` ([development.md](development.md)).
- The chat list is kept on the device (`SessionsCache`, the newest 200 rows, in Caches): a cold
  launch shows it at once and the gateway's replaces it when it comes, so a busy Mac no longer
  means an empty sidebar. The model list is kept the same way (`ModelOptionsCache`), so the model
  picker opens on it instead of "Loading models…". After health and capabilities, the chat list,
  the model list and widget support are read side by side.
- Offline, it tries again after 2, 4, 8 and 16 s, then every 30 s. A missing or rejected key, or
  a gateway that's too old, waits for the person instead.
- When the gateway is back, turns whose stream dropped re-attach to their runs (`last_seq`).

**Bot Mode socket** (`BotRoster`, `GatewaySocket`).

- A quiet socket is pinged every 10 s (`gateway.ping` when `gateway.ready` said `heartbeat`, else a
  WebSocket ping). One that has heard nothing for 75 s is closed and reconnected, unless the
  gateway's `/health` still answers: then its machine is up and the dashboard is frozen (Hermes
  logs "event loop stalled N s (GIL pressure suspected)", seen at 349 s on a loaded Mac), so the
  socket is kept, still pinging, for up to 10 minutes (`GatewaySocket.longestStall`). A new socket
  couldn't get in sooner: it would wait on the same loop.
- **Busy, not offline.** A proxy's 502, 503 or 504, or a timeout, while the gateway answers is a
  busy dashboard (`BackendClient.isSlowAnswer`): the Bots stay listed and the status says
  "<Mac> is busy · Bots are slow" (or "will catch up" while reconnecting). They're called offline
  only after 5 minutes without one answer while the gateway itself isn't busy, or when the gateway
  is unreachable too. A socket kept through a stall says busy as well, until a roster read comes
  back. Reconnecting, the open chats re-attach first (a running reply streams again at once), and
  the roster and group rooms are read after them. A send waits
  up to 10 minutes for its answer on an open socket (`BotRoster.patientTimeout`) rather than
  failing into "Couldn't tell whether Hermes got this message". A chat whose load Hermes was too
  slow for keeps what it shows, turns nothing red ("The Hermes backend answered 502."), and asks
  again after 5, 10, 15… up to 60 s (`ConversationModel.retriesQuietly`).
- Why the dashboard freezes: it runs every Bot's agent turns in its own process, so they share
  its event loop's lock. Hermes can run them in a child process instead
  (`dashboard.turn_isolation: true` in `config.yaml`; group-room turns are refused then). Telegram
  and Buzz don't see the freezes: they live in the gateway process, and their messages wait in
  Telegram's or Nostr's cloud.
- Reconnects back off 0.5, 1, 2, 4 and 8 s, then every 15 s, with ±20% jitter. A Mac app behind
  other apps backs off to every 60 s and reconnects at once when it comes to the front. With no
  network at all there are no attempts: the route coming back connects. For the first 20 s after a
  drop the app says "Reconnecting…", not offline.
- A change of network route (`NWPathMonitor`) reconnects at once, or probes an open socket, which
  often dies silently on the old route. Coming to the front probes the socket unless it was heard
  from in the last 12 s.
- In the background the roster stops polling and reconnecting. On iPhone and iPad the socket
  stays open while iOS lets the app run (background time, `BackgroundActivity`): a quick trip to
  another app finds it as it was, and a reply or a Bot's message keeps coming in meanwhile. The
  time goes back 15 s after the app left, or as soon as iOS asks for it: the socket closes
  cleanly then (a pause), and coming back opens a new one at once. The time is never held to
  its end: a busy phone starves a background app's main thread, and an app still holding
  background time when it runs out is ended. So the time is held, and given back, off the main
  thread (`ProcessInfo.performExpiringActivity`): the main thread only wraps up afterwards
  (pausing the socket), whenever it gets to run. Answering from a notification and the presence
  report hold time the same way.
- Coming back (after more than 5 s away, or the Mac waking) the chat on screen reads what happened
  meanwhile over HTTP at once (`catchUpOnReturn`), while the socket, the roster and the chat's
  re-attach are still on their way: on a busy Mac they take seconds. A Bot Chat opened while the
  socket is down loads the same way when its stored id is known, and attaches when the roster is
  back.
- A message sent before the chat's history came (a busy Mac can take minutes over it) doesn't
  leave the chat with nothing but the message: the history goes in above it as soon as there is
  one, the device's copy or Hermes's (`showHistoryUnderTurn`), cut before that message so it never
  shows twice (`TranscriptBuilder.history`). The turn's end brings its stored copy as always.
  While the Bots wait on a busy Mac the composer says "<Mac> is busy", not "Offline".
- The last roster (`profiles.list` rows) is kept on the device (`RosterCache`, in Caches, like
  the transcripts). An app that iOS ended in the background opens on its Bots and their cached
  Bot Chats, saying "Reconnecting…", instead of "Connecting to your Bots…" on an empty screen.
- Chats re-attach with `session.resume` and replay what they missed with `session.events.since`
  (`docs/sessions-and-models.md` §1).

## 9. Checks

- Scanning a code from Pair a Device connects without questions; opening the same link from the
  Camera app asks first.
- An `http` link to a public address, or a link reusing a saved gateway's name at another address,
  shows its warning and doesn't connect by itself.
- A gateway on `localhost` shows "Other devices can't reach this address" instead of a code.
- The code is frosted until Show Code and frosted again after switching apps.
- A wrong key fails with "Hermes rejected the API key"; a gateway without the needed capabilities
  asks for `hermes update`.
- Stopping the mock backend shows "Reconnecting…", then offline; starting it again reconnects
  without a tap.
- `POST /api/mock/stall {"seconds": 150}` on the mock backend: the Bots stay connected, the status
  says the Mac is busy, nothing reconnects, and a message sent meanwhile gets its reply once the
  stall ends.
- With the mocks on `--starve 5-30` (health checks late too), a relaunch shows the chats and Bots
  this device saw at once, the status says the Mac is busy and never Offline, and stopping the
  gateway mock instead says Offline within two checks.
- With the mock backend on `--slow-status 40`, the Bots connect in a second or two and the version
  fills in later; quitting and relaunching the app shows the Bots at once.
- With the mock backend on `--slow-history 15`, a fresh install opening Ops and sending "marathon"
  at once (`-HERMES_SEND_HERE "marathon please" -HERMES_SEND_HERE_AFTER 6`): about 15 s later
  Ops's history is above the message while the reply still works, and it stays when the reply ends.
- With the gateway unreachable, Talk says so, offers Try Again, and keeps what was said as
  the chat's draft.

## 10. Setup

Pairing needs only the gateway's API server. Bot Mode's link and sign-in are [setup.md](setup.md)
§4.1, and Settings → Setup checks them; Local Network on iPhone and iPad shows in the connection
banner (§4.15).
