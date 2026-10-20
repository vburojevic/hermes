import Foundation

/// Why an install didn't go through, in plain words, with Hermes's own message kept for the mono
/// line (`pluginInstallFailed`, `docs/plugins.md` §6). Hermes answers every install failure with
/// error 5026 and its message (`hermes_cli/plugins_cmd_install.py`, `plugins_cmd_catalog.py`).
public struct PluginInstallFailure: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The clone failed: no network, GitHub down, a timeout, no git.
        case unreachable
        /// The pinned commit isn't on GitHub anymore (its repository was rewritten): only a newer
        /// pin, from an update, installs it.
        case revisionGone
        /// On Hermes's kill list.
        case pulled(reason: String)
        /// Needs another OS.
        case platform(supported: String)
        /// Needs a newer Hermes.
        case hermesVersion(spec: String)
        /// An app it drives isn't on the gateway.
        case missingApp(String)
        /// Python packages Hermes didn't install (a forced replacement can't ask).
        case dependencies
        /// Its packages clash with Hermes's own.
        case dependencyConflict
        /// Hermes's security scan stopped it.
        case securityScan
        case other
    }

    public let reason: Reason
    /// Hermes's message, or its "Details:" part when there is one: shown in mono.
    public let detail: String

    public init(message: String) {
        detail = Self.detail(of: message)
        reason = Self.reason(of: message)
    }

    /// The sentence to show, naming the gateway.
    public func words(gateway: String) -> String {
        switch reason {
        case .unreachable: String(localized: "\(gateway) couldn’t download it from GitHub. Check that it’s online, then try again.")
        case .revisionGone: String(localized: "This version of the plugin is no longer on GitHub. Update the app or Hermes to get the current one.")
        case .pulled(let why): String(localized: "This plugin was pulled from the catalog: \(why)")
        case .platform(let supported): String(localized: "It runs on \(supported), not on \(gateway).")
        case .hermesVersion(let spec): String(localized: "It needs Hermes \(spec) on \(gateway). Update Hermes there, then try again.")
        case .missingApp(let app): String(localized: "It needs \(app) on \(gateway).")
        case .dependencies: String(localized: "It needs Python packages Hermes didn’t install.")
        case .dependencyConflict: String(localized: "Its Python packages clash with the ones Hermes uses, so Hermes left it off.")
        case .securityScan: String(localized: "Hermes’s security scan stopped it.")
        case .other: String(localized: "Hermes didn’t install it.")
        }
    }

    static func detail(of message: String) -> String {
        if let range = message.range(of: "\nDetails: ") {
            return String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reason(of message: String) -> Reason {
        let lower = message.lowercased()
        if lower.contains("could not download the plugin") || lower.contains("clone timed out")
            || lower.contains("git is not installed") || lower.contains("could not resolve host") {
            return .unreachable
        }
        // `_checkout_exact_revision`: "Git commit '<sha>' could not be fetched:" and git's own words.
        if lower.contains("could not be fetched") || lower.contains("not our ref") {
            return .revisionGone
        }
        if let range = message.range(of: "removed from the Hermes plugin catalog") {
            var why = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let colon = why.firstIndex(of: ":") { why = String(why[why.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
            if let removed = why.range(of: " (removed ") { why = String(why[..<removed.lowerBound]) }
            if let remove = why.range(of: " Remove it with") { why = String(why[..<remove.lowerBound]) }
            return .pulled(reason: why.isEmpty ? String(localized: "no reason given") : why)
        }
        if let range = message.range(of: "supported platforms: ") {
            let list = message[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            return .platform(supported: Self.platformWords(list))
        }
        if let range = message.range(of: " requires hermes ") {
            let spec = message[range.upperBound...].split(separator: ",").first.map(String.init) ?? ""
            return .hermesVersion(spec: spec.trimmingCharacters(in: .whitespaces))
        }
        if message.contains(" server '"), message.contains("' is unavailable") {
            let name = message.split(separator: "'").dropFirst().first.map(String.init) ?? ""
            return .missingApp(name)
        }
        if lower.contains("dependency install skipped") || lower.contains("install declined") {
            return .dependencies
        }
        if lower.contains("conflicts with the dependencies") {
            return .dependencyConflict
        }
        if lower.contains("security scan blocked") {
            return .securityScan
        }
        return .other
    }

    /// "windows, linux" → "Windows and Linux".
    public static func platformWords(_ list: String) -> String {
        let names = list.split(separator: ",").map { raw -> String in
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "macos", "darwin": "macOS"
            case "windows", "win32": "Windows"
            case "linux": "Linux"
            default: raw.trimmingCharacters(in: .whitespaces)
            }
        }
        return names.formatted(.list(type: .and))
    }
}
