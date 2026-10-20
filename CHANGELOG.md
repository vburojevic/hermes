# Changelog

Hermes is in **public beta**. Every build is version 1.0, numbered by when it was built
(`yyMMddHHmm`, UTC: build 2610201548 was made on October 20, 2026 at 15:48). iPhone and iPad builds
arrive through [TestFlight](https://testflight.apple.com/join/CVhbq8Ur); Mac builds update
themselves and are listed on [hermes-releases](https://github.com/vburojevic/hermes-releases/releases).
Each build also has a [release here](https://github.com/vburojevic/hermes/releases), marked pre-release
while Hermes is in beta. More about Hermes at [hermesapp.dev](https://hermesapp.dev).

## 1.0 beta

The first public beta, for iPhone, iPad and Mac.

- **Chat with your own Hermes Agent**, with a live timeline of every search, command, file change
  and helper; steer it or queue a follow-up while it works. Turns keep running when you leave.
- **Approvals you can read**: every command shown exactly as it will run, answered in the app, from
  a notification, the Lock Screen or the Dynamic Island.
- **Bots** (Hermes profiles) with their own faces, memory, routines and one chat that never resets,
  plus group chats where they work together.
- **Projects, the Board and the Inspector**: chats by folder and branch, a kanban Hermes works
  through on its own, and a panel beside the chat with live previews, files, diffs, the terminal
  and the team of helpers. Undo any turn that changed files.
- **Widgets in replies**: cards for the day at a glance, forms, checklists and approvals, answered
  with a tap.
- **Voice**: Talk (hands-free calls in each Bot's own voice, "Hey Hermes", the Lock Screen), voice
  messages, dictation and Listen.
- **Memory and what Hermes learned**: edit what it remembers, and see the skills it wrote for itself.
- **Settings → Setup** shows every feature's state and fixes what it can, including installing the
  app's Hermes plugins and updating Hermes Agent.
- **Privacy and security**: no account and no tracking, keys in the Keychain, end-to-end encrypted
  notifications, pairing links only Hermes opens, and content that can't approve commands or reach
  your network.

### Private beta

Everything that changed during the private beta, day by day.

<details>
<summary><b>October 20, 2026</b>: 26 changes</summary>

- **Board:** a hermesapp://board link opens only one of the gateway's own projects
- **Chat:** a routine delivered mid-turn no longer splits the turn in two
- **Chat:** a message whose answer was lost is never sent twice
- **Chat:** what Hermes or a Bot is doing is one line of words that shimmers, once per place
- **Chat:** a reply's pictures load by themselves only from the gateway itself
- **Chat:** replies built to be slow or deeply nested no longer freeze or stop the app
- **Commands:** the "/" menu lists what this Hermes offers, /update included, and says why one can't run
- **Composer:** menus above it stop under the top bar and scroll, keyboard up or down
- **Gateways:** a gateway's key goes only to the address the app saved it for
- **Inspector:** Preview pages can't reach this network or files outside their folder through a name or a symlink
- **Loading:** a spinner only for what you started, after half a second; lists that load show skeletons
- **Memory:** "Save to memory?" shows the whole entry; a marker in it can't hide the rest
- **Notifications:** Allow and Save show on a notification only beside the whole command or entry
- **Notifications:** a push is believed only as far as its sealed envelope says
- **Notifications:** each gateway seals to its own device key, so a notice can't pass for another
- **Pairing:** codes are hermesapp.dev universal links that only Hermes opens, details in the fragment
- **Plugins:** the app keeps push at 1.3.0, which tells Setup how the gateway's Mac runs Hermes
- **Plugins:** hermes-app-push 1.3.1 and hermes-app-widgets 1.2.1, with the security fixes
- **Plugins:** the app installs push 1.3.1 and widgets 1.2.1
- **Push plugin:** reply, room and cron text reads in one pass
- **Setup:** updating Hermes and restarting the gateway show their progress live, here and in a chat
- **Stability:** numbers and ranges from the gateway or a model no longer stop the app
- **Welcome:** on the Mac, Connect sends the .env key only to the Hermes process that recorded itself
- **Widgets:** a look-alike fence or a Bot's text can't plant a widget or swap one's terms
- **Widgets:** what you type into a card is kept on the device sealed
- **Widgets plugin:** look-alike fences, a directive's alt, names anyone can take and Discord threads

</details>

<details>
<summary><b>October 19, 2026</b>: 60 changes</summary>

- **Approvals:** an answer given while the gateway is away goes when it's back, to that request
- **Bot Chats:** a reply that repeats a routine's delivery shows only what it adds
- **Bots:** a Bot answering another Bot shows it's working, in its row, tile, face, chat and the jump pill
- **Bots:** a reconnect streams the open chat again first; a stalled socket says the Mac is busy
- **Bots:** Pin and Hide move the Bot at once
- **Chat:** a streaming reply redraws at most 15 times a second
- **Chat:** file cards from a running turn read Hermes's colored diffs
- **Chat:** files changed after a steer show after it when the turn folds
- **Chat:** a turn whose reply lands as the connection drops shows once
- **Chat:** a reply on its way never leaves an empty space under your message
- **Chat:** a flick that starts on a reply scrolls the chat; a swipe left still replies
- **Chat:** a page's zero-width spaces no longer read as "tried to give Hermes instructions"
- **Chat:** a message to a busy or away Mac shows at once and goes when it can
- **Chat list:** Archive's Undo and Mark All as Read don't wait for the gateway
- **Chats:** less main-thread work while any chat runs, and when a chat rebuilds
- **Chats:** a writing reply's line in the list drops Markdown's marks and reads only the reply's end
- **Chats:** reading far back keeps a few pages around the screen, so long chats scroll smoothly
- **Chats:** a chat of long replies opens with fewer rows and fills in by the room they take
- **Chats:** the chat list shows at once on launch, from what this device saw last
- **Connection:** a gateway too busy to answer its health check reads busy, not offline
- **Connection:** "busy" holds while the Mac is starved, and clears once it isn't
- **Group chats:** your message shows at once and goes when the Mac can take it
- **Listen:** a scheduled report reads as a brief, and every widget as its words
- **Memory:** on the Mac, a provider with a long name no longer squeezes Reset Memory… to "Re…"
- **Memory:** a provider that isn't installed installs from the app, after showing what Hermes will run
- **Models:** the model list and widget answers don't wait behind the chat list
- **Models:** the model picker opens on the list this device saw last
- **Motion:** a working Bot's dots and shimmer are played by Core Animation, not redrawn by the app
- **Notifications:** a Bot that chooses to say nothing ("[SILENT]") no longer notifies
- **Plugins:** one ask sets a gateway up for this app, and an update that needs more access waits for your Allow
- **Plugins:** the catalog, what's suggested, and what you answered, kept per gateway
- **Plugins:** Apps and Tools → Plugins is the hub: Suggested, Updates, Installed, the catalog and Hidden Suggestions
- **Plugins:** offered where they help: What's New, the checklist and Set Up Push
- **Plugins:** Turn On never skips an update that asks for more access, and the hub's pages go back where you were
- **Plugins:** hub rows with a wrapped tag meet without a pixel gap
- **Plugins:** the catalog's chips sit right under its search field
- **Plugins:** the ask's switches are switch green, not the text green
- **Plugins:** the "Missing in …" card keeps its background in dark
- **Plugins:** cards in their own Form row keep a background in dark and don't nest on the Mac
- **Plugins:** the catalog's chips run from the cards' edge to the screen's
- **Plugins:** a plugin's tag stays on its name's line when it fits
- **Push plugin:** the app installs 1.2.1, which sends no notice for a turn that says nothing
- **Search:** a result far back in a chat lands on its own message
- **Search:** chats whose title matches show at once while the gateway searches what was said
- **Settings:** on the Mac, a page opened inside a Settings tab keeps the highlight on that tab
- **Settings:** on the Mac every tab shows, whatever the pane, so the open tab is always the highlighted one
- **Setup:** Update Hermes and Turn Off ask from their own button, so on iPad the question points at it
- **Setup:** a gateway Mac that throttles Hermes says so, and the Mac app runs it at full priority
- **Setup:** the app notes whether this Hermes keeps a Bot's message to another Bot going when the sender's chat closes
- **Setup:** Bot-to-Bot Replies says when this Hermes can lose a Bot's reply to another Bot
- **Sidebar:** one chat's activity redraws only that chat's row
- **Talk:** can transcribe on the gateway, as you speak
- **Talk:** "Hey Hermes" starts a call, on the Mac and on a charging iPhone or iPad
- **Voice messages:** a vertical drag on a playing clip's waveform scrolls the chat
- **Widgets:** every chat you have gets widgets, not only the ones you open
- **Widgets:** https addresses in a widget's words can be tapped, and ask first like its links
- **Widgets:** stock quotes, flights, prices you watch and weather warnings draw as their own cards
- **Widgets:** the app installs widgets plugin 1.2.0, which knows the everyday cards
- **Widgets:** cards match their designs: full-width tables, one-line codes, the slider bar, date and menu fields
- **Widgets:** the slider takes arrow keys, and switches are switches at the row's end on the Mac

</details>

<details>
<summary><b>October 18, 2026</b>: 95 changes</summary>

- **Apps and Tools:** a built-in toolset that's on without its key says so
- **Apps and Tools:** a built-in toolset that needs a key takes one from the app
- **Apps and Tools:** apps that are turned off, or not in the Nous plan, say so instead of asking to sign in
- **Background:** the app is no longer ended for holding on to its background time
- **Board:** says when it's turned off and turns it back on, or that Hermes needs updating
- **Bot Mode:** a backend with a password asks you to sign in instead of reading as offline
- **Bot chats:** the typing bubble stays until the Bot's first words, not its first thought
- **Bots:** a Bot Mode client that's let go takes its connections with it
- **Bots:** a round of changes on Hermes gets one refresh, not five, and one running-chats request
- **Bots:** a face at rest is played by Core Animation, and the app does no work per frame for it
- **Chat:** a chat kept open stays as quick as when it opened: rows far above the end leave the window
- **Chat:** what live tool calls showed is kept within bounds for the life of a chat
- **Chat:** a chat on its way shows its shape, not a spinner
- **Chat:** opening a fold redraws its own reply, not every reply in the chat
- **Chat:** a message sent on another device shows at once, not when the reply ends
- **Chat:** a message sent before a chat's history came no longer leaves the chat empty
- **Chat:** a turn that failed on the model's key or sign-in says so, and takes a new key
- **Chat:** a provider sign-in that expired can be signed in again from the failure card
- **Chat:** web addresses written out in replies can be tapped
- **Chat:** a streamed word redraws only its own reply, and opening a chat no longer redraws every reply
- **Chats:** unread counts are worked out off the main thread, and not while a turn is still running
- **Chats:** coming back to the app shows what happened meanwhile without waiting for the socket
- **Chats:** kept current in the background, so they're up to date when you come back
- **Chats:** swipe buttons read in Dark Mode, and match the app's grays in both
- **Chats:** the drawer button's unread count stays whole while the button is pressed
- **Chats:** opening a chat no longer freezes the screen
- **Chats:** Select Text in a reply's menu on iPhone and iPad, and chats open a third lighter
- **Dictation:** words land at the cursor and typing carries on; group chats get the microphone
- **Drawer:** rows swipe like the system's again, and the list scrolls
- **Group chats:** say when turn isolation keeps Bots from replying, and turn it off
- **Group chats:** ask again whether rooms run each time Bot Mode connects
- **Learned:** says when tidying is turned off and turns it on, and shows the way to Bot Mode
- **Learned:** Tidy Up Now looks off while tidying is turned off or the gateway is away
- **Listen:** replies are read in the Bot's own voice, with the sentence lit up and a mini player
- **Listen:** the mini player floats 12 pt above the composer
- **Memory:** a provider in use that isn't set up says so, with the command that sets it up
- **Memory:** a provider that needs its settings is set up from the app
- **Models:** the picker shows providers that need a key, with Add Key…, and says why a list didn't load
- **Notifications:** a widget in a reply or a task reads as its text, a private one as "Hermes sent a widget"
- **Notifications:** a reply that asks with a widget notifies at once, Open only
- **Notifications:** a device that isn't on a gateway's list says why instead of "Push on"
- **Permissions:** a microphone, camera or local network that's off says how to turn it on
- **Plugins:** the app installs its Hermes plugins in Hermes and every Bot, and keeps them current
- **Plugins:** the app installs the widgets plugin too, pinned to 1.1.0
- **Plugins:** the push plugin 1.2.0 sends widget requests, and the app keeps gateways on it
- **Plugins:** a plugin turned off can be turned back on, and the restart it needs is remembered
- **Projects:** say what they need instead of an empty list or "Project not found"
- **Push plugin:** one board watcher per gateway, slower while the boards are quiet
- **Push plugin:** 1.1.0, with chats kept current while the app is away
- **Push plugin:** the app installs 1.1.0, which keeps chats current while the app is away
- **Search:** says why it searches titles only, and shows title matches when it fails
- **Settings:** Setup lists every feature that needs something configured, with its state and fix
- **Settings:** Setup's checks land one by one, and it counts tasks whose results didn't arrive
- **Settings:** Setup lists Talk, Listen and voice messages
- **Settings:** Setup shows the app's plugins missing, older or turned off in some Bots
- **Setup:** one way for every feature to say it isn't set up, and how to fix it
- **Setup:** Hermes Agent updates from the app, and the page follows the update until it's done
- **Setup:** a feature this gateway's Hermes doesn't have yet says it needs a newer Hermes Agent
- **Talk:** calls that keep going, in each Bot's own voice, with Realtime when the gateway offers it
- **Talk:** a reply is read to the end, "stop" stops it, and calls started from outside wait for Bot Mode
- **Talk:** noise heard as "." is no longer sent as a turn
- **Talk:** the ask to install the app's plugin waits for the call to end
- **Talk:** starting a call no longer freezes the app while the device's voices load
- **Talk:** the Live Activity's line starts on a whole word
- **Tasks:** a task whose results didn't arrive no longer reads as a success
- **Tasks:** results that didn't arrive say what to do, without pointing at runs iPhone doesn't show
- **Undo:** container chats say Hermes takes no checkpoints there; turning on says what it needs
- **Voice & Audio:** a settings page for Talk, voice messages, Listen and transcription, and each Bot's voice
- **Voice & Audio:** says what the gateway has for Talk, Listen and voice messages, and takes a missing key
- **Voice messages:** hold the microphone to send one, and Bots' audio plays in the chat
- **Voice messages:** a voice message never loses its first words
- **Voice mode:** keeps listening between turns, stops on a single "stop", and reads replies through the call's own engine
- **Widgets:** a gateway plugin that checks, stores and fills in the widgets agents send
- **Widgets:** answers are claimed once, and other platforms read each widget as text
- **Widgets:** a private widget's line in a reply carries only its title
- **Widgets:** the symbol allowlist takes the design's new voice symbols
- **Widgets:** a Bot Mode chat the app marks is known by the id its agent runs under
- **Widgets:** the plugin loads within Hermes's 10 s on a busy gateway
- **Widgets:** a Bot group chat the app marks gets its members' widgets as inline blocks
- **Widgets:** an alert can carry its Acknowledge button, as the design says
- **Widgets:** plugin 1.1.0, with Bot group chats and Acknowledge buttons
- **Widgets:** the app reads widget directives and payloads, failing closed
- **Widgets:** answers go as Send Next with readable words, and every device sees where a request stands
- **Widgets:** the shared card, and cards for numbers, collections and time
- **Widgets:** cards for things, statuses and questions
- **Widgets:** cards draw in replies and routine deliveries, with a gallery of every example
- **Widgets:** charts play as Audio Graphs in VoiceOver
- **Widgets:** a resolved approval no longer says when it expires
- **Widgets:** approvals that cost money ask for Face ID and are signed; private widgets stay private
- **Widgets:** Try Again shows your answer once, and a resolution says who answered
- **Widgets:** an approval you confirmed is never stuck on a key that won't sign; deleted chats drop their widget state
- **Widgets:** Bots send widgets unprompted whenever the content fits one
- **Widgets:** a card waiting on your answer says "Waiting", and the approval you tapped "Approving…"
- **Widgets:** cards closer to their designs, and the broken compare and status cards fixed
- **Widgets:** quotes, flights, watched prices and weather alerts read as text on every platform

</details>

<details>
<summary><b>October 17, 2026</b>: 43 changes</summary>

- **Bots:** coming back to the app reconnects at once on a busy Mac, and a relaunch opens on your Bots
- **Bots:** a frozen Hermes dashboard reads as busy, not offline, and the connection waits it out
- **Bots:** no reconnect attempts without a network; behind other apps every 60 s, and at once on coming back
- **Chat:** a sent message glides to the top in one smooth motion, without the stall and the lurch
- **Chat:** a reply's source chips no longer spill onto its actions
- **Chat:** no more scrolling into blank under a sent message while the keyboard is up
- **Chat:** a send that loses its answer no longer runs twice, and replies show without a reload
- **Chat:** background processes live in their turn, the composer and the Terminal, not piled under the chat
- **Chat:** an old chat's process steps say Ended once the gateway no longer lists them
- **Chat:** a Bot still answering another Bot shows it's working, with what it said so far
- **Chat:** a message sent while another Hermes process holds the chat waits and sends itself; busy 502s retry
- **Chat:** opens at the New Messages line, a jump pill says what's below, and replies can quote
- **Chat:** a chat opened at launch still finds its New Messages line, and the pill reads it at the end
- **Chat:** opening a notification shows its message at once, and chats catch up with a short page
- **Chat:** files a reply names open in the Inspector
- **Chat:** a file written twice in one turn shows one card, and the second write shows its change
- **Chat:** a load Hermes was too slow for retries quietly instead of a red "answered 502"
- **Chat:** folds stay as you left them, and nothing blinks or vanishes as replies settle and the chat reloads
- **Chat:** while a reply streams, the replies above it, the menu bar and the Inspector stay still
- **Chat list:** two-line rows with unread counts and what's happening, filters and swipes
- **Chats:** a sessions refresh that brings nothing new redraws nothing
- **Composer:** pasted pictures and files attach to the chat on screen, on iPhone, iPad and Mac
- **Connection:** leaving the app no longer drops the Bots' connection; it stays open while iOS lets the app run
- **Fixes from the docs review:** /goal and /plan send on a real Hermes, multi-select answers arrive as a list, withdrawn approvals don't strand the rest
- **Inbox:** the rules for what's new in a chat, where it starts and what's happening now
- **Inbox:** read marks, Mark as Unread and live previews from Hermes
- **Inbox:** one store per gateway for what's unread and what's running
- **Mac:** live dots, waving dots and shimmer stop when out of sight, so an idle window no longer pins a core
- **Mac:** behind other apps, Hermes asks the dashboard every 30 s and checks the gateway every 2 minutes
- **Mac:** a Bot chat in front idles at about 8% CPU instead of 44%: Bot faces share one clock
- **Mac:** the composer isn't measured again for every word of a streaming reply
- **Mac:** the Settings and Inspector windows hold their motion still when they aren't in front
- **Mac:** behind other apps, push, unread, project and Board timers slow down too
- **Notifications:** tapping a Bot's notification opens that Bot, including your primary Bot
- **Processes:** no false endings, steady polling, fewer redraws
- **Push:** a Bot's routine results and messages notify, however quick
- **Questions:** a long answer fits its row, and the card doesn't repeat who's asking
- **Security:** a flagged command is never allowed outside its card; Preview links to this device's network ask too
- **Tasks:** the default schedule and setup's morning briefing work on a real Hermes; small wording and link fixes
- **Terminal:** running rows show the pid; a Bot message cut before its hermes part reads short
- **Unread:** the drawer button, the app icon and muted notifications
- Bots read on the iPhone are read on the Mac again, within a moment
- Routine deliveries show in full, as designed

</details>

<details>
<summary><b>October 16, 2026</b>: 39 changes</summary>

- **Board:** a project's cards on iPhone, iPad and Mac
- **Board from a chat:** cards Hermes adds show under the reply, with Open Board
- **Board notifications:** a card needs you, ready for review, stopped, done
- **Board on iPad:** the board takes the sidebar's room; portrait shows two columns and opens cards as a sheet
- **Board on the Mac:** Move Card Right/Left (⌘→ ⌘←) in the View menu, off while typing in the card
- **Chat:** a tap on the chat puts the keyboard away; an opening chat says Reply from the start
- **Chat:** the jump arrow shows a reply still coming in below; bullets, code and tables fade in with streamed words
- **Chat:** sending glides your message to the top and the reply fills in below it, read from its start
- **Chat:** a reply that arrives whole fades in under your message
- **Concurrency:** nothing SwiftUI may run off the main thread trips a main-actor check; the microphone never stays on after stopping
- **Connection:** coming back to the app no longer drops it; a dead socket is replaced before anyone notices
- **Connection:** the network coming back reconnects at once; a setting in the way says which
- **Fix a crash opening a new chat:** the chips and the checklist no longer build rows on SwiftUI's render thread
- **Inspector:** a tabbed panel beside the chat (a two-height sheet on iPhone) that Hermes can open and drive
- **Inspector:** iPad and iPhone checked; fixes from them
- **Memory:** see, edit, forget and review what Hermes remembers
- **Memory edit:** refusals stay in view and show what the gateway has now
- **Memory in the chat:** notes after replies, the note sheet, Save to memory?
- **Memory on the Mac:** a Memory tab in Settings
- **Onboarding:** the welcome tour and Get Hermes Agent
- **Onboarding:** setup after pairing — a model, a little about you, places to start
- **Onboarding:** the first chat — greeting by name, the getting-started checklist, tips
- **Onboarding:** What's New, once per release that adds features
- **Onboarding:** the Mac welcome window finds Hermes Agent on this Mac
- **Onboarding:** setup's About You saves even when the gateway asks before saving
- **Performance:** lighter streaming, terminal output, roster polls, map layout; fewer leaks and idle wakeups
- **Performance:** long outputs, code blocks, the slash menu and tool rows draw cheaper; Mac and group polls slow down out of sight
- **Performance:** chats out of sight catch up when opened; previews let go two minutes after leaving the chat
- **Replies:** the newest words fade in along the line as they stream
- **Security:** links in chats only go to the web; previews read only their own folders; artifacts stay offline; keys never follow a redirect
- **Security:** approvals show what will really run, and only what's shown is answered
- **Security:** keys stay on this device, pairing shows where it really connects, the pairing code hides when you leave
- **What Hermes Learned:** the page, the map, a learned skill and Tidying, from Skills, Memory and chat notes
- **What Hermes Learned:** dates a skill was made, the Mac's title, labels that don't overlap
- **What Hermes Learned:** a quiet notification after a tidy that changed something, opening Tidying
- Opening a notification no longer crashes the app on iPhone
- Bot faces show whole, keep their shape and come alive on their own; Bot screens tidied
- A busy Mac reads as busy, not offline
- Bot faces in a window in the back no longer sit with their eyes shut

</details>

<details>
<summary><b>October 15, 2026</b>: 39 changes</summary>

- **Apps and Tools:** apps, MCP servers, plugins and built-in toolsets per gateway
- **Bots:** a busy Mac gets 30 s to answer; the Bots screen says when it can't connect
- **Chat stays put in long and busy chats:** no blank screens, no jumps
- **Chats open fast:** device cache, a smaller first page, older pages on scroll, no double loads
- **Checkpoints:** busy, off, container and file restore states; real line diffs in history
- **Checkpoints:** the Mac sheet's list sits in the sheet
- **Checkpoints:** the gateway's avatar by the folder, as designed
- **Dark mode and contrast pass:** readable default buttons, Skills cards on gray
- **Helpers:** live team card, Team page and inspector, helper detail, steer and stop
- **Mac:** sending no longer jitters the chat; layout stops re-measuring every row
- **Mac Voice panel:** a speaker control, and End that stays red
- **Mac polish:** toolbar buttons on the trailing side, white cards on the grouped background
- **Mac projects:** All Projects as a grid, a compact New Project sheet; windows restore what they showed
- **Notifications:** a Bot answering you notifies on the Mac; Bots' own processes find your devices
- **Projects:** fixes for a real Hermes, and Mac and iPad polish
- **Projects:** the Mac project home's menu sits top right
- **Projects (workspaces):** sidebar, project home, Run In, editing, moving chats
- **Question and approval cards:** long answers wrap; cards rise out of the composer and sink back
- **Questions wait for Send:** picking an answer selects it instead of sending it
- **Search:** chats found by what was said, in the drawer and sidebar
- **Search:** the Mac ⌘K palette, ⌥⌘F sidebar search and ⌘F find in chat
- **Skills:** a grid of cards on iPad and Mac; Tools and Apps replaces the toolset switches
- **Tasks on iPad and Mac:** the list beside the task, recent runs that open their chats
- **Undo and checkpoints:** the undo bar, Review, Undo, the timeline and the Mac sheet
- **Voice on iPad and Mac:** listening rings, the conversation beside it, a floating Mac panel
- **iPad:** Team as a sheet in portrait, ⌥Return mode menu, two-column Checkpoints and Apps and Tools
- **iPad polish:** Tasks, Skills, Voice, Checkpoints and Team match their renders
- **iPhone offers notifications too:** the ask waits for you to come back
- Chats open from the iPhone drawer without lag; heavy work leaves the main thread
- The app reconnects to Hermes by itself after a drop
- Helpers don't notify on their own; the results reply does
- Streaming, sent images and Quick Open stay off the main thread; Quick Open highlights again
- Routine deliveries fold when the Bot's reply follows
- Routine deliveries read as routines again; failed turns show their whole sentence
- Bots read on one device are read on the others
- Your message no longer leaves and comes back when a reply ends
- iPhone notifications show the reply, not "Reply ready on…"
- Bot faces match Hermes Bot Mode exactly, move like it, and react to what happens
- Search results flash when they land

</details>

<details>
<summary><b>October 14, 2026</b>: 16 changes</summary>

- **Chat holds still:** no blank screens, no jumps when sending or while Hermes works
- **Connection:** a network change no longer restarts connecting
- **Push:** extensions, app push layer (isolated), richer notices
- **Push:** settings, permission and setup sheets
- **Push:** requests on screen wait until you leave the chat
- **Push:** Bot profiles, faces, Live Activity start rules, answered-notice cleanup
- **Push:** a gateway page with a test notification, and Set Up Push from Settings
- **Push plugin:** published to its own public repository
- **Push plugin:** creates its folder only on first write
- **Sending while Hermes works:** Steer, Redirect, Send Next, Ask Aside, Run in Background
- **Steps as layers:** compact rows, runs, details on tap; smoother folds
- Bot Chats stay connected through drops, and the Try Again card no longer sticks
- Hermes warnings never become the live status; one-line header
- Approval card fits the screen; keyboard leaves with the chat; steadier sends
- Steered messages show; polished turn header; chats open without the drop
- Bot rows preview their Bot Chat, and Hermes' control frames read naturally

</details>
