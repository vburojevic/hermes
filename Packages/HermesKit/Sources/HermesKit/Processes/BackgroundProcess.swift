import Foundation

/// A process Hermes started that keeps running after its turn (`docs/background-processes.md`):
/// a dev server, a build, a test run, a message to another Bot. `terminal` with `background:
/// true` starts one, and so does `message_agent`'s delivery.
public struct BackgroundProcess: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case running, finished, failed, stopped
        /// The gateway no longer lists it, and nobody here saw how it ended.
        case ended
    }

    /// `proc_…`, the gateway's id (`session_id` in `process.list`).
    public let id: String
    /// The command as Hermes ran it (`process.list` gives its first 200 characters).
    public private(set) var command: String
    /// The command cleaned, home as `~` (§2): what shows after `$`.
    public private(set) var shownCommand: String
    /// "Release build", "Message to Engineer" (§2).
    public private(set) var name: String
    /// A name the call that started it gave ("Message to Engineer" from `message_agent`), which
    /// says more than its command.
    private var givenName: String?
    public internal(set) var output: ProcessOutput
    public internal(set) var state: State
    /// Stop was asked: "Stopping…" until the list says it exited.
    public internal(set) var isStopping = false
    public internal(set) var exitCode: Int?
    /// `exited`, `killed`, `lost`, `failed_start`.
    public internal(set) var completionReason: String?
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var cwd: String?
    public internal(set) var pid: Int?
    /// Hermes hears when it ends (`notify_on_complete`), and so does the push plugin.
    public internal(set) var notifiesOnCompletion = false
    /// It outlives its chat closing (`persist_on_release`): listed only when set.
    public internal(set) var persistsOnRelease = false
    /// The turn and the tool call that started it, when this chat has them.
    public internal(set) var turnID: String?
    public internal(set) var toolCallID: String?
    /// A failure shown in the Terminal: the chip stops counting it.
    public internal(set) var seenFailure = false

    public init(id: String, command: String = "", state: State = .running, startedAt: Date? = nil,
                botName: (String) -> String? = { _ in nil }) {
        self.id = id
        self.command = command
        shownCommand = ProcessNaming.clean(command)
        name = command.isEmpty ? String(localized: "Background process") : ProcessNaming.name(for: command, botName: botName)
        output = ProcessOutput()
        self.state = state
        self.startedAt = startedAt
    }

    public var isRunning: Bool { state == .running }

    /// `message_agent`'s delivery to another Bot: Hermes's own `bot_mode_dm.py --run-delivery`.
    public var isBotDelivery: Bool {
        command.contains("bot_mode_dm.py") && command.contains("--run-delivery")
    }

    mutating func setCommand(_ command: String, botName: (String) -> String?) {
        guard command != self.command, !command.isEmpty else { return }
        self.command = command
        shownCommand = ProcessNaming.clean(command)
        name = givenName ?? ProcessNaming.name(for: command, botName: botName)
    }

    mutating func give(name: String) {
        givenName = name
        self.name = name
    }

    /// Named again (the Bots' names arrived after the process did).
    mutating func rename(botName: (String) -> String?) {
        guard givenName == nil, !command.isEmpty else { return }
        name = ProcessNaming.name(for: command, botName: botName)
    }

    /// How long it ran (or has run): start to exit, or to now.
    public func duration(now: Date = .now) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (state == .running ? now : (finishedAt ?? now)).timeIntervalSince(startedAt))
    }

    /// The error in plain words when the output is one JSON error (§3), else the last line.
    public func latestLine(botName: (String) -> String? = { _ in nil }) -> String? {
        output.errorText.map { ProcessOutput.plainWords($0, botName: botName) } ?? output.latestLine
    }

    /// "Running · 3 min", "Stopping…", "Finished · 4 min", "Failed · exit 1", "Stopped · 12 min",
    /// "Ended" (§4).
    public func stateLabel(now: Date = .now) -> String {
        let time = duration(now: now).map(Self.durationText)
        switch state {
        case .running:
            if isStopping { return String(localized: "Stopping…") }
            return time.map { String(localized: "Running · \($0)") } ?? String(localized: "Running")
        case .finished:
            return time.map { String(localized: "Finished · \($0)") } ?? String(localized: "Finished")
        case .failed:
            if let exitCode, exitCode != 0 { return String(localized: "Failed · exit \(exitCode)") }
            return String(localized: "Failed")
        case .stopped:
            return time.map { String(localized: "Stopped · \($0)") } ?? String(localized: "Stopped")
        case .ended:
            return String(localized: "Ended")
        }
    }

    /// "40 s", "3 min", "2 h 5 min".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let seconds = Int(saturating: seconds)
        if seconds < 60 { return String(localized: "\(max(1, seconds)) s") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes) min") }
        return minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }

    /// "3 minutes", for VoiceOver.
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : (seconds < 3600 ? [.minutes] : [.hours, .minutes])
        return Duration.seconds(max(1, Int(saturating: seconds))).formatted(.units(allowed: units, width: .wide))
    }
}

/// A chat's background processes and what is known of them (`docs/background-processes.md` §1):
/// output as it streams (`agent.terminal.output`), the gateway's list (`process.list`, the only
/// word on exits), and which call started each one.
public struct ProcessTracker: Equatable, Sendable {
    /// Oldest first.
    public private(set) var processes: [BackgroundProcess] = []
    /// The gateway has answered `process.list` at least once: a process it doesn't list has ended.
    public private(set) var hasListed = false
    /// Calls that started processes, by process id, kept for processes not seen yet.
    private var links: [String: Link] = [:]

    struct Link: Equatable, Sendable {
        var turnID: String?
        var toolCallID: String?
        var name: String?
        var command: String?
    }

    /// A process that just ended while this chat watched.
    public struct Ending: Equatable, Sendable {
        public var id: String
        public var state: BackgroundProcess.State
    }

    public init() {}

    public subscript(id: String) -> BackgroundProcess? {
        processes.first { $0.id == id }
    }

    public var running: [BackgroundProcess] { processes.filter(\.isRunning) }

    /// Output for a process; one not seen before joins as running. Returns whether it's new.
    @discardableResult
    public mutating func receiveOutput(_ chunk: String, for id: String, now: Date = .now) -> Bool {
        if let index = processes.firstIndex(where: { $0.id == id }) {
            processes[index].output.append(chunk)
            // Output means it runs: a list that missed it (asked for just before it started) was wrong.
            if processes[index].state == .ended {
                processes[index].state = .running
                processes[index].finishedAt = nil
            }
            return false
        }
        var process = BackgroundProcess(id: id, startedAt: now)
        apply(links[id], to: &process, botName: { _ in nil })
        process.output.append(chunk)
        processes.append(process)
        return true
    }

    /// What `process.list` says now (`docs/background-processes.md` §1). A process it no longer
    /// lists ended (if it was running here, nobody saw how: "Ended"). Returns the processes this
    /// device saw running that ended since the last look (one that had ended before it first
    /// showed here is no news). `ignoring`: processes cleared on this device.
    @discardableResult
    public mutating func apply(list rows: [JSONValue], now: Date = .now, ignoring cleared: Set<String> = [],
                               botName: (String) -> String? = { _ in nil }) -> [Ending] {
        var endings: [Ending] = []
        var listed: Set<String> = []
        for row in rows {
            guard let id = row["session_id"]?.stringValue ?? row["process_id"]?.stringValue ?? row["id"]?.stringValue,
                  !id.isEmpty, !cleared.contains(id) else { continue }
            listed.insert(id)
            let index: Int
            let wasRunning: Bool
            if let found = processes.firstIndex(where: { $0.id == id }) {
                index = found
                wasRunning = processes[found].isRunning
            } else {
                var process = BackgroundProcess(id: id)
                apply(links[id], to: &process, botName: botName)
                processes.append(process)
                index = processes.count - 1
                wasRunning = false
            }
            Self.update(&processes[index], from: row, now: now, botName: botName)
            if wasRunning, !processes[index].isRunning {
                endings.append(Ending(id: id, state: processes[index].state))
            }
        }
        for index in processes.indices where !listed.contains(processes[index].id) && processes[index].isRunning {
            processes[index].state = processes[index].isStopping ? .stopped : .ended
            processes[index].isStopping = false
            processes[index].finishedAt = processes[index].finishedAt ?? now
            endings.append(Ending(id: processes[index].id, state: processes[index].state))
        }
        hasListed = true
        return endings
    }

    static func update(_ process: inout BackgroundProcess, from row: JSONValue, now: Date, botName: (String) -> String?) {
        if let command = row["command"]?.stringValue ?? row["cmd"]?.stringValue {
            process.setCommand(command, botName: botName)
        }
        // Whole seconds: kept unless it moved, so times and the chip don't jitter between looks.
        if let uptime = row["uptime_seconds"]?.doubleValue {
            let started = now.addingTimeInterval(-uptime)
            if process.startedAt.map({ abs($0.timeIntervalSince(started)) > 2 }) ?? true { process.startedAt = started }
        }
        process.cwd = row["cwd"]?.stringValue ?? process.cwd
        process.pid = row["pid"]?.truncatedIntValue ?? process.pid
        process.notifiesOnCompletion = row["notify_on_complete"]?.boolValue ?? process.notifiesOnCompletion
        process.persistsOnRelease = row["persist_on_release"]?.boolValue ?? false
        if process.output.text.isEmpty, let tail = row["output_tail"]?.stringValue ?? row["output_preview"]?.stringValue {
            process.output = ProcessOutput(cleaning: tail)
        }
        guard row["status"]?.stringValue == "exited" else {
            // Listed as running after an earlier list missed it: it runs. (An exit is final: a
            // stale list that still says running doesn't undo one.)
            if process.state == .ended {
                process.state = .running
                process.finishedAt = nil
            }
            return
        }
        let code = row["exit_code"]?.truncatedIntValue
        let reason = row["completion_reason"]?.stringValue
        process.exitCode = code
        process.completionReason = reason
        process.isStopping = false
        // Hermes writes 0 while it doesn't know yet (a failed start, the moment between exit and
        // its move to finished).
        if let exited = row["exited_at"]?.doubleValue, exited > 0 {
            process.finishedAt = Date(timeIntervalSince1970: exited)
        } else if process.finishedAt == nil {
            process.finishedAt = now
        }
        switch reason {
        case "killed": process.state = .stopped
        case "lost", "failed_start": process.state = .failed
        default: process.state = (code ?? 0) == 0 ? .finished : .failed
        }
    }

    /// `terminal.close`: Hermes closed the Terminal tab (`close_terminal`). The process keeps
    /// running: nothing here changes.
    public mutating func terminalClosed(_ id: String) {}

    /// Stop was asked (`process.kill`): "Stopping…" until the list says it exited.
    public mutating func stopRequested(_ id: String) {
        guard let index = processes.firstIndex(where: { $0.id == id }), processes[index].isRunning else { return }
        processes[index].isStopping = true
    }

    /// Stop couldn't be asked: back to running as it was.
    public mutating func stopFailed(_ id: String) {
        guard let index = processes.firstIndex(where: { $0.id == id }) else { return }
        processes[index].isStopping = false
    }

    /// The call that started a process (a `terminal` step, `message_agent`), from a turn.
    /// `started`: the call just finished here, so the process runs now, before any list says so.
    public mutating func link(_ id: String, turnID: String?, toolCallID: String?, name: String?, command: String?,
                              started: Bool = false, now: Date = .now, botName: (String) -> String? = { _ in nil }) {
        let link = Link(turnID: turnID, toolCallID: toolCallID, name: name, command: command)
        if links[id] != link {
            links[id] = link
            if let index = processes.firstIndex(where: { $0.id == id }) {
                apply(link, to: &processes[index], botName: botName)
            }
        }
        if started, !processes.contains(where: { $0.id == id }) {
            var process = BackgroundProcess(id: id, startedAt: now)
            apply(link, to: &process, botName: botName)
            processes.append(process)
        }
    }

    private func apply(_ link: Link?, to process: inout BackgroundProcess, botName: (String) -> String?) {
        guard let link else { return }
        process.turnID = link.turnID ?? process.turnID
        process.toolCallID = link.toolCallID ?? process.toolCallID
        if process.command.isEmpty, let command = link.command { process.setCommand(command, botName: botName) }
        if let name = link.name { process.give(name: name) }
    }

    /// The Terminal showed it: a failure stops counting in the chip.
    public mutating func markSeen(_ id: String) {
        guard let index = processes.firstIndex(where: { $0.id == id }), processes[index].state == .failed else { return }
        processes[index].seenFailure = true
    }

    /// Clear (Finished): gone from this device's list; the gateway forgets them by itself.
    public mutating func remove(_ ids: Set<String>) {
        processes.removeAll { ids.contains($0.id) && !$0.isRunning }
    }

    /// Names again once the Bots' names are known ("Message to Engineer").
    public mutating func rename(botName: (String) -> String?) {
        for index in processes.indices {
            processes[index].rename(botName: botName)
        }
    }
}

/// The composer's chip (`processChip`, `docs/background-processes.md` §5).
public enum ProcessChip: Equatable, Sendable {
    case hidden
    /// "Docs site · 3 min".
    case one(id: String, name: String, startedAt: Date?)
    /// "2 running".
    case several(count: Int)
    /// A check and the name, for 4 s.
    case finished(id: String, name: String)
    /// "1 failed", until the Terminal has shown it.
    case failed(count: Int)

    /// How long a finished process shows in the chip.
    public static let finishedHold: TimeInterval = 4

    /// - Parameter justFinished: a process that finished (exit 0) in the last 4 s.
    public init(processes: [BackgroundProcess], justFinished: String?) {
        let failed = processes.filter { $0.state == .failed && !$0.seenFailure }
        if !failed.isEmpty {
            self = .failed(count: failed.count)
            return
        }
        if let justFinished, let process = processes.first(where: { $0.id == justFinished }), process.state == .finished {
            self = .finished(id: process.id, name: process.name)
            return
        }
        let running = processes.filter(\.isRunning)
        switch running.count {
        case 0: self = .hidden
        case 1: self = .one(id: running[0].id, name: running[0].name, startedAt: running[0].startedAt)
        default: self = .several(count: running.count)
        }
    }
}

extension ToolActivity {
    /// Whether a result names a process (`proc_…`), by a scan of its bytes. Every stored terminal
    /// result is asked as a chat is rebuilt and as its folded turns draw, and a character-by-
    /// character search through long command output added up on the main thread.
    static func mentionsProcess(_ result: String) -> Bool {
        result.containsBytes("proc_")
    }

    /// The background process this call started: `terminal` with `background: true` answers with
    /// its id (`session_id`), `message_agent`'s delivery with `process_id`. Nil for a failed start.
    public var startedProcessID: String? {
        // Every stored terminal result is asked when a chat is rebuilt: only one that names a
        // process is parsed.
        guard name == "terminal" || name == "message_agent", let result, Self.mentionsProcess(result),
              let json = ToolDisplayCache.json(result) else { return nil }
        let id = json["session_id"]?.stringValue ?? json["process_id"]?.stringValue
        guard let id, id.hasPrefix("proc_") else { return nil }
        return id
    }

    /// "Message to Engineer" for `message_agent` (its `to`); a `terminal` process is named from
    /// its command.
    public var startedProcessName: String? {
        guard name == "message_agent", let result, let to = ToolDisplayCache.json(result)?["to"]?.stringValue, !to.isEmpty else { return nil }
        return String(localized: "Message to \(to)")
    }

    /// The command a `terminal` call ran.
    public var startedCommand: String? {
        if let command = arguments?["command"]?.stringValue, !command.isEmpty { return command }
        return name == "terminal" ? preview : nil
    }
}
