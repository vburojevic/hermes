import Foundation

/// A scheduled Hermes job (`/api/jobs`), shown in the app as a Task.
public struct CronJob: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var prompt: String
    public var scheduleDisplay: String
    public var skills: [String]
    public var enabled: Bool
    /// `scheduled`, `paused`, `running`, `completed`, `error` (open set).
    public var state: String
    public var pausedReason: String?
    public var createdAt: Date?
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    /// `ok`, `error`, … or `nil` before the first run.
    public var lastStatus: String?
    public var lastError: String?
    /// The run finished, but its results didn't reach `deliver` (`last_status: delivery_failed`).
    public var lastDeliveryError: String?
    /// A scheduled run that couldn't be started (`last_fire_error.detail`), until one runs.
    public var lastFireError: String?
    public var deliver: String?
    public var repeatTimes: Int?
    public var repeatCompleted: Int?
    /// The model the task runs on, when the job names one (`model`); `nil` means the gateway's default.
    public var model: String?
    /// When the run going on now started (`live_execution`), or `nil` when none is. Hermes has no
    /// running state for a job: a run in progress is a claimed or running execution row.
    public var runningSince: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, skills, enabled, state, schedule, deliver, model
        case liveExecution = "live_execution"
        case repeatInfo = "repeat"
        case scheduleDisplay = "schedule_display"
        case pausedReason = "paused_reason"
        case createdAt = "created_at"
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastStatus = "last_status"
        case lastError = "last_error"
        case lastDeliveryError = "last_delivery_error"
        case lastFireError = "last_fire_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Task"
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        let schedule = try? c.decodeIfPresent(JSONValue.self, forKey: .schedule)
        scheduleDisplay = (try? c.decodeIfPresent(String.self, forKey: .scheduleDisplay))
            ?? schedule?["display"]?.stringValue
            ?? schedule?.stringValue
            ?? ""
        skills = (try? c.decodeIfPresent([String].self, forKey: .skills)) ?? []
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? (enabled ? "scheduled" : "paused")
        pausedReason = try? c.decodeIfPresent(String.self, forKey: .pausedReason)
        createdAt = Self.date(c, .createdAt)
        nextRunAt = Self.date(c, .nextRunAt)
        lastRunAt = Self.date(c, .lastRunAt)
        lastStatus = try? c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        lastDeliveryError = (try? c.decodeIfPresent(String.self, forKey: .lastDeliveryError)).flatMap { $0.isEmpty ? nil : $0 }
        lastFireError = (try? c.decodeIfPresent(JSONValue.self, forKey: .lastFireError))?["detail"]?.stringValue
        deliver = try? c.decodeIfPresent(String.self, forKey: .deliver)
        let repeatInfo = try? c.decodeIfPresent(JSONValue.self, forKey: .repeatInfo)
        repeatTimes = repeatInfo?["times"]?.truncatedIntValue
        repeatCompleted = repeatInfo?["completed"]?.truncatedIntValue
        model = (try? c.decodeIfPresent(String.self, forKey: .model))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        runningSince = Self.liveStart(try? c.decodeIfPresent(JSONValue.self, forKey: .liveExecution))
    }

    /// The start of a live run: `started_at` once it runs, `claimed_at` while it is being handed to
    /// the runner. Any other status (or none) is no live run.
    static func liveStart(_ live: JSONValue?) -> Date? {
        guard let live, let status = live["status"]?.stringValue?.lowercased(),
              status == "running" || status == "claimed" else { return nil }
        return HermesDate.fromISO(live["started_at"]?.stringValue) ?? HermesDate.fromISO(live["claimed_at"]?.stringValue)
    }

    /// Dates are ISO strings in the job store, but tolerate epoch numbers too.
    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return HermesDate.fromISO(text)
        }
        return HermesDate.fromEpoch(try? container.decodeIfPresent(Double.self, forKey: key))
    }

    /// A task the gateway hasn't made yet: what New Task sent, shown until the gateway's answer
    /// replaces it (`docs/tasks.md` §1). Its next run comes with that answer.
    public init(making job: NewCronJob, id: String) {
        self.id = id
        name = job.name
        prompt = job.prompt
        scheduleDisplay = job.schedule
        skills = job.skills ?? []
        enabled = true
        state = "scheduled"
    }

    /// The task as it will be once the gateway has paused or resumed it. Resuming leaves the next
    /// run to the gateway's answer: the app never computes it.
    public func paused(_ paused: Bool) -> CronJob {
        var job = self
        job.enabled = !paused
        job.state = paused ? "paused" : "scheduled"
        job.pausedReason = nil
        job.nextRunAt = nil
        return job
    }

    public var isPaused: Bool { state == "paused" || !enabled }
    /// A run is going on now (`docs/tasks.md` §1).
    public var isRunning: Bool { runningSince != nil }
    /// The last run failed, or Hermes wouldn't start it for want of setup (`blocked_config`).
    public var hasFailed: Bool { state == "error" || lastStatus == "error" || lastStatus == "blocked_config" }
    /// The last run worked, but its results didn't arrive where they go (`docs/setup.md` §4.11).
    public var deliveryFailed: Bool { !hasFailed && (lastStatus == "delivery_failed" || lastDeliveryError != nil) }
    /// A scheduled run couldn't be handed to the runner; cleared by the next run that works.
    public var missedRun: Bool { lastFireError?.isEmpty == false }
    /// How many times it has run, for Recent runs (`docs/tasks.md` §4): what Hermes counts
    /// (`repeat.completed`), and the run going on now when Hermes hasn't counted it yet. A task
    /// that runs a set number of times is counted as its run starts (`cron/jobs.py`
    /// `claim_dispatch`), a recurring one as its run ends. Nil when Hermes doesn't count.
    public var runsCounted: Int? {
        guard let repeatCompleted else { return nil }
        return isRunning && repeatTimes == nil ? repeatCompleted + 1 : repeatCompleted
    }

    /// After Run Now, whether this read of the task shows the run it asked for. Hermes only marks
    /// the task due (`trigger_job`); its scheduler starts the run at its next tick, up to a minute
    /// later (`docs/tasks.md` §1). So the run shows once it is under way, as finished when it ran
    /// between two reads, or as a run the scheduler couldn't start. `before` is the task as it
    /// was when Run Now was sent.
    public func showsRun(askedOf before: CronJob) -> Bool {
        isRunning || lastRunAt != before.lastRunAt || repeatCompleted != before.repeatCompleted
            || lastStatus != before.lastStatus || lastFireError != before.lastFireError
    }

    /// What went wrong last, in Hermes's words.
    public var problem: String? {
        [lastFireError, lastDeliveryError, lastError].compactMap { $0 }.first { !$0.isEmpty }
    }
}

struct JobsEnvelope: Decodable {
    var jobs: [CronJob]

    enum CodingKeys: String, CodingKey { case jobs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = try c.decode([LossyElement<CronJob>].self, forKey: .jobs).compactMap(\.value)
    }
}

struct JobEnvelope: Decodable {
    var job: CronJob
}

/// Fields for creating a scheduled job.
public struct NewCronJob: Encodable, Sendable {
    public var name: String
    /// Hermes schedule syntax: `every 2h`, `in 30m`, `every day at 09:00`, `every weekday at 08:00`, or a
    /// cron expression. (`every 1d at 09:00` is refused: an interval takes no time of day.)
    public var schedule: String
    public var prompt: String
    public var skills: [String]?

    public init(name: String, schedule: String, prompt: String, skills: [String]? = nil) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.skills = skills
    }
}

/// One run of a task (`GET /api/cron/jobs/{id}/runs`, newest first). An agent run is a chat
/// (`cron_<jobId>_<timestamp>`, source `cron`) that opens like any other; a script-only run has
/// no chat, only its output.
public struct CronRun: Identifiable, Hashable, Sendable {
    /// The run's chat, when it has one.
    public var sessionID: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// What the run said: the chat's preview, or the script's output.
    public var summary: String?
    public var failed: Bool
    public var error: String?
    /// How many messages its chat has, when Hermes says (`message_count`).
    public var messageCount: Int?
    /// The profile whose store holds the run's chat (`profile`), when Hermes says.
    public var profile: String?

    public var id: String { sessionID ?? "\(startedAt?.timeIntervalSince1970 ?? 0)" }

    /// How long it ran.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// The run going on now, as the task's list reports it (`live_execution`). Set only by
    /// `withLiveRun`: a run with no end in the runs list alone can be one that never closed.
    public var isLive = false

    /// The task's recent runs with the run going on now at the top (`docs/tasks.md` §4). The
    /// runs list may already carry it (its chat started within a few minutes of the live run, with
    /// no end yet); otherwise it is added, so the list and the task's row agree that a run is
    /// under way. Finished runs keep their order.
    public static func withLiveRun(_ runs: [CronRun], runningSince: Date?) -> [CronRun] {
        guard let runningSince else { return runs }
        var runs = runs
        var live = CronRun(sessionID: nil, startedAt: runningSince)
        if let index = runs.firstIndex(where: { run in
            guard run.endedAt == nil, !run.failed, let started = run.startedAt else { return false }
            return abs(started.timeIntervalSince(runningSince)) < 300
        }) {
            live = runs.remove(at: index)
        }
        live.isLive = true
        return [live] + runs
    }

    public init(sessionID: String?, startedAt: Date?, endedAt: Date? = nil, summary: String? = nil, failed: Bool = false, error: String? = nil,
                messageCount: Int? = nil, profile: String? = nil) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.failed = failed
        self.error = error
        self.messageCount = messageCount
        self.profile = profile
    }

    /// The run's chat opens in Chats only when the gateway's own profile holds it: the app reads
    /// chats through the gateway, which can't open another profile's. A run of a Bot's routine is
    /// kept in the Bot's profile (`docs/tasks.md` §5). A run that names no profile is the
    /// gateway's own, as on a Hermes that doesn't say.
    public func opensAsChat(gatewayProfile: String?) -> Bool {
        guard sessionID != nil else { return false }
        guard let profile, !profile.isEmpty else { return true }
        return profile == (gatewayProfile ?? "default")
    }

    init(json: JSONValue) {
        func date(_ value: JSONValue?) -> Date? {
            if let seconds = value?.doubleValue { return HermesDate.fromEpoch(seconds) }
            return HermesDate.fromISO(value?.stringValue)
        }
        let status = (json["status"]?.stringValue ?? json["last_status"]?.stringValue ?? "").lowercased()
        let reason = (json["end_reason"]?.stringValue ?? "").lowercased()
        let error = json["error"]?.stringValue ?? json["last_error"]?.stringValue
        let id = json["id"]?.stringValue ?? json["session_id"]?.stringValue
        self.init(
            sessionID: (id?.isEmpty ?? true) || json["kind"]?.stringValue == "output" ? nil : id,
            startedAt: date(json["started_at"] ?? json["timestamp"] ?? json["ran_at"]),
            endedAt: date(json["ended_at"] ?? json["finished_at"]),
            summary: (json["summary"]?.stringValue ?? json["preview"]?.stringValue ?? json["output"]?.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            failed: ["error", "failed", "failure"].contains(status) || reason.contains("error") || reason.contains("fail") || (error?.isEmpty == false),
            error: error.flatMap { $0.isEmpty ? nil : $0 },
            messageCount: json["message_count"]?.truncatedIntValue,
            profile: json["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
