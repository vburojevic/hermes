# Goal: Hermes — a native Apple client for Hermes Agent

Build **Hermes**, one universal SwiftUI app for iPhone, iPad and Mac that talks to
[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) through its
API server, with the calm, monochrome, content-first feel of the Grok apps on
Apple platforms.

## What "done" means

### Connect
- Add any number of Hermes "bots" (a gateway URL — including `/p/<profile>` multiplexed
  profiles — plus its `API_SERVER_KEY`). Keys live in the Keychain, never on disk.
- Adding a bot verifies `/health` and `/v1/capabilities` and explains failures in plain
  language (wrong key, server down, old Hermes version, plain-HTTP over the internet).
- Switch bots from the sidebar; each bot keeps its own sessions and model choice.

### Converse
- Server-side sessions through the Sessions API: list, search, rename, branch (fork),
  delete — including conversations that started in Telegram, Discord, Slack, CLI, etc.
- Streaming replies over SSE with live, readable agent activity: thinking (reasoning),
  tool calls with previews and durations, mid-turn commentary, and the final answer.
- Stop a running turn. Answer tool-approval requests inline.
- Rich Markdown: headings, lists, task lists, quotes, tables, code blocks with copy and
  syntax tint, inline code, links.
- Image attachments (Photos, files, paste, drag and drop) sent as inline images.
- Per-chat model picker fed by `/api/model/options`, plus a reasoning-effort control.
- Copy, share, read aloud; resilient to backgrounding and dropped connections (the turn
  keeps running server-side and the transcript reconciles on return).

### Agent extras
- Tasks: Hermes scheduled jobs — list, run now, pause/resume, delete, create.
- Skills & toolsets browser per bot.

### Feel
- Grok-like: pure black/white canvas, a single floating Liquid Glass composer, user
  bubbles vs. full-width assistant prose, a drawer sidebar on iPhone and a split view on
  iPad/Mac, centered composer on the empty state of wide layouts.
- Native everywhere: Dynamic Type, VoiceOver labels, keyboard shortcuts and menu commands
  on Mac/iPad, haptics on iPhone, light and dark appearance, Reduce Motion respected.

## Quality bar
- Built with Xcode 27 / iOS 27 + macOS 27 SDKs, Swift 6 language mode, strict
  concurrency, zero warnings in our code.
- API contract taken from Hermes source (gateway/platforms/api_server*.py), not guessed.
- Core (API client, SSE parser, models, stores) covered by Swift Testing unit tests.
- Builds and launches on iPhone and iPad simulators and on macOS; screens verified with
  screenshots against a mock Hermes server.

## Status (2026-10-12)

Met, verified on the iPhone 18 Pro and iPad Pro 13" (iOS 27) simulators and on macOS 27
against `Tools/mock-hermes`, with Debug and Release builds clean on both SDKs and 57 package
tests passing. One deliberate difference from the list above: reasoning appears once a turn
is stored, not live, because Hermes' session and run streams don't stream it (only the
OpenAI-compatible routes do).

## Bot Mode (2026-10-12)

Goal: Hermes Desktop's Bot Mode on iPhone, iPad and Mac, faithful to Desktop's protocol
(`profiles.list` roster, the exact-title "Bot Chat", `ui_meta['hermes-bots']` with
compare-and-swap writes, `cron.manage` routines with `deliver: bot-chat`, `@mention` roster
notes, server-request approvals) and better looking than Desktop.

- [x] Backend link per gateway (automatic token, pasted token, password with Keychain cookies)
- [x] Roster with faces, unread, active state, pin and hide; Chats | Bots switch
- [x] Bot Chat over `/api/ws`: streaming, tools, reasoning, approvals, stop, images,
      reconnect with replay and dedupe, fail-closed Bot Chat lookup, `/new` → compact
- [x] @mention autocomplete and roster note; Bot-to-Bot messages and routine results as cards
- [x] Routines: list, add, pause/resume, run now, delete
- [x] New Bot (profile, look, hello turn) and Edit Bot
- [x] Animated faces, Metal aura and ripple, haptics, Reduce Motion and VoiceOver support
- [x] Verified on iPhone, iPad and Mac against the mock backend; read-only check against a real
      `hermes serve` 0.21.6
- [ ] Group chats (Desktop's rooms) — next

## Shipping (2026-10-12)

- [x] Debug = "Hermes Dev" (`co.caffeinatedcode.hermes.dev`, amber icon, demo bootstrap); Release =
      "Hermes" (`co.caffeinatedcode.hermes`), no demo code — separate data, Keychain and settings.
- [x] Caffeinated Code (`29ZNGBT83H`) everywhere: App ID `87NB3969NN`, profile "Hermes App Store"
      (`XLZJR6NKAK`), App Store Connect app "Hermes Agent App" (`6822000332`), internal TestFlight
      group with automatic access to all builds.
- [x] Mac as a notarized Developer ID DMG with Sparkle 2.9.4 (feed on vburojevic/hermes-releases,
      EdDSA key in Infisical prod `/hermes/ci`), iOS/iPadOS via TestFlight.
- [x] `Scripts/release.sh` signs with the escrowed identities in a temporary keychain.

## The Elyx design (2026-10-13)

Goal: the app as designed in the Hermes Elyx project (`~/Documents/Elyx/Hermes`): its tokens,
controls, blocks, every screen and state on iPhone, iPad and Mac, the flows, the comments on
each component, and the six implementation docs (`docs/*.md`). The designs say what it looks
like; the docs say which Hermes call and which Apple API sits behind each control.

**Transport decides what's possible.** Almost everything the design adds (the "/" menu, skills,
clarify / secret / sudo / vault / connection cards, steer / queue / ask aside, plans, diffs,
usage, models, side answers) exists only in the gateway protocol on the backend's `/api/ws`,
not in the API server (`/v1/runs`). So when a gateway has its Bot Mode backend linked, every
chat runs over `/api/ws`, not just Bot Chats. Without a backend, chats stay on the API server
(stream, tools, approvals, steer, stop) and the UI offers only what that can do. Protocol map:
`hermes-protocol-report.md` (thread storage), from the Hermes 0.21.6 source.

Done means each frame matches its Elyx render (checked side by side, light, dark and Increase
Contrast), every documented acceptance check passes, Dynamic Type / VoiceOver / Reduce Motion /
keyboard hold, the mock gateway can show every state, Debug and Release build with zero
warnings, and the package tests pass.

Released as 1.0 (2610132220) on 2026-10-14: TestFlight (internal) and the notarized DMG with its Sparkle appcast.

### M0 Foundation
- [x] Colours generated from the Elyx tokens with all four appearances (`Tools/elyx/generate_palette.py` → `Palette.swift`)
- [x] Ink is only the primary-action tint; links, cursor and selection are system blue again
- [x] Gateway avatar gradient; Bot faces to `docs/bot-faces.md` (depth, gloss, rim, lift, taller eyes, breathing, pointer, bounce, wiggle, contrast outline)
- [x] Debug design gallery (`-HERMES_GALLERY <page>`) to compare components with the renders
- [x] Button levels (ink / prominent, bordered / destructive / tonal, glass, link), chips (`chip`, `chipActive`), tags (`TagLabel`: neutral, success, warning, danger, ink), badges, status dots, state messages, request-card parts (`RequestParts.swift`)

### M1 Every chat over the gateway protocol
- [x] Normal chats over `/api/ws` when a backend is linked (resume / create, submit, events, reconnect); API-server fallback
- [x] Fix: `/api/ws` usage decoding, broadcast events (`approval.cancelled`, `session.reclaimed`), `reasoning.available` on `/v1/runs`
- [x] Mock gateway speaks the new methods and requests, so every state can be shown (combined mode: `backend.py --gateway-port 18642`; `chats.py`: commands, skills, paths, attach, steer, btw, background, branch, every server request, connections, moa, reactions, review, processes)

### M2 Navigation and chrome
- [x] Sidebar / drawer as designed: gateway switcher, Chats | Bots, search, rows (New Chat, Tasks, Skills; All Bots, New Bot, Tasks, Skills; New Group Chat waits for M8), sections, footer status, centred states, row and gateway menus, rename / delete alerts
- [x] Toolbars (model picker capsule with the model's name, Bot Chat title with "Thinking…" in orange), scroll edge effects; page headers. The Mac sidebar stays the system split-view sidebar: `.listStyle(.sidebar)` didn't produce the inset glass pane and broke the row insets
- [x] Bots home grid with All Bots selection; Mac menus (File / View with Show Sidebar / Chat, checked through System Events) and windows; iPad multitasking and multiple windows

### M3 Transcript (`docs/chat.md`)
- [x] Turn headers, step timeline with rails, tool / search / failed / running steps, narration, reasoning, subagents, status lines (checked on the Mac against the mock)
- [x] Markdown as designed; reply actions (+ … menu); stopped, failed, warning; date separators; scroll to latest
- [x] Chat extras from the gateway: diff, output, plan, risk, search results, sources, reaction, usage (+ Settings toggle), context notice, models, aside, background (`/bg`), review, memory, reclaimed, process (`process.kill`). Not yet: image and file results from the agent (no payload sample to build against)
- [x] Message menus (`userMessageMenu`, `replyMenu`; your messages aren't selectable so right-click / long press reach the menu), Edit and Resend and Branch from Here (`session.branch` with `count`), Send Again, Try Again (with…); Bot-to-Bot and routine cards kept

- [x] Reference pills (Elyx 15ab105, `docs/commands-and-references.md`), replacing the blue tint: `MessageParts` kept with each message at send time (command + argument, skills, Bots and gateway files with positions), sent in plain form (`/goal …`, `/skill` prefixes, `@handle`, `@file:path`); text from other clients upgraded (leading `/word`, roster `@handles`, `@file:` / `@folder:` paths). Composer: TextKit 2 `UITextView` / `NSTextView` with one attachment per pill, query capsule, Bots + Files menu, skill tray, command mode, plain-form copy, pill-making paste. Transcript: pills inline in user bubbles, replies and group messages (`InlineFlow`), skill chips above the text, command cards. Previews with Remove / Open (long-press, hover, tap). Released as 1.0 (2610141041) on 2026-10-14

### M4 Composer and voice (`docs/composer.md`)
- [x] + menu, Think, Dictate (on-device speech), trailing Voice / Send / Stop, attachments, files (`file.attach` / `pdf.attach`, inline text on the API server), offline
- [x] Follow-ups while a turn runs: Steer Now, Send After (queued strip), Ask Aside (aside card); checked on the Mac against the mock (`-HERMES_SEND`, `-HERMES_FOLLOWUP`)
- [x] Voice mode: listening, thinking, speaking, Bot, approval, no microphone, offline (states checked in `-HERMES_GALLERY voice[:3|:6]`; pause-to-send, barge-in and echo cancellation still need a real iPhone)

### M5 Commands, skills and references (`docs/commands-and-references.md`)
- [x] "/" menu (skills, commands, filtering, values; ↑↓ ↩ ⇥ esc), skill chips (up to five, `command.dispatch`), @mentions (Bot Chats), @path (`complete.path`, + → File on Gateway…)
- [x] Command cards (also for "/word" text from other clients), skill and file chips in bubbles, command results and notes, goal bar; the app runs new / retry / title / branch / model / reasoning / stop / steer / queue itself, the rest go through `slash.exec` → `command.dispatch`

### M6 Requests (`docs/quick-actions.md`)
- [x] Docked glass card: approval tiles (follow `choices` and `allow_*`), flagged, batch (parallel approvals no longer overwrite each other), … menu (copy, explain, deny with a note, allow everything, permissions), Always Allow alert, receipts (between the message and the reply, kept across reloads), permissions sheet, needs-you dock while typing on iPhone; Return / Escape
- [x] Clarify (single, multi, steps, open), secret, sudo, vault unlock / save login / code, connections (fields, OAuth with `connection.update`, install), setup choices (accent, theme, options); withdrawn-request receipts; resume restores `open_requests` and `pending_connection`. Mock: send "batch", "flagged", "clarify [multi|steps|open]", "secret", "sudo", "unlock", "save login", "2fa", "choose accent|theme|apps", "connect linear", "sign in", "install", "timeout"

### M7 Screens
- [x] Mac Settings as designed (General / Gateways / Chat tabs, follows the app's appearance, Sparkle auto-check), Tasks (icon tiles, schedules in words via `ScheduleText`, status tags, grouped with footer), Skills (tool-set switches over `tools.configure`, icon tiles, Use adds the skill chip, iPhone search in the bottom toolbar), New Bot / Edit Bot (compact on the Mac), model picker (compact Mac popover with search)
- [ ] Still to compare side by side: onboarding, Add / Edit Gateway (Mac column form), connect sheet, scanner, Pair a Device, Routines, Bot hello, Mac update windows; iPhone renders of all of these once the simulator is usable again

### M8 Group chats
- [x] Rooms per `blocks/groups.elyx` over the gateway's hosted rooms (`groups.*`, protocol 2, read from the Hermes 0.21.6 source): rows in the Bots roster (group avatar, "Needs you"), New Group Chat (2–6 Bots, first leads), the room (member messages with Lead, passes, round dividers, "Room settled · N rounds", who's replying), approvals (`groups.approve`, once / deny), Stop, Retry, Activity, Group Settings (rename, delete). There are no room events on the socket, so open rooms poll `groups.log` from the last `seq` (1.2 s while working, 5 s idle) and `groups.state`. Hermes has no call to change members after creation, so Manage Members isn't offered. Checked against the mock only; Desktop's own rooms (`ui_meta["hermes-bots-groups"]`) aren't shown
