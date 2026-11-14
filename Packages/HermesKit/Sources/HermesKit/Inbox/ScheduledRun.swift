import Foundation

// Hermes's scheduler runs every scheduled task in a session of its own (`source == "cron"`, no
// title), even when the run has nothing to say: a task every ten minutes leaves well over a hundred
// sessions a day, most of them empty. A run isn't a chat. Runs with output have two homes, Show →
// Scheduled Tasks and their task's runs in Tasks; empty ones show nowhere; nothing else that lists
// or counts chats sees them (`docs/inbox.md` §5, `docs/tasks.md` §5).

extension HermesSession {
    /// A scheduled task's run, by its source: run ids come in two shapes (`cron_<job>_<time>`
    /// and the newer runtime's `local-…`), so the id says nothing.
    public var isScheduledRun: Bool { origin == .scheduled }

    /// A run that left nothing to read: Hermes lists it with no messages. A count the row didn't
    /// give isn't taken for empty.
    public var isEmptyScheduledRun: Bool { isScheduledRun && messageCount == 0 }
}

public enum ScheduledRuns {
    /// The sessions the app keeps from a list page: everything but empty scheduled runs.
    public static func kept(_ sessions: [HermesSession]) -> [HermesSession] {
        sessions.filter { !$0.isEmptyScheduledRun }
    }

    /// The chats among the sessions the app keeps: everything but scheduled runs. The chat list's
    /// counts, unread badges, Quick Open, search by title and the push plugin's lists read these.
    public static func chats(_ sessions: [HermesSession]) -> [HermesSession] {
        sessions.filter { !$0.isScheduledRun }
    }

    /// A task's runs as Tasks lists them: newest first, empty ones left out.
    public static func shown(_ runs: [CronRun]) -> [CronRun] {
        runs.filter { !$0.isEmpty }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Every routine's runs in one list, as Routines' Past runs shows them: newest first, empty
    /// ones left out, each with the routine it belongs to.
    public static func merged(_ routines: [(routine: String, runs: [CronRun])]) -> [RoutineRun] {
        routines.flatMap { entry in shown(entry.runs).map { RoutineRun(routine: entry.routine, run: $0) } }
            .sorted { ($0.run.startedAt ?? .distantPast) > ($1.run.startedAt ?? .distantPast) }
    }

    /// What a run said, in full: its last reply. Hermes's run row carries only a short preview.
    public static func reply(in transcript: SessionTranscript) -> String? {
        transcript.messages.last { $0.role == "assistant" && !$0.content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.content.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Search's results without the empty runs. Hermes titles every finished run after its task,
    /// so a task's name or `cron_` finds them by title or id, with nothing in them to read.
    public static func shown(_ results: [SessionSearchResult]) -> [SessionSearchResult] {
        results.filter { !$0.isEmptyTaskRun }
    }
}

/// One run on Routines' Past runs, with the routine it belongs to.
public struct RoutineRun: Identifiable, Hashable, Sendable {
    public var routine: String
    public var run: CronRun

    public var id: String { run.id }

    public init(routine: String, run: CronRun) {
        self.routine = routine
        self.run = run
    }
}

extension SessionSearchResult {
    /// A run Hermes found by its id or title that has no messages. A match in what was said has
    /// a message, whatever count the row gave.
    public var isEmptyTaskRun: Bool {
        isTaskRun && messageCount == 0 && (role ?? "").isEmpty
    }
}

extension CronRun {
    /// A run Hermes lists with no messages that said nothing else: no output, no error. A count
    /// the row didn't give isn't taken for empty.
    public var isEmpty: Bool {
        messageCount == 0 && summary == nil && !failed
    }
}
