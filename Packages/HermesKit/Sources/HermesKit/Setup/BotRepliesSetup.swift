import Foundation

extension GatewaySetup {
    /// Bot-to-Bot replies (`docs/setup.md` §4.18): whether a Bot's message to another Bot outlives
    /// the sender's chat closing. Hermes 0.22 runs the delivery as a process of the sender's chat
    /// without `persist_on_release`, so reaping that chat kills it, and the other Bot's reply is
    /// lost. Nothing to set up for Bot-to-Bot itself, so the row is there only once the app has
    /// seen a delivery on this Hermes (`DeliveryProtection`); nil before.
    public static func botReplies(_ facts: GatewaySetupFacts,
                                  fixedIn: String? = DeliveryProtection.botDeliveryFixedIn) -> SetupStatus? {
        guard let record = facts.deliveryProtection else { return nil }
        let title = String(localized: "Bot-to-Bot Replies")
        if record.protected {
            return SetupStatus(id: ID.botReplies, state: .ready, title: title,
                               detail: String(localized: "A Bot's reply to another Bot survives the sender's chat closing."))
        }
        var fix: SetupFix?
        var steps: [SetupStep] = []
        if let fixedIn, !AppPlugin.version(record.version, isAtLeast: fixedIn) {
            fix = facts.update?.canApply == true ? SetupFix(title: String(localized: "Update Hermes…")) : nil
            steps = [SetupStep(String(localized: "Hermes \(fixedIn) fixes it. On \(facts.gatewayName):"),
                               command: facts.update?.updateCommand ?? "hermes update")]
        }
        return SetupStatus(
            id: ID.botReplies, state: .limited, title: title,
            detail: String(localized: "On this Hermes, a Bot's reply to another Bot can be lost when the sender's chat closes before it."),
            fallback: String(localized: "Keeping the app open while Bots reply to each other avoids it."),
            fix: fix, steps: steps, docs: Docs.botDeliveryFix
        )
    }
}
