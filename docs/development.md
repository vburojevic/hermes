# Developing Hermes

Everything you need to build the app, run it without a real Hermes Agent, and reach any screen in
any state. For the big picture see [architecture.md](architecture.md); coding agents should also
read [AGENTS.md](../AGENTS.md).

## Requirements

- Xcode 27 (iOS 27 and macOS 27 SDKs). The app deploys to iOS, iPadOS and macOS 26 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`): the Xcode project is
  generated from `project.yml`.
- Python 3.10+ for the mocks (standard library only), Node 20+ for the relay.

## Build

```sh
xcodegen generate
open Hermes.xcodeproj
```

Pick the **Hermes** scheme and an iPhone or iPad simulator, or My Mac. From the command line:

```sh
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-mac build
```

Simulator builds need no signing. To run on your own iPhone or Mac, set `DEVELOPMENT_TEAM` and
`bundleIdPrefix` in `project.yml` to your own team and prefix (and the App Group and Keychain group
settings next to them), then generate again. Push notifications need the APNs entitlement and the
relay, so expect them to stay quiet on a personal team.

### Debug and Release

| | Debug | Release |
|---|---|---|
| App | **Hermes Dev** (amber icon) | **Hermes** |
| Bundle id | `co.caffeinatedcode.hermes.dev` | `co.caffeinatedcode.hermes` |
| Mac data folder | `Application Support/co.caffeinatedcode.hermes.dev` | `Application Support/co.caffeinatedcode.hermes` |
| Keychain, settings | its own | its own |
| Demo bootstrap and `-HERMES_*` launch flags | yes | compiled out |
| Mac updates | off | Sparkle |

Dev builds can point at the mocks freely; they never touch the real app's gateways or keys, and both
run at the same time on one Mac. (`Application Support/Hermes` belongs to Hermes Desktop; the app
never writes there.)

## Test

```sh
cd Packages/HermesKit && swift test
# plus a round trip over a real WebSocket against the mock backend:
HERMES_MOCK_BACKEND=http://127.0.0.1:19119 swift test --filter BackendIntegrationTests
```

The tests (Swift Testing) cover the API client, the SSE parser, transcript folding, live turns,
Markdown and highlighting, the gateway socket's frames, Bot Mode decoding, @mentions, routines,
push crypto and notices, and the link, preview and approval safety rules.

UI tests (`UITests/`, scheme `HermesUITests`, iOS Simulator) drive the app against the mock:
start `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642` (restart it after
pulling), then

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# a mock elsewhere: add HERMES_MOCK_GATEWAY=http://127.0.0.1:28642 HERMES_MOCK_BACKEND=http://127.0.0.1:29119
# Voice tests with a slow audio engine, as on a busy Mac: add HERMES_ENGINE_START_DELAY=12
```

They cover opening at the New Messages line, the jump pill marking a chat read, and Mark as Read /
Unread syncing with another client (`docs/inbox.md` §7). Each test resets the mock's read marks.

A test that stops mid-call must end the call: its Live Activity outlives the app, and installing
the next build makes the system launch the app for it, without launch arguments, just as the next
run's first test launches the app. That test gets the system's launch and no `-HERMES_*` flags.
`VoiceUITests` ends any call left running when each test ends.

The relay has its own tests (`cd Relay && npm ci && npm test`). The app's Hermes plugins' tests run
against a real Hermes Agent checkout, in a throwaway `HERMES_HOME`; see [plugins.md](plugins.md)
§5.6 and [Tools/hermes-app-push](../Tools/hermes-app-push/README.md).

## Run without a real gateway


```bash
python3 Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef
```

Then add `localhost:18642` with that key, or launch a Debug build with
`HERMES_BOOTSTRAP_URL=http://127.0.0.1:18642` and `HERMES_BOOTSTRAP_KEY=…` in the environment.
Messages containing "approve" ask for permission, "slow" runs a long multi-tool turn, and
"fail" fails.

Onboarding (`Tools/mock-hermes/onboarding.py`): `setup.status`, `model.options`,
`model.save_key` and `free_tier.provision`. `--no-model` starts the backend with no model
provider, so setup asks for one. `POST /api/mock/onboarding {provider_configured, jobs:
"clear"|"seed"}` changes that while it runs ("clear" empties Tasks, so setup offers the
morning briefing). Debug flags: `-HERMES_WELCOME_PAGE 0…3|get`, `-HERMES_HAS_CAMERA YES` (the
camera variant on a simulator), `-HERMES_SETUP model|you|ready`, `-HERMES_TIPS reset|show`,
`-HERMES_WHATS_NEW YES`. On the Mac, `-HERMES_LOCAL_GATEWAY`, `-HERMES_LOCAL_BACKEND` and
`-HERMES_LOCAL_HOME` point the welcome window at the mock and a test folder with its own `.env`
and a `gateway.pid` holding the mock's process id (`lsof -t -iTCP:18642 -sTCP:LISTEN > <folder>/gateway.pid`),
since Connect sends the key only to the process Hermes recorded.
Build with another bundle id (`PRODUCT_BUNDLE_IDENTIFIER=co.caffeinatedcode.hermes.welcome`) to
see the Mac welcome with no gateways.

Pasting on a simulator, whose clipboard only takes text from the command line:
`-HERMES_PASTEBOARD image:<path>|link:<path>|file:<path>` puts that file on the clipboard (`link:`
adds the picture's address as text, as Safari's Copy Image does; `file:` copies it as the Files
app does), and ⌘V in the composer (`axe key-combo --modifiers 227 --key 25`) pastes it.

For Bot Mode, also run the mock backend (four Bots with Bot Chats, routines, a photo avatar,
an active worker and a routine that posts every couple of minutes):

```bash
python3 Tools/mock-hermes/backend.py --port 19119            # ungated: Automatic sign-in
python3 Tools/mock-hermes/backend.py --port 19119 --password pw   # gated: admin / pw
```

and turn on **Bot Mode** for the gateway with `127.0.0.1:19119`, or add
`HERMES_BOOTSTRAP_BACKEND=http://127.0.0.1:19119` to the Debug launch environment. "approve",
"slow" and "fail" work in Bot Chats too ("marathon" is "slow" for about 45 s, "essay" streams a long
Markdown reply for about ten seconds, "widgets" is a coding turn of about 25 s: two files, a failing
check, a third file and a passing one, with `inline_diff`s as Hermes renders them, and a steer sent
during the check is read after it, "late reply" ends its turn saying nothing and stores the reply 12 s
later, "page risks" reads three pages with what Hermes's scanner reports for each: a zero-width space
only, a right-to-left override, instructions; "page risks with a digest" also delivers Research
Buddy's Daily digest while the second page is read), and `@mentioning`
another Bot drops a message in its chat. `--drop-after-reply` cuts every socket right after a turn's
`message.complete`, `--agent-build <s>` says the session is idle on `prompt.submit` and takes the
prompt that long later (Hermes building a chat's agent on a loaded Mac), and `--late-settle <s>` says
the session is idle that long after it (the turn's
end handing over: `-HERMES_SEND "write swift widgets" -HERMES_SEND_AFTER 6 -HERMES_FOLLOWUP <text>
-HERMES_FOLLOWUP_MODE steer -HERMES_FOLLOWUP_SEND YES -HERMES_FOLLOWUP_AFTER 12` in `bot:default`, and
`-HERMES_LOAD_LOG YES` says "held for a later load" when it didn't). Connection trouble on demand: `POST
/api/mock/drop-sockets {settle, outage}` cuts every socket (the next `settle` resumes of a running
chat answer 4009, new sockets are cut for `outage` seconds), `POST /api/mock/freeze-sockets`
leaves them half-open, `POST /api/mock/stall {seconds}` freezes the backend the way Hermes's
dashboard freezes on a loaded Mac (requests, frames and pings wait, then all answer; the gateway
mock keeps answering), `POST /api/mock/starve {seconds, gap, slice, health}` starves the whole
Mac instead, both mocks at once (`Tools/mock-hermes/starve.py`, also on the gateway mock's port;
`--starve MIN-MAX` on either from launch): connections are taken but nothing is answered, health
checks included (`health: "prompt"` keeps those quick), until the process gets a `slice` (0.6 s)
of CPU every `gap` seconds (5–30 by default), when everything waiting goes out at once. It is what
Hermes did at load 500 on 2026-10-19, and how the app tells busy from offline
([connecting-and-voice.md](connecting-and-voice.md) §8); `{"seconds": 0}` ends it. `POST
/api/mock/lose-answer {method, taken}` loses the next answer to
`method` (default `prompt.submit`) with the request run (`taken: true`) or not, and `POST
/api/mock/fail-reads {count}` refuses the next `count` read marks with 503 on both servers, as a busy
gateway does, for the read outbox (`docs/inbox.md` §4), and `POST
/api/mock/message-agent {from, to, text}` delivers another Bot's message off the socket (profile
names: `researcher`, `writer` is Ada, `ops`), as Hermes's one-shot `hermes -p <bot> chat` does:
the message is stored, then 12 s with no rows and no `session.active_list` entry, then the
reply ("long": a command step for 25 s first; "dies": no reply ever, as when Hermes stops a
delivery with the sender's chat). That process holds the Bot Chat until it replies, so a send is
refused with Hermes's own sentence ([chat.md](chat.md), a chat another Hermes process holds).
`POST /api/mock/routine-elsewhere {profile, title, output, reply, seconds}` is a routine's
follow-up the same way (its output stored with no display kind, held `seconds`, default 20).
`POST /api/mock/hold {profile, seconds, surface, age, late}` holds a Bot Chat with nothing stored:
`age` minutes ago (45 reads as a terminal, 0 as a one-shot booting), `surface` `cli` or
`desktop`; `late: true` takes the next send, stores it and refuses the turn as it runs instead (the
`error` event shape). `POST /api/mock/held-notice {profile}` is a turn Hermes starts itself there
refused the same way (`message.start`, then `error`), as the notice of a finished process was on
2026-10-21. `-HERMES_PUSH_OPEN botreply:<profile>` opens a
reply's notification for that Bot 20 s after launch, as a tap would. `-HERMES_FACE_CANVAS YES`
draws every Bot face instead of playing resting faces on layers ([bot-faces.md](bot-faces.md) §3),
to compare the two. Live indicators ([chat.md](chat.md) §4a): "ponder" thinks for about 14 s before
a word (the live line's "Thinking… · 12s"); in the group chat (`-HERMES_OPEN group:launch-crew
-HERMES_GROUP_SEND "… together"`) "together" has Research Buddy, Ada and Ops think at once.
`-HERMES_MOTION_PROBE YES` puts the number of shimmers sweeping on screen in a near-invisible
`motionProbe` element for the UI tests, `-HERMES_GALLERY indicators` shows every indicator (with
`-HERMES_GALLERY_LOOK …+reducemotion` for Reduce Motion), and `-HERMES_SHIMMER_TIMELINE YES` draws
the shimmer from a `TimelineView` instead of its layer, to measure the two. `--slow-status SECONDS` answers `/api/status` that late, and past 30 s with a 502 at 30 s, like a
proxy in front of a dashboard on an overloaded Mac: the Bots still connect. `--turn-isolation
SECONDS` stores a turn's message that long after the turn starts, as Hermes does with
`dashboard.turn_isolation`: only the live session (`inflight`) has it meanwhile, so a second
device on the same chat shows whether it reads it from there ([chat.md](chat.md) §2).
`--slow-history SECONDS` answers stored chats' messages that late while the socket keeps up, as
a dashboard on an overloaded Mac does: a message sent meanwhile goes out before the history comes
([connecting-and-voice.md](connecting-and-voice.md) §8).
`POST /api/mock/read {chats, rooms, device_id?}` plays chats read on another device (the plugin's
`read`: read pushes to devices away from the app, badge pushes, the `read` list in later notices),
`POST /api/mock/badge {badge}` sends every device a badge-only push now, and
`GET /api/mock/push-state` shows what the push mock recorded (presence, reads, what each device was
sent and cleared, badge records). `POST /api/mock/sync {sessions}` sends every registered device a `sync` push now, and
`-HERMES_REFRESH_AFTER <s>` runs the app's background refresh that long after launch: both read
the chats kept current without waiting for iOS ([notifications.md](notifications.md) §2). A
simulator turns `simctl push` into a plain background fetch that never reaches
`didReceiveRemoteNotification`, so the push handler itself only runs on a device.

Measuring how chats open (iOS Debug, built with `SWIFT_OPTIMIZATION_LEVEL=-O` so the numbers mean
something): `-HERMES_FRAME_LOG YES` logs every frame that kept the main thread busy, with its CPU
time, `-HERMES_LOAD_LOG YES` times each step of loading a chat, and `-HERMES_OPEN_CYCLE
bot:ops,chat:<id>` opens those chats in turn (3 rounds, `-HERMES_OPEN_CYCLE_ROUNDS`), marking the
frame log as each opens and 4 s later: the main thread's work per open, without taps or the
accessibility queries a tapping tool sends. `--seed-bot-chat` with an export of long code replies
and tables makes Ops a heavy chat to open. `-HERMES_INLINE_SELECTION YES` makes iPhone and iPad
replies selectable in place again, as they were, to measure what that costs.

Measuring a cold launch (same build): `-HERMES_LAUNCH_LOG YES` prints each launch step once with
its time since the process started (`LaunchTrace`: the model, the first view, the kept chats, Bots
and last lines, the gateway's answer, the socket, the fresh lists, each row's last line), and the
chat load steps above with it. `-HERMES_RESTORE bot:ops` (or `session:<key>`) opens as if the
window had been showing that chat. A Mac window behind other windows isn't drawn, so its chat
doesn't load until it's in front; measure the open chat on the simulator. Kill the app between
launches, and launch twice: the first after a build pays for loading the new binary.

The frame log's times count from the process's start, with marks for the root view, the first
frame and the open chat showing (`chat showing`), and each mark carries the main thread's CPU so
far: a cold launch reads straight off it. `-HERMES_SCROLL_RUN <rounds>` scrolls the open chat from
its end to its top and back, `-HERMES_SCROLL_SPEED` points a second (2000 by default), starting
`-HERMES_SCROLL_AFTER` seconds after launch (10), only up with `-HERMES_SCROLL_LEGS up` (to send,
jump to the end or let a turn end from far back): a step a frame, taken by the chat as a drag, so
pages come in at the top and go below as they would under a finger. Each leg is marked
(`SCROLLRUN`, and in the frame log on iOS). It works on the Mac too. With `-HERMES_SCROLL_LOG YES`
the window's changes show between the per-frame offsets (`SCROLLLOG drop below`, `later in`,
`drop above`, `back above`, `earlier page`) with each step the run set (`SCROLLRUN set`): across
every change but a new earlier page the offset must stay where the run put it.
`-HERMES_SCROLL_THEN_JUMP <s>` (with `-HERMES_SCROLL_LEGS up`) jumps to the end that long after
the run, as ⌘↓ would, and `-HERMES_SEARCH_OPEN YES` (with `-HERMES_SEARCH`) opens the first result:
both reach on the Mac what a tap or a key would, without taking over the screen.

Measuring a streaming reply: "essay" streams a long Markdown reply for about ten seconds, and
`-HERMES_SEND_HERE "essay please" -HERMES_SEND_HERE_AFTER 10` sends it into the chat that opened,
marking the frame log as it goes. A streamed word should redraw only its reply's row
([chat.md](chat.md) §4): to see what else does, and why, put `let _ = Self._printChanges()` at the
top of the views' bodies in a scratch copy and count the lines while it streams (Instruments'
SwiftUI template doesn't record on a simulator). The environment tells values apart by their
contents, not by `==`: hand rows the same value when nothing changed (`stableReferences`).

Background processes (`Tools/mock-hermes/processes.py`, [background-processes.md](background-processes.md)),
in Bot Chats and normal chats: "release" with "docs" (or "processes") starts a Docs site that runs
on and a Release build that exits 0 after ~35 s with no event, and closes the Docs site's tab
mid-build (`terminal.close`); "trailhead" or "deploy log" sends a message to Ada that fails with a
JSON error and tails the deploy log. Output carries ANSI codes, `\r` progress and Hermes's CWD
marker. `POST /api/mock/processes/exit {process, code, reason}` ends one (by id or a word of its
command) with no event, `…/close {process}` sends `terminal.close`, `…/reset` forgets them, and
`…/deliveries {persist}` lists later `message_agent` deliveries with `persist_on_release` (Hermes
with upstream #136220) or without (Hermes 0.22, the default), for Settings → Setup's Bot-to-Bot row.
`-HERMES_SEND_HERE <text> -HERMES_SEND_HERE_ROUNDS 1` sends it once into the open chat.
In a Bot Chat, "links" answers with addresses written out every way agents write them (bare on a
line, in a sentence, `www.`, a Markdown link, `localhost`, one in code) to check that they open.
"clarify pair" (a Bot Chat or a Hermes chat) asks two questions in one card, the first with a long
pick; `-HERMES_CLARIFY_STEP 2` opens such a card at its second question with the first answered
by its first pick, so its one-line summary shows without a click (the Mac).

Widgets (`Tools/mock-hermes/widgets.py`, [widgets.md](widgets.md) §13) play the
hermes-app-widgets plugin over both servers: "widgets" pages through every example (three per
reply, "widgets 2"…), "widget <type>" shows one type's examples, "widget publish" an approval
without Face ID, "widget lunch" one with it, "widget expiring" one that expires in 60 s, "widget
silent" one whose first answer gets no update (Try Again), "widget private", "widget fence" (an
agent-typed block, shown as code), "widget unknown", "widget invalid" and "widget suggestions".
In a Bot group chat the app marked, the same words make Ops answer with an inline block. `POST
/api/mock/widget-answer {id?, action, device?, hold?}` answers the newest widget from another
device; `--no-widgets` leaves the plugin out. On a simulator, enrol Face ID with `xcrun simctl
spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` (then `-p` the same name)
and pass a check with `notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.

UI tests (`HermesUITests`, `UITests/`) run against the mock: start it first, then
`xcodebuild test -scheme HermesUITests -destination 'platform=iOS Simulator,name=…'`
(other ports: `HERMES_MOCK_GATEWAY=… HERMES_MOCK_BACKEND=…`).

With `--gateway-port 18642` the backend also has projects (`Tools/mock-hermes/projects.py`): the
design's Hermes App, Homelab, Blog, Hermes Agent fork and dotfiles, an archived Portfolio written
by the desktop app, and the found repos caffeinated-site and pantry. "Fix the reconnect after
sleep" runs a long test turn so Hermes App shows as working. Debug flags: `-HERMES_OPEN projects`,
`-HERMES_OPEN project:p_4f2a9c1e` (`-HERMES_PROJECT_LANE <lane id>`, `-HERMES_PROJECT_EXPAND <id>`),
`-HERMES_OPEN project-chat:<id>`, `-HERMES_PROJECT_SHEET new|edit:<id>|move:<session>|runin` and
`-HERMES_DRAWER YES`.

Unread and live activity (`Tools/mock-hermes/inbox.py`, `docs/inbox.md`): the gateway's chats keep
Hermes' read mark (`last_read_at`); seeded, Release prep has 3 replies since it was read, Morning
briefing 1, and Stand-up summary is marked unread. The dashboard's `GET /api/sessions` carries
`unread`, `last_read_at` and `last_active` (the API server's rows don't, as in Hermes), and
`session.active_list` says starting, working, waiting or idle with Hermes' preview. `--inbox-demo`
makes Swift 6 migration plan look like it keeps writing (a 40 s cycle) and Disk cleanup on the NAS
wait on an approval, for screenshots. Read marks change by `PATCH /api/sessions/{id} {unread}` on
either server; `GET /api/sessions/{id}?profile=default` on the backend shows one. A chat a launch
opened with `-HERMES_OPEN_SESSION` opens at its New Messages line when it has news.

It also has helpers (`Tools/mock-hermes/helpers.py`), shaped like Hermes' background delegation. A
message with "helpers" (or "swift 6") runs a team of four: one auditing for over a minute, one done
in seconds, one timing out, one waiting for a free slot; "nested helpers" runs a lead with three
sub-helpers; add "slowly" for screenshots. A steer containing "late" lands after the helper's last
step (missed) and one containing "reject" is rejected. "Swift 6 readiness check" has a saved past
run. Debug flags, after `-HERMES_SEND`: `-HERMES_HELPERS team|helper:<n>|steer:<n>|stop:<n>`,
`-HERMES_HELPERS_AFTER <seconds>` and `-HERMES_HELPERS_NOTE <text>` (sends the steer).

And Apps and Tools (`Tools/mock-hermes/connections.py`): GitHub with two accounts and 38 tools
(one blocked by the organization), Gmail, Linear signed out, Slack; Notion, Google Calendar and
Figma to connect (the sign-in page returns to the app after a few seconds); MCP servers
filesystem, github (from a plugin), sentry failing with a 401 until its key changes, and postgres
starting when needed; presets Brave Search, PostgreSQL and Playwright; plugins Xcode, Blender (app
not running) and homeassistant with an update that asks for shell access; eight built-in toolsets
with image generation off. `mock.nous {"signed_in": false}` shows the Nous sign-in state and
`mock.connections.reset` puts everything back. Debug flags, after `-HERMES_OPEN settings`:
`-HERMES_APPS_TOOLS apps|mcp|plugins|builtin`, with `:<app slug>`, `:<server>`, `:<plugin key>`,
`mcp:add` or `plugins:update` (on the Mac the flag alone opens the Apps & Tools tab).

And checkpoints (`Tools/mock-hermes/checkpoints.py`), shaped like `hermes serve`: the chat "Reconnect
and backoff" in Hermes App has three turns that edited files and four checkpoints (14:31, 13:02,
yesterday 18:40 twice); a restore overwrites the files (files created later stay), drops the newest
turn and reports Models/weights.bin as too large to checkpoint; a whole restore mid-turn is refused
with 4009. New turns in a project folder save a checkpoint before their first edit. `--checkpoints
off` starts with them off (Turn On writes `PUT /api/config`; open chats keep the old setting until
reattached); `mock.checkpoints {"enabled", "now", "busy", "container"}` switches states and
`mock.checkpoints.reset` puts everything back. Debug flags: `-HERMES_OPEN chat:prj_undo` with
`-HERMES_CHECKPOINTS review|undo|timeline|detail[:n]|restore-all[:n]|off`.

And memory (`Tools/mock-hermes/memory.py`), shaped like the gateway's `/api/learning/*`,
`/api/memory*` and `/memory` command: six things about you, fourteen notes (94% full) and two saves
waiting for review; Research Buddy has its own. Edits over a store's cap and stale ids are refused
with the gateway's words. In a chat, "remember …" or "vegetarian" saves (asking "Save to memory?"
first while Ask Before Saving is on), "in a task" stages the save for review, "forget …" removes,
"beta 3" updates and "three things" saves a batch. `POST /api/mock/memory/reset` puts it all back.
Debug flags, with `-HERMES_OPEN settings`: `-HERMES_MEMORY about|notes|options|edit:<n>|reset|bot:<profile>`
(on the Mac it opens Settings → Memory).

And Passwords (`Tools/mock-hermes/vault.py`, [web.md](web.md) §10), shaped like Hermes's `vault.*`
methods: Hermes's vault (Vercel, Example Cloud with an authenticator key, the Personal Visa test
card, Home), 1Password locked (GitHub, Linear, Amazon) and Bitwarden not installed. A master
password with "wrong" in it fails, one with "slow" times out after 20 s, any other unlocks. `POST
/api/mock/vault` shortens the idle lock (`{"idle": 60}`), sets a manager's state (`{"bitwarden":
"unlocked"}`), plays an older Hermes (`{"older": true}`) or resets (`{"reset": true}`). Debug flags,
with `-HERMES_OPEN settings` on iPhone and iPad: `-HERMES_PASSWORDS YES|add:login|add:payment|add:address|unlock:<source>|item:<id>`
(on the Mac it opens Settings → Passwords).

And where Hermes browses (`Tools/mock-hermes/browser.py`, [web.md](web.md) §10): `browser.manage`
(a window attaches after about 2 s), the browser and blocked-sites config, and Browserbase's keys
making it the cloud provider. `POST /api/mock/browser {"connect": "fails"|"unreachable"}` breaks
the window. `-HERMES_BROWSER YES|consent` opens the Browser page (on the Mac, Apps & Tools on
Browser).

In a chat (`Tools/mock-hermes/web_turns.py`, over Bot Mode's socket): "sign in to vercel" (Hermes's
vault and its authenticator key, no prompts), "sign in to github" (1Password locked: the unlock card,
then a code card), "sign in to linear" (nothing saved: the save-login card), "reorder" (a card fill:
Fill Card with Face ID) and "wrong site" (refused on gist.github.com). On a simulator, enroll Face ID
with `xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` then `-p` the
same name, and pass a prompt with `notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.

**The secrets search** ([web.md](web.md) §8), after a full sign-in, a 2FA code, an Add Card, a card
fill and a checkout in the app's browser against the mock: put every value you typed (master
password, passwords, card number, the code; a short security code as `"cvc":"737"`) in a file
outside the repo (`chmod 600`), one per line, and run `Scripts/dev/web-secret-search.sh --secrets
<file> --udid <simulator> --mac --mock-log <mock output> --since 1h` (`--bundle <id>` for another
simulator build, `--mac-bundle <id>` and `--mac-home <dir>` for a Mac build with its own bundle id or
run under `CFFIXED_USER_HOME`). The values are read from the file only, never put on a command line,
and looked for as typed, JSON-escaped, percent-encoded, as bare digits and in UTF-16. It searches
the simulator's and this Mac's unified logs (info and debug too), the app's data, group containers,
preferences, caches, web data and saved state, the folders an unsandboxed Mac build keeps straight
under `~/Library/Caches` and `Application Support` (Transcripts, Sessions, Outbox…), crash reports
and the mock's output. It prints where a value turned up (by line number, never the value) and
exits 1; it exits 2 when anything couldn't be searched or no place was given; "Nothing found" and 0
is the pass.

**Browsing in this app** ([web.md](web.md) §6) needs Bot Mode signed in, as Hermes refuses the
controller to Automatic sign-in: start the backend with `--password <anything>` and launch with
`-HERMES_BOOTSTRAP_BACKEND_PASSWORD <the same>` too (Debug only; the app signs in as admin). Pick In
this app on the Browser page, then "in the app" in a chat drives the mock's Acme Cloud pages in the
chat's Browser tab; "carry on" after signing in there finishes, "in the app slow" and "in the app
router" try the deadline and the network ask. `POST /api/mock/browser-control {"reset": true}`
drops every registration.

A message with "key expired" fails its turn on Anthropic's key (Add Key… in the chat; the mock's
`model.save_key` takes it), "signed out" on OpenAI Codex's sign-in.

Features that aren't set up (`Tools/mock-hermes/setup.py`, [setup.md](setup.md) §5): `--setup
board-off,tidying-off,turn-isolation,…` starts the backend with them, and `POST /api/mock/setup
{"states": [...]}` changes them while it runs (`["ready"]` clears them; it needs the
`X-Hermes-Session-Token` the mock's index page carries as `__HERMES_SESSION_TOKEN__`). The `update`
states run a 9 s `hermes update` for Update Hermes…. The app's fixes write
through `PUT /api/config`, which the mock deep-merges like Hermes. `-HERMES_SETTINGS_SETUP
YES|<feature id>` opens Settings → Setup, or one feature's page there (with `-HERMES_OPEN settings`
on iPhone and iPad).

On the Mac, a window on another Space takes no input from outside (cua-driver refuses it, and
bringing the app forward would take over the screen). `-HERMES_MAC_DRIVE "<steps>"` drives the
Debug app from inside instead: `wait <s>`, `press <toolbar item>` (a Settings tab), `tap <x> <y>`
(points from the Settings window's top left, a screenshot's pixels halved), `click top-button` (a
pushed page's back button), `key cmd+[`, and `dump` / `views` to see what's there. Each step logs
`HERMES_MAC_DRIVE` with the Settings window's title, so the page shown can be checked without a
screenshot (`App/Support/MacDebugDriver.swift`); `tabs` logs how many Settings tabs show, of how
many. Capture with `screencapture -x -o -l <window id>`. `-HERMES_SETTINGS_TABS_START <width>` starts
the Settings tabs' width too narrow, to watch the toolbar check widen it. `-HERMES_LAUNCH_AGENTS_DIR
<folder>` points Run at Full Priority (Setup → Priority) at a stand-in LaunchAgents folder and only
logs its `launchctl` calls (`HERMES_LAUNCHCTL …`); the mock's `throttled-here` and `priority-here`
states use `build/mock-launch-agents`. The main window's bars (the sidebar's footer, the composer)
don't draw in an off-Space capture, so `-HERMES_GALLERY priority` shows the footer with its priority
notice (at the sidebar's narrowest and usual widths, and with large text where SwiftUI scales it)
and the update's result for the connected gateway; `priority:update` updates Hermes first,
and `priority:update:fix` then runs Run at Full Priority (docs/setup.md §4.17). With
`priority-here`, `priority:update` shows the app putting the gateway back at full priority by
itself, and `priority:restart` does the same after Plugins' Restart Gateway (the mock's plist in
`build/mock-launch-agents` says Interactive again; pointed at another folder, it stays without).
`-appearance light` or `dark` picks the gallery's look.

A Mac window that isn't on screen (the screen locked, another Space, behind other windows) lays
out differently: AppKit solves its split view's constraints from each column's minimum size, and a
column that reports a minimum taller than the window sends it round until it throws
(`-[NSWindow _postWindowNeedsUpdateConstraints]`). So a column never takes its minimum from what
it shows (`RootView.splitView`, the sidebar's as much as the detail's, and the chat before the
Inspector makes it a column). A column that does lays out the whole window taller than itself even
on screen: its top slides under the title bar and its bottom (the composer, the sidebar's footer)
is cut off; the backend's `--setup throttled-here` puts the priority notice in the sidebar's footer
to check it. To check a change to what fills a column, start a Debug build from a shell (it opens
behind the window in front) on a chat with a question card:
`.../Hermes.app/Contents/MacOS/Hermes -HERMES_OPEN bot:researcher -HERMES_SEND_HERE "clarify pair"
-HERMES_SEND_HERE_AFTER 4` with the `-HERMES_BOOTSTRAP_*` flags and its own `CFFIXED_USER_HOME`.
It should still be running a minute later; the loop shows first as SwiftUI's "Geometry action is
cycling between duplicate values" in the log.

And the Board (`Tools/mock-hermes/kanban.py`), shaped like the gateway's kanban plugin
(`/api/plugins/kanban/*` and its event socket): Hermes App's board as the design draws it (two
running, one quiet for 9 minutes, a card that needs Ada's answer, one that gave up, a review with its
PR checks, a split card). A pretend dispatcher picks up cards that become Ready while it runs, works
on them for 20 s with worker output, and finishes them; seeded cards stay put. Refusals use the
gateway's words. In a chat, "… as cards" adds three cards with `kanban_create`. `POST
/api/mock/kanban/act {card, action: needs_input|review|gave_up|complete|stale}` drives a card
(`review` takes `ok: false` for a failing check), `POST /api/mock/kanban/config {dispatcher, socket}`
pauses the dispatcher or refuses the socket (the app then polls every 5 s), and `POST
/api/mock/kanban/reset` puts it back. Debug flags: `-HERMES_OPEN board:<project id>` with
`-HERMES_BOARD_COLUMN <column>`, `-HERMES_BOARD_CARD <card id>` and
`-HERMES_BOARD_SHEET new|assign|reopen|watch|edit`.

And the Inspector (`Tools/mock-hermes/inspector.py`): a "Hermes Site" project
(`/Users/studio/Code/hermes-site`) with files (`/api/fs/*`), git status and review with four
changed files, staging, commits, pushes and pull requests (`/api/git/*`), a dev server on
`127.0.0.1:5173` (`--dev-port`) serving the beta sign-up page, `preview.restart`, `llm.oneshot`
drafts, and the Bot Screen over RFB (`display.*`, `WS /api/display/ws`) with the lease. Its chat
"Pricing card" has two versions of an HTML artifact. In a chat, "… sign-up" or "… beta" writes the
page, starts `npm run dev`, opens it in the Preview and drives it (`preview.act`, `preview.read`);
"pricing" adds an artifact version; "terminal" reads the Terminal. Mock-only: `POST
/api/mock/inspector/screen {action: evict|stop|start}` (close codes 4000 and 4001),
`…/gh {authenticated, available}`, `…/touch {path, text}` (a change on the gateway), `…/dev
{running}`, `…/pace {seconds}` (slower driving, for screenshots) and `…/turn {session, text}`.

And What Hermes Learned (`Tools/mock-hermes/learned.py`), shaped like the gateway's
`/api/learning/*` and curator: eleven skills (two new this week, one stale), memories spread over
three months, three archived skills and a last tidy two days ago that merged two skills into
ios-testing. `/curator pin|unpin|restore|list-archived|usage` answers through `slash.exec` with the
CLI's words, Tidy Up Now takes 6 s and merges the least-used skill that isn't kept as is (and sends
the tidy's notification), and a chat message with "skill" writes commit-message-style with
`skill_manage`. `POST /api/mock/learned/reset` puts it back. Debug flags: `-HERMES_OPEN learned`
with `-HERMES_LEARNED map|tidying|skill:<id>|select:<id>|mapselect:<id>`, and
`-HERMES_PUSH_OPEN tidied` (a tapped tidy notification).

And full-text search (`Tools/mock-hermes/search.py`), shaped like `hermes serve`'s
`/api/sessions/search`: "reconnect" matches seven chats across Hermes App's lanes, a task run of
Check NAS backups and Ada's "Release notes draft"; prefixes match ("reconn"), `source`/`profile`
filters work, and replies take 150 ms. Tasks have three recent runs, one failed
(`/api/cron/jobs/<id>/runs`). Debug flags: `-HERMES_SEARCH <text>` types into the chat search
(with `-HERMES_DRAWER YES` on iPhone), `-HERMES_PALETTE <text>` opens the Mac's ⌘K palette,
`-HERMES_OPEN chat:<session id>` opens a chat, and `-HERMES_GALLERY talk[:n]` shows the Talk states
without the microphone (a Mac build started from a shell can't use it).

Talk: `-HERMES_TALK_TO <profile>|hermes` calls as a Shortcut would (after Bot Mode connects), and
`-HERMES_TALK_LATENCY YES` shows the time from the end of speech to the first audio. The mock's
audio (`Tools/mock-hermes/audio.py`) speaks every reply in speech-like PCM; `POST /api/mock/audio`
switches Realtime on (`{"realtime": true}`, its SDP answer can't connect, so the call falls back to
Hermes Voice), the voice to `fallback` or `broken`, client-direct keys (`direct`, a fake key) and
gateway transcription; `GET /api/mock/audio/turns` lists the voice turns and what was spoken. The
states: say "disk" or "approve" for an approval, "clarify" (in a Hermes chat) for a question,
"secret" or "sudo" for a request to type, "essay" for a long reply to talk over, "fail" for a
failed turn. Voice messages: hold Dictate with `-HERMES_VOICE_INPUT` set (the clips play from
when recording starts); ask any Bot for something "as audio" (or a "voice note") and it answers
with a `text_to_speech` voice message (`[[audio_as_voice]]` + `MEDIA:`), served by the mock's
`/api/files/stream` like the recordings `file.attach` staged. Voices: GET/PUT `/api/config` keep each
Bot's `tts` and `voice` sections; with `{"direct": true}` voice-config points previews at the mock's
own `/mock-provider/…` (never a real provider), and `GET /api/mock/audio/turns` lists them. Setup:
`GET /api/env` lists the voice keys per profile; `{"env_refusal": "…"}` makes `PUT /api/env` refuse
with Hermes's 400; `{"tts": "broken"}` makes the gateway's voice fail so Talk and Listen say why.
Transcribe on: The gateway (launch with `-voice.transcribeOn gateway`): `{"stt_streaming": true,
"transcript": "…"}` makes `transcribe-stream` answer with those words (or set `stt.provider` to
openai, xai or elevenlabs and `stt.streaming: true` with `PUT /api/config`, plus the key with
`PUT /api/env`, as on a real gateway); `{"stt_live_fail": "…"}` answers `eos` with that error, so
the turn goes whole to `POST /api/audio/transcribe`. `GET /api/mock/audio/turns` lists `live`
(each socket's rate, bytes and end) and `whole`.
A voice message without on-device words (record with `-HERMES_VOICE_INPUT` playing `loud-tv.m4a`,
whose words are none): `POST /api/mock/audio`
`{"transcript": "…", "transcribe_delay": 4}` has the gateway's words come back after 4 s, so the
message shows as audio first and "Transcribing…" in the live line; `{"transcript": ""}` is no words
heard; `{"transcribe_refusal": "No STT provider available. Install faster-whisper …"}` answers
Hermes's 400 instead (`null` turns it off).
`POST /api/mock/audio/brief` delivers Research Buddy's "Morning brief" routine now, a stack in an
inline block, for Listen to the brief.
Hey Hermes (launch with `-voice.heyHermes YES`, and `-HERMES_CHARGING YES` on a simulator, which
never charges; always with `-HERMES_VOICE_INPUT` there, or the simulator hears the Mac's
microphone): `POST /api/mock/wake {"enabled": true, "detect_after": 1}` turns the mock's wake word
on and has it hear "Hey Hermes" after a second of fed audio; `{"available": false, "hint": "…"}`,
`{"enabled": false}`, `{"other_owner": "tui"}`, `{"surface": "tui"}` and `{"capture": "local"}`
are the setup's other states. `GET /api/mock/wake` counts feeds, detections and resumes.
`-HERMES_LISTEN <text>` shows Listen's mini player reading the text, paused before a word is
spoken; with `-HERMES_DRAFT <text>` it sits over a grown composer.
`-HERMES_TYPE <text>` types into the open chat's composer as the keyboard would,
`-HERMES_TYPE_AFTER <seconds>` after it appears (8): "/" opens the command menu with the keyboard
up, without taps (and on the Mac without clicks). With `-HERMES_SCROLL_LOG YES`, `MENULOG` lines give
where the top bar ends and the composer's top, the two the menu's room comes from.

Voice without a microphone (simulators, UI tests, a Mac build started from a shell, which TCC stops
at the real microphone): `-HERMES_VOICE_INPUT <path>@<seconds>,…` plays spoken clips as if heard by
the microphone, each at its second from when listening starts (overlapping clips mix: a TV with
someone talking over it), e.g.
`-HERMES_VOICE_INPUT $PWD/Tools/mock-hermes/voice/check-nas.m4a@2,$PWD/Tools/mock-hermes/voice/allow-once.m4a@11`.
Listening starts when a call reaches Listening, dictation listens, a voice message records or the
wake word listens; until then the microphone hears a quiet room, so a call slow to get there plays
its clips late rather than to no one. The clips and their words keep one clock:
`-HERMES_ENGINE_START_DELAY <seconds>` holds the audio engine's first start back that long, as a
busy Mac can, to check that nothing counts on a quick start.
Voice activity, endpointing and barge-in run on that audio. `-HERMES_REALTIME_LOOPBACK YES`
(iPhone and iPad, with `{"realtime": true}` on the mock) answers Realtime's WebRTC offer with a
peer in the app instead of OpenAI: it speaks in bursts (four seconds on, four off) and logs how
loud what it hears is ("loopback heard -81 dB at 11.5 s, speaking", category `talk`), so the gate
can be checked with clips: a TV across the room is 40 dB down while it speaks, a near voice whole.
Nothing reaches a provider. Simulators can't run the speech model,
so there the words come from the `.txt` beside each clip, appearing as it plays. The clips in
`Tools/mock-hermes/voice/` were made with `say` and `afconvert -f m4af -d aac -b 32000 -c 1`;
`loud-tv` is three `say` voices mixed with `ffmpeg` at about the level of the others, with an empty
`.txt` (noise has no words).

The mock's audio routes (REST, both sockets, the voice fields of `prompt.submit`, the wake word)
have tests that start their own mock on free ports: `python3 -I -m unittest discover -s
Tools/mock-hermes/tests`.

### Push notifications

Run the mock backend with a relay to try notifications end to end:
`python3 Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642 --push-relay https://push.hermesapp.dev`
(real APNs sandbox to an Apple-silicon simulator). `--push-relay simctl` is the default but never
runs the service extension, and `none` plays a gateway without the plugin. In a Bot Chat,
"approve", "ask", "sudo" and "long" (a Live Activity turn; "long … approve" asks mid-way) send
notices. Use the iOS 26.5 simulator: iOS 27.0 never shows the notification permission prompt.

### The app's plugins

The mock plays the app's own plugins per profile (`Tools/mock-hermes/app_plugins.py`, wrapping
`plugins.manage`, [plugins.md](plugins.md) §2.1). `--app-plugins current` (the default) has
both plugins in every profile, installed by hand; `missing` (the default with `--push-relay
none`) has them nowhere, and `/app-push` answers 4018 until the root has it; `partial` leaves out Ada
(`writer`) and Scout; `old` has the previous versions everywhere (push 1.1.0, widgets 1.1.1: the
same access), so the app updates them quietly; `widened` has widgets 1.1.0, whose pin adds a hook,
so the update waits for the consent card; `off` has the root's hermes-app-push turned off (Turn On);
`failing` has them nowhere and every install fails like a gateway that can't reach GitHub. Installs
answer with an `activation` like Hermes's (hooks and commands now, tools and the prompt section
from the next chat). `POST /api/mock/app-plugins
{state}` sets it again while the app runs. Installs take 0.8 s, refuse like Hermes (5026 without
`force`, a short `ref`, a pinned copy without a new one; 4064 for an unknown profile), and
`POST /api/gateway/restart` answers like the real backend and gives the gateway a new `pid` in
`GET /health/detailed`; `GET /api/actions/gateway-restart/status` streams its log for about 5 s
(what /restart's card shows), and `POST /api/mock/restart {"fails": true}` makes it exit 1. `-HERMES_PLUGINS_ASK YES` opens the ask
for the current gateway once Bot Mode connects, whatever was answered before;
`-HERMES_PLUGINS_FORGET YES` forgets this device's answers and lets the app decide;
`-HERMES_PLUGINS_ASKED YES` plays a device that answered the ask in an older app (no per-plugin
yes), so a widened pin waits. UI tests: `PluginsUITests` (the ask once per gateway, installing in
5 profiles, the consent card, a failed install, no ask without Bot Mode, the hub without Bot Mode,
Don't Suggest Again and Show Again).

Hermes's catalog (`Tools/mock-hermes/plugin_hub.py`): the backend serves the catalog feed at
`/docs/api/plugin-catalog.json` (`Tools/mock-hermes/plugin-catalog.json`: twenty entries in the
design's states, a Windows-only one, one that needs a newer Hermes, and two pulled names); point a
Debug build at it with `-HERMES_PLUGIN_CATALOG_URL http://127.0.0.1:19119/docs/api/plugin-catalog.json`,
so nothing reaches the network. `GET /api/system/stats` says macOS, `studio-mac.local` and Hermes
0.22.2. `plugins.manage onboarding` and `presence` read the feed (Blender, Figma and TouchDesigner
present, Obsidian missing); `install {catalog_name}` installs any feed entry into the profile asked,
refusing like Hermes (pulled, another OS, a newer Hermes) and listing unset `requires_env` keys as
`missing_env`; `reload.env` takes no params. Installed for the hub: DaVinci Resolve (its app isn't
running), Obsidian Memory (off), Langfuse (two keys missing), agent-ledger (pulled), and the
homeassistant update that asks for more access in Hermes's words. `--plugin-catalog none` answers
404 for the feed; `POST /api/mock/plugin-hub {failing, feed}` makes installs fail or the feed vanish
while it runs. `-HERMES_APPS_TOOLS plugins` opens the hub, `plugins:suggested` the Mac's pane.

