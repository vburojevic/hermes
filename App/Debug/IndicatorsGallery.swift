#if DEBUG
import HermesKit
import SwiftUI

/// Every live and loading indicator in one place (`docs/chat.md` §4a), for the snapshot tests
/// (`IndicatorsUITests`) and checks against `blocks/transcript.elyx` and `blocks/inbox.elyx`:
/// `-HERMES_GALLERY indicators`, with `-HERMES_GALLERY_LOOK light|dark|light+contrast|dark+contrast`
/// and `+reducemotion` for Reduce Motion.
struct IndicatorsPage: View {
    private static let reduceMotion = UserDefaults.standard.string(forKey: "HERMES_GALLERY_LOOK")?.contains("reducemotion") == true

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("Turn header") {
                WorkSummaryView(turn: Self.turn(started: 2), isExpanded: false)
                WorkSummaryView(turn: Self.turn(started: 12), isExpanded: false)
                WorkSummaryView(turn: Self.turn(started: 5, steps: [Self.search(running: true)]), isExpanded: true)
                WorkSummaryView(turn: Self.turn(started: 9, steps: [Self.search(running: false), Self.search(running: false), Self.search(running: false)], answer: "Speculative decoding"), isExpanded: false)
                WorkSummaryView(turn: Self.turn(started: 22, steps: [Self.search(running: false), Self.search(running: false), Self.search(running: false)], answer: "Done", state: .complete), isExpanded: false)
                WorkSummaryView(turn: Self.turn(started: 4, steps: [Self.search(running: false)], state: .waitingForApproval), isExpanded: false)
                WorkSummaryView(turn: Self.turn(started: 1), status: String(localized: "Waiting for MacBook Pro…"), statusWaits: true, isExpanded: false)
            }
            section("Activity line") {
                ActivityLineView(line: .thinking)
                ActivityLineView(line: .writing("The socket reconnects with…"))
                ActivityLineView(line: .tool(symbol: "terminal", title: "Running swift test", progress: .init(done: 212, total: 240)))
                ActivityLineView(line: .helpers(3))
                ActivityLineView(line: .waiting(.approval))
                ActivityLineView(line: .failed("No API key"))
                HStack(spacing: 8) {
                    LiveDot()
                    Text("Fix the reconnect after sleep").font(.headline)
                }
            }
            section("Group chat") {
                BotThinkingLine(appearance: BotAppearance(profile: "researcher"), name: "Research Buddy")
                BotThinkingLine(appearance: BotAppearance(profile: "writer"), name: "Ada")
                Text("+1 more").font(.footnote).foregroundStyle(Theme.tertiaryText).padding(.leading, 26)
            }
            section("Jump pill") {
                JumpPillView(pill: .live, activity: nil) {}
            }
            section("Background and steers") {
                BackgroundStartedLine(prompt: "Check the release notes for typos")
                FollowUpBubble(text: "Use the staging database", caption: FollowUpBubbleCaption(symbol: FollowUpMode.steer.symbol, text: String(localized: "Steer · Hermes reads it after this step")), isPending: true)
            }
            section("The app's own waiting") {
                HStack(spacing: 10) {
                    Spinner()
                    Text("Connecting…").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                SkeletonRows()
            }
        }
        .accessibilityIdentifier("gallery.indicators")
        // The public key is read-only; the underscored one is what previews set.
        .environment(\._accessibilityReduceMotion, Self.reduceMotion)
        .motionProbe()
        .onAppear { WidgetGalleryLook.apply() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.tertiaryText).textCase(.uppercase)
            content()
        }
    }

    private static func turn(started seconds: TimeInterval, steps: [AssistantStep] = [], answer: String = "", state: AssistantTurn.State = .streaming) -> AssistantTurn {
        let start = Date.now.addingTimeInterval(-seconds)
        return AssistantTurn(id: UUID().uuidString, steps: steps, answer: answer, state: state, startedAt: start,
                             finishedAt: state == .complete ? .now : nil)
    }

    private static func search(running: Bool) -> AssistantStep {
        .tool(ToolActivity(id: UUID().uuidString, name: "web_search", preview: "mlx release notes October 2026",
                           status: running ? .running : .succeeded, startedAt: .now.addingTimeInterval(-3), duration: running ? nil : 2))
    }
}
#endif
