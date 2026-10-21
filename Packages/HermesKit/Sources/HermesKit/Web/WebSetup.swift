import Foundation

// Hermes on the web in Settings → Setup (`docs/setup.md` §4.19, `docs/web.md` §8).

extension GatewaySetup.ID {
    public static let passwords = "passwords"
    public static let browser = "browser"
}

extension GatewaySetup.Docs {
    public static let passwords = HermesDocs.page("user-guide/features/credential-vault")
    public static let browser = HermesDocs.page("user-guide/features/browser")
}

extension GatewaySetup {
    /// Passwords: Hermes's vault always works once Bot Mode is up; each manager whose CLI isn't
    /// on the gateway gets its install step, without counting as something to set up.
    public static func passwords(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Passwords")
        guard facts.botModeOnline else { return needsBotMode(id: ID.passwords, title: title, facts) }
        if facts.vaultMissing {
            return SetupStatus(
                id: ID.passwords, state: .notSetUp, title: title,
                detail: String(localized: "Needs a newer Hermes Agent on \(facts.gatewayName)."),
                steps: [SetupStep(String(localized: "On \(facts.gatewayName), update Hermes:"), command: "hermes update")],
                docs: Docs.updating
            )
        }
        guard let sources = facts.vaultSources else {
            return .unknown(id: ID.passwords, title: title, reason: String(localized: "Hermes didn't say where it finds logins."))
        }
        let inUse = sources.filter { $0.state != .notInstalled && $0.state != .off }.map(\.displayName)
        let steps = sources.filter { $0.state == .notInstalled }.compactMap { source -> SetupStep? in
            guard let command = source.installCommand, let cli = source.cli else { return nil }
            return SetupStep(String(localized: "To use your \(source.displayName) logins, install its CLI (\(cli)) on \(facts.gatewayName), then sign in to it there once:"), command: command)
        }
        return SetupStatus(
            id: ID.passwords, state: .ready, title: title,
            detail: inUse.formatted(.list(type: .and)),
            steps: steps, docs: Docs.passwords
        )
    }

    /// Browser: where Hermes browses is chosen on Bot Mode's backend (`PUT /api/config`), so it
    /// needs Bot Mode; once read, the place new chats use is the detail.
    public static func browser(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Browser")
        guard facts.botModeOnline else { return needsBotMode(id: ID.browser, title: title, facts) }
        guard let config = facts.config else {
            return .unknown(id: ID.browser, title: title, reason: String(localized: "Hermes didn't send its settings."))
        }
        let settings = BrowserSettings(config: config)
        if settings.extensionControl {
            return inAppBrowser(facts, title: title)
        }
        let detail: String = if let cloud = settings.cloud {
            String(localized: "In the cloud · \(BrowserSettings.cloudName(cloud))")
        } else if settings.useRealProfile {
            String(localized: "With your logins on \(facts.gatewayName)")
        } else {
            String(localized: "A browser on \(facts.gatewayName)")
        }
        return SetupStatus(id: ID.browser, state: .ready, title: title, detail: detail, docs: Docs.browser)
    }

    /// In this app: ready until a chat's registration is refused; then what would fix it, while
    /// Hermes browses with its own browser (a chat without a registered controller uses it).
    static func inAppBrowser(_ facts: GatewaySetupFacts, title: String) -> SetupStatus {
        let fallback = String(localized: "Meanwhile Hermes browses with its own browser on \(facts.gatewayName).")
        switch facts.inAppBrowserRefusal {
        case nil:
            return SetupStatus(id: ID.browser, state: .ready, title: title, detail: String(localized: "In this app"), docs: Docs.browser)
        case .needsNewerHermes?:
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "In this app needs a newer Hermes Agent on \(facts.gatewayName)."), fallback: fallback,
                               steps: [SetupStep(String(localized: "On \(facts.gatewayName), update Hermes:"), command: "hermes update")], docs: Docs.updating)
        // TODO(docs/web.md §9): Ready with Automatic sign-in, if Hermes ever lets a local internal
        // identity drive a browser.
        case .needsSignIn?:
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "Hermes lets only a signed-in app drive its browser, and Bot Mode on \(facts.gatewayName) signs in automatically."),
                               fallback: fallback,
                               steps: [SetupStep(String(localized: "Give the backend a sign-in: add these to ~/.hermes/.env on \(facts.gatewayName), restart it, then sign in with them in Edit Gateway:"),
                                                 command: "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=…\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=…\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=…")],
                               docs: Docs.botMode)
        case .needsAPIKey?:
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "\(facts.gatewayName)'s API server has no key, and Hermes lets only an app with the key drive its browser."), fallback: fallback,
                               steps: [SetupStep(String(localized: "On \(facts.gatewayName), set a key for the API server, then add it to this gateway in Edit Gateway:"), command: "API_SERVER_KEY=…")], docs: Docs.browser)
        case .keyRefused?:
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "\(facts.gatewayName) didn't accept this app's key for its browser."), fallback: fallback,
                               steps: [SetupStep(String(localized: "Check the gateway's key in Edit Gateway; it's API_SERVER_KEY on \(facts.gatewayName)."))], docs: Docs.browser)
        case .turnedOff?:
            // The Browser page says In this app, Hermes says the switch is off (edited by hand, or another profile).
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "In this app is off on \(facts.gatewayName)."), fallback: fallback,
                               steps: [SetupStep(String(localized: "Choose In this app on the Browser page again."))], docs: Docs.browser)
        case .other(let message)?:
            return SetupStatus(id: ID.browser, state: .limited, title: title,
                               detail: String(localized: "Hermes didn't let this app be its browser: \(message)"), fallback: fallback, docs: Docs.browser)
        case .unknownSession?:
            // The chat wasn't stored yet; its next turn registers again.
            return SetupStatus(id: ID.browser, state: .ready, title: title, detail: String(localized: "In this app"), docs: Docs.browser)
        }
    }
}
