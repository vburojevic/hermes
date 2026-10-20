#if os(iOS)
import AppIntents
import Foundation

/// Deny / Allow Once on the Live Activity and in the Dynamic Island (`liveActivityNeedsYou`,
/// `islandExpanded`). Compiled into the widget for its buttons; the system runs it in the app,
/// which answers the gateway. Face ID first: an approval is never one glance from the Lock Screen.
struct AnswerFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Hermes"
    static let description = IntentDescription("Allows or denies the command Hermes is waiting on.")
    static let isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Gateway") var gatewayID: String
    @Parameter(title: "Chat") var sessionID: String
    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}

    init(gatewayID: UUID, sessionID: String, requestID: String, allow: Bool) {
        self.gatewayID = gatewayID.uuidString
        self.sessionID = sessionID
        self.requestID = requestID
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        #if !HERMES_WIDGET
        await ActivityAnswering.answer(gatewayID: UUID(uuidString: gatewayID), sessionID: sessionID, requestID: requestID, allow: allow)
        #endif
        return .result()
    }
}
#endif
