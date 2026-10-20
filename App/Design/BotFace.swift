import HermesKit
import HermesPush
import ImageIO
import QuartzCore
import SwiftUI

/// How a Bot looks: Hermes Bot Mode's avatar model (`ui_meta['hermes-bots']` shape + colour + image),
/// drawn natively so a Bot looks the same in the Hermes desktop app and here (`docs/bot-faces.md`).
struct BotAppearance: Hashable, Sendable {
    typealias Shape = FaceShape

    /// Whose face this is (the profile name): a face shown for another Bot changes at once, while
    /// the same Bot's new shape or colour morphs into place.
    var id: String
    /// The drawn face: shape and colour.
    var look: FaceLook
    /// `data:` or `http(s):` image that replaces the drawn face.
    var imageURL: String?

    var shape: FaceShape { look.shape }
    /// The Bot's colour, for the things around its face (rings, sparkles, auras).
    var color: Color { Color(look.color) }
    /// Cream eyes: the body's luminance is under 110.
    var isDark: Bool { look.color.isDark }

    /// Hermes's rules (`botAppearance`): a stored pick wins; otherwise shape and hue come from the
    /// profile name. The primary profile wears a fixed violet squircle.
    init(profile: String, shape storedShape: String? = nil, color storedColor: String? = nil, image: String? = nil, customized: Bool = false) {
        id = profile
        look = FaceLook(profile: profile, shape: storedShape, color: storedColor, customized: customized)
        imageURL = (image?.isEmpty ?? true) ? nil : image
    }

    /// Hermes's `hashString`: `hash * 31 + code unit`, wrapping at 32 bits.
    static func stringHash(_ text: String) -> UInt32 {
        FaceColor.nameHash(text)
    }

    /// The face's own timing (`FacePose.of`): Bots side by side never sway or blink in step.
    var seed: UInt32 { FaceColor.nameHash(id) }
}

extension FaceShape {
    var label: String {
        switch self {
        case .circle: String(localized: "Circle")
        case .squircle: String(localized: "Rounded square")
        case .pill: String(localized: "Pill")
        case .triangle: String(localized: "Triangle")
        case .hexagon: String(localized: "Hexagon")
        case .cloud: String(localized: "Cloud")
        case .drop: String(localized: "Drop")
        }
    }
}

extension Color {
    /// HSL, as CSS writes it.
    init(hue: Double, saturation: Double, lightness: Double) {
        self.init(FaceColor(hue: hue * 360, saturation: saturation, lightness: lightness))
    }
}

/// What a Bot's face is doing (`docs/bot-faces.md` §3): Hermes's idle, thinking and working, plus
/// listening, happy and sleeping.
typealias BotMood = FaceMood

/// The shared face clock: seconds since launch, the `t` of Hermes's pose functions.
nonisolated enum FaceClock {
    static let origin = Date.now

    static func time(_ date: Date = .now) -> Double {
        date.timeIntervalSince(origin)
    }
}

/// The faces' one clock: a single loop ticks for every face on screen, so they all move in the
/// same instant and the window draws once per tick. A `TimelineView` per face drew the window
/// for each face's own timer, about 100 times a second for a sidebar of Bots, and
/// `.animation(minimumInterval:)` woke it on every display frame however low the interval:
/// either way a Mac with a Bot chat in front kept a core at half load.
@MainActor
@Observable
final class FaceTicker {
    static let shared = FaceTicker()

    /// `FaceClock` time at the latest tick: every 24th of a second while a busy or focused face
    /// is shown (`fast`), every 12th for the rest (`slow`, the same instants, half of them).
    private(set) var fast: Double = 0
    private(set) var slow: Double = 0
    /// How many faces tick at each step (24ths of a second).
    @ObservationIgnored private var demand: [Int: Int] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {}

    /// The time a face ticking every `step` 24ths of a second draws. A clock that stood still
    /// (every face held, the window in the back) gives the time now until it ticks again.
    func time(step: Int) -> Double {
        let ticked = step == 1 ? fast : slow
        let now = FaceClock.time()
        return now - ticked > 0.25 ? now : ticked
    }

    /// Keeps the clock ticking for one face, every `step` 24ths of a second, until the calling
    /// task is cancelled (the face holds still or goes).
    func ticks(step: Int) async {
        demand[step, default: 0] += 1
        start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        demand[step, default: 1] -= 1
        if demand[step] == 0 { demand[step] = nil }
    }

    private func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while true {
                guard let self, let step = self.demand.keys.min() else { break }
                // To the next instant on the shared grid of 24ths of a second.
                let interval = Double(step) / 24
                let now = FaceClock.time()
                let next = ((now / interval).rounded(.down) + 1) * interval
                try? await Task.sleep(for: .seconds(next - now), tolerance: .milliseconds(4))
                guard !self.demand.isEmpty else { break }
                if self.demand[1] != nil { self.fast = next }
                if Int((next * 24).rounded()) % 2 == 0 { self.slow = next }
            }
            self?.loop = nil
        }
    }
}

/// Draws a face at the face clock's time: on every tick while `step` is set (24ths of a second
/// between redraws), once while it holds still. Only this view reads the clock, so a tick redraws
/// the face's canvas and nothing around it.
private struct FaceClockView<Content: View>: View {
    let step: Int?
    @ViewBuilder let content: (_ time: Double, _ ticking: Bool) -> Content

    var body: some View {
        content(step.map { FaceTicker.shared.time(step: $0) } ?? FaceClock.time(), step != nil)
            .task(id: step) {
                guard let step else { return }
                await FaceTicker.shared.ticks(step: step)
            }
    }
}

/// A Bot's face: Hermes Bot Mode's shapes and colours (a flat body, two small eyes with a
/// catchlight, three dots while it thinks or works where it stands alone), fitted so every shape shows whole. The body
/// only leans, breathes and hops as one piece; the life is in the eyes, which glance about and
/// blink on each Bot's own timing (`docs/bot-faces.md`).
///
/// One clock drives every face (`FaceTicker`): 12 fps for a face at rest, 24 for one that's busy,
/// big or in the middle of a boop or a new shape, and nothing while the face is off screen.
/// Reduce Motion keeps the blink and the dots.
struct BotFace: View {
    let appearance: BotAppearance
    var size: CGFloat = 36
    var mood: BotMood = .idle
    /// An approval or question waits on the person: a short wiggle every few seconds.
    var needsYou = false
    /// Look toward something on screen (each axis −1…1), instead of the mood's own gaze.
    var look: CGVector?
    /// The Bot's voice level (0…1) while it talks: the body squashes with it.
    var voiceLevel: Double?
    /// Each change blinks once (a mention pill sent, a pause in typing).
    var blinks = 0
    /// Tapping the face boops it: squash, stretch, happy eyes, sparkles and a light haptic.
    var boopable = false
    /// Each change boops it, as a tap would.
    var boopTrigger = 0
    /// The three dots while it thinks or works. Only where the face stands alone (a group's face
    /// strip, a call): wherever words say what the Bot is doing, the face shows the mood without
    /// them, so only one thing moves (`docs/chat.md` §4a).
    var dots = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var transition = FaceTransition(target: FaceTarget(mood: .idle))
    @State private var happySince: Double?
    @State private var boopSince: Double?
    @State private var boops = 0
    @State private var blinkSince: Double?
    @State private var morph: (from: FaceShape, since: Double)?
    @State private var recolor: (from: FaceColor, since: Double)?
    @State private var isVisible = true
    @State private var wiggles = 0
    /// The mood or the look just changed: the face blends to it, drawn, for 0.4 s.
    @State private var retargetedAt: Double?

    init(
        appearance: BotAppearance, size: CGFloat = 36, isWorking: Bool = false, mood: BotMood? = nil,
        needsYou: Bool = false, look: CGVector? = nil, voiceLevel: Double? = nil, blinks: Int = 0, boopable: Bool = false,
        boopTrigger: Int = 0, dots: Bool = false
    ) {
        self.appearance = appearance
        self.size = size
        self.mood = mood ?? (isWorking ? .thinking : .idle)
        self.needsYou = needsYou
        self.look = look
        self.voiceLevel = voiceLevel
        self.blinks = blinks
        self.boopable = boopable
        self.boopTrigger = boopTrigger
        self.dots = dots
        _transition = State(initialValue: FaceTransition(target: FaceTarget(mood: self.mood, look: look, seed: appearance.seed)))
    }

    /// Faces under 24 pt (mention pills) hold still apart from their one-off blinks.
    private var holdsStill: Bool { size < 24 }
    private var moves: Bool { !reduceMotion && !holdsStill }
    /// A face in focus draws twice as often: Voice mode, the hello screen, the New Bot preview, a
    /// face being tapped or changing shape.
    private func isFocused(at t: Double) -> Bool {
        size >= 88 || voiceLevel != nil || (boopSince.map { t - $0 < 1.2 } ?? false) || (morph.map { t - $0.since < Self.morphDuration } ?? false)
    }

    private var target: FaceTarget {
        FaceTarget(mood: mood, look: reduceMotion ? nil : look, seed: appearance.seed)
    }

    /// A new shape or colour settles in this long.
    private static let morphDuration = 0.42

    var body: some View {
        content
            .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(4, duration: 0.08)
                    CubicKeyframe(-4, duration: 0.12)
                    CubicKeyframe(3, duration: 0.1)
                    CubicKeyframe(0, duration: 0.1)
                }
            }
            .onChange(of: target) { _, new in
                let now = FaceClock.time()
                transition.change(to: new, at: now)
                retargetedAt = now
            }
            .onChange(of: mood) { _, new in
                if new == .happy { happySince = FaceClock.time() }
            }
            .onChange(of: blinks) { blinkSince = FaceClock.time() }
            .onChange(of: boopTrigger) { boop() }
            .onChange(of: appearance) { old, new in
                // Another Bot in this place (a list reordering, the next chat): it just shows. The
                // same Bot's new look (the editor) morphs into place.
                guard old.id == new.id else {
                    morph = nil
                    recolor = nil
                    return
                }
                let now = FaceClock.time()
                if old.shape != new.shape, moves { morph = (old.shape, now) }
                if old.look.color != new.look.color, !reduceMotion { recolor = (old.look.color, now) }
            }
            .task(id: OneOffs(blink: blinkSince, boop: boopSince, happy: happySince, morph: morph?.since, recolor: recolor?.since, retarget: retargetedAt)) {
                // A finished blink, boop, hop, new look or mood change hands the face back to its usual
                // motion (or to rest).
                guard blinkSince != nil || boopSince != nil || happySince != nil || morph != nil || recolor != nil || retargetedAt != nil else { return }
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                let now = FaceClock.time()
                if let since = blinkSince, now - since > 0.3 { blinkSince = nil }
                if let since = boopSince, now - since > 1.3 { boopSince = nil }
                if let since = happySince, now - since > 1.3, mood != .happy { happySince = nil }
                if let since = morph?.since, now - since > Self.morphDuration { morph = nil }
                if let since = recolor?.since, now - since > Self.morphDuration { recolor = nil }
                if let since = retargetedAt, now - since > FaceTransition.duration { retargetedAt = nil }
            }
            .task(id: needsYou && moves) {
                guard needsYou, moves else { return }
                while !Task.isCancelled {
                    wiggles += 1
                    try? await Task.sleep(for: .seconds(6))
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let image = appearance.imageURL {
            photoFace(image)
        } else if boopable {
            drawnFace
                .contentShape(Rectangle())
                .onTapGesture { boop() }
                .sensoryFeedback(.impact(weight: .light), trigger: boops)
        } else {
            drawnFace
        }
    }

    private func boop() {
        let now = FaceClock.time()
        boops += 1
        guard !reduceMotion else {
            happySince = now
            return
        }
        boopSince = now
        happySince = now
    }

    // MARK: The drawn face

    @ViewBuilder
    private var drawnFace: some View {
        let now = FaceClock.time()
        // A face at rest only sways and breathes (seconds-long sines, a degree or two) between
        // blinks: 12 fps draws that smoothly and still gives a blink three frames. Voice mode's
        // squash follows its level, which redraws the face as it changes.
        let step = !PowerState.shared.isLowPower && (isFocused(at: now) || mood != .idle) ? 1 : 2
        // Still faces need the clock only for a one-off: a blink, a boop, a hop or a new look.
        let oneOff = [blinkSince, boopSince, happySince].compactMap { $0 }.contains { now - $0 < 1.3 }
            || (morph.map { now - $0.since < Self.morphDuration } ?? false) || (recolor.map { now - $0.since < Self.morphDuration } ?? false)
        let ticks = mood != .sleeping && (!holdsStill || oneOff)
        let paused = !isVisible || motionPaused || !ticks
        // Nothing but the mood's own motion: Core Animation plays it from a loop, and the app does
        // nothing per frame (`FaceLayers`). One-offs, a voice and held faces are drawn.
        let steady = !Self.drawsOnly && !paused && !oneOff && !holdsStill && voiceLevel == nil && happySince == nil && mood != .happy
            && (retargetedAt.map { now - $0 >= FaceTransition.duration } ?? true)
        if steady, let loop = FaceLoops.shared.loop(for: loopKey, target: transition.target) {
            FaceLayers(look: appearance.look, loop: loop, size: size, outline: outline, frameRate: layerFrameRate(at: now), dots: dots)
                .frame(width: size, height: FacePainter.height(forWidth: size))
        } else {
            FaceClockView(step: paused ? nil : step) { t, ticking in
                // Held, a face shows where it's going rather than where its last change began: a
                // mood that changed while the clock stood still (asleep until Bot Mode connects,
                // then idle) was drawn mid-change, every face with its eyes shut.
                Canvas { canvas, canvasSize in
                    var look = appearance.look
                    look.color = currentColor(at: t)
                    FacePainter.draw(look, frame: frame(at: t, settled: !ticking), in: &canvas, size: canvasSize)
                }
                .overlay {
                    if let boopSince, t - boopSince < 0.7, moves {
                        Sparkles(color: appearance.color, progress: (t - boopSince) / 0.6, size: size)
                    }
                }
            }
            .frame(width: size, height: FacePainter.height(forWidth: size))
        }
    }

    #if DEBUG
    /// `-HERMES_FACE_CANVAS YES`: every face drawn as before, to compare with the layers.
    private static let drawsOnly = UserDefaults.standard.bool(forKey: "HERMES_FACE_CANVAS")
    #else
    private static let drawsOnly = false
    #endif

    private var loopKey: FaceLoops.Key {
        FaceLoops.Key(target: transition.target, shape: appearance.look.shape, size: size, stilled: !moves)
    }

    /// Increase Contrast: an outline when the body is too close to the background.
    private var outline: Color? {
        guard contrast == .increased else { return nil }
        return FacePainter.contrastOutline(
            for: appearance.look.color, on: FacePainter.background(dark: colorScheme == .dark), separator: FacePainter.separator
        )
    }

    /// The render server's pace for a face on layers: slow sines look the same at 24 frames a
    /// second as at 120; the face in focus gets 60, Low Power Mode 12.
    private func layerFrameRate(at now: Double) -> CAFrameRateRange {
        if PowerState.shared.isLowPower { return CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12) }
        if isFocused(at: now) { return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }
        return CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
    }

    /// The colour on screen: the Bot's, or on its way there from the last one.
    private func currentColor(at t: Double) -> FaceColor {
        let color = appearance.look.color
        guard let recolor else { return color }
        let p = max(0, min(1, (t - recolor.since) / Self.morphDuration))
        guard p < 1 else { return color }
        let e = 1 - (1 - p) * (1 - p)
        return FaceColor(
            red: recolor.from.red + (color.red - recolor.from.red) * e,
            green: recolor.from.green + (color.green - recolor.from.green) * e,
            blue: recolor.from.blue + (color.blue - recolor.from.blue) * e
        )
    }

    /// One frame: the blended pose (or, `settled`, the one it's heading for), the eyes for the
    /// mood, and the one-offs on top.
    private func frame(at t: Double, settled: Bool = false) -> FaceFrame {
        var pose = settled ? transition.target.pose(at: t) : transition.pose(at: t)
        // A still frame never lands mid-blink.
        if settled { pose.lid = mood == .sleeping ? 0 : 1 }
        if !moves { pose = pose.stilled }
        if holdsStill {
            // A still frame: eyes open and ahead, dots mid-wave.
            pose = FacePose(lid: pose.lid, dots: FacePose.of(mood, at: 0.6).dots)
        }
        if !dots { pose.dots = (0, 0, 0) }
        if let blinkSince { pose.lid = min(pose.lid, FacePose.lidCurve(t - blinkSince)) }
        let happyNow = mood == .happy || (happySince.map { t - $0 < 1.2 && t >= $0 } ?? false)
        var frame = FaceFrame(mood: happyNow ? .happy : mood, pose: pose)
        if mood == .sleeping { frame.bodyOpacity = 0.45 }
        frame.outline = outline
        guard moves else { return frame }
        // The happy hop: up 6% of the size, then back on a spring (response 0.35, damping 0.6).
        if let happySince { frame.hop = Self.hop(t - happySince) * 44 * 0.06 }
        if let boopSince { frame.squash = Self.boopSquash(t - boopSince) }
        if let voiceLevel {
            let sy = 0.94 + 0.16 * max(0, min(1, voiceLevel))
            frame.squash = CGSize(width: frame.squash.width * (2 - sy), height: frame.squash.height * sy)
        }
        if let morph {
            let p = (t - morph.since) / Self.morphDuration
            if p < 1 { frame.morph = (morph.from, Self.morphCurve(p)) }
        }
        return frame
    }

    /// A morph's progress: quick at first, then settling gently into the new shape.
    static func morphCurve(_ p: Double) -> Double {
        guard p > 0 else { return 0 }
        guard p < 1 else { return 1 }
        let omega = 9.0, damping = 0.62
        return min(1, 1 - exp(-damping * omega * p) * cos(omega * (1 - damping * damping).squareRoot() * p))
    }

    /// 0…1 of the hop's height: up in 0.12 s, then a spring back (response 0.35, damping 0.6).
    static func hop(_ elapsed: Double) -> Double {
        guard elapsed >= 0 else { return 0 }
        let rise = 0.12
        if elapsed < rise { return 1 - pow(1 - elapsed / rise, 2) }
        let omega = 2 * Double.pi / 0.35, damping = 0.6
        let tau = elapsed - rise
        guard tau < 1.2 else { return 0 }
        return exp(-damping * omega * tau) * cos(omega * (1 - damping * damping).squareRoot() * tau)
    }

    /// Boop: squash (1.12 × 0.86), stretch (0.92 × 1.1), settle.
    static func boopSquash(_ elapsed: Double) -> CGSize {
        func ease(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) }
        func lerp(_ a: CGSize, _ b: CGSize, _ p: Double) -> CGSize {
            CGSize(width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
        }
        let rest = CGSize(width: 1, height: 1), squash = CGSize(width: 1.12, height: 0.86), stretch = CGSize(width: 0.92, height: 1.1)
        switch elapsed {
        case ..<0: return rest
        case ..<0.09: return lerp(rest, squash, ease(elapsed / 0.09))
        case ..<0.22: return lerp(squash, stretch, ease((elapsed - 0.09) / 0.13))
        case ..<0.6:
            // Settle with a small overshoot.
            let p = (elapsed - 0.22) / 0.38
            let wobble = exp(-5 * p) * cos(p * .pi * 2.5)
            return lerp(rest, stretch, wobble)
        default: return rest
        }
    }

    // MARK: Photo faces

    /// A picture avatar: a rounded square with a 22% radius. Its only motion is a slow breath.
    @ViewBuilder
    private func photoFace(_ source: String) -> some View {
        if !Self.drawsOnly, isVisible, !motionPaused, moves, let image = FaceImageCache.image(for: source) {
            // Breathing on layers: nothing per frame here (`PhotoFaceLayers`).
            PhotoFaceLayers(image: image, size: size, frameRate: layerFrameRate(at: FaceClock.time()))
                .frame(width: size, height: FacePainter.height(forWidth: size), alignment: .top)
        } else {
            drawnPhotoFace(source)
        }
    }

    private func drawnPhotoFace(_ source: String) -> some View {
        FaceClockView(step: !isVisible || motionPaused || !moves ? nil : 2) { t, _ in
            let breath = moves ? 1 + 0.01 * (1 - cos(t * .pi / 2)) : 1
            photo(source)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .scaleEffect(breath, anchor: .bottom)
        }
        // Same footprint as a drawn face (40 × 44), so rows and cards line up.
        .frame(width: size, height: FacePainter.height(forWidth: size), alignment: .top)
    }

    @ViewBuilder
    private func photo(_ source: String) -> some View {
        if source.hasPrefix("data:") || source.hasPrefix("face://"), let image = FaceImageCache.image(for: source) {
            Image(platformImage: image).resizable().scaledToFill()
        } else if let url = URL(string: source), WebLink.loadsByItself(url) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                appearance.color.opacity(0.4)
            }
        }
    }
}

private struct OneOffs: Equatable {
    var blink: Double?
    var boop: Double?
    var happy: Double?
    var morph: Double?
    var recolor: Double?
    var retarget: Double?
}

/// The boop's sparkles: 3–4 SF Symbol sparkles in the Bot's colour that pop and fade (0.6 s).
private struct Sparkles: View {
    let color: Color
    /// 0…1.
    let progress: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            // A nonisolated row builder (see `SparkleBurst`): the Bot hello sits in a
            // `ViewThatFits`, which may build these rows on SwiftUI's render thread.
            ForEach(0..<(size >= 40 ? 4 : 3), id: \.self, content: sparkle)
        }
        .allowsHitTesting(false)
    }

    private nonisolated func sparkle(_ index: Int) -> SparkleSpot {
        SparkleSpot(index: index, color: color, progress: progress, size: size)
    }
}

private nonisolated struct SparkleSpot: View {
    let index: Int
    let color: Color
    let progress: Double
    let size: CGFloat

    private static let spots: [(x: CGFloat, y: CGFloat, scale: CGFloat, delay: Double)] = [
        (-0.62, -0.42, 1, 0), (0.6, -0.52, 0.8, 0.06), (0.7, 0.22, 0.65, 0.12), (-0.5, 0.42, 0.7, 0.09),
    ]

    var body: some View {
        let spot = Self.spots[index]
        let p = max(0, min(1, (progress - spot.delay) / (1 - spot.delay)))
        Image(systemName: "sparkle")
            .font(.system(size: max(7, size * 0.2) * spot.scale, weight: .semibold))
            .foregroundStyle(color)
            .scaleEffect(p < 0.35 ? 0.4 + p / 0.35 * 0.8 : 1.2 - (p - 0.35) * 0.6)
            .opacity(p <= 0 ? 0 : (p < 0.6 ? 1 : 1 - (p - 0.6) / 0.4))
            .offset(x: spot.x * size * (0.9 + p * 0.25), y: spot.y * size * (0.9 + p * 0.25))
    }
}

/// Decoded, downsampled photo avatars, keyed by `face://<name>#<revision>`, so faces
/// never decode base64 on the main thread or hash a whole data URL per redraw. Inline images in
/// chats land here too, so it's bounded by decoded size and empties under memory pressure.
@MainActor
enum FaceImageCache {
    private static let images: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private static func cached(_ key: String) -> PlatformImage? {
        images.object(forKey: key as NSString)
    }

    /// Cost is the decoded bitmap: width × height × 4 bytes.
    private static func store(_ image: PlatformImage, key: String, pixels: CGSize) {
        images.setObject(image, forKey: key as NSString, cost: max(1, Int(pixels.width * pixels.height * 4)))
    }

    static func image(for key: String) -> PlatformImage? {
        if let cached = cached(key) { return cached }
        // A raw data URL (previews, tests): decode once, synchronously.
        guard key.hasPrefix("data:"), let comma = key.firstIndex(of: ","),
              let data = Data(base64Encoded: String(key[key.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let image = PlatformImage(data: data)
        else { return nil }
        #if os(macOS)
        let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        #else
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        #endif
        store(image, key: key, pixels: pixels)
        return image
    }

    /// Decodes and downsamples off the main thread, then caches under `key`.
    static func prepare(dataURL: String, key: String, maxPixelSize: Int = 288) async -> PlatformImage? {
        if let cached = cached(key) { return cached }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        store(image, key: key, pixels: CGSize(width: cgImage.width, height: cgImage.height))
        return image
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 16) {
            ForEach(FaceShape.allCases, id: \.self) { shape in
                BotFace(appearance: BotAppearance(profile: "researcher-\(shape.rawValue)", shape: shape.rawValue), size: 56, isWorking: shape == .cloud)
            }
        }
        HStack(spacing: 16) {
            ForEach(FaceMood.allCases, id: \.self) { mood in
                BotFace(appearance: BotAppearance(profile: "default"), size: 56, mood: mood, boopable: true)
            }
        }
    }
    .padding()
}
