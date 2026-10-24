# Undo and checkpoints

When checkpoints are on, Hermes saves the chat's folder just before a turn's first file write. The
person can see what a turn changed, undo it (files back as they were, the turn removed from the
chat, the message returned to the composer), go back further through a timeline, or restore a
single file.

This doc covers the gateway calls behind checkpoints, the undo bar and its sheets, the timeline,
the off and failure states, and what to check. Checkpoints need Bot Mode: `rollback.*` live on the
backend's JSON-RPC socket, so chats on a gateway without a linked backend have no undo bar.

The code lives in `Packages/HermesKit/Sources/HermesKit/Checkpoints/` (`CheckpointsClient`,
`CheckpointMatcher`, the diff and stat parsers in `CheckpointModels`), `App/Model/CheckpointsModel.swift`
(one per chat, owned by its `ConversationModel`) and `App/Views/Checkpoints/`. The mock is
`Tools/mock-hermes/checkpoints.py`; its demo chat, switches and debug flags are in
[development.md](development.md).

Design component names: `turnCheckpoint` (+ `Busy`), `checkpointFileRow` (+ `New`), `checkpointRow`
(+ `Now`), `restoredNote`, `checkpointsOff`; screens `reviewChanges`, `undoConfirm`, `afterUndo`,
`checkpointsTimeline`, `checkpointDetail`, `checkpointsOffSheet`, `macCheckpoints`,
`ipadCheckpoints`. The diff itself is the chat's `DiffCard`.

**Entry points:** Undo on a turn's Changes row; the reply menu's "Undo File Changes…"; a chat's
menu in the sidebar and in a project home's lanes → "Checkpoints…"; and on the Mac the Chat menu →
Checkpoints… and Undo File Changes… (⌥⌘Z, the newest reply that changed files).

The source is the gateway: `tui_gateway/methods_tools.py` (`rollback.*`),
`tools/checkpoint_manager.py`, and `hermes_cli/config_defaults.py` → `checkpoints`.

## 1. Calls

Every call takes the chat's **runtime** session id (the app attaches the chat first if it isn't
yet). `rollback.*` ignore the profile, so none is sent; unknown parameters are rejected (4000).

| Need | Call | Notes |
|---|---|---|
| Are checkpoints on, and the list | `rollback.list {session_id}` | `enabled`, then `checkpoints[]`: `hash`, `timestamp` (ISO 8601 with offset, whole seconds), `message`. Newest first. For the chat's working folder, so it includes other chats in the same folder |
| What changed since a checkpoint | `rollback.diff {session_id, hash}` | `stat` (`git diff --stat`) and `diff` (unified, checkpoint on the minus side, now on the plus side, **capped at 4000 characters**). The app parses both (§1.2) |
| Undo a turn / Restore All | `rollback.restore {session_id, hash}` | Restores the folder and drops the chat's **newest** user turn (`history_removed` = messages dropped). **Refused while a turn runs** (4009) |
| Restore one file | `rollback.restore {session_id, hash, file_path}` | Only that file; the chat is untouched. Allowed mid-turn |
| Drop more turns | `session.undo {session_id, intent: "undo"}` | Once per extra turn when going back further than the last turn (§3) |
| Turn checkpoints on | `PUT /api/config {config: {checkpoints: {enabled: true}}, profile}` (REST) | `config.set` rejects this key. Off by default |
| Make the open chat read it | `session.close {session_id}`, then resume | A chat's agent reads `checkpoints.enabled` only when it is built, so the open chat is reattached once idle |

Restore results: `success`, `restored_to` (8 characters), `reason`, `directory`, `file`,
`history_removed`, `error`. Gateways that restore in safe mode also send `restored_files`,
`skipped_oversize`, `skipped_user_edits` and `failed_deletes`; the app turns those into the
`restoredNote` lines when present.

Errors (`CheckpointFailure`):

| Code | Meaning | The app says |
|---|---|---|
| 4009, or `session_busy` (gateways with session authority) | A turn is running | "Hermes is still working. You can undo when it stops." |
| 5022 on `rollback.diff`, or `{success: false, error}` from restore | The chat runs in a container or remote backend (`_container_checkpoint_refusal`) | The gateway's reason; Undo is hidden |
| 5020, 5021, 4014 | List or restore failed, or no hash | The gateway's message, or for coded reasons a sentence ("That checkpoint is gone. Hermes may have pruned it.") |

Limits from the gateway: the last 20 checkpoints per folder, kept 7 days, 500 MB in all, files over
10 MB never saved. `hermes serve` builds its chats with these defaults whatever the config says.
The off state and the timeline footer show them.

### 1.1 What the real gateway does

- A checkpoint's `message` names the tool, never the turn: "before write_file", "before patch",
  "before terminal: <command>" (a command that looked destructive), "pre-rollback snapshot
  (restoring to 1a2b3c4d)", sometimes with " [nested git repos not captured: …]". Nothing links a
  checkpoint to a turn, and a turn can have several (one per loop step).
- A whole restore is a full overwrite (`git checkout <hash> -- .`): files changed since go back,
  but **files created after the checkpoint stay**. The safe-mode lists aren't sent.
- Every restore first saves a "pre-rollback snapshot", so a restore can itself be undone from the
  timeline (the files only; the dropped turns don't come back).
- Hashes change when Hermes prunes past 20. The app keys checkpoints by time and message, lists
  again before every diff or restore, and sends the full 40-character hash (a short hash made only
  of digits reads as a list position).

### 1.2 Matching checkpoints to turns

`CheckpointMatcher` splits the transcript into spans, one per message the person sent, from its
time to the next one's. A checkpoint belongs to the span whose time holds it (checkpoint times are
whole seconds, so a span starts at the second its message was sent), and a reply's **undo point**
is the earliest checkpoint in its span. Pre-rollback snapshots belong to no turn. The timeline
shows one row per turn (its earliest checkpoint) plus every checkpoint that belongs to no turn
here: another chat in the same folder, a restore's snapshot, or a command.

The diff's file rows come from the unified diff's sections (new, deleted, renamed and binary
files included). Files past the 4000-character cut come from the stat, whose +/− bars are scaled,
so their split is approximate; a stat path shortened to `.../tail` can't be restored on its own.

## 2. In the chat

- A reply whose tools wrote files (`write_file`, `patch`, or any tool that sent a diff) shows its
  Changes row under the turn header ([chat.md](chat.md) §1): "Changed 3 files · +41 −12". When the
  reply has an undo point, **Undo** (`turnCheckpoint`) sits at the row's end; the row itself is
  the review (its files and diffs, from the turn). The counts come from the turn itself, so they
  read the same live and from history.
  - It shows only when checkpoints are on and the reply has an undo point (§1.2).
  - The list loads when a chat with file edits opens, as an edit lands, and when a turn ends.
  - When checkpoints are off the bar is hidden, and the reply menu's "Undo File Changes…" opens
    the off sheet. When no checkpoint matches, it opens the timeline.
- While Hermes is still working, Undo is dimmed, its hint "Undo is available when Hermes stops"
  (`turnCheckpointBusy`). The row still opens the changes. Offline, Undo is disabled too; for a chat the gateway
  refuses (a container), there is no Undo at all.
- **Review:** the Changes row opens the turn's own files and diffs (the Changed Files tab on the
  Mac and iPad landscape, the Changes sheet elsewhere). What changed since a checkpoint, as git
  sees it, is the timeline's checkpoint detail (§3) and the Inspector's **Changes** tab on This
  Turn.
- **Review** (`reviewChanges`, full-height sheet): the files with +/− and "new" for files Hermes
  created, the selected file's diff ("Tap a file to see its diff. Undo puts all three back as they
  were at 14:31."), and Done / **Undo This Turn** in a bottom glass bar. A shortened diff says
  "The diff is shortened: Hermes sends its first 4,000 characters."
- **Undo** (`undoConfirm`, a partial sheet sized to its content):
  - "Undo this turn?" and "Hermes puts these files back as they were at 14:31 and removes the turn
    from this chat. Your message comes back to the composer."
  - The files (six, then "and N more").
  - An orange warning: changes made to those files since then are replaced too, and files Hermes
    created stay ("Notes.md stays: Hermes doesn't delete files it created.").
  - Cancel / **Undo Turn** (destructive). Disabled while Hermes works or the gateway is offline.
- **After** (`afterUndo`):
  - The turn is gone, and `restoredNote` sits where it was ("Restored 3 files to before 14:31 and
    removed that turn"), with grey lines for anything kept (too large to checkpoint, edited by you
    after Hermes, files Hermes created that are still there) and orange lines for what failed
    (files it couldn't delete, earlier turns it couldn't remove).
  - The undone message is back in the composer with a strip "Undone · your message is back to
    edit". Closing the strip discards it and gives the composer back what it held before.
  - There is no redo for the chat. The files can be put back from the timeline's pre-rollback
    snapshot.

## 3. Timeline and detail

- **Checkpoints** (`checkpointsTimeline`, iPhone): "Folder ~/Code/hermes-app on Studio Mac", then
  "Now" (current files, folder and branch), then each checkpoint, newest first: time ("14:31",
  "Yesterday 18:40"), what it was before ("Before “Fix the reconnect after sleep”", "Before going
  back to 13:02", "Before “rm -rf .build”", "Before a file edit in another chat"), and "N files
  changed after this" (or "Same as now"). Footer: the limits.
- **A checkpoint** (`checkpointDetail`): its time and title, "Compared with the files now", the
  files with Restore on each (`file_path`; a restored file says it is back as it was), the
  selected file's diff, then Done / **Restore All** in the bottom bar. The footer says restoring one
  file doesn't touch the chat and works even while Hermes is busy.
  - Restore All confirms with the same sheet as Undo ("Go back to 13:02?"), listing every turn
    that leaves the chat ("removes 2 turns from this chat:").
  - Restoring an older checkpoint **rewinds the chat to match**. The gateway drops only the newest
    turn, so the app then calls `session.undo` once for each further turn, back to and including
    the checkpoint's own. A checkpoint from elsewhere still costs the newest turn. If a
    `session.undo` fails, the note says how many turns stayed.
- **Mac** (`macCheckpoints`): one 820 × 560 window sheet with the timeline on the left and the
  selected checkpoint's files and diff on the right ("3 files differ from now"). Restore per file,
  then Done / Restore All… in the footer, which says how many turns Restore All also removes.
- **iPad** (`ipadCheckpoints`, regular width): a centred 800 × 600 sheet laid out like the Mac one,
  with Close and Done in its bar. Review on an older reply also opens it.

## 4. States

- **Off** (`checkpointsOff`): "Undo for files is off", what checkpoints do, **Turn On
  Checkpoints** (ink), and the limits. Turn On writes the config (§1), then reattaches the open
  chat when it is idle (or as soon as its turn ends). The timeline then says "Checkpoints are on.
  They start with the next turn that edits files." If the app can't change the setting, the sheet
  shows the command to run on the gateway: `hermes config set checkpoints.enabled true`.
- **No checkpoints yet:** "Nothing to undo yet. Hermes saves the folder before the next turn that
  edits files."
- **Chat in a container or remote backend:** the gateway refuses with a reason
  (`_container_checkpoint_refusal`). The timeline shows that reason; Undo is hidden.
- **Gateway offline:** Undo and Restore are disabled; the timeline shows the last loaded list,
  dimmed, with "<gateway> is offline. This is the last list; restoring waits until it's back."

## 5. Accessibility

- The Changes row reads "Changed 3 files, 41 lines added, 12 removed" as one button, then Undo
  as its own (hint "Undo is available when Hermes stops" while it works).
- The confirmation puts VoiceOver focus on Cancel first; Undo Turn is destructive. Escape cancels.
- A file row reads its path and "new file", "deleted" or "41 lines added, 12 removed".
- Diffs use the chat's `DiffCard`: Dynamic Type, and each line announced as "Added" or "Removed".

## 6. Acceptance checks

- A turn that edits files shows the undo bar; a turn that doesn't, doesn't.
- Undo restores the listed files, removes the turn and puts the message back in the composer; files
  Hermes created are named as still there.
- Restoring an older checkpoint removes every later turn, so the chat matches the files.
- Restoring one file leaves the chat and the other files alone, even while Hermes runs.
- Undo while a turn runs is never sent (4009 handled as "wait").
- After pruning changes the hashes, Review and Undo still act on the right checkpoint.
- The off state turns checkpoints on, and the next file-editing turn shows the bar without reopening
  the chat.
- Light, dark and Increase Contrast render correctly.

## 7. Setup

Checkpoints need `checkpoints.enabled` and a local or SSH terminal ([setup.md](setup.md) §4.6).
Turned off, the sheet turns them on; without Bot Mode it says turning them on needs it, with Edit
Gateway; when the app can't change the setting it shows the command for the chat's Bot (`hermes -p
<profile> …`) with Copy and the docs. In a chat whose commands run in a container the timeline says
Hermes takes no checkpoints there instead of "Nothing to undo yet".
