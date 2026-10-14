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
        deliver = try? c.decodeIfPresent(String.self, forKey: .deliver)
        let repeatInfo = try? c.decodeIfPresent(JSONValue.self, forKey: .repeatInfo)
        repeatTimes = repeatInfo?["times"]?.doubleValue.map { Int($0) }
        repeatCompleted = repeatInfo?["completed"]?.doubleValue.map { Int($0) }
    }

    /// Dates are ISO strings in the job store, but tolerate epoch numbers too.
    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return HermesDate.fromISO(text)
        }
        return HermesDate.fromEpoch(try? container.decodeIfPresent(Double.self, forKey: key))
    }

    public var isPaused: Bool { state == "paused" || !enabled }
    public var hasFailed: Bool { state == "error" || lastStatus == "error" }
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
    /// Hermes schedule syntax: `every 2h`, `in 30m`, `every 1d at 09:00`, or a cron expression.
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
