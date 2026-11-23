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

Simulator builds need no signing set up. Build Release for the simulator with signing on, as it is
by default: a build made with `CODE_SIGNING_ALLOWED=NO` carries no entitlements, so it can't save
the API key, and signing it ad hoc afterwards stopped it launching. To run on your own iPhone or
Mac, set `DEVELOPMENT_TEAM` and `bundleIdPrefix` in `project.yml` to your own team and prefix (and
the App Group and Keychain group settings next to them), then generate again. Push notifications
need the APNs entitlement and the relay, so expect them to stay quiet on a personal team.

### Debug and Release

| | Debug | Release |
|---|---|---|
| App | **Hermes Dev** (amber icon) | **Hermes** |
| Bundle id | `co.caffeinatedcode.hermes.dev` | `co.caffeinatedcode.hermes` |
| Mac data folder | `Application Support/co.caffeinatedcode.hermes.dev` | `Application Support/co.caffeinatedcode.hermes` |
| Mac caches folder | `Caches/co.caffeinatedcode.hermes.dev` | `Caches/co.caffeinatedcode.hermes` |
| Keychain, settings | its own | its own |
| Demo bootstrap and `-HERMES_*` launch flags | yes | compiled out |
| Mac updates | off | Sparkle |

Dev builds can point at the mocks freely; they never touch the real app's gateways, keys, outbox,
Up Next or caches, and both run at the same time on one Mac. (`Application Support/Hermes` belongs
to Hermes Desktop; the app never writes there.) Up to Hermes 1.0 beta (2611190410) both kept their
outbox, Up Next, waiting new chats, group posts and caches straight under the shared Application
Support and Caches folders. The release app carries its own queued items over from there, one
at a time as it opens them; Hermes Dev leaves what it kept there alone, and the old caches stay
where they are until you delete them. Removing a gateway or a chat clears only the app's own
folder, so a queued item it hasn't opened since stays in the shared folders too.

### Releases

Official releases are signed and shipped by the studio's Buildkite pipeline `hermes-release`, on its
own Mac mini's agent (`.buildkite/release.yml`, which runs `Scripts/release.sh`), with a trusted
MacBook as the fallback while that pipeline is new. Both need the studio's keys, so neither runs
anywhere else; [releasing.md](releasing.md) says how, a dry run first. Forks release with their own
team and their own tools.

## Test

```sh
cd Packages/HermesKit && swift test
# plus a round trip over a real WebSocket against the mock backend:
HERMES_MOCK_BACKEND=http://127.0.0.1:19119 swift test --filter BackendIntegrationTests
# how long a 50 KB reply takes to parse and tint as it streams, in release (about 80 s):
HERMES_STREAMING_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter StreamingTiming
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
`LaunchAppearanceUITests` switches the simulator between Light and Dark Mode and puts it back as it
was when each test ends (`docs/design-to-swiftui.md` §1).

A test that stops mid-call must end the call: its Live Activity outlives the app, and installing
the next build makes the system launch the app for it, without launch arguments, just as the next
run's first test launches the app. That test gets the system's launch and no `-HERMES_*` flags.
`VoiceUITests` ends any call left running when each test ends.

A turn one test leaves running would turn the next test's message in the same chat into a
redirect (Hermes's default busy mode). So `IndicatorsUITests` and `RequestCardUITests`, which send
in Research Buddy's chat, start each launch with `POST /api/mock/stop-turns {"profile":
"researcher"}` on the backend mock. It stops every running turn (of `profile`, if given) through
Hermes's own `session.interrupt`, as Stop on another device does, and answers once they are all
idle, or 504 with the ones still running after `seconds` (15 by default).

The relay has its own tests (`cd Relay && npm ci && npm test`). The app's Hermes plugins' tests run
against a real Hermes Agent checkout, in a throwaway `HERMES_HOME`; see [plugins.md](plugins.md)
§5.6 and [Tools/hermes-app-push](../Tools/hermes-app-push/README.md).

### The send matrix

Every way a message reaches Hermes, against every state a chat can be in (issue #53), proven
twice: at the model level by `SendMatrixTests` in HermesKit (each cell fed Hermes's own answer for
its state, and held to the rules below), and in the app on iPhone and Mac against the mock by
`Tools/mock-hermes/matrix/send_matrix.py`, which launches Hermes Dev with `-HERMES_*` flags, drives
the mock's endpoints, reads the screen (AXe, or cua-driver on the Mac) and counts what Hermes stored.
The rules: what was sent always shows its true state; nothing is lost, sent twice or sent into the
wrong turn; the queue survives a reconnect and a relaunch; Stop clears exactly what it says; a
refusal is Hermes's words, never a generic error.

| | Idle | Turn or tool running | Process notice's turn | Gateway's own turn | Unconfirmed | Another process | Reconnecting | Offline | Relaunch |
|---|---|---|---|---|---|---|---|---|---|
| Send | its turn | Up Next, "sends when this reply is done" | held by Hermes, runs once | Up Next, "sends when that turn ends" | looked for, never resent | Up Next, names the holder | Up Next, "sends when … is back" | "Waiting for …", goes once | behind the restored queue |
| Steer | goes next ("finished before reading it") | read into the turn | not offered | not offered | not offered | not offered | goes next, "Couldn't reach …" | not offered | read into the turn |
| Up Next | sends | waits | held by Hermes | waits for the gateway | looked for | waits, names the holder | waits | waits | sends once opened, Maybe sent stays |
| Stop | not offered | stops; gives back what Hermes held, says what else stopped | not offered | not offered | not offered | not offered | turn stays, "couldn't reach" | not offered | stops |
| Try Again | its turn | Up Next | held by Hermes | waits behind the refusal | not offered | waits behind the refusal | Up Next | waits for the gateway | Up Next |
| Edit and Resend | a new chat | a new chat | a new chat | a new chat | a new chat | a new chat | back in the field | back in the field | a new chat |
| Photo while busy | its turn | held by Hermes, own turn | held by Hermes | waits, "with its photo" | looked for | waits | Up Next | waits for the gateway | held by Hermes |
| Talk | its turn | steers | held by Hermes | waits | looked for | waits | goes next | back in the field | steers |
| Another Bot | its turn | Up Next | held by Hermes | waits | looked for | "… is answering …" | Up Next | waits for the gateway | Up Next |
| Routine follow-up | Hermes's turn, live | the next turn, after this one | the next turn | runs on the gateway | runs on the gateway | "… is following up on its routine …" | the next turn | stored, shown on return | the next turn |

Dictation fills the field, so it is Send. Talk is proven at the model level only (a simulator has
no microphone to drive). A photo while busy is sent with `-HERMES_FOLLOWUP_IMAGE <path>`, which
attaches that picture to the `-HERMES_FOLLOWUP` message as a paste does, on iPhone and Mac alike
(never through the Mac's clipboard). Once it ran, its bubble must show the photo, as one sent while
Hermes was idle does (`photo_idle`): the mock stores a photo as Hermes does, the words, an
`[Image attached at: <path>]` line per photo (`@image:<path>` with `backend.py --image-refs`), a
`[screenshot]` line per photo and the notes Hermes added for the model (`image_turns.py`).
`--photo-chats` seeds chats of such rows stored before Hermes kept the typed words apart.
`HERMES_MATRIX_PORTS=<backend>,<gateway>` moves the matrix's mock off 40219/40742, beside another
run. The cells that depend on timing (offline, reconnecting, a slow or lost answer, a relaunch with
an outbox) run in a quiet window; the rest run any time:

```sh
python3 -I Tools/mock-hermes/matrix/send_matrix.py --udid <simulator> --app <Hermes Dev.app> --out <folder> --only lane
python3 -I Tools/mock-hermes/matrix/send_matrix.py --mac --app <Hermes Dev.app> --out <folder> --only window
```

It starts its own mock on ports 40219 and 40742 and stops it at the end; on the Mac it sets Hermes
Dev's data folder aside first and puts it back byte for byte.

A follow-up that quotes a reply runs from launch flags too, since the Mac doesn't offer Reply while
a turn runs. `-HERMES_SEND_FIRST <text>` sends that first, in the chat `-HERMES_SEND` then goes to,
and waits up to 60 s for its reply to finish. `-HERMES_FOLLOWUP_QUOTE <words>` quotes those words
from the newest finished reply that has them, through the same call Reply makes, before the first
`-HERMES_FOLLOWUP` is typed (`docs/follow-ups.md` §1). `-HERMES_FOLLOWUP_SEND <seconds>` waits that
long between typing the follow-up and sending it, so the bar and the field can be seen first (`YES`
waits 0.6 s). The mock prints the text each aside and background task carries, quotes included:
`[mock-hermes] prompt.btw text '…'` and `[mock-hermes] prompt.background text '…'`. In
`backend.py`, "Show me the links" reaches the "links" reply, which begins "**Blog published:** it's
live.", and "marathon please" runs twelve steps of 3.6 s, about 45 s. On the Mac:

```sh
.../Hermes.app/Contents/MacOS/Hermes -HERMES_OPEN bot:default -HERMES_SEND_AFTER 6 \
  -HERMES_SEND_FIRST "Show me the links" -HERMES_SEND "marathon please" \
  -HERMES_FOLLOWUP "What does it cover?" -HERMES_FOLLOWUP_MODE askAside \
  -HERMES_FOLLOWUP_QUOTE "Blog published" -HERMES_FOLLOWUP_SEND 8
```

with the `-HERMES_BOOTSTRAP_*` flags and its own `CFFIXED_USER_HOME`. Two seconds into the marathon
(`-HERMES_FOLLOWUP_AFTER`'s default) the bar shows the quote and the field the question; 8 s later
both are empty, the turn still runs, and the mock prints the question behind a block quote of "Blog
published". `-HERMES_FOLLOWUP_MODE background` does the same for Run in Background.

## Checks on main

Every commit to `main` runs the checks in the studio's Buildkite pipeline `hermes-checks`, on its
own Mac mini's agent (the self-hosted `macos` queue, never a Buildkite-hosted Mac):
`.buildkite/checks.yml` runs `.buildkite/steps/checks.sh`, which runs

- `xcodegen generate`, then `swift test` in Packages/HermesKit;
- the relay's tests (`npm ci && npm test` in Relay);
- the iPhone (`generic/platform=iOS Simulator`) and Mac Debug builds, which fail on any warning in
  our own files (`Scripts/check-build-warnings.sh <log>` checks a build's log the same way).

The builds sign ad hoc, with no signing identity, and the pipeline has no secrets. The agent
builds with the mini's selected Xcode (it follows `xcode-select`), and the job's log starts with
its version. The job runs in the mini's desktop session, where the Keychain tests reach the login
keychain, and never during a release, which swaps that keychain out while it signs.

Pull requests, forks, tags and other branches are never built, on purpose. The repository is
public and the mini holds the studio's signing keys, so code that hasn't been merged doesn't run
there. The pipeline's settings build `main` only, and the step and the script each refuse anything
else as well. Before you open a pull request, run the commands under [Build](#build) and
[Test](#test) yourself.

## Run without a real gateway


```bash
python3 Tools/mock-hermes/server.py --port 18642 --key dev-key-0123456789abcdef
```

Then add `localhost:18642` with that key, or launch a Debug build with
`HERMES_BOOTSTRAP_URL=http://127.0.0.1:18642` and `HERMES_BOOTSTRAP_KEY=…` in the environment.
Messages containing "approve" ask for permission, "slow" runs a long multi-tool turn,
"marathon" runs six steps of 12 s each, "heartbeat" makes four tool calls with narration between
them and starts a background process that wakes the chat twice with a heartbeat (each answered
with `[SILENT]`) and once when it ends (answered with a reply), 6 s apart, as Hermes stores them
(two unread messages, `docs/inbox.md` §1 Counting), "aside" writes its reply in the same message as
a memory save and leaves the follow-up empty, as Hermes does beside only housekeeping calls, so the
reply has to show as the chat message and never in the steps (`docs/chat.md` §1), and "fail"
fails. Hermes sweeps a run's events 300 s after
the run was created when nothing listens, even while it runs (its status stays, its events answer
404); `--run-stream-ttl <s>` shortens that. A simulator keeps a suspended app's connections open,
so `POST /api/mock/drop-run-streams` closes every open run stream, as a phone's suspended app loses
them: "marathon" with `--run-stream-ttl 20`, the app sent to the background, the streams dropped,
and the app back after half a minute comes back to a run whose events are gone (`RunFollow`,
`docs/chat.md` §2). `POST /api/mock/restart-gateway` restarts the gateway under its runs: each dies
where it is and stores nothing more, its events go, and a run started under an `Idempotency-Key`
(the app's are) reads `interrupted`, "The gateway restarted before this run settled.", while one
without is gone (404); `{"forget": true}` forgets every run, as an older Hermes did. Relaunch the
app after it, or during "slow" without it, for a run whose end the app never heard (`UnheardRun`);
`POST /api/mock/runs-down {"seconds": 90}` first makes the run's status answer 502 meanwhile, for the
turn that says it couldn't reach the gateway.

The mock answers approvals as Hermes's run store does (`docs/quick-actions.md` §3): `POST
/v1/runs/{id}/approval` (and `/clarify`) takes exactly `{request_id, execution_generation,
choice}` (`answer`), and anything else is 400 `invalid_params`. A generation other than the run's
is 409 `stale_generation`, and a prompt it isn't waiting on is 409 `approval_not_pending`; each
refusal's message is its bare reason, as Hermes's. `GET /v1/runs/{id}` carries
`execution_generation` and the prompts in `pending_controls`. "approve stale" moves the run's
generation as soon as the card is up and drops the prompt with it, as Hermes does: the next read of
the run's status announces it (`approval.settled` with the old generation), so a card still up goes
then, an answer sent meanwhile is refused stale and finds the run no longer lists it, and the turn
asks again 30 s later. "approve stale retry" keeps the prompt under the new generation, which Hermes never does,
to exercise the app's one defensive retry. When Hermes stops waiting on an approval, however that
came about, the run's events say `approval.settled` with its `prompt_id` and generation. "approve
elsewhere" allows it on another device after 5 s, then runs the command for 20 s (the card's answer
in that time finds nothing waiting), and "approve timeout" stops waiting after 20 s (`timeout_s`)
and denies the command. "approve script" asks for a 20-line heredoc, taller than the card's
command box (docs/quick-actions.md §1), so the box caps its height and scrolls. With "legacy" in
the message (say "approve elsewhere legacy") the events are an older gateway's:
`approval.responded` after this device's answer, and nothing when another device answers.

"clarify" asks a question mid-turn as Hermes does over the API server: a running clarify step, the
prompt in the run's `pending_controls` and a `clarify.request` on its events, then
`clarify.settled` when it stops waiting, and the reply says what was picked. "clarify quiet" lists
it only in the status (a gateway that leaves it off the events), "clarify multi" offers several
picks, "clarify open" none, "clarify elsewhere" is answered on another device after 5 s, and
"clarify timeout" stops waiting after 20 s (`timeout_s`). `--late-events <s>` holds every run's
events that long after its stream opens, as a stream that attached late: with `--late-events 8`,
"clarify timeout" reaches the app 8 s after Hermes asked and still ends with "Hermes stopped
waiting · no answer in time".

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

Attaching without the clipboard, on a simulator or the Mac: `-HERMES_ATTACH <path>|<path>`
attaches those files to the new chat once it's connected, through the composer's own attach
path (the one the file picker, a drop and a paste use), so pictures, PDFs and other files land
where a person's would and a file the chat can't take shows the same Can't Attach alert. It never
touches the clipboard. Add `-HERMES_DRAFT <text>` to see the files in the composer before
sending, or `-HERMES_SEND <text>` to send them with the message (a name with `refuseupload` is
refused by the mock's `file.attach`, as a full disk would).

Ending a Mac run: `-HERMES_QUIT_AFTER <s>` quits Hermes Dev that many seconds after launch.
Every Debug build shares one bundle id, so a run never quits it by bundle id or name, and stops
only the process it launched itself.

For Bot Mode, also run the mock backend (four Bots with Bot Chats, routines, a photo avatar,
an active worker and a routine that posts every couple of minutes):

```bash
python3 Tools/mock-hermes/backend.py --port 19119            # ungated: Automatic sign-in
python3 Tools/mock-hermes/backend.py --port 19119 --password pw   # gated: admin / pw
python3 Tools/mock-hermes/backend.py --port 19119 --auth-providers session-token
python3 Tools/mock-hermes/backend.py --port 19119 --api-server-only
```

`--auth-providers` sets the sign-ins `/api/status` lists, comma-separated: `session-token` alone
gates the backend behind `--token` with no password (Edit Gateway offers only Session token),
`nous` alone offers none Bot Mode can use. `--api-server-only` answers like the gateway's API
server at the backend's address: `/health` and nothing Bot Mode needs, each refusal logged, to
count what the app sends to the wrong address (`docs/setup.md` §4.1). To count what a refused
sign-in costs, start it gated (`--auth-providers session-token --token <token>`), save a different
token in Edit Gateway, and count the log's `401` lines and `socket refused` lines: after the first
one or two, a stopped Bot Mode sends nothing until something changes. The same holds when the
address stops being a backend mid-session: sign in to a `--password` backend, then restart it on
the same port with `--api-server-only`, and the refused lines stop after the first one or two.

and turn on **Bot Mode** for the gateway with `127.0.0.1:19119`, or add
`HERMES_BOOTSTRAP_BACKEND=http://127.0.0.1:19119` to the Debug launch environment. "approve",
"slow" and "fail" work in Bot Chats too ("marathon" is "slow" for about 45 s, "flood" reads sixteen
sources with about 4,800 events in under a minute, more than the replay ring keeps (512 events or
4 MiB a session, as Hermes): `POST /api/mock/drop-sockets {"outage": 10}` in its middle and the
re-attach's `session.events.since` answers `truncated` (`docs/chat.md` §2), "essay" streams a long
Markdown reply for about ten seconds, "widgets" is a coding turn of about 25 s: two files, a failing
check, a third file and a passing one, with `inline_diff`s as Hermes renders them, and a steer sent
during the check is read after it, "late reply" ends its turn saying nothing and stores the reply 12 s
later, "upgrade" is the ARGUS turn from `docs/chat.md` §2 (one turn, one place): narration, three
commands, the reply and a `review.summary` 2 s after the turn, "many edits" is a coding turn of
about 15 s for the Changes row (`Tools/mock-hermes/edits.py`, `docs/chat.md` §2): a 100-line
script created (its `inline_diff` shortened at 80 lines, as Hermes does) and patched four times, a
helper patched twice, a patch that fails to match, a new note, an old script deleted with a V4A
patch, two checks between (`-HERMES_SHOW_CHANGES <s>` opens the open chat's latest changes that
long after launch, as tapping its row does), "page risks" reads three pages with what Hermes's scanner reports for each: a zero-width space
only, a right-to-left override, instructions; "page risks with a digest" also delivers Research
Buddy's Daily digest while the second page is read, "overnight" plays a night of a Bot working on its
own, as Hermes stores it: a message to Ada and two background checks, then over about 12 s a failed
test run's and a fetch's completion notices, a follow-up with two commands and `[SILENT]`, Ada's reply
carried back by the delivery's notice, a batch of helpers' results with one timed out, and Ada's
machine-style brief; `docs/chat.md` §2a), "bot messages" sends five messages to other Bots in
both shapes Hermes has (`Tools/mock-hermes/processes.py`): `message_agent` to Ada, replied about 3 s
after the turn, and to Ops, waiting for about 20 s before "No reply"; the Bot running `hermes -p
writer chat -q …` itself, replied; `hermes -p ops chat … --query-file …`, with no words to show,
ended and no longer listed ("Ended", the title row alone); and a `message_agent` to Ops streamed
without `args` (as a mirrored row is), ended with no answer 2 s later and no longer listed, so
while the turn runs it is the title row alone (its stored row has the words). "background tasks" (any
chat) starts five checks in the background and stores their completion notices as Hermes does
(`docs/chat.md` §2a): the tests failing with exit 1 after 5 s, a fetch, a build and a lint, as the
gateway's batch row for two (`… completed for this session.`, ids only) and two single rows in a row (one line, "4 background tasks finished · 3 ok, 1 failed"),
a reply, the docs build alone after about 25 s ("Docs build finished · 25 s" while the gateway still lists it), a reply, then a completion
with no details (`Command: unknown`, no output, no step: "A background process finished"). "every tool" plays one finished step of
each kind of tool (commands, one that printed nothing and one that printed only blanks, files read,
searched, patched and written, the web, the browser, typing into a page, images, code, a skill,
session search, two MCP tools, one answering only blanks, memory, and a failure), and `@mentioning`
another Bot drops a message in its chat. "fallback" ends its turn on a fallback model, with Hermes's
own lines (`docs/chat.md` §2, "Model switches"): "⚠️ Model fallback: claude-opus-5-5 via anthropic
unavailable (provider server error); using gpt-6-sol via openai-codex." just before the turn's end,
and "✅ Primary model restored: …" as the next turn starts. "fallback every turn" keeps the primary
failing, as one that fails for any reason but a rate limit does: every turn after it starts with the
restore and ends with the fallback, until "fallback off" (`Tools/mock-hermes/tests/test_model_switch.py`).
The chat shows one note and never the restore. `--drop-after-reply` cuts every socket right after a turn's
`message.complete`, `--late-store <s>` writes a turn's reply that long after `message.complete` (its
`persisted_turn` then has no `final_assistant_row_id`), `POST /api/mock/restart-gateway` kills the
turns where they are and cuts every socket, as a gateway restart does (a resume finds the chat idle,
with a new event sequence; auto-continue isn't played), `--agent-build <s>` says the session is idle on `prompt.submit` and takes the
prompt that long later (Hermes building a chat's agent on a loaded Mac). As Hermes, the mock
starts the next turn the moment one ends, right after its idle notice: a steer the turn never read,
then what its queue holds ("essay", a steer while it streams, and the steer goes as the next turn;
a steer with "quietly" in it makes that turn send nothing for 8 s, as a model writing a long tool
call: the steer shows as that turn's message meanwhile, never missed, `docs/chat.md` §2). Up Next
sending by itself (`docs/follow-ups.md` §4): queue a message behind "slow", quit the app before
the turn ends and open the chat again after it has (it goes once the chat loads), or queue one
behind a turn and `POST /api/mock/drop-sockets {"outage": 15}` past its end (it goes on the
reconnect). `--late-settle <s>` says
the session is idle that long after it (the turn's
end handing over: `-HERMES_SEND "write swift widgets" -HERMES_SEND_AFTER 6 -HERMES_FOLLOWUP <text>
-HERMES_FOLLOWUP_MODE steer -HERMES_FOLLOWUP_SEND YES -HERMES_FOLLOWUP_AFTER 12` in `bot:default`, and
`-HERMES_LOAD_LOG YES` says "held for a later load" when it didn't). Connection trouble on demand: `POST
/api/mock/drop-sockets {settle, outage, reap}` cuts every socket (the next `settle` resumes of a running
chat answer 4009, new sockets are cut for `outage` seconds, and with `reap` (Hermes's is 20) a
session no socket came back for in that many seconds is interrupted and let go, so the next resume
gets a fresh, idle one with nothing to replay), `POST /api/mock/turn-elsewhere {session_id | profile,
seconds, text, reply, display_kind}` has Hermes start a turn in that chat by itself, as when a
background process finishes (about 8 s; without `text` it answers a finished `message_agent`
delivery's notice, tagged `process_complete` as the TUI gateway starts it, with the delivery
runner's long command, its quoted JSON and its JSON reply under `Output:`, stored late under
`--turn-isolation`; with `text`, `display_kind` (default `internal_notification`) tags it; with
`{"outage": 25, "reap": 20}` above in its middle, the app never hears it end: a stuck turn,
`docs/chat.md` §4b; `-HERMES_STUCK_TURN <s>` holds the open chat that way that long after launch,
without the mock's help), `POST /api/mock/freeze-sockets`
leaves them half-open, `POST /api/mock/history-down {seconds, status}` refuses stored chats' messages that
long while the socket keeps working (a 502, or `status: 404` for a chat Hermes no longer has: a reply the app
lost track of then says why, `docs/chat.md` §2), `POST /api/mock/stall {seconds}` freezes the backend the way Hermes's
dashboard freezes on a loaded Mac (requests, frames and pings wait, then all answer; the gateway
mock keeps answering), `POST /api/mock/starve {seconds, gap, slice, health}` starves the whole
Mac instead, both mocks at once (`Tools/mock-hermes/starve.py`, also on the gateway mock's port;
`--starve MIN-MAX` on either from launch): connections are taken but nothing is answered, health
checks included (`health: "prompt"` keeps those quick), until the process gets a `slice` (0.6 s)
of CPU every `gap` seconds (5–30 by default), when everything waiting goes out at once. It is what
Hermes did at load 500 on 2026-10-19, and how the app tells busy from offline
([connecting-and-voice.md](connecting-and-voice.md) §8); `{"seconds": 0}` ends it. `POST
/api/mock/lose-answer {method, taken, freeze}` loses the next answer to
`method` (default `prompt.submit`) with the request run (`taken: true`) or not; with `freeze: true`
the request runs and its socket goes half-open, so the turn is stored and the app hears nothing
(`docs/chat.md` §4b), and `POST
/api/mock/fail-reads {count}` refuses the next `count` read marks with 503 on both servers, as a busy
gateway does, for the read outbox (`docs/inbox.md` §4), and `POST
/api/mock/message-agent {from, to, text}` delivers another Bot's message off the socket (profile
names: `researcher`, `writer` is Ada, `ops`), as Hermes's one-shot `hermes -p <bot> chat` does:
the message is stored, then 12 s with no rows and no `session.active_list` entry, then the
reply ("long": a command step for 25 s first; "dies": no reply ever, as when Hermes stops a
delivery with the sender's chat). That process holds the Bot Chat until it replies, so a send is
refused with Hermes's own sentence ([chat.md](chat.md), a chat another Hermes process holds).
`POST /api/mock/message-agents {to, from, gap}` is several of those back to back (`from` a list,
Ada, Ops and Hermes by default): each Bot's message and its reply `gap` seconds apart (default 1),
the chat held throughout, so the app's read every 10 s brings several at once, for the jump pill
(`docs/inbox.md` §4).
`POST /api/mock/routine-elsewhere {profile, title, output, reply, seconds}` is a routine's
follow-up the same way (its output stored with no display kind, held `seconds`, default 20).
`POST /api/mock/deliver {profile, text, reply}` (profile `ops` by default) is a script's alert
posted into a Bot Chat as `hermes peer dm` does: stored as is, tagged `internal_notification`, and
answered in a live turn whose `inflight` carries the same display kind; with the chat open it shows
as the "Automation" card from the start ([chat.md](chat.md) §2a). Ops' Bot Chat is seeded with one
of each message nobody typed: that alert and its reply, a routine's delivery mirrored into the chat
(its routine, Disk report, is in Ops' Routines), a webhook's, an untyped `[System: …]` nudge
(hidden), a skill used from another device, a compaction summary folded into the person's next
message and one on its own as the newest row.
Every reason Hermes gives for refusing a message (`docs/chat.md` §4c, §4d), shaped like the
gateway's own: `POST /api/mock/owner {mode, profile | session_id, seconds, ack}` lets the gateway's
own queue own a chat (a Bot Chat by profile, else a stored id) for `seconds`, its own turn running
there. `forward` queues a text-only send in that queue (`{status: queued, admission_id, forwarded:
true}`, then `session.info {pending_submissions}`, and once the owner's turn ends only
`message.start` and `message.complete` for it; the mock prints `owner: ran a forwarded message` each
time one runs, to count them); a photo can't join it (4090 `SESSION_OWNER_BUSY`, "an image cannot
join its queue, so it was removed from this message", the photo unstaged). `ack` makes the owner
answer that late, and past 30 s it is `SESSION_OWNER_UNCONFIRMED` while the message still runs, as
mode `unconfirmed` does at once. `busy` (`SESSION_OWNER_BUSY`), `ledger-unknown`
(`SESSION_NOT_OWNED`, "outcome-unknown work in the gateway's durable queue"), `coordination`
(`SESSION_COORDINATION_UNAVAILABLE`) and `no-reason` (a bare 4090) refuse with Hermes's words;
`unknown-reason` refuses with a reason no Hermes sends yet, for a reason newer than the app; `off`
lets go. `POST /api/mock/limit {seconds, active, limit}` puts Hermes at its chat limit
(`MAX_CONCURRENT_SESSIONS`, "(3/3)") for `seconds`.
A message queued behind a running turn joins a text-only head while nothing waits behind it, and
anything with a photo is its own envelope; each gets a stored row marked `_queued_prompt` at accept,
swapped for the turn's own row when it drains and left as it is when Stop empties the queue, as
Hermes does. Every refusal but the owner's busy one leaves staged photos for the next prompt, as Hermes does,
until `image.detach` takes them back by the `path` `image.attach_bytes` answered, and a turn takes
what was staged for it. A message that is exactly "stop talking" answers `{voice_stopped: true}`.
Files attach as on Hermes, and the backend log prints each one's name and size as it arrives
(`file.attach`, `pdf.attach`, then the `@file:` references `prompt.submit` carried). A file whose
name has "refuseupload" is refused as a full disk would be (5028 `[Errno 28] No space left on
device`), "toolarge" as over the 256 MB cap, and a PDF named with "nopdftoppm" as on a gateway
without poppler (5028), so it goes again with `file.attach`. `POST /api/mock/close-sessions` closes
every idle chat's session as another client's `session.close` would, with the sockets left up: the
next upload or prompt on it answers 4001 "session not found", and the app resumes and sends again.
`--hermes-version` (default 0.21.6) is the version `/api/status` reports; before 0.23.1 the socket
closes with 1009 on a message over 16 MiB, as uvicorn's did, so a file over about 12 MB never arrives.
`session.steer` refuses 4010 "agent does not support steer" in a turn's first half second (its
agent being built; 6 s when the message says "cold start", as on a loaded Mac) and answers `rejected` when idle; while Hermes compacts the chat (a "snapshot"
message with "compact", or a Bot Chat's "slow … compact", compacts for 8 s after its first step,
`status.update` kind `compacting`) a steer or redirect is held for the next turn and answered
`queued`; `session.interrupt` empties the queue held for
the next turn. A turn stopped while a card waits (an approval, a question, a password) ends as on
Hermes: the card is withdrawn (`request.cancel` with the card's own method, reason `interrupted`)
and the turn ends `interrupted` with no reply stored. On the API server mock a chat's runs go one at a time: a run posted behind another
answers `started` but sends nothing and reads `queued` until it runs, `POST /v1/runs/{id}/steer`
answers `{accepted: true}` (and `run.steered`) or 409 `run_not_accepting_steer` for a run that isn't
running, an unread steer comes back as `pending_steer` on `run.completed`, Stop on a queued run
cancels only it, Stop while an approval waits settles it (`approval.settled`), stores the step with
its blocked result and ends the run `cancelled` without a reply, and the same `Idempotency-Key` replays its run (409 `idempotency_key_conflict` with
another body). The API server's caps refuse as Hermes's do: past `max_runs` runs live at once (Hermes's
default is 10) a new run is 429 `rate_limit_exceeded` "Too many concurrent runs (max N)" with
`Retry-After`, and past 32 runs queued in one chat it is 409 `queue_full`, its message the bare
reason; `POST /api/mock/run-caps {max_runs, queue_max}` on the gateway mock lowers them to hit. `python3 -I -m unittest discover -s Tools/mock-hermes/tests -p test_sending.py`
proves each of these against the mock.
`POST /api/mock/hold {profile, seconds, surface, age, late}` holds a Bot Chat with nothing stored:
`age` minutes ago (45 reads as a terminal, 0 as a one-shot booting), `surface` `cli` or
`desktop`; `late: true` takes the next send, stores it and refuses the turn as it runs instead (the
`error` event shape). `POST /api/mock/held-notice {profile}` is a turn Hermes starts itself there
refused the same way (`message.start`, then `error`), as the notice of a finished process was on
2026-10-21. `-HERMES_PUSH_OPEN botreply:<profile>` opens a reply's notification for that Bot 20 s
after launch, as a tap would, and `-HERMES_PUSH_OPEN chatreply:<profile>:<session>` one about that
chat, tagged with that profile, 8 s after launch (`chatreply:researcher:api_1760_welcome` is a chat
the list holds; on the Mac it goes through what a click on the Mac's own notification runs).
`-HERMES_FACE_CANVAS YES` draws every Bot face instead of playing resting faces on layers
([bot-faces.md](bot-faces.md) §3), to compare the two. Live indicators ([chat.md](chat.md) §4a):
"ponder" thinks for about 14 s before a word (the live line's "Thinking… · 12s"); in the group
chat (`-HERMES_OPEN group:launch-crew -HERMES_GROUP_SEND "… together"`) "together" has Research
Buddy, Ada and Ops think at once. `-HERMES_MOTION_PROBE YES` puts the number of shimmers sweeping on
screen in a near-invisible `motionProbe` element for the UI tests, `-HERMES_GALLERY indicators`
shows every indicator (with `-HERMES_GALLERY_LOOK …+reducemotion` for Reduce Motion), and
`-HERMES_SHIMMER_TIMELINE YES` draws the shimmer from a `TimelineView` instead of its layer, to
measure the two. `--slow-status SECONDS` answers `/api/status` that late, and past 30 s with a 502
at 30 s, like a proxy in front of a dashboard on an overloaded Mac: the Bots still connect.
`--turn-isolation SECONDS` stores a turn's message that long after the turn starts, as Hermes does
with `dashboard.turn_isolation`: only the live session (`inflight`) has it meanwhile, so a second
device on the same chat shows whether it reads it from there ([chat.md](chat.md) §2).
`--slow-history SECONDS` answers stored chats' messages that late while the socket keeps up, as
a dashboard on an overloaded Mac does: a message sent meanwhile goes out before the history comes
([connecting-and-voice.md](connecting-and-voice.md) §8).
`POST /api/mock/read {chats, rooms, device_id?}` plays chats read on another device (the plugin's
`read`: read pushes to devices away from the app, badge pushes, the `read` list in later notices),
`POST /api/mock/badge {badge}` sends every device a badge-only push now, a chat deleted or
archived on the mock gateway (`DELETE /api/sessions/<id>`, `PATCH … {archived: true}`) plays the
plugin's `on_session_delete` (plugin 1.4.7: off every device's badge, with its badge and read pushes), and
`GET /api/mock/push-state` shows what the push mock recorded (presence, reads, what each device was
sent and cleared, badge records, the open requests and their count). Like plugin 1.4.8, the open
count leaves out a request past its deadline, one six hours old without one, and one whose turn a
restart killed (`/api/mock/restart-gateway`), and an API server run's approval goes when it settles
(answered, stopped or timed out). `POST /api/mock/push-reply {session_id, text, delay?}` sends a
reply's notice as if its turn ran long; `delay` sends it that many seconds after the reply landed, as
a slow end of turn does, so a read on another device meanwhile shows that it notifies and counts
nothing (plugin 1.4.6). A Bot's message in a group chat notifies 5 s after it lands, like the
plugin's (with Bots set to All). `POST /api/mock/sync {sessions}` sends every registered device a `sync` push now, and
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

Bot photos after memory pressure ([bots-groups-skills.md](bots-groups-skills.md) §1):
`-HERMES_EVICT_FACES <s>` empties the decoded image caches that many seconds after the first
image lands, as memory pressure does. Every face showing a photo draws the Bot's own face, and the
roster fetches each photo again once (one more `profiles.get_asset` per Bot in the mock's log).

Removed gateways' web data (`docs/connecting-and-voice.md` §7): `-HERMES_WEB_STORES_LOG YES`
prints one `WEBSTORES` line at launch with the stores WebKit has before and after the sweep, the
ones it deleted and the ones still waiting, even when nothing waits (without it, such a launch
doesn't touch WebKit).

Measuring a cold launch (same build): `-HERMES_LAUNCH_LOG YES` prints each launch step once with
its time since the process started (`LaunchTrace`: the model, the first view, the kept chats, the
window turning visible on a Mac (its first frame), the first chat row on screen, Bots and last
lines, the gateway's answer, the socket, the fresh lists, each row's last line), and the chat load
steps above with it. `--many-chats N` on either mock adds N ordinary chats (every fifth with two
unread replies), for a list as long as a well-used gateway's. With `--sparse-chats` they come
mostly from Telegram and Discord: each page of 50 holds one or two of this app's chats and one
scheduled run, for the end of a list that loads under This App or Scheduled Tasks.
`--routine-runs` (on `server.py`, or on `backend.py` with `--gateway-port`) adds two routines that
ran every 10 minutes over the last day, as Hermes's scheduler leaves them: 288 untitled chats with
source `cron` and ids `cron_<job>_<YYYYmmdd_HHMMSS>`, most of them empty. "Watch the inbox" said
something every sixth run, "Watch the website" every 47th. All Chats shows none of them, Show →
Scheduled Tasks only the ones with something in them, and the tasks' recent runs the same
([inbox.md](inbox.md) §5, [tasks.md](tasks.md) §5).
With `-HERMES_SEARCH` and `-HERMES_SEARCH_OPEN YES`, `-HERMES_SEARCH_AFTER <s>` waits that long
after launch before typing, and the load log marks `search result opened` for the chat it opens. `-HERMES_RESTORE bot:ops` (or `session:<key>`) opens as if the
window had been showing that chat; with `-HERMES_OPEN bot:ops` (or `-HERMES_OPEN_SESSION <key>`)
too, it's the launch where the Mac's detail once missed the selection
([bots-groups-skills.md](bots-groups-skills.md) §1.2). A Mac window behind other windows isn't drawn, so its chat
doesn't load until it's in front; measure the open chat on the simulator. Kill the app between
launches, and launch twice: the first after a build pays for loading the new binary.

Where a Mac cold launch stood on 2026-11-17 (Debug at `-O` whole module; restored at launch, a
300-turn chat with headings, code blocks, tables, lists, images and tool steps, seeded from a
scratch copy of `backend.py --long-chat` as in Measuring a scroll back below; `--many-chats 200`;
20 base launches over 4 batches, the last 3 interleaved with each lever; 82 to 83% memory free,
thermal nominal, load 6 to 16): settled 1163 ms median (1084 to 1238), first view 450, window on
screen 832, open span 553, main CPU 1.02 s. Three levers measured within that range and were
reverted: reading and building the restored chat's kept copy while the window goes up (1146),
showing it in the window's first layout (1134, but the window waited until 1129 and the first
measure cost more), restoring the selection on appear instead of in a task (1152). What remains is
serial main-thread work (Time Profiler, 1 sample = 1 ms): from first view to window, 305 to 320
samples, of which the hosting view's layout 128 to 141, the toolbar 43 to 45 and the sidebar's
row heights 14 to 29; then the transcript's first measure, `RowEdges` 89 to 95 (tables 20 to 24,
text selection 17, TextKit 13). Reordering the two doesn't help; one of them has to get cheaper.

The frame log's times count from the process's start, with marks for the root view, the first
frame and the open chat showing (`chat showing`), and each mark carries the main thread's CPU so
far: a cold launch reads straight off it. `-HERMES_SCROLL_RUN <rounds>` scrolls the open chat from
its end to its top and back, `-HERMES_SCROLL_SPEED` points a second (2000 by default), starting
`-HERMES_SCROLL_AFTER` seconds after launch (10), only up with `-HERMES_SCROLL_LEGS up` (to send,
jump to the end or let a turn end from far back): a step a frame, taken by the chat as a drag, so
pages come in at the top and go below as they would under a finger. Each leg is marked
(`SCROLLRUN`, and in the frame log on iOS). It works on the Mac too, where each leg's mark says
whether the window is on screen or covered, and a change mid-leg is marked (`window covered`): a
covered window gets no frames, so a run with one measures nothing. With `-HERMES_SCROLL_LOG YES`
the window's changes show between the per-frame offsets (`SCROLLLOG drop below`, `later in`,
`drop above`, `back above`, `earlier page`) with each step the run set (`SCROLLRUN set`): across
every change but a new earlier page the offset must stay where the run put it. Each step also says
where the run found the chat (`from`), and each row logs its top in the content as it moves
(`SCROLLLOG row`). Between two steps the first row on screen moved by its top's change less the
offset's change the chat made itself: that stays within 2 pt, across an earlier page too.
`SCROLLLOG at the first message` marks the run reaching the chat's first message, and
`waiting at the edge` and `moving again` the run waiting at an edge for rows (up to 4 s; a leg
stops after 150 s). On the Mac, `-HERMES_SCROLL_WHO YES` logs each move of the chat the run didn't
make, with who made it (`SCROLLRUN chat moved`, from where to where, and the call stack).
`-HERMES_SCROLL_THEN_JUMP <s>` (with `-HERMES_SCROLL_LEGS up`) jumps to the end that long after
the run, as ⌘↓ would, and `-HERMES_SEARCH_OPEN YES` (with `-HERMES_SEARCH`) opens the first result:
both reach on the Mac what a tap or a key would, without taking over the screen.

In a group chat, `-HERMES_SCROLL_LOG YES` logs each poll that brings events (`GROUPLOG model`,
with the room's item count) and the transcript's geometry (`GROUPLOG geometry`, with the content
and container widths and the sideways offset `ox`). A room that opens right rests at its end within
about a second of its items arriving: the visible rect ends at the content height plus the bottom
inset, and `ox` stays 0 ([bots-groups-skills.md](bots-groups-skills.md) §2). A room message
with "holdsend" in it gets no answer for 60 s, so it stays on its way and is kept on the device:
quit then, and the next launch opens the room with it (`-HERMES_GROUP_SEND "holdsend …"`).

Measuring a streaming reply: "essay" streams a long Markdown reply for about ten seconds, and
`-HERMES_SEND_HERE "essay please" -HERMES_SEND_HERE_AFTER 10` sends it into the chat that opened.
The frame log works on the Mac too, and marks the send (`send-here: sending`) and the reply's end
(`reply ended`): the main thread's CPU between the two marks, and the busy frames logged between
them, are what one streamed reply costs. A streamed word should redraw only its reply's row
([chat.md](chat.md) §4): to see what else does, and why, put `let _ = Self._printChanges()` at the
top of the views' bodies in a scratch copy and count the lines while it streams (Instruments'
SwiftUI template doesn't record on a simulator). The environment tells values apart by their
contents, not by `==`: hand rows the same value when nothing changed (`stableReferences`).

Measuring a scroll back: use a chat long enough that reading back loads page after page.
`backend.py --long-chat` seeds "Homelab rebuild" with `seed_long_chat()`, 60 turns; for a few
hundred turns with headings, lists, code blocks, tables and tool steps, raise its `turns` and add
those blocks to its replies in a scratch copy of the mock. Open the chat with
`-HERMES_RESTORE session:<key>` and scroll it with `-HERMES_SCROLL_RUN 1 -HERMES_SCROLL_SPEED 3000`
`-HERMES_SCROLL_AFTER 14 -HERMES_SCROLL_LOG 1` (the log marks each page it loads). On the Mac,
build Debug (the launch flags need it) with `SWIFT_OPTIMIZATION_LEVEL=-O`
`SWIFT_COMPILATION_MODE=wholemodule`, and run a copy with its own bundle id and
`CFFIXED_USER_HOME`, so it keeps its own data and never meets the Hermes you use. A leg's cost is
the main thread's CPU time over its wall time between its `SCROLLRUN` marks (`ps -M -p <pid>` at
each mark): its busy share. An app in a simulator is a process on the Mac, so the same reading
works there. Note the pages each leg loads (`earlier page`), the time to the top and the footprint
before and after. One run is noise: compare a change with the build before it in interleaved pairs
(B F F B B F F B B F, after an unmeasured run of each to warm caches, each run from the same copy
of its home), with the load average and `memory_pressure -Q` noted for each run, and report the
median and range. To see where the time goes, run `sample <pid> 30 1 -file <out>` from a leg's
mark (a run apart from the measured ones: the sampler costs time), and read the main thread's own
call graph. Most of a scroll's time is SwiftUI's attribute graph rather than any one body, so
count what changes it: how many views each settled message builds, and how many stay in the
window while it moves.

Background processes (`Tools/mock-hermes/processes.py`, [background-processes.md](background-processes.md)),
in Bot Chats and normal chats: "release" with "docs" (or "processes") starts a Docs site that runs
on and a Release build that exits 0 after ~35 s with no event, and closes the Docs site's tab
mid-build (`terminal.close`); "trailhead" or "deploy log" sends a message to Ada that fails with a
JSON error and tails the deploy log; "background tasks" ends five checks and stores their
completion notices as Hermes does (above). Output carries ANSI codes, `\r` progress and Hermes's CWD
marker. `POST /api/mock/processes/exit {process, code, reason}` ends one (by id or a word of its
command) with no event, `…/close {process}` sends `terminal.close`, `…/reset` forgets them, and
`…/deliveries {persist}` lists later `message_agent` deliveries with `persist_on_release` (Hermes
with upstream #136220) or without (Hermes 0.22, the default), for Settings → Setup's Bot-to-Bot row.
`-HERMES_SEND_HERE <text> -HERMES_SEND_HERE_ROUNDS 1` sends it once into the open chat.
`-HERMES_SEND_HERE_CHAT <id>` sends into that chat instead, open or not.
In a Bot Chat, "links" answers with addresses written out every way agents write them (bare on a
line, in a sentence, `www.`, a Markdown link, `localhost`, one in code) to check that they open.
"clarify dose" (a Bot Chat or a Hermes chat) asks a long question with three short picks, as a Bot
does after a photo of a supplement box; "clarify open" in a Bot Chat asks one in words; "clarify
twice" asks two at once (parallel tool calls). Each runs as a clarify step ("Asking a question"),
as in Hermes, and "… later" (a Bot Chat) asks 4 s after the message, so it arrives while you type
the next one (the dock, `docs/quick-actions.md` §1).
"clarify pair" (a Bot Chat or a Hermes chat) asks two questions in one card, the first with a long
pick; `-HERMES_CLARIFY_STEP 2` opens such a card at its second question with the first answered
by its first pick, so its one-line summary shows without a click (the Mac).

Bot Mode's numbers ([inbox.md](inbox.md) §5, [bots-groups-skills.md](bots-groups-skills.md) §2):
`backend.py --group-counts` adds two group chats to Launch crew. Ada and Ops are in all three.
"Design review" has four members: Ada, Ops, Scout (hidden in the mock's roster) and Intern, a
member whose Bot no longer exists (Hermes keeps a room's members as created). "Release log" has
199 events, so the next discussion in it lands past seq 200: `POST /api/mock/room-say
{"room": "release-log", "text": "…"}` (with `X-Hermes-Session-Token`, printed at start) should
show a count of 4 on its row, one for each member's message. The same post to `launch-crew` is the
short room to compare it with. An optional `"reply": "…"` sets what the last member says in the
second round, so each post leaves a newest message of its own (the row-line check in
[bots-groups-skills.md](bots-groups-skills.md) §4). `POST /api/mock/routine-elsewhere
{"profile": "writer"}` gives Ada unread routine news that leaves the rooms alone, and `POST
/api/mock/drop-sockets {}` reconnects without moving any count. Mute a Bot or a group from its
row's menu, and turn Bot Mode off and on in Settings, to check that a muted row keeps its grey
count and every badge returns as it was.

Widgets (`Tools/mock-hermes/widgets.py`, [widgets.md](widgets.md) §13) play the
hermes-app-widgets plugin over both servers: "widgets" pages through every example (three per
reply, "widgets 2"…), "widget <type>" shows one type's examples, "widget <name> <name>…" those
examples by name in that order ("widget route-4 route-1 weather-1"), "widget publish" an approval
without Face ID, "widget lunch" one with it, "widget expiring" one that expires in 60 s, "widget
silent" one whose first answer gets no update (Try Again), "widget private", "widget gateway
image" (pictures the Bot keeps on its gateway, `hermes-file:`: a media card, a guide step and a
flashcard with one, then the reply's own Markdown image of the first file at a home path; the
backend's `/api/fs/download` serves them as PNGs drawn in `inspector.py`, answers 404 "File not
found" for a missing file and 403 "Path is outside the managed read boundary" outside the
project), "widget private image" (the same, private), "widget missing image" (a media card whose
file isn't there), "widget media" (a gateway video with its poster and a grid of twelve
screenshots, each with Open; the backend's `/api/files/stream` serves `media/walkthrough.mp4` with
Range reads and checks `profile`), "widget media refused" (the "Old recordings" grid: a video and a
picture that are gone, a picture over 50 MB, a video and a picture that are private, a broken
video, and an https video on another host that asks first), "widget media web <port>" (a card whose
video is on an https site that isn't the gateway, at `https://localhost:<port>/clips/launch.mp4`,
with no poster; the site is `Tools/mock-hermes/media_site.py`, below), "widget fence" (an
agent-typed block, shown as code), "widget refused" (a refused create whose reply names the widget
anyway, with a comma between the directive's attributes) and "widget refused inline" (that reply in
one message with the call), "widget routine" in a Bot Chat (the Bot's Daily plan routine runs now
and its report arrives with the widget; "widget routine json" when its agent typed the payload as a
json block, as plugin 1.4.0 delivers it, "widget routine json old" as 1.3.0 left it, "widget
routine broken" when the payload stops halfway, "widget routine directive" and "widget routine
missing" when the Bot's reply names a stored widget or one never stored), "widget unknown", "widget
invalid", "widget suggestions" and "widget wide" (everything long in one reply: a long inline code
path and name, a wide code block, a details card with long labels, values and a long state tag, a
snippet and an output with lines of over 200 characters; nothing in it may widen the reply,
[chat.md](chat.md) §3) and "widget wide table" (a table with long headings, text and mono values
and a long state tag). "Weather today?" (any message with "weather" or "forecast") is what an agent
told about widgets does: it looks the forecast up, reads the weather examples and answers one
sentence and the weather card. Over the socket, a chat the app didn't mark gets each widget's plain
text instead, as on a real gateway. In a Bot group chat the app marked, the same words make Ops
answer with an inline block. `POST /api/mock/widget-answer {id?, action, device?, hold?}` answers
the newest widget from another device; `--no-widgets` leaves the plugin out. `/app-widgets client`
(which app sent a turn, [widgets.md](widgets.md) §11) answers as plugin 1.6.0 does, refusals
included; `--widgets-version 1.5.0` (either server) plays the plugin before it, where `client` is
an unknown command and `status` says 1.5.0. On a simulator, enrol Face ID with `xcrun simctl spawn
<udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` (then `-p` the same name) and pass
a check with `notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.

UI tests (`HermesUITests`, `UITests/`) run against the mock: start it first, then
`xcodebuild test -scheme HermesUITests -destination 'platform=iOS Simulator,name=…'`
(other ports: `HERMES_MOCK_GATEWAY=… HERMES_MOCK_BACKEND=…`).

With `--gateway-port 18642` the backend also has projects (`Tools/mock-hermes/projects.py`): the
design's Hermes App, Homelab, Blog, Hermes Agent fork and dotfiles, an archived Portfolio written
by the desktop app, and the found repos caffeinated-site and pantry. "Fix the reconnect after
sleep" runs a long test turn so Hermes App shows as working. Activity moves without a message there
too: zsh startup time (dotfiles, last spoken in 32 days ago) had a heartbeat 7 minutes ago, and Post:
Building Hermes for iPhone (Blog) was compacted 25 minutes ago; search for "zsh" or "outline" to see
their results' times, and All Projects to see dotfiles stay last. Debug flags: `-HERMES_OPEN projects`,
`-HERMES_OPEN project:p_4f2a9c1e` (`-HERMES_PROJECT_LANE <lane id>`, `-HERMES_PROJECT_EXPAND <id>`),
`-HERMES_OPEN project-chat:<id>`, and `-HERMES_PROJECT_SHEET new|edit:<id>|move:<session>|runin`.
A project with "readonly" in its name can be renamed but not changed: Archive, Restore, Delete
and Add Folder answer 5061 "attempt to write a readonly database", as Hermes does when it can't
write its projects.db.

Unread and live activity (`Tools/mock-hermes/inbox.py`, `docs/inbox.md`): the gateway's chats keep
Hermes' read mark (`last_read_at`); seeded, Release prep has 3 replies since it was read, Morning
briefing 1, and Stand-up summary is marked unread. The dashboard's `GET /api/sessions` carries
`unread`, `last_read_at` and `last_active` (the API server's rows don't, as in Hermes), and
`session.active_list` says starting, working, waiting or idle with Hermes' preview. `--inbox-demo`
makes Swift 6 migration plan look like it keeps writing (a 40 s cycle) and Disk cleanup on the NAS
wait on an approval, for screenshots. Read marks change by `PATCH /api/sessions/{id} {unread}` on
either server; `GET /api/sessions/{id}?profile=default` on the backend shows one. A chat a launch
opened with `-HERMES_OPEN_SESSION` opens at its New Messages line when it has news.
The list starts with this app's chats; the seeded Telegram, Slack, Discord and CLI chats and the
scheduled run "Morning briefing · …" (`cron`) show under the filter's Show (`docs/inbox.md` §5).
`-HERMES_INBOX_SHOW all|otherPlatforms|scheduled` starts the list there.
`VoiceOverFocusUITests` turns VoiceOver on inside the simulator, puts it on a row or a message, and only then
starts a "slow marathon" turn: in the open chat, or in a chat listed below the row, which moves above it. Each
test checks the reply landed while it listened and that VoiceOver stayed put (about 3 minutes each).
Activity moves as in Hermes, not only with messages (`docs/inbox.md` §2): a Bot Chat's
`last_active` is its heartbeat, a Bot's `last_session` is any of its sessions but workers, and a
compaction stores its summary as the newest row. Seeded, Ada's routine ran silently 7 minutes ago
in a `cron` session of its own, Ops' Bot Chat and the chat Release notes draft were compacted with
nothing after, and `session.compress` stores a summary too.

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
preferences, caches, web data and saved state, the folders older Mac builds kept straight under
`~/Library/Caches` and `Application Support` (Transcripts, Sessions, Outbox…), crash reports and
the mock's output. It prints where a value turned up (by line number, never the value) and
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

A gateway behind an access gateway (`Tools/mock-hermes/access_gateway.py`,
[connecting-and-voice.md](connecting-and-voice.md) §11): a stdlib reverse proxy, one port per mock
behind it, that passes calls, event streams, socket upgrades, uploads and downloads once they carry
the service token's two headers, and drops those headers before the mock sees them. Without them a
request that accepts HTML is redirected to a sign-in page on another origin (`localhost`, at
`--sign-in-port`), and anything else gets a 403 HTML page, as Cloudflare Access does. It logs one
line per request with its kind and whether the token, its cookie and Hermes's key came, never
their values. A token pass sets a `CF_Authorization` cookie that later requests pass by, as a page's
images do. `GET /__mock/leave`, once let in, redirects to the sign-in origin's `/__mock/left`,
which logs whether the token followed; "preview <address>" in a chat opens an address in the
Preview, so "preview http://127.0.0.1:20642/__mock/leave" checks that the Preview leaves it behind:

```bash
python3 -I Tools/mock-hermes/backend.py --port 21119 --gateway-port 21642
python3 -I Tools/mock-hermes/access_gateway.py --route 20642=21642 --route 20119=21119 \
    --sign-in-port 20999 --log "$TMPDIR/access.log"
```

Pair with `http://127.0.0.1:20642` (Bot Mode at `http://127.0.0.1:20119`), then set Access to
Service token with `mock-client.access` and `mock-secret-0123456789abcdef` (`--client-id`,
`--client-secret`). A Debug build launched with `-HERMES_BOOTSTRAP_ACCESS_ID <client id>
-HERMES_BOOTSTRAP_ACCESS_SECRET <secret>` next to the other `-HERMES_BOOTSTRAP_*` flags starts with
that token set. Its tests: `python3 -I -m unittest discover -s Tools/mock-hermes/tests -p
test_access_gateway.py`.

For Browser sign-in, choose it in Access and Sign In…: the mock's sign-in page is a form on the
sign-in origin that takes any email (no identity provider). It sends the page back through the
route's `/cdn-cgi/access/authorized`, which sets `CF_Authorization` (a JWT-shaped token with the
email and `exp`) for that route's origin and redirects to where the page was going. Sessions last
a day; `--session-seconds 60` makes one run out a minute after signing in, refuses its cookie
from then on, and cuts a stream or socket it let in, so "marathon" in a chat (over a minute of
steps) shows a sign-in running out mid-reply. Sign In… in the chat's banner signs in again and
the reply carries on. A Debug build launched with `-HERMES_BOOTSTRAP_ACCESS browser` starts set to
Browser sign-in, signed out.

A proxy that asks for a client certificate (`Tools/mock-hermes/mtls_proxy.py`,
[connecting-and-voice.md](connecting-and-voice.md) §11.9): a stdlib TLS proxy, one port per mock
behind it, that turns away a device without a certificate its own CA signed. It makes a throwaway
CA and certificates with `openssl` at start (`ca.pem`, `issuing-ca.pem`, `client.p12`,
`expired.p12`, `other.p12`, password `hermes-mock`), keeps them in `--certs` only, and logs each
certificate it verified or why it refused one. The device certificates come from the issuing CA
and the proxy trusts `ca.pem` alone, so the `.p12` files carry the issuing CA with them. Each
request gets a connection of its own; `--keep-alive` keeps connections open and asks for the
certificate once per connection, as a real proxy does, which shows whether a check of another
certificate goes on a connection of its own. `--tls-max 1.2` checks the older handshake:

```bash
python3 -I Tools/mock-hermes/backend.py --port 27119 --gateway-port 27642
python3 -I Tools/mock-hermes/mtls_proxy.py --route 25642=27642 --route 25119=27119 \
    --certs "$TMPDIR/mtls" --log "$TMPDIR/mtls.log"
```

Pair with `https://127.0.0.1:25642` (Bot Mode at `https://127.0.0.1:25119`). A simulator trusts
the CA with `xcrun simctl keychain <UDID> add-root-cert "$TMPDIR/mtls/ca.pem"`. Never add it to a
keychain on the Mac: a Debug build there trusts it with `-HERMES_TRUST_CA <path to ca.pem>`, for
that process alone, and `-HERMES_MEMORY_CERTIFICATES YES` keeps imported certificates in memory
instead of the Keychain. API keys and the other secrets need no flag: a Mac Debug build without a
keychain entitlement keeps them in memory for that run and never reads or writes the login
keychain, so a keychain password dialog means something is wrong. Quit the app by its PID and
leave the dialog unanswered. `-HERMES_BOOTSTRAP_CERTIFICATE <path to client.p12>
-HERMES_BOOTSTRAP_CERTIFICATE_PASSWORD hermes-mock` next to the other `-HERMES_BOOTSTRAP_*` flags
starts with the certificate set. Put `access_gateway.py` behind the proxy to need a token and a
certificate both. Its tests: `python3 -I -m unittest discover -s Tools/mock-hermes/tests -p
test_mtls_proxy.py`.

A press site for "widget media web <port>" (`Tools/mock-hermes/media_site.py`,
[widgets.md](widgets.md) §9.3): it serves one video over https with Range reads, using the
proxy's server certificate from the same `--certs` folder. `--rate <bytes a second>` slows each
answer, so a seek lands while a read is still coming in, and the log says how far each read got
before the app let it go. `--ignore-ranges` answers every read with the whole file (200), which
the app refuses. A Debug build on the Mac trusts the site with `-HERMES_TRUST_CA <certs>/ca.pem`:

```bash
python3 -I Tools/mock-hermes/media_site.py --port 24443 --certs "$TMPDIR/mtls" \
    --file Tools/mock-hermes/media/sample-clip.mp4
```

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
pushed page's back button), `key cmd+[`, `menu <title>` (a menu bar menu's items and shortcuts,
which a locked or off-Space screen can't capture), `frame <width> <height>` (resizes the chats
window), `item View > Show Sidebar` (chooses a menu item), `mainkey esc` (Esc in the chats window),
`mainkey cmd+r` (⌘R there, then the menus, which answer from the key window's focused values),
`mainkey tab|up|down|left|right|return` (typed into the chats window, as the project home's lanes
read them), `key cmd+r` (⌘R in the Settings window, then the menus, as Setup's Check Again answers),
`sidebar` (the sidebar button's action), `select group:<id>` or `select bot:<name>` (that sidebar
row, as a click on it would, to leave a chat and open it again in one launch), and `dump` / `views`
to see what's there (`maindump` the chats window's accessibility tree). For the ⌘K palette
(`-HERMES_PALETTE <text>` opens it in each
chats window once connected, and fills its field with that text each time it opens): `paletteopen`
(⌘K in the first window), `palettekey up|down|return|esc|space|cmd+return|cmd+1` (any digit; a ⌘
key goes to the window's key equivalents, then the menus, as the app routes one), `palettetype
<text>` (one key per character, so it goes through the field editor as typing does; `palettekey
space` types a space), `paletteblur` (takes the field out of editing, as a click elsewhere does)
and `palette` (logs the field's text, whether it's being edited, its field editor's text
replacement, spelling correction and spell checking, and the chats windows with their titles, which
name what each shows; the rows and the selection aren't in it, so read them from a screenshot or
the accessibility tree). Each step logs `HERMES_MAC_DRIVE` with the Settings window's title, so the
page shown can be checked without a screenshot (`App/Support/MacDebugDriver.swift`), on standard
output and in `-HERMES_MAC_DRIVE_LOG <file>` when it's given; `tabs` logs how many Settings tabs
show, of how many, and `maintabs` which of the chats window's toolbar items show. Capture with
`screencapture -x -o -l <window id>`. `-HERMES_SETTINGS_TABS_START <width>` starts the Settings
tabs' width too narrow, to watch the toolbar check widen it. `-HERMES_LAUNCH_AGENTS_DIR <folder>`
points Run at Full Priority (Setup → Priority) at a stand-in LaunchAgents folder and only logs its
`launchctl` calls (`HERMES_LAUNCHCTL …`); the mock's `throttled-here` and `priority-here` states
use `build/mock-launch-agents`. The main window's bars (the sidebar's footer, the composer) don't
draw in an off-Space capture, so `-HERMES_GALLERY priority` shows the footer with its priority
notice (at the sidebar's narrowest and usual widths, and with large text where SwiftUI scales it)
and the update's result for the connected gateway; `priority:update` updates Hermes first, and
`priority:update:fix` then runs Run at Full Priority (docs/setup.md §4.17). With `priority-here`,
`priority:update` shows the app putting the gateway back at full priority by itself, and
`priority:restart` does the same after Plugins' Restart Gateway (the mock's plist in
`build/mock-launch-agents` says Interactive again; pointed at another folder, it stays without).
`priority:states` draws each of the Mac line's states (`macPriorityNotice`, its next start,
restarting and restored variants, and the connection alone) at the same widths and sizes from
sample reads, with no Bot Mode. `-appearance light` or `dark` picks the gallery's look,
`-HERMES_GALLERY_LOOK light+contrast` or `dark+contrast` adds Increase Contrast, and
`+reducemotion` (`light+reducemotion`) Reduce Motion, which holds the restarting spinner still.

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
drafts, and the Bot Screen over RFB (`display.*`, `WS /api/display/ws`) with the lease, running from
the start so a Bot Chat with no Inspector tabs has one to open from its ··· menu. Its chat
"Pricing card" has two versions of an HTML artifact. In a chat, "… sign-up" or "… beta" writes the
page, starts `npm run dev`, opens it in the Preview and drives it (`preview.act`, `preview.read`);
"pricing" adds an artifact version; "terminal" reads the Terminal. Mock-only: `POST
/api/mock/inspector/screen {action: evict|stop|start}` (close codes 4000 and 4001; Start Screen
in the app is `display.start`), `{action: uninstall|install|unsupported|supported}` (the Screen's
setup states, [setup.md](setup.md) §4.21), `GET …/screen/keys` (the keys the screen received
during Take Control, and what they typed into its sign-in form; `POST` clears them),
`…/gh {authenticated, available}`, `…/touch {path, text}` (a change on the gateway), `…/dev
{running}`, `…/pace {seconds}` (slower driving, for screenshots) and `…/turn {session, text}`.

And What Hermes Learned (`Tools/mock-hermes/learned.py`), shaped like the gateway's
`/api/learning/*` and curator: eleven skills (two new this week, one stale), memories spread over
three months, three archived skills and a last tidy two days ago that merged two skills into
ios-testing. `/curator pin|unpin|restore|list-archived|usage` answers through `slash.exec` with the
CLI's words, Tidy Up Now takes 6 s and merges the least-used skill that isn't kept as is (and sends
the tidy's notification), and a chat message with "skill" writes commit-message-style with
`skill_manage`. `POST /api/mock/learned/reset` puts it back, and `POST /api/mock/learned/graph
{mode}` gives the graph another shape: `used-only` (only skills Hermes used, none it wrote, no
memories), `empty` (Nothing learned yet), `fail` (the read refused with 500, Settings → Memory's
too) or `full`. Debug flags: `-HERMES_PUSH_OPEN tidied` (a tapped tidy notification), and
`-HERMES_OPEN learned` with `-HERMES_LEARNED map|tidying|skill:<id>|select:<id>|mapselect:<id>`.

And full-text search (`Tools/mock-hermes/search.py`), shaped like `hermes serve`'s
`/api/sessions/search`: "reconnect" matches seven chats across Hermes App's lanes, a task run of
Check NAS backups and Ada's "Release notes draft"; prefixes match ("reconn"), `source`/`profile`
filters work, and replies take 150 ms. Tasks have three recent runs, one failed
(`/api/cron/jobs/<id>/runs`). Debug flags: `-HERMES_SEARCH <text>` types into the chat search
(on iPhone, the chat list's), `-HERMES_PALETTE <text>` opens the Mac's ⌘K palette,
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
`/api/files/stream` like the recordings `file.attach` staged (an "audio digest" is 20 s, enough
to skip through). Voices: GET/PUT `/api/config` keep each
Bot's `tts` and `voice` sections; with `{"direct": true}` voice-config points previews at the mock's
own `/mock-provider/…` (never a real provider), and `GET /api/mock/audio/turns` lists them. Setup:
`GET /api/env` lists the voice keys per profile; `{"env_refusal": "…"}` makes `PUT /api/env` refuse
with Hermes's 400; `{"tts": "broken"}` makes the gateway's voice fail so Talk and Listen say why.
voice-config answers Hermes's verdict for the profile's providers (set them with `PUT /api/config`);
a provider without credentials is refused as Hermes refuses it (`speak` 400, `speak-stream`
`fallback`, `transcribe` "No STT provider available. …"). `{"xai_oauth": true}` signs the gateway in
to xAI Grok (`GET /api/providers/oauth` lists `xai-oauth`): with `tts.provider` and `stt.provider`
`xai` and no key, it speaks and transcribes voice messages, never live.
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
`-HERMES_IME <script>` composes words in the open chat's composer as an input method does,
`-HERMES_IME_AFTER <seconds>` after it appears (8), each letter left marked while the composer
redraws. `nihao>你好` marks n, ni… then chooses 你好; `dajia>` leaves its letters marked; `|2`
puts the caret after the second character. `IMELOG` lines give the field, caret, marked text,
draft and how often the draft was written over the field; `-HERMES_IME_LOG <path>` saves them.
With `-HERMES_SEND "marathon please"`, `nihao>你好 shijie>世界 |2 dajia>大家` ends at 你好大家世界,
caret 4, while the reply runs (docs/composer.md §5).

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
Voice activity, endpointing and barge-in run on that audio. `-HERMES_SPEAKER_ECHO 25` adds a
loudspeaker's echo that got past the echo canceller: what the call plays comes back into the
simulated microphone that many dB quieter, its words heard by the transcriber as they're said, so
Talk's echo handling can be checked (the Bot's words must never come back as your turn). `-HERMES_REALTIME_LOOPBACK YES`
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

### Hangs

Every build, Release included, keeps MetricKit's hang and CPU exception reports
(`App/Support/HangDiagnostics.swift`). MetricKit hands them over at most once a day, usually on
the next launch after the hang, and only for a main thread blocked about 250 ms or more. Each
report goes through `HangReport` (HermesKit), which keeps the length, the app's version and build,
the system's version and every thread's stack as binary, UUID, offset and sample count: no
addresses, no region, no device, and anything that could carry words is cut to letters, digits and
a few marks. The blamed thread comes first. A report goes to the system log under the app's bundle
id, category `hangs` (its heading and top frames: `log show --predicate 'subsystem BEGINSWITH
"co.caffeinatedcode.hermes" AND category == "hangs"' --last 2d` finds Release and Debug alike),
and whole to `Diagnostics/hangs.log` in Application Support (the app's container on a sandboxed
Mac), newest last, about 256 KB at most. Nothing is sent anywhere. To read a stack, match each
frame's UUID to the build's dSYM (`dwarfdump --uuid`) and look up its offset (`atos -o <dSYM> -l
0x100000000 <0x100000000 + offset>`); frames in system binaries name the framework, which is
often enough. `-HERMES_HANG_REPORT_SAMPLE YES` (Debug) writes one made-up report through the
same path, to see both written without waiting a day.

In Debug, `-HERMES_HANG_LOG <file>` starts a watchdog: a thread pings the main queue every 20 ms
and writes `HANG start=<ms> duration=<ms> main-cpu=<ms>` for each block of 250 ms or more, timed
from the process's start like the frame log. `main-cpu` is what the main thread itself used
meanwhile: close to the duration, it was busy; far below, it waited (a lock, a synchronous call)
or was starved, as a covered window's app is under App Nap on a loaded Mac. The scenarios below
write `MARK at=<ms> <step>` into the same file, and so does each `SCROLLRUN` mark, so a block
reads against what was happening. Count the `HANG` lines and take the longest; five fresh
launches per scenario, the median of each.

The freeze scenarios run in the Mac Debug app through `-HERMES_MAC_DRIVE` (see above), with the
backend mock started with `--token <t>` and the app given `-HERMES_MOCK_TOKEN <t>`:

- `mode chats; scroll sidebar 2000 3`: the chat list from the top to its end and back, 3 times,
  at 2000 points a second (`--many-chats` makes it long).
- `cycle 3 chat:#0,chat:#5,bot:#0,group:#0,…`: opens each in turn for 4 s, 3 rounds. A target is
  `chat:<id>`, `bot:<name>`, `group:<id>`, or `#<n>` for its place in the list.
- `burst 50 5`: `POST /api/mock/burst {count, seconds}` sends that many messages within that time,
  across the newest chats, between Bots and into group chats (every tenth).
- `sleepwake 30`: the sleep notice the app hears from the system, the mock's sockets cut for 30 s
  (`/api/mock/drop-sockets {outage}`), then the wake notice and 10 s after it.
- `mark <text>` writes a line of its own; `window` logs whether the chats window is on screen and
  the app in front. A covered window draws no frames, so a run with one measures nothing.

Start a measured copy with `-NSAppSleepDisabled YES`, so App Nap doesn't slow a covered window's
app, and `-HERMES_LAUNCH_BEHIND YES` (Debug), so it stays behind the app in front. Both are
launch arguments and write nothing to the app's preferences. A binary a shell runs is never
launched in the background as `open -g` is, so AppKit activates it as launching ends and its
first window comes key and front, even as an accessory app. With the flag the copy launches
with a prohibited activation policy, which nothing can activate; once the chats window's first
view is up it becomes an accessory app (no Dock icon, no menu bar) and the window is ordered in
at the back, never key, which the hang log marks (`launch behind: …`). Count the runs where it
came forward anyway: `lsappinfo front` against the copy's own ASN.

The mock calls go only to a `-HERMES_BOOTSTRAP_BACKEND` on 127.0.0.1. SwiftUI's own complaints
read alongside: `log show --predicate 'processIdentifier == <pid> AND eventMessage CONTAINS "tried
to update multiple times per frame"'` counts them for that run.

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
(`writer`) and Scout; `old` has the previous versions everywhere (push 1.1.0, widgets 1.5.0: the
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

