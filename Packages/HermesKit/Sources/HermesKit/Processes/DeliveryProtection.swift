import Foundation

/// Whether a gateway's Hermes keeps a Bot's message to another Bot going when the sender's chat
/// closes (`docs/setup.md`, Bot-to-Bot replies). Hermes delivers `message_agent` through a
/// background process of the sender's chat; without `persist_on_release` on it, closing that chat
/// (the dashboard closes it once its turn ends with no app connected) stops the receiving Bot's
/// turn, and its reply is lost (upstream issue #134898, pull request #136220). Read from the
/// deliveries `process.list` shows, for the Hermes version they were seen on.
public struct DeliveryProtection: Sendable, Equatable, Codable {
    /// The Hermes Agent version the deliveries ran on.
    public var version: String
    /// They outlive the sender's chat (`persist_on_release`).
    public var protected: Bool

    /// The first Hermes Agent release whose deliveries survive the sender's chat closing, once
    /// upstream ships the fix. Until then Setup offers no update for it.
    public static let botDeliveryFixedIn: String? = nil

    public init(version: String, protected: Bool) {
        self.version = version
        self.protected = protected
    }

    /// What one look at a chat's processes shows: nil when none is a delivery to another Bot.
    /// One unprotected delivery decides it (a local fix undone by an update shows at once).
    public static func seen(in processes: [BackgroundProcess], version: String) -> DeliveryProtection? {
        let deliveries = processes.filter(\.isBotDelivery)
        guard !deliveries.isEmpty else { return nil }
        return DeliveryProtection(version: version, protected: deliveries.allSatisfy(\.persistsOnRelease))
    }

    /// The record after a look: the latest delivery seen on this version counts, and a record
    /// from another version is dropped (an update may have changed it).
    public static func updated(_ record: DeliveryProtection?, seen: DeliveryProtection?, version: String) -> DeliveryProtection? {
        seen ?? (record?.version == version ? record : nil)
    }
}
