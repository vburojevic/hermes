#if DEBUG
import HermesKit
import HermesPush
import SwiftUI

/// Debug-only pages that show components in isolation, for checking them against the Elyx
/// renders: `-HERMES_GALLERY faces` (and `-HERMES_GALLERY_DARK YES` is just the system setting).
struct DesignGallery: View {
    let page: String

    var body: some View {
        if page.hasPrefix("widgets") {
            // Its own scroll view and the chat's 20 pt margins, so cards are as wide as in a reply.
            WidgetGallery(page: page)
        } else {
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case "faces": FacesPage()
        case let page where page.hasPrefix("talk"): TalkPage(start: Int(page.dropFirst(5)) ?? 0)
        case "voice": VoiceMessagesPage()
        case "indicators": IndicatorsPage()
        case let page where page.hasPrefix("priority"): PriorityPage(page: page)
        default: Text("Unknown gallery page \(page)")
        }
    }
}

/// The Talk states from `screens/iphone/talk.elyx`, at iPhone size, then the panel, the pill
/// and the summary card (`-HERMES_GALLERY talk:4` starts at the fifth).
private struct TalkPage: View {
    @State private var stages = TalkStage.all
    @State private var showsTurns = false
    var start = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(stages.dropFirst(start).prefix(3).enumerated()), id: \.offset) { _, stage in
                    TalkScreen(session: stage)
                        .frame(width: 402, height: 820)
                        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(Theme.hairline))
                        .scaleEffect(0.86, anchor: .topLeading)
                        .frame(width: 402 * 0.86, height: 820 * 0.86, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 20) {
                    TalkPanel(session: stages[0])
                    CallPill(session: stages[0])
                        .frame(width: 382)
                    CallSummaryCard(
                        record: CallRecord(id: UUID(), session: nil, botName: nil, title: "Hermes", startedAt: .now.addingTimeInterval(-372), endedAt: .now,
                                           turns: 9, approvals: 1, steps: 2,
                                           summary: "Checked the NAS (61% full) and removed 14 snapshots older than 30 days after your OK. 148 GB free now; a weekly cleanup runs on Sundays."),
                        showsTurns: $showsTurns, onTalkAgain: {}
                    )
                    .frame(width: 362)
                }
            }
            .padding(20)
        }
    }
}

/// `blocks/audio.elyx`: the recorder holding (with the red microphone and the lock), locked and
/// in Review; a voice message and a Bot's listen strip. The clip is the first of
/// `-HERMES_VOICE_INPUT`, when set.
private struct VoiceMessagesPage: View {
    @State private var holding = VoiceRecorder()
    @State private var locked = VoiceRecorder()
    @State private var review = VoiceRecorder()
    @State private var hold = HoldGesture()

    private static let words = "Check the disk space on the NAS, and if it’s over 80%, clean up snapshots older than a month."
    private static let levels: [Float] = (0..<240).map { index in
        let syllable = sin(Float(index) * 0.9) * 0.5 + 0.5
        return index % 37 > 30 ? 0.02 : 0.15 + 0.7 * syllable * (index % 11 > 2 ? 1 : 0.3)
    }

    private var clip: String? {
        UserDefaults.standard.string(forKey: "HERMES_VOICE_INPUT")?
            .split(separator: ",").first?.split(separator: "@").first
            .map { URL(fileURLWithPath: String($0)).absoluteString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                RecorderWords(settled: "Check the disk space on the NAS, and", volatile: "if it’s over")
                    .lineLimit(2)
                    .padding(EdgeInsets(top: 14, leading: 26, bottom: 6, trailing: 26))
                HStack(spacing: 6) {
                    RecorderHoldBar(recorder: holding, hold: hold)
                    MicButton(recorder: holding, hold: hold, cancelDistance: 190, onDictate: {}, onRecord: {}, onSend: {}, onCancel: {}, onLock: {})
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
            .frame(width: 382)
            .padding(.top, 150)
            RecorderLockedPanel(recorder: locked, onDelete: {}, onPause: {}, onSend: {})
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
                .frame(width: 382)
            RecorderReviewPanel(recorder: review, onDelete: {}, onResume: {}, onSend: {})
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
                .frame(width: 382)
            if let clip {
                UserBubble(entry: {
                    var entry = UserEntry(id: "gallery-voice", text: Self.words)
                    entry.voicePath = clip
                    return entry
                }(), images: [])
                .frame(width: 362)
                ListenStrip(audio: AgentAudio(path: clip, isVoice: true))
                    .frame(width: 362)
            }
        }
        .task {
            hold.isHolding = true
            holding.stage(.holding, settled: "Check the disk space on the NAS, and", volatile: "if it’s over", duration: 7, levels: Self.levels)
            locked.stage(.locked, settled: Self.words, volatile: "Keep the weekly ones.", duration: 23, levels: Self.levels)
            review.stage(.review, settled: Self.words + " Keep the weekly ones.", duration: 23, levels: Self.levels)
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
