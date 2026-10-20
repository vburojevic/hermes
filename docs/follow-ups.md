# Sending while Hermes works (steer, redirect, queue, aside, background)

The app never refuses a message typed while a turn is running. The person picks what Hermes
should do with it, and the chat shows what actually happened to it, from the gateway's answer and
the events after it, never just from the mode that was picked. This document covers the five
modes, how each reaches Hermes on each transport, the queue tray, and how the chat shows each
message along the way.

Code: `App/Model/FollowUps.swift` (modes, records, the queue store, the Settings picker), the
"Sending while Hermes works" section of `App/Model/ConversationModel.swift`,
`App/Views/Composer/FollowUpComposer.swift` (mode chip, mode menu, queue tray, editing strip),
`App/Views/Chat/FollowUpTranscript.swift` (captioned bubbles, redirect mark, missed card), and
`FollowUpStatus` in HermesKit. Names in backticks such as `modeChip` or `steerMissed` are the
design's component names, used in code comments.

## 1. The five modes

| Mode (chip label) | What it does | Hermes call | In the chat |
|---|---|---|---|
| **Steer** | Hermes reads it after the current step and keeps going | Gateway protocol: `session.steer {session_id, text}`; `queued` means accepted, not read yet. API server: `POST /v1/runs/{id}/steer {input}` | A dashed bubble with a spinner, then the read bubble and a "Read your note" step in the timeline (§2) |
| **Redirect** | Stops the current step and changes course | `session.redirect {session_id, text}` (gateway protocol only) | `redirectMark`, the message captioned "Redirect", then a new running turn (§3) |
| **Send Next** | Waits until this reply is done, then sends it as the next turn | Held by the app in the queue tray; sent with `prompt.submit {session_id, text, queued: true}` over the gateway protocol, or as a new `/v1/runs` turn | Nothing until it sends; then the bubble captioned "Sent from the queue" (§4) |
| **Ask Aside** | A quick answer on the side; the turn keeps going | `prompt.btw {session_id, text}` → `{task_id}`, answered by `btw.complete {task_id, question, text}` | The side answer after the chat (`asideCard`): "Aside", the question, "Answering…" then the answer, and Dismiss |
| **Run in Background** (chip: "Background") | Another Hermes works on it; the result lands here | `prompt.background {session_id, text}` → `{task_id}`, answered by `background.complete {task_id, text}` | The bubble captioned "Run in Background", "Working in the background: …" (`backgroundStarted`), then "Finished in the background" with Open (`backgroundCard`) |

- **Which modes a chat has.** Over the gateway protocol (the backend's socket, Bot Mode) all five.
  A chat that only has the API server can Steer and Send Next; a picked or default mode the chat
  can't do falls back to Steer.
- **Default mode.** Settings → Chat → "Sending while Hermes works" offers Steer, Redirect and Send
  Next (the modes Hermes' own `busy` setting has). The choice is app-wide, stored on the device
  (`followUpDefault`), and **defaults to Steer**, because Steer never throws work away. Changing it
  also writes Hermes' setting on every connected gateway with `config.set {key: "busy", value}`
  (`steer`, `interrupt` for Redirect, `queue` for Send Next), so other clients behave the same.
  While the app has no choice of its own, opening Settings adopts a gateway's value from
  `config.get {key: "busy"}`, unless it is Hermes' default, `interrupt`.
- **Per message.** The mode chip (`modeChip`) takes Think's place while a turn runs and the field
  has text or an attachment (not while dictating, in command mode, or while steering a helper). It
  shows the mode Send will use. Tapping it puts the keyboard away and opens the mode menu
  (`modeMenu`): each mode with its one-line detail, and a footer naming the default and where to
  change it. The pick applies to this message only; the chip goes back to the default after
  sending. While a turn runs, the Send button reads "Send, Steer" (or the picked mode) to
  VoiceOver.
- **Mac keys.** Return sends with the default mode, ⌥Return sends next, ⌘Return redirects. The
  Settings picker's caption on the Mac says so: "Return uses this; ⌥Return sends next, ⌘Return
  redirects." With no turn running, ⌥Return is a new line and ⌘Return sends. ⌘Return redirects
  only when "Send with Return" is on and the chat can redirect; otherwise it sends with the
  default mode.
- **Fall-backs.** Hermes can only steer with text:
  - A Steer or Redirect with images, files or skills waits for the next turn instead. Over the
    gateway protocol (without skills) the app attaches the images and files to the session and
    sends `prompt.submit {queued: true}`, so the gateway holds it: it shows in the tray,
    read-only (§4). Otherwise it goes to the app's own queue.
  - A redirect the gateway answers with `queued` (the agent was still starting, or the chat is
    being compacted) is held by the gateway for the next turn, and shows in the tray.
  - A redirect sent while a tool runs is delivered by Hermes like a steer, after the tool's
    result: it shows as a steer captioned "Redirect · Hermes reads it after this step".
  - The chat always shows the state the gateway's answer implies (`FollowUpStatus`: `streaming`,
    `queued`, `steered`, `redirected`, `rejected`), not the mode that was picked.

## 2. Steer, in detail

1. On Send, a dashed bubble appears at the end of the running turn, captioned "Steer · Hermes
   reads it after this step" (`followUpBubble`). No spinner: the dashed border is the sign it
   hasn't been read ([chat.md](chat.md) §4a). `session.steer` answering
   `queued` (or `steered`) means Hermes accepted it; any other answer, or an error, turns it
   into `steerMissed` at once.
2. Hermes has no event for a steer being read: it goes in with the result of the step that was
   running. So a tool finishing arms the steers waiting at that moment, and whatever Hermes does
   next (a tool starts, text, reasoning, narration, a subagent) marks them read. The bubble turns
   solid and moves before what Hermes went on to say, captioned "Steer · read after “Listed
   snapshots”" (the step's past-tense title), and a `steerStep` ("Read your note" and the quote)
   is inserted in the timeline at that point.
3. If the turn ends before Hermes read it:
   - Over the gateway protocol, Hermes sends unread steers as the next turn by itself. The bubble
     stays dashed, captioned "Steer · sends as the next message", and when that turn starts the
     message appears captioned "Steer · sent after the reply". If no turn comes within 6 s, the
     steer is missed.
   - After Stop, or over the API server, it is missed straight away.
   - Steers the stored transcript shows as read are taken from there.
4. A missed steer (`steerMissed`) shows "Hermes finished before reading your note", the quoted
   message, Discard, and Send as Message (ink). Send as Message sends it as a normal message, or
   puts it first in the queue if a turn is running. Nothing is ever sent without asking.
5. Several steers in a row keep their order; each gets its own bubble.

## 3. Redirect

- `session.redirect`. When Hermes answers `redirected` (or `steered`) with no tool running, the
  work so far stays in the chat as it was, `redirectMark` ("Changed course · Stopped while
  thinking", or "writing", or the running step) closes it, the message follows captioned
  "Redirect" (`followUpBubbleRedirect`), and a new running header starts below.
- With a tool running, Hermes doesn't stop the tool: the redirect shows as a steer (§1).
- `queued`: the gateway holds it for the next turn; it shows in the tray, read-only.
- `rejected` (the reply ended first): it goes first in the app's queue and sends next.
- No answer: the text goes back in the field with "Couldn't redirect Hermes. Your message is
  back in the field."
- Over the API server there is no redirect; Redirect sends a steer.

## 4. The queue (Send Next)

- **Where:** at the top of the composer (`queueTray`). The header reads "Up next · sends when this
  reply is done", or "Up next · Send sends the first" after Stop, with Clear. Items are numbered
  in send order (`queueItem`: number, one line of text or the file name or "Photo", a paperclip
  if it has attachments, a drag handle). Three show; more fold into "+N more", which shows them
  all.
- **Actions:**
  - Drag to reorder.
  - Tap to edit (`composerQueueEditing`): the item leaves the queue while it is in the field, its
    attachments and skills come with it, and anything already typed is set aside. The strip says
    "Editing queued message 2 · Send puts it back", and Send returns it to its place; the close
    button puts it back unchanged. Picking another mode on the chip while editing sends it now
    that way instead.
  - Long press (`queueItemMenu`): Edit, Steer Now (sends it as a steer into the running turn; Send
    Now when nothing runs), Move to Top, Remove.
- **Draining:** when the turn has settled (`session.info {running: false}` over the gateway
  protocol, the run's end over the API server) the first item goes as the next turn. Over the
  gateway protocol it is sent with `prompt.submit {queued: true}`, so Hermes never turns it into a
  steer. It appears captioned "Sent from the queue" and the rest move up. One at a time: the next
  item waits for that turn to end too. Messages the gateway holds go before the app's queue.
- **Stop:** the trailing Stop interrupts the turn (`session.interrupt`, or
  `POST /v1/runs/{id}/stop`) and does **not** drain the queue. The tray stays, and Send with an
  empty field sends the first item. The next turn that starts resumes draining.
- **Survives:** the queue is kept per chat on the device (Application Support,
  `FollowUpQueues/<chat>/`, attachments included) and survives app restarts. It waits while the
  gateway is unreachable and drains on reconnect, after a resumed turn ends. Removing the gateway
  removes its chats' queues.
- **The gateway's own queue.** A message Hermes holds itself (attachments or a fall-back, §1)
  shows first in the tray, read-only, marked "on <gateway name>". After a reconnect the app
  reads it from `session.resume` (`queued`), shows one held message, and expects it as the next
  turn.

## 4a. iPad

The same caption lines and queue tray, with the composer centred at the reading width. With a
hardware keyboard (iPad, or an iPhone with one): Return sends in the default mode, ⌥Return opens
the mode menu while a turn runs (when the chat has more than one mode), and ⌘Return sends as Send
Next while a turn runs, or sends normally otherwise. With no turn running, ⌥Return is a new line.

## 5. Accessibility

- The mode chip reads "Send mode, Steer, button". The menu options read their title and detail,
  and the current one is selected.
- The queue tray is a container labelled "Up next". Each item reads "2. the message" (", with
  attachments" when it has them), with the hint "Edits the message" and the actions "Move up",
  "Move down", "Steer Now" (while a turn runs) and "Remove". The drag handle, number badge and
  paperclip are hidden from VoiceOver. A held gateway item has the hint "Waiting on <gateway>; it
  can't be changed here".
- Bubble captions are read before the message ("Steer, read after Listed snapshots: Skip the
  snapshots from this week").

## 6. Acceptance checks

- Each mode sends the call in §1 and the chat shows the matching state.
- A steer never becomes an interrupt, and a queued message never becomes a steer: queued sends
  carry `queued: true`; don't bypass it.
- With three queued messages, they send one per turn, in tray order, after reordering.
- A steer that arrives too late always ends as `steerMissed`, never silently lost.
- Stop leaves the queue intact, and Send then sends the first item.
- The Mac shortcuts match the Settings caption.
- Against the mock backend, a message with the word "snapshot" starts a long turn to steer,
  redirect and queue against (`run_snapshots_turn` in `Tools/mock-hermes/chats.py`).

## 7. Setup

Which modes a chat has depends on its connection: all five over Bot Mode ([setup.md](setup.md)
§4.1).
