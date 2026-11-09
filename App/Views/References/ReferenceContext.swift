import HermesKit
import ImageIO
import OSLog
import SwiftUI

/// What pills need to know about where they're shown: the gateway's Bots, skills and files, and
/// where Open goes.
///
/// Equatable: a chat makes one on every update (each streamed token); an equal one doesn't
/// count as a change for the messages that read it from the environment.
struct ReferenceContext: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace === rhs.workspace && lhs.conversation === rhs.conversation && lhs.catalog === rhs.catalog
            && lhs.vocabulary == rhs.vocabulary
    }

    weak var workspace: BotWorkspace?
    /// The chat these messages are in: its Inspector opens the files they name.
    weak var conversation: ConversationModel?
    var catalog: SlashCatalog?
    /// The names plain text is upgraded against (`docs/commands-and-references.md` §4).
    var vocabulary = ReferenceVocabulary()

    init(workspace: BotWorkspace? = nil, conversation: ConversationModel? = nil, catalog: SlashCatalog? = nil, extraHandles: Set<String> = []) {
        self.workspace = workspace
        self.conversation = conversation
        self.catalog = catalog
        guard let workspace else { return }
        var handles = extraHandles
        if let roster = workspace.roster {
            for bot in roster.visibleBots + roster.hiddenBots {
                for form in Self.handles(of: bot) { handles.insert(form) }
            }
        }
        vocabulary = ReferenceVocabulary(
            handles: handles,
            commands: ReferenceVocabulary.knownCommands.union(catalog?.commands.map { $0.name.lowercased() } ?? []),
            skills: catalog?.skillNames ?? []
        )
    }

    /// Every way a Bot can be `@`-mentioned: its tag, handle and profile name.
    static func handles(of bot: BotProfile) -> [String] {
        [bot.mentionTag, bot.handle, bot.name].filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    var roster: BotRoster? { workspace?.roster }

    func bot(handle: String) -> BotProfile? {
        guard let roster else { return nil }
        let wanted = handle.lowercased()
        return (roster.visibleBots + roster.hiddenBots).first { Self.handles(of: $0).contains(wanted) }
    }

    func appearance(handle: String) -> BotAppearance? {
        guard let roster, let bot = bot(handle: handle) else { return nil }
        return roster.appearance(for: bot)
    }

    func skill(_ name: String) -> SlashCatalog.Entry? {
        catalog?.skills.first { $0.name == name }
    }

    var gatewayName: String { workspace?.bot.name ?? "Hermes" }

    /// Parts for a message from elsewhere: the leading command or skills, Bots and files.
    func parts(of text: String, leading: Bool = true) -> MessageParts {
        MessageParts.parse(text, vocabulary: vocabulary, leading: leading)
    }

    // MARK: Open

    func openChat(with bot: BotProfile) {
        guard let workspace else { return }
        if workspace.roster != nil { workspace.sidebarMode = .bots }
        workspace.selection = .bot(bot.name)
    }

    func showSkill(_ name: String) {
        guard let workspace else { return }
        workspace.pendingSkillQuery = name
        workspace.selection = .skills
    }

    /// A gateway file a message named (`GatewayFileLink`): its File tab in this chat's Inspector.
    /// Outside a chat (a group room), the file's preview.
    func openInInspector(_ path: String) {
        if let conversation {
            conversation.inspector.openFile(path)
        } else {
            workspace?.openedFile = GatewayFile(path: path)
        }
    }

    /// A widget's `hermes-file:` link: the same file a picture with that address reads
    /// (`gatewayPicture`). In a chat, its Inspector joins a relative path onto the chat's folder;
    /// in a group room it's joined onto the gateway's default folder here, and nothing opens
    /// until that folder is known.
    func openWidgetFile(_ address: String) {
        if conversation != nil {
            if let path = WidgetFile.path(address) { openInInspector(path) }
        } else if let path = WidgetFile.resolve(address, in: workspace?.projects.defaultFolder) {
            openInInspector(path)
        }
    }

    // MARK: Gateway pictures

    /// Where a picture kept on the gateway is read (docs/widgets.md §9).
    enum GatewayPicture: Hashable {
        /// The file to read through the backend, with the Bot's profile.
        case file(path: String, profile: String?)
        /// No backend to read it through: Bot Mode is off.
        case needsBotMode
        /// The address names no file the gateway could read (`WidgetFile`).
        case unreadable
    }

    /// In a chat, a widget's relative path is in the chat's working folder, the one its Inspector
    /// opens files from, and is read with its Bot's profile. A group room has no chat of its own:
    /// the gateway's default folder, read without a profile (docs/widgets.md §9). Reading the
    /// chat's folder makes its Inspector if it has none yet; a chat's screen has made it already.
    func gatewayPicture(_ source: GatewayImageSource) -> GatewayPicture {
        guard workspace?.roster != nil else { return .needsBotMode }
        let path: String? = switch source {
        case .widget(let address):
            WidgetFile.resolve(address, in: conversation?.inspector.workingFolder ?? workspace?.projects.defaultFolder)
        case .path(let path):
            path
        }
        guard let path else { return .unreadable }
        return .file(path: path, profile: conversation?.gatewayProfileForCheckpoints)
    }

    /// The picture's bytes, read through the backend, whose session keeps no URL cache: a private
    /// widget's picture is held in memory only and never reaches the disk.
    func pictureData(_ path: String, profile: String?) async throws -> Data {
        guard let client = roster?.boardClient else { throw URLError(.notConnectedToInternet) }
        return try await client.downloadFile(path, profile: profile).0
    }

    func openFile(_ reference: MessageReference) {
        workspace?.openedFile = GatewayFile(path: reference.value, isFolder: reference.kind == .folder)
    }

    /// The file's size and first lines, read on the gateway (`shell.exec`).
    func peek(_ file: GatewayFile, bytes: Int = 600) async -> GatewayFile.Peek? {
        guard let roster, roster.isConnected else { return nil }
        let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = file.isFolder
            ? "ls -1p -- \(quoted) | head -n 12"
            : "wc -c < \(quoted) && head -c \(bytes) -- \(quoted)"
        guard let result = try? await roster.request("shell.exec", ["command": .string(command)], timeout: .seconds(15)),
              (result["code"]?.doubleValue ?? 0) == 0, let output = result["stdout"]?.stringValue else { return nil }
        if file.isFolder { return GatewayFile.Peek(size: nil, text: output) }
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let size = lines.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return GatewayFile.Peek(size: size, text: lines.count > 1 ? String(lines[1]) : "")
    }
}

extension EnvironmentValues {
    /// Where pills are shown: the gateway's Bots and skills, and where Open goes.
    @Entry var references = ReferenceContext()
}

/// A file on the gateway that a message named.
struct GatewayFile: Identifiable, Hashable {
    var path: String
    var isFolder = false

    var id: String { path }
    var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    var directory: String? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let folder = String(trimmed[..<slash])
        return folder.isEmpty ? "/" : folder
    }

    struct Peek: Hashable {
        var size: Int?
        var text: String

        var sizeText: String? {
            size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        }
    }
}

/// A picture kept on the gateway.
enum GatewayImageSource: Hashable {
    /// A widget's `hermes-file:` address (`WidgetFile`).
    case widget(String)
    /// The absolute or home path a reply's image names (`GatewayFileLink`).
    case path(String)
}

/// Where a gateway picture is: loading, shown, or failed, with the note that says why.
enum GatewayImagePhase {
    case empty
    case success(Image)
    case failure(note: String)
}

/// A picture from a file on the gateway: a widget's `hermes-file:` media, or a reply's image
/// that names a file. It's read through the backend with the Bot's profile, decoded and
/// downsampled off the main thread to the size it's drawn at, and held by this view alone: no
/// disk or shared cache, so a private widget's picture never reaches the disk (docs/widgets.md
/// §8). Leaving the screen cancels the read.
struct GatewayFileImage<Content: View>: View {
    let source: GatewayImageSource
    /// The size it fits inside, in points (a reply's image). Nil: it fills the frame it's given
    /// (a widget's well), measured as it's laid out.
    var fits: CGSize?
    var transaction = Transaction()
    @ViewBuilder let content: (GatewayImagePhase) -> Content

    @Environment(\.references) private var references
    @Environment(\.displayScale) private var displayScale
    @State private var phase = GatewayImagePhase.empty
    /// The pixels the picture is wanted at. It only grows, in steps, so a window being resized
    /// doesn't read the file again for every point.
    @State private var wanted = Pixels(width: 0, height: 0)
    @State private var shown: Request?

    struct Pixels: Hashable, Sendable {
        var width: Int
        var height: Int
    }

    private struct Request: Hashable {
        var source: GatewayImageSource
        var pixels: Pixels
        /// Where it's read. A picture drawn before Bot Mode is on or the chat's folder is known
        /// reads again once they are.
        var picture: ReferenceContext.GatewayPicture
    }

    var body: some View {
        Group {
            if let fits {
                let request = Request(source: source, pixels: Self.pixels(fits, scale: displayScale), picture: references.gatewayPicture(source))
                content(phase).task(id: request) { await load(request) }
            } else {
                let request = Request(source: source, pixels: wanted, picture: references.gatewayPicture(source))
                Color.clear
                    .overlay { content(phase) }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        let pixels = Self.pixels(size, scale: displayScale)
                        if pixels.width > wanted.width || pixels.height > wanted.height {
                            wanted = Pixels(width: max(pixels.width, wanted.width), height: max(pixels.height, wanted.height))
                        }
                    }
                    .task(id: request) { await load(request) }
            }
        }
    }

    private func load(_ request: Request) async {
        // Not laid out yet, or shown at this size already: a row scrolled back into view
        // doesn't read it again.
        guard request.pixels.width > 0, request.pixels.height > 0, shown != request else { return }
        // A sharper copy for a larger frame keeps the one shown until it's there.
        if shown?.source != request.source, !isEmpty { phase = .empty }
        switch request.picture {
        case .needsBotMode:
            phase = .failure(note: String(localized: "Turn on Bot Mode to load this image"))
        case .unreadable:
            phase = .failure(note: String(localized: "Couldn't load this image"))
        case .file(let path, let profile):
            do {
                let data = try await references.pictureData(path, profile: profile)
                let image = try await GatewayPictureDecoder.decode(
                    data, width: request.pixels.width, height: request.pixels.height, fills: fits == nil)
                guard !Task.isCancelled else { return }
                withTransaction(transaction) {
                    phase = .success(Image(decorative: image, scale: displayScale))
                    shown = request
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Domain and code only: a URL error's description carries the gateway's address.
                let nsError = error as NSError
                var status = 0
                if case BackendClient.Failure.http(let code, _) = error { status = code }
                GatewayPictureDecoder.logger.error("Gateway picture failed: \(nsError.domain, privacy: .public) \(nsError.code) HTTP \(status)")
                if shown?.source == request.source { return }
                withTransaction(transaction) { phase = .failure(note: String(localized: "Couldn't load this image")) }
            }
        }
    }

    private var isEmpty: Bool {
        if case .empty = phase { true } else { false }
    }

    /// Points to pixels, rounded up to a step of 128.
    private static func pixels(_ size: CGSize, scale: CGFloat) -> Pixels {
        func step(_ points: CGFloat) -> Int {
            guard points.isFinite, points > 0 else { return 0 }
            return (Int((points * scale).rounded(.up)) + 127) / 128 * 128
        }
        return Pixels(width: step(size.width), height: step(size.height))
    }
}

/// Outside the generic view, so decoding off the main actor needs nothing from its content.
private nonisolated enum GatewayPictureDecoder {
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    /// Decodes only as many pixels as the frame shows: filled, the picture covers it; fitted, it
    /// sits inside it. Never larger than the file itself.
    @concurrent
    static func decode(_ data: Data, width wantedWidth: Int, height wantedHeight: Int, fills: Bool) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { throw RemotePicture.Failure.notAPicture }
        // Orientations 5 to 8 turn the picture a quarter: its sides swap once it's upright.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let across = Double(wantedWidth) / width, down = Double(wantedHeight) / height
        let scale = min(1, fills ? max(across, down) : min(across, down))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((max(width, height) * scale).rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RemotePicture.Failure.notAPicture
        }
        return image
    }
}
