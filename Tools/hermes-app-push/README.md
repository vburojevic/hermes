# hermes-app-push

Push notifications for the [Hermes](https://github.com/vburojevic/hermes) iPhone, iPad and Mac app.
Hermes Agent can't push to Apple, so this gateway plugin listens to Hermes's plugin hooks, seals each
notice for every registered device and sends it through the Caffeinated Code push relay to APNs. The
relay sees only routing fields and an encrypted envelope.

The app's [docs/plugins.md](https://github.com/vburojevic/hermes/blob/main/docs/plugins.md) covers
what works without the plugin, installing, updating and changing it, and
[docs/notifications.md](https://github.com/vburojevic/hermes/blob/main/docs/notifications.md) the
whole design. This plugin is developed in the app's repository (`Tools/hermes-app-push`) and
published here with `Scripts/publish-push-plugin.sh`; send changes there.

## Install

Each Bot is a Hermes profile with its own plugins, so install it in the root and in every profile:

```sh
hermes plugins install vburojevic/hermes-app-push --enable
for p in $(ls ~/.hermes/profiles 2>/dev/null); do hermes -p "$p" plugins install vburojevic/hermes-app-push --enable; done
hermes gateway restart        # registers the apppush delivery and starts the Board and tidy watcher
```

The app does this itself: once Bot Mode is linked it asks once, then installs the plugin in the root
and every profile, pinned to the commit it was tested with, and keeps it current (Settings →
Notifications → your gateway → Set Up… does the same). It reaches the plugin through the gateway's
Hermes backend (`hermes serve`, Bot Mode in the app). `hermes plugins update` refuses a pinned
install: the app moves it, or reinstall with `--force --ref <sha>`.
A Bot made later with "copy setup from the primary" gets the root's plugins; one made from scratch
needs its own install.

## Update

```sh
hermes plugins update hermes-app-push
for p in $(ls ~/.hermes/profiles 2>/dev/null); do hermes -p "$p" plugins update hermes-app-push; done
hermes gateway restart        # and restart `hermes serve` / Hermes Desktop for Bot Mode chats
```

An update only pulls the files. Running processes keep the code they loaded until they restart; a
Bot's own `hermes -p` processes (its routines) load the new code on their next run.

## Settings

All optional, in each home's `config.yaml` (a profile reads its own):

```yaml
plugins:
  entries:
    hermes-app-push:
      settings:
        relay_url: https://push.hermesapp.dev
        gateway_name: Home Server
        card_poll_seconds: 5        # Board cards: while a card runs or the boards just changed
        card_idle_poll_seconds: 30  # ...backing off to this while the boards are quiet
        tidy_poll_seconds: 30       # finished skills tidies
```

One gateway process runs one watcher for Board cards and tidies, however many profiles it serves
(a multiplexed gateway imports the plugin once per profile). The watcher reads the state file without
a lock and writes only when a cursor moves.

Scheduled tasks: `deliver: apppush`, and `failure_deliver: apppush:fail` to hear only about failures.

## What sends what

| Hook | Notice | Category | Level |
|---|---|---|---|
| `pre_approval_request` (gateway surface) | approval, with the queue's `request_id` | `APPROVAL` | time-sensitive |
| `on_human_input_request` `clarify` | question, choices from the `clarify` tool call | `QUESTION` | time-sensitive |
| `on_human_input_request` `sudo` | "needs a password" (what for, never the value) | `OPEN` | time-sensitive |
| `pre_llm_call` → `on_session_end` | reply (its first three lines), when the turn ran ≥ the device's threshold or the device was watching the chat when the turn started and has left since | `REPLY` | active |
| `pre_llm_call` → `on_session_end`, the reply asks with an `approval`, `choice` or `form` widget (hermes-app-widgets) | widget request, at once: "Hermes needs your OK" with the widget's title, or "Hermes sent a request" for a private one; answered on its card in the app | `OPEN` | time-sensitive (approval) / active |
| cron delivery (`apppush`) | task result or failure | `TASK` | passive / active |
| `kanban_task_completed` / `kanban_task_blocked` | a Kanban card done, or stuck | `TASK` | passive / active |
| `on_room_member_activity` | a Bot's group message (settled after 5 s) | `MESSAGE` | active |
| none: the gateway reads each profile's new `logs/curator/<run>/run.json` every 30 s | "Hermes tidied its skills" when a tidy merged, archived or marked something (once per run; follows the tasks setting) | `OPEN` | passive |
| `post_approval_response`, `on_human_input_resolved`, `pre_tool_call` on `widget` claim or resolve | background "withdraw" push | — | — |
| the app's `read` (a chat or group chat read on another device) | background "read" push to devices away from the app that were sent a reply or Bot message for it or count it, and a badge-only push (`aps {badge}`) to those that count unread chats. A reply or message read before its notice goes notifies nothing | — | — |

Live Activities: `pre_llm_call`, `pre_tool_call`, approvals and questions, and `on_session_end` update the
activity a device registered for that chat.

Rules: one notice per request (`apns-collapse-id` = request id), `apns-expiration` = the request's
deadline, no push to a device showing that chat, none to a Mac whose app is running (it posts its own),
and per-device preferences decide the rest.

## App protocol

Plugins can't add gateway RPC methods, so the app calls
`command.dispatch {name: "app-push", arg: "<command> <json>"}` and reads one line of JSON from
`output`. A `4018` error means the plugin isn't installed.

| Command | Arguments | Answer |
|---|---|---|
| `register` | `device_id`, `token` (hex), `topic` (bundle id), `environment` (`development`/`production`), `public_key` (base64 X25519), `platform`, `name`, `app_version`, `preferences` | `ok`, `gateway {id, name}`, `relay`, `devices` |
| `unregister` | `device_id` | `removed` |
| `preferences` | `device_id`, `preferences` | the stored preferences |
| `presence` | `device_id`, `state` (`foreground` + `session_id`, `running`, `away`), `live` (chats the app notifies about itself, the Mac), `sync` (with `away`: chats to keep current; a turn ending in one sends the device a background `sync` push, at most one a minute), `unread` and `muted` (with `away`: `{chats, rooms}`, what the app icon's badge counts and what it never counts; at most 200 of each), `listed` (with `away`: every chat the app lists; only those count), `unmarked` (with `away`: listed chats Hermes never marked, which count only once a `read` names them) | `open`, `read` (the last six hours' reads, as notices list them) |
| `read` | `device_id` (the device that read), `chats` (session ids), `rooms` (group chat ids), at most 50 of each | `ok`, `open` |
| `activity` | `device_id`, `token` (or none to end), `session_id`, `activity_id` | `ok` |
| `status` | `device_id` (optional) | version, relay, devices, registered, preferences, open, read |
| `test` | `device_id` | sends a test notice now |
| `host` | none | `host {os, machine_id, jobs}`: Hermes's launchd jobs on this Mac (gateways, dashboards and their proxies) with `label`, `role`, `plist`, `process_type`, `spawn_type`, `pid`, `priority` |

Approvals carry `answer`: `{"via": "socket", "session_id"}` (`approval.respond` on the backend socket) or
`{"via": "run", "run_id"}` (an API server run: `POST /v1/runs/{run_id}/approval`); a messaging platform's own
approvals carry none and only open the app. Questions answered in the TUI gateway carry `{"via": "socket"}`:
the app reads the session's open requests (`session.resume`) and answers with `request.answer`.

Replies skip subagent turns and messaging-platform chats (their own app already notifies).

Reading: every notice lists the chats and rooms read in the last six hours (`read: {chats: [[id, at], …],
rooms: […]}`, the newest 12 of each; the oldest give way first when a notice would pass the relay's
4 KB), and so do withdrawals and syncs. A device away from the app that was sent a reply or Bot message for
something read elsewhere, or counts it in its badge, gets a background `read` push (`read: {chats: [[id, at], …], rooms}`: all read since it was last in front,
with when each was last read, at most 40 each; `open`), at most one every 30 s, collapse id `read`. A device that left with `unread` gets a badge-only
push (`{"aps": {"badge": n}}`, priority 5, collapse id `badge`) when its count (open requests + unread
chats + unread rooms) moves: down for a chat or room read elsewhere, up for a reply
or message it's sent (not a muted one, only in a chat its list shows, and not in one Hermes never marked
until it's read). A reply or message whose chat
was read on some device after it landed (a room read while its message settles) goes to no device and
counts on none. Coming back to the app (`presence foreground`) forgets all of it for that device.

Preferences: `approvals`, `passwords`, `replies`, `reply_after` (seconds), `tasks` (`all`/`failures`/`off`, default `all`),
`bots` (`all`/`mentions`/`off`), `background`, `live_activity`, `show_details`, `mention_names`.

## Encryption

Per notice: an ephemeral X25519 key, HKDF-SHA256 (salt = ephemeral public key ‖ device public key, info
`hermes-app-push v1`, 32 bytes), ChaCha20-Poly1305. Envelope:
`{"v": 1, "epk": base64, "box": base64(nonce ‖ ciphertext ‖ tag)}` — CryptoKit `ChaChaPoly.SealedBox.combined`.
Alert pushes put it in `payload.hermes`; Live Activities in `content-state.sealed` (the widget opens it).

## Relay protocol

- `POST /v1/installations {client, name}` → `{installation_id, secret}` (stored owner-only in
  `<HERMES_HOME>/plugin-data/hermes-app-push/relay-secret`).
- `POST /v1/push` with `Authorization: Bearer <secret>` and `X-Hermes-Installation`:
  `{token, environment, topic, push_type: alert|background|liveactivity, priority, collapse_id?, expiration?, payload}`
  → `{status, reason?, apns_id?}`. A dead token (`410`, `Unregistered`, `BadDeviceToken`, …) removes the device.

## Tests

From the app's repository (`tests` here):

```sh
HERMES_SOURCE=<hermes-agent> <its venv>/bin/python -m pytest Tools/hermes-app-push/tests --import-mode=importlib
```

They load the plugin through Hermes's own plugin manager in a throwaway `HERMES_HOME`, drive the real
approval queue and human-input hooks, and check what a fake relay receives (including that it never sees
a command, prompt, reply or secret).
