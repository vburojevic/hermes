import Foundation

/// A method or route this gateway's Hermes Agent doesn't have yet (`docs/setup.md` §4.2): the
/// socket's -32601 "unknown method", the dashboard's 404 "No such API endpoint". Every feature
/// that meets one says the same thing, with the way to update.
public enum HermesVersionGap {
    public static var message: String {
        String(localized: "This needs a newer Hermes Agent on the gateway. Update it in Settings → Setup → Hermes Agent, or run hermes update there.")
    }

    public static func isMissing(_ error: any Error) -> Bool {
        switch error {
        case let error as GatewayRPCError: error.code == -32601
        case BackendClient.Failure.http(404, let detail?): isMissingRoute(detail)
        default: false
        }
    }

    /// The dashboard's catch-all for an `/api/*` path it has no route for
    /// (`hermes_cli/web_server_dashboard.py`), and the wording a proxy in front of an older
    /// dashboard uses.
    static func isMissingRoute(_ detail: String) -> Bool {
        let detail = detail.lowercased()
        return detail.contains("no such api endpoint") || detail.contains("endpoint is likely missing")
    }
}
