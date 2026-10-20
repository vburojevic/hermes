# Bot faces

This document covers how the app draws a Bot's face: the shapes and their geometry, the colours,
the moods and their motion, the sizes it is drawn at, and the moments where a face reacts to what
is happening. A Bot keeps the same identity (shape, colour, eye colour) here and in Hermes
Desktop.

The look is flat: one body colour, two small eyes with a catchlight, and three dots in the body
colour while the Bot thinks or works. There is no gradient, gloss, glow or shadow on a face; the
life is in the motion.

In this app the dots show only where the face stands alone (`BotFace(dots: true)`): a group's face
strip, Talk, the compact Dynamic Island. Wherever words say what the Bot is doing (chats, rows, the
toolbar, the jump pill), the face shows the mood without dots, so only one thing moves
([chat.md](chat.md) §4a).

**Attribution.** The shapes, the colour rules and the eye, catchlight and dot geometry are ported
from Hermes Desktop's Bot Mode in [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(MIT License, copyright Nous Research): `apps/desktop/src/plugins/hermes-bots/avatar.tsx`
(`BotFace`, `sampleFaceRing`, `facePose`, `paintMathFace`, `startFaceClock`, `defaultShapeFor`,
`botAppearance`) and `apps/desktop/src/lib/profile-color.ts` (`profileColor`, `hashString`). When
a Bot's identity looks different from Desktop, that file is the reference. The fitting of each
shape (§1.1) and the motion (§3) are the app's own.

Code:

| Where | What |
|---|---|
| `Packages/HermesKit/Sources/HermesPush/Faces/FaceStyle.swift` | `FaceShape`, `FaceColor`, `FaceInk`, `FaceLook`: shapes, colours, eye inks, Hermes's appearance rules |
| `…/Faces/FaceGeometry.swift` | `FaceGeometry` (Hermes's outlines) and `FaceBody` (the fitted outline, eye line and gaze range) |
| `…/Faces/FaceMotion.swift` | `FaceMood`, `FacePose`, `FaceNoise`, `FaceTarget`, `FaceTransition` |
| `…/Faces/FacePainter.swift` | `FaceFrame`, `FacePainter` (draws a frame into a `GraphicsContext`), `StillFace` |
| `App/Design/BotFace.swift` | `BotAppearance`, `BotFace` (the animated view), photo faces, sparkles, `FaceImageCache` |

The face code lives in `HermesPush` so the widget extension (Live Activity) and the notification
avatar renderer draw the same faces as the app. The public API of the view is
`BotFace(appearance:size:mood:…)`; `BotAppearance(profile:shape:color:image:customized:)` builds
the appearance from a Bot's `ui_meta["hermes-bots"]`.

## 1. Geometry (40 × 44 box)

All numbers are in a 40-wide, 44-tall box and scale with `size` (`size` is the width; the height
is `size × 1.1`, `FacePainter.height(forWidth:)`). The body and eyes sit in the top 40 × 40; the
dots sit in the strip below.

**Hermes's outlines** (`FaceGeometry.ring`) are closed paths sampled from Hermes's formulas.
Angle `a` runs from −π/2, the centre is (20, 20), and the radius is `r(a)`:

| Shape | r(a) |
|---|---|
| circle | 16.2 |
| squircle | 16.2 / (\|cos a\|⁵ + \|sin a\|⁵)^(1/5) |
| pill | 16 / (\|cos a\|⁸ + \|sin a / 0.72\|⁸)^(1/8) |
| triangle | 13.5 / max(0.42, cos((sector − 0.5) × 1.9)), where sector = ((a + π/2) mod 2π) / (2π/3) mod 1 |
| hexagon | 16.2 × cos(π/6) / cos(a − (π/3)·round(a / (π/3))) |
| cloud | fixed path `M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z`, its arcs resolved the way SVG resolves them (`FaceGeometry.cloudArcs`) |
| drop | cubic (20,3)(20,3)(6,20)(6,27), half-ellipse centre (20,27) radii 14 × 13.5, cubic back to (20,3) |

Hermes samples 52 points. Hermes's triangle reaches about 3 units above the box, and Desktop lets
it overflow.

**Hermes's eyes** are two ellipses at x 15.4 and 24.6, y 17.2 (y 22 on the cloud), rx 2.2 × ry
2.3, with ry 2.6 while the Bot listens, thinks or works. A gaze offset moves both eyes together.

**Catchlight:** a circle of r 0.65 at (eye x − 0.6, eye y − 0.7). It follows the pupils.

**Closed eyes:** a round-capped stroke 2 wide across each eye. Happy is the stroke curved up (^ ^);
sleeping is curved down (‿ ‿).

**Dots:** three circles of r 1.15 at x 16.4, 20 and 23.6, y 41.2, in the body colour. Their
opacities wave (§3).

**Photo Bots** (a picture avatar) are clipped to a rounded square with a 22% radius. They have no
eyes or dots; their only motion is a slow breath (§3).

### 1.1 How the app fits the outlines (`FaceBody`)

Drawn exactly as Hermes draws them, some shapes were cut off (the triangle's tip), some loomed over
others, and narrow shapes let the eyes drift off the body. So the app keeps Hermes's outlines but
fits each one into the box once, at launch (`FaceBody.of(_:)`, cached per shape):

1. Sample the outline at 480 points and resample it evenly by arc length.
2. Scale it to the same weight for every shape: about 680 square units (a circle about 29.5 units
   across), and never more than 33 units on its longer side.
3. Centre it on (20, 20).
4. Resample to 240 points (`FaceBody.pointCount`), the same way round for every shape and starting
   nearest the top centre, so two shapes can morph point to point.

The eyes keep Hermes's spacing (±4.6 from the middle, `FaceBody.eyeSpread`) and size, but sit on
an eye line per shape, as a share of the fitted body's height from its top:

| Shape | Eye line |
|---|---|
| circle, squircle, hexagon | 0.44 |
| pill | 0.46 |
| drop, cloud | 0.60 |
| triangle | 0.62 |

Each shape also gets a gaze range (`FaceBody.GazeRange`): how far both eyes, with a 1.4-unit
margin, can move left, right, up and down (up to 3.4 units) and still sit on the body. Every gaze
is clamped to it when drawn.

The app's strokes differ slightly from Hermes: the closed-eye stroke runs ±2.4 from the eye's
centre, the happy stroke is a curve from ±2.6 at y + 1 with its control at y − 3.4, and the
sleeping stroke a curve from ±2.4 at y + 0.6 with its control at y + 2.6.

## 2. Colour

- **Hues:** `hsl(H, 68%, 58%)` (`FaceColor.hue(_:)`, converted the way browsers convert CSS HSL).
  - A Bot without a picked colour gets H = (hash of its profile name) mod 360, where the hash is
    `h = h × 31 + UTF-16 code unit`, unsigned 32-bit (`FaceColor.nameHash`, Hermes's
    `hashString`).
  - A Bot without a picked shape gets one from the same kind of hash, taken over the name's code
    points, mod 7, in the order circle, squircle, pill, triangle, hexagon, cloud, drop
    (`FaceShape.forName`, Hermes's `defaultShapeFor`).
  - The picker offers 12 swatches at H = 0, 30 … 330 and stores `hsl(H 68% 58%)`. Stored colours
    are read in both forms Hermes writes: `#rrggbb` (or `#rgb`) and `hsl(h s% l%)`, commas
    allowed.
  - The default profile wears violet `#8b5cf6` on a squircle unless it has been customised
    (`custom: true` in its `hermes-bots` meta).
  - Design tokens: `faces.red` … `faces.pink`, `faces.default`.
- **Eyes follow the body's brightness**, computed as 0.2126 R + 0.7152 G + 0.0722 B on a 0–255
  scale (`FaceColor.luminance`, Hermes's `isDarkColor`):
  - **Below 110** (red, violet and blue among the swatches): cream eyes
    `rgba(232, 220, 195, 0.95)` (`faces.eye-on-dark`) with a dark catchlight `rgba(0, 0, 0, 0.6)`
    (`faces.sparkle-on-dark`).
  - **Otherwise:** dark eyes `rgba(0, 0, 0, 0.85)` (`faces.eye-on-light`) with a white catchlight
    `rgba(255, 255, 255, 0.85)` (`faces.sparkle-on-light`).
  - This is computed from the actual colour, never from a list.
- The same colours are used in light and dark mode, as in Hermes.
- **Increase Contrast:** the body gets a 1 pt outline in the system separator colour only when its
  WCAG contrast against the surface it usually sits on is under 3:1 (`FacePainter.contrastOutline`).
  That surface is white in light mode and `#1C1C1E` in dark mode. In practice: yellow and lime on
  white, blue and violet on dark.
- A colour change on the same Bot blends from the old colour to the new one over 0.42 s
  (ease-out), unless Reduce Motion is on.

## 3. Moods and motion

Hermes has three moods (idle, think, work) and a blink. The app adds listening, happy and
sleeping (`FaceMood`). The app does not use Hermes's pose functions (`facePose`): their head turn
rotates the outline and then squashes it on the screen axes, which shears squares into
parallelograms, and with one shared clock every Bot sways and blinks in step. Instead, a face's
body only ever moves as one rigid piece (it leans, breathes and hops) so its outline keeps its
shape, and the life is in the eyes.

### The pose

A frame's pose (`FacePose`) is:

| Field | Meaning |
|---|---|
| `lean` | Degrees the whole face rotates about the bottom centre of the body |
| `breath` | The body's height against rest (1); the width gives back half as much |
| `gazeX`, `gazeY` | Where the eyes look, in face units from their rest, clamped to the shape's gaze range |
| `lid` | Eyelids, 1 open to 0 shut |
| `dots` | The three dots' opacities |

`FacePose.of(mood, at: t, seed:)` gives the pose at `t` seconds on the shared clock. The seed is
the hash of the Bot's profile name (`BotAppearance.seed`): it sets the face's own speed (0.9–1.1×)
and a time offset, and every random choice below comes from deterministic noise on it
(`FaceNoise`, splitmix64). The same Bot moves the same way on every device and redraw, and Bots
side by side never move in step.

The motion repeats every 40 s (`FaceTarget.period`): the last 1.5 s of each stretch fades into its
first, blinks included (each stretch's blinks fade out rather than averaging into a half-shut
stare). So one loop of a mood's motion serves at any moment, played `t mod 40` seconds in, and
a face looks the same whether it's drawn or played (§3, The clock and frame rates).

### Per mood

With `T = 2π × t` (t already scaled and offset by the seed):

| Mood | Lean (°) | Breath | Gaze | One blink about every | Dots |
|---|---|---|---|---|---|
| idle | 1.4 sin(T/6.3) + 0.5 sin(T/2.9) | 1 + 0.016 sin(T/3.6) | a new target every 2.6 s, reached in 0.12 s: 40% of the time straight ahead, else x within ±2.3, y within ±1.2 | 4.4 s | off |
| listening | −1.6 + 0.6 sin(T/4.7) (leaning in) | 1 + 0.012 sin(T/3.2) | toward the composer: x 0.2…1.4, y 1.1…1.7, a new target every 1.9 s | 5.2 s | off |
| thinking | 3.2 sin(T/4.1) | 1 + 0.014 sin(T/3.0) | up and to one side: x ±1.2…2.6, y −1.6…−2.4, a new target every 1.7 s, reached in 0.38 s | 3.4 s | wave, f = 2.2 |
| working | 1.1 sin(T/1.8) | 1 + 0.012 sin(T/2.4) | reading along a line: x from −1.9 to +1.9 over 82% of each 1.25 s, then a quick return; y 0.85…1.35 per line | 3.1 s | wave, f = 2.6 |
| happy | as idle | as idle | idle's x × 0.3, y −0.4 | none: ^ ^ eyes | off |
| sleeping | 0 | still | y 0.6 | lids shut: ‿ ‿ eyes | off |

- **Glances** switch at an uneven moment of each stretch (between 15% and 75% of it) and ease out,
  so they never keep time.
- **Blinks** land at an uneven moment of each interval (between 20% and 80%); 18% of them are
  double blinks, 0.26 s apart. The lids shut in 70 ms (ease-in), stay shut 50 ms and are open again
  by 240 ms (ease-out) (`FacePose.lidCurve`).
- **Dots:** dot k (0, 1, 2) has opacity 0.2 + 0.8 · max(0, sin(f·t − 0.7k)), on the unscaled
  clock. Hermes uses f = 2.4 for think and 2.6 for work.
- **Eyes:** open eyes are 2.3 tall, 2.6 while listening, thinking or working, times `lid`. Below
  0.35 they are drawn as the closed stroke.
- **Sleeping** (Bot Mode offline, the chat put to rest by the gateway, the Bot hidden): ‿ ‿ eyes,
  the body and dots at 45% opacity, and no motion at all (the face's clock stops).
- **Looking at something:** a view can pass `look`, a direction with each axis −1…1. It replaces
  the mood's gaze with up to 3.2 units each way (`FaceTarget.maxGaze`), except while sleeping.
- **Switching mood or look** blends from the pose on screen over 0.4 s with ease-out
  (1 − (1 − p)²) (`FaceTransition`), so a change never jumps.

### One-offs on top of the pose

These live in `BotFace` and `FaceFrame`:

- **Happy hop:** when the mood turns happy (or on a boop), the face rises 2.64 units (6% of its
  height) in 0.12 s, then springs back (response 0.35, damping 0.6). The ^ ^ eyes hold for 1.2 s.
- **Boop squash:** squash 1.12 × 0.86 in 0.09 s, stretch 0.92 × 1.1 by 0.22 s, then settle with a
  small overshoot by 0.6 s, scaled about the bottom of the body (§5.4).
- **Voice squash:** while a Bot speaks in Talk, sy = 0.94 + 0.16 × level and sx = 2 − sy
  (§5.3).
- **Needs you:** while an approval waits in Talk, the face wiggles (±4°, 0.4 s) every 6 s.
- **One blink on demand** (`blinks`): a mention pill sent, a pause in typing.
- **Shape morph:** when the same Bot's shape changes (the editor), the outline interpolates point
  to point from the old fitted outline to the new one over 0.42 s on an underdamped curve, and the
  eye line and gaze range blend with it. A face view that is reused for a different Bot (a list
  reordering, the next chat) never morphs: `BotAppearance.id` is the profile name, and a new id
  just shows the new face.
- **Photo breath:** a picture avatar scales up to 2% from its bottom edge on a 4 s cycle. A
  picture the app has (a stored face) breathes on layers like a face at rest; one still loading
  from a link breathes at 12 fps.

### The clock and frame rates

- A face doing only its mood's motion (shown, the window in front, no blink on cue, boop, hop,
  new shape or colour, mood or look change, voice or happy moment under way, 24 pt or larger) is
  played by Core Animation (`FaceLayers`). Its mood's loop (`FaceLoop`: lean, breath, eye
  position, eyelids, catchlight and dots, each thinned to the keys that matter) is built once per
  Bot and mood off the main actor (`FaceLoops`) and handed to the render server, which plays it at
  up to 24 fps (60 for the face in focus, 12 in Low Power Mode) with no work in the app per frame.
  A Bots page in front measured 0% CPU this way, against about 30% drawn. Everything else is
  drawn as below and hands back when it's done.
- One clock drives every drawn face: seconds since launch (`FaceClock`), ticked by one loop
  (`FaceTicker`) on a grid of 24ths of a second. Each face draws in a `Canvas` that reads the
  latest tick, so every face on screen moves in the same instant and the window draws once per
  tick. No `TimelineView` per face: `.animation(minimumInterval:)` wakes the window on every
  display frame however low the interval (120 a second on a Mac), and a periodic schedule per
  face draws the window for each face's own timer (about 100 a second for a sidebar of Bots).
  Either kept a core half busy with a Bot chat in front.
- Frame rates: 24 fps for a busy face and for the face in focus (88 pt and larger, a face with a
  voice level, a face booped in the last 1.2 s or morphing), 12 fps for an idle face and in Low
  Power Mode. Talk's squash follows the voice level, which redraws the face as it changes.
- A face's clock is paused when it is off screen (`onScrollVisibilityChange`), when
  `pausesDecorativeMotion` is set (the window isn't in front, the app isn't active, or Low Power
  Mode is on, so inside the main window Low Power Mode holds faces still rather than slowing them),
  while it sleeps, and for faces under 24 pt except during a one-off (a blink, a boop, a hop, a
  morph or a colour blend).
- A paused face shows the pose it is heading for with its eyes open, never a frame caught
  mid-blink or mid-change.
- **Reduce Motion:** no lean, breath, glances, looks, hop, squash, sparkles or morph (a new shape
  or colour shows at once). The blink and the dots stay. A boop gives happy eyes and the haptic
  only. Mood changes still blend over 0.4 s, which with Reduce Motion only moves the eyelids and
  dots.

## 4. Sizes

| Where | Size (width, pt) |
|---|---|
| Talk | 160; 84 in the panel, the iPad landscape and the Mac window, and while an approval waits |
| Bot hello (a Bot Chat before its first message) | 120 |
| New Bot / Edit Bot preview | 88 |
| Welcome tour | 64 |
| Bots grid tiles | 56 |
| Routines | 40 |
| Roster rows | 36 on iPhone and iPad, 28 on the Mac (`SidebarMetrics.faceSize`) |
| Notification avatar | 36, rendered still (§5.6) |
| Lock Screen Live Activity | 36 |
| Shape picker in New Bot / Edit Bot | 36, 26 on the Mac |
| Bot Chat toolbar | 32 |
| Group Activity rows, member picker, `/` menu, Quick Open | 30 |
| Bot message cards, group member messages | 28 |
| Dynamic Island | 24 expanded, 20 compact and minimal |
| Group chat header stack | 20 |
| Mention pills | 18 (15 in small pills), scaled with Dynamic Type |
| Search results, passed rows in group chats | 16 |

Below 24 pt the catchlights are hidden and the dots are drawn at 1.4× their radius, so they still
read. Faces under 24 pt also hold still apart from their one-off blinks, and show busy moods with
the dots frozen mid-wave.

## 5. Moments in the app

Each moment is small and never blocks anything.

1. **The header shows what the Bot is doing.** The Bot Chat's toolbar face
   (`BotChatTitle`, from `ConversationModel.faceMood(isOnline:)`):
   - thinking while a turn runs, working while a tool runs (between `tool.start` and its
     completion, `LiveTurn.isUsingTool`), idle when the turn is done;
   - happy for 1.8 s after a turn completes;
   - listening while the composer has text or the person dictates;
   - sleeping when Bot Mode is offline, or when the gateway has put the chat to rest
     (`session.reclaimed`) and no turn is running.

   The Bot hello face follows the same rules, without the happy moment. Roster rows and grid
   tiles use `BotRoster.faceMood(for:)`: the Bot Chat's turn, working while one of the Bot's
   background workers has beaten in the last 150 s, sleeping when Bot Mode is offline or the Bot
   is hidden.
   A grid tile listens while the pointer hovers over it.
2. **Group chats: everyone looks at who's talking** (`GroupFaceStack`, `MemberStatusRow`).
   - The member whose turn is running (`turn.started` in `groups.log`, not yet settled) thinks,
     lifted by 12% of its size and tilted 4°.
   - The other members' faces look toward it, in the header stack and in the Activity sheet.
   - A member that passed blinks once and looks back to centre.
   - The header shows at most three faces.
3. **Talk: the face is the voice** (`TalkFigure`, `docs/voice.md` §4.2).
   - While listening, three rings in the Bot's colour (`ring0`…`ring2`) grow with the
     microphone level.
   - While the Bot talks, the body squashes with its real voice level (sx = 2 − sy, sy
     0.94–1.1): the RMS of the audio being played, per 1/30 s, looked up by play time (Realtime:
     WebRTC's playout).
   - The eyes look slightly down, at the person, except while working.
4. **Tap a Bot: boop.** On the Bots grid, the Bot Chat header, the Bot hello and the New Bot
   preview: squash, stretch, settle (§3), happy eyes, a hop, and 3 SF Symbol `sparkle`s (4 on faces
   40 pt and larger) in the Bot's colour that pop and fade in 0.6 s, with a light impact haptic.
   Long-press still opens the context menu.
5. **New Bot: it watches you name it** (`BotSheet`).
   - The preview face listens while a field has focus, and looks down at the Name field while it
     has focus (down and to the right on the Mac, where the face sits beside the name).
   - It blinks when typing pauses for 0.8 s.
   - It morphs to each shape picked and blends to each colour (0.42 s), with a happy squint for
     0.9 s after each pick.
   - It thinks while saving. A new Bot gets a sparkle burst, a success haptic and happy eyes
     before the sheet closes.
   - The preview keeps one identity while the name is typed, so it morphs instead of starting
     over. Each face in the shape row has its own timing, so the row doesn't blink in unison.
6. **Dynamic Island, Lock Screen and notifications.**
   - A turn's Live Activity shows the Bot's face: working, with the dots mid-wave, while the turn
     runs, idle when it's done (`IslandFace`). Live Activities don't animate, so it's one frame.
   - Communication notifications use the face as the sender's avatar. The app renders each Bot's
     face to a 36 pt PNG at 3× (idle, still; a photo Bot's picture) where the Notification Service
     extension finds it (`PushCenter.renderFaces`), re-renders a face older than a day, and
     re-renders all of them once when the drawing style changes. See
     [notifications.md](notifications.md).
7. **Mentions come alive.** A Bot's mention pill (`Slash.mentionInline`, `mentionChip`) in a
   message just sent blinks once, 0.35 s after it appears (`mentionsBlinkOnAppear`).
   - Not built yet: the face in the reply starting to think when the mentioned Bot picks the
     message up. In group chats the mentioned member's header face thinks once its turn starts
     (§5.2).
8. **Hand-offs: Bots look at each other.**
   - In a group chat, when a member's message mentions another member (`@handle`), the two faces
     in the header stack turn toward each other for 0.6 s; then the receiving one thinks until its
     turn starts (at most 3 s). Only hand-offs that happen while the room is open count, not the
     one it opened on.
   - In a Bot Chat, a message another Bot sent with `message_agent` that arrived in the last 8 s
     shows its sender's face on the card looking up toward the header for 0.6 s.
   - Not built yet: faces reacting when Hermes delegates to a Bot.

9. **The list shows what each Bot is doing** (`BotInboxRow`, `ActivityLine.faceMood`,
   `docs/inbox.md` §2):
   - thinking while it starts or thinks (a routine included);
   - working while a tool runs, helpers work or it writes;
   - listening while it waits for you;
   - happy for 2 s when a reply lands;
   - sleeping when it's muted and idle (and, as before, offline or hidden).

   Rows and chats show no dots: the activity line says it in words. A group chat's
   `BotThinkingLine` uses the thinking face without dots ([chat.md](chat.md) §4a).

## 6. Checks

- Unit tests (`Packages/HermesKit/Tests/HermesKitTests/FaceTests.swift`): outlines follow Hermes's
  formulas, the cloud's arcs resolve as SVG does, morphs keep every outline the same way round,
  colours come from the name and eyes from luminance, every shape fits whole with room to move,
  eyes stay on the body wherever they look, each Bot keeps its own time, blinks close and open
  smoothly, busy moods wave their dots, mood changes blend over 0.4 s with ease-out, Increase
  Contrast outlines pale bodies, a mood's loop follows its pose and repeats without a seam, and a
  loop's eyes shut and lose their catchlight as the painter draws them.
- In a Debug build, `-HERMES_GALLERY faces` opens a gallery of every shape in every colour, the
  moods, the sizes and a morph (`App/Debug/DesignGallery.swift`).
- For every shape and the 12 swatches plus the default violet, a face's identity matches Hermes
  Desktop side by side: the same shape, the same colour, and the same eye colour (red, violet and
  blue get cream eyes). The outlines are fitted (§1.1), so they are not pixel-identical.
- No gradient, gloss, glow or shadow anywhere on a face.
- Each mood's motion matches §3; mood changes blend in 0.4 s; Bots side by side don't move in
  step.
- Reduce Motion leaves only the blink and the dots. No more than 24 fps anywhere drawn, 12 at
  rest. Off-screen faces don't tick.
- A face at rest is on layers: a SwiftUI trace with Bots on screen shows no window redraws from
  it. `-HERMES_FACE_CANVAS YES` (Debug) draws every face instead, to compare. A face handing over
  between drawn and layers doesn't jump.
- Each moment in §5 triggers on the event listed and never delays the UI.

## 7. Setup

Faces come with Bot Mode ([setup.md](setup.md) §4.1); there's nothing else to set up.
