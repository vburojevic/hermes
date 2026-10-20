import Foundation

/// What a paste into the composer becomes (docs/composer.md §5), from what the clipboard holds:
/// copied files attach as files, a picture attaches as a picture, text goes into the field.
public enum PastePlan: Equatable, Sendable {
    case files
    case images
    case text
    /// Nothing the composer takes itself: the text view's own paste.
    case system

    /// - Parameters:
    ///   - hasFiles: files copied in the Finder or the Files app.
    ///   - hasImages: picture data on the clipboard.
    ///   - text: the clipboard's plain text, if any.
    public static func plan(hasFiles: Bool, hasImages: Bool, text: String?) -> PastePlan {
        if hasFiles { return .files }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A browser's Copy Image leaves the picture's address alongside it: the picture is what
        // was copied. Text copied from a document can carry a picture of itself: the text wins.
        if hasImages, trimmed.isEmpty || isLink(trimmed) { return .images }
        if let text, !text.isEmpty { return .text }
        return .system
    }

    /// A lone web address or file path, which is all the text a copied picture carries.
    static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~/") { return true }
        guard let scheme = URL(string: text)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data", "blob"].contains(scheme)
    }
}
