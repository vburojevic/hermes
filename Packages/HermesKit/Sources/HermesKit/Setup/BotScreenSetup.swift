import Foundation

extension GatewaySetup {
    /// Bot Screen (`docs/setup.md` §4.21): a Bot's own desktop on a Linux gateway, which the
    /// Inspector's Screen tab shows (`docs/inspector.md` §2.6). The gateway's packages decide
    /// whether it can run at all; each Bot starts its own. No row on a gateway that can't have one
    /// (macOS and Windows hosts use their own display) or that didn't say (an older Hermes).
    public static func botScreen(_ facts: GatewaySetupFacts) -> SetupStatus? {
        guard let status = facts.botScreen, status.supported else { return nil }
        let title = String(localized: "Bot Screen")
        if let missing = missingPackages(status, profile: nil, gatewayName: facts.gatewayName) {
            return SetupStatus(id: ID.botScreen, state: .notSetUp, title: title, detail: missing.detail, steps: missing.steps, docs: Docs.botScreen)
        }
        return SetupStatus(
            id: ID.botScreen, state: .ready, title: title,
            detail: String(localized: "Each Bot can have its own screen on \(facts.gatewayName), which you can watch and take over.")
        )
    }

    /// One Bot's screen, for its Screen tab: nil while it runs. Stopped, it offers Start Screen
    /// (`display.start`); without the packages, the steps that install them. `profile` is the
    /// Bot's (nil for the default one).
    public static func screen(_ status: BotScreenStatus, profile: String?, gatewayName: String) -> SetupStatus? {
        guard !status.running else { return nil }
        let title = String(localized: "Screen")
        guard status.supported else {
            return SetupStatus(
                id: ID.botScreen, state: .notSetUp, title: title,
                detail: String(localized: "\(gatewayName) isn't a Linux computer, so Hermes uses its own display there instead of a screen of its own."),
                docs: Docs.botScreen
            )
        }
        if let missing = missingPackages(status, profile: profile, gatewayName: gatewayName) {
            return SetupStatus(id: ID.botScreen, state: .notSetUp, title: title, detail: missing.detail, steps: missing.steps, docs: Docs.botScreen)
        }
        if let blocker = status.blocker {
            return SetupStatus(id: ID.botScreen, state: .notSetUp, title: title, detail: blocker, docs: Docs.botScreen)
        }
        return SetupStatus(
            id: ID.botScreen, state: .notSetUp, title: title,
            detail: String(localized: "The screen isn't running. Start it to watch what Hermes does there and take over when it needs you."),
            fix: SetupFix(title: String(localized: "Start Screen")),
            steps: [SetupStep(String(localized: "Or on \(gatewayName):"), command: command("start", profile: profile))],
            docs: Docs.botScreen
        )
    }

    /// The packages aren't on the host: what that means, and how to install them there.
    private static func missingPackages(_ status: BotScreenStatus, profile: String?, gatewayName: String) -> (detail: String, steps: [SetupStep])? {
        guard !status.installed else { return nil }
        var steps = [SetupStep(String(localized: "On \(gatewayName), install TigerVNC and the Xfce core:"),
                               command: status.installCommand ?? command("install", profile: profile))]
        steps.append(SetupStep(String(localized: "Then start the screen:"), command: command("start", profile: profile)))
        return (String(localized: "\(gatewayName) needs TigerVNC and the Xfce core to give a Bot its own screen."), steps)
    }

    private static func command(_ action: String, profile: String?) -> String {
        if let profile, !profile.isEmpty, profile != "default" { return "hermes -p \(profile) computer-use screen \(action)" }
        return "hermes computer-use screen \(action)"
    }
}
