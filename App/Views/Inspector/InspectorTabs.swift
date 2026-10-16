import HermesKit
import SwiftUI

// MARK: - Terminal

/// The Terminal tab (`ipadInspectorTerminal`): the process (`processHeader`) and its live output,
/// then the chat's other processes, finished ones last. Output is never logged.
struct TerminalTabView: View {
    let inspector: InspectorModel
    let conversation: ConversationModel
    let processID: String

    @State private var shownIDs: Set<String> = []

    private var processes: [ConversationModel.BackgroundProcess] { conversation.processes }
    private var main: ConversationModel.BackgroundProcess? { processes.first { $0.id == processID } }
    private var others: [ConversationModel.BackgroundProcess] {
        processes.filter { $0.id != processID }.sorted { ($0.isRunning ? 0 : 1, $1.startedAt) < ($1.isRunning ? 0 : 1, $0.startedAt) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let main {
                    ProcessHeader(process: main, stop: { conversation.stopProcess(main) })
                    OutputView(text: main.output)
                } else {
                    Text("This process isn't running in this chat anymore.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 20)
                }
                ForEach(others) { process in
                    ProcessHeader(process: process, stop: { conversation.stopProcess(process) }, show: {
                        if shownIDs.contains(process.id) { shownIDs.remove(process.id) } else { shownIDs.insert(process.id) }
                    }, isShown: shownIDs.contains(process.id))
                    if shownIDs.contains(process.id) {
                        OutputView(text: process.output)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .defaultScrollAnchor(.top)
        .task { await conversation.refreshProcesses() }
    }
}

/// `processHeader`: state, command, how long, where, pid, and Stop (or Show).
private struct ProcessHeader: View {
    let process: ConversationModel.BackgroundProcess
    let stop: () -> Void
    var show: (() -> Void)?
    var isShown = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(process.isRunning ? Theme.success : Theme.tertiaryText)
                .frame(width: 8, height: 8)
                .overlay {
                    if process.isRunning { Circle().stroke(Theme.success.opacity(0.3), lineWidth: 4) }
                }
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.command.isEmpty ? String(localized: "Background process") : process.command)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(detail(now: context.date))
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if process.isRunning {
                Button("Stop", action: stop)
                    .font(.footnote.weight(.medium))
                    .cardButton()
            } else if let show {
                Button(isShown ? "Hide" : "Show", action: show)
                    .font(.footnote.weight(.medium))
                    .cardButton()
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// "Running 12 min · ~/Code/hermes-site · pid 48213", "Finished 9 min ago · exit 0".
    private func detail(now: Date) -> String {
        var parts: [String] = []
        if process.isRunning {
            parts.append(String(localized: "Running \(Self.duration(now.timeIntervalSince(process.startedAt)))"))
        } else if let finished = process.finishedAt {
            parts.append(String(localized: "Finished \(Formatting.relativePhrase(finished))"))
        } else {
            parts.append(String(localized: "Finished"))
        }
        if let cwd = process.cwd { parts.append(cwd.replacingOccurrences(of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression)) }
        if process.isRunning, let pid = process.pid { parts.append("pid \(pid)") }
        if !process.isRunning, let code = process.exitCode { parts.append("exit \(code)") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "under a minute") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }
}

/// A process's output: monospaced, selectable, following new lines; error lines in red.
private struct OutputView: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(400)
        Text(attributed(lines))
            .font(.system(.footnote, design: .monospaced))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel(Text("Output"))
    }

    private func attributed(_ lines: ArraySlice<Substring>) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var run = AttributedString(String(line) + (index < lines.count - 1 ? "\n" : ""))
            run.foregroundColor = OutputBlock.isFailure(String(line)) ? Theme.danger : Theme.primaryText
            result += run
        }
        return result
    }
}

// MARK: - Screen

/// The Screen tab (`ipadInspectorScreen`): Hermes's own desktop, live, with `screenBar` in clear
/// glass over a media-dim fade. Take Control and Hand Back move the lease.
struct ScreenTabView: View {
    let inspector: InspectorModel
    let screen: ScreenController

    @State private var keyboardText = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hermes's screen on \(inspector.gatewayMachineName)")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
            ZStack(alignment: .bottom) {
                Color.black
                if let image = screen.image {
                    GeometryReader { geometry in
                        let fitted = fit(screen.size, in: geometry.size)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .gesture(input(in: geometry.size, fitted: fitted))
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text("Hermes's screen, live"))
                    .accessibilityAddTraits(.updatesFrequently)
                } else {
                    placeholder
                }
                LinearGradient(colors: [.clear, Theme.mediaDim], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
                ScreenBar(screen: screen, typing: $typing)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)
                if screen.personInControl {
                    TextField("", text: $keyboardText)
                        .focused($typing)
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                        .onChange(of: keyboardText) { _, text in
                            guard !text.isEmpty else { return }
                            screen.type(text)
                            keyboardText = ""
                        }
                        .onSubmit { screen.key(0xFF0D); typing = true }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            #if os(macOS)
            .focusable(screen.personInControl)
            .onKeyPress(phases: .down) { press in
                guard screen.personInControl else { return .ignored }
                if let keysym = Self.keysym(press.key) { screen.key(keysym) } else { screen.type(press.characters) }
                return .handled
            }
            #endif
        }
        .task {
            await screen.refreshStatus()
            await screen.connect()
        }
        .onDisappear { screen.disconnect() }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch screen.phase {
        case .closed(let reason):
            VStack(spacing: 10) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("Reconnect") { Task { await screen.connect() } }
                    .glassButton()
            }
            .padding(24)
        default:
            ProgressView().tint(.white)
        }
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Taps click and drags move the pointer, in the screen's own pixels.
    private func input(in box: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard screen.personInControl else { return }
                screen.pointer(at: map(value.location, box: box, fitted: fitted), buttons: 1)
            }
            .onEnded { value in
                guard screen.personInControl else { return }
                screen.pointer(at: map(value.location, box: box, fitted: fitted), buttons: 0)
                typing = true
            }
    }

    private func map(_ point: CGPoint, box: CGSize, fitted: CGSize) -> CGPoint {
        let origin = CGPoint(x: (box.width - fitted.width) / 2, y: (box.height - fitted.height) / 2)
        let scale = fitted.width > 0 ? screen.size.width / fitted.width : 1
        return CGPoint(x: max(0, (point.x - origin.x) * scale), y: max(0, (point.y - origin.y) * scale))
    }

    #if os(macOS)
    private static func keysym(_ key: KeyEquivalent) -> UInt32? {
        switch key {
        case .return: 0xFF0D
        case .delete: 0xFF08
        case .tab: 0xFF09
        case .escape: 0xFF1B
        case .leftArrow: 0xFF51
        case .upArrow: 0xFF52
        case .rightArrow: 0xFF53
        case .downArrow: 0xFF54
        default: nil
        }
    }
    #endif
}

/// `screenBar`: live, who's in control, Take Control or Hand Back. Clear glass over the video.
private struct ScreenBar: View {
    let screen: ScreenController
    var typing: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(screen.phase == .live ? Theme.danger : Color.white.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error = screen.leaseError {
                Text(error).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Button {
                Task {
                    if screen.personInControl { await screen.handBack() } else { await screen.takeControl(); typing.wrappedValue = true }
                }
            } label: {
                Text(screen.personInControl ? "Hand Back" : "Take Control")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(screen.phase != .live || screen.isChangingLease)
            .accessibilityLabel(screen.personInControl ? "Hand Back" : "Take Control")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 48)
        .frame(maxWidth: 420)
        .glassEffect(.clear, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var status: String {
        switch screen.phase {
        case .live:
            if screen.personInControl { return String(localized: "Live · You're in control") }
            if screen.someoneElseInControl { return String(localized: "Live · Someone else is in control") }
            return String(localized: "Live · Hermes is in control")
        case .connecting: return String(localized: "Connecting…")
        case .idle: return String(localized: "Not connected")
        case .closed: return String(localized: "Disconnected")
        }
    }
}

// MARK: - Team, Plan, Sources

/// The Team tab: the team, or one helper in it (the old Team inspector).
struct TeamTabView: View {
    let store: HelperStore
    let conversation: ConversationModel
    let workspace: BotWorkspace
    let teamID: String

    var body: some View {
        Group {
            if let helperID = store.shownHelper, store.helper(helperID) != nil, store.team(containing: helperID)?.id == teamID {
                HelperDetailView(store: store, conversation: conversation, workspace: workspace, helperID: helperID, style: .inspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                TeamView(store: store, conversation: conversation, workspace: workspace, teamID: teamID, style: .inspector)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .environment(\.inInspectorTab, true)
        .animation(Theme.snappy, value: store.shownHelper)
    }
}

/// The Plan tab: the latest plan, live (`todo.updated`).
struct PlanTabView: View {
    let inspector: InspectorModel

    var body: some View {
        ScrollView {
            if let plan = inspector.latestPlan {
                PlanCard(plan: plan)
                    .padding(12)
            } else {
                Text("Hermes hasn't made a plan in this chat.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        }
    }
}

/// The Sources tab: the latest turn's search results, numbered as the reply cites them.
struct SourcesTabView: View {
    let inspector: InspectorModel

    var body: some View {
        ScrollView {
            let sources = inspector.latestSources
            if sources.isEmpty {
                Text("No sources from this chat yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                SearchResultsCard(results: sources, limit: nil)
                    .padding(12)
            }
        }
    }
}

extension EnvironmentValues {
    /// Helper views inside the Inspector's Team tab: no header of their own (the tab names it).
    @Entry var inInspectorTab = false
    /// The chat's Inspector, for transcript cards that open things in it.
    @Entry var inspectorModel: InspectorModel?
}
