#if DEBUG
import HermesKit
import HermesPush
import SwiftUI

/// Debug-only pages that show components in isolation, for checking them against the Elyx
/// renders: `-HERMES_GALLERY faces` (and `-HERMES_GALLERY_DARK YES` is just the system setting).
struct DesignGallery: View {
    let page: String

    var body: some View {
        ScrollView {
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case "faces": FacesPage()
        case let page where page.hasPrefix("voice"): VoicePage(start: Int(page.dropFirst(6)) ?? 0)
        default: Text("Unknown gallery page \(page)")
        }
    }
}

/// The Voice mode states from `screens/iphone/voice.elyx`, at iPhone size.
private struct VoicePage: View {
    private let states: [VoiceScreen.State] = [
        .init(phase: .listening, title: "Voice", status: "Listening…",
              caption: "How full is the NAS, and can you clean up old snapshots?",
              hint: "Pause to send · swipe down to keep it running", level: 0.4),
        .init(phase: .thinking, title: "Voice", status: "Working · checking the NAS",
              caption: "Running df on /volume1…", captionIsSecondary: true, hint: "You can keep talking"),
        .init(phase: .speaking, title: "Voice", status: "Hermes is speaking",
              caption: "The NAS is at 61 percent. Snapshots take 212 gigabytes. Want me to remove the ones older than 30 days?",
              hint: "Tap anywhere to interrupt"),
        .init(phase: .listening, title: "Research Buddy", status: "Research Buddy is listening…",
              caption: "Anything new on speculative decoding this week?", hint: "Pause to send", speakerName: "Research Buddy",
              botAppearance: BotAppearance(profile: "researcher", shape: "hexagon", color: "hsl(150 68% 58%)", customized: true)),
        .init(phase: .approval, title: "Voice", status: "Waiting for your approval",
              caption: "Say “allow once”, “allow in this chat” or “deny”, or tap below.",
              approval: ApprovalRequest(requestID: "r1", command: "rm -rf ./build && make release", description: "Recursive delete", choices: [.once, .session, .always, .deny])),
        .init(phase: .noMicrophone, title: "Voice", status: "Microphone is off",
              caption: "Hermes needs the microphone and speech recognition to hear you. Speech is turned into text on this device."),
        .init(phase: .offline, title: "Voice", status: "Can't reach Studio Mac",
              caption: "Voice needs a connection to your gateway. What you said is kept as a draft.", captionIsSecondary: true),
    ]

    /// `-HERMES_GALLERY voice:3` starts at the fourth state; three fit a default window.
    var start = 0

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(states.dropFirst(start).prefix(3).enumerated()), id: \.offset) { _, state in
                VoiceScreen(state: state, actions: .init())
                    .frame(width: 402, height: 820)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(Theme.hairline))
                    .scaleEffect(0.86, anchor: .topLeading)
                    .frame(width: 402 * 0.86, height: 820 * 0.86, alignment: .topLeading)
            }
        }
    }
}

/// The one-off motions, on a loop: a boop every 2.5 s, a shape morph every 1.5 s, a look around
/// every second, and a blink each time a pill would be sent.
private struct MotionChecks: View {
    @State private var boops = 0
    @State private var shape = FaceShape.squircle
    @State private var look = 0
    @State private var blinks = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            BotFace(appearance: BotAppearance(profile: "sun", shape: "circle", color: "hsl(60 68% 58%)", customized: true), size: 88, boopable: true, boopTrigger: boops)
            BotFace(appearance: BotAppearance(profile: "writer", shape: shape.rawValue, color: "hsl(330 68% 58%)", customized: true), size: 88)
            BotFace(appearance: BotAppearance(profile: "researcher", shape: "hexagon", color: "hsl(150 68% 58%)", customized: true), size: 56,
                    look: [nil, CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1)][look % 5])
            BotFace(appearance: BotAppearance(profile: "writer", shape: "cloud", color: "hsl(330 68% 58%)", customized: true), size: 18, blinks: blinks)
        }
        .padding(.vertical, 16)
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                tick += 1
                if tick % 5 == 0 { boops += 1 }
                if tick % 3 == 0 { shape = FaceShape.allCases[(FaceShape.allCases.firstIndex(of: shape)! + 1) % FaceShape.allCases.count] }
                if tick % 2 == 0 { look += 1 }
                if tick % 4 == 0 { blinks += 1 }
            }
        }
    }
}

/// `controls/bot-face.elyx` and `flows/bot-faces.elyx`: the seven shapes × thirteen colours at
/// 56 pt (still, Hermes's first paint), then every mood moving, and the sizes.
private struct FacesPage: View {
    /// The board's rows and columns: default violet, then the twelve swatches.
    private static let shapes: [FaceShape] = [.squircle, .circle, .pill, .hexagon, .triangle, .cloud, .drop]
    private static let colors: [FaceColor] = [.defaultViolet] + FaceColor.swatches

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Self.shapes, id: \.self) { shape in
                    GridRow {
                        ForEach(Array(Self.colors.enumerated()), id: \.offset) { _, color in
                            StillFace(look: FaceLook(shape: shape, color: color), size: 56)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 22) {
                ForEach(FaceMood.allCases, id: \.self) { mood in
                    VStack(spacing: 6) {
                        BotFace(appearance: BotAppearance(profile: "default"), size: 56, mood: mood, boopable: true)
                        Text(mood.rawValue).font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            MotionChecks()
            HStack(alignment: .bottom, spacing: 18) {
                ForEach([160, 120, 88, 56, 36, 32, 28, 24, 20, 18] as [CGFloat], id: \.self) { size in
                    BotFace(appearance: BotAppearance(profile: "writer", shape: "cloud", color: "hsl(330 68% 58%)", customized: true), size: size, mood: size == 56 ? .working : .idle)
                }
            }
        }
    }
}
#endif
