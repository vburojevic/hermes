import Foundation

/// A widget's `hermes-file:` address (`$defs/Url`): a file in the Bot's workspace on the gateway.
/// Open shows it in the Inspector and a picture loads from it, so both name the same file
/// (docs/widgets.md §9).
public enum WidgetFile {
    static let prefix = "hermes-file:"

    /// The path an address names, as Open reads it: without `hermes-file:` and a `#L42` fragment,
    /// percent-decoded. Nil for another scheme, an empty path, or one with a `..` step: the
    /// contract allows none, and a picture never reads above the folder it names.
    public static func path(_ address: String) -> String? {
        guard address.count > prefix.count, address.prefix(prefix.count).lowercased() == prefix else { return nil }
        var rest = address.dropFirst(prefix.count)
        // The fragment goes before decoding, so a name with an encoded # (%23) keeps it.
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        guard !decoded.isEmpty, !decoded.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return decoded
    }

    /// The path the gateway reads: an absolute or home path as it is, as Open keeps it, and a
    /// relative one joined onto `folder` (the chat's working folder). Nil for a relative path with
    /// no folder: the gateway would read it from wherever it was started.
    public static func resolve(_ address: String, in folder: String?) -> String? {
        guard let path = path(address) else { return nil }
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        guard let folder, !folder.isEmpty else { return nil }
        var relative = Substring(path)
        while relative.hasPrefix("./") { relative = relative.dropFirst(2) }
        guard !relative.isEmpty else { return nil }
        return (folder.hasSuffix("/") ? String(folder.dropLast()) : folder) + "/" + relative
    }
}
