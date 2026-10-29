# Composer and voice

This document covers the composer (the panel where the person writes, attaches and sends), what
each control does and which Hermes call it maps to, dictation into the field, and where Talk starts.
Messages sent while a turn runs are in [follow-ups.md](follow-ups.md); commands, skills and the
pills in the field are in [commands-and-references.md](commands-and-references.md).

Code: `App/Views/Composer/ComposerView.swift` (the panel and its controls), `PillTextView.swift`
(the text field), `SlashMenu.swift`, `FollowUpComposer.swift`, `ProjectChip.swift`;
`App/Support/DictationController.swift` (speech to text), `VoiceRecorderViews.swift` (voice
messages), `App/Audio/` (the engine, transcription, voices, the recorder and Listen); `App/Model/TalkSession.swift`,
`TalkCenter.swift` and `App/Views/Talk/` (Talk). The audio design is in [voice.md](voice.md). Names in backticks such as `composerEditing`
are the design's component names, used in code comments.

A chat sends over one of two transports (see [chat.md](chat.md) §2): the backend's JSON-RPC
socket ("gateway protocol", whenever the gateway has a linked Hermes backend, and always for Bot
Chats), or the gateway's API server. Several controls only exist on the first.

## 1. Layout

One floating Liquid Glass panel (regular glass, corner radius 28). Top to bottom, each row
appears only when it has content:

1. The queue tray (Send Next, [follow-ups.md](follow-ups.md) §4)
2. A strip for what the field is doing: editing a queued message (`composerQueueEditing`),
   steering a helper (`helperSteer`), Edit and Resend ("Editing · goes in a new chat; this one stays",
   `composerEditing`), or a message given back by Undo ("Undone · your message is back to edit")
3. Image thumbnails
4. Skill chips (up to five, `composerSkills`), then file and PDF chips (`composerFiles`)
5. The text field, with Bot and gateway-file pills inline
6. The command hint line, in command mode (`composerCommand`)
7. Controls: **+**, **Think** (or the mode chip while a turn runs and the field has content), the
   background-process chip (`processChip`, [background-processes.md](background-processes.md)
   §5), the project chip (`projectChip`, [projects.md](projects.md)), a spacer, a short status
   when the gateway is busy, connecting or needs a sign-in, **Dictate**, then one trailing
   button. Bot Chats have no Think control, and its slot takes no room until the mode chip shows
   in it. While dictating, the whole controls row becomes the dictation row (§3). Holding
   Dictate records a voice message instead: the field and controls become the recorder, locked
   and Review panels ([voice.md](voice.md) §2).

The model picker is in the chat's title, not in the composer.

Menus that grow up from the composer (the "/" and "@" menus, a group chat's members) never pass
the top bar or a banner under it, with the keyboard up or down: each is as tall as its rows, at
most 440 pt, and at most the room between the bar's bottom edge and the composer less 8 pt
(`ComposerMenuRoom`); what doesn't fit scrolls inside it. The chat screens measure where the bar
ends (`composerCeiling`), the composer measures its own top (`ComposerTop`, read only by the menu,
so the keyboard moving doesn't redraw the composer), and the bar's height is never animated. The
chat's jump pill sits in the same room: while a menu leaves it none, it steps aside rather than
rise over the top bar.

The trailing button is the only tinted control:

| Situation | Trailing button |
|---|---|
| Field empty, nothing attached | Talk (waveform) |
| Text, images, files, skills or a command present | Send (arrow) |
| Nothing running, field empty, messages queued after a Stop | Send: sends the first queued message |
| A turn is running, field empty | Stop |
| A turn is running, field has content | Send, read to VoiceOver as "Send, Steer" (the mode it will use) |
| Dictating | Done (checkmark), at the end of the dictation row |

Where Talk isn't offered (a helper's page, the Mac project home), the trailing button is a
disabled Send instead of the waveform.

Offline, the panel dims to half opacity and +, Dictate and the trailing button are disabled.

## 2. What each control does

| Control | Behaviour | Hermes |
|---|---|---|
| Send | Submits the text with its images, files and skills; the message appears at once and the chat turns the page ([chat.md](chat.md) §4). If the turn can't start, everything goes back into the field | Gateway protocol: `session.create` or `session.resume`, then `prompt.submit {session_id, text}` (see below). API server: `POST /v1/runs {input, session_id, model, provider, model_options}` with an `Idempotency-Key`, or `POST /api/sessions/{id}/chat/stream` when there are images |
| Stop | Interrupts the running turn; queued messages wait for a Send. What the gateway's own queue held comes back first in Up Next, Not sent, and a receipt names helpers stopped and an approval declined with it ([follow-ups.md](follow-ups.md) §4) | `session.interrupt {session_id}`, or `POST /v1/runs/{id}/stop` (retried while a queued run answers 409). If no end arrives, the app marks the turn stopped after 12 s (15 s over the API server) |
| + → Photos, Camera, Paste | Attach images (up to four per pick from Photos; Camera on iPhone and iPad; Paste takes an image from the clipboard). Images are scaled to 1600 px and kept as JPEG. Disabled where the chat can't send images | `image.attach_bytes {session_id, content_base64, filename}` per image at send time. Over the API server, images need the gateway's session chat stream |
| + → Files | Attach files or PDFs from the device, up to 20 MB each; images picked here become image attachments | `pdf.attach {session_id, content_base64, filename}` sends a PDF's pages as images; anything else, or a PDF the gateway can't render, goes with `file.attach {session_id, data_url, name}` and the prompt carries its `@file:` reference. The API server has no upload: text files and PDFs with a text layer go inline after the message, anything else is refused with an alert |
| + → File on Gateway… | Puts `@` in the field to pick a file on the Hermes machine; the same as typing `@path`. Gateway protocol only, not in Bot Chats | `complete.path` |
| + → Skills…, Commands… | Put `/` in the field and open the slash menu (Skills… opens the full skill list). Shown over the gateway protocol when the gateway has skills | the catalog from `commands.catalog` and `complete.slash`; see [commands-and-references.md](commands-and-references.md) |
| Think | Reasoning effort for this chat: Auto, Off, Minimal, Low, Medium, High, Extra High, Max. Applied when the next turn starts | Gateway protocol: `config.set {session_id, key: "reasoning", value}` when it changed; API server: `model_options.reasoning_effort` |
| Typing `/` | A query capsule in the field and the slash menu above the composer, filtered on the device | — |
| Picking a command that takes an argument | Command mode: command pill, argument placeholder, hint line; Send disabled until the argument is there (`composerCommand`) | on Send: the app's own handling, or `slash.exec` / `command.dispatch` |
| Typing `@`, picking a Bot or path | A query capsule, then an atomic pill inline (`composerReferences`) | `complete.path {word, session_id}` for files (debounced, up to 12 items); the roster for Bots |
| Mode chip (turn running, field has content) | How Send delivers this message: Steer, Redirect, Send Next, Ask Aside, Run in Background (`FollowUps.modeMenu`) | `session.steer`, `session.redirect`, `prompt.submit {queued: true}` at turn end, `prompt.btw`, `prompt.background`; [follow-ups.md](follow-ups.md) |
| Queue tray | Messages waiting for the turn to end; reorder, edit, Steer Now, Remove | held by the app, sent one per turn |

Over the gateway protocol, Send also sets the chat's model and reasoning effort on its session when
they changed (`config.set` with `key: "model"`, value `"<model> --provider <provider>"`, and
`key: "reasoning"`), and expands skills with `command.dispatch {name, arg, session_id}`, whose
`message` becomes the prompt ([commands-and-references.md](commands-and-references.md) §4). If
the backend no longer knows the session, the app resumes it and sends once more. If the socket
refuses a normal chat's turn before anything started, the turn goes to the API server instead.

Attachments are uploaded only when the message is sent, so removing one from the composer needs
no call.

Not built yet: Hermes' `image.generate` and `image.detach`.

## 3. Dictation (speech to text)

Words are transcribed **on the device** and land in the field as normal text. Nothing is sent
until the person taps Send. Dictation holds the audio coordinator's dictation role while it
listens ([voice.md](voice.md) §7): it never sets up the audio session itself, and during a call
it's refused ("Dictation is off during a call").

- Tapping Dictate turns the controls row into the dictation row (`dictationLive`): Cancel, a live
  level meter, the language, the elapsed time and Done. The words land at the caret (over a
  selection), the newest lighter until they settle; typing carries on around them, because the
  dictated span is marked in the field (`PillTextController.beginDictation`).
- Done keeps the words as ordinary text, with the field focused. Cancel takes out only the
  dictated words. There is no silence timeout or time limit.
- The language chip lists the languages on the device, Device Language and Add Language (the
  ones that can download); picking one keeps what was heard and listens again in it. Holding
  the microphone records a voice message ([voice.md](voice.md) §2), so the language switch lives
  in the dictation row rather than on a long press.
- Group chats have Dictate and voice messages too; a voice message there sends its transcript,
  as group chats carry text.
- Speech: `SpeechAnalyzer` with a `DictationTranscriber` (progressive long dictation,
  punctuation, emoji) for the device's language, falling back to US English, fed from the
  coordinator's microphone tap (`SpeechInput`).
- The speech model downloads on first use (`AssetInventory`): the row says "Downloading English
  for dictation · 40%" with a bar.
- It works offline: Dictate stays enabled when the gateway can't be reached.
- Failures are shown in the row, with Try Again and close.
- The level meter follows the audio's power (−50 to 0 dB), updated about 20 times a second.
- Permissions: the microphone, asked on first use. On-device transcription needs no
  speech-recognition permission. If the microphone is off, an alert says "Microphone is off for
  Hermes", with Open Settings on iPhone and iPad.

## 4. Talk

A call with Hermes or a Bot, in the same chat: every spoken turn is a normal message (marked
Spoken), and the reply is read in the Bot's own voice. It opens from the trailing waveform button,
or Chat → Talk (⌥⌘V). The call lives outside the chat: minimising it (the chevron, swiping down)
keeps it going with a pill at the top of the chat ("Type into the call" in the field), and it
survives leaving the chat and the app going to the background. Everything about it, including
its states, audio and system integration, is in [voice.md](voice.md) §4.

## 5. Platform notes

- **Send with Return** (Settings → Chat, on by default): with a hardware keyboard, Return sends
  and Shift-Return starts a new line. The on-screen keyboard's Return always inserts a new line.
- **iPad** (and iPhone with a hardware keyboard): ⌥Return opens the send-mode menu while a turn
  runs, ⌘Return sends as Send Next while a turn runs and sends otherwise, whether or not Return
  sends ([follow-ups.md](follow-ups.md) §4a).
- **Mac:** ⌥Return sends next and ⌘Return redirects while a turn runs; ⌘. (Chat → Stop
  Responding) stops; ⌥⌘V starts Talk, and ends it while a call runs. Dictate is the button only; it has no shortcut of
  its own.
- The slash and `@` menus follow the arrow keys, Tab and Escape, with key hints on iPad and Mac.
- **Paste** (⌘V, Edit ▸ Paste, the field's edit menu): files copied in the Finder or the Files
  app attach as files (pictures among them as pictures); a copied picture attaches as a picture,
  even with its address alongside it (a browser's Copy Image); text goes into the field (pasted
  `@handle`s and `@file:` paths become pills), and wins over a picture of itself (Pages, Numbers).
  `PastePlan` decides. A chat that can't send pictures says so instead. Pastes always land in the
  chat on screen: the field outlives a switch to another chat.
- **Drag and drop:** images dropped on the chat attach on every platform, where the chat can send
  pictures (elsewhere the drop is refused). Not built yet: dropping other files.

## 6. Acceptance checks

- The trailing button follows the table in §1 in every state.
- Dictated text can be edited before sending, and Cancel restores the field.
- A follow-up sent with each mode reaches Hermes as [follow-ups.md](follow-ups.md) §1 says.
- Talk turns appear in the transcript like typed ones, marked Spoken.
- Denied microphone permission never leaves the person stuck: Type Instead and End both work.
- Nothing typed or attached is lost when a send fails: it is back in the field.
- Light, dark and Increase Contrast match the design.
- With the keyboard up on the smallest iPhone, typing "/" opens a menu that ends below the top bar
  and scrolls; the same on iPad, the Mac and in a group chat's "@" menu.

## 7. Setup

Dictation and voice messages need the microphone ([setup.md](setup.md) §4.15); the camera button
needs the camera. Talk's setup is [voice.md](voice.md) §6.1.
