import HermesKit
import SwiftUI

/// A command as sent (`blocks/slash.elyx` `commandBubble`): what it does in plain words with the
/// command underneath, never a bare "/text" bubble. A command with an argument shows the
/// argument as the title ("Ship Hermes 1.3 by Friday" over "/goal").
struct CommandBubble: View {
    let name: String
    let argument: String?
    var isBotChat = false

    private var info: SlashCommandInfo { SlashCommands.info(name) }

    private var title: String {
        let canonical = SlashCommands.canonical(name)
        if isBotChat, canonical == "new" || canonical == "compress" { return String(localized: "Compact Chat") }
        if let argument, !argument.isEmpty {
            if canonical == "model" { return ModelNames.display(argument.components(separatedBy: " --provider ")[0]) }
            if canonical == "reasoning", let level = ReasoningEffort(rawValue: argument) { return ReasoningNames.title(for: level) }
            return argument
        }
        return String(localized: String.LocalizationValue(info.title))
    }

    private var subtitle: String {
        "/" + (argument == nil || SlashCommands.known(name) != nil ? name : "\(name) \(argument!)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isBotChat && SlashCommands.canonical(name) == "new" ? "rectangle.compress.vertical" : info.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 32, height: 32)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(3)
                // An unknown command's title is already the raw command.
                if subtitle != title {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), command"))
        .contextMenu {
            Button("Copy Command", systemImage: "doc.on.doc") { Pasteboard.copy(subtitle) }
        }
    }
}

/// A command run here and what came of it: the card on the person's side, then a quiet note,
/// a result card, or the failure on the assistant side.
struct CommandRow: View {
    let entry: CommandEntry
    var isBotChat = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CommandBubble(name: entry.name, argument: entry.argument, isBotChat: isBotChat)
            outcome
        }
    }

    @ViewBuilder
    private var outcome: some View {
        switch entry.outcome {
        case .running(let status):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status ?? String(localized: "Running /\(entry.name)…"))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.vertical, 4)
        case .note(let text):
            CommandNote(text: text)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.danger)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        case .result(let rows, let text):
            CommandResultCard(name: entry.name, rows: rows, text: text)
        }
    }
}

/// One quiet line (`commandNote`): "Model changed to Claude Opus 4.6".
struct CommandNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// An info command's data (`commandResult`): "Usage · this session" and label / value rows,
/// or the output itself when it isn't rows.
struct CommandResultCard: View {
    let name: String
    let rows: [CommandEntry.Row]
    let text: String?

    private var info: SlashCommandInfo { SlashCommands.info(name) }

    private var heading: String {
        switch SlashCommands.canonical(name) {
        case "usage": String(localized: "Usage · this session")
        case "status": String(localized: "Status")
        case "context": String(localized: "Context · this session")
        default: String(localized: String.LocalizationValue(info.title))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(heading, systemImage: info.symbol)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            if !rows.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(Theme.secondaryText)
                                .gridColumnAlignment(.leading)
                            Text(row.value)
                                .foregroundStyle(Theme.primaryText)
                                .textSelection(.enabled)
                        }
                        .font(.subheadline)
                    }
                }
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(rows.isEmpty ? Theme.Typography.code : .footnote)
                    .foregroundStyle(rows.isEmpty ? Theme.primaryText : Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A standing goal (`goalBar`): pinned above the composer until cleared.
struct GoalBar: View {
    let goal: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Goal")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(goal)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Clear goal")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
