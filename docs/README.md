# Hermes docs

## Start here

| | |
|---|---|
| [development.md](development.md) | Build the app, run the tests, run it against the mock Hermes, and open any screen in any state |
| [architecture.md](architecture.md) | How the app, Hermes Agent, the push relay and the gateway plugin fit together, and the safety rules the code keeps |
| [plugins.md](plugins.md) | The app's own Hermes Agent plugins: what each adds, what works without them, installing them in every profile, updating, and changing them |
| [setup.md](setup.md) | Features that need something configured: the rule (state, fix, steps, fallback), the shared setup views, Settings → Setup, and every feature's states and how to set it up |
| [releasing.md](releasing.md) | How official builds reach TestFlight and the Mac (maintainers) |

## The app, area by area

Each document says what that part of the app does, which Hermes calls sit behind each control, how
it behaves on iPhone, iPad and Mac, and how to check it. Code comments cite them as
`docs/<area>.md §n`, so section numbers stay put when a document changes.

| | |
|---|---|
| [design-to-swiftui.md](design-to-swiftui.md) | Colours, Liquid Glass, buttons, inputs, sheets, toolbars, search, type, states and accessibility: how each design rule maps to SwiftUI |
| [chat.md](chat.md) | Everything a turn can contain: each Hermes event, what shows it, Markdown and chat interactions |
| [quick-actions.md](quick-actions.md) | Approvals and every other request Hermes sends mid-turn: which card, which fields, what to answer |
| [commands-and-references.md](commands-and-references.md) | "/" commands, skills, @mentions and file references: while composing and once sent |
| [follow-ups.md](follow-ups.md) | Sending while Hermes works: Steer, Redirect, Send Next, Ask Aside and Run in Background |
| [composer.md](composer.md) | The composer, dictation and where Talk starts |
| [voice.md](voice.md) | Voice and audio: Talk (calls, Realtime, the Live Activity), the audio coordinator, turn-taking and barge-in, what replies sound like |
| [inbox.md](inbox.md) | Unread and live activity: two-line rows with counts, mentions, needs-you and mute; the activity line; opening at the New Messages line; the jump pill; typing; reply with a quote; filters, swipes, menus and badges |
| [sessions-and-models.md](sessions-and-models.md) | The chat list and chat menus, context and compacting, the model picker and provider keys, background processes |
| [connecting-and-voice.md](connecting-and-voice.md) | The two transports, pairing, setup checks, and how voice maps to on-device speech and Hermes's voice turns |
| [onboarding.md](onboarding.md) | First launch to first chat: the welcome tour, getting Hermes Agent, setup, the getting-started checklist, tips, What's New, the Mac welcome window |
| [search.md](search.md) | Searching chats by what was said, the Mac's ⌘K palette, and jumping to the message |
| [bots-groups-skills.md](bots-groups-skills.md) | Bots (profiles), group chats (rooms) and Skills |
| [bot-faces.md](bot-faces.md) | Bot faces as Hermes Agent's Bot Mode draws them: geometry, colours, moods and motion |
| [tasks.md](tasks.md) | Tasks and Routines (scheduled jobs): schedules, delivery, run now and edit |
| [projects.md](projects.md) | Projects: the sidebar and project home, lanes by branch and worktree, starting and moving chats |
| [helpers.md](helpers.md) | Helpers (sub-agents): the team card, the Team page and inspector, steering and stopping, nested helpers, past runs |
| [board.md](board.md) | The Board: cards Hermes and its Bots work through, columns from the gateway's workflow, needs-you and review |
| [background-processes.md](background-processes.md) | Dev servers, builds, tests and Bot messages Hermes leaves running: the step in their turn, the composer's chip, the Terminal |
| [inspector.md](inspector.md) | The Inspector: previews Hermes opens and drives, artifacts, files, git changes, terminal, the Bot Screen, team, plan and sources |
| [checkpoints.md](checkpoints.md) | Undo and checkpoints: the undo bar, review, the timeline, restoring files, turning checkpoints on |
| [connections.md](connections.md) | Apps and Tools: connected apps and accounts, tool permissions, MCP servers, plugins, built-in toolsets |
| [memory.md](memory.md) | What Hermes remembers: About You and Hermes's Notes, Ask Before Saving, the review queue, providers |
| [web.md](web.md) | Hermes on the web: Passwords (Hermes's vault, 1Password, Bitwarden), where Hermes browses, signing in and card fills in a chat, and browsing in the app |
| [learned.md](learned.md) | What Hermes Learned: the skills it wrote, the map of how they connect, and the curator's tidying |
| [notifications.md](notifications.md) | Push notifications: the gateway plugin, the relay and encryption, answering from the Lock Screen, Live Activities (installing the plugin: [plugins.md](plugins.md)) |
| [widgets.md](widgets.md) | Agent widgets: directives and payloads, reading them failing closed, the store, answering, approvals, privacy, the cards and the gallery |

## Ground rules

- Hermes method and field names come from the Hermes Agent source and match what the app sends and
  the mocks answer. When Hermes changes, check the source, update the client, the mock and the doc
  together.
- Apple API names are checked against the SDKs the app builds with (Xcode 27).
- Demo content (Sam, Studio Mac, Research Buddy, Ops, Ada) comes from the mock in
  `Tools/mock-hermes`.
