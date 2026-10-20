import HermesKit
import SwiftUI

/// Hermes is waiting for permission (`blocks/actions.elyx` `approvalAsk`, `approvalFlagged`,
/// `approvalBatch`): the command and its risk, then every answer Hermes accepts as a tile with
/// its scope. Extras live in the … menu; Always Allow asks first. Return allows once, Escape
/// denies.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    /// Who is asking: "Hermes", or the Bot in a Bot Chat.
    var asker: String = "Hermes"
    /// Approvals waiting behind this one (parallel tool calls).
    var waiting: [ApprovalRequest] = []
    let onChoice: (ApprovalChoice) -> Void
    /// Answers every waiting approval the same way.
    /// One answer for every approval the card shows (their ids), and only those.
    var onChoiceForAll: ((ApprovalChoice, [String]) -> Void)?
    /// The … menu's extras; `nil` hides the menu (Talk).
    var extras: Extras?

    struct Extras {
        var explain: () -> Void
        var denyWithNote: (String) -> Void
        var allowEverything: () -> Void
        var showPermissions: () -> Void
    }

    @State private var confirmingAlways = false
    @State private var confirmingAlwaysAll = false
    @State private var confirmingEverything = false
    @State private var writingNote = false
    @State private var note = ""
    @State private var reviewingEach = false

    /// One answer for all only when each command shows whole on the card, and none is flagged or
    /// a memory save: those are read and answered one at a time.
    private var isBatch: Bool {
        !waiting.isEmpty && !reviewingEach && onChoiceForAll != nil
            && all.allSatisfy { !$0.smartDenied && !$0.isMemorySave && Self.showsWholeInBatch($0.summary) }
    }

    static func showsWholeInBatch(_ command: String) -> Bool {
        command.count <= 240 && command.split(whereSeparator: \.isNewline).count <= 4
    }

    var body: some View {
        Group {
            if approval.isMemorySave {
                // Ask Before Saving: Don't Save / Save / Save All in This Chat (`memorySaveAsk`).
                MemorySaveAsk(approval: approval, asker: asker, onChoice: onChoice)
            } else if isBatch {
                batch
            } else if approval.smartDenied {
                flagged
            } else {
                single
            }
        }
        .requestCard()
        .alert("Always allow commands like this?", isPresented: $confirmingAlways) {
            Button("Cancel", role: .cancel) {}
            Button("Always Allow") { onChoice(.always) }
        } message: {
            Text("\(asker) will run matching commands without asking again, in every chat.")
        }
        .alert("Always allow all \(waiting.count + 1)?", isPresented: $confirmingAlwaysAll) {
            Button("Cancel", role: .cancel) {}
            Button("Always Allow") { onChoiceForAll?(.always, all.map(\.id)) }
        } message: {
            Text("\(asker) will run commands like these without asking again, in every chat.")
        }
        .alert("Allow everything in this chat?", isPresented: $confirmingEverything) {
            Button("Cancel", role: .cancel) {}
            Button("Allow Everything") { extras?.allowEverything() }
        } message: {
            Text("\(asker) will run any command in this chat without asking until it ends. Other chats still ask.")
        }
        .alert("Deny with a note", isPresented: $writingNote) {
            TextField("Why not, or what to do instead", text: $note)
            Button("Cancel", role: .cancel) { note = "" }
            Button("Deny") {
                extras?.denyWithNote(note)
                note = ""
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed")
    }

    // MARK: One command

    private var hasCommand: Bool {
        !(approval.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var subtitle: String {
        "\(asker) · \(approval.toolName ?? (hasCommand ? "terminal" : "tool"))"
    }

    private var single: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: "hand.raised.fill",
                title: hasCommand ? String(localized: "Run this command?") : String(localized: "\(asker) needs your permission"),
                subtitle: subtitle,
                menu: { moreMenu }
            )
            if hasCommand, let command = approval.command {
                CodeBox(text: command, risk: approval.description)
            } else if let description = approval.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            }
            tiles
            if let scope {
                Text("Allowing covers \(scope) like this one. Change it any time in Chat Permissions.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// What an allow covers, in words: "recursive deletes".
    private var scope: String? {
        guard approval.choices.contains(.session) || approval.choices.contains(.always) else { return nil }
        if let key = approval.patternKeys.first {
            let words = key.replacingOccurrences(of: "_", with: " ")
            switch key {
            case "rm_rf", "recursive_delete": return String(localized: "recursive deletes")
            default: return String(localized: "\(words) commands")
            }
        }
        guard let description = approval.description, !description.isEmpty else { return nil }
        return description.lowercased().hasSuffix("s") ? description.lowercased() : description.lowercased() + "s"
    }

    private var tiles: some View {
        let showsSession = approval.choices.contains(.session)
        let showsAlways = approval.choices.contains(.always)
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                ActionTile(symbol: "xmark", title: String(localized: "Deny"), detail: String(localized: "Don't run it"), style: .danger) {
                    onChoice(.deny)
                }
                .keyboardShortcut(.cancelAction)
                ActionTile(symbol: "checkmark", title: String(localized: "Allow Once"), detail: String(localized: "Only this command"), style: .primary) {
                    onChoice(.once)
                }
                .keyboardShortcut(.defaultAction)
            }
            if showsSession || showsAlways {
                GridRow {
                    if showsSession {
                        ActionTile(symbol: "checkmark.shield.fill", title: String(localized: "Allow in This Chat"), detail: String(localized: "Until this chat ends")) {
                            onChoice(.session)
                        }
                    }
                    if showsAlways {
                        ActionTile(symbol: "checkmark.seal.fill", title: String(localized: "Always Allow"), detail: String(localized: "Every chat, saved")) {
                            confirmingAlways = true
                        }
                    }
                    if !(showsSession && showsAlways) {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    // MARK: Flagged

    private var flagged: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: "xmark.shield",
                tint: Theme.danger,
                tileFill: Theme.dangerTint,
                title: String(localized: "\(asker)'s safety check flagged this"),
                subtitle: subtitle,
                menu: { moreMenu }
            )
            if let command = approval.command {
                CodeBox(text: command, risk: approval.description)
            }
            Text("You can still run it once if you trust it.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                ActionTile(symbol: "exclamationmark.triangle.fill", title: String(localized: "Run Once Anyway"), detail: String(localized: "Only this command"), style: .danger) {
                    onChoice(.once)
                }
                ActionTile(symbol: "xmark.shield", title: String(localized: "Keep Blocked"), detail: String(localized: "Recommended"), style: .primary) {
                    onChoice(.deny)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Several at once

    private var all: [ApprovalRequest] { [approval] + waiting }

    private var batch: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(
                symbol: "hand.raised.fill",
                title: String(localized: "\(all.count) commands are waiting"),
                subtitle: subtitle,
                menu: { moreMenu }
            )
            VStack(spacing: 6) {
                ForEach(all) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
                        // Whole, never shortened: these are what Allow All runs.
                        Text(item.summary)
                            .font(Theme.Typography.code)
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 38)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    ActionTile(symbol: "xmark", title: String(localized: "Deny All"), detail: String(localized: "None of them run"), style: .danger) {
                        onChoiceForAll?(.deny, all.map(\.id))
                    }
                    .keyboardShortcut(.cancelAction)
                    ActionTile(symbol: "checkmark", title: String(localized: "Allow All Once"), detail: String(localized: "Only these \(all.count)"), style: .primary) {
                        onChoiceForAll?(.once, all.map(\.id))
                    }
                    .keyboardShortcut(.defaultAction)
                }
                GridRow {
                    if all.allSatisfy({ $0.choices.contains(.session) }) {
                        ActionTile(symbol: "checkmark.shield.fill", title: String(localized: "Allow All in Chat"), detail: String(localized: "Until this chat ends")) {
                            onChoiceForAll?(.session, all.map(\.id))
                        }
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    ActionTile(symbol: "list.bullet", title: String(localized: "Review Each"), detail: String(localized: "One command at a time")) {
                        reviewingEach = true
                    }
                }
            }
            if all.allSatisfy({ $0.choices.contains(.always) }) {
                Button("Always Allow All…") { confirmingAlwaysAll = true }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var moreMenu: some View {
        if let command = approval.command, !command.isEmpty {
            Button("Copy Command", systemImage: "doc.on.doc") { Pasteboard.copy(command) }
        }
        if let extras {
            Button("Ask \(asker) to Explain", systemImage: "questionmark.bubble") { extras.explain() }
            Button("Deny with a Note…", systemImage: "text.bubble") { writingNote = true }
            Divider()
            Button("Allow Everything in This Chat…", systemImage: "bolt.shield") { confirmingEverything = true }
            Button("Chat Permissions", systemImage: "lock.shield") { extras.showPermissions() }
        }
    }
}
