import Foundation

/// Why Bot Mode can't sign in at an address, as the warm card that says so (`docs/setup.md`
/// §4.1): in Edit Gateway while the address is checked (`botModeNotBackend`,
/// `botModeUnsupported`), and in Settings → Setup once Bot Mode stopped trying
/// (`botModeRefused`, `botModeWrongServer`).
public struct BotModeWarning: Hashable, Sendable {
    public var title: String
    public var body: String
    /// What to do on the computer running Hermes, in Markdown with the commands as code.
    public var steps: String?
    /// Where the answer came from: "From the backend at studio.local:9119".
    public var source: String
    /// The fix the app offers beside Check Again; none in Edit Gateway, where the fields are.
    public var fix: SetupFix?

    public init(title: String, body: String, steps: String? = nil, source: String, fix: SetupFix? = nil) {
        self.title = title
        self.body = body
        self.steps = steps
        self.source = source
        self.fix = fix
    }

    /// Edit Gateway's card for an address Bot Mode can't use, nil when it can (or didn't answer).
    /// An address that isn't Hermes at all has no card: the field's footer says so.
    /// `address` is how the person typed it: host, and port when there is one.
    public static func check(_ check: BackendCheck, address: String) -> BotModeWarning? {
        let startBackend = String(localized: "On the computer running Hermes, set `HERMES_DASHBOARD_SESSION_TOKEN` to a token of your choosing, then run `hermes serve --host 0.0.0.0`. Enter its address below and choose Session token.")
        switch check {
        case .apiServer:
            return BotModeWarning(
                title: String(localized: "This is the gateway, not Bot Mode's backend"),
                body: String(localized: "\(address) answered as Hermes's API server. Bot Mode needs the backend, which has its own address, usually port 9119."),
                steps: startBackend,
                source: String(localized: "From \(address)")
            )
        case .unsupported:
            return BotModeWarning(
                title: String(localized: "Bot Mode can't sign in to this backend"),
                body: String(localized: "This backend signs in only with Nous or single sign-on, which Bot Mode can't use. It needs a password or a session token."),
                steps: String(localized: "On the computer running Hermes, set `HERMES_DASHBOARD_SESSION_TOKEN` to a token of your choosing and restart it. Then check again and choose Session token."),
                source: String(localized: "From the backend at \(address)")
            )
        case .backend, .notHermes, .unreachable:
            return nil
        }
    }

    /// Settings → Setup's card once Bot Mode stopped trying, nil while it hasn't.
    public static func stopped(_ botMode: GatewaySetupFacts.BotMode) -> BotModeWarning? {
        switch botMode {
        case .refused(let address):
            return BotModeWarning(
                title: String(localized: "The backend refused Bot Mode's sign-in"),
                body: String(localized: "Check the username and password, or the session token. Bot Mode stopped trying until you do. Chats still work."),
                source: String(localized: "From the backend at \(address)"),
                fix: SetupFix(title: String(localized: "Edit Sign-In…"), action: .signIn)
            )
        case .wrongServer(let address):
            return BotModeWarning(
                title: String(localized: "Bot Mode's address is the gateway, not its backend"),
                body: String(localized: "\(address) answered as Hermes's API server, so the sign-in could never work. Bot Mode stopped trying. Chats still work."),
                source: String(localized: "From \(address)"),
                fix: SetupFix(title: String(localized: "Edit Backend…"), action: .linkBotMode)
            )
        default:
            return nil
        }
    }
}
