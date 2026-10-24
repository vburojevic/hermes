# hermes-app-widgets

Widgets for the Hermes iPhone, iPad and Mac app. An agent sends a card the app draws natively:
numbers, lists, schedules, statuses, choices, approvals. Every other platform gets the widget's
plain text in its place. The contract is `docs/widgets/payload-contract.md` in the Elyx project.
`spec/` is a verbatim copy of its generated schemas, examples, catalogue and rules (`sync-spec.py`
refreshes it; never edit the copy).

## Install

Published to [vburojevic/hermes-app-widgets](https://github.com/vburojevic/hermes-app-widgets)
(`Scripts/publish-widgets-plugin.sh`). Install it like `hermes-app-push`, in the root **and every
profile** (each Bot is a profile with its own plugins):

```sh
hermes plugins install vburojevic/hermes-app-widgets --enable
for p in $(ls ~/.hermes/profiles 2>/dev/null); do hermes -p "$p" plugins install vburojevic/hermes-app-widgets --enable; done
```

- Hooks and the command take effect at once. The tools and the prompt section apply from each
  session's next start, because Hermes builds a session's tool list and system prompt once.
- No Python dependencies are declared. It needs `jsonschema` and `referencing`, which come with
  Hermes's `[all]` extra (through `mcp`), and `cryptography`. Without them the widget tool answers
  with an error that says what's missing; nothing else breaks.

Settings (`config.yaml`, `plugins.entries.hermes-app-widgets.settings`):

| Setting | Default | What it does |
|---|---|---|
| `app_platforms` | `[]` | Session platforms that are always the Hermes app, such as `[api_server]` on a gateway the app reaches without Bot Mode. |
| `store_media` | `false` | Fetch and store remote images when a widget is created (proposal; see Media). |
| `text_answers` | `true` | On messaging platforms, turn a plain answer to the one open widget into its action. |

## What it registers

| Hermes API | What |
|---|---|
| `register_tool("widget", toolset="widgets")` | `op`: `create`, `update`, `resolve`, `claim`, `get` |
| `register_tool("widget_examples", toolset="widgets")` | The examples, limits and fallback rule for one type |
| `register_system_prompt_section("hermes-app-widgets")` | ≤ 4,000 characters, only in the app's sessions (see Sessions). Widgets are the default there: an agent uses the matching widget unprompted whenever the content fits a type, and keeps prose for explanation |
| `pre_llm_call` | Once per app chat that didn't get the section (Hermes builds a chat's system prompt at its first turn and keeps it: a long-lived Bot Chat, or a chat the app marked later), the same rule as turn context |
| `register_skill("widgets")` | `docs/widgets/agent-usage.md`, as `hermes-app-widgets:widgets` |
| `transform_llm_output` | Neutralises `` ```widget `` fences, then rewrites directives per platform |
| `pre_gateway_dispatch` | Plain answers on messaging platforms ("check tomatoes") |
| `subagent_start` | Notes helpers' sessions: helpers and sub-agents get no widgets |
| `register_command("app-widgets")` | The app's channel to the plugin (see App protocol) |

`widget` results are pinned in `tools.budget_config.PINNED_THRESHOLDS`, the way Hermes pins
`read_file`, so they're never spilled to a file. Hermes would otherwise store a large result as a
1,500-character preview, and the app reads the payload from the stored result. Payloads are capped at
64 KB, so pinning costs at most that.

## The widget tool

`create` takes the input form (`spec/schemas/input/<type>.input.schema.json`): no `id`, `rev` or
`producer`, `fallback_text` optional, `from_file` allowed, and stack children with a `ref`. It:
- reads `from_file` with the §4 parsers: `junit`, `coverage` (lcov, Cobertura, coverage.py), `csv`,
  `tsv`, `jsonl`, `json` (with `map` pointers), `log`, `ics`, `sarif` and `gh-run`. Paths are
  workspace-relative and resolved inside the session's workspace; files are at most 5 MB; XML with a
  DOCTYPE is refused. File data never sets `actions`, `sensitivity`, `producer`, `resolution` or `for`.
  Fields from the file win, and a field also typed is an error. `source` and `as_of` come from the file;
- applies the catalogue defaults (a `pass` is private) and makes a stack private when a child is;
- assigns `w_` ids (children too), `rev` 1, and `producer` from the session's Bot (the root is
  `{"name": "Hermes", "bot": "hermes"}`, a profile is its own handle and display name);
- resolves `supersedes: "task:<id>"` to that task's newest widget;
- writes a missing `fallback_text` from each type's "Text fallback" rule (`fallback.py`). An
  approval that must be signed never invites a text answer: its stored fallback ends "Open the
  Hermes app to approve; this can't be approved by text.";
- validates against the full schemas and every rule in `semantic-rules.json` marked plugin, both or
  warn, including the gateway's redaction patterns over every string. Errors name the path, the
  allowed values and a close match, and nothing is stored. Warnings are returned and stored;
- stores revision 1 in `<root>/widgets/<id>.json`, each stack child as its own widget, and returns
  `{id, rev, directive, fallback_text, children: {ref: id}, payload, warnings?}`.

`update` replaces the whole payload (rev + 1); only the producer may update. On a stack child it
also writes the stack's next revision with that child in place. `resolve` writes rev + 1 from the
stored revision plus `resolution` (`done`, `failed`, `rejected`, `cancelled`, `expired`,
`elsewhere`; `at` from the gateway clock; `action` and `by` from the claim) and `answer`,
`submitted`, `undo`, `undone`. `get` returns the newest revision.

### claim

`widget {op: "claim", id, rev, action, mid, values, sig?, device?}` is the gate before acting. It
runs under the store's lock, so the first answer wins across every Hermes process. `result` is one of:

| `result` | Fields | When |
|---|---|---|
| `ok` | `at`, `by`, `signature?` | Act now, then resolve |
| `already_answered` | `mid`, `action`, `by`, `at` (the first answer) | Someone answered this revision, or it's resolved |
| `stale_rev` | `current_rev` | The answer is to an older revision |
| `expired` | `expires_at`, `now` | Past `expires_at` (or the undo window) on the gateway clock |
| `unsigned` | `reason`: `missing`, `invalid`, `text_answer` | A signed approval without a valid signature |
| `not_for_you` | `for` | In a group chat, the sender isn't the widget's `for` |

A second claim with the same `mid` returns the first result with `replay: true`, plus the
resolution when there is one. Every answer has `message`, one sentence for the model. Unknown
widgets and actions return `{"error": …}`. The answers a resolved revision still takes are Retry
after `failed` and the resolution's own `undo` action.

### Signed answers

Approvals that are a `transfer`, `purchase` or `spend`, need `authentication: required`, have
`reversible: no`, or carry a non-zero cost or amount, need a signature for `approve`. So does any
action with `requires: authentication`. Unknown approval kinds count as transfers.

- Each device registers a Secure Enclave P-256 public key (`keys.register`). After Face ID, the app
  signs `hermes-widgets-v1|<id>|<rev>|<action>|<sha256 hex of the canonical values>|<mid>` (UTF-8).
  The canonical values are `json.dumps(values, sort_keys=True, separators=(",", ":"),
  ensure_ascii=False)`. `sig` is base64 of the DER signature (64-byte raw r‖s also works); the key is
  base64 of the X9.63 point or the SPKI DER. `signing.py` is the reference.
- A claim from a session that isn't the app (Telegram, the CLI) is always `unsigned`
  (`text_answer`), whatever it carries.
- Until any device has registered a key, an app session's claim is `ok` with `signature:
  "unavailable"`: Face ID in the app is the only gate, as the contract allows for now.
- The limit is the agent itself. An agent with a terminal can edit `keys.json` or act without
  claiming. Signatures stop a typed or forwarded "approve" from counting as consent; they don't
  sandbox a compromised agent.

## Platforms and sessions

`transform_llm_output` runs before a reply is stored and sent. It first rewrites every
`` ```widget `` fence to `` ```json ``, wherever it is, so the only inline blocks anyone sees are the
plugin's. Then:

| Session | Directive lines become |
|---|---|
| The app's (see below) | Unchanged: the app draws the card |
| A scheduled task whose every delivery target is the app (`apppush`, `bot-chat`, an origin chat the app marked) | An inline `` ```widget `` block of the stored payload |
| A member of a Bot group chat (hosted room) the app marked (`/app-widgets room`) | An inline block too: the app reads room messages as copied text, never the members' tool rows |
| Everything else: Telegram, Slack, the CLI, Hermes Desktop, other API clients, other tasks | The widget's `fallback_text` (an unknown id: its `alt`) |

The app's sessions can't be told apart by platform. Bot Mode chats send `source: "desktop"`, as
Hermes Desktop does, and gateway chats are always `api_server`, as any OpenAI-compatible client is.
So the app marks each chat before its first prompt (`/app-widgets session`), and `app_platforms`
covers gateways the app reaches without Bot Mode. The prompt section and the kept directives
follow the mark. Hermes compacts a long chat into a new session with a new id (a Bot Chat compacts
often, sometimes mid-turn), so a session compacted from a marked one is the app's too: the plugin
reads its compression lineage from Hermes's session store (`get_compression_lineage`) and marks it.
A branch is a new conversation and needs its own mark. Cron sessions are identified with `ctx.current_cron_execution()` and the job's
`deliver` from `cron.jobs.get_job`.

`pre_gateway_dispatch` only runs for messaging adapters. When exactly one widget is open in the
chat, a short plain answer ("approve", "2", "got lemons and feta", "undo", a button's label) becomes
`[widget <id> rev <n>] <action>: <words>` plus a JSON line with a fresh `mid` and `"via": "text"`.
It never does this for an approval that must be signed.

## App protocol

Plugins can't add gateway RPC methods, so the app calls
`command.dispatch {name: "app-widgets", arg: "<command> <json>"}` on the backend socket, as it does
for `app-push`, and reads one line of JSON. A `4018` error means the plugin isn't installed. The
commands that change state are refused from messaging platforms.

| Command | Arguments | Answer |
|---|---|---|
| `session` | `session_id` and/or `stored_session_id`, or `session_ids` (up to 500, to mark every known chat at once); the session bound to the call counts too | `ok`, `session_ids`: the chat is the app's. A Bot Mode chat's agent runs under `session.create`'s `stored_session_id` |
| `room` | `room_id` | `ok`: the app reads this Bot group chat. The room comes from the coordinates the backend keeps on a member's session during a room turn (`_hosted_room_task`) |
| `get` | `id`, `rev?` | `ok`, `id`, `rev`, `payload`: the refresh, and the fallback when a stored tool row lacks the payload |
| `keys.register` | `device_id`, `name`, `public_key` | `ok`, `fingerprint`, `devices` |
| `keys.remove` | `device_id` | `removed` |
| `keys.list` | | `devices` (ids, names, fingerprints) |
| `status` | | `version`, `spec`, `widgets`, `keys`, `validator`, settings |

The app reads payloads from the stored tool rows: REST `GET /api/sessions/{id}/messages`
(`?include_compacted=true` after compression), on the backend or the API server. The JSON-RPC
`session.resume` and `session.history` drop tool content. The socket's `tool.complete.result` carries
the full result too, but only while tool progress is on.

### The smallest gateway change

`command.dispatch` works today, but a slash command reaches messaging platforms too, and the only
argument it carries is a string. The smallest change that gives plugins a client-only channel is
one JSON-RPC method on the backend socket:

```
plugin.call {plugin: "hermes-app-widgets", method: "keys.register", params: {…}}
```

It would dispatch to a handler the plugin registers with `ctx.register_rpc(method, fn)`. It is
reachable only by authenticated socket clients, never by a chat or a model. Its sibling for stored
media would be `GET /api/plugins/{plugin}/files/{name}` on the backend, serving files a plugin wrote
under its data folder. With those, keys, refresh and media move off the slash command.

## Media (proposal)

`src` stays the https URL, and the app waits for a tap that shows the domain. With `store_media` on,
`create` fetches each https image, video or audio file once. The fetch refuses private, loopback,
link-local, shared, multicast, reserved and metadata addresses, on the pinned address it connects to
and on every redirect. It caps files at 10 MB and sniffs the bytes (no SVG or HTML). It strips JPEG
and PNG metadata and stores the file as `<root>/widgets/media/<sha256>.<ext>`. Nothing serves those
copies yet.

## Storage

All in the Hermes root (`get_default_hermes_root()`), whichever profile a turn runs in:
`widgets/<id>.json` (every revision, where it was made, warnings, claims), `widgets/index.json`
(chats and tasks → widgets), `widgets/sessions.json` (chats the app marked), `widgets/keys.json`
(device public keys) and `widgets/media/`. Writes take an `fcntl` lock and replace files atomically.

## Tests

```sh
HERMES_SOURCE=<hermes-agent> <its venv>/bin/python -m pytest Tools/hermes-app-widgets/tests --import-mode=importlib
```

They load the plugin through Hermes's own plugin manager in a throwaway `HERMES_HOME`. They drive
the real `transform_llm_output` caller, the system prompt sections, `pre_gateway_dispatch`, cron
jobs and both servers' tool lists. They cover every parser; every example passing and every
`examples/invalid/` payload failing for its stated reason; the SSRF guard; the Telegram and CLI
rewrite; fence neutralising; and claim idempotency, first-answer-wins and signatures. They also check
that the app's bundled spec (`Packages/HermesKit/.../Widgets/Spec`) matches `spec/` byte for byte.
Nothing touches `~/.hermes`.
