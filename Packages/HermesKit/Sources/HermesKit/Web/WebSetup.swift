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
        let detail: String = if let cloud = settings.cloud {
            String(localized: "In the cloud · \(BrowserSettings.cloudName(cloud))")
        } else if settings.useRealProfile {
            String(localized: "With your logins on \(facts.gatewayName)")
        } else {
            String(localized: "A browser on \(facts.gatewayName)")
        }
        return SetupStatus(id: ID.browser, state: .ready, title: title, detail: detail, docs: Docs.browser)
    }
}
