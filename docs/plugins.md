# The app's Hermes plugins

Hermes Agent can't do everything the app needs on its own. It can't reach Apple's push service, for
one. So the app ships its own Hermes Agent plugins. They live in this repository under `Tools/`,
run inside the person's own Hermes, and are published to public repositories that
`hermes plugins install` can fetch.

| Plugin | What it adds | Source | State |
|---|---|---|---|
| `hermes-app-push` | Push notifications on iPhone and iPad, answers from the Lock Screen, Live Activity updates, scheduled tasks delivered to the app | [`Tools/hermes-app-push`](../Tools/hermes-app-push/README.md), published to [vburojevic/hermes-app-push](https://github.com/vburojevic/hermes-app-push) | Shipped, 1.4.5 |
| `hermes-app-widgets` | Widgets agents send to the app: approvals, forms, checklists, results, with plain text on every other platform | [`Tools/hermes-app-widgets`](../Tools/hermes-app-widgets/README.md), published to [vburojevic/hermes-app-widgets](https://github.com/vburojevic/hermes-app-widgets) | Shipped, 1.2.2 |

Everything else the app does runs on a stock Hermes Agent: the API server for chats, and
`hermes serve` for Bot Mode ([architecture.md](architecture.md)). Hermes's own bundled plugins
aren't covered here. The Board, for one, uses the bundled kanban plugin ([board.md](board.md)).

## 1. What works without them

Without `hermes-app-push`, everything in the app works while it's open. These are what's missing:

- **Notifications on iPhone and iPad.** Approvals, questions, password prompts, finished replies,
  Bot messages, scheduled tasks, Board cards and skill tidies all need the plugin to reach a phone
  that isn't showing the app ([notifications.md](notifications.md) §2). So do answering from the
  Lock Screen, notifications going away when answered elsewhere, and the badge's count of open
  requests.
- **Live Activity updates while the phone is locked.** The app still starts the activity and
  updates it while it runs, but the step, needs-you and done updates after that come from the plugin
  (§4 there).
- **Scheduled tasks delivered to the app.** A task whose `deliver` is `apppush` has nowhere to go
  ([tasks.md](tasks.md)).

The Mac needs no plugin: while its app runs, it posts its own notifications from its own
connections (`MacNotifier`, [notifications.md](notifications.md) §1.6). It only checks that the
plugin is there, to show its state in Settings.

The app installs them itself once the person says yes (§2.1). What it shows meanwhile: Settings →
Notifications lists each gateway, and one without the plugin reads
"Needs the Hermes app plugin to send notifications." with **Set Up…**. That opens Set Up Push
(`pushSetup`). A gateway without Bot Mode reads "Needs Bot Mode, so Hermes can reach the plugin.",
because the app talks to the plugin over the backend socket ([notifications.md](notifications.md)
§5).

Without `hermes-app-widgets`, agents can't send widgets. They answer in plain text, as
they do today.

## 2. Installing

A plugin runs only in the Hermes homes it's installed and enabled in. Hermes keeps one plugin
manager per home, and each Bot is a profile with its own home (`~/.hermes/profiles/<bot>`), its
own `plugins/` folder and its own `plugins.enabled` list. Hooks reach only the plugins of the
profile a turn runs in. A plugin installed only in the root never hears about a Bot's turns, its
routines or its Bot Chat. So the plugins go in the root **and every profile**.

Each plugin keeps its data in the Hermes root, whichever profile a hook runs in:
`~/.hermes/plugin-data/<plugin>/`.

### 2.1 From the app

The app installs its plugins itself, over Bot Mode (`AppPluginsModel`, `AppPlugin` in HermesKit).
The design is the Elyx project's `docs/plugins.md`; its frames are named below.

- **The registry.** Each of the app's plugins is one `AppPlugin` entry
  (`Packages/HermesKit/Sources/HermesKit/Plugins/AppPluginRegistry.swift`): its repository and
  pinned `ref` (a full SHA), the version there and the minimum the app needs, the capability list
  of every published version (`provides_hooks`, tools, commands, delivery platforms, network hosts,
  skills, prompt sections, from each version's `plugin.yaml` and `register()`), the moments it may
  be offered (the ask, Turn On Notifications, What's New, the checklist), and its words: feature
  title, one sentence, SF Symbol, "What you get", "What it can do" in plain words with the
  manifest's names, and the promise the review quotes. A test checks the pinned version's hooks and
  tools against `Tools/<plugin>/plugin.yaml` and that every hook is named on the review. A new app
  plugin is one entry and a What's New row.
- **When it looks.** When Bot Mode connects (at most hourly) it reads every profile's plugins
  (`plugins.manage {action: list, profile}` for each profile in `profiles.list`, the root as
  `default`). A plugin is missing, older than the app's minimum version, turned off, or current.
  A profile it can't read is reported, never installed into.
- **The one ask (`pluginsAsk`, `macPluginsAsk`).** The first time it finds an app plugin missing
  or older on a gateway, after setup, it asks once: "Set Up Studio Mac for This App". Never during
  the welcome tour or setup, never over What's New, another sheet or a call. Every app plugin
  missing or older there is listed with a switch (on), and tapping one opens its review
  (`pluginReview`). "Installs into Hermes and 4 Bots", "Kept current by this app". **Install on
  <gateway>** installs the ones switched on, the root first, a profile at a time ("Installing in
  Scout… (4 of 5)"); the sheet can close and it keeps going. **Not Now**, or closing the sheet, is
  the answer for that gateway on this device: it isn't asked again, and the plugins stay offered.
  Afterwards (`pluginsAskDone`) the sheet says where each is on, or what failed in plain words with
  Hermes's message in mono, Try Again and the commands for Terminal. A gateway that already has
  every plugin settles the ask without showing it.
- **The review (`pluginReview`, `pluginReviewPush`).** One page per plugin: hero, What you get,
  What it can do on <gateway> (one line per thing it can reach, an orange shield where it can change
  or block something, the manifest's names in mono), the promise ("From Caffeinated Code"), the
  source (made by, repository, version pinned to the commit, installs into, kept current), then
  **Install on <gateway>** in a floating bar. Install there is the consent for that plugin.
  Afterwards (`pluginInstalled`): "Ready now" (hooks and commands Hermes reports in
  `activation.activated_now`) and "From your next chat" (`deferred` tools and prompt sections),
  then Try It in a New Chat, or Restart Gateway / Later for push.
- **The install** is `plugins.manage {action: install, repo, ref, enable: true, profile}`, pinned
  to the commit the app was tested with (`ref`, a full SHA), with `force: true` to replace an older
  copy (Hermes's `update` only moves catalog installs). An older copy that's turned off is replaced
  with `enable: false`, so it stays off. Hooks and the `/app-push` command work at once; the app
  checks push again straight after.
- **The restart.** When push went into the root, the sheet offers **Restart Gateway**
  (`POST /api/gateway/restart`, the backend's `hermes gateway restart`; running replies finish
  first), because the scheduled-task delivery and the Board and tidy watcher start with the
  gateway. **Later** leaves "Restart the gateway to finish" in Settings. The app remembers that per
  gateway with the gateway's process id at the time (`GET /health/detailed` → `pid`) and drops it
  when a later check sees a new process, however the gateway restarted. On a Mac the restart writes
  the gateway's plist without full priority, so the app reads it again afterwards and puts it back
  as Settings → Setup's restart does ([setup.md](setup.md) §4.17).
- **Keeping current** (`AppPluginsSurvey.plan`). The app remembers, per gateway on this device, the
  version of each plugin the person said yes to (the ask, a review's Install, the consent card).
  Each time it looks, and right after it makes a Bot (`createBot`: a Bot made from scratch has none
  of the root's plugins), it reinstalls the pinned `ref` where a copy is missing or older than its
  minimum, for the plugins the person said yes to or that are on somewhere on the gateway. It never
  restarts the gateway on its own. A copy newer than the app's minimum is left alone, so two
  devices on different app versions don't take turns reinstalling. A plugin turned off everywhere
  isn't installed into new Bots.
- **More access asks first** (`pluginUpdate`, `AppPluginsSurvey.held`). Before moving to a pin
  whose capability list adds hooks, tools, middleware, a command, a platform or a network host to
  the newest version on the gateway (or the one the person last allowed), the app waits: Settings
  shows the consent card, "This update asks for more access", one line per addition in plain words,
  and **Allow and Update**. A version the registry doesn't know can't be compared, so it asks too.
  An update with the same access stays silent.
- **Turned off.** The person's own Install or **Turn On** (the ask, Settings, Set Up Push) turns a
  copy that's off back on: `plugins.manage {action: toggle, key, enable: true, profile}`. Push
  needs it on in the root: Hermes knows `/app-push` only while it is, and answers 4018 otherwise.
- **Settings:** Hermes on <gateway> → Apps and Tools → Plugins (the Mac: Settings → Apps & Tools)
  lists each app plugin with the others (§9); its row opens its page across Hermes and the Bots
  (`pluginProfiles`, `PluginProfilesView`): a summary with one fix ("Missing in Scout and Ops" →
  **Install in Scout and Ops**, "Turned off in Research Buddy" → **Turn On**), the consent card when
  an update asks for more access, one row per profile with its face and state ("On · 1.2.0", "Not
  installed", "Older (0.9.0)", "Turned off") and Install, Turn On or Update, what went wrong, the
  version, when it was checked and **Check Again**, **Restart Gateway** while one is due, then
  **Turn Off in Hermes and All Bots** (it stays installed; keeping current leaves it off and out of
  new Bots) and **Remove from <gateway>…** (out of every profile; back in Suggested), both
  confirmed. Removing push stops notifications for every device on that gateway; Stop
  Notifications in Settings → Notifications stops just one.
- **Settings → Setup** ([setup.md](setup.md)) reads the same thing per plugin:
  `AppPluginsModel.status(for:)` gives an `AppPluginStatus` (HermesKit): needs Bot Mode, offline,
  checking, current, missing, outdated or off in which profiles, restart pending (push only), or
  failed with Hermes's words. An update waiting for the person reads "An update asks for more
  access". Widgets missing everywhere opens its review there.
- **Set Up Push** (Settings → Notifications → the gateway → **Set Up…**) has the same **Install on
  Studio Mac** for push alone, and the commands below to run by hand.
- **Failures** (`PluginInstallFailure`, HermesKit) read Hermes's 5026 message and say it plainly:
  "<gateway> couldn't download it from GitHub", the pinned version no longer on GitHub (a build
  older than a repository rewrite: update the app), pulled from the catalog, needs another OS or a newer
  Hermes, needs an app on the gateway, Python packages Hermes didn't install, a clash with Hermes's
  own packages, or the security scan. The message itself shows in mono.

Without Bot Mode the app can't reach the plugins, so it neither asks nor installs.

### 2.2 By hand

```sh
hermes plugins install vburojevic/hermes-app-push --enable      # the root (the primary Bot)
for p in $(ls ~/.hermes/profiles 2>/dev/null); do                 # every other Bot
  hermes -p "$p" plugins install vburojevic/hermes-app-push --enable
done
hermes gateway restart
```

- `install` clones the repository into that home's `plugins/hermes-app-push`. `--enable` adds it
  to that home's `plugins.enabled` in `config.yaml`. The plugin isn't in Hermes's reviewed catalog,
  so Hermes says it's from a custom, unreviewed source.
- With `--enable`, a running gateway and dashboard pick up the plugin's hooks and commands at once.
  Restart the gateway once anyway: the scheduled-task delivery (`apppush`) and the watcher for
  Board cards and tidies start when the gateway connects its platforms.
- `hermes profile list` shows the profiles; `~/.hermes/profiles` holds one folder for each.
- `hermes-app-push` declares no Python dependencies: it uses `httpx` and `cryptography`, which come
  with Hermes. Without a terminal (Hermes running the command for you), add `--yes-deps` for a
  plugin that does declare some, or Hermes installs it but leaves it off.
- A Bot made later with "copy setup from the primary" (`profiles.create` with `clone_from`) gets the
  root's plugins and their settings. A Bot made from scratch has none: install them for it too.
- An install by hand isn't pinned. The app leaves it as long as its version meets the app's
  minimum.

## 3. Updating

**Installed by the app**, a plugin is pinned to the commit the app was tested with, and the app
moves it: an app that needs a newer plugin reinstalls it over the old one (§2.1). `hermes plugins
update` refuses a pinned install ("pinned to <sha>"); by hand, reinstall it with
`hermes plugins install vburojevic/hermes-app-push --enable --force --ref <40-character SHA>`.

**Installed by hand:**

```sh
hermes plugins update hermes-app-push                    # the root
for p in $(ls ~/.hermes/profiles 2>/dev/null); do
  hermes -p "$p" plugins update hermes-app-push          # every Bot
done
```

An update is not a reload. `hermes plugins update` pulls the new files (`git pull --ff-only`) and
stops there, so each process keeps running the code it loaded:

- **The gateway** runs the old code until `hermes gateway restart`.
- **The dashboard** (`hermes serve`, or Hermes Desktop) runs Bot Mode turns, the Bot Chats. It
  keeps the old code until it restarts too, the way it was started.
- **A Bot's own processes** (`hermes -p <bot> …`, which run its routines) load the new code the
  next time they start.

So after an update that changes Bot Mode behaviour, restart the dashboard as well as the gateway.
Check that no Bot is in the middle of a reply first. `hermes plugins check` lists the plugins that
have updates. The app's installs reload hooks and commands themselves (`enable` activates the new
copy in the gateway and the dashboard); the delivery platform and the watcher still need the
gateway restart. The plugin's version (1.0.0) hasn't moved with each published change, so compare
commits to tell copies apart: `git -C ~/.hermes/plugins/hermes-app-push log -1`.

## 4. Turning off and removing

- `hermes plugins disable hermes-app-push` (per home, like install) takes effect from the next
  session. A running gateway keeps the plugin's hooks until it restarts.
- `hermes plugins remove hermes-app-push` deletes the plugin's folder and its settings under
  `plugins.entries`. Its data folder (`~/.hermes/plugin-data/hermes-app-push`: devices, the relay
  secret) is left as it was.
- One device can stop without touching the gateway: **Stop Notifications** on the gateway's page in
  Settings → Notifications, or removing the gateway from the app, unregisters it.

## 5. hermes-app-push

Push notifications for the iPhone, iPad and Mac app. It listens to Hermes's plugin hooks, seals
each notice for every registered device, and sends it through the Caffeinated Code push relay to
APNs. The relay never sees the content. Answers go back over the normal gateway protocol; the
plugin only reports. [notifications.md](notifications.md) is the full design; this section is the
plugin's side of it.

### 5.1 What it uses in Hermes

| Kind | Name | What for |
|---|---|---|
| Hooks | `pre_approval_request`, `post_approval_response` | Approvals: the notice, then its withdrawal |
| | `on_human_input_request`, `on_human_input_resolved` | Questions (`clarify`), password and value prompts |
| | `pre_llm_call`, `post_llm_call`, `on_session_end` | Finished replies (or a widget request, when the reply asks with one) and the Live Activity's start and end |
| | `pre_tool_call` | The Live Activity's step, a `clarify` call's questions, and a `widget` claim or resolve withdrawing its notice |
| | `on_room_member_activity` | Bot messages in group chats |
| | `kanban_task_blocked`, `kanban_task_completed` | Board cards that need you or are done |
| Command | `/app-push <command> <json>` | How the app registers devices, sets preferences, presence and Live Activities, and says which chats were read. Hidden from the app's "/" list |
| Delivery platform | `apppush` (`ctx.register_platform`) | Scheduled tasks: `deliver: apppush`, `failure_deliver: apppush:fail` |
| Watcher | one thread per gateway process | What Hermes has no hook for: cards ready for review or stopped (each board's `task_events`) and skill tidies (each profile's `logs/curator/<run>/run.json`) |
| Hermes code it reads | `tools.approval`, `hermes_state.SessionDB`, `hermes_cli.kanban_db`, `hermes_cli.profiles`, `gateway.hosted_rooms`, `agent.redact`, `cron.execution_identity` | Request ids, chat titles, card facts, profiles' names and homes, room names, the redactor, a task's name |
| Network | the relay, `POST /v1/installations` and `POST /v1/push` | Its only outgoing calls ([notifications.md](notifications.md) §1.4) |

Plugins can't add gateway RPC methods, so the app calls
`command.dispatch {name: "app-push", arg: "<command> <json>"}` on the backend socket and reads one
line of JSON (`AppPushClient`). The commands are `register`, `unregister`, `preferences`,
`presence`, `read`, `activity`, `status`, `test` and `host` ([notifications.md](notifications.md) §1.2). Error
4018 ("not a quick/plugin/bundle/skill command") means the plugin isn't installed or enabled in that
profile. A command that fails answers `{"ok": false, "error": …}` and never raises, because Hermes
would turn an exception into the same 4018.

Hooks only do bookkeeping and queue the push. One background thread talks to the relay, so a slow
relay never holds up a prompt or a turn. A failure is logged and never raised into Hermes.

### 5.2 Files

In `~/.hermes/plugin-data/hermes-app-push/` (the root's, for every profile):

| File | What's in it |
|---|---|
| `state.json` | Devices (APNs token, bundle id, public key, name, app version, preferences; at most 32), open requests, recently settled ones, presence (forgotten after 75 s), the chats each device keeps current while away (forgotten after a day), chats and rooms read (forgotten after six hours) and, per device away from the app, which ones it was sent, cleared and counts unread (forgotten when it's back in the app), Live Activity tokens, the relay installation id, the board and tidy cursors. Owner-only (0600), replaced atomically |
| `relay-secret` | The secret the relay issued this gateway. Owner-only, never logged or sent to the app |
| `.lock` | The write lock shared by every Hermes process (`fcntl`) |

### 5.3 Configuration

All optional, under `plugins.entries.hermes-app-push.settings` in each home's `config.yaml`. A
profile reads its own, so a setting that should hold for every Bot goes in each profile:

| Setting | Default | What it does |
|---|---|---|
| `relay_url` | `https://push.hermesapp.dev` | The relay. Point it at your own to run one ([Relay/README.md](../Relay/README.md)) |
| `gateway_name` | this computer's name | The name notices give the gateway |
| `card_poll_seconds` | 5 | Seconds between looks at the boards while a card runs or the boards just changed (1–300) |
| `card_idle_poll_seconds` | 30 | The longest wait between those looks while the boards are quiet (up to 600) |
| `tidy_poll_seconds` | 30 | Seconds between looks for a finished skill tidy (5–3600) |

What each device gets is its own preferences, set in the app and sent with `register` and
`preferences`, not gateway settings.

### 5.4 Privacy and security

- Each notice is sealed for one device: X25519, HKDF-SHA256 and ChaCha20-Poly1305. The relay and
  Apple see only routing fields and a kind-only alert such as "Hermes needs your OK"
  ([notifications.md](notifications.md) §1.3).
- Command and prompt text goes through Hermes's own redactor, forced on, before it goes into a
  notice. When the redactor can't run, the text is left out, never sent raw. Hooks never hand a
  password, secret or code to plugins, and the plugin never sends one.
- A command Hermes's safety check flagged gets no Allow outside the app: its notice opens the chat.
- The relay keeps only the gateway's installation id, a hash of its secret, the plugin's version
  and push counts (`Relay/convex/schema.ts`). Addresses are hashed for its rate limits. A dead
  APNs token makes the plugin forget that device.
- Nothing is pushed for the chat a device shows.

### 5.5 Compatibility

- Tested against Hermes Agent 0.22.2. It needs the hooks above (`VALID_HOOKS` in
  `hermes_cli/plugins.py`) and `command.dispatch` on the backend socket, so the app needs Bot Mode
  to reach it.
- With `plugins.isolation: host`, Hermes refuses plugin delivery platforms: notifications and the
  app's commands still work, but scheduled tasks can't deliver to the app. The default,
  `in_process`, has everything.
- A multiplexed gateway imports the plugin once per profile it serves. Those copies share one
  watcher, and every profile reads and writes the root's data.
- Preferences the plugin doesn't know are ignored, and `background` is kept only for older apps.

### 5.6 Tests

They load the plugin through Hermes's own plugin manager in a throwaway `HERMES_HOME`, drive the
real approval queue and human-input hooks, and check what a fake relay receives. That includes the
relay never seeing a command, prompt, reply or secret, and every notice's title and category being
on the relay's list (`Relay/convex/validate.ts`).

```sh
HERMES_SOURCE=<hermes-agent> <its venv>/bin/python -m pytest Tools/hermes-app-push/tests --import-mode=importlib
```

`test_relay_e2e.py` also runs the plugin against a local relay and a fake APNs; it's skipped unless
those are running ([Relay/README.md](../Relay/README.md)). The mock gateway plays the plugin for the
app (`Tools/mock-hermes/push.py`), and `--push-relay none` plays a gateway without it
([development.md](development.md)).

## 6. hermes-app-widgets

Widgets agents send to the app: a card the app draws natively (numbers, lists, schedules, statuses,
choices, approvals), with a plain-text version on every other platform. The contract is
`docs/widgets/payload-contract.md` in the design project; the plugin bundles its generated schemas,
examples, catalogue and rules in `spec/`, and the app bundles the same files (a plugin test checks
they match). [Its README](../Tools/hermes-app-widgets/README.md) has the details. Install, update
and remove it like `hermes-app-push` (§2–§4), in the root and every profile:
`hermes plugins install vburojevic/hermes-app-widgets --enable`. No restart is needed: hooks apply
at once, and the tools and prompt section from each chat's next start. The app installs and updates
it like the push plugin (§2.1), pinned in `AppPlugin.widgets` (1.2.0: the everyday cards' fields; since
1.1.1 Bot group chats use its `room` command, and the app marks every chat it knows with one
`session` call).

### 6.1 What it uses in Hermes

| Kind | Name | What for |
|---|---|---|
| Tools | `widget` (`op` `create`, `update`, `resolve`, `claim`, `get`), `widget_examples`, toolset `widgets` | Agents make, change and answer widgets. On both servers' tool lists (`GET /v1/toolsets`, socket `tools.list`) |
| Prompt section | `hermes-app-widgets`, ≤ 4,000 characters | The rules and one line per type, only in the app's sessions. Widgets are the default: Bots use the matching one unprompted |
| Skill | `hermes-app-widgets:widgets` | The full guide (`agent-usage.md`) |
| Hooks | `pre_llm_call` | Once per app chat whose system prompt predates its widgets (a long-lived Bot Chat), the same rule as turn context |
| | `transform_llm_output` | Before a reply is stored: widget fences become `json`; each widget line stays (the app), becomes an inline block (a scheduled task delivering to the app) or becomes the widget's plain text (everyone else) |
| | `pre_gateway_dispatch` | On messaging platforms, a plain answer to the one open widget ("check tomatoes") becomes its action |
| | `subagent_start` | Helpers and sub-agents get no widgets |
| Command | `/app-widgets <command> <json>` | The app marks its chats (`session`) and Bot group chats (`room`), refreshes payloads (`get`) and registers signing keys (`keys.register`); `status` |
| Hermes code it reads | `gateway.session_context`, `cron.execution_identity`, `cron.jobs`, `agent.redact`, `agent.runtime_cwd`, `hermes_cli.profiles`, `tools.budget_config` | The session and sender, a task's delivery target, the redactor, the workspace, a Bot's name, and pinning widget results so they're stored whole |

The app tells its chats apart with `/app-widgets session` before a chat's first prompt, because the
platform can't: Bot Mode chats report `desktop` like Hermes Desktop, and gateway chats `api_server`
like any other client. The app reads payloads from the stored tool rows (REST
`GET /api/sessions/{id}/messages?include_compacted=true`), since the JSON-RPC history drops tool
content and `/v1/runs` sends only a preview.

### 6.2 Files

In `~/.hermes/widgets/` (the root's, for every profile): `<id>.json` (every revision of one widget,
where it was made, its warnings and claims), `index.json` (chats and scheduled tasks → widgets),
`sessions.json` (the chats the app marked), `keys.json` (devices' public signing keys) and `media/`
(only with `store_media`). Owner-only, written under an `fcntl` lock and replaced atomically.

### 6.3 Configuration

Under `plugins.entries.hermes-app-widgets.settings`: `app_platforms` (platforms that are always the
app, for a gateway the app reaches without Bot Mode), `store_media` (off: fetch and store remote
images, waiting for a gateway route to serve them) and `text_answers` (on: plain answers on
messaging platforms).

### 6.4 Privacy and security

- Payloads are checked before anyone sees them: the schemas, the design's rules, and Hermes's
  redaction patterns over every string. A match is refused. `from_file` reads only the session's
  workspace, at most 5 MB, never XML with a DOCTYPE, and file data can't set actions or sensitivity.
- `claim` is the gate before acting on an answer. The first answer wins across every process, and a
  retry never acts twice. It checks the revision and expiry on the gateway clock, and `for` in group
  chats.
- Approvals that cost money, can't be undone, need authentication or move money are approved only
  by a signature from a device's Secure Enclave key, and never by text or a Telegram reply. Their
  plain text says "Open the Hermes app to approve; this can't be approved by text." Until a device
  registers its key, Face ID in the app is the only gate.
- Private widgets are refused in group chats. A reply's widget line for one carries only its title,
  and push notices say "Hermes sent a widget."
- Only the Bot that made a widget can change it, and a `bot:` icon or a handoff's sender must be that
  Bot.

### 6.5 Compatibility

Tested against Hermes Agent 0.22.2. It needs `jsonschema` and `referencing` (Hermes's `[all]`
extra) and `cryptography`. The app's commands need `command.dispatch`, so they need Bot Mode;
without it, `app_platforms` stands in for the chat marks. A gateway without the plugin has no
widgets, and agents answer in Markdown as before.

### 6.6 Tests

```sh
HERMES_SOURCE=<hermes-agent> <its venv>/bin/python -m pytest Tools/hermes-app-widgets/tests --import-mode=importlib
```

They load the plugin through Hermes's plugin manager in a throwaway `HERMES_HOME` and drive Hermes's
own transform caller, prompt sections, `pre_gateway_dispatch`, cron jobs and tool lists. They cover
every parser, every example and invalid payload in the spec, the SSRF guard, the Telegram and CLI
rewrite, fence neutralising, and claims.

## 7. Changing a plugin

- Change the plugin in `Tools/<plugin>/` and commit it here first. Then publish it to its public
  repository: `Scripts/publish-push-plugin.sh "<message>"` for `hermes-app-push`,
  `Scripts/publish-widgets-plugin.sh "<message>"` for `hermes-app-widgets`. The script copies
  the folder over the public repository, so a change made only in the installed copy or the public
  repository is undone by the next publish.
- Hook names and arguments come from the Hermes Agent source (`hermes_cli/plugins.py`
  `VALID_HOOKS`, `ctx.register_*`), never from guessing.
- Hooks must never raise or block a turn: do the bookkeeping, queue the work, log failures.
- Keep the plugin's data in the Hermes root (`get_default_hermes_root()`), never in a profile's
  home. A Bot's own process starts with `HERMES_HOME` set to its profile.
- A new notice kind needs its fallback title and category on the relay's list
  (`Relay/convex/validate.ts`) and in the app's `HermesPush`. The plugin's tests check the relay's
  list.
- A new command, or a change to one, changes `AppPushClient`, the mock (`Tools/mock-hermes/push.py`)
  and [notifications.md](notifications.md) §1.2 in the same change.
- Run the plugin's tests (§5.6) before publishing. They never touch `~/.hermes`.
- A published change the app needs bumps the plugin's version (`plugin.yaml` and `VERSION` in
  `core.py`), then moves `AppPlugin`'s `ref` to the published commit (the publish script prints
  it) and its `minimumVersion` to that version, and adds the new version's capability list to its
  registry entry (`AppPluginRegistry.swift`). Without the bump, installed copies count as current
  and stay as they are. If the new list adds a hook, a tool, a command, a platform or a network
  host, gateways on the older version wait for the person's yes (§2.1), and the review's lines
  must name the new hook (a test checks).
- Once published, installed copies change only when the app reinstalls them (§2.1), or with
  `hermes plugins update` in the root and every profile for copies installed by hand, then a
  restart (§3).

## 8. Setup

Settings → Setup shows what each plugin brings and whether it's there ([setup.md](setup.md) §4.13,
§4.14); installing stays here (§2).

## 9. The hub: Apps and Tools → Plugins

Every plugin, the app's and Hermes's catalog's, is offered, reviewed and installed one way
(`PluginHubModel`; the design's `docs/plugins.md` §3–§5). Nothing installs without the person's
tap on a review or the ask.

- **Suggested** (`pluginsHub`, `PluginOffers.suggested`): the app's plugins first (missing:
  Install; installed but off everywhere: Turn On), then Hermes's curated list (`plugins.manage
  {action: onboarding}`) where `app_state` is `present`, five at most. Left out: what's installed and
  on, what's hidden, and what can't run on the gateway (another OS by the feed's `platforms`, a newer
  Hermes by `requires_hermes`, checked against `GET /api/system/stats`). The footer says why they're
  picked. Settings → Hermes on <gateway> → Apps and Tools reads "… · 2 suggested" in plain text.
- **Updates:** catalog plugins with `update_available` (Update, the consent card on
  `consent_required`), and the app's own plugins whose pin adds access (their consent card).
- **Installed:** on, off, needs keys ("Needs 2 keys · tap to add them": required secret fields
  without a value), a problem (Hermes's `servers[].sentence`), or pulled from the catalog: Hermes's
  rows don't say so, so the app matches `catalog_name` (or the repository) against the feed's
  `removed` list. A pulled plugin's switch can't turn it on (Hermes's `toggle` would answer ok and
  load nothing); its detail says why and when, with Remove.
- **New in the Catalog:** names this device hasn't shown for this gateway. The first visit counts
  every name as seen, so it starts empty; names shown are marked seen when the hub closes. Then
  **Browse All N Plugins…** (`pluginsCatalog`: search, chips for For This App, Official and the
  catalog's categories, shelves; installed entries say so) and **Hidden Suggestions**.
- **Without Bot Mode** (`pluginsNeedsBotMode`): "Plugins need Bot Mode" with Link Bot Mode, and the
  app's plugins dimmed with "Needs Bot Mode". Nothing is asked and nothing installs.
- **iPad landscape:** the hub on the left (Installed, the catalog and Hidden as rows), the selected
  plugin's review on the right. **The Mac:** Suggested heads Settings → Apps & Tools → Plugins
  (`macPluginsSuggested`), the review opens in the pane (`macPluginReview`).

### 9.1 The catalog feed

`https://hermes-agent.nousresearch.com/docs/api/plugin-catalog.json` (`PluginCatalogStore`), the
feed Hermes's own client reads: `entries` (name, title, repo, sha, description with its
`Disclosure —` sentence, tier, category, maintainer, version, `capabilities`, `requires_hermes`,
`platforms`, `known_issues`) and `removed` (the kill list). For display only: installs always go
through the gateway by `catalog_name`, so its pin and kill list apply. The app keeps it six hours
in Caches and uses the copy on disk when the feed can't be read; a deep link to a name the feed
doesn't have falls back to `plugins.catalog.lookup`. Debug builds read
`-HERMES_PLUGIN_CATALOG_URL` instead (the mock serves `Tools/mock-hermes/plugin-catalog.json`), so
tests never reach the network.

### 9.2 A catalog plugin's review and install

- **The review (`pluginReviewCatalog`):** the hero (tier, maintainer, version), What it can do on
  <gateway> (whether its app is there, from `plugins.manage {action: presence, names}`, then its
  hooks in words, middleware, tools and keys; never "sends nothing", since the catalog doesn't list
  network), the catalog's disclosure, known issues, the source (Reviewed: Hermes catalog · scan
  passed, the repository, version and short SHA) and **Installs into**: Hermes by default, any Bot
  with a checkmark. Can't install here: the bar says why and stays off.
- **Install** is `plugins.manage {action: install, catalog_name, enable: true, profile}` in each
  chosen profile, the root first ("Installing in Scout… (2 of 3)"); the page can close and the hub
  row keeps its spinner. Afterwards: Ready now (live MCP tools, skills, hooks switched on) and From
  your next chat (`deferred`), or the keys (`pluginInstalledKeys`): one secure field per
  `missing_env` name, written once with `PUT /api/env` into each profile it went into, then
  `reload.env` (no params: Hermes reloads its own profile). Never shown, logged or kept. Or the
  failure in words with Hermes's message in mono, Try Again and `hermes plugins install <name>`.
- **Answers** (`PluginAnswers`): Not Now (an offer card) answers that moment for that gateway on
  this device, and the card may come back once at its next natural moment after 14 days. Don't
  Suggest Again (a row's or card's … menu) moves it to Hidden Suggestions until Show Again; it
  stays in the catalog. Hidden names are kept per gateway behind `HiddenSuggestionStore`: on this
  device for now, and in iCloud key-value storage (`CloudHiddenSuggestions`) once the app has that
  entitlement and `HermesICloudKeyValueSync` is set. Remove puts a plugin back in Suggested (the
  app's) or the catalog.

## 10. Open points

- **Syncing Hidden Suggestions.** The app has no iCloud entitlement yet, so hidden names stay on
  each device. To sync them: turn on iCloud with key-value storage for the app's App IDs (iOS and
  Mac) in the developer portal, regenerate the App Store profiles and the Mac Developer ID profile
  in the signing escrow, add `com.apple.developer.ubiquity-kvstore-identifier =
  $(TeamIdentifierPrefix)$(CFBundleIdentifier)` to both entitlements, and set
  `HermesICloudKeyValueSync` to `YES` in the Info.plist (`project.yml`). `CloudHiddenSuggestions`
  then keys them by the gateway's hostname, which every device sees the same.
- **Git links** install as they did (`install {repo, ref, enable: true}` from Install from a Git
  Link…). The design's review first (install with `enable: false`, read the manifest, review, then
  `toggle`) needs the manifest's hooks, which `plugins.manage list` doesn't report.
- **"Asks for more access" on a catalog update** shows once `update` has answered
  `consent_required`; Hermes has no call that says so beforehand.
- **The app's own plugins in Hermes's catalog** (the design's §13): until they're submitted, Hermes
  calls them a custom source and the review says so.
