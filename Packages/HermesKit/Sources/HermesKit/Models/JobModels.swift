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

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, skills, enabled, state, schedule, deliver
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
    /// The last run failed, or Hermes wouldn't start it for want of setup (`blocked_config`).
    public var hasFailed: Bool { state == "error" || lastStatus == "error" || lastStatus == "blocked_config" }
    /// The last run worked, but its results didn't arrive where they go (`docs/setup.md` §4.11).
    public var deliveryFailed: Bool { !hasFailed && (lastStatus == "delivery_failed" || lastDeliveryError != nil) }
    /// A scheduled run couldn't be handed to the runner; cleared by the next run that works.
    public var missedRun: Bool { lastFireError?.isEmpty == false }
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

    public var id: String { sessionID ?? "\(startedAt?.timeIntervalSince1970 ?? 0)" }

    /// How long it ran.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    public init(sessionID: String?, startedAt: Date?, endedAt: Date? = nil, summary: String? = nil, failed: Bool = false, error: String? = nil) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.failed = failed
        self.error = error
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
            error: error.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
