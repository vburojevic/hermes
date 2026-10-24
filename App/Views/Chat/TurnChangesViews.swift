import HermesKit
import HermesMarkdown
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// What a turn did to files (`turnChanges`, `docs/chat.md` §1): one row under the turn's header,
// the files and their diffs a tap away, in a sheet or the Inspector's Changed Files tab
// (`docs/inspector.md` §2.7). Transcript content: `surface` fills, never glass.

/// `turnChanges`: "Changed 3 files · +106 −1" and the files' names. While the turn runs it keeps
/// its count without moving (`docs/chat.md` §4a). Undo sits at its end when the turn has an undo
/// point (`docs/checkpoints.md` §2).
struct TurnChangesRow: View {
    let turn: AssistantTurn

    @Environment(\.inspectorModel) private var inspector
    @Environment(\.checkpoints) private var checkpoints
    /// Outside a chat (a helper's transcript): the sheet opens from here.
    @State private var localSheet: TurnChangesTarget?

    var body: some View {
        let changes = TurnChanges.of(turn)
        if !changes.isEmpty {
            HStack(spacing: 10) {
                Button(action: open) {
                    label(changes)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(changes.spokenSummary)
                .accessibilityHint("Shows the changes")
                if let checkpoints, checkpoints.checkpoint(beforeTurn: turn.id) != nil, checkpoints.refusal == nil {
                    Button {
                        checkpoints.undo(turnID: turn.id)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .font(.footnote.weight(.medium))
                    .cardButton()
                    .controlSize(.small)
                    .disabled(checkpoints.chatIsWorking || !checkpoints.isOnline)
                    .accessibilityHint(checkpoints.chatIsWorking ? "Undo is available when Hermes stops" : "Puts these files back and removes the turn")
                    .hermesTip(UndoTip(), arrowEdge: .bottom)
                    .task { await UndoTip.filesChanged.donate() }
                }
            }
            .padding(.leading, 12)
            .padding([.vertical, .trailing], 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Counts follow the edits as they land, without moving (`docs/chat.md` §4a).
            .transaction { $0.animation = nil }
            .contextMenu {
                Button("Show Changes", systemImage: "plus.forwardslash.minus", action: open)
                if let inspector {
                    ForEach(changes.files.filter { $0.change != .deleted }.prefix(8)) { file in
                        Button("Open \(file.name)", systemImage: "doc") { inspector.openFile(file.path) }
                    }
                }
            }
            .sheet(item: $localSheet) { target in
                TurnChangesSheet(target: target, changes: { _ in TurnChanges.of(turn) }, onOpenFile: nil)
            }
        }
    }

    /// "Changed 4 files · +115 −7" over the names. "1 failed" leads the names line, not the title
    /// line: beside Undo on an iPhone the title line has no room for it.
    private func label(_ changes: TurnChanges) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(changes.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                    if !changes.changedFiles.isEmpty {
                        Text(verbatim: "·")
                            .font(.footnote)
                            .foregroundStyle(Theme.tertiaryText)
                        DiffCounts(added: changes.added, removed: changes.removed, spacing: 5)
                            .font(.footnote.monospacedDigit().weight(.medium))
                    }
                }
                .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if !changes.changedFiles.isEmpty, changes.failedEdits > 0 {
                        Text(changes.failedEdits == 1 ? "1 failed" : "\(changes.failedEdits) failed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.warning)
                            .fixedSize()
                        Text(verbatim: "·")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Text(changes.names())
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private func open() {
        if let inspector {
            inspector.showChanges(turn: turn.changesKey)
        } else {
            localSheet = TurnChangesTarget(turnKey: turn.changesKey)
        }
    }
}

/// "+106 −1": colour never the only sign, the + and − say it too.
struct DiffCounts: View {
    let added: Int
    let removed: Int
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            Text("+\(added)").foregroundStyle(Theme.Syntax.inserted)
            Text("−\(removed)").foregroundStyle(Theme.Syntax.deleted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(added) added, \(removed) removed"))
    }
}

// MARK: - The sheet

/// iPhone, and iPad where the Inspector is a sheet: the turn's files, each opening to its diff.
struct TurnChangesSheet: View {
    let target: TurnChangesTarget
    /// The turn's changes now, by its key: a running turn's follow its edits.
    let changes: (String) -> TurnChanges?
    /// Open in the chat's Inspector (read through the gateway); nil where there's none.
    let onOpenFile: ((String) -> Void)?

    @State private var path: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let changes = changes(target.turnKey) ?? TurnChanges(files: [])
        NavigationStack(path: $path) {
            TurnChangesList(changes: changes, selected: nil) { path.append($0) }
                .navigationTitle("Changes")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.ink)
                    }
                }
                .navigationDestination(for: String.self) { filePath in
                    if let file = changes.file(filePath) {
                        ChangedFileDiffPage(file: file, onOpen: onOpenFile.map { open in { dismiss(); open(file.path) } })
                    } else {
                        ContentUnavailableView("This file isn't in the turn anymore", systemImage: "doc")
                    }
                }
        }
        .onAppear {
            if let file = target.file, path.isEmpty { path = [file] }
        }
    }
}

/// The turn's files, each once: its name, its folder, what happened to it, +/−.
struct TurnChangesList: View {
    let changes: TurnChanges
    let selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        List {
            Section {
                ForEach(changes.files) { file in
                    Button { onSelect(file.path) } label: {
                        ChangedFileRow(file: file, isSelected: selected == file.path)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected == file.path ? Theme.surfaceRaised : Theme.sheetCell)
                }
            } header: {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(nil)
            } footer: {
                Text("What this turn's edits did, read from the chat. Tap a file for its diff.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.sheetBackground)
    }

    /// "3 files · +106 −1 · 12 edits".
    private var summary: String {
        let edits = changes.files.reduce(0) { $0 + $1.edits }
        var parts = [changes.title, "+\(changes.added) −\(changes.removed)"]
        parts.append(edits == 1 ? String(localized: "1 edit") : String(localized: "\(edits) edits"))
        if changes.failedEdits > 0 {
            parts.append(changes.failedEdits == 1 ? String(localized: "1 failed") : String(localized: "\(changes.failedEdits) failed"))
        }
        return parts.joined(separator: " · ")
    }
}

/// One file of a turn's changes (`fileChangeRow`): its name, what happened to it as a tag, its
/// folder, its net +/−, and a chevron unless it's the one selected.
struct ChangedFileRow: View {
    let file: ChangedFile
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(symbolColor)
                .frame(width: 21)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if kind != nil || detail != nil {
                    HStack(spacing: 6) {
                        if let kind {
                            TagLabel(title: kind, isSmall: true)
                                .layoutPriority(1)
                        }
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if file.isBinary {
                    Text("binary").foregroundStyle(Theme.tertiaryText)
                } else if file.hasChange {
                    DiffCounts(added: file.added, removed: file.removed)
                } else {
                    Text("no change").foregroundStyle(Theme.tertiaryText)
                }
                if !file.failures.isEmpty {
                    Text(file.failures.count == 1 ? "1 failed" : "\(file.failures.count) failed")
                        .foregroundStyle(Theme.warning)
                }
            }
            .font(.footnote.monospacedDigit().weight(.medium))
            if !isSelected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.placeholderText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var symbol: String {
        switch file.change {
        case .created: "doc.badge.plus"
        case .deleted: "trash"
        case .renamed: "arrow.right.doc.on.clipboard"
        case .modified, .rewritten: "doc.text"
        }
    }

    private var symbolColor: Color {
        switch file.change {
        case .created: Theme.Syntax.inserted
        case .deleted: Theme.Syntax.deleted
        default: Theme.secondaryText
        }
    }

    /// What happened to it, as its tag: New, Deleted, Renamed from old.py, Written whole.
    private var kind: String? {
        switch file.change {
        case .created: String(localized: "New")
        case .deleted: String(localized: "Deleted")
        case .renamed(let from): String(localized: "Renamed from \(ProjectPath.lastComponent(from))")
        case .rewritten: String(localized: "Written whole")
        case .modified: nil
        }
    }

    /// "3 edits · Sources/Chat", or the folder.
    private var detail: String? {
        let folder = file.folder.isEmpty ? nil : file.folder
        let edits: String? = file.change == .modified && file.edits > 1 ? String(localized: "\(file.edits) edits") : nil
        let parts = [edits, folder].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var spoken: String {
        var parts = [file.name]
        if let kind { parts.append(kind) }
        if let detail { parts.append(detail) }
        if file.isBinary {
            parts.append(String(localized: "binary"))
        } else if file.hasChange {
            parts.append(file.added == 1 ? String(localized: "1 line added") : String(localized: "\(file.added) lines added"))
            parts.append(String(localized: "\(file.removed) removed"))
        } else {
            parts.append(String(localized: "no change"))
        }
        if !file.failures.isEmpty {
            parts.append(file.failures.count == 1 ? String(localized: "1 edit failed") : String(localized: "\(file.failures.count) edits failed"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - A file's diff

/// One file's diff as a page of the sheet: its notes, then every line with its numbers.
struct ChangedFileDiffPage: View {
    let file: ChangedFile
    let onOpen: (() -> Void)?

    @AppStorage(PreferenceKey.wrapsDiffLines) private var wraps = false

    var body: some View {
        VStack(spacing: 0) {
            ChangedFileNotes(file: file)
            ChangedFileDiff(file: file, wraps: wraps)
        }
        .background(Theme.canvas)
        .navigationTitle(file.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                WrapLinesToggle(isOn: $wraps)
                if let onOpen, file.change != .deleted {
                    Button("Open", action: onOpen)
                        .accessibilityLabel(Text("Open \(file.name) in the Inspector"))
                }
            }
        }
    }
}

/// `wrapLinesToggle`: Wrap Lines in the diff page's toolbar, a glass button that fills with ink
/// while on, never the system blue a toggle takes.
private struct WrapLinesToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        let button = Button {
            isOn.toggle()
        } label: {
            Label("Wrap Lines", systemImage: "text.word.spacing")
        }
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isToggle)
        if isOn {
            button
                .buttonStyle(.glassProminent)
                .tint(Theme.ink)
        } else {
            button
        }
    }
}

/// What the diff below can't say by itself (`diffNote`): the path, failed edits, a shortened or
/// unmerged diff.
struct ChangedFileNotes: View {
    let file: ChangedFile

    var body: some View {
        let notes = notes
        VStack(alignment: .leading, spacing: 4) {
            Text(ProjectPath.abbreviated(file.path))
                .font(.caption.monospaced())
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
            ForEach(notes, id: \.text) { note in
                Label(note.text, systemImage: note.symbol)
                    .font(.footnote)
                    .foregroundStyle(note.isWarning ? Theme.warning : Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private struct Note {
        let symbol: String
        let text: String
        var isWarning = false
    }

    private var notes: [Note] {
        var notes: [Note] = []
        for failure in file.failures {
            notes.append(Note(symbol: "exclamationmark.triangle",
                              text: failure.isEmpty ? String(localized: "An edit failed and changed nothing.")
                                  : String(localized: "An edit failed and changed nothing: \(failure)"), isWarning: true))
        }
        if case .rewritten = file.change {
            notes.append(Note(symbol: "doc.text", text: String(localized: "Hermes wrote the whole file. What it held before isn't in the chat.")))
        }
        if case .renamed(let from) = file.change {
            notes.append(Note(symbol: "arrow.right", text: String(localized: "Renamed from \(ProjectPath.abbreviated(from))")))
        }
        if !file.isMerged {
            notes.append(Note(symbol: "list.number", text: String(localized: "These edits couldn't be combined, so each shows on its own, in order.")))
        }
        if file.isShortened {
            notes.append(Note(symbol: "scissors", text: String(localized: "Hermes sent part of this change. Open the file to see all of it.")))
        }
        if file.edits > 0, file.hasChange == false, file.failures.count < file.edits, !file.isBinary {
            notes.append(Note(symbol: "equal", text: String(localized: "The turn's edits to this file cancel out: it's as it was.")))
        }
        return notes
    }
}

/// The diff itself (`fileDiff`): numbers before and after, the sign, the line in its language's
/// colours. Lines run off to the side and scroll, or wrap.
struct ChangedFileDiff: View {
    let file: ChangedFile
    var wraps = false

    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = Self.baseSize
    @State private var styled: [Int: AttributedString] = [:]
    @State private var viewport: CGFloat = 0

    #if os(macOS)
    private static let baseSize: CGFloat = 12.5
    #else
    private static let baseSize: CGFloat = 13
    #endif

    var body: some View {
        if file.isBinary {
            placeholder("doc.zipper", String(localized: "A binary file. Its changes can't be shown here."))
        } else if let bytes = file.tooBig {
            placeholder("doc.text.magnifyingglass", String(localized: "This change is too big to show here (\(bytes.formatted(.byteCount(style: .file)))). Open the file to see it."))
        } else if file.rows.isEmpty {
            placeholder("equal", file.failures.isEmpty ? String(localized: "Nothing changed in this file.") : String(localized: "Nothing changed: its edits failed."))
        } else {
            ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.rows) { row in
                        DiffRowView(row: row, text: styled[row.id], numberWidth: numberWidth, charWidth: charWidth, codeSize: codeSize, wraps: wraps)
                    }
                    if file.totalRows > file.rows.count {
                        Text("Showing the first \(file.rows.count.formatted()) of \(file.totalRows.formatted()) lines. Open the file to see it all.")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(12)
                    }
                }
                .frame(width: wraps ? nil : max(viewport, contentWidth), alignment: .leading)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
            .task(id: file) { await highlight() }
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        ContentUnavailableView {
            Label(text, systemImage: symbol)
                .font(.subheadline)
        }
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var charWidth: CGFloat {
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        #else
        let font = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        #endif
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The widest line number's room.
    private var numberWidth: CGFloat {
        let largest = file.rows.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        return CGFloat(max(2, String(largest).count)) * charWidth + 10
    }

    /// Unwrapped, every row as wide as the longest line, so the tints reach the edge.
    private var contentWidth: CGFloat {
        let longest = file.rows.reduce(0) { max($0, $1.text.count) }
        return numberWidth * 2 + 22 + CGFloat(longest) * charWidth + 24
    }

    /// Each line coloured by `CodeHighlighter`, worked out away from the main thread.
    private func highlight() async {
        guard let language = file.language else { return }
        let palette = SyntaxPalette()
        let lines = file.rows.map { (id: $0.id, text: $0.text) }
        let result = await Task.detached(priority: .userInitiated) {
            var styled: [Int: AttributedString] = [:]
            for line in lines where !line.text.isEmpty {
                var text = AttributedString()
                for token in CodeHighlighter.tokenize(line.text, language: language) {
                    var part = AttributedString(token.text)
                    if let color = palette.color(token.kind) { part.foregroundColor = color }
                    text += part
                }
                styled[line.id] = text
            }
            return styled
        }.value
        guard !Task.isCancelled else { return }
        styled = result
    }
}

/// The syntax colours, read on the main actor and handed to the highlighter's task.
private struct SyntaxPalette: Sendable {
    let colors: [CodeHighlighter.Token.Kind: Color]

    init() {
        colors = [
            .keyword: Theme.Syntax.keyword, .type: Theme.Syntax.type, .string: Theme.Syntax.string,
            .number: Theme.Syntax.number, .comment: Theme.Syntax.comment, .function: Theme.Syntax.function,
            .property: Theme.Syntax.property, .meta: Theme.Syntax.meta,
        ]
    }

    nonisolated func color(_ kind: CodeHighlighter.Token.Kind) -> Color? { colors[kind] }
}

/// One row of a diff: a line (`diffLine`), the unchanged lines it skips (`diffGap`), or an edit's
/// header when they show one by one (`diffEditHeader`).
private struct DiffRowView: View {
    let row: DiffRow
    let text: AttributedString?
    let numberWidth: CGFloat
    let charWidth: CGFloat
    let codeSize: CGFloat
    let wraps: Bool

    var body: some View {
        switch row.kind {
        case .gap(let skipped):
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                if let skipped {
                    Text(skipped == 1 ? String(localized: "1 unchanged line") : String(localized: "\(skipped) unchanged lines"))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.leading, numberWidth * 2 + 22)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(skipped.map { String(localized: "\($0) unchanged lines") } ?? String(localized: "Unchanged lines"))
        case .edit(let number, let count, let failure):
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit \(number) of \(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(failure == nil ? Theme.secondaryText : Theme.warning)
                if let failure {
                    Text(failure.isEmpty ? String(localized: "Failed: it changed nothing.") : String(localized: "Failed: \(failure)"))
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, number == 1 ? 4 : 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        case .context, .added, .removed:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(row.oldLine)
                number(row.newLine)
                Text(sign)
                    .foregroundStyle(signColor)
                    .frame(width: 18)
                Group {
                    if let text { Text(text) } else { Text(row.text.isEmpty ? " " : row.text).foregroundStyle(Theme.primaryText) }
                }
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: !wraps, vertical: true)
                .padding(.trailing, 12)
            }
            .font(.system(size: codeSize, design: .monospaced))
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        }
    }

    private func number(_ value: Int?) -> some View {
        // A space, not nothing: an empty text has no baseline and the row grew around it.
        Text(value.map(String.init) ?? " ")
            .foregroundStyle(Theme.tertiaryText)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 2)
    }

    private var sign: String {
        switch row.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var signColor: Color {
        row.kind == .added ? Theme.Syntax.inserted : row.kind == .removed ? Theme.Syntax.deleted : Theme.tertiaryText
    }

    private var tint: Color {
        switch row.kind {
        case .added: Theme.successTint
        case .removed: Theme.dangerTint
        default: .clear
        }
    }

    /// "Added, line 6: import re".
    private var spoken: String {
        let line = row.text.isEmpty ? String(localized: "blank line") : row.text
        switch row.kind {
        case .added: return String(localized: "Added, line \(row.newLine ?? 0): \(line)")
        case .removed: return String(localized: "Removed, line \(row.oldLine ?? 0): \(line)")
        default: return String(localized: "Line \(row.newLine ?? row.oldLine ?? 0): \(line)")
        }
    }
}
