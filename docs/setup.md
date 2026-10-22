# Setup: features that need something configured

Much of the app depends on something set up outside it: Bot Mode on the gateway, the app's
plugins, a model and its key, a memory provider, a Bot's voice, a permission on this device.
This doc has the rule every such feature follows, the shared views that draw it, and each
feature's states: what tells them apart, the Hermes calls behind them, what the app shows and how
to set it up. [AGENTS.md](../AGENTS.md) has the short version of the rule.

## 1. The rule

A feature that depends on something configured never just fails or hides. Where it matters,
the app shows:

- **its state:** ready, partly set up or not set up, and what that means for the person;
- **the fix:** configured in the app wherever Hermes accepts it (`PUT /api/config`,
  `profiles.configure`, `plugins.manage`, the env and secret routes…), read from the Hermes Agent
  source, never guessed;
- **otherwise the steps:** what's missing and the exact way to set it up elsewhere (the `hermes`
  command or config key, the Desktop setting, a link to the docs), with Check Again;
- **a fallback:** if the feature can still work in a lesser way, it does, and says why.

Settings on a person's gateway change only when they tap in the app: the app never changes a
setting by itself, and a check never costs money (no model calls).

### 1.1 States

`SetupStatus.State` (HermesKit, `Setup/SetupStatus.swift`):

| State | Label | Meaning |
|---|---|---|
| `ready` | Ready | Set up and working. The detail says what's in use ("ElevenLabs · Adam") |
| `limited` | Partly set up | Works in a lesser way; the fallback line says how and why |
| `notSetUp` | Not set up | Doesn't work until it's set up, and nothing stands in for it |
| `unknown` | Can't check | The app can't tell: the gateway is out of reach, or the check needs Bot Mode |
| `checking` | Checking… | Asking the gateway or the device |

An older Hermes Agent without the route a feature needs is `notSetUp`, with
`SetupStep.updateHermes` (`hermes update`) as its step. A refusal the person can't fix from here
(a 403 on a route that needs the dashboard) is `notSetUp` with the steps that fix it where it can
be fixed.

### 1.2 Fixing it in the app

`SetupStatus.fix` holds the words of the fix ("Turn On", "Install…", "Add Key…"); the view that
shows the status passes the action, so the feature's model makes the call. A fix the app makes:

- goes through a route Hermes has for it, with the same error handling as the rest of the
  feature, and is mocked with its refusals (§5);
- asks first when it restarts something or changes every profile, and says what it changed;
- checks again afterwards, so the state shown is the gateway's, not the app's guess.

### 1.3 Steps elsewhere

`SetupStatus.steps` are `SetupStep`s: a sentence that says what to do and where ("On the
gateway's computer, …", "In Hermes Desktop, …"), and the command or config line to run, which the
app shows monospaced with a Copy button. Commands are real `hermes` CLI commands and config keys
from the Hermes Agent source. `SetupStatus.docs` is the page in Hermes Agent's documentation
(`HermesDocs.page`), opened as a web link (Learn More). Check Again is always offered with steps.

### 1.4 Fallbacks

`limited` is for a feature that still works: Talk with this device's voice, search over titles
without Bot Mode's full-text search. The fallback line says what happens and why, in one
sentence, and the feature says it again where the person uses it (`SetupNote`).

### 1.5 Copy

Plain, short and specific, like the rest of the app ([AGENTS.md](../AGENTS.md)). The title is
the feature's name. The detail says what the state means for the person ("Hermes can't reach
this iPhone when it needs you."), not what's broken inside. Steps start with where to do them.
Buttons are verbs in title case: Turn On, Install…, Check Again, Learn More.

## 2. The views

`App/Design/SetupViews.swift`, described for design in
[design-to-swiftui.md](design-to-swiftui.md) §12.

| View | Where |
|---|---|
| `SetupStateLabel` | The state as a glyph and a word, in rows and cards |
| `SetupSection` | A Form section on a Settings page: state and meaning, fallback, the fix (a button, or the feature's own controls), steps, Check Again, Learn More |
| `SetupRow` | A Settings row opening the feature's page; Settings → Setup is a list of them |
| `FeatureSetupPage` | The page a `SetupRow` opens when the feature has no page of its own |
| `SetupCard` | The same as `SetupSection` outside a Form: the top of a list, a panel, the Inspector |
| `SetupMessage` | A full-area message for a panel whose feature can't work at all |
| `SetupNote` | One line where a feature runs on its fallback (the Talk screen, the Listen player) |
| `SetupSteps`, `SetupCommand`, `SetupCheckButton`, `SetupDocsLink` | The parts, for a feature that lays out its own |

## 3. Where it shows

- **Settings → Setup** (iPhone and iPad: Settings → Hermes on <gateway> → Setup; Mac: the Setup
  tab) lists every feature in this doc with its state, in fixed groups (Hermes on the gateway,
  Features, Reaching You, Voice & Audio, On This Device) so rows don't jump while it checks. Each
  row opens the feature's own page, or its `FeatureSetupPage` with the fix and the steps. The
  Settings row says how many things need setting up. `SetupCenter` (one per gateway,
  `workspace.setup`) reads everything when the page or the row appears and again when Bot Mode
  connects or drops; each read lands as it comes back and gives up after 20 s, and a status
  waiting on a read says Checking… the first time round.
- **The feature's own page** puts its setup first while it isn't ready (`SetupSection` or
  `SetupCard`), and keeps the rest of the page usable where it can.
- **Where it's used**, a feature that can't run says so in place: a `SetupMessage` instead of an
  empty panel, a `SetupNote` under a control that falls back, a disabled control with its reason.
  Never a silent no-op, a hidden button or a bare error code.

## 4. Feature by feature

For each feature: what it needs, the states and what tells them apart, what the app shows, and
how to set it up. Commands run on the gateway's computer; `-p <profile>` (`hermes -p research …`)
does the same for one Bot. The checks are `GatewaySetup` (HermesKit, `Setup/GatewaySetup.swift`,
tested in `SetupTests.swift`), `DeviceSetup` and `SetupCenter`.

### 4.1 Bot Mode

Needs Hermes's backend (`hermes serve`, or Hermes Desktop, which starts it) linked in Add or Edit
Gateway. Everything in Bot Mode, projects, the Board, memory, Apps and Tools, Learned, the app's
plugins, "/" commands, sending files, searching what was said, Talk's voices and read sync need
it; chats, Tasks, Skills and models work without it.

| State | Told by | The app shows |
|---|---|---|
| Not set up | no link (`bot.backend == nil`) | What Bot Mode adds, Link Bot Mode… (Edit Gateway), the steps below |
| Not set up | `BotRoster.State.signInRequired`: a REST 401, socket close 4401 | Sign In… (Edit Gateway) |
| Can't check | `BotRoster.State.failed(reason)` | The roster's reason, "Chats still work.", Edit Gateway… and `hermes serve` |
| Ready | roster online | "Linked · 5 Bots" |

Set up: `hermes serve` on the gateway's computer. From another device the backend needs a
sign-in: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `…_PASSWORD` and `…_SECRET` in `~/.hermes/.env`,
then `hermes serve --host 0.0.0.0`, and Username & password in Edit Gateway. Docs:
`user-guide/bot-mode`, `user-guide/features/web-dashboard`.

When signing in by itself fails and `/api/status.auth_required` is true, Bot Mode asks for a
sign-in (Username & password) instead of retrying as offline. The sidebar's "Bots are offline"
shows the roster's reason. Pages that run on Bot Mode show its setup where they'd be empty
(`BotModeSetupMessage`: the Board, Learned, Projects) or a Link Bot Mode… button in their note
(`BotModeLinkButton`: Memory, Apps and Tools, Set Up Push).

### 4.2 Hermes Agent

The version comes from `/api/status.version` (backend) or `/health` (gateway). A gateway too old
for the app fails to connect with `unsupportedServer` (Not set up: `hermes update`, then `hermes
gateway restart`). `GET /api/hermes/update/check` (cached by Hermes for a day; the app never
forces it; the cache is keyed by the checkout's commit, so it's fresh after an update) gives
`behind`, `can_apply` and `update_command`: an update keeps the row Ready, with "an update is
available" and the command. Docs: `getting-started/updating`.

Where `can_apply` (a git checkout), Update Hermes… updates it from the app, after a confirmation
("Hermes restarts once running chats and tasks finish"), the way the dashboard does
(`web/src/contexts/SystemActions.tsx`):

- `POST /api/hermes/update` starts `hermes update` and returns its `action_id`, or `ok: false`
  with Hermes's words when this install doesn't update itself (a desktop app bundle, Nix, a
  container). The app shows those words, without the CLI's "✗", and the command when the words
  don't already carry it.
- `GET /api/actions/hermes-update/status?lines=300` every 2 s: its lines and the step running
  now show under the section while it runs (§4.2a). The dashboard restarts along the way, so
  failed polls are expected. Bot Mode signs in
  again by itself, and each poll uses its current client. Ten minutes without an answer stops the
  follow ("stopped answering… Check Again in a minute").
- Done: only a receipt carrying the start's `action_id` counts; the route attaches the latest
  receipt, which may be another profile's run. A `success` or `partial` receipt with `followups`
  or a `user_action` is Partly set up: Update Again… finishes the follow-ups, and the person's
  own step is shown in Hermes's words (a rerun doesn't do it). Otherwise exit 0 is Ready with
  the new version, any other exit is Partly set up with the last log line and Try Again…. Not
  running with no exit code stays "updating" for 90 s (the record lags a restart), then reads
  as unknown.

`HermesUpdateStart`, `HermesUpdateStatus.outcome(actionID:)` and `HermesUpdateRun` (HermesKit)
hold these rules; `SetupCenter.updateHermes()` runs it.

### 4.2a Long jobs: their lines as they run

On Telegram, `/update` streams: `_handle_update_command` (`gateway/slash_commands.py`) starts
`hermes update --gateway` detached into `~/.hermes/.update_output.txt`, and
`_watch_update_progress` (`gateway/run_notifications.py`) polls it every 2 s and sends the new
output as code blocks at most every 4 s, then "✅ Hermes update finished." or the failure notice;
the gateway after the restart sends the last lines again. `/restart` sends "♻ Restarting
gateway…", then a notice once it's back. Hermes refuses `/update` off messaging platforms
("only available from messaging platforms"), and its desktop surface marks both `terminal`.

The app gets the same lines from the dashboard, which starts long jobs with their output in
`~/.hermes/logs/<job>.log` and tails it at `GET /api/actions/{name}/status?lines=N` (1 to 2000;
`running`, `exit_code`, `lines`; `hermes_cli/web_routers/actions.py`). The file keeps every run,
each after `=== <name> started <time> [<action id>] ===`. The app runs two of them:

| Job | Started by | Started with | Followed at | Done |
|---|---|---|---|---|
| Update Hermes | Settings → Setup → Hermes Agent, /update | `POST /api/hermes/update` | `actions/hermes-update/status` | its receipt (§4.2) |
| Restart the gateway | /restart | `POST /api/gateway/restart` | `actions/gateway-restart/status` | exit 0; any other exit failed |

- **What shows** (`GatewayJobView`): while it runs, the step running now in words that shimmer,
  the one moving thing there (`docs/chat.md` §4a), with its time counting up (the system's
  timer text); the newest 6 lines below, mono, as they arrive; Show All Lines (up to 400; Copy
  Lines copies all). Then how it ended, still: "Updated to 0.22.0", "The update stopped (exit
  1)" with "The previous version is still running.", "Hermes doesn't update itself here" with
  Hermes's words and command.
- **Lines** (`ActionLog`): only this run's, after its header (the one with the start's
  `action_id` when there is one), up to the next header. Colour codes go, and a progress line
  redrawn with `\r` keeps its last state. Once a long run pushes its header out of the tail, new
  lines continue from the overlap with the last poll. The step is the newest line marked `→`,
  `↻`, `☤` or `⏳`, without its mark, else the newest line.
- **One run, two places**: `SetupCenter` runs both jobs, so /update in a chat while Settings
  updates shows the same run, and a page opened later shows it too. Each run has a number
  (`GatewayJob.Ref`); a chat card keeps showing its own run, as it ended, after a newer one
  starts. The cards live with the chat's other command cards (local, not in Hermes's transcript).
- **From a chat**: /update and /restart are commands the app runs (`ConversationModel.runCommand`).
  Picking one from the "/" menu puts it in command mode; nothing runs until Send (the composer's
  `confirmsOnSend`). Send is the confirmation, as on Telegram; Settings asks first.
- **Not in the app**: Hermes's questions during an update. Telegram gets them as buttons through
  `--gateway`'s prompt file; the dashboard starts `hermes update` without input, so Hermes takes
  its defaults.
- **Polling**: every 2 s (Hermes's dashboard: 1.5 s; Telegram: new lines every 4 s). A restart
  that stops answering for 10 minutes, or reads not running with no exit code for 90 s, says
  so and stops following.
- **Priority afterwards**: both jobs write the gateway's launchd plist again without
  `ProcessType`, so on a Mac each result can end with Hermes at background priority (§4.17).

`ActionLog`, `ActionStatus`, `ActionRunState` and `GatewayJob` (HermesKit) hold these rules.

A feature whose method or route this gateway's Hermes doesn't have yet (the socket's -32601
"unknown method: … run `hermes update`", the dashboard's 404 "No such API endpoint") says so in
the same words everywhere: `HermesVersionGap.message` ("This needs a newer Hermes Agent on the
gateway. Update it in Settings → Setup → Hermes Agent, or run hermes update there."), which both
errors' descriptions carry, so any alert or failure line shows it. A feature with its own empty
state checks `HermesVersionGap.isMissing(error)` and shows the update steps there (the Board's
`missing`, Projects).

### 4.3 Models, providers and keys

`setup.status.provider_configured` (Bot Mode) and the usable providers in `GET /api/model/options`
(gateway). None: Not set up, "chats get no answers", Choose a Provider… (the setup flow's model
step on its own, `SetupFlowView(modelOnly:)`, which saves a key with `model.save_key` or signs in
with a device code), and `hermes model`. Ready: the default model. Docs: `integrations/providers`.

A turn that fails on its provider's credentials says so in the chat instead of Hermes's bare
error (`ProviderProblem`): the gateway protocol's `error_surface` (`layer: "auth"`, `auth_kind`,
`api_key_env`), the `error` event's `code: provider_not_configured`, or the API server's
"Provider authentication failed". A refused key offers Add Key… (`model.save_key {slug, api_key,
profile}` over Bot Mode; the key goes to the gateway and isn't kept on the device), a revoked
sign-in offers Sign In… or `hermes auth add <provider> --type oauth` (below), and no provider
opens Choose a Provider…. Try Again stays. Mock: a message with "key expired" or "signed out"
(OpenAI Codex, whose mock sign-in is approved on its second poll).

The model picker lists providers Hermes reports without credentials (`authenticated: false`)
under Needs a key, with Add Key…, instead of hiding them, and a list that didn't load says why
with Try Again instead of "Loading models…".

A sign-in that expired for a provider Hermes signs in to by device code (Nous Portal, OpenAI
Codex, MiniMax, xAI: `_DEVICE_CODE_STARTERS`) offers Sign In… on the card: Hermes's device-code
flow in the browser (`POST /api/providers/oauth/<provider>/start`, then its poll), as the setup
flow does for Nous. Others (Anthropic, Claude Code) give `hermes auth add <provider> --type
oauth`.

### 4.4 Memory

`GET /api/memory`: the active provider and each provider's `status` (`ready`, `needs_config`,
`unavailable`, `missing`). An active provider that isn't ready is Partly set up: Hermes falls back
to its built-in memory by itself; the step is `hermes memory setup <provider>`. Needs Bot Mode.
The Memory page has the switches and the provider picker ([memory.md](memory.md)). Docs:
`user-guide/features/memory-providers`.

The Memory page marks a provider in use that isn't set up ("Honcho · not set up") and gives
its command. A provider that needs its settings (`needs_config`) opens Set Up from the provider
list (iPhone, iPad) or Set Up a Provider (Mac): Hermes's own fields for it (`GET
/api/memory/providers/{name}/config`: secrets, text, choices, switches, numbers, each shown or
hidden by its `when` as Hermes does), saved with `PUT …/config` (only what changed; an empty
secret is left as it is). Mock: Mem0 needs its key; saving one makes it ready.

An `unavailable` provider offers Install… (Install a Provider on the Mac). Its sheet first lists
what Hermes will run on the gateway, from the provider's plugin (the config route's `setup`:
`pip_dependencies`, installed with `hermes pm install`, and each `external_dependencies` install
command), through `VisibleText` as approvals are. Install runs them with `POST …/{name}/setup`
(body `{"values": {}}`). Hermes answers only when they're done (five minutes a command at most),
so the request waits up to ten minutes. A proxy's 502 or a timeout before then is followed by
re-reading the provider every 5 s, for up to six minutes, until `setup.dependencies_installed`.
Then:

- Installed, needing its settings: Set Up… opens the settings form.
- Installed and ready: Use <provider>.
- A step failed: the failed commands with Hermes's output, Try Again, and `hermes memory setup`.
- Its packages are in place but it's still unavailable: says so, with `hermes memory setup`.

A provider Hermes can't find (`missing`) gives `hermes memory setup`. Mock: Hindsight installs in
about 4 s and then needs its key; `POST /api/mock/memory/install {"fails": true}` makes its `uv`
step fail.

A provider that signs in with OAuth (Honcho) signs in on the gateway with `hermes memory setup
<provider>`: Hermes has no dashboard route to start that sign-in, and its settings route leaves a
key an OAuth token holds as it is (`_write_provider_honcho`), so the app's form can't replace it.

### 4.5 Apps and Tools, MCP

Its page ([connections.md](connections.md)) shows sign-ins that expired, MCP servers that fail
(with Update API Key, Test Again, Sign In) and plugins. Needs Bot Mode.

A built-in toolset that's on but has no key (`GET /api/tools/toolsets`, `configured` false;
Hermes leaves its tools out) reads Needs a key on <gateway>, with an Add a Key… row under it: the
providers that take a key (`GET /api/tools/toolsets/{name}/config`, leaving out the Nous-managed
rows), the picked one's fields, and Save, which writes them to the gateway's `.env` (`PUT
…/{name}/env`, only the toolset's own variables) and makes that provider the one in use (`PUT
…/{name}/provider`). The section's footer also gives `hermes tools`. Mock: image generation and
the browser have no keys; saving Browserbase's or FAL's makes them ready.

When `connectors.list` says `available: false`, the Apps tab tells Hermes's three reasons apart:
apps turned off in config (`tools.connectors`, read with `GET /api/config`; Turn On writes
`tools.connectors.enabled: true`, or `hermes config set tools.connectors.enabled true`), signed in
to Nous without apps in the plan (`GET /api/providers/oauth`, `nous` logged in; the docs), or not
signed in (Sign In to Nous).

### 4.6 Undo for Files (checkpoints)

`GET /api/config` → `checkpoints.enabled` and `terminal.backend`. Off: Not set up, Turn On
(`PUT /api/config`, as the Checkpoints sheet does, [checkpoints.md](checkpoints.md)) or `hermes
config set checkpoints.enabled true`. On, with commands running in docker, modal or another
container: Partly set up, no checkpoints there, `hermes config set terminal.backend local`. Docs:
`user-guide/checkpoints-and-rollback`.

### 4.7 Search

Bot Mode online: Ready, unless `/api/status.fts_rebuild` says the index is rebuilding (Partly set
up, results may be missing). Without Bot Mode: Partly set up, search finds chats by their titles,
and its line says why (not linked, a sign-in, or not answering); a failed full-text search shows
title matches with the reason ([search.md](search.md) §5). Docs: `user-guide/sessions`.

### 4.8 Board

`GET /api/plugins/kanban/workflow`: 404 "Plugin not found" means `kanban` is in
`plugins.disabled` (Not set up, Turn On: the app removes it from the list with `PUT /api/config`,
and the routes come back without a restart; or `hermes plugins enable kanban`); any other 404 is
a Hermes without the Board (`hermes update`). With the Board on and `/api/status.gateway_running`
false, cards wait in Ready (Partly set up, `hermes gateway start`). Docs:
`user-guide/features/kanban`.

The Board screen tells them apart itself, with Turn On for a Board turned off, the update step
for a Hermes without it, and Bot Mode's setup without Bot Mode ([board.md](board.md) §8).

### 4.9 Projects

Bot Mode, and `projects.*`; -32601 means an older Hermes (`hermes update`). All Projects and a
project's home show Bot Mode's setup without it and the update step on an older Hermes
([projects.md](projects.md) §7). Docs: `user-guide/desktop`.

### 4.10 Learning and tidying

`GET /api/curator` → `enabled`, `paused`. Turned off in config: Partly set up, Hermes still learns
skills but nothing tidies them; Turn On writes `curator.enabled: true` (`PUT /api/config`), or
`hermes config set curator.enabled true`. Paused: Resume (`PUT /api/curator/paused`), or `hermes
curator resume`. Docs: `user-guide/features/curator`.

The Learned page's Tidying card says "Tidying is off" while the curator is off in config, its
switch turns it on, and Tidy Up Now waits for it ([learned.md](learned.md) §9).

### 4.11 Scheduled tasks and delivery

Tasks run in the messaging gateway's scheduler: `/api/status.gateway_running` false means they
don't run (Not set up: `hermes gateway start`, `hermes gateway install` to keep it running).
Active tasks from `GET /api/jobs` whose results didn't arrive (`last_status: delivery_failed`,
`last_delivery_error`) make it Partly set up, with Hermes's reason and `hermes gateway setup` for
the platform they deliver to; tasks whose last run failed (`error`, `blocked_config`) or didn't
start (`last_fire_error`) too, since each tries again at its next run. Tasks shows the same on
each task ([tasks.md](tasks.md) §6). Docs: `user-guide/features/cron`.

### 4.12 Group chats

Needs Bot Mode, the room service (`groups.capabilities.driver`), at least two Bots, and
`dashboard.turn_isolation` off: with it on, Hermes refuses members' turns (4121) and requeues them
forever, so rooms never answer. Turn isolation on: Not set up, Turn Off Turn Isolation (after a
confirmation that says what isolation is for) writes `dashboard.turn_isolation: false` with `PUT
/api/config`; or `hermes config set dashboard.turn_isolation false`. No driver: Not set up,
restart Hermes's backend. One Bot: Partly set up. Docs: `user-guide/bot-mode`.

### 4.13 Notifications and the push plugin

The permission (`UNUserNotificationCenter`), and on iPhone and iPad the gateway's push plugin
reached through Bot Mode (`PushCenter.GatewayState`). Off in Settings: Open Settings. Not asked
yet: Turn On Notifications. No plugin: Set Up… on the Notifications page, or `hermes plugins
install vburojevic/hermes-app-push --enable` and `hermes gateway restart`. The plugin there but
this iPhone not on its list (`status.registered` false, for want of permission or a push address
from Apple): Not set up, with the reason. A relay problem: Partly set up, the app still reaches
you while it's open. Every gateway row that isn't on has Check Again. With push on, a plugin
missing, older or turned off in some Bots, or a restart still to do, is Partly set up in the
plugins page's words (`AppPluginStatus`, [plugins.md](plugins.md) §2); an update whose pin adds
access reads "An update asks for more access" until the person allows it. The Mac notifies while
the app runs and needs no plugin. Installing the plugin is [plugins.md](plugins.md) §2;
[notifications.md](notifications.md) §5 has the page.

### 4.14 Widgets

The `widget` tool in the gateway's toolsets (`WidgetStore.isAvailable`). Without the plugin:
Partly set up, Hermes sends lists, numbers and choices as text; the row opens the plugin's review
to install it (`pluginReview`, [plugins.md](plugins.md) §2.1), or `hermes plugins install
vburojevic/hermes-app-widgets --enable`. Missing, older or turned off in some Bots: Partly set up,
with the plugins page's words, and the page lists each profile; an update that asks for more access
shows its consent card there. [widgets.md](widgets.md) has the rest.

### 4.15 Permissions on this device

`DeviceSetup`: the microphone (`AVAudioApplication.recordPermission`), the camera on iPhone and
iPad (`AVCaptureDevice.authorizationStatus`), and Face ID, Touch ID or the passcode
(`LAContext`), which confirms widget approvals. Not asked yet is Ready ("Hermes asks the first
time…"): the app asks where the feature starts, never from Setup. Denied: Not set up, what it
stops and what still works, Open Settings (the app's page on iPhone and iPad, the privacy pane on
the Mac). Face ID turned off for Hermes: Partly set up, the passcode stands in. No passcode: Not
set up.

Where they're used: the microphone alert has Open Settings on every platform and covers voice
messages; the attachment camera checks access first and says how to turn it on; the connection
banner offers Open Settings when Local Network, Wi-Fi or Mobile Data is off for Hermes; Photos
and Camera say when the model can't read pictures. Widget approvals without Face ID, Touch ID or
a passcode: [widgets.md](widgets.md).

### 4.16 Voice and audio

Talk, Listen and voice messages, per gateway and per Bot (`VoiceSetup`, one per gateway,
`workspace.voiceSetup`; the rules are `VoiceSetupRules` in HermesKit, tested in
`VoiceMediaTests.swift`). Read from `GET /api/config?profile=` (the speech and transcription
providers and voices), `GET /api/env?profile=` (which keys are set, by name only) and
`GET /api/audio/voice-live/status`.

| Feature | Ready | Partly set up (and the fallback) |
|---|---|---|
| Talk | Realtime is offered ("Realtime · Cedar") | Hermes Voice answers, in the gateway's voice or the device's; Hermes's reason for no Realtime |
| Listen | The speech provider has its key ("ElevenLabs · Adam") | Replies are read in the device's voice; also after a read fails on the gateway, in a sentence |
| Voice messages | The transcription provider has its key, or needs none | The device transcribes; only "heard no words" needs the gateway |
| Transcribe on the gateway (only while chosen) | "OpenAI, as you speak" (voice-config `stt.streaming`) | Calls transcribe on the device: the provider can't stream, its key is missing (Add Key…), `stt.streaming` is off (Turn On), or a call just failed |
| Hey Hermes (only while on, the gateway's own) | Listening, or the gateway's own microphone listens (`wake.status`) | Waiting for charging (iPhone, iPad); another device is listening. Not set up: off on the gateway (Turn On, `wake.start {persist: true}`), kept for another surface, or no engine (Hermes's hint) |

Without Bot Mode, while the gateway is out of reach, or on a Hermes too old to answer, all three
say Can't check (Hey Hermes too on a Hermes without `wake.*`). Fixes: Add Key… (`PUT /api/env?profile=`, sent once, never kept or logged; a
refusal shows Hermes's reason) and Choose a Voice…; the steps are `hermes config set
OPENAI_API_KEY <your key>`, `hermes config set tts.provider edge` (with `-p <bot>` for a Bot).
Each row in Settings → Setup opens Voice & Audio; Talk, the Listen player and the chat show a
`SetupNote` with Set Up… when they fall back. [voice.md](voice.md) §6.1 has the rest.

### 4.17 Priority (the gateway's Mac)

On macOS, launchd runs a LaunchAgent with no `ProcessType` as a background job (`launchctl print`
says "spawn type = daemon"; older notes say "background"): the system throttles its CPU and I/O,
so when the Mac is busy Hermes answers late or not at all while the person's apps carry on (`man
launchd.plist`, ProcessType). `Interactive` gives a job the limits apps have, none. Hermes writes
its gateway plist without one, and writes it again (still without) on `hermes gateway start`,
`restart`, `install` and `hermes update`, whenever the file differs from the one it generates
(`refresh_launchd_plist_if_needed`, which compares all of it but `PATH`); it never writes a
dashboard's plist. The gateway itself (`hermes gateway run`) and `launchctl kickstart` leave the
file alone. So the app's own Update Hermes and /restart reset it, and say so (below). The cause
is in Hermes Agent: `generate_launchd_plist` (`hermes_cli/gateway_launchd.py`) writes no
ProcessType, and `refresh_launchd_plist_if_needed` counts one added by hand as a difference to
undo. Upstream: issue #72210, PR #72211 (open, not merged); until it's in, the app doesn't work
around it.

- **Read:** `/app-push host` (push plugin 1.3.0, `hostinfo.report`) lists Hermes's launchd jobs on
  the gateway's Mac: its gateways (`ai.hermes.gateway*`), the `ai.hermes.*` jobs that run a
  dashboard or a proxy in front of one, and the job the plugin itself runs in
  (`XPC_SERVICE_NAME`). For each: the plist's ProcessType, the spawn type launchd loaded it with,
  its pid and priority. It runs in the dashboard (the command goes through Bot Mode), so it reports
  the whole Mac, not its own process. A job is throttled when it's loaded as anything but
  interactive, or when its plist no longer says Interactive: launchd keeps running a job as it
  loaded it, and Hermes's update reloads the gateway only once the old one has drained
  ("reload deferred to a transient launchd job"), so right after an update the gateway still
  runs at full priority while its next start won't (`losesPriorityAtNextStart`: "From its next
  start, macOS runs Hermes…", "It runs at full priority until then.").
- **States:** Ready on other systems and when every job is interactive. Partly set up while a job
  is throttled ("macOS runs Hermes on <gateway> as a background job, so when the Mac is busy it
  answers late or not at all"), with one Terminal step per job (`plutil -replace ProcessType
  -string Interactive <plist> && launchctl bootout …; launchctl bootstrap …`) and, for a gateway,
  that updating writes it again. A job whose plist already says Interactive only needs a reload.
  Can't check without the plugin, on an older plugin (with the update step) or when it doesn't
  answer. Needs Bot Mode.
- **Fix, on the Mac, for a gateway on this Mac:** Run at Full Priority…, after a confirmation
  (replies in progress stop; Bot Mode reconnects). The plugin's `machine_id` (a hash of the Mac's
  hardware id, `GatewayHostReport.machineID`) says it's this Mac; with an older plugin, the
  gateway's address resolving to one of this Mac's addresses does, and the app reads the jobs
  itself (`LocalLaunchJobs.report`). Each throttled job gets `ProcessType Interactive` (inserted as
  text, so Hermes's comments stay) and is reloaded with `bootout` and `bootstrap` (`kickstart`
  doesn't read the plist again), dashboards first and the gateway last. A job that still runs at
  full priority only gets the plist (its Terminal step too): nothing restarts. Only `ai.hermes.*`
  jobs whose plist is in `~/Library/LaunchAgents` are touched, whatever the report says.
- **After the app's own update or restart** (Settings → Setup, /update, /restart; §4.2a): once
  it's done (any end but a failed update), the app reads `/app-push host` again as soon as Bot
  Mode is back, every 10 s for up to two minutes while the dashboard restarts. When the gateway is
  throttled, the result says so under how it ended (`PriorityResetView`, in Setup and on the chat
  card): "Updating reset Hermes to background priority" ("Restarting reset…"; "Hermes still runs
  at background priority" when the read before the run already said so), what that means, and
  Run at Full Priority… with the same confirmation on the gateway's own Mac, otherwise the same
  Terminal steps as the Priority row. It follows the reads, so the fix takes it away.
- **The update's confirmation** says it up front on a Mac gateway (a report from `darwin` with a
  gateway job): "Updating resets Hermes to background priority on <gateway>. The app offers to
  restore it when it's done." (`GatewaySetup.updateConfirmation`).
- **Beside Settings, on the Mac** (`macPriorityNotice`): while the gateway runs throttled (or will
  from its next start) and Bot Mode is online, one line in the sidebar's footer, above the
  connection and Settings: the warning glyph, "Background priority" ("Priority drops at next
  start"), Fix… and × (Not Now). It never wraps: the words truncate, so it can't change the
  window's layout at any sidebar width or text size. Its help and VoiceOver label carry the
  headline and what it means ("Hermes runs at background priority. When <gateway> is busy, Hermes
  answers late or not at all. Hermes Agent writes its plist without it on every restart and
  update; the fix is hermes-agent pull request 72211."). Fix… is Run at Full Priority… with its
  confirmation on this Mac, and opens Settings → Setup (the steps) for another. Not Now puts it
  away on this Mac until a read sees the gateway at full priority again, so it comes back only
  after something resets it, never on a timer. The Mac reads `/app-push host` when Bot Mode
  connects (at most hourly), so the line doesn't wait for Settings. The iPhone and iPad keep it to
  Setup and the job results: they can't fix it.

### 4.18 Bot-to-Bot replies

Hermes 0.22 runs `message_agent`'s delivery (`… bot_mode_dm.py --run-delivery …`) as a background
process of the sender's chat without `persist_on_release`, so when the dashboard reaps that chat
(its turn ended while no app was connected) the delivery dies, and the receiving Bot's reply with
it. Upstream: issue #134898, PR #136220. Bot-to-Bot itself needs nothing set up, so the app doesn't
probe or guess from the version: it reads the deliveries it already lists in `process.list`
([background-processes.md](background-processes.md)), and `DeliveryProtection` records per gateway
whether they carried `persist_on_release: true`, on which Hermes version (a new version clears it).

- No row until a delivery has been seen on this version.
- Ready once a protected one was: "A Bot's reply to another Bot survives the sender's chat
  closing."
- Partly set up after an unprotected one: "On this Hermes, a Bot's reply to another Bot can be
  lost when the sender's chat closes before it", with the fallback that keeping the app open
  avoids it, and Learn More on the upstream PR. Once `DeliveryProtection.botDeliveryFixedIn` names
  the release with the fix and the gateway is older, Update Hermes… (§4.2) and its command join
  it. No source-patch steps: the app doesn't suggest editing Hermes.

### 4.19 Passwords

`vault.sources` on Bot Mode's socket ([web.md](web.md) §1). Needs Bot Mode. Hermes's own vault
always works, so Passwords is Ready once Bot Mode is up: the detail names the sources in use
("Hermes vault and 1Password"). A manager whose CLI isn't on the gateway (`installed: false`) adds
its step without counting as something to set up: "To use your Bitwarden logins, install its CLI
(bw) on Studio Mac, then sign in to it there once:" `npm install -g @bitwarden/cli` (1Password:
`brew install 1password-cli`). A Hermes from before Passwords (-32601) is Not set up with "Needs a
newer Hermes Agent on Studio Mac." and `hermes update`. The page itself opens from the row
(Passwords on iPhone and iPad, Open the Passwords Tab on the Mac). Docs:
`user-guide/features/credential-vault`. Mock: `POST /api/mock/vault {"bitwarden": "unlocked"}`,
`{"onepassword": "missing"}`, `{"older": true}` ([web.md](web.md) §10).

### 4.20 Browser

`GET /api/config` (the `.config` read) and Bot Mode ([web.md](web.md) §5): where Hermes browses is
read and written on the backend, so Browser needs Bot Mode. Once read it's Ready, with the place
new chats use as the detail ("A browser on Studio Mac", "With your logins on Studio Mac", "In the
cloud · Browserbase"); the row opens the Browser page (Open Apps & Tools on the Mac). Docs:
`user-guide/features/browser`.

With **In this app** (`browser.extension_control.enabled`, [web.md](web.md) §6) it's Ready ("In
this app") until a chat's registration is refused, then Partly set up, with the fallback "Meanwhile
Hermes browses with its own browser on Studio Mac." and what would fix it
(`GatewaySetup.inAppBrowser`): **needs a newer Hermes Agent** (`hermes update`); **needs a sign-in**
(Bot Mode with Automatic sign-in: Hermes lets only a signed-in client drive its browser, so the
steps add the dashboard's username and password to `~/.hermes/.env` there and sign in with them in
Edit Gateway); **needs the gateway's key** (`API_SERVER_KEY`); **the key was refused** (check it in
Edit Gateway); **turned off** on the gateway though the page says In this app (choose it again);
anything else in Hermes's words. A refusal for a chat Hermes doesn't know yet stays Ready: the next
turn registers again.

## 5. Mocks and launch flags

`Tools/mock-hermes/setup.py` serves each "not set up" state: start the backend with `--setup
<state>[,<state>…]`, or change them while it runs with `POST /api/mock/setup {"states": [...]}`
(`["ready"]` clears them).

| State | What the mock answers |
|---|---|
| `board-off` | `kanban` in `plugins.disabled`; the Board's routes answer 404 "Plugin not found" |
| `board-missing` | The Board's routes answer 404 "Not Found" (an older Hermes) |
| `tidying-off`, `tidying-paused` | `curator.enabled: false`; or paused. Tidy Up Now refuses while off |
| `turn-isolation` | `dashboard.turn_isolation: true` |
| `no-driver` | `groups.capabilities.driver: false` |
| `gateway-stopped` | `/api/status.gateway_running: false` |
| `update` | `GET /api/hermes/update/check` says 12 commits behind; Update Hermes… (or /update) runs about 9 s, its log growing like the real one (an earlier run first, colour codes, a `\r` progress line, indented details; a 2 s "restart" answers 502), and moves the version to 0.22.0 |
| `update-fails`, `update-owes`, `update-refused`, `update-slow` | the update exits 1 on a merge conflict; a partial run owes a plugin reinstall; Hermes runs from the desktop app bundle and refuses; the same run over 36 s (screenshots under load) |
| (always, `app_plugins.py`) | /restart runs about 5 s of `hermes gateway restart` lines, then exit 0; `POST /api/mock/restart {"fails": true}` makes the next ones exit 1 |
| `throttled`, `throttled-here` | `/app-push host` reports the gateway and dashboard as background jobs, on another Mac; or on this Mac (its machine id), with plists in `build/mock-launch-agents` that Run at Full Priority edits under `-HERMES_LAUNCH_AGENTS_DIR` |
| `priority-here` | the same Mac at full priority. On any darwin host (all but `host-linux`), a good update (6 s in) or restart (when it's done) takes `ProcessType` out of the gateway's plist, as Hermes does; the report keeps the gateway loaded interactive for 20 s more (the deferred reload), then from the plist |
| `host-linux`, `push-old` | the gateway runs on Linux; the push plugin is older than `host` |
| (processes mock) | "trailhead" in a chat starts a delivery to Ada; `POST /api/mock/processes/deliveries {persist}` makes later ones protected or not (default not, like Hermes 0.22), for §4.18 |
| `docker` | `terminal.backend: docker` |
| `memory-provider` | Honcho active and `needs_config` |
| `search-index` | `/api/status.fts_rebuild` while the index rebuilds |
| `delivery-failed`, `missed-run` | The morning briefing's results didn't arrive, or its last run didn't start |
| `apps-off`, `apps-not-included` | `tools.connectors.enabled: false`; or signed in to Nous without apps in the plan |

Fixes write through `PUT /api/config`, which the mock deep-merges like Hermes, so Turn On and Turn
Off change what the next check reads. Other states have flags of their own: `--checkpoints off`,
`--no-model`, `--app-plugins missing|partial|old`, `--push-relay none`, `--no-widgets`,
`--password <pw>` (a backend that needs a sign-in); leave out `-HERMES_BOOTSTRAP_BACKEND` for a
gateway without Bot Mode. Voice has its own switches (`Tools/mock-hermes/audio.py`): `PUT
/api/config` sets a profile's `tts.provider`, `POST /api/mock/audio {"realtime": false}` takes
Realtime away and `{"env_refusal": "…"}` makes `PUT /api/env` refuse with that reason.

`-HERMES_SETTINGS_SETUP YES` opens Settings → Setup (with `-HERMES_OPEN settings` on iPhone and
iPad; the Mac opens its Settings window on the Setup tab), and `-HERMES_SETTINGS_SETUP <id>`
opens one feature's page there (`checkpoints`, `board`, `learned`, `groupChats`, `models`,
`botMode`…).

## 6. Checks

- Every state in §5 shows on Setup with the right label, line and fix, on iPhone, iPad and Mac,
  in light, dark and Increase Contrast; VoiceOver reads a row as its name, line and state.
- Each fix (Turn On for checkpoints, the Board and tidying, Turn Off Turn Isolation) changes the
  mock's config and the row turns Ready after its check, without leaving the page.
- A gateway without Bot Mode: Bot Mode, and every feature that needs it, say Link Bot Mode…, which
  opens Edit Gateway.
- Copy buttons copy the command; Learn More opens the docs page.
- A slow or missing answer leaves only its own rows on Checking… or Can't check.

## 7. A new feature

1. If it needs anything configured, list its states here (§4) with the Hermes calls that tell
   them apart, read from the Hermes Agent source.
2. Give it a check that returns a `SetupStatus` (in `GatewaySetup` when it reads the gateway,
   with tests), and a row on Settings → Setup (`SetupCenter`, `SetupOverviewView`).
3. Where Hermes accepts the change, make the fix in the app; otherwise give the steps with the
   real command and the docs page. Say what still works.
4. Show the state where the feature is used: a `SetupSection` or `SetupCard` on its page, a
   `SetupMessage` for an empty panel, a `SetupNote` where it falls back.
5. Mock every new call and each "not set up" state (`setup.py` or the feature's own mock), and add
   a Setup section to the feature's doc pointing here.
6. On a Hermes older than the feature, its calls fail with `HermesVersionGap`'s words (§4.2) on
   their own; an empty state of its own checks `HermesVersionGap.isMissing(error)` instead of
   showing a bare error.
