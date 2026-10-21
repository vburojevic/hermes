# Push notifications

Hermes keeps working after the person leaves the app. Notifications bring them back when it
matters: Hermes is paused waiting for them (an approval, a question, a password), a long reply
finished, a scheduled task ran or failed, a Bot mentioned them in a group chat, or a Board card
needs them. A Live Activity shows a long turn while the phone is locked.

This doc covers how a notice travels from the gateway to the device, what each Hermes event sends,
answering from a notification, the Live Activity, permission and settings, and the Apple setup.

The code lives in `Tools/hermes-app-push/` (the Hermes Agent plugin), `Relay/` (the relay),
`Packages/HermesKit/Sources/HermesPush/` (notices, categories, crypto, preferences, Live Activity
state; shared with the extensions), `Packages/HermesKit/Sources/HermesKit/Networking/AppPushClient.swift`
(the plugin's commands), `Push/App/` (`PushCenter`, `PushResponder`, `TurnActivityController`,
`MacNotifier`, the settings and sheets), `Push/NotificationService/`, `Push/NotificationContent/`
and `Push/Widgets/`. The app's push layer compiles under `HERMES_PUSH`, which the app target sets.
The mock plays the plugin (`Tools/mock-hermes/push.py`); how to run it end to end is in
[development.md](development.md).

Design component names: `notification`, `notificationApproval`, `notificationExpanded`,
`notificationActions`, `notificationQuestion`, `notificationExpandedQuestion`,
`notificationActionsQuestion`, `notificationReplyField`, `notificationTask`,
`notificationTaskFailed`, `notificationBot`, `notificationStack`, `notificationHidden`,
`bannerInApp`, `liveActivity`, `liveActivityNeedsYou`, `liveActivityDone`, `islandCompact`,
`islandCompactNeedsYou`, `islandExpanded`, `permissionPrime`, `settingsNotifications`,
`settingsNotificationsOff`, `macSettingsNotifications`, `pushSetup`, `macNotification`.

Hermes names come from the Hermes Agent source: the plugin hooks (`hermes_cli/plugins.py`
`VALID_HOOKS`, `ctx.register_hook`), `command.dispatch` (`tui_gateway/methods_tools.py`),
`approval.respond` and `request.answer` (`tui_gateway/methods_prompt.py`), the approval queue
(`tools/approval*.py`) and `POST /v1/runs/{run_id}/approval` (`gateway/platforms/api_server.py`).

## 1. How a notification gets to the phone

Hermes Agent has no Apple push support. Over the backend socket the app hears everything, but iOS
suspends the app and closes the socket soon after it goes to the background. So:

```
Hermes gateway ── plugin "hermes-app-push" ──HTTPS──▶ push relay ──APNs──▶ iPhone / iPad
   (hooks)          seals each notice per device      (push.hermesapp.dev,   Notification Service
                                                       holds the APNs key)    Extension opens it
```

### 1.1 Gateway plugin

`hermes-app-push` (`Tools/hermes-app-push`) is a standalone Hermes plugin. People install it with
`hermes plugins install … --enable` in the Hermes root and in every profile, since each Bot's
profile has its own plugins, then restart the gateway ([plugins.md](plugins.md) §2; the app's Set
Up Push sheet, §5). Updating and what works without it are in [plugins.md](plugins.md) too. It
registers:

- Hooks: `pre_approval_request` / `post_approval_response` (approvals), `on_human_input_request` /
  `on_human_input_resolved` (questions and password prompts), `pre_llm_call`, `post_llm_call` and
  `on_session_end` (replies, the Live Activity and chats kept current while the app is away), `pre_tool_call` (the Live Activity's step and a
  `clarify` call's questions), `on_room_member_activity` (group chats), `kanban_task_blocked` and
  `kanban_task_completed` (the Board).
- A delivery platform, `apppush` (`ctx.register_platform` with `standalone_sender_fn`), so a
  scheduled task's `deliver: apppush` or `failure_deliver: apppush:fail` reaches the app.
- A watcher in the gateway process for what Hermes has no hook for: Board cards ready for review or
  stopped (the boards' events), and the curator's tidies (each profile's
  `logs/curator/<run>/run.json`, every 30 s).
- The `/app-push` command the app talks to (§1.2).

Every hook only does bookkeeping and queues; one background thread talks to the relay, so a slow
relay never delays a prompt or a turn. A gateway process runs one watcher however many profiles it
serves: every 5 s while a card runs or the boards just changed, slowing to 30 s while they're quiet.
Settings in `config.yaml` under `plugins.entries.hermes-app-push.settings`: `relay_url` (default
`https://push.hermesapp.dev`), `gateway_name` (default the machine's host name) and the watcher's
`card_poll_seconds`, `card_idle_poll_seconds` and `tidy_poll_seconds` ([plugins.md](plugins.md) §5.3).
Its state lives in `<Hermes root>/plugin-data/hermes-app-push`.

### 1.2 Registration

Plugins can't add gateway RPC methods, so the app calls
`command.dispatch {name: "app-push", arg: "<command> <json>"}` on the backend socket and reads one
line of JSON from `output` (`AppPushClient`). Error 4018 means the plugin isn't installed or isn't
enabled. This needs Bot Mode: without a backend link the gateway shows "Needs Bot Mode" (§5).

| Command | Arguments | Answer |
|---|---|---|
| `register` | `device_id`, `token` (APNs, hex), `topic` (bundle id), `environment` (`development` / `production`, from the provisioning profile), `public_key` (base64 X25519), `platform` (`ios` / `ipados`), `name`, `app_version`, `preferences` | `ok`, `gateway {id, name}` (the relay installation id and the gateway's name), `relay` (`ok` or the error), `devices` |
| `unregister` | `device_id` | `removed` |
| `preferences` | `device_id`, `preferences` | the stored preferences |
| `presence` | `device_id`, `state` (`foreground` with `session_id`, `running`, `away`), `live`, `sync` (with `away`: the chats to keep current, at most 20), `unread` and `muted` (with `away`: `{chats, rooms}`, the chats the app icon badge counts, one session id each, and the muted ones, when it counts unread chats) with `badge_others` (what the person's other gateways add to the badge; plugin 1.4.0) | `open` (open requests) |
| `read` | `device_id` (the device that read), `chats` (session ids: each chat's id and its lineage root, a Bot Chat's stored id), `rooms` (group room ids). Plugin 1.4.0 | `ok`, `open` |
| `activity` | `device_id`, `token` (none to end), `session_id`, `activity_id` | `ok` |
| `status` | `device_id` | `version`, `gateway`, `relay_error`, `devices`, `registered`, `preferences`, `open` |
| `test` | `device_id` | sends a test notice now |
| `host` | none | `host {os, machine_id, jobs}`: Hermes's launchd jobs on the gateway's Mac and how launchd runs them, for Settings → Setup → Priority ([setup.md](setup.md) §4.17; plugin 1.3.0) |

- On iPhone and iPad, once there's permission and an APNs token, the app registers with every
  connected gateway, then checks again hourly, when the gateway comes back online and when the token
  changes. A check that finds no plugin or fails waits 30 s, then twice as long each time, up to an
  hour; the Set Up Push sheet asks at once.
- `device_id` is this installation's id (survives updates, not reinstalls). The gateway's relay
  installation id names it in notices; the app keeps the mapping in its App Group.
- Preference changes go to every gateway with push on, 0.6 s after the last change.
- While the app is in front it reports `presence foreground` with the chat on screen every 50 s or
  when the chat changes (the plugin forgets a report after 75 s), and `away` as it leaves, naming
  the chats to keep current meanwhile (`sync`, §2).
- Removing a gateway from the app, or Stop Notifications on its detail page, sends `unregister`.
- Reading a chat, a Bot or a group chat in the app (opening it, or Mark as Read) sends `read` to
  that gateway, at most once a second with everything read meanwhile (§2, Reading). An older
  plugin answers it with an error, which the app ignores.

### 1.3 Encryption

The plugin seals each notice for each device: an ephemeral X25519 key, HKDF-SHA256 (salt = the
ephemeral public key ‖ the device public key, info `hermes-app-push v1`, 32 bytes) and
ChaCha20-Poly1305. The envelope is `{"v": 1, "epk": base64, "box": base64(nonce ‖ ciphertext ‖
tag)}`, CryptoKit's `ChaChaPoly.SealedBox.combined` (`PushEnvelope`, `crypto.py`). Alert pushes
carry it in `payload.hermes`; Live Activity updates in `content-state.sealed`.

Each gateway's push plugin (one relay installation, which the profiles of one Hermes share) gets
a device key of its own (`PushShared.deviceKey(installation:)`). The app asks the plugin which
installation it is (`status`) the first time, then registers with that installation's key, and
deletes the key when the gateway is removed (`PushShared.forget`). A notice opens with one key
only, so it's from that installation whatever it says about itself: one that names another
installation, or comes from a gateway no longer in the app, keeps the relay's kind-only alert and
can't be answered (`PushShared.open`). Live Activity states open with their gateway's keys.
Builds before this sealed every gateway's notices to one shared key; it keeps opening notices of
known installations until each gateway has registered with its own, and is then deleted.

The service extension stores the opened notice in the notification's `userInfo`
(`hermes.notice`) for display, but nothing that answers a request trusts that copy: the app, the
content extension and background pushes open the envelope again with the device key
(`NotificationDelegate.notice(from:isRemote:)`). Anyone controlling the relay could write a plain
`hermes.notice` of their own. A plain notice counts only in a notification the app posted itself
(the Mac's).

The relay sees only the routing fields APNs needs (device token, environment, topic, push type,
priority, collapse id, expiration), the `aps` fields (category, interruption level, relevance,
sound) and a kind-only fallback alert ("Hermes needs your OK", "Open Hermes to see it."). Every
command or prompt text the plugin puts in a notice goes through Hermes's own redactor first; when
the redactor can't run, the text is left out. Hooks never hand a secret, password, code or sudo
password to plugins, and the plugin never sends one ([quick-actions.md](quick-actions.md)).

The device key is made by the app on first registration and kept in the Keychain, in an access
group the extensions share, readable after first unlock, on this device only (never backed up or
synced). Only its public half leaves the device.

### 1.4 Relay

A small HTTPS service run by Caffeinated Code at `https://push.hermesapp.dev` (`Relay/`, a Convex
app behind a Vercel rewrite). It holds the APNs key, stores no content and needs no account:

- `POST /v1/installations {client, name}` → `{installation_id, secret}` on a gateway's first
  contact. The relay keeps only a hash of the secret; the plugin keeps the secret owner-only in its
  data folder. 20 registrations an hour per address, as the Vercel proxy saw it (calls that
  skip the proxy share one bucket).
- `POST /v1/push` with `X-Hermes-Installation` and `Authorization: Bearer <secret>` → APNs's answer
  `{status, reason?, apns_id?}`. 120 pushes a minute and 5,000 a day per gateway.
- It refuses anything that could carry content: topics other than the app's, alert titles and
  bodies other than the kind-only ones, `aps` fields it doesn't forward, payloads without a sealed
  envelope, Live Activity states other than `{phase, sealed}`, and payloads over 4 KB. Its logs say
  only the push type, environment and APNs status.
- A token APNs calls dead (410, `Unregistered`, `BadDeviceToken`…) makes the plugin forget that
  device.

### 1.5 Notification Service Extension

`HermesNotificationService` (`NotificationService.swift`) opens each notice with the device key and
fills the notification (`NoticePresentation`): text in the device's language with the app's own name
for the gateway, the per-gateway category (§2, Hidden details), the badge, and for a Bot's message
(or a Bot's reply) a communication notification (`INSendMessageIntent`, the Bot's face as
`INImage`, rendered by the app into the App Group). The plugin tags a Bot Chat's notice with the
Bot's profile, except the primary Bot's (the gateway's own profile): the app shares each Bot's own
chat by session id (`PushShared.botChats`, from the roster's `canonical_session`), so that Bot's
notices still carry its name and face (`PushNotice.nameBot`). It also clears delivered notices for
requests answered elsewhere and for chats read since (`read`, §2 Reading), adds the notice's chat to
the unread list and sets the badge (§2, Badge). If anything fails or time runs out, the
notification keeps the relay's kind-only text, never content.

### 1.6 Mac

The Mac app hears its chats over its own connections and posts local notifications
(`MacNotifier`, `UNUserNotificationCenter`) only while it runs, and only when Hermes isn't in front or
the chat isn't the one on screen. Answers go straight back through the chat. The Mac checks that
the plugin is there (`status`) but doesn't register, so the relay never pushes to it.

Not built yet: notifications on the Mac while its app is closed (the plugin already understands a
`running` presence with the chats the Mac notifies about itself, `live`).

Privacy copy in Settings says this plainly: "They are encrypted on the gateway; only this device can
read them, and they reach Apple through our relay."

## 2. What sends a notification

| Hermes event | Notification | Category / actions | Interruption level | Thread | Design |
|---|---|---|---|---|---|
| Approval: `pre_approval_request` on the gateway or transport surface (not a coalesced follower) | "Hermes needs your OK" ("Ada needs your OK" for a Bot) · chat title · "Run `<command>` on `<gateway>`?" (one line, clipped at 80) | `APPROVAL`: Allow Once, Deny (destructive), More Options…. `OPEN` (no actions) for a command Hermes's safety check flagged (`smart_denied`), and on the Mac for one the banner can't show whole | Time Sensitive | session | `notificationApproval`, `notificationExpanded`, `notificationActions` |
| "Save to memory?" (an approval whose description starts with "Save to memory", Ask Before Saving on) | "Hermes wants to remember something" · chat · the entry | `MEMORY`: Save, Don't Save | Active | session | `notificationApproval` with memory copy ([memory.md](memory.md)) |
| Question: `on_human_input_request` `clarify` | "Hermes has a question" · chat · the first question | `QUESTION`: up to 3 choices (for a single, single-select question), Reply… | Time Sensitive | session | `notificationQuestion`, `notificationExpandedQuestion`, `notificationActionsQuestion`, `notificationReplyField` |
| Password: `on_human_input_request` for `sudo`, secrets and other value prompts | "Hermes needs a password" · chat · "For `<command>`" for sudo (never the value) | `PASSWORD` (`OPEN` on the wire): no actions; opens the chat with its card docked | Time Sensitive | session | `notificationApproval` text variant |
| Turn finished: `pre_llm_call` → `on_session_end`, completed with text, when the turn ran at least the Replies threshold (30 s) or this device was watching the chat when it started and has left since | chat title (or the Bot) · the reply's first 4 lines | `REPLY`: Reply… | Active | session | `notification` |
| Scheduled task delivered (`deliver: apppush`, `failure_deliver: apppush:fail`) | task name · "Failed" when it failed · the result's first lines | `TASK`: Open | Passive (Active if failed) | `task:<job id>` | `notificationTask`, `notificationTaskFailed` |
| Bot message in a group chat: `on_room_member_activity` `message.delta`, settled after 5 s of quiet | Bot name · room · the message's first lines | `MESSAGE`: Reply… (a communication notification) | Active | `room:<id>` | `notificationBot` |
| Board card needs you (`kanban_task_blocked`, waiting on a person), is ready for review or stopped (the watcher: `review_requested`, `gave_up`, `crashed`), is done (`kanban_task_completed`) | "Ada needs you on “…”" with the question; "Ready for review"; "Stopped"; "Done" | `CARD`: Reply…, Open (needs you); `BOARD`: Open | Time Sensitive for needs-you; Active for review and stopped; Passive for done | `board:<board>` | `notificationApproval` with card copy ([board.md](board.md)) |
| A widget request: a reply (`on_session_end`) with an `approval`, `choice` or `form` that isn't resolved (`hermes-app-widgets`: a directive whose widget is in its store, or an inline block), whatever the Replies threshold | "Hermes needs your OK" ("Ops needs your OK") · chat · the widget's title; a private one says only "Hermes sent a request" | `OPEN` only (kind `widget`): answered on its card, where Face ID and the signature are ([widgets.md](widgets.md) §12). Its claim (`pre_tool_call` on `widget` claim or resolve) withdraws it | Time Sensitive for approvals, else Active | session | `notificationApproval` with widget copy |
| The curator tidied and changed something (the watcher) | "Hermes tidied its skills" · "Merged 2 overlapping skills and archived 3 unused ones." | `OPEN`: opens Tidying | Passive | `learned:<profile>` | [learned.md](learned.md) |
| Send a Test Notification (a gateway's detail page) | "Push notifications are on" · "Home Server can reach this device." | `OPEN` | Active | — | — |
| Answered anywhere, timed out or cancelled (`post_approval_response`, `on_human_input_resolved`) | The delivered notification goes (a background push) | — | — | — | — |

Not built yet: notices for a finished background process or side task. The plugin sends none
(helpers don't notify on their own), and the `background` preference is kept only for older apps.

Board cards and tidies follow the Scheduled tasks setting: a card that needs you or stopped counts
as a failure; review, done and tidies need All.

A turn that ends in Hermes' silence marker (`[SILENT]`, `NO_REPLY`; for a routine's output also
`[SILENT]` with a note after it) is the agent choosing to say nothing. Hermes delivers nothing for
it and the app hides it in the chat, so the plugin sends no reply for it either (Hermes' own
`gateway.response_filters` rule, plain markers on an older Hermes; plugin 1.2.1).

Rules:

- **Grouping.** `threadIdentifier` is the chat (session), room, task, board or profile, so a chat's
  notifications stack (`notificationStack`); the chat title is the subtitle.
- **One per request.** `apns-collapse-id` is the request id, so a repeat replaces, never duplicates.
  Replies collapse per chat, task results per job, card news per card, tidies per profile.
- **Withdrawing.** When a request settles (answered anywhere, timed out, cancelled), the plugin sends
  every device a background push (`withdraw`, with the request ids and the open count). The app
  removes the delivered notifications, updates the badge and moves the Live Activity back to
  working. Each new notice also lists recently settled requests (`resolved`), and the service
  extension clears their notifications and any "needs you" notification more than a minute past its
  deadline. In the chat, a cancelled request leaves a receipt ("Hermes stopped waiting · no answer
  in time", "Answered on another device").
- **Keeping chats current.** Leaving the app, the iPhone or iPad names the chats it keeps current
  while away (`presence away` with `sync`): the one on screen, the Bots' own chats and the five
  most recent chats in the list, at most 20 (`BotWorkspace.chatsToKeepCurrent`). The plugin keeps
  that list for a day. When a turn ends in one of them (`on_session_end`) and the device isn't
  back in the app, it sends a background push (`sync`, with the chat ids), at most one a minute per
  device: a change inside the minute waits for it, and goes then. The app reads those chats'
  stored rows over HTTP, with the chat list, and keeps them on the device (`keepCurrent`, at most
  20 s), so they show as they are when the person comes back, even before the socket has. It only
  reads: attaching a chat would bring the socket back in the background. iOS also runs an app
  refresh now and then (`co.caffeinatedcode.hermes.refresh`, `.backgroundTask(.appRefresh)`,
  asked for 15 minutes after leaving) that reads the same chats, for when no push comes: iOS
  rations background pushes, and none reach an app the person force-quit.
- **Expiry.** Approvals time out after `approvals.timeout` (default 300 s), questions after
  `agent.clarify_timeout` (default 3600 s), sudo prompts after 120 s and other value prompts after
  300 s. `apns-expiration` is the deadline (24 hours for other notices) and approvals get relevance
  1.0. The expanded view says how long is left ("It expires in 4 minutes if no one answers").
- **Not in the open chat.** The plugin sends nothing for the chat a device shows; a request held
  back that way goes out when the person leaves. In the app (`userNotificationCenter(_:willPresent:)`,
  `PushCenter.presentation(for:)`), a notice for the chat on screen doesn't banner: its card docks
  above the composer, and a request goes quietly into Notification Center in case the person walks
  away. Other chats banner (`bannerInApp`); task results and tidies only go into the list.
- **Reading.** A chat read anywhere leaves no notifications behind for it.
  - On the device that read it (opening it, or Mark as Read, chats, Bots and group chats alike)
    the app removes the chat's delivered notifications at once: replies, Bot and group messages,
    never a request still waiting for an answer, a task result or a card. It decides from what each
    notification carries (`hermes.notice`, or the sealed envelope when the extension didn't run)
    and removes only those sent before the chat was read (`ReadNotices`). It does the same for
    chats read elsewhere whenever it learns of the read (`sessions.changed`, the list, coming back
    to the app, an app refresh), and on the Mac for its own notifications.
  - The app tells the gateway (`read`, §1.2). The plugin remembers each read for six hours and
    lists the latest in every notice (`read: {chats, rooms}` with the times), so the service
    extension clears those chats' notifications whenever the next one arrives.
  - Devices that aren't in the app and were sent a reply or Bot message for a chat read since get a
    background push (`read`, with the chats and rooms read since the device was last in front and
    when each was read, at most 40 each, and the open count): the app removes their notifications and sets the badge. At
    most one a device every 30 s (a read inside the window waits for it), collapse id `read`, and
    none when the plugin sent that device nothing for those chats: iOS rations background pushes to
    two or three an hour, and none reach an app the person force-quit. What a push doesn't reach,
    the next notice, the next app refresh or coming back to the app catches up.
  - A device that counts unread chats in its badge told the gateway which ones as it left
    (`presence away` with `unread` and `muted`). The plugin keeps that set, adds the chats it
    notifies the device about (not the muted ones), drops chats read anywhere, and when the number
    changes while the device is away sends a badge-only push (`aps {badge}`, nothing shown, priority
    5, collapse id `badge`, plus `badge_others`), so the Lock Screen's badge is right even when the
    app isn't woken.
  - Group chats have no read mark on the gateway (`docs/inbox.md` §1), so the plugin's reads are
    how a room read on one device reaches the others: an app that hears of one (the `read` push,
    or a notice's list, applied when it next comes to the front) marks the room read too, unless
    it moved since.
- **Badge** counts unread, unmuted chats, Bots and group chats plus open "needs you" requests across
  gateways by default (Settings → Notifications → App Icon Badge, Dock Badge on the Mac → Unread
  Chats; Needs You counts only the requests). Requests: each gateway's latest `open` count, ignoring
  counts older than six hours. Chats: one list per gateway in the App Group (`PushShared.unread`),
  which the app writes whenever its counts move (`UnreadStore`), the service extension adds a chat
  to when a reply or message for it arrives (unless it's muted), and every read takes chats off.
  The badge (`PushShared.badge`) is set by the app whenever that list or a count moves and at
  launch (`setBadgeCount`, `NSApp.dockTile.badgeLabel`, so the Mac's Dock shows it too), by the
  extension on every notice, and by the plugin's badge-only push (`docs/inbox.md` §5).
- **Muted chats** are on the device (`docs/inbox.md` §1). The extension delivers their notices
  quietly (`interruptionLevel = .passive`, no sound); approvals, questions, keys and mentions in
  group chats still alert (`PushNotice.quietWhenMuted`, `muteKeys`).
- **Hidden details.** iOS can't vary the hidden-preview text per notification, only per category,
  so each category also exists once per gateway slot (`APPROVAL.3`, 16 slots) whose
  `hiddenPreviewsBodyPlaceholder` names that gateway. With iPhone's Show Previews at When Unlocked,
  a locked phone shows "Needs your OK on Home Server" (`notificationHidden`) and the text after Face
  ID. With Show Message Text off, every notification says only the kind and the gateway ("Reply
  ready on Home Server").

## 3. Answering from a notification

- **Allow Once / Deny** (`UNNotificationAction` with `.authenticationRequired`; Deny also
  `.destructive`). The app wakes in the background, uses the gateway's live backend socket or opens
  a fresh one with the saved sign-in (`PushResponder`), and answers the request the notification
  showed, by id:
  - `answer.via: "socket"`: `approval.respond {session_id, choice: "once" | "deny", request_id}`.
    The gateway falls back from a stale session id to the request id (`tui_gateway/methods_prompt.py`);
    `resolved: 0` means it was already settled.
  - `answer.via: "run"` (an API server run): `POST /v1/runs/{run_id}/approval {choice, request_id}`
    with the gateway's key; 409 means already settled.
- Allow is offered only for a command the notification shows whole (`PushNotice.answersInBanner`):
  on iPhone and iPad the long-press view shows the command the notice carries; on the Mac, which
  has no expanded view, only a single line of at most 80 characters. The plugin clips a command at
  600 characters, ending the cut with "…", and sends none when its redactor can't run, so a notice
  whose command is cut or empty is never answered from the notification either. Nor is a command
  Hermes's safety check flagged. Those open the chat, where the card shows the whole command.
- Approval text is decoded through `VisibleText`, so invisible and reordering characters show as
  their codes (`⟨U+202E⟩`) on the notification, the expanded view and the Live Activity.
- **More Options…** opens the chat with the approval card docked, showing every answer it allows
  (Deny, Allow Once, Allow in This Chat, Always Allow, the last behind a confirmation). "Always" is
  never one tap from the Lock Screen.
- **Save / Don't Save** answer a "Save to memory?" request like Allow Once and Deny, offered only
  when the body shows the whole entry (240 characters, 80 on the Mac; `PushNotice.savesInBanner`).
  A longer entry opens the chat's card.
- **Question choices** answer `clarify` with that choice; **Reply…**
  (`UNTextInputNotificationAction`) answers it with the typed text. The app finds the open request
  in the session's `session.resume` snapshot (`open_requests`, matched by the first question) and
  calls `request.answer {id, result: {answers}}`; a question with several parts gets the answer for
  the first and the rest in the app.
- **Reply…** on a reply or a message sends a new message: a chat's as a new run on the API server
  (`POST /v1/runs`), a Bot Chat's with `session.resume` in the Bot's profile and `prompt.submit`, a
  room's with `groups.send`. On a card that needs you it comments on the card and moves it back to
  Ready ([board.md](board.md)).
- A tap or **Open** shows the chat, Bot Chat, room, Tasks, the card or Tidying. A Bot Chat opens
  as the Bot, found by the notice's profile or, for the primary Bot, by its chat
  (`PushCenter.open`); the Mac's own notifications carry the profile.
- A reply or message it opens is fetched at once (`ConversationModel.notificationOpened`), not
  when the roster next notices the chat moved: on a busy Mac that waited for the socket, then
  `profiles.list`, then the whole page. Until the newest row is Hermes's, stored no earlier than
  15 s before the notice's `sent_at`, it looks again after 2, 5, 10 and 20 s: Hermes notifies as
  a turn ends, and a busy Mac can store the reply after that. A notice that arrives for the chat
  on screen (no banner) does the same.
- On the Mac, answers from its own notifications go straight back through the chat's live
  connection (`MacNotifier.handle`): Allow Once and Deny answer the approval card, a choice or a
  typed answer answers the question, and Reply… sends a message.
- Only a failure leaves a notification, a quiet one: "Couldn't reach Home Server · Open Hermes to
  answer.", or "Already answered" when the request settled first.
- Answering in the background needs the gateway reachable from the device (the same network,
  Tailscale and so on). If it isn't, the failure notification says so; the app shows its offline
  banner when opened.

## 4. Live Activity and Dynamic Island

- ActivityKit starts activities only for an app in front, so the app starts one
  (`TurnActivityController`, `pushType: .token`) when a turn has run 15 s while the app is showing,
  or as the person leaves if a turn already has. One activity per gateway: the newest running turn
  wins and replaces the older one. Its push token goes to the plugin (`/app-push activity`), which
  sends the updates through the relay.
- The plugin's updates carry only the phase in the clear (`content-state {phase, sealed}`); the
  widget opens the rest with the device key. Updates the app makes itself carry the state as is.
- States (`TurnActivityState`):
  - **Working:** the step from the latest tool ("Running a command: npm test", "Searching the web"),
    progress from the plan (steps done of total), elapsed time. The plugin sends at most one working
    update every 12 s.
  - **Needs you:** the command (or the question). Deny and Allow Once (`AnswerFromActivityIntent`, a
    `LiveActivityIntent` that needs Face ID or the passcode) show only beside a command on one line
    of at most 50 characters; anything longer opens the app. The app never puts a flagged command's
    request on the activity it starts.
  - **Done:** the result line and whether it succeeded; it ends after 4 minutes.
- Designs: `liveActivity`, `liveActivityNeedsYou`, `liveActivityDone`, `islandCompact`,
  `islandCompactNeedsYou`, `islandExpanded`. A Bot with a drawn face shows it in the Island; others
  show the Hermes wing.
- A needs-you update alerts once (a kind-only alert with sound), so the Island expands by itself.
- Answering anywhere moves the activity back to working ("Continuing"); the turn ending ends it, from
  the app and from the plugin.
- Toggle: Settings → Notifications → Live Activity.

## 5. Asking for permission and settings

- **When to ask.** Never at first launch or during setup after pairing. The app asks with
  `permissionPrime` (a partial sheet) at the first approval or question, after the first turn that
  ran over 30 s, or when the person leaves while a turn runs. A moment that comes while the app isn't
  in front is kept and asked about when they're back. Turn On Notifications calls
  `requestAuthorization([.alert, .sound, .badge, .providesAppNotificationSettings])`; Time Sensitive
  comes from the entitlement. Not Now waits 7 days and asks once more at the next moment, then only
  from Settings.
- **Settings → Notifications** (`settingsNotifications`, `macSettingsNotifications`). The gateway
  decides what to send, so the preferences go to every gateway with push on (`PushPreferences`):
  - Needs you: Approvals and questions (on), Passwords and sign-ins (on).
  - While you're away: Replies (on, turns over 30 s), Scheduled tasks (All / Failures Only / Off;
    default All), Bots and group chats (All / Mentions / Off; default Mentions).
  - Lock Screen (iPhone and iPad): Show Message Text (on) and Live Activity (on), with a link to the
    system's notification settings. "When Unlocked" is left to iOS's Show Previews.
  - Gateways: each gateway's state ("Push on", "Needs the Hermes app plugin…" with Set Up…, "Needs
    Bot Mode…" with Set Up…, Offline, or the error, with Check Again). A plugin that answers while
    this iPhone isn't on its list (`status.registered` false: no permission, or no push address
    from Apple, `didFailToRegisterForRemoteNotifications`) says why instead of "Push on". On the
    Mac, a gateway without the plugin says the Mac is notified while Hermes is open and the plugin
    reaches iPhone and iPad (§1.6). A gateway with push on opens its detail page: status, the
    relay's gateway id, Send a Test Notification, and Stop Notifications from it.
  - Footers say when Time Sensitive is off for Hermes (a Focus holds approvals back) and when Live
    Activities are off in iOS Settings, or the last one failed to start.
  - The Settings row sums it up: "Approvals, replies, tasks · 2 of 3 gateways".
- **Denied** in the system settings: `settingsNotificationsOff` says Hermes can't reach the person
  when it needs an answer and opens the system's settings for Hermes
  (`UIApplication.openNotificationSettingsURLString` on iPhone and iPad).
- The system's "Hermes Notification Settings" link opens Settings → Notifications in the app.
- **Set Up Push** (`pushSetup`, which is push's review `pluginReviewPush`, [plugins.md](plugins.md)
  §2.1): shown for a gateway without the plugin (`plugins.manage list` has no `hermes-app-push`, or
  `/app-push status` answers 4018), from Turn On Notifications or Settings → Notifications →
  Set Up…. What you get, what the plugin can do on the gateway (its hooks in words with their
  names, the relay), the promise, the source pinned to the tested commit, then **Install on
  <gateway>**: Hermes and every Bot, a profile at a time ("Installing in Ada… (2 of 5)"), then
  Restart Gateway / Later. **Set Up in Terminal Instead** shows the commands to copy. The sheet asks
  the gateway every 3 s and closes with a check mark when the plugin answers, however it got
  there. A gateway without Bot Mode is asked to link it first (Link Bot Mode…, the docs), with the
  commands. The first time Bot Mode connects, the one ask (`pluginsAsk`) offers push together with
  the app's other plugins.

## 6. Apple setup

- Capabilities (`Push/App/Hermes-iOS.entitlements`, `App/Resources/Info.plist`): Push Notifications
  (`aps-environment` from the build configuration), Time Sensitive Notifications, Communication
  Notifications, an App Group and a Keychain access group shared with the extensions, Background
  Modes → Remote notifications (withdrawals and `sync`) and Background fetch (the app refresh, with
  `BGTaskSchedulerPermittedIdentifiers`), `NSUserActivityTypes` → `INSendMessageIntent`, and
  `NSSupportsLiveActivities`.
- iOS targets embedded in the app (`project.yml`): `HermesNotificationService` (opens notices, the
  communication intent), `HermesNotificationContent` for the `APPROVAL`, `QUESTION` and `CARD`
  categories and their slots (`notificationExpanded`: the command, Hermes's description of the risk,
  how long is left; a question; a card's question), and `HermesWidgets` for the Live Activity.
- Categories are registered at launch and whenever the gateways change (`NotificationCatalog`):
  `APPROVAL`, `QUESTION`, `REPLY`, `MESSAGE`, `TASK`, `OPEN`, `PASSWORD`, `MEMORY`, `CARD` and
  `BOARD`, each also once per gateway slot. A question's choices change per request: the payload
  carries them and the content extension sets them as the expanded notification's actions
  (`extensionContext.notificationActions`).
- Mac: the same categories, without hidden-preview text. A local question with choices gets its own
  category (`QUESTION.local.<id>`). Banners show the first action and an Options menu
  (`macNotification`).

## 7. Acceptance checks

- With the app closed, an approval on a gateway with the plugin reaches the Lock Screen within 5 s,
  and Allow Once from the Lock Screen (after Face ID) lets Hermes continue.
- A flagged (`smart_denied`) command's notification has no Allow; it opens the chat.
- A long or multi-line command shows whole in the long-press view; on the Mac its banner has no
  Allow.
- Answering on the Mac removes the iPhone notification within 5 s, and vice versa.
- No notification payload contains a secret, password, code or sudo password; the relay sees only
  kind-only alerts and sealed envelopes, and its logs contain no content.
- With Show Previews at When Unlocked, the locked screen shows only the kind and the gateway; with
  Show Message Text off, so does every notification.
- No banner for the chat on screen; banners for other chats.
- Opening a reply's notification shows the reply within a second or two of the chat opening, even
  when it was stored after the notice (`-HERMES_PUSH_OPEN botreply:ops` against the mock, with
  `POST /api/mock/message-agent` just before it opens).
- The badge equals open requests and reaches 0 when they're answered.
- Time Sensitive approvals break through a Focus that allows Hermes; passive task results never
  light the screen.
- A turn over 15 s shows a Live Activity that moves to needs-you for an approval and ends with the
  result.
- Light, dark and Increase Contrast match the design.

## 8. Setup

The permission, the plugin and the relay, as Settings → Setup shows them: [setup.md](setup.md)
§4.13.
