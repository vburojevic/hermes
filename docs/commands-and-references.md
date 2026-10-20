# Commands, skills, mentions and file references

Anything the person types with a prefix (`/command`, `/skill`, `@bot`, `@file:path`) is shown as a
designed element, never as raw text in a bubble. This document covers how each kind looks, how
the composer builds them, how they look once sent, how commands run on each transport, and how
plain text from other clients is upgraded to the same look.

Code: `SlashCommands.swift` and `MessageParts.swift` in HermesKit (`Transcript/`),
`App/Model/SlashCatalog.swift` (the "/" menu's entries), the "Commands" section of
`App/Model/ConversationModel.swift`, `App/Views/Composer/PillTextView.swift` (the field) and
`SlashMenu.swift`, `App/Views/References/` (pills, previews, `InlineFlow`), and
`App/Views/Chat/CommandViews.swift`. Names in backticks such as `commandPill` or `richBubble` are
the design's component names, used in code comments.

## 1. One look per kind

Every reference has one look, the same in the composer, in the sent bubble, in replies and in
group chats. Shape and icon say what kind it is; nothing is ever blue text (`ink` is the only
accent; colour belongs to Bot faces).

| Kind | Look | Where it sits | View (component) |
|---|---|---|---|
| Command | Ink square tile with the command's symbol, then what it does in plain words ("Set Goal", "Change Model") | Start of the field (command mode); a card once sent | `CommandPill` (`commandPill`), `CommandBubble` (`commandBubble`) |
| Skill | Capsule, book glyph, skill name; in the tray with a remove button | Tray above the text (it applies to the whole message); chips row inside the sent bubble | `SkillChip` (`skillChip`, `richBubble`) |
| Bot | Capsule with the Bot's face (an `@` glyph for an unknown handle) and @handle | Inline, where it was typed | `BotPill` (`mentionChip`, `mentionInline` in prose) |
| Gateway file or folder | Capsule, page or folder glyph, path in monospace (middle-truncated) | Inline, where it was typed | `FilePill` (`fileRefChip`) |

All pills use the `surface-raised` fill (content, never glass). Bot and file pills come in two
sizes so they sit on a line of the text around them: regular (26 pt, for 17 pt text) and compact
(22 pt, for 15 pt prose). Messages use regular on iPhone and iPad and compact on the Mac; replies
use compact. The command pill in the field is 28 pt.

## 2. While composing

| Typed | What appears | Design |
|---|---|---|
| `/` or `/g…` at the start of the field | The typed text sits in a grey query capsule; the slash menu opens above the composer. With nothing typed after `/`: the first three skills and "Show all N skills", then commands by group. With a query: one "Matches for /g" section, skills then commands, up to 12 rows (name prefix first, then word prefix, then anywhere) | `queryToken`, `slashMenu`, `slashMenuFiltered` |
| `@` or `@wri…` in any word | The same query capsule; the roster's Bots and, over the gateway protocol, paths on the gateway (`complete.path`) | `queryToken`, `composerMention` |
| A skill picked | A chip in the tray above the text, up to five, no duplicates; the `/name` text leaves the field | `composerSkills`, `skillChip` |
| A Bot or gateway file picked | The query becomes a pill in the text. A folder stays as text, so completion can go on into it | `composerReferences`, `inlineFlow` |
| A command with no argument, or an optional one (`/usage`, `/new`, `/title`), picked | Runs at once; it is not placed in the field | — |
| A command that needs an argument or offers values (`/goal`, `/steer`, `/queue`, `/btw`, `/plan`, `/bg`, `/model`, `/reasoning`) picked | Command mode: the command pill starts the field, a placeholder asks for the argument ("What should Hermes work toward?"), a one-line hint sits under the field ("Hermes keeps the goal across turns until you clear it."), and Send stays off until the argument is there. `/model` and `/reasoning` list their values above the field (models by provider with pricing, the current one first) | `composerCommand`, `slashMenuArgs` |
| Long press a pill (hover on the Mac) | A preview: what it is, its status, and Remove and Open | `referencePreview`, `referencePreviewSkill`, `referencePreviewFile` |

The menu's entries come from `commands.catalog {profile}` (commands and skills), with descriptions
from one `complete.slash {text: "/"}`; both load once per profile and the menu filters on the
device. Until they've loaded they're asked for again when the chat's connection comes up and when
the menu opens (a first ask before the socket was up used to leave only the app's own commands for
the rest of the session). Skills are offered over the gateway protocol only, and only while the
tray has room. Without the gateway protocol the menu lists only the commands the app runs itself
(§4).

- **Parsed in HermesKit** (`SlashCommandCatalog`). Skill keys come as `/name` and also appear in
  `pairs`: they're listed once, as skills. Aliases aren't listed. Commands the app knows get its
  words and symbols (`SlashCommands`); the rest keep Hermes's line and go in the group nearest
  Hermes's category (Session, Info, Configuration → Settings, the rest under More).
- **Where Hermes offers each one** (`commands[/name].desktop`, `CommandDef.desktop`): unset or
  `advanced` runs; `hidden` stays out of the menu; any other value lists the command greyed, with
  why, in place of what it does ("Runs only in Hermes in a terminal", "Use the microphone in the
  composer", "Set this up in Settings"), and choosing it does nothing. Commands the app runs
  itself are listed however Hermes marks them.
- **`/update` and `/restart`** restart Hermes, so the app runs them through the dashboard
  ([setup.md](setup.md)), not the gateway (`/update` is terminal-only there, `/restart` only for
  messaging platforms and not in the catalog). They're listed once the catalog is in. Picked, they
  wait in the field as a command pill with Send already on (`confirmsOnSend`), never running on the
  tap. Paths come
from `complete.path {word, session_id}` (debounced, the first 12 items).

### Pill behaviour (the parts that are easy to get wrong)

- **Atomic.** A pill is one character for editing (a text attachment): the caret moves around it,
  one Delete removes it whole, selection covers it whole. It never turns back into half-deleted
  text. If the text a pill stands for is edited away, the pill goes with it.
- **Query capsule.** Starts at the trigger (`/` only at the start of the field, `@` in any word)
  and grows as the person types; it shows while the menu has rows. Picking a row replaces it
  with a pill. Escape, a space, or moving the caret away turns it back into plain text. Typing a
  roster Bot's whole `@handle` and a space makes a pill too.
- **Keys.** The arrow keys move through the menu, Return chooses, Tab completes, Escape closes.
- **Command mode.** Typing a command that takes an argument and a space ("/goal ") enters it too.
  The caret can't go before the command pill. Delete on an empty argument, or Escape, removes the
  pill and leaves command mode. Only one command per message: the menu offers commands only when
  the query is all there is in the field (no skills, pills or attachments), and a message with any
  of those is never run as a command.
- **Paste and copy.** Copying text with pills copies the plain form (`@writer`, `@file:path`;
  in command mode `/goal …`). Pasting `@handle` that matches a roster Bot, or an `@file:` or
  `@folder:` path, makes a pill.
- **Preview actions.** Bot: face, title, handle, role and whether its gateway is online; Remove,
  Open Chat. Skill: summary and category; Remove, Show Skill. File: folder, gateway and size, with
  the first lines (a folder lists its first entries), read through `shell.exec`; Remove, Open
  File. Previews in the transcript have no Remove.

## 3. Once sent

| What was sent | Shown as | Component |
|---|---|---|
| A command (`/usage`, `/new`, `/goal …`) | A card on the person's side: ink icon tile, what it does in plain words, the command in small monospace underneath. Copy Command in its menu | `commandBubble` |
| A message with skills or files | The normal bubble with skill chips (and file chips) in a row above the text | `richBubble` |
| A message with a Bot mention or a gateway file | The same bubble with the pills inline, where they were typed | `richBubbleRefs`, `inlineFlow` |
| A reply or group message that names a Bot or a gateway file | A pill in the sentence | `mentionInline`, `Groups.memberMessageMentions` |
| The command running | "Running /name…" with a spinner on the assistant side | `CommandRow` |
| The command's outcome, with data | A result card ("Usage · this session", "Status", "Context · this session") with label and value rows, or the output as monospace text | `commandResult` |
| The command's outcome, no data | One quiet line ("Model changed to Claude Opus 4.6"; "Done" when there was no output) | `commandNote` |
| A failed command | The failure on the assistant side | `CommandRow` |
| `/update`, `/restart` | A card that streams the gateway job's lines as they arrive, the step running now shimmering with its time counting up, then how it ended. The same run Settings → Setup shows (`docs/setup.md` §4.2a) | `GatewayJobCard` |
| A standing goal (`/goal …`) | A bar pinned above the composer until cleared; clearing sends `/goal clear` | `goalBar` |

### The command card

- **Title:** what the command does, in words. For a command with an argument the argument is the
  title ("Ship Hermes 1.3 by Friday") and the command sits underneath (`/goal`); `/model` shows the
  model's display name and `/reasoning` the level's name.
- **Icon:** one SF Symbol per command, from the table in `SlashCommands.all`:

| Group | Commands (symbol) |
|---|---|
| Session | `new` New Chat (`square.and.pencil`), `retry` (`arrow.clockwise`), `undo` (`arrow.uturn.backward`), `title` Rename (`pencil`), `branch` (`arrow.triangle.branch`), `compress` Compact Chat (`rectangle.compress.vertical`) |
| While Hermes works | `steer` (`arrow.turn.up.right`), `queue` (`text.line.first.and.arrowtriangle.forward`), `btw` Aside (`questionmark.bubble`), `stop` (`stop.circle`), `goal` (`target`), `plan` (`list.bullet.clipboard`), `bg` Background Task (`tray.and.arrow.down`) |
| Info | `usage` (`chart.bar`), `status` (`info.circle`), `context` (`rectangle.stack`), `tools` (`wrench.and.screwdriver`), `skills` (`book.closed`), `help` (`questionmark.circle`), `update` Update Hermes (`arrow.down.circle`), `restart` Restart Hermes (`arrow.clockwise.circle`) |
| Settings | `model` (`cpu`), `reasoning` (`lightbulb`), `fast` Fast Mode (`hare`), `yolo` Run Without Asking (`bolt.shield`), `personality` (`theatermasks`) |
| More | `review` (`checkmark.seal`), `memory` (`brain`), `save` Save Chat (`square.and.arrow.down`), `version` (`number`) |

  Hermes' aliases map onto these: `reset` and `clear` → `new`, `compact` → `compress`, `q` →
  `queue`, `background` → `bg`, `effort` → `reasoning`, `rename` → `title`. A command the app
  doesn't know still works and renders, with `slash.circle` and the raw command as its title.
  `update` and `restart` wait in the field for Send rather than running on the tap (§2).
- In a Bot Chat, `/new` and `/compress` don't start a fresh chat; they compact
  (`session.compress`), and the card says "Compact Chat".
- `/update` and `/restart` don't go to the gateway's command runner: Hermes runs `/update` only
  from messaging platforms and marks both `terminal` on its desktop surface. The app starts them
  on the dashboard instead (`SetupCenter.updateHermes()`, `restartGateway()`), the same runs
  Settings → Setup shows, and the card follows them (`docs/setup.md` §4.2a). Without Bot Mode the
  card says Bot Mode isn't connected.

### Pills inside a bubble or a reply

- Skill chips sit in a row above the text and wrap onto more lines.
- Bots and files stay inline in the sentence, as pills. The same applies to @handles and
  `@file:` paths in Hermes's and members' replies: they are matched against the roster and drawn
  as pills; unknown handles stay plain text. Headings are left as text.
- Tapping a pill in the transcript opens its preview; Open goes to the skill, the Bot's chat or
  the file.

## 4. Implementation notes

- **Parts are stored at send time.** The command name and argument, skill names, mentions and
  paths are kept with the message (`MessageParts`), so rendering doesn't re-parse the text. Hermes
  is sent the plain form it expects (`/goal …`, `@handle`, `@file:path`). The parts of messages
  with skills or pills are kept on the device (`parts.<chat>`), so they survive a reload of the
  transcript. Command cards and their outcomes are made by the app and Hermes doesn't store them:
  they are put back after the message they followed when the transcript reloads, and don't
  survive a relaunch.
- **Messages from other clients** (the CLI, Telegram, a Bot's reply) are plain text. A leading
  `/word` that names a known command, or leading `/skill` words that name the gateway's skills,
  become the same card or chips; `@handle`s that name a roster Bot (its mention tag, handle or
  name) and `@file:` / `@folder:` paths become pills. A reference must start the text or follow a
  space or an opening bracket, so email addresses aren't caught. Anything unrecognised stays text.
- **Skills** go with a message up to five (Hermes' `_MAX_STACKED_SKILLS`). A typed `/skill …` is
  the same as one picked from the menu. The app asks the gateway to expand them:
  `command.dispatch {name: <first skill>, arg: "/second /third <message>", session_id}` returns
  the `message` that is then sent with `prompt.submit`.
- **Running a command.** Some commands the app runs itself, on either transport: `new` (a new
  chat), `retry`, `stop`, `branch`, `steer`, `queue`, `model` and `reasoning` (set for this chat,
  with a note), `title` (renames the chat), and `goal` (also pins the goal bar). Over the gateway
  protocol `btw` and `bg` go to `prompt.btw` and `prompt.background` ([follow-ups.md](follow-ups.md)),
  and everything else to `slash.exec {session_id, command: "name arg"}` (its `output` and
  `warning` make the outcome). Hermes reroutes some commands itself (goal, plan, queue, steer,
  retry, undo, compress, skills and bundles): `slash.exec` then answers with `command.dispatch`'s
  directive, `type` set. Older gateways refuse those with an error instead, and the app asks
  `command.dispatch {name, arg, session_id}`. Either way the app follows the `type`: `alias` runs
  the target, `send` and `skill` send the `message` as a turn, `prefill` puts it in the field,
  anything else shows its `output` or `notice`. Without the gateway protocol, other
  commands show "/name runs over Bot Mode. Link this gateway's Hermes backend to use commands."
- **Composer text with pills.** SwiftUI's `TextField` and `TextEditor` can't host views inline,
  so the field is a `UITextView` / `NSTextView` wrapper (`PillTextView`): each pill is a text
  attachment character with a custom attribute holding the reference, the pill views are placed
  over the attachments by the field itself, and caret, delete and selection treat the attachment
  as one unit.
- **Prose with pills.** In the transcript, references are an attribute on the reply's attributed
  text, and a paragraph that has any is laid out as a flow of text runs and pills
  (`InlineFlow`), with the baseline aligned to the text.
- **VoiceOver** reads the command card as its title followed by "command", a chip as its kind and
  name ("Skill, github-pr-workflow"), and Bot and file pills as "Bot, Ada, @ada"
  or "File, Sources/App.swift".

## 5. Acceptance checks

- No bubble in the transcript shows a bare `/command`.
- No reference is ever shown as blue or tinted text, in the composer or the transcript.
- One Delete removes a whole pill; the caret never lands inside one.
- A command typed by hand and one picked from the menu look the same once sent.
- Unknown commands still render (fallback icon, raw command as title).
- Commands that need the gateway protocol say so on an API-server-only chat instead of failing
  silently.
- Light, dark and Increase Contrast match the design.

## 6. Setup

"/" commands run over Bot Mode ([setup.md](setup.md) §4.1).
