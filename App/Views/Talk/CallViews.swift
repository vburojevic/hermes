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
    /// A call, or one waiting to start.
    private var hasCall: Bool { center.session != nil || center.pendingCall != nil }

    func body(content: Content) -> some View {
        #if os(iOS)
        let usesPanel = sizeClass == .regular && isLandscape
        content
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
            .overlay(alignment: .topTrailing) {
                if usesPanel, center.isExpanded {
                    Group {
                        if let session = center.session {
                            TalkPanel(session: session)
                        } else if let call = center.pendingCall {
                            // A call from outside the app that waits to start (`talkWaiting`).
                            PendingCallPanel(call: call)
                        }
                    }
                    .padding(.top, 88)
                    .padding(.trailing, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !usesPanel && hasCall && center.isExpanded },
                set: { if !$0 { center.isExpanded = false } }
            )) {
                if let session = center.session {
                    TalkScreen(session: session)
                } else if let call = center.pendingCall {
                    PendingCallScreen(call: call)
                }
            }
            .animation(.snappy(duration: 0.22), value: !hasCall || !center.isExpanded)
            .modifier(PendingCallAnnouncer())
        #else
        content
            .modifier(TalkWindowOpener())
            .modifier(PendingCallAnnouncer())
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
            } else if let call = center.pendingCall {
                PendingCallPanel(call: call)
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

/// Opens the call window when a call starts, or one from outside the app waits to, and closes
/// it when the call ends or the waiting one is cancelled.
private struct TalkWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var shown: Bool { TalkCenter.shared.session != nil || TalkCenter.shared.pendingCall != nil }

    func body(content: Content) -> some View {
        content.onChange(of: shown) { _, shown in
            if shown { openWindow(id: TalkCenter.windowID) } else { dismissWindow(id: TalkCenter.windowID) }
        }
    }
}

/// The call in the menu bar while it lasts: who, the state, Mute, Show and End. (ActivityKit
/// doesn't run in Mac apps, so this is the Mac's Live Activity.)
struct TalkMenuBar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var app
    private var center: TalkCenter { .shared }

    var body: some View {
        if let session = center.session {
            Text("\(session.speakerName) · \(session.status)")
            Button(session.isMuted ? "Unmute" : "Mute", action: session.toggleMute)
            Button("Show Call") { openWindow(id: TalkCenter.windowID) }
            Divider()
            Button("End Call", action: center.end)
        } else if let call = center.pendingCall {
            let copy = PendingCallCopy(call, workspace: app.currentWorkspace)
            Text("\(copy.name) · \(copy.title)")
            Button("Show Call") { openWindow(id: TalkCenter.windowID) }
            Divider()
            Button("Cancel Call", action: center.cancelPending)
        }
    }
}
#endif

/// Calls started from outside the chat (Shortcuts, the control, the Action button, Hey Hermes):
/// the Bot's chat opens (Hermes gets a new chat) and the call starts there. Until it can,
/// `TalkCenter` holds it as a pending call with what the app knows here (`docs/voice.md` §4.4).
/// Also keeps the Bots Shortcuts can name up to date.
struct TalkEntry: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The model, not this view: the center calls these after the view has gone by.
                let app = app
                TalkCenter.shared.startCall = { callee in Self.start(callee, app: app) }
                TalkCenter.shared.readFacts = { callee in Self.facts(for: callee, app: app) }
                // Quietly: offline Bots stay offline rather than reading "Connecting…" every try.
                TalkCenter.shared.connectBotMode = { app.currentWorkspace?.roster?.connectIfNeeded(quietly: true) }
                TalkCenter.shared.factsChanged()
            }
            // From a cold launch the gateway and its Bots arrive a moment later: the call waits.
            .onChange(of: Self.facts(for: TalkCenter.shared.pendingCall?.callee ?? .hermes, app: app)) {
                TalkCenter.shared.factsChanged()
            }
            // A wait stands still behind other apps: back in front, it starts or times out now.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { TalkCenter.shared.factsChanged() }
            }
            #if DEBUG
            // `-HERMES_TALK_TO <profile>|hermes` calls as a Shortcut would (screenshots, UI tests).
            .task {
                guard let name = UserDefaults.standard.string(forKey: "HERMES_TALK_TO") else { return }
                TalkCenter.logger.info("debug: calling \(name, privacy: .public) as a Shortcut would")
                TalkCenter.shared.request(botName: name == "hermes" ? nil : name)
            }
            #endif
            .onChange(of: app.currentWorkspace?.roster?.visibleBots.map(\.name), initial: true) {
                guard let roster = app.currentWorkspace?.roster else { return }
                TalkDirectory.save(roster.visibleBots.map { ($0.name, $0.displayName) })
                HermesShortcuts.updateAppShortcutParameters()
            }
    }

    /// Where a call would go: the gateway, its Bot Mode connection (where a Bot's voice comes
    /// from), and for a Bot, whether its roster has it.
    private static func facts(for callee: PendingCall.Callee, app: AppModel) -> PendingCall.Facts {
        guard let workspace = app.currentWorkspace else { return PendingCall.Facts(hasGateway: false, botMode: .notSetUp) }
        guard let roster = workspace.roster else { return PendingCall.Facts(hasGateway: true, botMode: .notSetUp) }
        guard roster.isConnected else { return PendingCall.Facts(hasGateway: true, botMode: .connecting) }
        var hasBot: Bool?
        if let name = callee.botName {
            hasBot = roster.bot(named: name) != nil ? true : (roster.hasLoaded ? false : nil)
        }
        return PendingCall.Facts(hasGateway: true, botMode: .connected, hasBot: hasBot)
    }

    private static func start(_ callee: PendingCall.Callee, app: AppModel) {
        guard let workspace = app.currentWorkspace else { return }
        let conversation: ConversationModel
        if let name = callee.botName {
            guard let roster = workspace.roster else { return }
            workspace.selection = .bot(name)
            conversation = roster.conversation(for: name)
        } else {
            workspace.startNewChat()
            conversation = workspace.currentConversation
        }
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

// MARK: A call waiting to start

/// What a call from outside the app says while it can't start yet (`talkWaiting`,
/// `talkWaitTimedOut`, `talkNoBot`, `talkNotSetUp`, `talkNoGateway`; `docs/voice.md` §4.3).
struct PendingCallCopy {
    enum Fix {
        case tryAgain
        case addGateway
        case setUpBotMode
    }

    let name: String
    let appearance: BotAppearance
    let isWaiting: Bool
    /// Asleep when there's no gateway to call through.
    let mood: BotMood
    let meta: String
    let title: String
    let caption: String
    let hint: String?
    let fix: (title: String, action: Fix)?

    init(_ call: PendingCall, workspace: BotWorkspace?) {
        let roster = workspace?.roster
        let bot = call.callee.botName.flatMap { roster?.bot(named: $0) }
        if case .cantStart(.noGateway) = call.state {
            name = String(localized: "Hermes")
        } else if let botName = call.callee.botName {
            name = bot?.title ?? TalkDirectory.bots().first { $0.id == botName }?.title ?? botName
        } else {
            name = String(localized: "Hermes")
        }
        if let bot, let roster {
            appearance = roster.appearance(for: bot)
        } else if call.callee == .hermes, let roster, let main = roster.visibleBots.first(where: \.isDefault) {
            appearance = roster.appearance(for: main)
        } else {
            appearance = BotAppearance(profile: call.callee.botName ?? "hermes")
        }
        isWaiting = call.state == .waitingForBotMode
        mood = call.state == .cantStart(.noGateway) ? .sleeping : .idle
        meta = isWaiting ? String(localized: "Not started yet") : String(localized: "Didn’t start")
        switch call.state {
        case .waitingForBotMode, .ready:
            title = String(localized: "Waiting for Bot Mode")
            caption = String(localized: "The call starts as soon as Bot Mode connects.")
            hint = String(localized: "Hermes stops waiting after a minute.")
            fix = nil
        case .timedOut:
            title = String(localized: "Bot Mode isn’t connected")
            caption = String(localized: "\(name) can’t take the call until Bot Mode connects.")
            hint = nil
            fix = (String(localized: "Try Again"), .tryAgain)
        case .cantStart(.noSuchBot):
            title = String(localized: "No Bot called \(call.callee.botName ?? name)")
            caption = String(localized: "There’s no Bot with that name on this gateway.")
            hint = nil
            fix = nil
        case .cantStart(.botModeNotSetUp):
            title = String(localized: "Bot Mode isn’t set up")
            caption = String(localized: "Talking with a Bot needs Bot Mode on this gateway.")
            hint = String(localized: "Talk with Hermes works without it.")
            fix = (String(localized: "Set Up Bot Mode"), .setUpBotMode)
        case .cantStart(.noGateway):
            title = String(localized: "No gateway yet")
            caption = String(localized: "Add your Hermes gateway to start a call.")
            hint = nil
            fix = (String(localized: "Add Gateway"), .addGateway)
        }
    }

    static func perform(_ fix: Fix) {
        switch fix {
        case .tryAgain: TalkCenter.shared.retryPending()
        case .addGateway: TalkCenter.shared.fixPending(.addGateway)
        case .setUpBotMode: TalkCenter.shared.fixPending(.setUpBotMode)
        }
    }
}

/// The call screen while the call waits to start, or says why it can't (`talkWaiting`): who,
/// "Not started yet", the state, and Cancel. The spinner is the one moving thing.
struct PendingCallScreen: View {
    let call: PendingCall
    @Environment(AppModel.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let copy = PendingCallCopy(call, workspace: app.currentWorkspace)
        let compact = verticalSizeClass == .compact
        VStack(spacing: 0) {
            HStack {
                Button {
                    TalkCenter.shared.isExpanded = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(nil)
                .accessibilityLabel("Minimise")
                .accessibilityHint("Keeps waiting while you read the chat")
                Spacer()
                VStack(spacing: 1) {
                    Text(copy.name)
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(copy.meta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Spacer(minLength: 8)
            PendingCallFigure(appearance: copy.appearance, mood: copy.mood, size: compact ? 84 : 160)
            PendingCallTexts(copy: copy, large: !compact)
                .padding(.horizontal, 32)
                .padding(.top, compact ? 14 : 26)
            Spacer(minLength: 12)
            PendingCallButtons(copy: copy, height: 50)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .accessibilityAction(.escape) { TalkCenter.shared.isExpanded = false }
    }
}

/// The waiting call as the iPad panel and in the Mac's call window.
struct PendingCallPanel: View {
    let call: PendingCall
    @Environment(AppModel.self) private var app

    var body: some View {
        let copy = PendingCallCopy(call, workspace: app.currentWorkspace)
        VStack(spacing: 12) {
            PendingCallFigure(appearance: copy.appearance, mood: copy.mood, size: 84)
                .frame(height: 150)
            VStack(spacing: 2) {
                Text(copy.name)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(copy.meta)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            PendingCallTexts(copy: copy, large: false)
            PendingCallButtons(copy: copy, height: 40)
        }
        .padding(18)
        .frame(width: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.name)
    }
}

/// The face on its aura, still: what moves while the call waits is the spinner.
private struct PendingCallFigure: View {
    let appearance: BotAppearance
    let mood: BotMood
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: Palette.aura, location: 0),
                        .init(color: Palette.auraSoft, location: 0.55),
                        .init(color: Palette.auraSoft.opacity(0), location: 1),
                    ],
                    center: .center, startRadius: 0, endRadius: size
                ))
                .frame(width: size * 2, height: size * 2)
                .opacity(mood == .sleeping ? 0.5 : 0.8)
            BotFace(appearance: appearance, size: size, mood: mood)
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .accessibilityHidden(true)
    }
}

private struct PendingCallTexts: View {
    let copy: PendingCallCopy
    let large: Bool

    var body: some View {
        VStack(spacing: large ? 10 : 6) {
            HStack(spacing: 8) {
                if copy.isWaiting { Spinner() }
                Text(copy.title)
                    .font(large ? .title3.weight(.semibold) : .headline)
                    .foregroundStyle(Theme.primaryText)
            }
            Text(copy.caption)
                .font(large ? .body : .subheadline)
                .foregroundStyle(Theme.secondaryText)
            if let hint = copy.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// The fix when there is one (Try Again, Set Up Bot Mode, Add Gateway), then Cancel.
private struct PendingCallButtons: View {
    let copy: PendingCallCopy
    let height: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            if let fix = copy.fix {
                Button {
                    PendingCallCopy.perform(fix.action)
                } label: {
                    // Drawn like Cancel rather than `.borderedProminent`, which the Mac greys out
                    // in a window that isn't key while its label stays ink-coloured.
                    Text(fix.title)
                        .font(.headline)
                        .foregroundStyle(Theme.inkForeground)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            Button(action: TalkCenter.shared.cancelPending) {
                Text("Cancel")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(Theme.controlFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// The waiting call minimised (`talkWaitingMinimised`): who, the state, and Cancel.
struct PendingCallPill: View {
    let call: PendingCall
    @Environment(AppModel.self) private var app

    var body: some View {
        let copy = PendingCallCopy(call, workspace: app.currentWorkspace)
        HStack(spacing: 10) {
            Button {
                TalkCenter.shared.isExpanded = true
            } label: {
                HStack(spacing: 10) {
                    BotFace(appearance: copy.appearance, size: 24, mood: copy.mood)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(copy.appearance.color.opacity(0.5), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Calling \(copy.name)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Text(copy.title)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Calling \(copy.name), \(copy.title)")
            .accessibilityHint("Opens the call")
            Button(action: TalkCenter.shared.cancelPending) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 34, height: 34)
                    .background(Theme.ink, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Cancel call")
        }
        .padding(.leading, 10)
        .padding(.trailing, 11)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Says the waiting call's state to VoiceOver once each time it changes, and opens the fix its
/// screen asked for in this window (`docs/voice.md` §4.4).
struct PendingCallAnnouncer: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    private var center: TalkCenter { .shared }

    private struct Key: Equatable {
        let id: UUID
        let state: PendingCall.State
    }

    /// Every window has this; the first to see a state says it.
    private static var announced: Key?

    func body(content: Content) -> some View {
        content
            .onChange(of: center.pendingCall.map { Key(id: $0.id, state: $0.state) }, initial: true) { _, key in
                guard let key, key != Self.announced, let call = center.pendingCall else { return }
                Self.announced = key
                let copy = PendingCallCopy(call, workspace: app.currentWorkspace)
                AccessibilityNotification.Announcement(copy.title).post()
            }
            .onChange(of: center.setupRequest) { _, request in
                guard let request, let router else { return }
                center.setupRequest = nil
                switch request {
                case .addGateway:
                    router.sheet = .addGateway
                case .setUpBotMode:
                    guard let workspace = app.currentWorkspace else { return }
                    router.sheet = .editGateway(workspace.bot)
                }
            }
    }
}
