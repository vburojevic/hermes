import HermesKit
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
