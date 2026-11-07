import Foundation

/// Whether a chat takes the model Hermes reports for its session, so a model picked for the chat
/// on another device is the one this device's next message uses (`docs/sessions-and-models.md` §4).
///
/// The chat follows a report only when it is news: it differs from what this device last sent and
/// from what the same source last reported, and the person hasn't picked a model here since.
/// Hermes keeps a session's row on its first model while API server turns run on others, so a
/// row counts only once it moves, and a report that hasn't changed says nothing about another
/// device.
public struct ChatModelFollow: Sendable, Equatable {
    /// The session's model as Hermes reports it: `info.model` and `info.provider` over the socket
    /// (`tui_gateway/server.py` `_session_info`), or the `model` of the session's row, which
    /// carries no provider (`api_server.py` `_session_response`).
    public struct Report: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            /// The session's row in the chat list.
            case row
            /// The socket's session info: `session.resume`, `session.create` and `session.info`.
            case live
        }

        public var model: String
        public var provider: String?
        public var source: Source

        public init(model: String, provider: String? = nil, source: Source = .live) {
            self.model = model
            self.provider = provider
            self.source = source
        }
    }

    /// What this device last sent with a turn, set on the session or took from another device;
    /// `.some(nil)` is the gateway's default model.
    private var sent: ModelSelection??
    /// What each source last reported: the row and the socket can disagree for a while.
    private var seen: [Report.Source: Report] = [:]
    private var pickedHere = false
    /// Models Hermes fell back to in this chat: it reports them as the session's model until the
    /// next turn restores the primary, and they are never the person's pick.
    private var fallbacks: Set<String> = []

    public init() {}

    /// The person picked a model on this device: it wins for this device's next turn.
    public mutating func picked() {
        pickedHere = true
    }

    /// This device sent a turn with this model or set it on the session.
    public mutating func sent(_ selection: ModelSelection?) {
        sent = .some(selection)
        pickedHere = false
    }

    /// Hermes moved a turn onto a fallback model.
    public mutating func fellBack(to model: ModelSwitch.Model) {
        fallbacks.insert(model.name)
    }

    /// The model the chat should switch to for this report, or `nil` to keep its own.
    /// - Parameters:
    ///   - current: the chat's model now; `nil` is the gateway's default.
    ///   - options: the gateway's models, to name a provider when the report has none and to
    ///     know the default.
    ///   - turnRunning: a turn is running, so the report may name a fallback mid-switch.
    public mutating func reported(_ report: Report, current: ModelSelection?, options: ModelOptions?,
                                  turnRunning: Bool = false) -> ModelSelection? {
        let model = report.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // The API server's virtual model is no model at all.
        guard !turnRunning, !model.isEmpty, model != "hermes-agent" else { return nil }
        let provider = report.provider.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let report = Report(model: model, provider: provider, source: report.source)
        if let previous = seen[report.source] {
            if Self.same(report, previous) { return nil }
        } else if report.source == .row {
            // A row keeps the session's first model while API server turns run on others, so the
            // first one seen is only where it stands; the socket's info is the live agent's model.
            return keep(report)
        }
        // A report that can't be read yet (the gateway's models aren't known) isn't kept as seen,
        // so it counts once it can be.
        if isFallback(model) { return keep(report) }
        if case .some(let sent) = sent {
            guard let same = matches(report, sent, options: options) else { return nil }
            if same { return keep(report) }
        }
        if pickedHere { return keep(report) }
        guard let same = matches(report, current, options: options) else { return nil }
        if same { return keep(report) }
        guard let selection = selection(for: report, current: current, options: options) else { return nil }
        seen[report.source] = report
        // The model taken is what this device now runs on, so the other device switching back to
        // this device's earlier pick is news too.
        sent = .some(selection)
        return selection
    }

    /// Notes the report as seen and keeps the chat's model.
    private mutating func keep(_ report: Report) -> ModelSelection? {
        seen[report.source] = report
        return nil
    }

    private func isFallback(_ model: String) -> Bool {
        fallbacks.contains(model) || fallbacks.contains(ModelSelection(provider: "", model: model).shortName)
    }

    /// Two reports name the same model; a missing provider matches any.
    private static func same(_ a: Report, _ b: Report) -> Bool {
        a.model == b.model && (a.provider == nil || b.provider == nil || a.provider == b.provider)
    }

    /// The report names this selection, or `nil` when that can't be told yet: for the gateway's
    /// default it compares with the default the gateway lists.
    private func matches(_ report: Report, _ selection: ModelSelection?, options: ModelOptions?) -> Bool? {
        guard let selection else {
            guard let model = options?.model, !model.isEmpty else { return nil }
            return Self.same(report, Report(model: model, provider: options?.provider))
        }
        return Self.same(report, Report(model: selection.model, provider: selection.provider))
    }

    /// The report as a selection the chat can send. A row names no provider: the chat's own
    /// provider when it lists the model, else the first one that does.
    private func selection(for report: Report, current: ModelSelection?, options: ModelOptions?) -> ModelSelection? {
        if let provider = report.provider { return ModelSelection(provider: provider, model: report.model) }
        let providers = options?.providers ?? []
        if let current, providers.contains(where: { $0.slug == current.provider && $0.models.contains(report.model) }) {
            return ModelSelection(provider: current.provider, model: report.model)
        }
        let listing = providers.first { $0.isUsable && $0.models.contains(report.model) }
            ?? providers.first { $0.models.contains(report.model) }
        return listing.map { ModelSelection(provider: $0.slug, model: report.model) }
    }
}
