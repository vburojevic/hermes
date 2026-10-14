# hermes-app-push

Push notifications for the Hermes iPhone, iPad and Mac app (`docs/notifications.md` in the Elyx
project). Hermes Agent can't push to Apple, so this gateway plugin listens to Hermes's plugin hooks,
seals each notice for every registered device and sends it through the Caffeinated Code push relay
to APNs. The relay sees only routing fields and an encrypted envelope.

## Install

```sh
cp -R hermes-app-push ~/.hermes/plugins/      # or: hermes plugins install <repo>
hermes plugins enable hermes-app-push
hermes gateway restart                          # and restart `hermes serve` / Hermes Desktop
```

Optional settings (`config.yaml`):

```yaml
plugins:
  entries:
    hermes-app-push:
      settings:
        relay_url: https://push.hermesapp.dev
        gateway_name: Home Server
```

Scheduled tasks: `deliver: apppush`, and `failure_deliver: apppush:fail` to hear only about failures.

## What sends what

| Hook | Notice | Category | Level |
|---|---|---|---|
| `pre_approval_request` (gateway surface) | approval, with the queue's `request_id` | `APPROVAL` | time-sensitive |
| `on_human_input_request` `clarify` | question, choices from the `clarify` tool call | `QUESTION` | time-sensitive |
| `on_human_input_request` `sudo` | "needs a password" (what for, never the value) | `OPEN` | time-sensitive |
| `pre_llm_call` → `on_session_end` | reply (its first three lines), when the turn ran ≥ the device's threshold or the device was watching the chat when the turn started and has left since | `REPLY` | active |
| cron delivery (`apppush`) | task result or failure | `TASK` | passive / active |
| `kanban_task_completed` / `kanban_task_blocked` | a Kanban card done, or stuck | `TASK` | passive / active |
| `on_room_member_activity` | a Bot's group message (settled after 5 s) | `MESSAGE` | active |
| `subagent_stop` (≥ 60 s, after its turn) | background work finished | `OPEN` | passive |
| `post_approval_response`, `on_human_input_resolved` | background "withdraw" push | — | — |

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
| `presence` | `device_id`, `state` (`foreground` + `session_id`, `running`, `away`), `live` (chats the app notifies about itself, the Mac) | `open` |
| `activity` | `device_id`, `token` (or none to end), `session_id`, `activity_id` | `ok` |
| `status` | `device_id` (optional) | version, relay, devices, registered, preferences, open |
| `test` | `device_id` | sends a test notice now |

Approvals carry `answer`: `{"via": "socket", "session_id"}` (`approval.respond` on the backend socket) or
`{"via": "run", "run_id"}` (an API server run: `POST /v1/runs/{run_id}/approval`); a messaging platform's own
approvals carry none and only open the app. Questions answered in the TUI gateway carry `{"via": "socket"}`:
the app reads the session's open requests (`session.resume`) and answers with `request.answer`.

Replies skip subagent turns and messaging-platform chats (their own app already notifies).

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

```sh
~/.hermes/hermes-agent/.venv/bin/python -m pytest Tools/hermes-app-push/tests --import-mode=importlib
```

They load the plugin through Hermes's own plugin manager in a throwaway `HERMES_HOME`, drive the real
approval queue and human-input hooks, and check what a fake relay receives (including that it never sees
a command, prompt, reply or secret).
