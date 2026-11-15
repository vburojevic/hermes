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
- A gateway's key and Bot Mode sign-in are read only for the addresses saved with them
  (`<gateway id>.destinations`), checked at each read: other addresses in `bots.json` go back to
  the saved ones. While the Keychain can't be read yet, nothing is read and the gateway says
  "Hermes can't read this gateway's key from the Keychain right now". It tries again on its own,
  as the app comes back, and when the device unlocks.
- Removing a gateway deletes its key, its Bot Mode credential, its cached transcripts and sent
  images, its Inspector tabs and its web data on this device. Its chats stay on the gateway.
- Its web data (the Preview's cookies and storage, and the in-app browser's sign-ins) goes at the
  app's next launch. Removing the gateway closes its pages first and writes their two stores down
  (`RetiredWebStores`, kept in `UserDefaults`). At the next launch the app deletes each one in
  turn, awaited on the main actor, and never a store a current gateway uses, so no web view can be
  using it: a store deleted under a web view that still uses it crashes WebKit, and a page on
  screen lets its web view go only after the screen changes. With nothing waiting, launch doesn't
  touch WebKit. A store that can't be deleted waits for the launch
  after. A page made again for a screen that still shows it keeps nothing (a
  non-persistent store). WebKit's store calls (`allDataStoreIdentifiers`, `remove(forIdentifier:)`)
  are made only once WebKit has started in the process (`WKWebsiteDataStore.default()`): before
  that they crash the app on a background thread, which removing a gateway in a session that
  never opened a page did. Stores left by gateways removed on builds before this list aren't
  known to it and stay.
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
  means an empty sidebar. It's read as the gateway's workspace is made, before the first frame
  (`ChatListSnapshot`, about a millisecond for 200 rows), so the window opens with its rows in
  place instead of sliding them in after it. The first frame lists a screenful
  (`ChatListSnapshot.firstFrameRows`, 40) and the rest join right after it, so laying out every
  row doesn't hold the window back. The model list is kept the same way (`ModelOptionsCache`), so
  the model picker opens on it instead of "Loading models…". After health and capabilities, the
  chat list, the model list and widget support are read side by side. Each row's last message is kept too
  (`LastLinesCache`, `docs/inbox.md` §1), so the rows read right before the gateway answers.
- Opening a chat, the copy this device kept (`TranscriptCache`) goes up while the gateway's newest
  rows are asked for, not before: the request leaves as soon as the copy is read from disk, with
  a short page reaching back to its newest row, and what's new goes in below it once it's on
  screen. A Bot Chat shown from the device's copy keeps its first fetch when the roster says the
  chat moved meanwhile (the roster's first read after a launch always does): it fetches once more
  after it, instead of starting again; on a busy Mac that first fetch had been running for
  seconds.
- Offline, it tries again after 2, 4, 8 and 16 s, then every 30 s. A missing or rejected key, or
  a gateway that's too old, waits for the person instead. A proxy's certificate refusal keeps
  being checked, since it can look like a drop (§11.9).
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
  socket is down loads the same way when its stored id is known (from the roster, or from the copy
  the device kept when the chat opens before the roster does, as at a launch), and attaches when
  the roster is back.
- A message sent before the chat's history came (a busy Mac can take minutes over it) doesn't
  leave the chat with nothing but the message: the history goes in above it as soon as there is
  one, the device's copy or Hermes's (`showHistoryUnderTurn`), cut before that message so it never
  shows twice (`TranscriptBuilder.history`). The turn's end brings its stored copy as always.
  While the Bots wait on a busy Mac the composer says "<Mac> is busy", not "Offline".
- The last roster (`profiles.list` rows) is kept on the device (`RosterCache`, in Caches, like
  the transcripts). An app that iOS ended in the background opens on its Bots and their cached
  Bot Chats, saying "Reconnecting…", instead of "Connecting to your Bots…" on an empty screen.
  The copy only lists the Bots (with their unread marks and pictures): it never counts as the
  gateway's answer (`RosterLoad`), so nothing it lacks reads as missing (a call to a Bot made
  since, "No Bots yet", a chat's empty layout, a notification's chat), and whether a Bot is
  online, busy or working waits for the gateway's list.
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

## 11. Behind an access gateway

Some people put Hermes behind an access gateway (Cloudflare Access and the like) or a proxy that
asks for a client certificate. The access gateway answers first, so the app has to pass it, and
Hermes's own API key and Bot Mode sign-in still go on every request behind it.

### 11.1 Access settings

Each gateway has Access settings (`GatewayAccess` in `bots.json`): a page from Edit Gateway's Access
row on iPhone and iPad (`gatewayAccess`), inline in the Mac's sheet (`macAccess`), and in pairing
once an access gateway turns it away (§11.5). A status card leads them (`accessStatus`,
`accessTokenRejected`, `accessReady`) with what the last check found, who said so, and Check
Again. The methods:

- **None**, the default.
- **Service token**: a client ID and secret from the access gateway's dashboard, sent as two
  headers. The names default to Cloudflare Access's (`CF-Access-Client-Id`,
  `CF-Access-Client-Secret`) and can be changed under Headers.
- **Client certificate**, its own section under the method: a .p12 or .pfx file for a proxy that
  asks for one, with either method or alone (§11.9).
- **Browser sign-in**: the access gateway's own sign-in page, in a sheet, for a gateway people sign
  in to with their account (§11.10). Its card names who signed in and until when, with Sign In…
  and Sign Out.

The secret lives in the Keychain like the key (§7), account `<gateway id>.access`, read only for
the addresses saved with the gateway. The field stays empty for a saved secret and keeps it unless
something is typed. A header name that could replace one the app sends itself (`Authorization`,
`Cookie`, `Host`, a `Sec-` or `Proxy-` header, and the like) or a value with a line break is
refused, in the editor and again when it's sent: `bots.json` is a plain file. Check Again tries the
settings on screen before they're saved, for the check's own requests alone (`trying`, a task-local
value): the live connection to the same gateway keeps sending the saved settings meanwhile.
Saving new settings reconnects the gateway and keeps its chats. Removing the gateway removes the
secret, and a sign-in's session (§11.10) with it.

### 11.2 Telling refusals apart

`AccessRefusal` (HermesKit) reads who stopped a request before Hermes saw it, so a sign-in page is
never taken for a wrong key:

| Answer | Read as |
|---|---|
| A redirect (the access gateway's sign-in, on another origin; `SameOriginRedirects` doesn't follow it) | `signInNeeded`, `tokenRejected` when a token was sent, or `signInExpired` when a sign-in's cookies were |
| 401 or 403 with an HTML page, or a body that isn't JSON | the same |
| 401 or 403 with JSON, or an empty body (the API server's bare 403 for a browser origin) | Hermes's own refusal, as before |
| A socket's upgrade refused (no body to read) with an HTML page | the same, by the token its upgrade carried |
| A socket's upgrade refused with any other type (the bare 403 is `text/plain`) | Hermes's own refusal |
| `URLError.clientCertificateRequired` | `certificateNeeded` |
| `.clientCertificateRejected`, or a lost connection or failed handshake just after a certificate challenge (below) | `certificateNeeded` if none was given, `certificateExpired` if it ran out, else `certificateRejected` |
| The server's own certificate isn't trusted (`serverCertificateUntrusted` and the like) | not a refusal: the system's error, as before |

The system rarely names a certificate refusal. A TLS 1.3 proxy turns the device away after the
handshake, which reads as `networkConnectionLost`, and TLS 1.2 gives `secureConnectionFailed`, for
no certificate, one from another authority and an expired one alike. So the registry notes each
client-certificate challenge by origin, with whether it was answered and with which certificate,
and a failure there within 30 seconds is read as the proxy's answer. A request that gets an answer over
TLS clears the note, so a later dropped connection isn't blamed on the certificate.

They arrive as `HermesError.accessRefused(host:_:)`, checked before Hermes's key, with their own
title, line and "From the access gateway at …" (or "From the proxy at …").

### 11.3 Where it's set up

[setup.md](setup.md) §4.24 lists Access in Settings → Setup for a gateway with Access settings or
one an access gateway or a proxy turned away, with Check Again and Edit Access…. Each certificate
refusal says what to get from whoever runs the proxy and where to import it.

### 11.4 What isn't built

The sign-in page is the app's own sheet, not the system browser: a password manager's extension
and a passkey saved for the identity provider's site may not be offered there (§11.10 says why).
Mutual TLS, a service token and browser sign-in each stand alone or with a certificate; a token and
a sign-in together aren't offered, since the access gateway takes either.

### 11.5 Where a refusal shows

- **Pairing** (`pairingAccess`): instead of "Hermes rejected the API key" the card says an access
  gateway answered, where from, and Set Up Access…, a sheet with the settings above. Pairing then
  checks again with them and saves them with the gateway.
- **A chat** (`accessTokenBanner`): the banner names the gateway and offers Access. A sign-in
  that ran out (`chatAccessExpired`) says "Your access sign-in expired" and offers Sign In… in
  place, and the composer says "Sign-in needed" (§11.10).
- **Settings → Setup**: the Access row (§11.3).

### 11.6 One seam for every request

`GatewayAccessRegistry.shared` (HermesKit) is the one place gateway requests get what an access
gateway asks for. `AppModel` hands it each gateway's credentials for that gateway's own addresses
(its API server and Bot Mode), and every transport passes its requests through `prepare`:
`HermesClient` (calls, run streams, uploads inline in a message, the browser bridge's socket),
`BackendClient` (calls, file reads and writes, downloads, its sockets), `GatewaySocket`,
`BoardEventStream`, `GatewayAudio`, `BrowserControlClient`, `RemotePicture` (every gateway image)
and the Preview's web view. Reconnects build their requests again, so they get it too.

- A request gets the headers and cookies only when it goes to exactly the gateway's origin
  (scheme, host and port; `ws` counts as `http`, `wss` as `https`). Another port, `http` for
  `https`, or `localhost` for `127.0.0.1` gets nothing.
- Hermes's `Authorization` header and its session cookie stay; the access gateway's cookies are
  added after them.
- `SameOriginRedirects` takes every access header and cookie off a redirect and puts them back only
  when it leads to the same origin. A redirect within the request's own origin keeps the headers
  it went out with, so settings being tried survive it.
- A page the Preview opens on the gateway loads with them, and a link on it within the gateway
  loads again with them. A web view keeps a load's headers across a redirect and isn't covered by
  `SameOriginRedirects`, so a redirect or a link off the gateway's origins is stopped and loaded
  again without them (`leaksAccess`), then asked about like any other address.
- A page's own images, scripts and frames go out without the headers. They pass by the access
  gateway's session cookie (`CF_Authorization`), which it sets in the web view on the page's
  first load.
- A proxy's client-certificate challenge gets the gateway's certificate only for the gateway's own
  origins, the same test as the headers (§11.9). URLSession asks `SameOriginRedirects`, the
  Preview's web view asks `PreviewController`, and both answer through the registry. Every other
  challenge, the server's own trust included, gets the system's handling.

### 11.7 Mock

`Tools/mock-hermes/access_gateway.py` stands in front of the mocks
([development.md](development.md)): pair with its port, see the refusal, then set Service token
with the mock's client ID and secret, or Browser sign-in. A token pass sets a `CF_Authorization`
cookie that later requests can pass by. Its sign-in page is a form that takes any email (no
identity provider) and sets the same cookie, with an `exp`, for the route's origin;
`--session-seconds 60` makes a session run out a minute later, and a stream or socket it let in is
cut then. `/__mock/leave` redirects a page to the sign-in origin, whose log says whether the token
came along; "preview <address>" in a chat opens it in the Preview.

`Tools/mock-hermes/mtls_proxy.py` is a TLS proxy that asks for a client certificate, for §11.9. It
makes a throwaway certificate authority and certificates when it starts, so no key is in the
repository, and logs every certificate it verified or turned away. The device certificates are
signed by an issuing authority under the root and the proxy trusts the root alone, so a
certificate only passes with its chain. How to run it, trust its
authority and add its certificate is in [development.md](development.md). The two stack: put the
access gateway behind the proxy and set both a service token and the certificate.

### 11.8 Checks

- Pairing through the mock access gateway without a token shows "An access gateway answered, not
  Hermes", never "Hermes rejected the API key".
- With the token, a chat streams, a file goes up and comes down, the Board's live stream runs, a
  preview and an image load, and stopping and starting the mock behind reconnects without a tap.
- The mock's log shows the token on every kind of request, and the gateway's key never reaches
  another server.
- "preview http://127.0.0.1:20642/__mock/leave" in a chat: the sign-in origin logs `token=none`.
- Pairing through the mock mTLS proxy without a certificate shows "The proxy asks for a
  certificate", on TLS 1.3 and 1.2 alike. Its expired certificate shows "The certificate expired",
  and the one from the other authority "The proxy refused this certificate".
- With its certificate, everything in the token check above works, and the proxy's log names the
  certificate on every connection. Through the proxy and the access gateway together, with a token
  and a certificate, it works the same.
- Remove the certificate and Save: the Keychain no longer has it, unless another gateway uses it.
- Browser sign-in through the mock access gateway: Sign In… opens its form, signing in closes the
  sheet, Check Again says "Sign-in accepted", and after Save a chat streams. With
  `--session-seconds 60`, a reply that runs past the minute stops with "Your access sign-in
  expired", nothing says Reconnecting…, Sign In… in the banner signs in again, and the reply picks
  up where it stopped. Sign Out and Save: the next request asks for a sign-in.

### 11.9 Client certificates

A proxy in front of Hermes (nginx, Caddy, Traefik, a company's gateway) can ask every device for a
certificate during the TLS handshake. The Access settings take one per gateway, as a PKCS #12 file
(`.p12` or `.pfx`) holding the certificate and its private key.

- **Importing** (`accessCertificate`): Import Certificate… (Import… on the Mac) picks the file from
  Files, then asks for its password. A wrong password asks again; a file without a private key, or
  not a certificate file at all, says so. The card shows the file's name, who it was issued to and
  by, and when it expires (in red once it has), with Replace… and Remove.
- **Where it's kept**: the identity, the certificate with its key, goes into the Keychain when the
  gateway is saved, device-only, found again by the certificate's SHA-256 fingerprint. The
  password is never kept. `bots.json` keeps the file's name, subject, issuer, expiry and
  fingerprint, so another device sees which certificate the gateway uses and says it isn't on this
  device until it's imported there. The intermediate certificates the file carries are kept
  beside it and sent with it, for a proxy that trusts only the root. On the Mac only the
  data-protection keychain is used, never the login keychain, so using the certificate never asks
  for the Mac's password.
- **Sharing and removing**: gateways behind one proxy can use one identity. It leaves the Keychain
  when no saved gateway names it any more: removed, replaced, or its gateway removed.
- **What it answers**: every transport in §11.6, reconnects included, answers the proxy's
  challenge with the identity when the request goes to the gateway's own origin. Check Again and
  pairing try a certificate before it's saved for their own requests alone: `prepare` marks each
  one, since the challenge arrives outside the task, and they go on a connection of their own, so
  the proxy asks again even while the live connection is up. The server's own certificate is checked by
  the system as for any other https address; the app never trusts one the system doesn't.
- **Making one** for a proxy you run, with OpenSSL: a certificate authority the proxy trusts, and a
  certificate it signs for the device, exported with its key.

  ```sh
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Home CA" -keyout ca.key -out ca.pem
  openssl req -newkey rsa:2048 -nodes -subj "/CN=My iPhone" -keyout device.key -out device.csr
  openssl x509 -req -in device.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -out device.pem
  openssl pkcs12 -export -inkey device.key -in device.pem -name "My iPhone" -out device.p12
  ```

  Send `device.p12` to the device (AirDrop, Files), import it in Edit Gateway → Access, and keep
  `ca.key` off the devices. nginx checks it with `ssl_client_certificate ca.pem;
  ssl_verify_client on;`.
- **What the proxy checks**: that the certificate chains to its authority, that it hasn't expired,
  and, if it keeps one, that it isn't on its revocation list. Hermes behind it never sees the
  certificate; its key and Bot Mode sign-in still go on every request.
- **Telling a refusal from a drop**: on TLS 1.3 a proxy refuses a certificate after the handshake
  looks done, so URLSession reports a lost connection, the same as a network drop. A request that
  ends that way before any answer, right after a certificate challenge (or with none sent when one
  was asked for), reads as the refusal. One that had already been answered, a run stream or a
  socket that dropped later, is a lost connection and reconnects. Since a drop at the wrong moment
  can still read as a refusal, a certificate refusal doesn't stop the connection being kept (§8): the
  certificate state shows while the app keeps checking at its offline backoff, up to every 30 s,
  and a route change checks at once. A refusal answered over HTTP (a token, a sign-in) waits for
  the person.

### 11.10 Browser sign-in

An access gateway that people sign in to (Cloudflare Access with Google, GitHub, a one-time code or
a company's identity provider) answers a browser with its sign-in page and lets it through with a
session cookie for the gateway's address (`CF_Authorization` for Cloudflare). Browser sign-in gets
that cookie for the app.

- **The flow**: Sign In… opens a sheet with a web view on the gateway's `/health`. The access
  gateway redirects it to its sign-in page, the person signs in there, and it sends the web view
  back with its cookie. When the gateway itself answers (a 2xx from the gateway's own origin, its
  body never shown), the sheet closes and keeps the cookies set for that address
  (`AccessSession.from`: the browser's own domain and path rules, a Secure cookie only over https).
  Cookies for the identity provider's pages stay in the sheet's store, which is thrown away with
  it. The app never sees the password.
- **Why not the system browser**: `ASWebAuthenticationSession` hands back only a callback URL, and
  the session is an HttpOnly cookie on the gateway's own address, which no callback carries. A
  person's gateway has no associated domain for the app, and on the Mac the system sheet uses the
  default browser's cookies. The in-app sheet is the one place the app can read the cookie, so it
  is built to hold the page at arm's length (below).
- **The page is untrusted** (`AccessSignInPolicy`): only a link the person taps is held to the
  origins the sheet has been on (the gateway's, and those the access gateway or the page itself
  sent it to by redirect, form or script); a tap anywhere else, and any new window, opens in the
  browser through `WebLink`. Frames inside the page load from any https origin, since identity
  providers embed their own widgets. Other schemes are refused, and plain http only goes to the
  gateway itself or a local address. Its store is non-persistent, the page
  can't write the clipboard, link previews and data detectors are off, nothing is downloaded, and
  nothing from it is logged or reaches a chat. The gateway's client certificate (§11.9) answers
  only the gateway's own handshake.
- **The session**: the cookies, when they run out and the email the token names (shown, not
  verified) go into the Keychain, device-only, account `<gateway id>.access-session`, read only for
  the addresses saved with the gateway. Expiry is the earlier of the cookie's and the token's
  `exp`. They go on every request through the seam (§11.6), to the gateway's origin only. In the
  editor a sign-in belongs to its draft: Check Again tries it (`trying`) and Save keeps it, and
  changing the address drops it. Sign Out drops it from the draft; saving then removes it from
  the Keychain. Sign In… in a chat's banner saves the new session at once; in Settings → Setup it
  opens Edit Gateway, where it's a draft like any other.
- **When it runs out**: an expired session is still sent, and the access gateway's refusal of it
  reads as `signInExpired` (§11.2). The connection stops being kept (§8): no Reconnecting…, the
  chat's banner says "Your access sign-in expired" with Sign In…, the composer says "Sign-in
  needed", and a turn that was streaming waits (`RunFollow.Step.waitForSignIn`). Signing in again
  saves the session, reconnects the gateway and wakes the waiting turns, which re-attach with
  `last_seq` and carry on; the turn kept running on the gateway meanwhile. Saving Edit Gateway
  with a new sign-in or token does the same. Bot Mode behind the same access gateway stops
  reconnecting too, and comes back when the session is saved. A Bot chat shows the same banner
  with Sign In… instead of Bot Mode's Retry, which the access gateway would only refuse again,
  and the sidebar's "Bots are offline" offers Sign In… (Edit Gateway) in place of Retry.
- **How long it lasts** is set on the access gateway, not in the app. Cloudflare Access defaults
  to 24 hours per application and allows from 15 minutes to a month; the identity provider can end
  it sooner.
- **Setting up Cloudflare Access** for it, in general terms: in Zero Trust, add a self-hosted
  application for the gateway's hostname (and Bot Mode's, if it's served apart), with an Allow
  policy for the people who may sign in and the login methods they use, and set its session
  duration. The same application can also allow a service token, for devices nobody signs in on.
