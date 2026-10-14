#if DEBUG
import HermesKit
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

private struct FacesPage: View {
    private let profiles: [(String, String?, String?)] = [
        ("default", nil, nil),
        ("researcher", "hexagon", "hsl(150 68% 58%)"),
        ("writer", "cloud", "hsl(330 68% 58%)"),
        ("scout", "triangle", "hsl(30 68% 58%)"),
        ("pill", "pill", "hsl(210 68% 58%)"),
        ("sun", "circle", "hsl(60 68% 58%)"),
        ("drop", "drop", "hsl(240 68% 58%)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach([96, 40, 28] as [CGFloat], id: \.self) { size in
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(profiles, id: \.0) { profile in
                        BotFace(appearance: BotAppearance(profile: profile.0, shape: profile.1, color: profile.2, customized: profile.1 != nil), size: size)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 18) {
                BotFace(appearance: BotAppearance(profile: "default"), size: 56, mood: .thinking)
                BotFace(appearance: BotAppearance(profile: "default"), size: 56, mood: .happy)
                BotFace(appearance: BotAppearance(profile: "default"), size: 56, mood: .listening)
                BotFace(appearance: BotAppearance(profile: "writer", shape: "cloud", color: "hsl(330 68% 58%)", customized: true), size: 56, mood: .thinking)
            }
        }
    }
}
#endif
