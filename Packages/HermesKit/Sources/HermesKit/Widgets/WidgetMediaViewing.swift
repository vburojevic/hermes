import Foundation

/// A file that opens as media rather than as text: a picture, or a video the gateway streams
/// (docs/widgets.md §9, docs/inspector.md §2.8).
public struct MediaFileType: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case picture
        case video
    }

    public let kind: Kind
    public let mimeType: String
    /// The uniform type AVFoundation is told the bytes are, when a resource loader answers for them.
    public let uniformType: String
    /// The name the File tab's footer gives it: "JPEG", "MPEG-4 video".
    public let name: String

    /// Videos are only the ones Hermes streams (`/api/files/stream` answers 415 for any other
    /// suffix) and the system player plays: MPEG-4 and QuickTime.
    private static let byExtension: [String: MediaFileType] = [
        "jpg": .init(kind: .picture, mimeType: "image/jpeg", uniformType: "public.jpeg", name: "JPEG"),
        "jpeg": .init(kind: .picture, mimeType: "image/jpeg", uniformType: "public.jpeg", name: "JPEG"),
        "png": .init(kind: .picture, mimeType: "image/png", uniformType: "public.png", name: "PNG"),
        "gif": .init(kind: .picture, mimeType: "image/gif", uniformType: "com.compuserve.gif", name: "GIF"),
        "heic": .init(kind: .picture, mimeType: "image/heic", uniformType: "public.heic", name: "HEIC"),
        "heif": .init(kind: .picture, mimeType: "image/heif", uniformType: "public.heif", name: "HEIF"),
        "webp": .init(kind: .picture, mimeType: "image/webp", uniformType: "org.webmproject.webp", name: "WebP"),
        "tif": .init(kind: .picture, mimeType: "image/tiff", uniformType: "public.tiff", name: "TIFF"),
        "tiff": .init(kind: .picture, mimeType: "image/tiff", uniformType: "public.tiff", name: "TIFF"),
        "mp4": .init(kind: .video, mimeType: "video/mp4", uniformType: "public.mpeg-4", name: "MPEG-4 video"),
        "mov": .init(kind: .video, mimeType: "video/quicktime", uniformType: "com.apple.quicktime-movie", name: "QuickTime video"),
    ]

    private init(kind: Kind, mimeType: String, uniformType: String, name: String) {
        self.kind = kind
        self.mimeType = mimeType
        self.uniformType = uniformType
        self.name = name
    }

    /// The type a file path names by its extension; nil when it isn't a picture or a video the
    /// app opens. A `hermes-file:` address or an https URL's path work too.
    public init?(path: String) {
        var name = Substring(path)
        if let slash = name.lastIndex(of: "/") { name = name[name.index(after: slash)...] }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              let type = Self.byExtension[name[name.index(after: dot)...].lowercased()]
        else { return nil }
        self = type
    }

    /// The type a server named in its `Content-Type`, parameters ignored.
    public init?(mimeType: String) {
        let bare = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard let type = Self.byExtension.values.first(where: { $0.mimeType == bare }) else { return nil }
        self = type
    }
}

/// What a media card's full-screen viewer pages through, and where it opens
/// (docs/widgets.md §9.1).
public enum MediaViewing {
    /// The largest picture or video the app opens, checked from the file's size before reading
    /// it. The app's own limit: Hermes's file routes have none, and what opens is held in memory
    /// only, never written to disk.
    public static let maxBytes: Int64 = 50_000_000

    /// How many items a grid card shows; the last one shown carries "+N" for the rest.
    public static let gridShows = 4

    /// The items the viewer pages through, in the card's order: its pictures and videos. A voice
    /// note plays in its row and never opens here.
    public static func items(of widget: MediaWidget) -> [MediaWidget.Item] {
        widget.items.filter { $0.media.kind != .audio }
    }

    /// The page a tap on the card's item at `index` opens. The grid's "+N" tile opens at the
    /// first item the grid doesn't show (`moreTile: true`).
    public static func startPage(tapping index: Int, in widget: MediaWidget, moreTile: Bool = false) -> Int {
        let target = moreTile ? gridShows : index
        guard widget.items.indices.contains(target) else { return 0 }
        return widget.items[..<target].filter { $0.media.kind != .audio }.count
    }

    /// "4 of 12", or nil for a viewer with one item, which shows no position.
    public static func position(_ page: Int, of count: Int) -> (current: Int, total: Int)? {
        guard count > 1, (0..<count).contains(page) else { return nil }
        return (page + 1, count)
    }

    /// A video's length as a clock: "0:42", "12:05", "1:02:09".
    public static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let hours = whole / 3600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// The File tab's footer for a media file: "JPEG · 4,032 × 3,024 · 3.1 MB",
    /// "MPEG-4 video · 1,920 × 1,080 · 0:42 · 18.4 MB". A part not known yet is left out.
    public static func summary(_ type: MediaFileType, width: Int?, height: Int?, duration: Double?, bytes: Int64?,
                               locale: Locale = .current) -> String {
        var parts = [type.name]
        if let width, let height, width > 0, height > 0 {
            let style = IntegerFormatStyle<Int>(locale: locale)
            parts.append("\(width.formatted(style)) × \(height.formatted(style))")
        }
        if type.kind == .video, let duration, duration > 0 { parts.append(clock(duration)) }
        if let bytes, bytes > 0 { parts.append(bytes.formatted(.byteCount(style: .file).locale(locale))) }
        return parts.joined(separator: " · ")
    }
}

/// A picture or video over `MediaViewing.maxBytes`, found from its size before reading it.
public struct MediaTooBig: Error, Sendable, Equatable {
    public let bytes: Int64

    public init(bytes: Int64) { self.bytes = bytes }
}

/// One stretch of a file, both ends included, as HTTP's Range header counts it.
public struct ByteRange: Sendable, Hashable {
    public let start: Int64
    public let end: Int64

    public var length: Int64 { end - start + 1 }
    /// `bytes=0-1023`.
    public var header: String { "bytes=\(start)-\(end)" }

    public init?(offset: Int64, length: Int64) {
        guard offset >= 0, length > 0 else { return nil }
        start = offset
        end = offset + length - 1
    }
}

/// A 206 answer's `Content-Range: bytes 0-1023/52428800` (or `/*` when the size isn't known).
public struct ContentRange: Sendable, Hashable {
    public let start: Int64
    public let end: Int64
    public let total: Int64?

    public init?(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = trimmed.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start else { return nil }
        if parts[1] == "*" {
            total = nil
        } else {
            guard let total = Int64(parts[1]), total > end else { return nil }
            self.total = total
        }
        self.start = start
        self.end = end
    }
}

/// Why a picture or video in the viewer or the File tab didn't open, each with the design's own
/// state (docs/widgets.md §9.2).
public enum MediaProblem: Sendable, Equatable {
    /// 404: the file isn't on the gateway anymore.
    case gone
    /// Over `MediaViewing.maxBytes`.
    case tooBig(bytes: Int64)
    /// 403: Hermes keeps files like this one private ("Access to sensitive files is not allowed").
    case notAllowed
    /// Anything else on the way to a picture: Try Again.
    case couldntLoad
    /// Anything else on the way to a video, a stream cut short included: Try Again.
    case couldntPlay
    /// No backend to read gateway files through.
    case needsBotMode

    /// What an error from `downloadPicture`, `fileStreamRange` or `RemoteMedia` means to the
    /// person. A 404 for a Bot profile that doesn't exist, or from a Hermes without the route,
    /// isn't the file being gone.
    public static func of(_ error: any Error, video: Bool) -> MediaProblem {
        let other: MediaProblem = video ? .couldntPlay : .couldntLoad
        switch error {
        case let error as MediaTooBig:
            return .tooBig(bytes: error.bytes)
        case BackendClient.Failure.http(404, let detail):
            if let detail, detail.hasPrefix("Profile ") || HermesVersionGap.isMissingRoute(detail) { return other }
            return .gone
        case BackendClient.Failure.http(403, _), RemotePicture.Failure.status(403):
            return .notAllowed
        case RemotePicture.Failure.status(404), RemotePicture.Failure.status(410):
            return .gone
        default:
            return other
        }
    }
}
