import HermesKit
import SwiftUI

// One look per kind (`blocks/slash.elyx`, `docs/commands-and-references.md` §1): commands are an
// ink tile and plain words, skills a capsule with a book, Bots a capsule with their face, gateway
// files a capsule with a page and the path in mono. All `surface-raised`, never glass, never
// blue; each as tall as a line of the text around it.

/// How big a pill is: `mentionChip` / `fileRefChip` next to 17 pt text, `mentionInline` next to
/// 15 pt prose.
enum PillSize: Hashable {
    case regular, compact

    /// Next to `Theme.Typography.message`.
    static var message: PillSize {
        #if os(macOS)
        .compact
        #else
        .regular
        #endif
    }

    var height: CGFloat { self == .regular ? 26 : 22 }
    var face: CGFloat { self == .regular ? 18 : 15 }
}

extension EnvironmentValues {
    /// Mention pills in a message just sent blink once (`docs/bot-faces.md` §5.7).
    @Entry var mentionsBlinkOnAppear = false
}

/// A Bot in the text (`mentionChip`, `mentionInline`): face and @handle.
struct BotPill: View {
    let handle: String
    var appearance: BotAppearance?
    var size: PillSize = .message

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.mentionsBlinkOnAppear) private var blinksOnAppear
    @State private var blinks = 0

    var body: some View {
        HStack(spacing: size == .regular ? 5 : 4) {
            if let appearance {
                // Still at this size, apart from one blink when the message is sent (§5.7).
                BotFace(appearance: appearance, size: size.face * scale, blinks: blinks)
                    .task {
                        guard blinksOnAppear else { return }
                        try? await Task.sleep(for: .seconds(0.35))
                        blinks += 1
                    }
            } else {
                Image(systemName: "at")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: size.face * scale)
            }
            Text(verbatim: "@" + handle)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
        .padding(.leading, (size == .regular ? 4 : 3) * scale)
        .padding(.trailing, (size == .regular ? 9 : 7) * scale)
        .frame(height: size.height * scale)
        .background(Theme.surfaceRaised, in: Capsule())
        .fixedSize()
    }
}

/// A file or folder on the gateway (`fileRefChip`): page glyph and the path in mono.
struct FilePill: View {
    let path: String
    var isFolder = false
    var size: PillSize = .message

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    /// In a chat, a file opens in the Inspector's File tab and a folder in Files.
    @Environment(\.inspectorModel) private var inspector

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isFolder ? "folder" : "doc.text")
                .font(.system(size: (size == .regular ? 13 : 11.5) * scale))
                .foregroundStyle(Theme.secondaryText)
            Text(verbatim: path)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, (size == .regular ? 8 : 7) * scale)
        .padding(.trailing, (size == .regular ? 9 : 8) * scale)
        .frame(height: size.height * scale)
        .frame(maxWidth: 260)
        .background(Theme.surfaceRaised, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .onTapGesture {
            guard let inspector else { return }
            if isFolder {
                inspector.open(.files, key: path, title: ProjectPath.lastComponent(path))
            } else {
                inspector.openFile(path)
            }
        }
    }
}

/// A command waiting for its argument in the field (`commandPill`): ink tile, what it does.
struct CommandPill: View {
    let info: SlashCommandInfo

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: info.symbol)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 20 * scale, height: 20 * scale)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
            Text(CommandMode.pillTitle(info))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
        }
        .padding(.leading, 4 * scale)
        .padding(.trailing, 10 * scale)
        .frame(height: 28 * scale)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9 * scale, style: .continuous))
        .fixedSize()
    }
}

/// A skill on the message (`skillChip`): book, name and, in the composer's tray, remove.
struct SkillChip: View {
    let name: String
    var onRemove: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "book.closed")
                .font(.system(size: 11 * scale, weight: .medium))
                .frame(width: 12 * scale, height: 12 * scale)
            Text(verbatim: name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(Theme.placeholderText)
                        .frame(width: 22 * scale, height: 28 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
                .padding(.horizontal, -4 * scale)
            }
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.leading, 9 * scale)
        .padding(.trailing, (onRemove == nil ? 9 : 5) * scale)
        .frame(height: 28 * scale)
        .background(Theme.surfaceRaised, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Skill, \(name)"))
    }
}

/// What the field and the pill say for a command that takes an argument (`composerCommand`).
enum CommandMode {
    /// The commands that wait for an argument instead of running at once.
    static func takesArgument(_ info: SlashCommandInfo) -> Bool {
        info.needsArgument || info.takesOptions
    }

    /// What the command does, as a verb: "Set Goal", "Change Model".
    static func pillTitle(_ info: SlashCommandInfo) -> String {
        switch info.name {
        case "goal": String(localized: "Set Goal")
        case "model": String(localized: "Change Model")
        case "reasoning": String(localized: "Set Reasoning")
        case "steer": String(localized: "Steer")
        case "queue": String(localized: "Queue Next")
        case "btw": String(localized: "Ask Aside")
        case "plan": String(localized: "Plan")
        case "bg": String(localized: "Run in Background")
        case "personality": String(localized: "Set Personality")
        default: info.title
        }
    }

    /// The field's placeholder while the argument is empty.
    static func placeholder(_ info: SlashCommandInfo) -> String {
        switch info.name {
        case "goal": String(localized: "What should Hermes work toward?")
        case "model": String(localized: "Pick one, or type a name")
        case "reasoning": String(localized: "Pick a level")
        case "steer": String(localized: "What should Hermes change?")
        case "queue": String(localized: "What should Hermes do next?")
        case "btw": String(localized: "Ask without interrupting")
        case "plan": String(localized: "What should Hermes plan?")
        case "bg": String(localized: "What should run in the background?")
        default: String(localized: "Add details")
        }
    }

    /// The one line under the field.
    static func hint(_ info: SlashCommandInfo) -> String {
        switch info.name {
        case "goal": String(localized: "Hermes keeps the goal across turns until you clear it.")
        case "model": String(localized: "For this chat only. Your default stays in Settings.")
        case "reasoning": String(localized: "For this chat only.")
        case "steer": String(localized: "Hermes reads it after the next tool call.")
        case "queue": String(localized: "Sends when Hermes finishes, without interrupting.")
        case "btw": String(localized: "Hermes answers on the side and keeps working.")
        case "bg": String(localized: "Hermes tells you when it's done.")
        default: info.summary
        }
    }
}

// MARK: - Spoken labels

extension MessageReference {
    /// What VoiceOver reads: "Bot, Ada, @writer", "File, CHANGELOG.md".
    @MainActor
    func spokenLabel(bot: BotProfile?) -> String {
        switch kind {
        case .bot:
            if let bot { return String(localized: "Bot, \(bot.title), @\(value)") }
            return String(localized: "Bot, @\(value)")
        case .file: return String(localized: "File, \(value)")
        case .folder: return String(localized: "Folder, \(value)")
        }
    }
}
