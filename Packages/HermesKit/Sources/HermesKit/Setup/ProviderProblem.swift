import Foundation

/// A turn that failed on its model provider's credentials, or with no provider set up
/// (`docs/setup.md` §4.3): what the chat shows instead of the bare error, with the way to fix it.
///
/// Told by the gateway protocol's `error_surface` (`layer: "auth"`, with `auth_kind` and
/// `api_key_env`) and the `error` event's `code: provider_not_configured`; the API server only
/// says "Provider authentication failed" in its `run.failed` text, which Hermes keeps in English
/// for exactly this (`gateway/platforms/api_server.py`).
public struct ProviderProblem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// An OAuth or subscription sign-in that expired or was revoked.
        case signIn
        /// An API key that was refused; the variable it lives in, when Hermes says.
        case key(envVar: String?)
        /// No provider is set up at all.
        case notConfigured
    }

    public var kind: Kind
    /// Hermes's slug: "anthropic", "openai-codex".
    public var provider: String?
    /// "Anthropic", "OpenAI Codex".
    public var providerLabel: String?

    public init(kind: Kind, provider: String? = nil, providerLabel: String? = nil) {
        self.kind = kind
        self.provider = provider
        self.providerLabel = providerLabel
    }

    /// From `message.complete`'s `error_surface`.
    public static func from(surface: JSONValue?) -> ProviderProblem? {
        guard let surface, surface["layer"]?.stringValue == "auth" else { return nil }
        let provider = surface["provider"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let label = surface["provider_label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let kind: Kind = surface["auth_kind"]?.stringValue == "oauth"
            ? .signIn
            : .key(envVar: surface["api_key_env"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        return ProviderProblem(kind: kind, provider: provider, providerLabel: label)
    }

    /// From a failure's text, when the transport gives nothing else (the API server's
    /// `run.failed`).
    public static func from(message: String?) -> ProviderProblem? {
        guard let message, message.contains("Provider authentication failed") else { return nil }
        return ProviderProblem(kind: .key(envVar: nil))
    }

    /// Providers Hermes signs in to by device code from the app (`_DEVICE_CODE_STARTERS` in
    /// `hermes_cli/web_routers/oauth.py`); the rest sign in through their own CLI.
    public static let deviceCodeProviders: Set<String> = ["nous", "openai-codex", "minimax-oauth", "xai-oauth"]

    /// Sign In… can run from the app.
    public var signsInFromApp: Bool {
        guard case .signIn = kind, let provider else { return false }
        return Self.deviceCodeProviders.contains(provider)
    }

    private var name: String { providerLabel ?? provider ?? String(localized: "The model's provider") }

    /// What the chat shows: what happened, the fix the app can make, and the steps elsewhere.
    public func status(gatewayName: String) -> SetupStatus {
        let id = GatewaySetup.ID.models
        let title = String(localized: "Models")
        switch kind {
        case .notConfigured:
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "Hermes on \(gatewayName) has no model provider, so it can't answer."),
                fix: SetupFix(title: String(localized: "Choose a Provider…")),
                steps: [SetupStep(String(localized: "Or on \(gatewayName), choose one:"), command: "hermes model")],
                docs: GatewaySetup.Docs.providers
            )
        case .signIn:
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "\(name) needs you to sign in again: its sign-in expired or was revoked."),
                fix: signsInFromApp ? SetupFix(title: String(localized: "Sign In…")) : nil,
                steps: [SetupStep(String(localized: "On \(gatewayName), sign in again:"), command: provider.map { "hermes auth add \($0) --type oauth" } ?? "hermes model")],
                docs: GatewaySetup.Docs.providers
            )
        case .key(let envVar):
            var steps = [SetupStep(String(localized: "Or on \(gatewayName), add a new key:"), command: provider.map { "hermes auth add \($0) --type api-key" } ?? "hermes model")]
            if let envVar {
                steps.append(SetupStep(String(localized: "It lives in ~/.hermes/.env as \(envVar).")))
            }
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "\(name) refused Hermes's key."),
                fix: provider == nil ? nil : SetupFix(title: String(localized: "Add Key…")),
                steps: steps,
                docs: GatewaySetup.Docs.providers
            )
        }
    }
}
