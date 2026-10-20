import HermesKit
import SwiftUI

/// Talk minimised (`callPill`): a glass pill at the top of the chat while you read or type. The
/// ring is the Bot's colour; tap to open the call again; Mute; End.
struct CallPill: View {
    let session: any TalkDisplay

    var body: some View {
        HStack(spacing: 10) {
            Button {
                TalkCenter.shared.isExpanded = true
            } label: {
                HStack(spacing: 10) {
                    BotFace(appearance: session.figureAppearance, size: 24, mood: session.phase == .working ? .working : .listening, dots: true)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(session.figureAppearance.color.opacity(0.5), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Talking with \(session.speakerName)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        HStack(spacing: 0) {
                            if let started = session.startedAt {
                                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                                    .monospacedDigit()
                            }
                            if session.isMuted { Text(" · Muted") }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PillWave(level: session.phase == .speaking ? session.outputLevel : session.inputLevel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Talking with \(session.speakerName), \(session.status)")
            .accessibilityHint("Opens the call")
            Button(action: session.toggleMute) {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(session.isMuted ? Theme.inkForeground : Theme.primaryText)
                    .frame(width: 34, height: 34)
                    .background(session.isMuted ? Theme.ink : Theme.controlFill, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(session.isMuted ? "Unmute" : "Mute")
            Button(action: TalkCenter.shared.end) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.danger, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("End call")
        }
        .padding(.leading, 10)
        .padding(.trailing, 11)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Seven bars that follow the call's sound, newest level in the middle.
private struct PillWave: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape: [CGFloat] = [0.35, 0.85, 0.75, 0.3, 0.5, 0.85, 0.35]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.shape.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Theme.primaryText)
                    .frame(width: 3, height: max(4, 18 * height * (reduceMotion ? 0.7 : CGFloat(0.4 + 0.6 * level))))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// After a call (`callSummary`): the spoken turns fold into one card. What was done, how long,
/// turns, approvals and steps, Transcript (opens the turns in place) and Talk Again.
struct CallSummaryCard: View {
    let record: CallRecord
    @Binding var showsTurns: Bool
    let onTalkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 32, height: 32)
                    .background(Theme.ink, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Talk with \(record.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Theme.snappy) { showsTurns.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(showsTurns ? 180 : 0))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsTurns ? "Hide the turns" : "Show the turns")
            }
            if let summary = record.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if record.summaryByDevice {
                        Text("Summary by Apple Intelligence")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
            HStack(spacing: 6) {
                Chip(text: record.turns == 1 ? String(localized: "1 turn") : String(localized: "\(record.turns) turns"))
                if record.approvals > 0 {
                    Chip(text: record.approvals == 1 ? String(localized: "1 approval") : String(localized: "\(record.approvals) approvals"))
                }
                if record.steps > 0 {
                    Chip(text: record.steps == 1 ? String(localized: "1 step") : String(localized: "\(record.steps) steps"))
                }
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(Theme.snappy) { showsTurns.toggle() }
                } label: {
                    Text("Transcript")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.controlFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                Button(action: onTalkAgain) {
                    Label("Talk Again", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .inkFilledButton()
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// "6 min 12 s · 09:41–09:47".
    private var meta: String {
        let length = Duration.seconds(record.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        let start = record.startedAt.formatted(date: .omitted, time: .shortened)
        let end = record.endedAt.formatted(date: .omitted, time: .shortened)
        return "\(length) · \(start)–\(end)"
    }

    private struct Chip: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.controlFill, in: Capsule())
        }
    }
}

/// Where the call shows (`docs/voice.md` §4.5): full screen on iPhone and iPad portrait, a floating
/// panel on iPad landscape. On the Mac the call has its own window (`TalkWindow`).
struct TalkPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isLandscape = false
    private var center: TalkCenter { .shared }

    func body(content: Content) -> some View {
        #if os(iOS)
        let usesPanel = sizeClass == .regular && isLandscape
        content
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
            .overlay(alignment: .topTrailing) {
                if usesPanel, let session = center.session, center.isExpanded {
                    TalkPanel(session: session)
                        .padding(.top, 88)
                        .padding(.trailing, 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !usesPanel && center.session != nil && center.isExpanded },
                set: { if !$0 { center.isExpanded = false } }
            )) {
                if let session = center.session {
                    TalkScreen(session: session)
                }
            }
            .animation(.snappy(duration: 0.22), value: center.session == nil || !center.isExpanded)
        #else
        content
            .modifier(TalkWindowOpener())
        #endif
    }
}

#if os(macOS)
/// The Mac's call window (`macTalk`): small, floating over every app, opened and closed with
/// the call. Space mutes while it's focused; ⌥⌘V starts and ends.
struct TalkWindowContent: View {
    private var center: TalkCenter { .shared }

    var body: some View {
        Group {
            if let session = center.session {
                TalkPanel(session: session)
                    .padding(8)
            } else {
                Text("No call")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 240, height: 120)
            }
        }
        .fixedSize()
    }
}

/// Opens the call window when a call starts and closes it when the call ends.
private struct TalkWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: TalkCenter.shared.session?.id) { _, id in
            if id != nil { openWindow(id: TalkCenter.windowID) } else { dismissWindow(id: TalkCenter.windowID) }
        }
    }
}

/// The call in the menu bar while it lasts: who, the state, Mute, Show and End. (ActivityKit
/// doesn't run in Mac apps, so this is the Mac's Live Activity.)
struct TalkMenuBar: View {
    @Environment(\.openWindow) private var openWindow
    private var center: TalkCenter { .shared }

    var body: some View {
        if let session = center.session {
            Text("\(session.speakerName) · \(session.status)")
            Button(session.isMuted ? "Unmute" : "Mute", action: session.toggleMute)
            Button("Show Call") { openWindow(id: TalkCenter.windowID) }
            Divider()
            Button("End Call", action: center.end)
        }
    }
}
#endif

/// Calls started from outside the chat (Shortcuts, the control, the Action button): the Bot's
/// chat opens (Hermes gets a new chat) and the call starts there. Also keeps the Bots Shortcuts
/// can name up to date.
struct TalkEntry: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            // From a cold launch the Bots arrive a moment later: the call waits for them.
            .onChange(of: isReady, initial: true) { _, ready in if ready { startIfReady() } }
            #if DEBUG
            // `-HERMES_TALK_TO <profile>|hermes` calls as a Shortcut would (screenshots, UI tests).
            .task {
                guard let name = UserDefaults.standard.string(forKey: "HERMES_TALK_TO") else { return }
                TalkCenter.logger.info("debug: calling \(name, privacy: .public) as a Shortcut would")
                TalkCenter.shared.pendingStart = .init(botName: name == "hermes" ? nil : name)
            }
            #endif
            .onChange(of: app.currentWorkspace?.roster?.visibleBots.map(\.name), initial: true) {
                guard let roster = app.currentWorkspace?.roster else { return }
                TalkDirectory.save(roster.visibleBots.map { ($0.name, $0.displayName) })
                HermesShortcuts.updateAppShortcutParameters()
            }
    }

    /// A call is waiting and what it needs is there: the gateway, and for a Bot, its roster.
    private var isReady: Bool {
        guard let start = TalkCenter.shared.pendingStart, let workspace = app.currentWorkspace else { return false }
        // With Bot Mode, its connection first: that's where the Bot's voice comes from.
        if let roster = workspace.roster, !roster.isConnected { return false }
        guard let name = start.botName else { return true }
        return workspace.roster?.bot(named: name) != nil
    }

    private func startIfReady() {
        guard let start = TalkCenter.shared.pendingStart, let workspace = app.currentWorkspace else { return }
        let conversation: ConversationModel
        if let name = start.botName {
            guard let roster = workspace.roster, roster.isConnected, roster.bot(named: name) != nil else { return }
            workspace.selection = .bot(name)
            conversation = roster.conversation(for: name)
        } else {
            workspace.startNewChat()
            conversation = workspace.currentConversation
        }
        TalkCenter.shared.pendingStart = nil
        TalkCenter.logger.info("call requested from outside the chat")
        TalkCenter.shared.start(conversation: conversation, workspace: workspace)
    }
}

/// "Spoken" under a message said in a call (`talkMinimised`).
struct SpokenMark: ViewModifier {
    let isSpoken: Bool

    func body(content: Content) -> some View {
        if isSpoken {
            VStack(alignment: .trailing, spacing: 6) {
                content
                Label("Spoken", systemImage: "waveform")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Spoken")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            content
        }
    }
}
