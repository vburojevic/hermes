import Foundation

// TODO(docs/web.md §9): read a dedicated card-fill request kind once Hermes sends one.
/// A card fill waiting for the person's OK (`docs/web.md` §4, `approvalPayment`). Hermes asks with
/// a generic approval: the command "Fill payment card '<label>' on <origin>" with the pattern key
/// `mcp_elicitation` (`tools/browser_vault_tool.py` `_confirm_payment_fill`); its `vault-payment`
/// surface reaches the app only inside a push notice (the plugin hears it). So the command tells
/// it apart. A request that only looks
/// like one gets the stricter card (Face ID, never Always, never from a notification), which
/// costs nothing; a real one never gets anything less.
public struct PaymentFill: Equatable, Sendable {
    /// The card's name in Hermes's vault ("Personal Visa"): never its number.
    public let label: String
    /// The page it would be filled into, `scheme://host[:port]`.
    public let origin: String

    static let prefix = "Fill payment card '"
    /// The approval surface Hermes names for it; it reaches the app only inside a push notice.
    public static let surface = "vault-payment"

    public init?(command: String?) {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), command.hasPrefix(Self.prefix),
              let separator = command.range(of: "' on ", options: .backwards), separator.lowerBound >= command.index(command.startIndex, offsetBy: Self.prefix.count) else { return nil }
        let label = String(command[command.index(command.startIndex, offsetBy: Self.prefix.count)..<separator.lowerBound])
        let origin = String(command[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !origin.isEmpty, !origin.contains(where: \.isWhitespace) else { return nil }
        self.label = label
        self.origin = origin
    }

    /// "amazon.com": the page's host without `www.`.
    public var site: String {
        let host = URLComponents(string: origin)?.host ?? origin
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether a command is a card fill at all: anything starting the way Hermes's does.
    public static func isPaymentFill(_ command: String?) -> Bool {
        command?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) ?? false
    }
}
