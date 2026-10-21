# From the designs to SwiftUI

How each rule of the app's visual design maps to SwiftUI: colours, Liquid Glass, buttons, inputs,
sheets, toolbars, type, states, symbols and accessibility, plus the Bots home. The design itself
lives in a separate design project; this doc carries its component and token names in backticks
(`inkButton`, `media-dim`) so code and design can be matched. [AGENTS.md](../AGENTS.md) has the
short version of the UI rules.

The shared pieces live in `App/Design/`: `Theme.swift` (the colour names views use, type, radii,
motion), `Palette.swift` (every design colour, generated), `Components.swift` (button styles and
small views), `Motion.swift` (`pausesDecorativeMotion`, Low Power Mode), `Effects.swift` (Metal
effects), `HermesMark.swift` and `BotFace.swift`. The app targets iOS and macOS 26; Apple API names
here are checked against the SDKs it builds with.

## 1. Colour

The design's colour tokens have four values each: light, dark, Increase Contrast, and dark with
Increase Contrast.

- `Tools/elyx/generate_palette.py` turns the tokens into `App/Design/Palette.swift` (maintainers run
  it against the design project; don't edit the file by hand). Each colour is a
  `Color(light:dark:increasedContrastLight:increasedContrastDark:)` (`Theme.swift`), a dynamic
  `UIColor`/`NSColor` provider that switches with the appearance and Increase Contrast. A token an
  appearance doesn't override falls back to dark, then light. There are no asset-catalog colour
  sets apart from `AccentColor`.
- Settings → Appearance (System, Light, Dark) is set on iPhone and iPad as the window's
  `overrideUserInterfaceStyle` (`WindowAppearance`), not with `.preferredColorScheme`. iOS draws the
  app switcher's picture of the app with the window's style. With the SwiftUI preference, an app
  set to Dark on a phone in Light Mode (or the reverse) left a picture in the phone's appearance:
  the switcher showed it light, and it turned dark as it opened. The Mac keeps
  `.preferredColorScheme`. Check: `Scripts/check-switcher-snapshots.sh`.
- Views use the names in `Theme` (`Theme.canvas`, `Theme.primaryText`, `Theme.ink`), not `Palette`
  directly. Colours that aren't design tokens live in `Theme` with the same initializer
  (`rowSelected`, `rowHover`).
- Where a token equals a system colour, its values are the system colour's, copied:

| Token | System equivalent |
|---|---|
| `canvas` | system background (white, black) |
| `grouped-background`, `grouped-cell` | system grouped background, secondary grouped background |
| `sheet-background`, `sheet-cell` | the same grouped colours with the elevated dark values (#1C1C1E, #2C2C2E) that sheets get |
| `separator` | system separator |
| `control-fill` | tertiary system fill |
| `switch-on` | system green (toggles are system `Toggle`s, so the app doesn't use it) |
| `link` | system blue (the text-legible variant) |

  The app doesn't reference the system colours themselves, so if the OS changes them, the tokens
  need updating to follow.
- Unread marks (counts, dots, the mode switch's badges) are `ink` / `on-ink`; a muted count is
  `control-fill` with `text-secondary`. The blue `faces.unread` is retired (`docs/inbox.md`).
- Custom, not system: `ink` and `on-ink` (the black/white action colour), `text-*` (slightly softer
  than the system labels; secondary and tertiary both clear 4.5:1 on every surface), `surface` and
  `surface-raised`, `sidebar`, the status colours `success`, `warning`, `danger` (darker in light mode
  than system green, orange and red so they pass 4.5:1 as text), the `*-tint`, `*-wash`, `*-halo`
  and `*-border` backgrounds, `accents.*` (a Bot's avatar colours), `faces.*` (Bot faces),
  `syntax.*` (code, after Xcode's themes).
- `ink` is the tint for primary actions only. It is not the app's accent colour: `AccentColor` is
  system blue, so links and selection stay blue.
- `media-dim` (35% black) is the dimming layer under clear glass over live media: the Inspector's
  Screen bar fades over it.
- The generator skips tokens that exist only to draw Liquid Glass, scroll fades and mock-up chrome
  in a static design: `glass-*`, `clear-glass`, `on-glass-dark`, `*-veil`, `*-clear`, and the
  `desktop-*`, `window-*`, `traffic-*`, `keyboard-*`, `camera-backdrop` and `qr-*` chrome. The app
  gets glass and scroll edges from the system (§2) and needs no colours for them.

## 2. Liquid Glass

Glass is for the layer that floats above content: toolbar buttons and the model picker, the
composer and what docks above it, the Mac and iPad sidebar, menus, popovers, alerts, half-height
sheets, banners, the slash menu, the Inspector's tab strip and pill, and floating bars.

- Standard bars, sheets, menus, alerts and sidebars become glass by building with the current SDK.
  Don't draw them by hand.
- Custom floating surfaces use `glassEffect(.regular, in: shape)` (`.regular.interactive()` for the
  Inspector pill). Neighbouring glass shapes share one `GlassEffectContainer` so they blend and
  morph: the chat's bottom stack (request dock, error banner, goal bar, voice bar, Inspector pill,
  composer) is one container in `ChatScreen.bottomBar`, and the banner, goal and voice bars and the
  composer each have a `glassEffectID` of their own.
- The specular rim in the designs (`glass-edge`, `glass-rim-faint`) is what the system draws on real
  glass. Don't recreate it.
- Clear glass (`.clear`) only over live media, with `media-dim` behind it: the Inspector's Screen
  bar. Other controls over a camera or video (the pairing scanner's hint) use regular glass in the
  dark appearance.
- Tint only the single primary action: `.prominentGlassButton()` (`.glassProminent` tinted `ink`).
  Everything else stays untinted (`.glassButton()` clears any surrounding tint, since `.glass` fills
  itself with it while a Mac window is active).
- Never put glass on content: chat bubbles, transcript cards, list rows, chips, the tiles inside a
  request card, the Inspector's tab bodies. Those use `surface` and `canvas` fills.
- No glass on glass: buttons inside a sheet, alert or docked card are filled buttons
  (`.inkFilledButton()`, `.cardButton()`; §3).
- Scroll fades (`*-veil` gradients in the designs) are the system's scroll edge effect:
  `scrollEdgeEffectStyle(.soft, for: [.top, .bottom])` on the transcript, the sidebar and other
  long lists. Content scrolls under the toolbar and the composer: bars attach with
  `safeAreaBar(edge:)` (the composer stack, the connection banner, the sidebar's header and footer),
  not with insets.
- Corners: inner radius = outer radius − padding. The app uses fixed radii from `Theme.Radius`
  (bubble 22, composer 28, card 18, code 14, row 12); `ConcentricRectangle` isn't used yet.
- The system handles Reduce Transparency, Increase Contrast and Reduce Motion for real glass. Test
  all three; don't add your own fallbacks first.

## 3. Buttons

Three levels, plus icon buttons.

| Level | Design component | SwiftUI (`Components.swift`) |
|---|---|---|
| Primary, one per group | `inkButton` (34 pt), `prominentButton` (50 pt) | `.inkFilledButton()`: `.borderedProminent`, capsule, tinted `ink`, inside cards and sheets. `.prominentGlassButton()` when it floats. `.inkDefaultButton()` for a Mac window's default action (Run Now, Create Project), which drops the fill while the window is inactive |
| Secondary | `borderedButton`, `destructiveButton` (red label), `tonalButton` (50 pt) | `.cardButton()`: `.bordered`, capsule, tinted with the primary text colour; `role: .destructive` for the red one |
| Floating over content or media | `glassButton`, `compactGlassButton`, `glassIconButton` | `.glassButton()` (`.glass`) |
| Third-level option | plain text link | `.buttonStyle(.plain)` with the secondary text colour |
| Icon only, rows, cards | — | `IconButtonStyle(size:)` (a hit area with a pressed circle), `PressableStyle` (dims while pressed) |

- Paired buttons share the row equally, secondary on the left, primary on the right. The primary
  gets `.keyboardShortcut(.defaultAction)` so Return triggers it on Mac and iPad.
- Toolbar items are standard `ToolbarItem`s; the system gives them glass. Sheet chrome goes in
  `.cancellationAction` and `.confirmationAction`; where a sheet uses `Button(role: .confirm)` and
  `role: .cancel`, the system draws the ✓ and ✕.
- Mac alerts and Mac Settings use the native macOS button look; don't restyle them.
- Minimum touch target 44 × 44 pt on iPhone and iPad even where the drawn shape is smaller (the 34
  pt and 36 pt controls); give the label a larger frame and `contentShape`, as `ErrorBanner`'s ✕
  does. Not met everywhere yet: `IconButtonStyle` defaults to 36 pt, and the Inspector's bars use
  28–30 pt.

## 4. Inputs

The design's input catalog (`inputCatalog`) shows every input type with its purpose.

| Design | SwiftUI |
|---|---|
| Grouped form sections (`Forms.formCard`, the row components) | `Form` with `.formStyle(.grouped)`; on the Mac this gives the Settings look |
| `formField`, `formFieldFilled` | `TextField` in a form row |
| `secureField` with the eye | `SecureField`, swapped for a `TextField` while revealed, with an eye button ("Show", "Hide") |
| `formFieldError` | keep the typed value, show the warning glyph, put the reason in the section footer in `danger` |
| `textArea` | `TextField(axis: .vertical)` with a line limit range |
| `searchField` in sheets and lists | `.searchable` |
| The sidebar's search | `SearchField` (`SidebarView.swift`), a field of its own that ⌥⌘F focuses |
| `glassSearchBar` (Skills) | `.searchable(placement: .toolbar)`, which iPhone puts at the bottom; dictation comes from the system |
| `switchOn` / `switchOff`, `macSwitch*` | `Toggle` |
| `segmentedControl` | `Picker` with `.pickerStyle(.segmented)` |
| `stepper` | `Stepper` |
| `swatch` | a custom button row; the selected swatch gets a 2 pt ring outset 4 pt |
| Picker rows (value and chevron) | `Picker` with the menu style, or `.pickerStyle(.navigationLink)` on iPhone |
| Request-card inputs (`choiceRow`, `checkRow`, `otherRow`, `plainField`, `maskedField`) | custom views; see [quick-actions.md](quick-actions.md) |

The Paste button in `maskedField` is the system `PasteButton`, which pastes without the permission
prompt. It shows only on iPhone and iPad, in an empty key or token field (not a password) and in a
code field. The Mac reads the pasteboard when asked.

## 5. Sheets, menus and alerts

- Full-height sheets: `.sheet` with the large detent and grouped form content. On the Mac, a sheet
  sets its own frame size.
- Half-height sheets (Connect, Activity, Permissions, the iPhone Inspector):
  `.presentationDetents` with a medium or custom height. The system insets them and makes them
  glass; the 8 pt inset and radius 46 in the designs are that system look.
- Menus: `Menu` and `.contextMenu` with labelled buttons and SF Symbols. Destructive items use the
  destructive role.
- Alerts: `.alert` and `.confirmationDialog`. "Always Allow" always goes through a confirmation
  ("Always allow commands like this?").
- Popovers on iPad and Mac (the model picker, the Inspector's + menu, file and skill previews):
  `.popover`; on iPhone the model picker becomes a sheet. The slash menu is glass above the
  composer, not a popover.

## 6. Toolbars and navigation

- Chat toolbar: the leading sidebar button (`SidebarButton`, two offset bars and the unread count;
  on iPhone and iPad it draws its own glass, `sidebarButtonGlass()`, so the count stays whole
  while it's pressed: the toolbar's glass clipped it), the centred model
  picker (a Bot Chat shows the Bot's title instead), and a trailing New Chat (a Bot Chat has
  Routines and a … menu). iPad and Mac add the Inspector button ([inspector.md](inspector.md)).
- Not built yet: the toolbar shrinking while scrolling (frame `chatReplyMinimized`).
- iPad and Mac: `NavigationSplitView` (balanced; sidebar 240–380 pt, ideally 290). The sidebar
  floats as inset glass by default on the current SDK. In a compact width (iPhone, narrow iPad
  windows) the sidebar is a drawer that slides over the chat.
- Detail-page actions float in a bottom bar (Task detail: Run Now, Pause) attached with
  `safeAreaBar(edge: .bottom)`.
- Mac Settings: a page pushed inside a Settings tab (Setup's feature pages, Hermes's voice, a
  gateway's notifications, Browse All Apps…) carries `.settingsPage(back:)`. Its back button sits
  at the top of the page with ⌘[. The system one in the window's toolbar pushes the tab buttons
  aside while macOS keeps the highlight where it was, over the wrong tab. On iPhone and iPad it
  changes nothing.
- Mac Settings: every tab shows, none in the toolbar's » overflow, where the open tab has no
  highlight. Each pane is at least `SettingsTabsFit.width` wide: estimated from the tab titles as
  AppKit lays them out, then checked against the toolbar (`visibleItems`) after each resize, which
  widens it while a tab is still clipped (a larger text size, a longer translation). A pane's own
  toolbar items would crowd the tabs too, so Settings pages keep their actions in the page
  (Setup's Check Again), and Setup's Memory page opens the Memory tab.
- Not built yet: the zoom from a Bot tile into its chat ([bot-faces.md](bot-faces.md)); a tap opens
  the chat directly.

## 7. Type

The design's type tokens hold the sizes for iOS and iPadOS and for macOS. On iPhone and iPad each
maps to a system text style (`.body`, `.subheadline`, `.footnote`, `.caption`, `.headline`, `.title3`
and so on): use the text styles, never fixed sizes, so Dynamic Type works. Code uses the monospaced
design of the same style (`Font.system(.footnote, design: .monospaced)`). The design shows Menlo
only because the design tool has no SF Mono.

macOS has no Dynamic Type and a 13 pt body, which is too small for long-form chat, so
`Theme.Typography` gives the Mac its own scale (messages 15 pt, code 12.5 pt, headings 22 / 19 /
16.5 / 15 pt). Glyph sizes for SF Symbols are set with `.font(.system(size:))`; text isn't.

## 8. States

Each screen has its empty, loading, error, offline and permission states, built from the design's
state and banner components.

- Empty and error states in lists and pages: `ContentUnavailableView` with the symbol, title,
  description and one secondary button from the design. Full-area states inside panels and detail
  pages (the Inspector's tabs, the Board, Tasks) use `StateMessage` (`Components.swift`): a symbol,
  a title, a message and one glass button.
- In the sidebar and drawer (no chats, no search results, Bots connecting, sign-in needed, Bots
  offline, no Bots) the state is centred in the free space between the navigation rows and the
  footer, not pinned under the last row: `SidebarState` sits in the list's overlay, padded down by
  the navigation rows' height, so the rows stay in place.
- A feature that needs something configured (Bot Mode, a plugin, a key, a permission) shows its
  setup state with the setup views (§12), not an error.
- Connection problems: the banner under the toolbar (`ConnectionBanner`, `BotModeBanner`) with its
  one action (Retry, Edit Gateway), the sidebar's "Can't reach" state, and the composer's offline
  state. Errors from a turn show as a glass `ErrorBanner` above the composer.
- Loading ([chat.md](chat.md) §4a):
  - **Agent activity** is one shimmering line of words, once per place: one `ShimmerText` view for
    the turn header, a row's activity line, the jump pill, `BotThinkingLine` and the background
    line. Never typing bubbles, waving dots or spinners for agent activity.
  - **How it moves:** the band is a Core Animation layer (`ShimmerLayer`) masked by the words,
    capped at 30 fps, not a `TimelineView`, because it costs the app nothing per frame. Measured
    on the iOS 27 simulator (2026-10-20, a loaded Mac, 20 s each): a working Bot's chat took 9.3% of
    a core for the app with the layer against 19.0% with `TimelineView(.animation(minimumInterval:
    1/30))` redrawing a gradient, the render server about 8% either way; the indicators gallery
    (about ten shimmers) took 2.4% with the layer, the same as with Reduce Motion (2.9%), against
    13.9% (and 16% against 6.8% in the render server). `TimelineView` still wakes the window at
    display rate whatever its interval. `-HERMES_SHIMMER_TIMELINE YES` (Debug) swaps it in to
    measure again.
  - **`Spinner`** (a `ProgressView` shown after 0.5 s) only for the app's own waiting that the
    person started (connecting, pairing, signing in, installing, restarting, saving), in the control
    that started it or centred on an empty page. **`SkeletonRows`** for lists and cards that load.
  - **Reduce Motion:** the shimmer stops; the words are still `text-secondary`.
- Decorative motion (shimmer, blinks, auras, pulsing dots) holds still while
  `pausesDecorativeMotion` is set (the window isn't in front, or Low Power Mode is on) and stops
  under Reduce Motion. Every window's root sets it with `pausesMotionWhenAway()`, the Settings and
  Inspector windows included. A loop goes through `DecorativeLoop`: its moving part is a view that
  starts as it appears and is taken away to stop, since setting a `repeatForever` value back
  without an animation doesn't end it (and lists keep hidden rows alive). The loop that runs while
  a Bot works (the shimmer) is a Core Animation layer
  (`LoopLayers.swift`, as `FaceLayers` for faces): the render server plays it and the app does
  nothing per frame. A SwiftUI `repeatForever` costs the app every frame it runs.

## 9. Symbols

Icons are SF Symbols, drawn with `Image(systemName:)` under the names the design uses
(`hand.raised.fill`); the app ships no symbol images. The Hermes wing is a `Shape` of its own
(`HermesMark`), the same path the app icons are rendered from (`Tools/IconGen`), and Bot faces are
drawn (`BotFace`, [bot-faces.md](bot-faces.md)).

## 10. Accessibility checks

- Light, dark and both Increase Contrast appearances match the design.
- Text contrast is at least 4.5:1 everywhere, and code's syntax colours reach 7:1 with Increase
  Contrast.
- Dynamic Type up to the largest accessibility size without clipped buttons; paired buttons may
  stack vertically at large sizes.
- Every icon-only button has a label. Request cards announce their title and answers in order.
- Reduce Motion and Reduce Transparency behave as described in §2 and §8.

## 11. Getting back to the Bots grid ("All Bots")

The Bots home grid (`BotsHomeView`; designs `bots-home`, `macBots`, `bots-landscape`) is the home
of Bots mode. The way back to it from any Bot or group chat is the **All Bots** row, the first row
of the sidebar in Bots mode (`Sidebar.sidebarBots`, `macSidebarBots`; frame `drawerBotsHome` shows
it selected on iPhone).

- Sidebar rows in Bots mode, in order: All Bots, New Bot (⇧⌘N), New Group Chat (when the gateway
  has group chats), Tasks (⇧⌘1), Skills (⇧⌘2), then the roster.
- All Bots is a selection, not an action: it's highlighted while the grid shows, and no roster row is
  highlighted then.
- In the code it's the empty selection: `BotWorkspace.selection` is a `SidebarItem?` (`.session`,
  `.bot`, `.group`, `.tasks`, `.skills`, `.project`, `.board`, `.allProjects`), and `nil` in Bots
  mode shows the grid (`DetailView.showsBotsHome`). A window keeps its selection in
  `SceneStorage` (`SidebarItem.storedValue`); an empty one restores as the grid, with no special
  case.
- Each sidebar mode remembers what it last showed while the app runs: switching from Chats to Bots
  lands on the Bot chat that was open the last time Bots mode was used, else on All Bots.
- On iPhone, selecting All Bots closes the drawer and shows the grid.
- Chats mode needs no equivalent row: New Chat already opens the empty chat with the greeting and
  suggestions, which is the home of Chats mode.

## 12. Setup states

What a feature shows when it needs something configured: its state, the fix the app can make,
the steps to take elsewhere and what still works ([setup.md](setup.md) has the rule and every
feature's states). The views are in `App/Design/SetupViews.swift`. Each takes a `SetupStatus`
(HermesKit, `Setup/SetupStatus.swift`) that the feature's producer works out; the feature keeps
the actions and passes them in (`check:`, `fix:`).

| Where | View | What it draws |
|---|---|---|
| A Settings page (a `Form`) | `SetupSection` | A grouped section: the state label and what it means, what still works, the fix as a Form button (or the feature's own controls), the numbered steps, Check Again and Learn More. A ready feature is one row |
| Settings lists, the Setup page | `SetupRow` | A glyph tile, the feature's name, one line (what's in use, what still works, or what's missing) and the state label, opening the feature's page |
| A page or panel that isn't a `Form` (the top of a list, the Inspector) | `SetupCard` | The same parts on a `surface` card; the fix is the card's one `inkFilledButton()`, Check Again a `cardButton()` |
| A panel whose feature can't work at all | `SetupMessage` | `StateMessage`'s layout with the steps on a card and the same buttons |
| Where a feature runs on its fallback | `SetupNote` | One footnote line with an info glyph and a "Set Up…" button in the link colour |

- The state label (`SetupStateLabel`): Ready (`checkmark.circle.fill` in `success`), Partly set
  up (`exclamationmark.circle.fill` in `warning`), Not set up (`circle.dashed`), Can't check
  (`questionmark.circle`), Checking… (a small spinner). The words stay `text-secondary` in every
  appearance; the glyph carries the colour, so colour is never the only signal.
- A step's command (`SetupCommand`) is monospaced footnote text on a `surface` box, selectable,
  with a Copy button (a 44 pt target) that turns into a ✓ for two seconds.
- Learn More opens Hermes Agent's documentation (`HermesDocs.page`), and only an http(s) link
  (`WebLink.isWeb`).
- Check Again shows only while the feature isn't ready. A ready feature says what's in use
  ("ElevenLabs · Adam"), plus steps and Learn More only when there's one thing worth doing (an
  update).
- Setup is never a banner over a chat or an alert. A chat feature that falls back says so where
  it starts (a `SetupNote` under the control), and the connection banner stays for connection
  problems.
- VoiceOver reads the state and what it means as one element; the fix, Check Again, Copy and
  Learn More are separate buttons.
