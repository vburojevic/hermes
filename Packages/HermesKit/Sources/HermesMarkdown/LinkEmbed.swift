import Foundation

/// A link a reply shows as a card: a paragraph that is only a link to a video, some music or a
/// GitHub page the app knows by its address (`docs/chat.md` §3d). Everything on the card comes from
/// the address and the reply's own words: nothing is fetched to make it, so showing a reply tells
/// no service it was read.
///
/// The address must be https on the service's own host, matched whole, so `github.com.evil.example`
/// or `youtube.com@evil.example` stays a plain link, and its parts must be the plain characters the
/// service writes ids with, so nothing on the card can be reordered or disguised.
public struct LinkEmbed: Hashable, Sendable {
    public enum Service: String, Hashable, Sendable, CaseIterable {
        case youtube, vimeo, spotify, soundcloud, github, bilibili

        /// The service's own name, the same in every language.
        public var name: String {
            switch self {
            case .youtube: "YouTube"
            case .vimeo: "Vimeo"
            case .spotify: "Spotify"
            case .soundcloud: "SoundCloud"
            case .github: "GitHub"
            case .bilibili: "Bilibili"
            }
        }
    }

    public enum Kind: Hashable, Sendable {
        case video, short, live, playlist
        case track, album, artist, episode, show
        case repository, issue(Int), pullRequest(Int), discussion(Int)
    }

    public var service: Service
    public var kind: Kind
    /// What the address itself says it is: `owner/repository` on GitHub, `artist/track` on
    /// SoundCloud, the video's id on Bilibili; nil where it's an id nobody reads.
    public var name: String?
    /// The link's words, when the reply gave it any besides the address.
    public var label: String?
    /// The address as the reply wrote it.
    public var url: URL

    /// The card a paragraph is, or nil when it's anything but one link to a known page.
    public init?(_ block: MarkdownBlock) {
        guard case .paragraph(let inlines) = block else { return nil }
        self.init(inlines)
    }

    init?(_ inlines: [MarkdownInline]) {
        // Most paragraphs stop here, at their first words.
        var link: (destination: String, content: [MarkdownInline])?
        for inline in inlines {
            switch inline {
            case .softBreak, .lineBreak:
                continue
            case .text(let text) where text.allSatisfy(\.isWhitespace):
                continue
            case .link(let destination?, let content) where link == nil:
                link = (destination, content)
            default:
                return nil
            }
        }
        guard let link, let embed = LinkEmbed(address: link.destination) else { return nil }
        self = embed
        let words = link.content.map(\.plainText).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // The address written out, whole or without its https, isn't a title.
        let bare = words.lowercased()
        if !words.isEmpty, !bare.hasPrefix("http://"), !bare.hasPrefix("https://"), !bare.hasPrefix("www."),
           !link.destination.lowercased().hasSuffix(bare) {
            label = words
        }
    }

    /// The card an address makes by itself.
    public init?(address: String) {
        guard address.utf8.count <= 2048, let parts = URLComponents(string: address), let url = parts.url,
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased() else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/").map(String.init)
        // An escaped character is never part of an id.
        guard path.allSatisfy(Self.isPlain) else { return nil }
        let query = parts.queryItems ?? []
        guard let found = Self.classify(host: host, path: path, query: query) else { return nil }
        self.init(service: found.0, kind: found.1, name: found.2, label: nil, url: url)
    }

    init(service: Service, kind: Kind, name: String?, label: String?, url: URL) {
        self.service = service
        self.kind = kind
        self.name = name
        self.label = label
        self.url = url
    }

    private static func classify(host: String, path: [String], query: [URLQueryItem]) -> (Service, Kind, String?)? {
        switch host {
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "www.youtube-nocookie.com":
            return youtube(path, query)
        case "youtu.be":
            guard path.count == 1, isYouTubeID(path[0]) else { return nil }
            return (.youtube, .video, nil)
        case "vimeo.com", "www.vimeo.com":
            // A private video's address has its key after the number.
            guard (1...2).contains(path.count), isNumber(path[0]), path.count == 1 || isHex(path[1]) else { return nil }
            return (.vimeo, .video, nil)
        case "player.vimeo.com":
            guard path.count == 2, path[0] == "video", isNumber(path[1]) else { return nil }
            return (.vimeo, .video, nil)
        case "open.spotify.com":
            return spotify(path)
        case "soundcloud.com", "www.soundcloud.com", "m.soundcloud.com":
            return soundcloud(path)
        case "github.com", "www.github.com":
            return github(path)
        case "bilibili.com", "www.bilibili.com", "m.bilibili.com":
            guard path.count == 2, path[0] == "video", isBilibiliID(path[1]) else { return nil }
            return (.bilibili, .video, path[1])
        default:
            return nil
        }
    }

    private static func youtube(_ path: [String], _ query: [URLQueryItem]) -> (Service, Kind, String?)? {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if path == ["watch"] {
            guard let id = value("v"), isYouTubeID(id) else { return nil }
            return (.youtube, .video, nil)
        }
        if path == ["playlist"] {
            guard let id = value("list"), id.count >= 10, isPlain(id) else { return nil }
            return (.youtube, .playlist, nil)
        }
        guard path.count == 2, isYouTubeID(path[1]) else { return nil }
        switch path[0] {
        case "shorts": return (.youtube, .short, nil)
        case "live": return (.youtube, .live, nil)
        case "embed", "v": return (.youtube, .video, nil)
        default: return nil
        }
    }

    private static func spotify(_ path: [String]) -> (Service, Kind, String?)? {
        // A shared address can start with the person's language: /intl-de/track/….
        var path = path[...]
        if let first = path.first, first.hasPrefix("intl-") { path = path.dropFirst() }
        guard path.count == 2, let kind = path.first, let id = path.last,
              id.utf8.count == 22, id.utf8.allSatisfy(isLetterOrDigit) else { return nil }
        switch kind {
        case "track": return (.spotify, .track, nil)
        case "album": return (.spotify, .album, nil)
        case "playlist": return (.spotify, .playlist, nil)
        case "artist": return (.spotify, .artist, nil)
        case "episode": return (.spotify, .episode, nil)
        case "show": return (.spotify, .show, nil)
        default: return nil
        }
    }

    /// SoundCloud's own pages, which look like a person's.
    private static let soundcloudPages: Set<String> = [
        "charts", "discover", "feed", "jobs", "library", "messages", "notifications", "pages", "people", "search",
        "settings", "stations", "stream", "tags", "terms-of-use", "upload", "you",
    ]
    private static let soundcloudTabs: Set<String> = [
        "albums", "comments", "followers", "following", "likes", "popular-tracks", "reposts", "sets", "spotlight", "tracks",
    ]

    private static func soundcloud(_ path: [String]) -> (Service, Kind, String?)? {
        guard let artist = path.first, !soundcloudPages.contains(artist) else { return nil }
        if path.count == 3, path[1] == "sets" { return (.soundcloud, .playlist, "\(artist)/\(path[2])") }
        guard path.count == 2, !soundcloudTabs.contains(path[1]) else { return nil }
        return (.soundcloud, .track, "\(artist)/\(path[1])")
    }

    /// GitHub's own pages, which look like an owner's.
    private static let githubPages: Set<String> = [
        "about", "account", "apps", "codespaces", "collections", "contact", "customer-stories", "enterprise", "events",
        "explore", "features", "issues", "login", "logout", "marketplace", "mobile", "new", "notifications", "orgs",
        "organizations", "pricing", "pulls", "search", "security", "sessions", "settings", "signup", "site", "solutions",
        "sponsors", "stars", "team", "topics", "trending", "users",
    ]

    private static func github(_ path: [String]) -> (Service, Kind, String?)? {
        guard path.count == 2 || path.count == 4, !githubPages.contains(path[0].lowercased()),
              !path[0].hasPrefix("."), !path[1].hasPrefix(".") || path[1] == ".github" else { return nil }
        let name = "\(path[0])/\(path[1].hasSuffix(".git") ? String(path[1].dropLast(4)) : path[1])"
        if path.count == 2 { return (.github, .repository, name) }
        guard isNumber(path[3]), let number = Int(path[3]) else { return nil }
        switch path[2] {
        case "issues": return (.github, .issue(number), name)
        case "pull": return (.github, .pullRequest(number), name)
        case "discussions": return (.github, .discussion(number), name)
        default: return nil
        }
    }

    // MARK: - Ids

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Letters, digits, `-`, `_` and `.`, not only dots.
    private static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { isLetterOrDigit($0) || $0 == 45 || $0 == 95 || $0 == 46 }
            && text.contains { $0 != "." }
    }

    private static func isNumber(_ text: String) -> Bool {
        (1...18).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isHex(_ text: String) -> Bool {
        (6...40).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isYouTubeID(_ text: String) -> Bool {
        text.utf8.count == 11 && text.utf8.allSatisfy { isLetterOrDigit($0) || $0 == 45 || $0 == 95 }
    }

    /// `BV` and ten characters, or the older `av` and a number.
    private static func isBilibiliID(_ text: String) -> Bool {
        if text.hasPrefix("BV") { return text.utf8.count == 12 && text.utf8.allSatisfy(isLetterOrDigit) }
        return text.lowercased().hasPrefix("av") && isNumber(String(text.dropFirst(2)))
    }
}
