import HermesKit
import SwiftUI

// MARK: - Terminal

/// The Terminal tab (`docs/background-processes.md` §6): the chat's processes, running first with
/// Stop and the newest one's output open, then Finished (failed first) with Clear. A row's chevron
/// (or its open output) shows that process's own page. Output is never logged.
struct TerminalTabView: View {
    let inspector: InspectorModel
    let conversation: ConversationModel

    var body: some View {
        Group {
            if let id = inspector.terminalPage {
                ProcessPage(inspector: inspector, conversation: conversation, processID: id)
            } else {
                ProcessList(inspector: inspector, conversation: conversation)
            }
        }
        .animation(.smooth(duration: 0.25), value: inspector.terminalPage)
        .task { await conversation.refreshProcesses() }
        .confirmationDialog(
            Text("Stop \(confirmingName)?"), isPresented: Binding(
                get: { inspector.confirmingStop != nil }, set: { if !$0 { inspector.confirmingStop = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                if let id = inspector.confirmingStop { conversation.stopProcess(id) }
                inspector.confirmingStop = nil
            }
        } message: {
            Text("It stops on \(inspector.gatewayMachineName). Hermes hears it was stopped.")
        }
    }

    private var confirmingName: String {
        inspector.confirmingStop.flatMap { conversation.processTracker[$0]?.name } ?? String(localized: "this process")
    }
}

/// The list: running, newest first; then Finished.
private struct ProcessList: View {
    let inspector: InspectorModel
    let conversation: ConversationModel

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var processes: [BackgroundProcess] { conversation.processTracker.processes }

    private var running: [BackgroundProcess] {
        processes.filter(\.isRunning).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Failed first, then the most recent.
    private var finished: [BackgroundProcess] {
        processes.filter { !$0.isRunning }.sorted {
            if ($0.state == .failed) != ($1.state == .failed) { return $0.state == .failed }
            return ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast)
        }
    }

    /// The running row whose output is open: the one tapped, else the newest.
    private var openRow: String? {
        if let id = inspector.terminalOpenRow, running.contains(where: { $0.id == id }) { return id }
        return running.first?.id
    }

    var body: some View {
        if processes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Nothing runs in the background")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Text("Dev servers, builds and tests Hermes starts in this chat show here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(running) { process in
                        ProcessRow(process: process, botName: { conversation.botTitle($0) }) {
                            conversation.stopProcess(process.id)
                        } open: {
                            withAnimation(.smooth(duration: 0.25)) { inspector.terminalOpenRow = process.id }
                        }
                        if openRow == process.id {
                            ProcessLog(process: process)
                                .onTapGesture { inspector.terminalPage = process.id }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint(Text("Shows all of its output"))
                                .padding(.bottom, 8)
                                .transition(.opacity)
                        }
                    }
                    if !finished.isEmpty {
                        HStack {
                            Text("Finished")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                            if sizeClass != .compact {
                                Button("Clear") { withAnimation(.smooth(duration: 0.25)) { conversation.clearFinishedProcesses() } }
                                    .font(.footnote.weight(.medium))
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, running.isEmpty ? 4 : 14)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(finished) { process in
                            ProcessRow(process: process, botName: { conversation.botTitle($0) }, stop: {}) {
                                inspector.terminalPage = process.id
                            }
                            .onAppear { conversation.markProcessSeen(process.id) }
                        }
                        if sizeClass == .compact {
                            Button("Clear Finished") { withAnimation(.smooth(duration: 0.25)) { conversation.clearFinishedProcesses() } }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                                .buttonStyle(.borderless)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .animation(.smooth(duration: 0.25), value: processes.map(\.state))
            }
        }
    }
}

/// `processRow`: the state, the name, the command, when and where; Stop while it runs, else a
/// chevron to its output.
private struct ProcessRow: View {
    let process: BackgroundProcess
    let botName: (String) -> String?
    let stop: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProcessStateGlyph(state: process.state, showsFailure: true, size: 16)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if !process.shownCommand.isEmpty {
                    Text(verbatim: process.shownCommand)
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TimelineView(.periodic(from: .now, by: process.isRunning ? 15 : 60)) { context in
                    Text(meta(now: context.date))
                        .font(.caption)
                        .foregroundStyle(process.state == .failed ? Theme.danger : Theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The words read as one element; the button stays its own (a combined element
            // holding a control that disappears sent AppKit's accessibility into a loop).
            .accessibilityElement(children: .combine)
            if process.isRunning {
                Button(process.isStopping ? "Stopping…" : "Stop", action: stop)
                    .font(.footnote.weight(.medium))
                    .cardButton()
                    .disabled(process.isStopping)
                    .accessibilityLabel(Text("Stop \(process.name)"))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAction(named: Text("Show Output"), open)
        .contextMenu {
            Button("Copy Command", systemImage: "doc.on.doc") { Pasteboard.copy(process.shownCommand) }
            Button("Copy Output", systemImage: "text.alignleft") { Pasteboard.copy(process.output.text) }
                .disabled(process.output.text.isEmpty)
            if process.isRunning {
                Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
            }
        }
    }

    /// "Running 3 min · ~/Code/hermes", "Finished 9 min ago · 46 passed", "Failed · exit 1 ·
    /// Engineer is busy with another message".
    private func meta(now: Date) -> String {
        var parts: [String] = []
        switch process.state {
        case .running:
            if process.isStopping {
                parts.append(String(localized: "Stopping…"))
            } else if let time = process.duration(now: now) {
                parts.append(String(localized: "Running \(BackgroundProcess.durationText(time))"))
            } else {
                parts.append(String(localized: "Running"))
            }
            if let cwd = process.cwd { parts.append(ProcessNaming.shortenPaths(cwd)) }
            if let pid = process.pid { parts.append("pid \(pid)") }
        case .finished:
            parts.append(process.finishedAt.map { String(localized: "Finished \(Formatting.relativePhrase($0, now: now))") } ?? String(localized: "Finished"))
            if let latest = process.latestLine(botName: botName) { parts.append(latest) }
        case .failed:
            parts.append(process.stateLabel(now: now))
            if let latest = process.latestLine(botName: botName) { parts.append(latest) }
        case .stopped:
            parts.append(process.finishedAt.map { String(localized: "Stopped \(Formatting.relativePhrase($0, now: now))") } ?? String(localized: "Stopped"))
        case .ended:
            parts.append(String(localized: "Ended"))
        }
        return parts.joined(separator: " · ")
    }
}

/// `processLog`: the command and the newest lines of a running process, the last one brightest.
private struct ProcessLog: View {
    let process: BackgroundProcess

    /// The newest eight lines with something on them at either end.
    private var lines: [Substring] {
        var lines = process.output.lastLines(9)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(8).drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 3) {
            if !process.shownCommand.isEmpty {
                Text(verbatim: "$ " + process.shownCommand)
                    .foregroundStyle(Theme.tertiaryText)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: String(line))
                    .foregroundStyle(index == lines.count - 1 ? Theme.primaryText : Theme.secondaryText)
            }
        }
        .font(Theme.Typography.code)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One process's page: `processHeader`, then all of its output (selectable, following the
/// newest line), Copy Output, Stop, and Ask Hermes About This.
private struct ProcessPage: View {
    let inspector: InspectorModel
    let conversation: ConversationModel
    let processID: String

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var process: BackgroundProcess? { conversation.processTracker[processID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                inspector.terminalPage = nil
            } label: {
                Label("Terminal", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            if let process {
                ProcessHeader(process: process) { conversation.stopProcess(process.id) }
                OutputView(lines: process.output.lastLines(400))
                    .layoutPriority(1)
                HStack(spacing: 8) {
                    Button("Copy Output", systemImage: "doc.on.doc") { Pasteboard.copy(process.output.text) }
                        .disabled(process.output.text.isEmpty)
                    Button("Ask Hermes About This", systemImage: "text.bubble") { askAbout(process) }
                        .disabled(process.output.text.isEmpty)
                }
                .font(.footnote.weight(.medium))
                .cardButton()
                .onAppear { conversation.markProcessSeen(process.id) }
            } else {
                Text("This process isn't in this chat's list anymore.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// The last 40 lines into the composer as a quote; the sheet steps aside on iPhone.
    private func askAbout(_ process: BackgroundProcess) {
        let lines = process.output.lines.suffix(40).map { "> " + $0 }
        let quote = String(localized: "About \(process.name) (`\(process.shownCommand)`):") + "\n" + lines.joined(separator: "\n") + "\n\n"
        conversation.draft = conversation.draft.isEmpty ? quote : conversation.draft + "\n\n" + quote
        if sizeClass == .compact { inspector.isPresented = false }
    }
}

/// `processHeader`: the state, the name and command, how long, where, pid, and Stop.
private struct ProcessHeader: View {
    let process: BackgroundProcess
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProcessStateGlyph(state: process.state, showsFailure: true, size: 14)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if !process.shownCommand.isEmpty {
                    Text(verbatim: process.shownCommand)
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TimelineView(.periodic(from: .now, by: process.isRunning ? 15 : 60)) { context in
                    Text(detail(now: context.date))
                        .font(.caption)
                        .foregroundStyle(process.state == .failed ? Theme.danger : Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if process.isRunning {
                Button(process.isStopping ? "Stopping…" : "Stop", action: stop)
                    .font(.footnote.weight(.medium))
                    .cardButton()
                    .disabled(process.isStopping)
                    .accessibilityLabel(Text("Stop \(process.name)"))
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
    }

    /// "Running 12 min · ~/Code/hermes-site · pid 48213", "Finished 9 min ago · exit 0".
    private func detail(now: Date) -> String {
        var parts = [process.stateLabel(now: now)]
        if let cwd = process.cwd { parts.append(ProcessNaming.shortenPaths(cwd)) }
        if process.isRunning, let pid = process.pid { parts.append("pid \(pid)") }
        if process.state == .finished, let code = process.exitCode { parts.append("exit \(code)") }
        return parts.joined(separator: " · ")
    }
}

/// A process's output: monospaced, selectable, following new lines; error lines in red.
private struct OutputView: View {
    let lines: [Substring]

    var body: some View {
        let text = Text(attributed(lines))
            .font(Theme.Typography.code)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        // Short output hugs its lines; long output scrolls and follows the newest lines.
        ViewThatFits(in: .vertical) {
            text.fixedSize(horizontal: false, vertical: true)
            ScrollView { text }
                .defaultScrollAnchor(.bottom)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func attributed(_ lines: [Substring]) -> AttributedString {
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
                // Closed over the last frame: why, and Reconnect.
                if screen.image != nil, case .closed = screen.phase {
                    Theme.mediaDim
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
            Spinner(size: .regular).tint(.white)
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
        case .closed(let reason): return reason
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
