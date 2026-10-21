# Onboarding

This document covers everything from first launch to a useful first chat:

1. A four-page tour of what Hermes does, with pairing one tap away on every page.
2. A way in for people who don't have Hermes Agent yet.
3. Three short, skippable setup steps after the first gateway is added.
4. A first chat with a getting-started checklist, and tips one at a time.
5. What's New for people who update.
6. The Mac's welcome window, which connects to Hermes Agent on the same Mac in one click.

Pairing itself (the scanner, the connect sheet, Set Up Manually) is in
`docs/connecting-and-voice.md` §2 and §6.

Design components, for matching code to the design:

- The tour: `pageDots`, `tourText`; on iPhone `welcomeChat`, `welcomeBots`, `welcomeWork`,
  `welcomeLearns`; `onboardingNoCamera` when there's no camera; `ipadWelcome` on iPad.
- Getting Hermes: `getHermes`, `installCard`, `stepRow`.
- Setup: `setupModel`, `setupYou`, `setupReady`, `setupSteps`, `startCard`.
- The first chat: `firstChat`, `getStartedCard`, `checklistRow` (and its done state), `tipBubble`.
- What's New: `whatsNew`, `macWhatsNew`, `whatsNewRow`.
- Mac: `macWelcome`.

The code is in `App/Views/Welcome/` and `App/Model/WelcomeProgress.swift`.

## 1. The tour (first launch, not paired)

With no gateway saved, iPhone and iPad open on the tour (`WelcomeTourView`); the Mac opens its
welcome window (§6).

| Page | Title | Vignette |
|---|---|---|
| 1 | Your agent, on your phone. | A message (`UserBubble`) and the approval it leads to (`ApprovalCard`) |
| 2 | Bots that keep at it. | Three Bot faces and a `BotMessageCard` |
| 3 | Hand it the work. | Board cards (`BoardCardView`) with the Inspector pill (`InspectorPillLabel`) |
| 4 | It gets better with you. | The learning map (`LearningMapView`, `learningMapCompact`) and a memory note (`MemoryNotes`) |

- The vignettes are the app's own components in a fixed demo state (`WelcomeDemo`), not live
  data. They ignore touches and VoiceOver skips them.
- Light motion: the Bot faces blink, the running card's clock ticks and the map's nodes settle
  (the last two only on the page on screen).
- Pages advance by themselves every 6 s until the person touches the tour, and stop on the last
  page. **Reduce Motion** and **VoiceOver** turn auto-advance off; Reduce Motion also stops the
  clock.
- The actions are the same on every page:
  - **Scan Pairing Code** (primary), only where VisionKit's scanner is supported;
  - **Set Up Manually**, which becomes the primary button when there's no camera
    (`onboardingNoCamera`);
  - "New to Hermes Agent? Get it".
- **iPhone:** the brand at the top, the vignette (faded at its foot) above the words, the dots,
  then the actions.
- **iPad** (regular width): the vignette on a rounded card at the left, the words, dots and
  actions at the right.

## 2. Get Hermes Agent (`getHermes`)

- What Hermes Agent is: it runs on a computer you own (a Mac, a home server, a VPS), and this app
  talks to it.
- The install command (`installCard`) with Copy, from the Hermes Agent README's quick install:
  `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`, and a line saying Hermes
  Agent is free and open source, by Nous Research.
- Three steps (`stepRow`):
  - iPhone and iPad: 1. Install it. 2. Show a pairing code: in Hermes for Mac, Settings → Pair a
    Device; on a server, Set Up Manually with its address and API key. 3. Scan it here.
  - Mac: 1. Install it. 2. Come back here: the welcome window finds the agent on this Mac.
    3. Or use another machine with Connect to Another Gateway.
- **iPhone and iPad:** a bottom bar with **Send to My Mac** (the share sheet with the command and
  `https://hermes-agent.nousresearch.com`, for AirDrop or Messages) and **Scan Code** (or Set Up
  Manually without a camera).
- **Mac:** a sheet with Done.

## 3. Setup after pairing (three steps, each skippable)

Setup runs once, when the **first** gateway is saved: by pairing, by Set Up Manually, or by the
Mac's Connect (`AppModel.setupGatewayID`). It doesn't run for later gateways or for the Debug
bootstrap. It covers the window: full screen on iPhone and iPad, a sheet on the Mac. The step bars
(`setupSteps`) show progress, and every step can be left.

### Step 1: a model (`setupModel`)

Shown only when the gateway has no model provider. Asking needs Bot Mode, so without it (or if
the question fails) setup starts at step 2.

- The app waits up to 10 s for Bot Mode to connect, then calls `setup.status {profile?}`. The
  step shows when `provider_configured` is false (or `ready` is false; Hermes sends `ready: true`
  or leaves it out).
- Providers come from `model.options {include_unconfigured: true, profile?}`: `slug`, `name`,
  `auth_type`, `free_tier` (or `free_tier_row`). Nous Portal comes first when its free tier is
  offered, then OpenRouter, Anthropic, OpenAI and Gemini, then the rest; local providers (Ollama,
  LM Studio and the like) last. Three plus one local show until Show All Providers.
- **Continue** depends on the provider:
  - Nous Portal: with the free tier, `free_tier.provision`, done when it answers `has_guest:
    true`. Otherwise the Nous sign-in: `POST /api/providers/oauth/nous/start` opens the
    verification page in the browser, and `GET /api/providers/oauth/nous/poll/<session>` is asked
    every `poll_interval` seconds until `approved`.
  - A provider with `auth_type: api_key`: the key screen, then `model.save_key {slug, api_key,
    profile?}`. The key is saved on the gateway; on the device it is only in memory and is
    cleared when the screen closes. 4003 says the provider signs in on the gateway (run
    `hermes model` there); 4006 says the gateway's keys are managed and can't be changed here.
  - Anything else (a local model, another sign-in): a message to run `hermes model` on the
    gateway.
- **Later** skips the step.

### Step 2: about you (`setupYou`)

- A name ("What should Hermes call you?") and what Hermes is mostly for, as chips: Code, My home
  server, Research, Writing, Life admin.
- **Save to Memory** (on by default): Continue sends one sentence as the first message of a new
  chat that is never opened: "Remember that I'm Sam and I mostly use you for code and my home
  server." Hermes saves it with its memory tool, because there is no direct add call
  (`docs/memory.md`). With Ask Before Saving on, the app approves that one save itself
  ("allow once"), since nobody would see the question.
- Continue keeps the name on the device for the greeting (§4) either way. With Save to Memory off,
  nothing is sent. **Skip** keeps nothing.

### Step 3: starting points (`setupReady`)

"You're set, Sam" and up to four cards (`startCard`), each only when the gateway backs it, in this
order:

| Card | When | Opens |
|---|---|---|
| Make *label* a project | A folder Hermes has worked in at least three times that isn't a project yet (`projects.discover_repos`); the one with the most chats | Creates the project (`projects.create`) and opens its home |
| Meet your N Bots | Bot Mode is connected and has Bots besides the default | Bots mode in the sidebar |
| Get a morning briefing | The gateway has no tasks (`GET /api/jobs`) | Tasks, with New Task filled in |
| Ask about *gateway* | Always | A new chat with "What's using the most disk space?" typed, not sent |

**Start Chatting** skips them all.

Setup never asks for notifications; the prompt waits for a moment that needs it (§4). Once setup is
done, a gateway whose Bot Mode finds the app's plugins missing asks once to install them
(`pluginsAsk`, [plugins.md](plugins.md) §2.1).

## 4. The first chat (`firstChat`)

Until the checklist is done or dismissed, every new chat outside a project shows a greeting and
the checklist above the composer.

- **Greeting** with the name from setup, by the time of day: "Good morning, Sam" (05:00–12:00),
  "Good afternoon" (to 18:00), "Good evening" (to 23:00), "Up late, Sam?" otherwise. Without a
  name, just the greeting.
- **`getStartedCard`:** "Get to know Hermes", a ring with *n*/5 (or /6), ✕, and five rows, with
  a sixth while the widgets plugin is missing or off on the gateway. Rows tick themselves when the
  thing happens anywhere in the app:

  | Row | Tap | Ticks when |
  |---|---|---|
  | Connect to your gateway | nothing | the gateway is online; the detail reads "Studio Mac · Hermes 0.21.6" |
  | Tell Hermes about you | a new chat with "Remember that " typed | setup's About You was sent, or a reply shows a saved memory |
  | Let Hermes run a command | a new chat that sends "What's using the disk?" | any approval is answered |
  | Meet your Bots (with Bot Mode) or Start a project (without) | Bots mode, or All Projects | a Bot Chat opens, or a project is created |
  | Turn on undo for files | the checkpoints sheet: the off sheet with Turn On (`checkpointsOff`), or the timeline when they're on (`docs/checkpoints.md`) | checkpoints are turned on, or a chat finds them on already |
  | Let Hermes answer with cards ("Installs a plugin on Studio Mac · you review it first"; only while `hermes-app-widgets` is missing or off, and gone once hidden with Don't Suggest Again) | the plugin's review (`pluginChecklist`, [plugins.md](plugins.md) §2.1) | the plugin is on |

  ✕ hides the card for good; it also hides itself once all its rows are done. Progress is per
  device and never synced (`UserDefaults` `welcome.name`, `welcome.checklist.done`,
  `welcome.checklist.hidden`).
- **Tips** (`tipBubble`, TipKit): each shown once, at most one an hour, each only after the
  person has had a reason to need it. Got It and ✕ put a tip away for good. A tip never gets in
  the way of what it points at: it hangs off a clear stand-in laid over the control
  (`hermesTip`), because wrapped by the popover the toolbar's sidebar button and a Bot Chat's title
  stopped answering taps (`ToolbarButtonsUITests`).

  | Tip | Shown on | After |
  |---|---|---|
  | Everything lives here | the button that opens the sidebar or drawer | the first new chat appears |
  | What Hermes is working on | the Inspector pill (iPhone, iPad portrait) | something first opens in the Inspector |
  | Take back a turn | the undo bar | a turn first changes files |
  | Its face says what it's doing | the Bot's face and name at the top of its chat | a Bot Chat first opens |
  | Steer while it works | the send-mode chip in the composer | the person first types while Hermes works |

- **Notifications** are asked for in context, never here: on the first approval, a turn that
  runs over 30 s, or leaving while one runs; never at launch, never while setup is on screen, and
  never for setup's About You chat (`permissionPrime`, `docs/notifications.md`).

## 5. What's New (`whatsNew`, `macWhatsNew`)

- The content ships with the app: `WhatsNewCatalog.releases`, newest first, each with an id (not
  an app version) and its features.
- About a second after launch the app shows the newest release it hasn't shown yet, once, and
  marks it seen as it appears. Never while setup is on screen.
- A first install (no gateway and nothing seen yet) marks the newest release seen without showing
  it.
- "What's New in Hermes", four rows at most, Continue. On the Mac each row names its shortcut or
  where it lives ("⇧⌘B", "Settings → Memory").
- The current release lists Cards in Replies and Plugins; the one before, the Board, the
  Inspector, Memory and What Hermes Learned.
- A feature that needs one of the app's plugins (Cards in Replies) has its offer card under the
  row (`pluginWhatsNew`, `pluginOfferWidgets`), only while the plugin is missing or off on the
  current gateway: Set Up opens the review, Turn On turns an installed copy back on, Not Now
  leaves it in Suggested (the card may come back once after 14 days), and its … menu hides it.
- **The one plugin ask** (`pluginsAsk`) comes after setup, the first time Bot Mode connects on a
  gateway, never during the tour, setup or What's New ([plugins.md](plugins.md) §2.1).

## 6. Mac welcome (`macWelcome`)

With no gateway saved, the Mac's window shows the tour at the left (starting on page 3; the page
capsules can be clicked) and the way in at the right: "Welcome to Hermes", a card about Hermes
Agent on this Mac, then **Connect to Another Gateway…** (the Add Gateway sheet) and **Get Hermes
Agent** (§2, as a sheet).

- **Looking.** The app asks `GET http://127.0.0.1:8642/v1/health` (no key, 2.5 s; the address, not
  `localhost`, which may reach a listener on IPv6's `::1` first), and
  `GET http://127.0.0.1:9119/api/status` to see whether Bot Mode is there (any answer below 500).
- **Running:** "Hermes Agent is running on this Mac", with "Hermes 0.21.6 · 127.0.0.1:8642 · Bot
  Mode on", and **Connect** as the default button.
- **Connect** reads `API_SERVER_KEY` from `~/.hermes/.env` only when it's clicked (plain,
  `export`ed, quoted or with a trailing comment). The Mac app isn't sandboxed (it ships as a
  Developer ID app), so it reads the file directly; there's no open panel. The key goes straight
  to the Keychain and never into a log. The gateway is saved with the Mac's name, and with Bot
  Mode (Automatic sign-in) when the backend answered. Setup (§3) follows.
- Before the key is read, the process listening on the port must be the one Hermes recorded in
  `~/.hermes/gateway.pid` (`LocalListener`, read through libproc, which only sees this user's
  processes). Anything can answer `/v1/health` on a free port, a sandboxed app that can't read
  `~/.hermes` included, and the key runs commands on this Mac. Otherwise: "Something other than
  Hermes Agent is answering on 127.0.0.1:8642. Quit it or restart Hermes Agent, then try again."
- No key in the file: "Hermes Agent on this Mac has no API key yet. Set API_SERVER_KEY in
  ~/.hermes/.env, restart it, then try again."
- **Not running:** "Hermes Agent isn't running on this Mac", a line about `hermes gateway`, and
  **Look Again**.

## 7. Accessibility

- Each tour page reads its title first, as a header, with the value "Page 2 of 4", then its words.
  The vignettes are hidden from VoiceOver. On the Mac each page capsule is a button named "Page 2
  of 4: Bots that keep at it."
- Auto-advance is off while VoiceOver runs and under Reduce Motion.
- The step bars read "Step 2 of 3"; selected chips and providers carry the selected trait.
- The checklist reads "Get to know Hermes, 2 of 5 done"; each row is a button with the value
  "Done" or "Not done".
- Tips have a labelled Close button and Got It.

## 8. Acceptance checks

Run them against the mocks (`docs/development.md`); `backend.py --no-model` and
`POST /api/mock/onboarding {provider_configured, jobs: "clear"|"seed"}` set up the cases, and
`-HERMES_WELCOME_PAGE`, `-HERMES_SETUP`, `-HERMES_TIPS` and `-HERMES_WHATS_NEW` open each screen.

- First launch shows the tour; Scan Pairing Code (or Set Up Manually) works from every page.
- A gateway without a model shows the model step; one with a model skips it. Without Bot Mode the
  step is skipped.
- Saving step 2 creates an About You memory, visible in Settings → Memory, without a question.
- Starting points show only what the gateway backs: the briefing only with no tasks, Bots only in
  Bot Mode.
- The checklist ticks items as they happen and hides itself when done or dismissed.
- What's New appears once after an update and never on a fresh install.
- On a Mac running Hermes Agent, the welcome window connects in one click.
- Every screen here reads well in light and dark, with Increase Contrast, and at the largest
  Dynamic Type sizes.

## 9. Setup

Setup after pairing asks for a model once. After that, Settings → Setup lists everything else that
needs setting up ([setup.md](setup.md)).
