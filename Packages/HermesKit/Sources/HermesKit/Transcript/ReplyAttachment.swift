import CryptoKit
import Foundation

/// A file Hermes sent in a reply (`docs/chat.md` §3a): a `MEDIA:<path>` line on its own, outside
/// a code block, naming a file on the gateway. The reply's text keeps a plain note in its place
/// ("*Attachment on server: chart.png*"), which is what every plain-text use of the reply reads
/// (Copy, Listen, notifications, previews); only the chat draws the file there instead.
///
/// Audio is not one of these: it's split off first and plays in a listen strip (`AgentAudio`,
/// `docs/voice.md` §2).
public struct ReplyAttachment: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        /// Drawn in the reply; a tap opens the viewer.
        case picture
        /// Its first frame in the reply; a tap plays it in the viewer, streamed.
        case video
        /// A card whose Open shows it in the Inspector (`opens`).
        case document
        /// A card whose action saves a copy to the device.
        case file
    }

    public let path: String
    public let kind: Kind

    /// A `MEDIA:` path the chat can draw: absolute or in the home folder, ending in a file name
    /// with an extension, and not audio. A relative path, a folder or a bare name stays a note.
    public init?(path: String) {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), !path.hasPrefix("//"),
              !path.contains(where: \.isNewline) else { return nil }
        let name = Self.fileName(of: path)
        // A name with an extension of 1 to 10 letters or digits, not hidden (`.env`).
        guard name.first != ".", let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let suffix = ext.lowercased()
        guard !AgentAudio.extensions.contains(suffix) else { return nil }
        self.path = path
        if let media = MediaFileType(path: name) {
            kind = media.kind == .picture ? .picture : .video
        } else if GatewayFileOpening.destination(for: name) == .save {
            kind = .file
        } else {
            kind = .document
        }
    }

    /// "chart.png".
    public var fileName: String { Self.fileName(of: path) }

    /// "png", lowercased.
    public var suffix: String { Self.suffix(of: fileName) }

    /// The line the reply's text has in its place, for everything that reads the reply as text.
    public var note: String { Self.note(for: path) }

    /// Where Open shows a document; a picture or video opens in the viewer instead.
    public var opens: GatewayFileOpening.Destination { GatewayFileOpening.destination(for: fileName) }

    /// What the card calls the file: "PDF", "Markdown", "ZIP archive", else its extension.
    public var typeName: String {
        if let media = MediaFileType(path: fileName) { return media.name }
        return Self.typeNames[suffix] ?? suffix.uppercased()
    }

    /// A picture or video the viewer pages through.
    public var isVisual: Bool { kind == .picture || kind == .video }

    /// The file as the viewer reads a widget's media: its `hermes-file:` address
    /// (`WidgetFile.path` gives the path back), and the file's name for VoiceOver.
    public var media: WidgetMedia {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%#?")
        let address = WidgetFile.prefix + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
        return WidgetMedia(src: address, alt: fileName, kind: kind == .video ? .video : .image)
    }

    /// The largest file Save reads to keep a copy: it's held in memory until it's written where
    /// the person chose.
    public static let maxSaveBytes: Int64 = 100_000_000

    /// The pictures and videos a reply's viewer pages through, in the reply's order, from the
    /// segments it's drawn as.
    public static func viewerFiles(in segments: [ReplySegment]) -> [ReplyAttachment] {
        segments.flatMap { segment -> [ReplyAttachment] in
            if case .attachments(let files) = segment { files.filter(\.isVisual) } else { [] }
        }
    }

    private static let typeNames: [String: String] = [
        "pdf": "PDF", "md": "Markdown", "markdown": "Markdown", "txt": "Text", "text": "Text", "csv": "CSV",
        "tsv": "TSV", "json": "JSON", "jsonl": "JSON Lines", "yaml": "YAML", "yml": "YAML", "toml": "TOML",
        "xml": "XML", "html": "HTML page", "htm": "HTML page", "svg": "SVG", "log": "Log", "zip": "ZIP archive",
        "docx": "Word document", "xlsx": "Excel workbook", "pptx": "PowerPoint deck", "key": "Keynote deck",
        "pages": "Pages document", "numbers": "Numbers spreadsheet", "doc": "Word document", "xls": "Excel workbook",
        "ppt": "PowerPoint deck", "rtf": "Rich text", "odt": "OpenDocument text", "ods": "OpenDocument spreadsheet",
        "odp": "OpenDocument presentation",
    ]

    // MARK: Reading a reply

    /// The plain note for a `MEDIA:` path, as `TranscriptBuilder.cleanAssistantText` writes it.
    static func note(for path: String) -> String {
        "*Attachment on server: \(path.split(separator: "/").last.map(String.init) ?? path)*"
    }

    /// The files a reply's text sends, in order: each `MEDIA:` line outside a code block whose
    /// path the chat can draw (`init?(path:)`), read the way `AgentAudio.split` reads audio.
    /// Audio lines are left for `AgentAudio` and never returned.
    public static func parse(_ text: String) -> [ReplyAttachment] {
        guard text.containsBytes("MEDIA:") else { return [] }
        var found: [ReplyAttachment] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Asked of a streaming reply for each word: a line is looked at only when it starts
            // like a fence or a `MEDIA:` line.
            guard let first = line.first(where: { !$0.isWhitespace }), Self.mayStartLine(first) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            guard !inCode, let path = AgentAudio.mediaPath(trimmed), let attachment = ReplyAttachment(path: path) else { continue }
            found.append(attachment)
        }
        return found
    }

    /// A line's first character that could start a fence or a `MEDIA:` line (with its quotes).
    static func mayStartLine(_ character: Character) -> Bool {
        character == "M" || character == "`" || character == "\"" || character == "'" || character == "*" || character == "_"
    }

    /// A last line still arriving that may turn out to be a `MEDIA:` line: held back while the
    /// reply streams, so neither its raw path nor half a card ever shows.
    public static func mayBeArriving(_ line: Substring) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'*_"))
        guard let first = bare.first, first == "M" else { return false }
        return bare.hasPrefix("MEDIA:") || "MEDIA:".hasPrefix(bare)
    }

    /// A reply still streaming without a last line that may be a `MEDIA:` line on its way.
    public static func holdingBackArrival(_ text: String) -> String {
        guard !text.hasSuffix("\n") else { return text }
        let start = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        guard mayBeArriving(text[start...]) else { return text }
        return String(text[..<start])
    }

    private static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func suffix(of name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

/// Where a gateway file a reply names opens (`docs/inspector.md` §2): text and code in the File
/// tab, pages and PDFs in a Preview tab (`hermes-fs`, which shows an HTML file with its relative
/// files, a PDF or a picture), office documents in Quick Look (`docs/chat.md` §3a), and anything
/// else only as a copy saved to the device.
public enum GatewayFileOpening {
    public enum Destination: Sendable, Hashable {
        case fileTab
        case preview
        /// A copy read on the person's tap, shown by the system's Quick Look and deleted when it
        /// closes (`QuickLookCopy`).
        case quickLook
        case save
    }

    /// Word, Excel and PowerPoint, rich text and iWork files: what Quick Look draws everywhere. Of
    /// OpenDocument it draws only text, and only on the Mac; the rest keeps Save.
    static let quickLooked: Set<String> = {
        var suffixes: Set<String> = ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "rtf", "pages", "numbers", "key"]
        #if os(macOS)
        suffixes.insert("odt")
        #endif
        return suffixes
    }()

    /// Shown by the Preview tab: a page, a PDF, or a picture the File tab doesn't draw.
    static let previewed: Set<String> = ["pdf", "html", "htm", "svg", "bmp"]

    /// Read as text by the File tab (`/api/fs/read-text`).
    static let textual: Set<String> = [
        "md", "markdown", "mdx", "txt", "text", "rst", "csv", "tsv", "json", "jsonl", "ndjson", "yaml", "yml", "toml",
        "xml", "ini", "cfg", "conf", "log", "diff", "patch", "tex", "bib",
        "swift", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cc",
        "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "ps1", "sql", "css", "scss", "sass", "less",
        "vue", "svelte", "lua", "r", "pl", "ex", "exs", "erl", "hs", "scala", "dart", "gradle", "proto", "graphql",
        "ipynb",
    ]

    /// Where a file by this name opens. A picture or video the File tab draws goes there too.
    public static func destination(for path: String) -> Destination {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .save }
        let suffix = name[name.index(after: dot)...].lowercased()
        if previewed.contains(suffix) { return .preview }
        if quickLooked.contains(suffix) { return .quickLook }
        if textual.contains(suffix) || MediaFileType(path: name) != nil { return .fileTab }
        return .save
    }

    /// A reply's link to a gateway file (`GatewayFileLink`) opens in a Preview tab rather than
    /// the File tab, which can't show it: a PDF or a page.
    public static func opensInPreview(_ path: String) -> Bool {
        destination(for: path) == .preview
    }
}

/// Where the copy of a file opened in Quick Look is kept while it shows (`docs/chat.md` §3a): a
/// folder of its own in the app's caches, named for the gateway path and the Bot profile it was
/// read with, so two Bots' files of the same name never meet, holding the file under its own name
/// (Quick Look reads the type from it). The folder is deleted when the preview closes.
public enum QuickLookCopy {
    /// The caches folder the copies live under.
    public static let folder = "Quick Look"

    /// The copy's folder: a digest of the profile and the path, never the path itself.
    public static func folderName(path: String, profile: String?) -> String {
        let digest = SHA256.hash(data: Data("\(profile ?? "")\u{0}\(path)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The copy's own name: the file's, as a single safe path component.
    public static func fileName(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        var name = String(last.map { $0 == ":" || $0.isNewline || $0 == "\\" ? "_" : $0 })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120, let dot = name.lastIndex(of: ".") {
            let ext = name[dot...]
            name = String(name.prefix(120 - ext.count)) + ext
        }
        return name.isEmpty ? "file" : name
    }
}
