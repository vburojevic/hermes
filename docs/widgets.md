# Widgets

Agents put widgets in their replies: cards for numbers, lists, schedules, statuses, questions and
approvals. A widget is read in two seconds and answered with one tap. The design system, the
contract and the 35 primitive specs live in the design project's `docs/widgets/`; this document
says how the app builds them.

The contract's machine-readable parts are copied verbatim into
`Packages/HermesKit/Sources/HermesKit/Widgets/Spec/` (from the design project at `cbc510c`, the same commit as the plugin's copy):

- `schemas/`: the JSON Schema 2020-12 schemas (`common`, `envelope`, one per primitive);
- `catalog.json`: every type with its examples, Elyx exports, skeleton and fallback rule;
- `semantic-rules.json`: the rules the schemas can't say;
- `examples/`: valid payloads (the gallery and the mock show them).

The payloads that must fail (`examples/invalid/`) are test fixtures in
`Packages/HermesKit/Tests/HermesKitTests/Fixtures/widgets/`. The gateway plugin
(`Tools/hermes-app-widgets`) keeps its own copy of the same files and a test that they match.

The Swift models are generated from the schemas: after copying new ones, run
`python3 -I Tools/widget-models/generate.py` and commit `WidgetModels.swift` with them. Never edit
the generated file.

## 1. What a widget is

A widget is a `surface` card in the reply column, drawn by the app, in the same family as the
app's diffs, plans and outputs. The agent writes one plain sentence first; the widget supports it
and never replaces it.

```
agent ──widget(create)──▶ hermes-app-widgets ──▶ { id, rev, directive, fallback_text, payload }
reply text:   "Two price drops tonight…\n\n::widget{id="w_3kq9x2" alt="Apartments in Brooklyn: 3 new"}"
the app:      the widget tool's result ─▶ WidgetStore ─▶ the card, where the directive is
tap:          "[widget w_3kq9x2 rev 1] book_viewing" + {mid,…} ─▶ Send Next
agent:        widget(claim) ─▶ acts ─▶ widget(resolve) ─▶ rev 2 redraws the card in place
```

Without the `hermes-app-widgets` plugin there are no widgets: replies are Markdown as before
(§11).

## 2. Where widgets come from

### The directive

`::widget{id="w_…" alt="…"}` on its own line, outside code fences (`WidgetDirective`,
`ReplySplitter`). Leading and trailing spaces are ignored; `id` is required, `alt` is optional and
cut at 140 characters; unknown attributes are ignored; only double quotes, with `\"` for a quote.
Attributes are separated by spaces or by a comma, as models often write them; the plugin reads both.

- The reply's text is split at directive lines before Markdown parsing; the text between them is
  Markdown as before. A reply without `::widget{` takes the old path untouched.
- The same id twice draws once, at the first place. At most three widgets per reply; a fourth
  directive shows its `alt` as text.
- While a reply streams, a last line that could still become a directive (`::wid`) is held back,
  so `::widget{…}` never shows raw.
- A directive whose widget was never stored (its create was refused, or the model made the id up)
  keeps its place: "Couldn't load this widget" with its `alt` (`WidgetMissingCard`). The rest of
  the reply always shows.
- Words written in the same message as only widget calls are the reply, not narration: a refused
  call is not a step, so the words read as the answer, in full, also when the chat is opened again.

### The payload

The `widget` tool returns `{id, rev, directive, fallback_text, children, payload}`
(`WidgetToolResult`). Where the app reads it depends on the transport:

| Chat | Live | Reopened, or another device |
|---|---|---|
| Bot Mode and Desktop chats (backend socket) | `tool.complete.result` | the session's stored tool rows |
| Gateway chats (`/v1/runs`) | the run stream's `tool.completed` carries only a 500-character preview, so on `tool.completed` for `widget` the app reads the session's messages again: Hermes stores the tool row before it emits the event (`tool_executor.py`, `_flush_session_db_after_tool_progress`) | the session's stored tool rows |

The `widget` and `widget_examples` tool steps are hidden from the turn's steps: the card is the
step.

### Inline blocks

A scheduled task delivers text only, so the plugin replaces each directive in a task's output with
a ` ```widget ` block holding the payload, after rewriting any other ` ```widget ` fence in that
text to ` ```json `. The app draws inline blocks only in routine deliveries on a gateway with the
plugin. Anywhere else a ` ```widget ` fence is code, except in Debug builds or with Settings →
Developer → Render Inline Widgets (§11).

A task's agent sometimes types a payload into its report instead of calling the tool. Plugin 1.4.0
(the version the app installs, [plugins.md](plugins.md) §6) makes such a ` ```widget ` fence, or a
` ```json ` fence holding a payload, the way the tool would: its own id and revision, the same
checks, then an inline block. One that can be answered, needs a signature, fails the checks or
comes after the third becomes its plain text, so only the tool makes a card a person acts on.
With an older plugin, or none, a routine delivery reads such a fence as its `fallback_text` (or
title) with "Shown as text", never as code and never as a card (`ReplySplitter` `typedAsText`,
`Parts.fallbackText`). JSON that isn't a widget (no `type`, or none of `v`, `fallback_text` or a
widget id) stays code, and outside routine deliveries every fence stays code.

A smaller model can stop halfway through a payload or leave its words out. Where inline blocks
draw, or in a routine delivery, a payload that can't be read keeps its place as "Couldn't show this
card." with "Shown as text", and the reply's words around it stay (`ReplySegment.unreadable`). That
is a ` ```widget ` block that isn't a JSON object, a ` ```json ` block that names a `type` and a `v`
or `fallback_text` but doesn't parse or has no words, and either one left open when the reply ends.
It is never raw JSON and never a blank reply; Copy and Listen skip it. While a reply streams, an
open block waits.

## 3. Reading a payload

`WidgetReader.read` decides between drawing a widget and showing its text:

1. An unknown `type`, or a `v` above 1, shows `fallback_text` with "Update Hermes to see this
   widget" in the widget menu.
2. The payload is validated against the full JSON Schema 2020-12 schemas (`JSONSchemaValidator`,
   no dependency; every keyword the schemas use, `unevaluatedProperties` annotations included,
   formats as assertions).
3. Clients are lenient within a major version and fail closed (contract §10). Where the only
   fault is one of these, the app draws the safe reading instead of falling back:

   | Unknown… | Read as |
   |---|---|
   | field (a name the type's schema doesn't know anywhere) | left out |
   | `sensitivity` | `private` |
   | approval `subject.kind` | `transfer` (authentication, a signature, no notification buttons) |
   | approval `consequences.reversible` | `no` |
   | `Action.kind`, or a link whose scheme isn't `https:` or `hermes-file:` | the action or link dropped |
   | `Action.requires` / approval `authentication` | `authentication` / `required` |
   | `state` (widget, item, tag) | `info` (the badge word from `state_label`); progress states read `unknown` |
   | `layout`, `style`, `view` | the primitive's default |

   The same holds for addresses in a widget's words (notes, details, bodies, summaries, log
   lines, table cells): an `https:` one is a link (`Text(widgetLinking:)`), anything else stays
   text. Like the widget's own links, a tap first asks "Open <host>?", in a stack too.

   A field by a known name in the wrong place (a fifth outline level) isn't forgiven: the client
   cuts nothing silently.
4. The client's semantic rules (`semantic-rules.md`, "both"): widget-level action ids are unique
   and never a built-in id (`approve`, `check`…); at most one primary action (a summary's
   `do_first` counts); a destructive action has `confirm`, an open action `url`, a copy action
   `value`; a stack's children each read as widgets of their own, and a private child makes the
   stack private.
5. Anything else wrong, a missing required field above all, falls back: `fallback_text` as reply
   prose with a quiet "Shown as text", and the first reason in the widget menu ("Shown as text:
   consequences.cost is required"). A widget is never half drawn. A fallback whose `sensitivity`
   is anything but `normal` stays private.

`WidgetReader.strictFailures` is the producer's view (the full schemas, strictly, and the same
rules): the tests check that every example passes it and every invalid fixture fails it. Four
invalid fixtures are still drawn by the client, as the table says: `metric-1` (a misspelt field
is left out), `status-2` and `outline-2` (unknown states), `sources-2` (an `http:` link is
dropped).

## 4. The store and revisions

One `WidgetStore` per gateway (`BotWorkspace.widgets`):

- **Payloads** by widget id. The newest `rev` wins and redraws in place, at the directive's
  position; an older revision arriving later is dropped. A stack's children are registered as
  widgets of their own, so an update to a child replaces just it.
- **Where they come from:** every rebuild of a chat from its stored rows reads the `widget` tool
  rows (`ingest(messages:)`); the socket's `tool.complete` hands over its parsed result; a run's
  `tool.completed` for `widget` re-reads the newest 30 rows; a routine delivery's inline blocks
  are read as its row is built. A directive whose payload isn't known yet tries the device's copy,
  then the chat's rows again with `include_compacted=true` (compression sets rows aside, it
  doesn't delete them).
- **On the device:** each payload is kept in Caches (`WidgetCache`, `Widgets/<gateway>/<id>.json`);
  private ones are sealed with ChaChaPoly under a key kept in this device's Keychain
  (`<id>.sealed`, §8). Removing a gateway removes its folder.
- **This device's own state:** the mids it sent (kept, so a restart still knows its own answers),
  when each entered a turn, a tap not in the chat yet, checklist ticks and flashcard ratings
  waiting to go, and each widget's view state (sort, filter, a guide's step, a flipped card, Show
  all: `WidgetViewState`), dropped with the chat's cache. View state never syncs; answers do. It
  holds what the person typed into forms before sending, so it's sealed like private payloads
  (`views.sealed`); the plain `views.json` of older builds is read once and removed.

## 5. Answering a widget

A tap builds a `WidgetAnswer` (contract §6.2). The payload can't choose its words:

```
[widget w_flights21 rev 1] answer: UA 1187 · 10:55 AM → 2:20 PM
{"device":"iPhone","mid":"9a21d4e8-…","values":{"selected":["ua1187"]}}
```

- **Line 1** is readable: the action id, then the values in words from the labels the person saw
  (`WidgetAnswers.swift`: `choice`, `checklist`, `form`, `control`, `approval`, `flashcards`,
  `compare`, and a payload's own actions with `{item}` or a guide's `{step}`). Free text (a form's
  text, an Other answer, an edited message, a rejection note) is defused: one line, quoted, cut
  at 200 characters, a leading `[widget` escaped, invisible and reordering characters shown as
  their codes.
- **Line 2** is compact JSON and authoritative: a fresh `mid`, `values`, the action's `payload`
  echo, `sig` for signed answers (§6), and `device` ("iPhone", "iPad" or "Mac", never a personal
  name) so other devices can say where it was answered.
- **Always Send Next**, whatever the follow-up setting: with a turn running (or the chat held
  elsewhere) it joins Up Next, "Queued · sends after the current turn"; otherwise it starts a turn
  at once. It never goes through the composer, so the draft stays as it was.
- **Where a request stands** (`WidgetInteraction.evaluate`), from the newest payload, the chat's
  rows (`WidgetChatFacts`) and this device's state, in this order: superseded; resolved (the
  resolution line replaces the actions); expired (`expires_at` passed: the client turns the
  actions off itself); for someone else in a group chat (read-only); answered in the chat for
  this revision from any device (locked: "Answered on Mac · waiting"); this device's tap not in
  the chat yet (sending or queued); a question moved past (§7); open.
- **No answer:** 60 s after this device's answer entered a turn (`start` with that message, not
  the tap: Send Next can wait behind a long turn), without a newer revision, the actions come back
  with "No answer from <producer> yet · Try Again". Try Again sends the stored message again, the
  same mid, so the agent's `claim` answers it once.
- **Offline:** approvals and other answers aren't queued ("Not sent: you're offline"). Checklist
  ticks and flashcard ratings wait on the device and go when the gateway is back.
- **Batches:** ticks are optimistic and show pending until a newer revision confirms them
  (`ChecklistTicks`); they go as one `check` message 5 s after the last tick or when the chat
  closes. A flashcard session's ratings go as one `rate` message when its last card is rated or
  the chat closes. A newer revision keeps unsent ticks, measured against it.

## 6. Approvals: Face ID and signed answers

Some answers need Face ID (or Touch ID, or the passcode where there's neither) before they go, and
the device's signature with them (contract §6.3). `WidgetSignature.isRequired` is the plugin's own
rule, so the app asks exactly when the plugin will check: approving an approval that costs money
(a cost or an amount that isn't 0), can't be undone (`reversible` not `yes` or `until`), says
`authentication: required`, is a transfer, purchase or spend, or has a kind this app doesn't know;
and any action marked `requires: authentication`. Rejecting and editing never need it.

- **The key** (`DeviceWidgetSigner`): a Secure Enclave P-256 key made once per device, that only
  Face ID or Touch ID unlocks (`.biometryCurrentSet`; a Mac without Touch ID uses its password,
  `.userPresence`). Its sealed blob is kept in the Keychain on this device only.
- **Registering it:** when a gateway turns out to have the plugin and its socket is up, the app
  runs `/app-widgets keys.register {device_id, public_key, name}` (`AppWidgetsClient`): the push
  layer's device id, the X9.63 key in base64, and "iPhone", "iPad" or "Mac". Again before a signed
  answer if the key is new. Removing the gateway from the app runs `keys.remove`.
- **Answering:** the tap asks for Face ID ("Confirm “Order lunch?”"), then signs `WidgetAnswer.
  signingInput` (`hermes-widgets-v1|id|rev|action|sha256 of the canonical values|mid`) with the
  context just checked, so there's one prompt, and sends the answer with `sig` (base64 DER).
  Cancelling sends nothing and leaves the buttons as they were. Offline, it doesn't ask at all:
  "Not sent: you're offline".
- **When faces or fingers change,** the old key can't sign again: the app makes a new one, signs
  with it and registers it before the answer goes. If no key works at all on the device, the
  person has still passed the check, so the answer goes without `sig` rather than not at all.
- **No Secure Enclave** (and the simulator, which can't use a key bound to Face ID): the check
  alone gates the answer, with no `sig`. The plugin accepts that only while no device of the
  gateway has registered a key; after that such an answer is refused (`unsigned`).
- **Failures** show as an alert on the card: no Face ID, Touch ID or passcode set up ("Answer it on
  another device, or set one up in Settings"), or the check failed ("nothing was sent").

## 7. Folding, groups and suggestions

- **Superseded:** a newer widget in the chat whose `supersedes` names this one folds it to one
  line ("Updated · the newer one is below") with its actions off; tapping the line unfolds it.
  An approval doesn't fold: it stays readable, its actions off.
- **Moved past:** a question (`choice`, `form`) the person answered by typing something else folds
  to "Not answered · you replied in the chat". Unfolded, it can still be answered until it expires.
  Only typed messages count: another widget's answer, a routine delivery or a Bot's message don't.
- **Suggestions** (`choice` with `style: suggestions`): no card, a few rows under the reply that
  send exactly their words as the person's message. They show only on the newest reply, and only
  until something comes after it.
- **Group chats** (Bot rooms): the app marks a room as its own (`/app-widgets room {room_id}`) when
  it opens and before the person's first message; the plugin then writes its members' widgets
  into their replies as inline blocks, because a room shows no tool rows. Facts come from the
  room's rows (`WidgetChatFacts.build(room:)`). A widget whose `for` names one of the room's Bots is
  read-only ("For Ops"); anything else in a room is the person's to answer, since they're its only
  human. Answers go into the room as the person's message (`groups.send`), ticks one at a time
  (no 5 s batch). Updates to an answered widget are read with `/app-widgets get` when the room
  moves on, since no tool row brings them.

## 8. Privacy

Private widgets (`sensitivity` anything but `normal`, read failing closed; a stack with one private
widget is private) follow contract §9:

- **At rest:** the widget cache seals them (ChaChaPoly, key in the Keychain on this device only;
  `WidgetCache`). The transcript cache (`TranscriptCache`) never writes their payloads:
  `WidgetPrivacy.atRest` takes a private widget's payload out of its tool row (`{"id", "rev",
  "private": true}` is left), turns its inline block into a directive to the sealed copy, and keeps
  only the action and mid of an answer to it. Cards for those rows read the sealed copy.
- **Previews:** the chat list's last line, the Mac's reply notifications and the Live Activity show
  a reply's words without its widgets (`WidgetPrivacy.previewText`), never an `alt` (a private
  widget's alt is its title). A reply that is only widgets reads "Sent a widget"; an answer reads
  as what it did ("Approved"), without its words. Push notifications are the push plugin's
  (`docs/notifications.md`): a private widget there says "Hermes sent a widget."
- **The app switcher:** on iPhone and iPad a private card is blurred, with a lock, whenever the app
  isn't in front (`PrivateWidgetCover`), its pictures included.
- **Pictures on the gateway** (`hermes-file:`, §9) are held in memory by the card that shows them
  and nowhere else: read through the backend, whose session keeps no URL cache, decoded in memory,
  never written to a temporary file, the picture cache (`RemotePictures`) or the widget cache,
  which keeps the payload and its address only. This holds for every widget, so a private one's
  picture never reaches the disk.
- **Videos** (§9.3) stream into memory a stretch at a time, with no size cap, and are let go
  when the viewer or the File tab closes: never a file, a URL cache or the widget cache, on the
  gateway or on the web. A video on the gateway carries the gateway's headers; an https video
  carries no key on any host, only an access gateway's own headers on the gateway's host, and one
  on another server waits for the card's tap, as a picture does. The full-screen viewer neither
  saves nor shares a private widget's pictures.
- **Never indexed:** nothing from widgets goes to Spotlight, Siri suggestions or the Home Screen.
- **Group chats:** the plugin refuses private widgets there.

## 9. How widgets look

`WidgetCard` is the design's `Parts.card`: header (glyph or the producer's face, title, subtitle,
one badge), banners, the primitive's body (`WidgetBodyView`, one view per type under
`Views/Widgets/Primitives/`), the status or resolution line, the footer (source, as of, Refresh) and
the action row with "…" for the rest. A stack has no card of its own: a header line, then its
widgets.

- **One badge,** by precedence: critical, stale ("3 h old"), unverified, warning, pending, info, ok;
  without a `state`, the worst item state. An answer in flight (this device's or another's) reads
  "Waiting" (pending), and an approval's tapped tile says "Approving…" and "Sent"
  (`Asking.approvalPending`).
- **Density:** compact on the Mac and inside a stack of four or more (`WidgetDensity`).
- **Width:** at most 560 pt, 720 for wide layouts (`lanes`, `grid`), and never wider than the
  reply: nothing inside a card may make it wider. Long words wrap in the card, a tag with a long
  word wraps inside its pill, a `details` value moves under its label when the two don't fit on
  one line (`Collections.details`), and a table reflows into blocks. Only a code snippet keeps
  its lines and scrolls sideways inside its well; output and logs wrap (`Things.code`).
- **Surfaces:** cards are `surface`, never glass; an unresolved alert is tinted by its severity.
- **Pictures** (`media`, a guide step's `image`, a flashcard's `media`): one from the gateway's
  own address shows by itself; one from anywhere else waits for "Tap to load from <host>". One
  the Bot keeps on its gateway (`hermes-file:<path>`) is read through the backend
  (`/api/fs/download`) with the chat's Bot profile, as Open reads it (`WidgetFile`): a relative
  path is in the chat's working folder, the one its Inspector opens; the address is
  percent-decoded, a `#L42` fragment is dropped, and a path with a `..` step is refused. In a
  Bot group chat a widget has no chat of its own: a relative path is in the gateway's default
  folder and is read without a profile, and Open on its link shows that same file. It's decoded
  off the main thread at the size it's drawn at (`GatewayFileImage`) and the read stops when the
  card leaves the screen. A card draws a video's `thumb`; the video itself is read only once it
  is opened and played (§9.3). A tap on a picture or a video opens the viewer (§9.1); a
  picture still waiting for its tap loads first. While it loads the well is `controlFill`; when
  the file is missing or the gateway refuses it, the description with "Couldn't load this
  image"; without Bot Mode, the description with "Turn on Bot Mode to load this image".
  VoiceOver reads the `alt` either way.
- **Loading:** a skeleton in the type's shape while a payload is on its way; "Couldn't load this
  widget" with Try Again when it never comes; text with "Shown as text" for an unknown type, a
  newer version or an invalid payload (the widget menu says why).
- **Reuse:** `Theme`, `TagLabel`, `StatusDot`, `PlanCard`, `DiffCard`, `OutputBlock`,
  `SourcesRow`, `BotFace`, `FlowLayout`, `MarkdownTableView`; Swift Charts, MapKit snapshots and
  CoreImage codes.
- **Everyday cards** (design 5e1f02f): a market quote (`chart` with `stats` under the plot as
  `LabeledContent`, the previous close as the dashed `target` rule with its label), a flight's
  status (`route` with `mode: flight`: both airports with their times and how late or early,
  orange only while the flight is delayed, the plane along the line, gate, terminal, belt and
  aircraft; the badge from `flight.state`, delayed orange, cancelled and diverted red), a price
  you watch (`entity`, `kind: product`: the rating as one line under the name, the photo beside
  it, `price.history` as a step line whose last price keeps a step of its own, `price.lowest` as
  a green tag when the price is at or near it, Open in Shop through the open check), and a
  weather warning (the first alert leads as the banner, "+1 more" for the rest, a Warning badge
  when the payload sends no state; in the compact layout the alert takes the tip's place).
  The gallery adds `weather-alert` (the first forecast with the compact example's warning) so
  the banner over a full forecast has a card to compare with `weatherAlert`.
- **The gallery** (Debug builds): Settings → Developer → Widgets, or `-HERMES_GALLERY
  widgets[:<type or example>[:<state>[:compact]]]`, draws every example in every state at both
  densities ("widgets:table-1:ready" is that one card). Cards are as wide as in a reply (the
  chat's 20 pt margins), the width the designs are drawn at.
- **Footers** (`Parts.cardFooter`): the source's glyph, its name, then its `detail` when the
  producer sends one ("invoices/0042.pdf", "listed 9 days ago"), else the time. The glyph is the
  source's `symbol` (a plane for flight data, a heart for Apple Health, a page for a folder); a
  source without one, or with a name the app doesn't draw, keeps the link glyph.
- **Quantities:** a `unit` is the plural; with `unit_one` a value of exactly 1 reads with it ("1
  vote", "2 votes"). A date or time with `from_now` adds how far away it is in days, counted in
  calendar days and kept current by the app ("Tue 20 Oct, in 4 days", "tomorrow", "2 days ago");
  it reads as plain text, never a tag. The plugin's text fallback leaves the distance out, since
  it would go stale.
- **Inputs:** a control's slider is a thick capsule filled in ink, with the slider's `symbol` at
  its start when it sends one (the sun on a brightness bar), set by tapping or dragging anywhere
  along it; the drag starts only when the finger moves sideways, so the chat still
  scrolls over it, and VoiceOver adjusts it as a slider. A form's date reads as words ("Fri 30
  Oct") with a calendar glyph and opens a calendar over the field; a menu fills its well, with
  up-down chevrons at the end.

### 9.1 The viewer

A tap on a picture or a video in a `media` card opens the viewer over the whole window (design
`mediaViewer`, `macMediaViewer`): the card's pictures and videos in its order, one screen each, on
the canvas, starting at the one tapped (the "+8" tile opens on its own picture). Audio stays in
the card.

- **iPhone and iPad:** it grows from the tile and shrinks back to it (Reduce Motion: it appears and
  goes without the zoom). Close, the position ("4 of 12", not shown for one item), Save and Share
  sit at the top on glass, the caption and credit at the bottom, and the picture fits between
  them; with large text the position moves aside to stay clear of the buttons. A tap on the
  picture hides and shows them with the status bar. A swipe sideways pages, a swipe down on a
  picture that isn't zoomed closes it.
- **Mac:** it fills the window and hides its toolbar, crossfading in. The top bar has Close after
  the window's buttons, the file's name and position in the middle, then Zoom Out, Zoom In, Share
  and Save; previous and next sit at the window's edges. Escape closes, the arrow keys page,
  ⌘+ and ⌘− zoom, ⌘0 fits.
- **Zoom:** a pinch, a double tap (at the point tapped) or ⌘+ zooms up to 5×; a zoomed picture
  pans and doesn't page or close until it's back at its fit. Pictures are decoded off the main
  thread at most 3,072 px on the long side, so a large photo doesn't take hundreds of megabytes.
- **Memory:** only the page shown and its neighbours hold their bytes; the rest are let go, and
  everything goes when the viewer closes.
- **Save and Share:** Save adds the picture to Photos with add-only access on iPhone and iPad
  (`NSPhotoLibraryAddUsageDescription`) and asks where to save it on the Mac; Share is the system
  sheet. Neither is offered for a private widget, a video, or a page that isn't showing a
  picture.
- **Where pictures come from:** the card's rule (§9). A picture on the gateway is read again
  through the backend at full size (`/api/fs/download`, the chat's Bot profile); an https one on
  the gateway's host loads, one elsewhere shows "Tap to load from <host>" until the card's tap,
  which lets in every picture and video on that card; plain http and other schemes show the
  unloadable state below.
- **VoiceOver** reads each page's `alt`, then its caption; the tiles say "video" and the length
  for a video, and "8 more photos" on the "+8" tile.

### 9.2 When it doesn't open

Each page that can't show its picture or video says why (`MediaStateView`), in the viewer and in
the File tab alike:

- **Gone** (404): "This picture is gone" or "This video is gone", "<name> isn't on the gateway
  anymore. Ask Hermes to send it again."
- **Too big:** "This picture is too big to open", "It's 72 MB, and the app opens pictures up to
  50 MB. Ask Hermes for a smaller copy." The 50 MB cap (`MediaViewing.maxBytes`) is the app's,
  for pictures only, since a picture is held whole: a gateway picture's size is asked with a HEAD
  first (`downloadPicture`), and an https picture stops reading past it (`RemoteMedia`). A video
  has no size cap (§9.3).
- **Not allowed** (403): "Hermes doesn't share this file", "The gateway keeps files like this one
  private, so the app can't open it."
- **Couldn't load:** "Couldn't load this picture", "Can't reach Hermes at <host>.", with Try
  Again; a video that stops coming reads "Couldn't play this video", with Try Again, which
  carries on from where it stopped. A web picture or video names its own server instead of
  Hermes: "Can't reach <host>. Try again later." and "Couldn't stream it from <host>. Try again
  later." The gateway has no part in fetching them.
- **Bot Mode isn't linked:** a file on the gateway needs Bot Mode (docs/setup.md §4.1); the state
  links it in Edit Gateway and has Check Again.
- **Unloadable:** an address the app doesn't read (plain http, another scheme) shows the
  picture's description, as on the card.

While a picture reads, the page shows the canvas with a `Spinner` after half a second.

### 9.3 Videos

A video plays only after a tap: the card's play button opens the viewer and plays it, the
viewer's poster plays on its own button, and the File tab waits in the system player. The system
player has its controls, AirPlay and captions; Picture in Picture is off, since the video lives
only as long as the view that streams it.

- **One route:** AVPlayer is given a `hermes-media://video/<uuid>.mp4` address that names neither
  the file nor the server, so it can't fetch, cache or write anything itself. Every byte comes
  through the app's resource loader (`MediaStreamLoader`) as 1 MB Range reads, held only until
  the player takes them. A video is never held whole, so it has no size cap, on the gateway or
  on the web.
- **On the gateway** (`hermes-file:`): `GET /api/files/stream?path=…&profile=…` through the
  backend with a `Range` header, the key in the request's headers and never in a URL, the chat's
  Bot profile as for pictures. MP4 and MOV play; other types say they can't play.
- **On the web** (https): the same loader reads it through `RemoteMedia`, an ephemeral session
  with no cache or cookies whose redirects stay on the same server (`SameOriginRedirects`).
  It never carries the API key; on the gateway's own host it carries only an access gateway's
  headers (`GatewayAccessRegistry`), and anywhere else nothing. A video on the gateway's host
  plays on tap; one on another server first shows "Tap to load from <host>" in the poster's
  well, once per card. A web video with no `thumb` shows a plain well under its play button; the
  app never fetches the video's own address as a picture. Plain http and other schemes don't
  play. A server that answers a Range read with the whole file (200 instead of 206) reads
  "Couldn't play this video": the app never slices that answer or reads it again.
- **Nothing on disk:** no temporary file, no URL cache, no download; paging away or closing stops
  the player and lets every read in flight go.

## 10. Accessibility and motion

- **VoiceOver:** each card is one container labelled with its title and badge; bodies speak whole
  sentences ("Revenue today, 1,240 euros, up 12 percent on last Monday, good"), not fragments.
  Charts carry an `AXChartDescriptor` for Audio Graphs.
- **Listen:** a reply or a routine's delivery read aloud reads each widget as its `fallback_text`,
  and a scheduled report (`stack`) as a brief: an intro with its weekday, then each widget in order
  (`SpokenWidgets`, [voice.md](voice.md) §3).
- **Dynamic Type:** rows that sit side by side stack at accessibility sizes (`AnyLayout`); nothing
  truncates silently.
- **Targets:** buttons are at least 44 pt tall.
- **Skeleton shimmer:** the blocks fade halfway toward what's right behind them and back every
  1.4 s: the card's surface, or the code well under a code skeleton's lines, which stays still.
  Never toward the canvas behind a card, which is darker than the card in dark.
- **Reduce Motion:** skeleton shimmer, resolution springs and chart scrubbing animations turn off;
  decorative loops use `DecorativeLoop`, so they stop when off screen.
- **RTL and localisation:** layouts use leading and trailing; phrases are localised whole, never
  built from pieces.

## 11. Turning widgets on

- **The flag:** widgets are on for a gateway when the `widget` tool is in its tool list: `GET
  /v1/toolsets` (`data[].tools`), or the socket's `tools.list` in Bot Mode. It's checked on every
  connect. There is no installer here: the app's plugin installation covers `hermes-app-widgets`.
- **Marking the app's chats:** Hermes can't tell the app's sessions from Desktop's or any OpenAI
  client's by platform, so before a chat's first prompt over the socket the app runs
  `/app-widgets session {"session_id": <runtime id>, "stored_session_id": <stored id>}`
  (`AppWidgetsClient.markSession`), once per chat per run; the agent runs under the stored id.
  Rooms are marked the same way with `room` (§7). On connect and whenever the chat list or
  `sessions.changed` brings new ones, the app also marks every chat it knows by stored id (gateway
  chats and Bot Chats, `session {"session_ids": […]}`, 500 to a call, plugin 1.1.1), so a chat it
  never opens (a Bot Chat a routine writes to) gets widgets too. Unmarked chats get
  `fallback_text` in place of directives. Gateways without Bot Mode rely on the plugin's
  `app_platforms` setting.
- **Which profile:** a Bot Chat is marked through its own Bot's profile (the plugin survey,
  [plugins.md](plugins.md) §2.1, says whether the plugin runs there), so a Bot with the plugin gets
  widgets even where Hermes itself has none, and a Bot without it shows in Settings → Setup as
  partly set up, with Install. Commands about no one chat (the signing key, marking known chats) go
  through a profile that runs the plugin, an older copy included: Hermes itself, else such a Bot
  through its open chat, because Hermes runs a command without a session in the profile it was
  launched in. The plugin keeps its data in the Hermes root, so any profile's copy marks for all.
  Where only a Bot has it, those wait until that Bot's chat opens here. A first message sent before the gateway's tool list answered marks
  its chat anyway; a gateway without the plugin says so (4018) and nothing changes.
- **Compaction:** Hermes compacts a long chat into a new session with a new id, often in the
  middle of a turn, and a Bot Chat never ends, so it compacts often. From plugin 1.3.0 a session
  Hermes compacted from a marked one is the app's too (`Widgets.ancestors`, Hermes's
  `get_compression_lineage`), and is marked in turn. With 1.2.2 the new session was the app's only
  once the app marked it before its next message, so a reply in the turn that compacted lost its
  widgets, and the rules reached the agent again only at the next compaction.
- **What the agent hears:** the prompt section (`prompt.py`) in a chat's system prompt, and in a
  chat whose prompt was built before it was marked, the same rules once as turn context
  (`pre_llm_call`, again whenever `REMINDER_VERSION` moves: 2 in 1.3.0). Both say that a short
  question still gets its widget ("Weather today?" is a `weather` card); the catalogue's one-word
  cue for weather read as a topic, and the skill used a forecast as its example of a fact for
  prose, so a weather question came back as bullets.
- **Which app sent the turn** (plugin 1.6.0): Hermes doesn't tell a plugin which client sent a
  turn (upstream NousResearch/hermes-agent#155538), so just before a turn the app runs
  `/app-widgets client {"session_id", "stored_session_id", "client": {"id": "hermes-app", "version",
  "build", "os", "os_version", "device", "renders": […]}, "turn": {"text_sha256"}}`. `os` is iOS,
  iPadOS or macOS, `device` iphone, ipad or mac, and `renders` lists what the app draws (widgets,
  gateway-file-images, gateway-files, markdown, code, tables, diagrams, math, svg, live-pages,
  office-files, link-cards; `gateway-files` is the files a reply sends with `MEDIA:` lines and
  `office-files` the ones Quick Look opens, [chat.md](chat.md) §3a; `diagrams`, `math` and `svg` are
  §3b, `live-pages` §3c and `link-cards` §3d). The hash is SHA-256 of the message's UTF-8
  bytes, exactly as sent, nothing trimmed (`tests/client_vectors.json` has worked examples). It
  carries no device name, no identifier and nothing the person typed. The plugin checks every field
  against a short list or pattern and refuses anything else with one line of JSON. A render value
  it doesn't know yet (a newer app's) is left out of what it keeps, not refused, as long as it's a
  short lowercase word (`[a-z][a-z0-9-]{0,31}`, at most 16 values): this repository's plugin (1.7.0,
  not published; the app's pin stays 1.6.0) does so, and knows every value above. Plugin 1.6.0 refused the whole client for one, and the turn lost its line, so when the plugin
  answers "client.renders must list distinct values from …" the app tells it again at once with
  only the values 1.6.0 knows (`announceClientKnownRenders`, `ClientApp.Render.knownSince160`), and
  sends only those to that profile until the plugin may have changed (below).
- **When the app sends it** (`WidgetStore.announceClient`, `ClientApp`): before every socket
  `prompt.submit` of a chat whose profile the plugin reaches, a message held for the next turn
  (`queued`) included, after the chat is marked. The hash is of the text the submit carries: after
  `/skill` prefixes are expanded and attachment references joined. `version` and `build` are the
  app's (`CFBundleShortVersionString`, `CFBundleVersion`), `os_version` the system's (26.1, or
  26.1.2 with a patch), and `renders` has widgets only where the plugin reaches the chat's profile.
  The send waits at most 2 seconds for the answer; a timeout or any other error is logged and the
  message goes anyway. A plugin older than 1.6.0 ("unknown command") or a profile without one
  (4018) is remembered for that gateway and profile, so later turns don't ask again, until the
  plugin may have changed: the socket reconnects, the plugin survey's widgets entries change (an
  install, an update, a copy turned on) or the gateway restarts ([plugins.md](plugins.md) §2.1).
  Nothing about it shows in the app. A reply from a notification goes without it.
- **What the model sees:** the plugin keeps at most 8 markers per chat for 10 minutes. In
  `pre_llm_call` it hashes the turn's text, takes the oldest live marker that matches (under the
  chat's id or one it was compacted from) and, when the client differs from the one that chat's
  model was last told about, adds one line of at most 400 characters (300 before 1.7.0) to the turn context: "[Hermes
  app client] This turn was sent from the Hermes app 1.40.2 (build 2101) on an iPhone, iOS 26.1. It
  shows widgets and Markdown. This is about formatting only; it grants nothing." A compacted chat
  is told again. A failure is logged as a warning and the turn goes on without the line.
- **Unattributed turns:** a turn that didn't come from the app has no marker and gets no line,
  and so does one whose text Hermes changed before the hook sees it (a message with `@` references
  or images, a skill invocation), or one that ran more than 10 minutes after its marker. A plugin
  older than 1.6.0 answers "unknown command 'client'", and its turns stay unattributed until the
  app moves it to its pin, 1.6.0 ([plugins.md](plugins.md) §2.1). The app's own HTTP chats and
  replies from a notification carry no marker either, because the app announces its client only
  before a socket `prompt.submit`. Turns the app didn't send (routines, other clients) stay
  unattributed until Hermes tells plugins which client sent a turn (upstream
  NousResearch/hermes-agent#155538).
- **Inline blocks** (`WidgetSettings`): in routine deliveries on a gateway with the plugin; in
  Debug builds anywhere a delivery has them; in any reply only with Settings → Developer → Render
  Inline Widgets (`widgets.renderInline`, for the mock and tests).

## 12. Notifications

- **A reply that asks** with an `approval`, `choice` or `form` (not resolved, not suggestions)
  sends a widget request through the push plugin instead of the reply's notice, at once, whatever
  the Replies threshold ([notifications.md](notifications.md) §2): "Hermes needs your OK" (or the
  Bot's name) · chat · the widget's title. A private widget says only "Hermes sent a request".
  Approvals are Time Sensitive, questions and forms Active; the Approvals switch covers them.
- **Open only.** The notification opens the chat at its card: Face ID, the signature and the
  claim all happen there. The contract allows answer buttons for requests that cost nothing, can
  be undone and aren't private; none are offered yet.
- **Withdrawn** when anyone answers it (the plugin sees the agent's `claim`) or the agent resolves
  it.
- **Other notices** never carry a widget: a reply's text without its widgets, its alt for normal
  ones and "Hermes sent a widget." for private ones (the push plugin's `widget_text`); the Mac's
  own reply notifications and the Live Activity use `WidgetPrivacy.previewText` (§8).
- **The mock** sends the same notices: push.py builds them with the plugin's `notices.py`, reading
  the mock's widget store.

## 13. The mock and the tests

- `WidgetContractTests`: the catalogue and `WidgetType` agree; every example validates strictly
  and reads as a widget; all 119 invalid fixtures fail the strict checks, and the client draws
  only the four the fail-closed table forgives; the table itself, one rule at a time.
- `WidgetDirectiveTests`: directives, fences, streaming, inline blocks and tool results.
- `WidgetMisfireTests`: a directive written with commas, a payload typed into a routine's delivery,
  and a reply in the same message as its widget call (§2).
- `WidgetAnswerTests`: the answer message, defusing, the round trip and batches.
- `WidgetMediaTests`: the viewer's items and start page, the position, the File tab's summary,
  media types by path and MIME type, Range and Content-Range, and which problem an error shows.
- `WidgetPrivacyTests`: when a signature is needed, the signing input against the plugin's,
  previews, what the transcript cache keeps, and the `/app-widgets` client.

The mock (`Tools/mock-hermes/widgets.py`) plays the plugin, in chats and Bot Chats alike: `widget` create, update, resolve,
claim and get, and `/app-widgets` session, room, client, get and keys, with the plugin's results
and messages, signatures checked for real. Its words are in its docstring and
[development.md](development.md): "widgets" pages through every example, "widget <type>",
"widget <name> <name>…" (those examples by name, "widget route-1 chart-1"),
"widget publish" (an approval without Face ID), "widget lunch" (with it), "widget expiring",
"widget silent" (Try Again), "widget private", "widget gateway image", "widget private
image" (pictures kept on the gateway, §9) and "widget missing image" (one that isn't there),
"widget media" (a gateway video with its poster and a grid of twelve screenshots, each opening
full screen, §9.1) and "widget media refused" (everything that doesn't open, §9.2),
"widget fence", "widget unknown", "widget invalid", "widget suggestions", "widget wide" and
"widget wide table" (one of everything long, §9), "widget refused" (a refused create whose reply
names the widget anyway, the directive's attributes split by a comma) and "widget refused inline"
(the same reply in one message with the call), "Weather today?" (a lookup, `widget_examples`,
then the weather card, as an agent with plugin 1.3.0's rules answers), and in a marked room the
same words. In a Bot Chat, "widget routine" runs the Bot's Daily plan routine now and delivers its
report a moment later with the widget as an inline block; "widget routine json" is a report whose
agent typed the payload as a ` ```json ` block, delivered as 1.4.0 makes it; "widget routine json
old" is the same as 1.3.0 left it; "widget routine broken" is a report whose payload stops
halfway; "widget routine directive" repeats the stored widget's directive in the Bot's reply, and
"widget routine missing" names one that was never stored (§2). Over the socket a chat the app
didn't mark gets each widget's `fallback_text`, as the plugin's `transform_llm_output` gives it. `POST
/api/mock/widget-answer {id, action}` answers from another device. `/app-widgets client` files
markers with the plugin's checks and refusals (8 per chat, 10 minutes, in memory), and each socket
`prompt.submit` uses up the oldest marker whose hash matches its text, as `pre_llm_call` would, and
logs `[mock-widgets] prompt.submit in <chat>: text_sha256 <hash> matches the <device> app's client
marker` (or "has no client marker", and "(held for the next turn)" after `prompt.submit` for a
held message); and `--widgets-version 1.5.0` plays the plugin before it, where `client` is an unknown
command (`tests/test_widgets_client.py`). `--no-widgets` leaves the plugin out. Every payload,
update and resolution the mock makes passes the plugin's own validator.


## 14. What to check

Against the mock (`backend.py --gateway-port …`; the words are in §13), on iPhone, iPad and Mac, in
light, dark and Increase Contrast:

- "Weather today?" in a Bot Chat and in a chat: one sentence, then the weather card.
- "widgets 1" … "widgets 35": every example draws as a card, none as text; the gallery
  (Settings → Developer → Widgets) matches them at both densities.
- "widget publish": Publish → your action bubble → "Publish · done" with who and when, the buttons
  gone, on every device showing the chat.
- "widget lunch": Order asks for Face ID ("Confirm “Order lunch?”"); Cancel sends nothing; on a
  device with a Secure Enclave the answer carries `sig` and the mock's claim says `verified`.
- "widget expiring": after a minute the actions turn off and "Expired at …" shows, with no message.
- Another device: `POST /api/mock/widget-answer {"action": "approve", "hold": 8}` locks the card
  ("Answered on Mac · waiting"), then resolves it.
- "widget silent": after 60 s "No answer from Hermes yet · Try Again"; Try Again settles it once.
- "widget checklist": ticks show at once with "not confirmed yet", go as one message 5 s later.
- "widget fence" stays code; "widget unknown" and "widget invalid" read as text with "Shown as
  text" (the widget menu says why).
- In a Bot Chat, "widget routine" and "widget routine json": the report's card; "widget routine
  json old": the report's words with "Shown as text", no code; "widget routine broken": the
  report's words with "Couldn't show this card." between them, no code; "widget routine missing" and
  "widget refused": "Couldn't load this widget" with the alt, the words around it shown; "widget
  refused inline": the reply as the answer, also after the chat is opened again.
- "widget private": the lock on the card, nothing of it in the chat list, the card blurred in the
  app switcher; the transcript cache (`Caches/Transcripts`) has no payload for it.
- "widget gateway image": the media, guide step and flashcard pictures show, and so does the
  reply's own image below them (docs/chat.md §3), also in a chat reopened after a cold launch.
  Without Bot Mode each reads "Turn on Bot Mode to load this image".
- "widget missing image": "Sign-ups" reads its description with "Couldn't load this image".
- "widget private image": the same pictures, covered in the app switcher; nothing of them in the
  app's container (search it for the pictures' hashes after they've shown).
- "widget media": a tap on a screenshot opens the viewer at it; pinch and double tap zoom, a
  swipe (or the arrows and chevrons on the Mac) goes to the next, "4 of 12" follows, a swipe down
  or Escape closes and the tile takes it back; the "+8" tile opens on the fifth. The video's play
  button opens it playing, streamed (the backend's log shows Range reads of
  `/api/files/stream` with the chat's profile). Open Video and Open Original open the files in
  the Inspector's File tab, as media (docs/inspector.md §2.8). Nothing of either is in the app's
  container afterwards.
- "widget media refused": each page says its state (§9.2); Try Again on the broken video tries
  once more; the press-site video asks "Tap to load from media.example.com". Without Bot Mode
  the gateway pages read "Bot Mode isn't linked".
- "widget suggestions": rows under the newest reply only; tapping one sends its words.
- Which app sent the turn: in the backend's log every message, a held one and one with a skill or a
  file included, has a `client:` line just before its `prompt.submit` line, and the submit's hash
  matches it. With `--widgets-version 1.5.0` messages send as before, and `client` is tried once
  per profile, not every turn.
- A Bot group chat: "widget publish" in the room, the card from Ops, answered into the room.
- VoiceOver reads each card as one sentence-led container; Audio Graphs plays a chart.
- `HermesUITests/WidgetsUITests` and `WidgetGalleryUITests` pass; the gallery's pages are in the
  result bundle.

## 15. Open points

- **Not yet seen on a real gateway** (the plugin thread checked them in the Hermes Agent source):
  a payload passing through the stored tool row unchanged under 64 KB and through history
  compression, and room marking in a live Bot group chat.
- **Answer buttons in notifications** for requests that cost nothing, can be undone and aren't
  private: allowed by the contract, not offered (§12).
- **Client refresh** needs a gateway route a plugin can't add today. Pictures a Bot keeps on its
  gateway load through `/api/fs/download` (§9), which needs Bot Mode; without it they read
  their description, and remote images from other hosts still wait for a tap.
- **Answering in a room** goes through `groups.send` as the person's message; which Bot picks it
  up is the room's choice, so the producing Bot's claim is what makes it count.

## 16. Setup

The widgets plugin as Settings → Setup shows it: [setup.md](setup.md) §4.14.
