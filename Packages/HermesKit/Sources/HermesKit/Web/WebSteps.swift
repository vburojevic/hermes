import Foundation
import HermesPush

/// How a browser or Passwords step reads in a chat (`docs/web.md` §4, `signInStep`): the site and
/// where a login came from, never a username, password or code. Built from the call's arguments
/// and Hermes's JSON result (`tools/browser_vault_tool.py`, `tools/browser_tool.py`,
/// `tools/browser_use_cli.py`); nil for tools it doesn't cover, which keep `ToolDescriptor`.
public struct WebStep: Equatable, Sendable {
    public var title: String
    public var symbol: String
    /// The second line: a URL (monospaced), or where a login came from.
    public var preview: String?
    public var previewIsAddress = false
    /// What went wrong, in words; nil when it worked or is still running.
    public var failure: String?
    /// The person said no (didn't save, didn't fill): a quiet note, not a failure.
    public var declined = false

    public init(title: String, symbol: String, preview: String? = nil, previewIsAddress: Bool = false, failure: String? = nil, declined: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.preview = preview
        self.previewIsAddress = previewIsAddress
        self.failure = failure
        self.declined = declined
    }

    /// The tools whose arguments may hold what the person types: the step never shows them.
    public static func hidesArguments(_ name: String) -> Bool {
        name == "browser_type" || name == "browser_vault"
    }

    public static func describe(name: String, arguments: JSONValue?, result: String?, isRunning: Bool) -> WebStep? {
        let json = result.flatMap(ToolDisplayCache.json)
        switch name {
        case "browser_navigate":
            let url = arguments?["url"]?.stringValue ?? ""
            let site = Self.site(url) ?? String(localized: "a page")
            return WebStep(title: isRunning ? String(localized: "Opening \(site)") : String(localized: "Opened \(site)"),
                           symbol: "globe", preview: Self.shortURL(url), previewIsAddress: true,
                           failure: isRunning ? nil : genericFailure(json))
        case "browser_type":
            // The text is often the username Hermes types itself; it never shows in a step.
            return WebStep(title: isRunning ? String(localized: "Typing into the page") : String(localized: "Typed into the page"), symbol: "keyboard",
                           failure: isRunning ? nil : genericFailure(json))
        case "browser_exec":
            // Browser Use: the model opens each script with a one-line comment that says what it does.
            let title = comment(in: arguments?["code"]?.stringValue) ?? (isRunning ? String(localized: "Using the browser") : String(localized: "Used the browser"))
            return WebStep(title: title, symbol: "safari", failure: isRunning ? nil : genericFailure(json))
        case "browser_vault":
            return vault(arguments: arguments, json: json, isRunning: isRunning)
        default:
            return nil
        }
    }

    // MARK: Passwords

    private static func vault(arguments: JSONValue?, json: JSONValue?, isRunning: Bool) -> WebStep {
        let action = arguments?["action"]?.stringValue ?? "fill"
        let source = sourceName(handle: arguments?["handle"]?.stringValue, backend: json?["backend"]?.stringValue)
        let site = json?["origin"]?.stringValue.flatMap(VaultOrigin.site).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        var step: WebStep
        switch action {
        case "list":
            step = WebStep(title: isRunning ? String(localized: "Looking up your logins") : String(localized: "Looked up your logins"), symbol: "key")
        case "save_login":
            let label = arguments?["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? site
            step = WebStep(title: isRunning ? String(localized: "Asking you to save a login") : String(localized: "Saved a login for \(label ?? String(localized: "this site"))"),
                           symbol: "person.badge.key", preview: isRunning ? nil : String(localized: "In Hermes's vault · Hermes never saw the password"))
        case "enter_code":
            let from: String? = switch json?["source"]?.stringValue {
            case "user"?: String(localized: "From you")
            case VaultSource.hermesVault?: String(localized: "From your authenticator key")
            case let backend?: String(localized: "From \(sourceName(handle: nil, backend: backend) ?? backend)")
            case nil: nil
            }
            step = WebStep(title: isRunning ? String(localized: "Entering the 2FA code") : String(localized: "Entered the 2FA code"), symbol: "number.square", preview: from)
        case "unlock":
            let manager = sourceName(handle: nil, backend: arguments?["backend"]?.stringValue) ?? String(localized: "the password manager")
            step = WebStep(title: isRunning ? String(localized: "Unlocking \(manager)") : String(localized: "Unlocked \(manager)"), symbol: "lock.open")
        default:
            switch json?["kind"]?.stringValue {
            case "payment"?:
                step = WebStep(title: String(localized: "Filled your card on \(site ?? String(localized: "the page"))"), symbol: "creditcard",
                               preview: String(localized: "Hermes never saw the number"))
            case "address"?:
                step = WebStep(title: String(localized: "Filled your address on \(site ?? String(localized: "the page"))"), symbol: "house",
                               preview: source.map { String(localized: "From \($0)") })
            default:
                step = WebStep(title: isRunning ? String(localized: "Signing in") : String(localized: "Signed in to \(site ?? String(localized: "the site"))"), symbol: "key",
                               preview: isRunning ? nil : source.map { String(localized: "Your login from \($0) · Hermes never saw the password") })
            }
        }
        guard !isRunning, let json, json["success"]?.boolValue == false else { return step }
        step.preview = nil
        switch json["error_type"]?.stringValue {
        case "save_declined"?, "payment_declined"?:
            step.declined = true
            step.failure = String(localized: "Not filled.")
        case "code_declined"?:
            step.declined = true
            step.failure = String(localized: "No code entered.")
        case "unlock_cancelled"? where action == "unlock":
            step.declined = true
            step.failure = String(localized: "Kept locked.")
        case "origin_mismatch"?:
            step.title = String(localized: "Didn't sign in")
            step.failure = originMismatch(json["error"]?.stringValue)
        case "unlock_required"?, "unlock_cancelled"?, "unlock_failed"?:
            step.title = String(localized: "Didn't sign in")
            step.failure = String(localized: "\(source ?? String(localized: "The password manager")) is locked.")
        case "no_code_field"?:
            step.failure = String(localized: "Finish signing in on your device.")
        case "human_has_control"?:
            step.failure = String(localized: "You're in control of the browser; Hermes is waiting.")
        case "supervisor_required"?:
            step.title = String(localized: "Didn't sign in")
            step.failure = String(localized: "Passwords can't fill a page in this app's browser. It's your turn to sign in.")
        case "origin_changed"?:
            step.failure = String(localized: "The page changed before Hermes could fill it. Nothing was written.")
        case "no_origin"?:
            step.failure = String(localized: "It has no site saved with it, so Hermes can't fill it anywhere.")
        default:
            step.failure = String(localized: "Couldn't fill it.")
        }
        return step
    }

    /// "Your login is for github.com, not this page." from Hermes's refusal, which names the
    /// page's origin and the item's (never a secret).
    static func originMismatch(_ message: String?) -> String {
        guard let message, let range = message.range(of: "bound origin(s) (") else {
            return String(localized: "That login is for another site, not this page.")
        }
        let rest = message[range.upperBound...]
        let origins = rest.prefix { $0 != ")" }.split(separator: ",").compactMap { VaultOrigin.site(String($0).trimmingCharacters(in: .whitespaces)) }
        guard !origins.isEmpty else { return String(localized: "That login is for another site, not this page.") }
        return String(localized: "Your login is for \(origins.formatted(.list(type: .or))), not this page.")
    }

    /// "1Password" from an item handle (`op:…`, `bw:…`, `vault_…`) or a source name.
    static func sourceName(handle: String?, backend: String?) -> String? {
        let name = backend ?? handle.flatMap { handle -> String? in
            if handle.hasPrefix("op:") { return "onepassword" }
            if handle.hasPrefix("bw:") { return "bitwarden" }
            if handle.hasPrefix("vault_") { return VaultSource.hermesVault }
            return nil
        }
        switch name {
        case "onepassword"?: return String(localized: "1Password")
        case "bitwarden"?: return String(localized: "Bitwarden")
        case VaultSource.hermesVault?: return String(localized: "Hermes's vault")
        default: return nil
        }
    }

    private static func genericFailure(_ json: JSONValue?) -> String? {
        guard let json, json["success"]?.boolValue == false else { return nil }
        if json["error_type"]?.stringValue == "human_has_control" {
            return String(localized: "You're in control of the browser; Hermes is waiting.")
        }
        return json["error"]?.stringValue.map { String($0.prefix(200)) }
    }

    /// The first `# comment` line of a Browser Use script.
    static func comment(in code: String?) -> String? {
        guard let code else { return nil }
        for line in code.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(1).uppercased() + text.dropFirst().prefix(119)) }
        }
        return nil
    }

    /// "vercel.com".
    static func site(_ url: String) -> String? {
        let text = url.contains("://") ? url : "https://" + url
        guard let host = URLComponents(string: text)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "vercel.com/login": the address without its scheme, query or fragment.
    static func shortURL(_ url: String) -> String? {
        let text = url.contains("://") ? url : "https://" + url
        guard let components = URLComponents(string: text), let host = components.host else { return url.isEmpty ? nil : url }
        let path = components.path == "/" ? "" : components.path
        return host + path
    }
}

extension ApprovalRequest {
    /// A card fill (`docs/web.md` §4): answered only on its own card, with Face ID or Touch ID, Fill
    /// Card or Don't Fill, never Always and never from a notification, the dock, a batch or Talk.
    public var isPaymentFill: Bool {
        PaymentFill.isPaymentFill(command)
    }

    /// The card and page a fill names, when the command reads as Hermes writes it.
    public var paymentFill: PaymentFill? {
        PaymentFill(command: command)
    }
}
