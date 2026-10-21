# Quick actions: approvals and other requests from Hermes

Mid-turn, Hermes can stop and ask the person for something: permission to run a command, an
answer to a question, a key, a password, a code, a sign-in. The app answers each request with a
card of buttons and small inputs so the person rarely has to type. This document covers where the
cards appear, which card each request gets, what each answer sends back, approvals in detail, and
the rules that keep secrets out of the chat.

Code: `HermesRequest` (`Packages/HermesKit/Sources/HermesKit/BotMode/HermesRequest.swift`) and
`ApprovalRequest` (`Models/SessionModels.swift`) in HermesKit; the "Requests" section of
`App/Model/ConversationModel.swift`; `App/Views/Chat/ApprovalCard.swift`; and
`App/Views/Requests/` (`RequestCard` for everything but approvals, `RequestDock` for the dock,
receipts and the permissions sheet, `RequestParts` for the shared pieces). Server requests arrive
over the backend socket, which opts in with `client.capabilities {server_requests: true}`, and are
routed to their chat by `BotRoster`. Names in backticks such as `approvalAsk` or `needsYouDock` are
the design's component names, used in code comments.

## 1. Where a card appears

- One request card at a time, docked above the composer as a single Liquid Glass card, not inline
  in the transcript. It rises out of the composer and sinks back into it once answered. While an
  approval waits, the turn header reads "Waiting for your approval"; for other requests it keeps
  the running tool's title ("Asking a question…").
- An approval always takes the card first; other requests follow, oldest first. Several approvals
  at once (parallel tool calls) share one batch card (§3).
- The card is never wider than the screen. Questions and picks wrap; in a card of several
  questions each earlier answer is one line ("Which Google Workspace…: Yes—Gmail, Calendar…") that
  truncates inside the card, and tapping it goes back to that question. Rows of chips wrap and a
  chip too long for a line shortens its text (`FlowLines`).
- A card with a deadline shows a countdown in its header ("m:ss", red under 30 s). Connection
  requests carry one (`deadline_at` or `timeout_seconds`); other requests do when their params
  include `timeout_seconds`.
- While the person types in the composer on iPhone (and iPad in compact width), the card steps
  aside for the compact `needsYouDock` bar: "Hermes is waiting for you" (or the Bot's name) and
  what is waiting. Tapping it brings the card back. For a single short command shown whole (and
  not flagged), the dock also offers Deny and Allow right there; for a memory save, Don't Save and
  Save.
- When a request is settled, the card leaves and a one-line receipt is added to the transcript
  (`ReceiptRow`). Receipts are the app's own; Hermes doesn't store them. No secret, password or
  code ever goes into a receipt.
- Hermes can withdraw a request (`request.cancel` with `id`, `method`, `reason`). Only the card or
  waiting approval with that id is removed, with a receipt for the reason:

| `reason` | Receipt |
|---|---|
| `timeout` | "Hermes stopped waiting · no answer in time" (`requestTimedOut`) |
| `resolved` | "Answered on another device" (`requestAnsweredElsewhere`) |
| `interrupted` | "Cancelled · you stopped this reply" (`requestInterrupted`) |
| anything else (`shutdown`, `session_closed`…) | none; the card just goes |

- After a reconnect, `session.resume` brings back the chat's open requests (`open_requests`) and
  any pending connection (`pending_connection`), so their cards return.
- Answered on another device: Hermes settles a request with the first answer from any client and
  tells the others nothing (no `request.cancel`; a later answer to that id is dropped without a
  word). So each device asks itself (`RequestSync`): when it attaches or comes back, while a card is
  up and the chat moves on (`session.events.since` lists `open_requests` and changes nothing), and
  just before sending an answer. A card Hermes no longer lists goes with "Answered on another
  device", or "Hermes stopped waiting · no answer in time" past its deadline; an answer, password
  or key for it is not sent, and the chat says "Not sent · already answered on another device".
  Questions, approvals, secrets, sudo and the vault prompts all work this way. The mock settles one
  as another device would with `POST /api/mock/answer-elsewhere {"method"}`.

## 2. Request to card

| Request | Card | Inputs | Answer |
|---|---|---|---|
| `approval` | `approvalAsk` | an answer tile per choice Hermes offers | `{choice, all: false}` |
| `approval` with `smart_denied` | `approvalFlagged` | Run Once Anyway, Keep Blocked | `{choice: "once"}` or `{choice: "deny"}` |
| several `approval`s at once | `approvalBatch` | Deny All, Allow All Once, Allow All in Chat, Review Each | one answer per request shown on the card |
| an `approval` titled "Save to memory?" | `Memory.memorySaveAsk` ([memory.md](memory.md)) | Don't Save, Save, Save All in This Chat | `{choice}` |
| `clarify`, one question with choices | `clarifySingle` | radio rows, Something else… | `{answers: {qid: text}}` |
| `clarify`, `multi_select` | `clarifyMulti` | checkbox rows | `{answers: {qid: [label, …]}}`: the chosen labels as a list (a string would be read as one typed answer) |
| `clarify`, several questions | `clarifySteps` | one question per step, Back and Next | all answers in one result; a skipped question is `null` |
| `clarify`, no choices | `clarifyFree` | multi-line text | `{answers: {qid: text}}` |
| `secret` | `secretAsk` | masked field for `env_var` | `{value}` |
| `sudo` | `sudoAsk` | masked password for `command` | `{value}` |
| `vault.unlock_prompt` | `vaultUnlock` | master password | `{value}` |
| `vault.save_login` | `vaultSaveLogin` | username and password | `{value}` holding JSON `{identifier, password}` |
| `vault.code` | `codeAsk` | six digit boxes | `{value}` |
| `connection.request` event, fields needed | `connectCredentials` | one field per `required_env` entry | `connection.respond` |
| `connection.request`, OAuth | `connectSignIn` → `connectWaiting` → `connectDone` | one button, then the browser | `connection.respond`, then `connectors.operation.wake` |
| `connection.request`, plugins or skills | `installAsk` | a switch per item | `connection.respond` |
| `setup_choose`, kind `accent` | `chooseAccent` | colour swatches | `{picked, label}` |
| `setup_choose`, kind `theme` | `chooseTheme` | System, Light, Dark | `{picked, label}` |
| `setup_choose`, other kinds | `chooseOptions` | option rows with detail; `preselected` arrive ticked; `multi_select` decides radio or checkbox | `{picked, label}` (`picked` a list for multi-select), or `{picked: null, said}` for a typed answer |

Server requests are answered with a JSON-RPC response to their id (`srq-…`). A connection is
answered with `connection.respond {owner: {type: "session", session_id}, op_id, result}`, where
`result` is `{targets: [{name, status: "approved" | "skipped", env?}]}`; its card follows
`connection.update` (each target's `state`) until the update says `settled`. Managing connections
outside a chat (accounts, tool switches, servers, built-in toolsets) is in
[connections.md](connections.md).

Skipping or cancelling a value request (secret, sudo, vault) answers with an empty `value`
("Skipped · …"). In a `clarify` card Skip moves past a question, answering it `null`; skipping
every question sends them all as `null`. Skipping a choice sends `{picked: null}`. Skipping a
connection answers each of its targets `skipped`.

Requests without a card:

- `preview.read`, `preview.act`, `terminal.read` and `window.read` are answered by the chat's
  Inspector when it is on screen ([inspector.md](inspector.md)); otherwise they are declined, so
  Hermes stops waiting at once.
- A request for a session no open chat shows is declined with code 4404 ("This chat isn't open in
  the Hermes app.").
- Everything else (`tour`, `display.install.sudo`, and any method the app doesn't know) is
  declined as unsupported (-32601), never left waiting.

Not built yet: Hermes' current onboarding and theme requests, `setup_beat`, `theme.pick` and
`theme.apply`. They are declined as unsupported. The `setup_choose` cards above serve gateways that
still send it (and the mock).

## 3. Approvals in detail

Fields used: `request_id`, `command`, `description`, `tool_name`, `choices`, `allow_session`,
`allow_permanent`, `smart_denied`, `pattern_keys` (or `pattern_key`), and `title` for memory
saves. `command`, `description` and `title` pass through `VisibleText`, so invisible and
reordering characters show as their codes (`⟨U+202E⟩`) and the person sees what will really run.

- Header: "Run this command?" ("Hermes needs your permission" when there is no command), then
  who is asking and the tool ("Hermes · terminal"; the Bot's name in a Bot Chat).
- Command box: `command` in monospace; the risk chip shows `description`.
- Every answer Hermes offers is a visible tile with its scope in one line. No answer is hidden
  in a menu.

| Tile | Shown when | Sends |
|---|---|---|
| Deny ("Don't run it") | always | `choice: deny` |
| Allow Once ("Only this command", primary) | always | `choice: once` |
| Allow in This Chat ("Until this chat ends") | `choices` has `session`, `allow_session` is not false, and the command isn't flagged | `choice: session` |
| Always Allow ("Every chat, saved") | `choices` has `always`, `allow_permanent` is not false, and the command isn't flagged | after "Always allow commands like this?", `choice: always` |

- With two tiles only (Deny, Allow Once) they sit in one row.
- The footnote names what an allow covers, from `pattern_keys` or `description` ("Allowing covers
  recursive deletes like this one. Change it any time in Chat Permissions."), when a session or
  permanent allow is offered.
- A flagged command (`smart_denied`) gets its own card: "Hermes's safety check flagged this",
  "You can still run it once if you trust it.", Run Once Anyway and Keep Blocked (recommended).
  It is answered only here, never from a notification, the Lock Screen or the dock.
- Keyboard on Mac and iPad: Return allows once, Escape denies. On a flagged card Return keeps it
  blocked. On the batch card Return allows all once and Escape denies all.
- **Batch card.** Shown only when every waiting command shows whole on the card and none is
  flagged or a memory save; otherwise they are answered one at a time. Allow All in Chat appears
  when every one offers it, and an "Always Allow All…" link when every one offers that, with its
  own confirmation. The batch answers exactly the approvals it showed (by id); one that arrived
  after it was drawn waits for its own answer.
- The … menu holds optional extras only. Copy Command is always there; the rest need the gateway
  protocol:

| Item | Does |
|---|---|
| Copy Command | copies `command` |
| Ask Hermes to Explain | denies, then sends "Explain what this command does and why you need it." as a steer (or a new message if the turn has ended) |
| Deny with a Note… | denies, then sends the note the same way |
| Allow Everything in This Chat… | after a confirmation, `config.set {key: "yolo", value: "on", session_id, scope: "session"}`, and allows the command on the card once |
| Chat Permissions | opens the permissions sheet (`qaPermissions`) |

- Receipts: "Allowed once · …", "Denied · …", "Always allowed · …", and for a session allow
  "Allowed in this chat · …" with Manage, which opens the permissions sheet (`approvalReceipt`).
  A batch says "3 commands". Memory saves: "Saved to memory · …", "Not saved · …", "Saving to
  memory in this chat · …".
- The permissions sheet ("Chat Permissions") has an "Allow Everything in This Chat" switch, which
  follows `session.info`'s `yolo`, and lists what was allowed in this chat from approval cards on
  this device ("Nothing allowed for this chat yet."). Its footer says these end with the chat, and
  that commands always allowed apply in every chat and are reviewed with `/approvals`. Hermes has
  no call to revoke a single session permission, so the list can't remove one.
- Over the API server (no backend socket), only approvals exist:
  `POST /v1/runs/{id}/approval {choice, request_id}`, one at a time; `approval.responded` in the
  run's events clears the card, and a 409 means it was already settled. The … menu then offers
  only Copy Command. A busy or unreachable gateway gets the answer when it can: it's asked again
  after 2, 4, 8, 16, then every 30 s, for up to four minutes (Hermes waits five; a repeat that lands
  after the first is that 409); only then does the card come back with the error.
- **Answers the gateway can't take yet** (`AnswerLedger`). Hermes acknowledges no answer: it
  resolves the request id it's given if that request is still open and drops it otherwise. So an
  approval, question or choice answered over the socket is kept by its id until the next attach
  says how it went. With no socket to send it on (reconnecting, a pause), the card goes as usual
  and a receipt says "Your answer goes to <Mac> when it's back"; on attaching, if Hermes lists
  that request in `open_requests` the answer goes again, to that id only, and the card isn't
  shown a second time. An answer written to a socket that died before Hermes read it goes again
  the same way. One that never went out to a request Hermes stopped waiting for (approvals wait 5
  minutes) says "Hermes stopped waiting before your answer got there". A flagged command's answer
  still comes only from its card. Passwords, keys and codes are never kept: with no socket the
  card comes back to be answered again.

## 4. Inputs inside cards

- Choice rows are whole-row buttons. A pick is a choice, not a send: Send (or Next, in a
  multi-step card) confirms it, and Return does the same on a keyboard. In multi-select the
  Submit button shows the count and needs at least one pick.
- "Something else…" turns into an inline "Your answer" field; Send in the footer sends it.
- Masked fields never echo into the transcript. The eye reveals the value. On iPhone and iPad an
  empty key field offers the system Paste button; password fields don't. Password fields set
  `.textContentType(.password)` so AutoFill offers passwords; the code card uses `.oneTimeCode`
  and the number pad, and has Paste Code on the Mac.
- The code card takes six digits and sends on the sixth.
- The fine-print line under a field says where the value goes and how long it is kept. Keep that
  text; it is part of the trust model:

| Card | Fine print |
|---|---|
| `secretAsk` | "Saved to the gateway's .env. Never shown in chat or sent to the model." |
| `sudoAsk` | "Used for this command only. Hermes doesn't keep it." |
| `vaultUnlock` | "Goes straight to {name} on {gateway}. Only a session token stays, and it locks after 30 minutes idle." (Keep Locked / Unlock) |
| `vaultSaveLogin` | "Saved encrypted in Hermes's vault on {gateway}. Hermes fills it in and never sees it." (Not Now / Save & Sign In) |
| `connectSignIn` | "Opens {host} in your browser. Hermes never sees your password." |

- Connection fields: the label is the variable name plus "required" or "optional"; `secret`
  decides masked or plain; defaults fill in; Connect waits for every required field.
- OAuth: Sign In tells Hermes to go ahead (`connection.respond` with `approved`), opens the
  sign-in in `ASWebAuthenticationSession`, then tells Hermes the browser came back
  (`connectors.operation.wake {owner, op_id}`). The card shows `connectWaiting` ("Waiting for you
  to finish in the browser…", Cancel, Open Again) until `connection.update` reports the target
  connected, then `connectDone`.

## 5. Buttons

Every card footer is a pair: secondary (Skip, Cancel, Back, Not Now, Skip All) on the left and
the primary action on the right (Save Key, Run, Unlock, Save & Fill, Continue, Connect, Install N,
Send, Next, Submit), equal widths. Escape triggers the secondary and Return the primary.
Approvals use answer tiles instead, and the first OAuth step is one full-width "Sign In with …"
button.

## 6. Voice

During a call the approval card docks at the bottom and can also be answered by voice
(`talkApproval`, [voice.md](voice.md) §4.3; `SpokenAnswers.approval`): "allow once" (or a short
yes such as "yes", "go ahead", "run it"), "allow in this chat", or "deny" (any no, at any time).

- A yes said within 2 s of the card appearing is refused, so the person reads it first.
- "Allow in this chat" falls back to Allow Once when the chat allow isn't offered.
- These need a tap on the card, whatever is said:
  - Always Allow;
  - a command Hermes's safety check flagged (`smart_denied`);
  - anything that deletes, wipes, kills or spends (`SpokenAnswers.isIrreversible`).
- Allowing everything in the chat can only be turned on from the card's … menu.

## 7. Acceptance checks

- Every request in the table produces its card, and every answer reaches Hermes in the shape
  listed.
- Tiles shown match the `choices` and `allow_*` flags exactly.
- A withdrawn request clears only its own card.
- Answers go to the request the person saw, by id, never to "whatever is pending now".
- A question answered on the iPhone leaves the Mac within a second of the turn moving on, and the
  other way round; a device that was asleep or in the background takes the card down when it comes
  back; a card answered on both sends only the first answer (`POST /api/mock/answer-elsewhere`).
- With the mock backend's sockets cut (`POST /api/mock/drop-sockets {"outage": 10}`) just before
  Allow Once on an "approve" card, the receipt says the answer goes when the Mac is back, and the
  command runs once the socket is back, without the card showing again.
- No secret, password or code ever appears in the transcript, receipts, logs or notifications
  (push rules: [notifications.md](notifications.md)).
- Flagged commands can only be run from their card in the app.
- Cards work with VoiceOver, Dynamic Type and a hardware keyboard.
- No card is wider than the screen: "clarify pair", answered with its long first pick, shows
  "Question 2 of 2" whole on the smallest iPhone, an iPad and the Mac (`RequestCardUITests`).
- Against the mock backend (`Tools/mock-hermes/chats.py`), words in a message ask for each card:
  "approve", "batch", "flagged", "clarify" (and "clarify steps", "clarify multi", "clarify open",
  "clarify long" for picks of three lines, "clarify pair" for two questions with a long first answer),
  "secret", "sudo", "unlock", "save login", "2fa", "choose accent", "choose theme", "choose apps",
  "connect linear", "sign in", "install" and "timeout".

## 8. Setup

Requests are answered in the chat with nothing to set up. Answering from a notification needs
notifications and, on iPhone and iPad, the push plugin ([setup.md](setup.md) §4.13); approvals in
widgets need Face ID, Touch ID or a passcode (§4.15).
