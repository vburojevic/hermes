import HermesKit
import HermesMarkdown
import SwiftUI

// MARK: - Files

/// The Files tab: the chat's folder as a tree (`fileTreeRow`) with git letters. A file opens in
/// its own File tab.
struct FilesTabView: View {
    let inspector: InspectorModel
    let tree: FileTreeModel
    var selectedPath: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let error = tree.errors[tree.root] {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .padding(10)
                }
                ForEach(tree.rows, id: \.entry.path) { row in
                    FileTreeRow(entry: row.entry, depth: row.depth, isExpanded: tree.expanded.contains(row.entry.path),
                                letter: row.entry.isDirectory ? nil : tree.letter(for: row.entry.path),
                                isSelected: row.entry.path == selectedPath) {
                        if row.entry.isDirectory {
                            withAnimation(Theme.snappy) { tree.toggle(row.entry) }
                        } else {
                            inspector.openFile(row.entry.path)
                        }
                    }
                }
                if tree.loading.contains(tree.root), tree.rows.isEmpty {
                    SkeletonRows(count: 4, twoLines: false)
                        .padding(12)
                }
            }
            .padding(6)
        }
        .refreshable { await tree.refresh() }
        .task { await tree.loadIfNeeded() }
    }
}

/// `fileTreeRow`: disclosure, folder or file glyph, name, git letter.
private struct FileTreeRow: View {
    let entry: WorkspaceEntry
    let depth: Int
    let isExpanded: Bool
    let letter: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(entry.isDirectory ? 1 : 0)
                    .frame(width: 10)
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 15)
                Text(entry.name)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let letter {
                    Text(letter)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(GitLetter.color(letter))
                }
            }
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 6)
            .frame(minHeight: 26)
            .background(isSelected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibility: String {
        var parts = [entry.name, entry.isDirectory ? String(localized: "folder") : String(localized: "file")]
        if let letter { parts.append(GitLetter.name(letter)) }
        if entry.isDirectory { parts.append(isExpanded ? String(localized: "expanded") : String(localized: "collapsed")) }
        return parts.joined(separator: ", ")
    }
}

/// Git status letters and their colours (`changeRow`, `fileTreeRow`).
enum GitLetter {
    static func color(_ letter: String) -> Color {
        switch letter {
        case "A": Theme.success
        case "D", "U": Theme.danger
        default: Theme.warning
        }
    }

    static func name(_ letter: String) -> String {
        switch letter {
        case "A": String(localized: "added")
        case "D": String(localized: "deleted")
        case "U": String(localized: "conflict")
        case "R": String(localized: "renamed")
        default: String(localized: "modified")
        }
    }
}

// MARK: - File

/// A File tab (`macInspectorFiles`): the path, Edited and Save, then the code with line numbers.
/// Wide panels keep the project tree beside it.
struct FileTabView: View {
    let inspector: InspectorModel
    let editor: FileEditorModel

    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if width >= 560, let root = inspector.workingFolder, editor.path.hasPrefix(root) {
                FilesTabView(inspector: inspector, tree: inspector.tree(root: root), selectedPath: editor.path)
                    .frame(width: min(200, width * 0.34))
                    .task { await inspector.tree(root: root).reveal(editor.path) }
                Divider().overlay(Theme.hairline)
            }
            FileEditorView(inspector: inspector, editor: editor)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct FileEditorView: View {
    let inspector: InspectorModel
    let editor: FileEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if let conflict = editor.conflict, case .changedOnGateway = conflict {
                conflictNote
            }
            if let error = editor.saveError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.dangerWash)
            }
            content
            if editor.hasLoaded {
                Divider().overlay(Theme.hairline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
            }
        }
        .task { await editor.loadIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(relativePath)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if editor.isEdited {
                TagLabel(title: String(localized: "Edited"), style: .warning)
            }
            if editor.isEditable {
                Button {
                    Task { await editor.save() }
                } label: {
                    if editor.isSaving {
                        Spinner()
                    } else {
                        Text("Save")
                    }
                }
                .font(.footnote.weight(.semibold))
                .inkFilledButton()
                .disabled(!editor.isEdited || editor.isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var content: some View {
        if let error = editor.loadError {
            StateMessage(symbol: "doc.badge.ellipsis", title: String(localized: "Couldn't open this file"), message: error,
                         actionTitle: String(localized: "Try Again")) { Task { await editor.load() } }
        } else if !editor.hasLoaded {
            Spinner(size: .regular).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if editor.isBinary {
            StateMessage(symbol: "doc", title: String(localized: "This file isn't text"), message: nil)
        } else {
            CodeTextView(
                text: Binding(get: { editor.text }, set: { editor.text = $0 }),
                language: editor.language,
                isEditable: editor.isEditable,
                changedLines: CodeTextView.changedLines(from: editor.original, to: editor.text),
                onCaretLine: { editor.caretLine = $0 }
            )
        }
    }

    /// "Hermes changed this file": Reload or Keep Mine.
    private var conflictNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes changed this file")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("It changed on \(inspector.gatewayMachineName) since you opened it.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Button("Reload") { editor.takeTheirs() }
                .font(.footnote)
                .cardButton()
            Button("Keep Mine") { Task { await editor.keepMine() } }
                .font(.footnote.weight(.semibold))
                .inkFilledButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.warningTint)
    }

    private var relativePath: String {
        if let root = inspector.workingFolder, editor.path.hasPrefix(root + "/") { return String(editor.path.dropFirst(root.count + 1)) }
        return editor.path
    }

    /// "TypeScript · line 8 · you changed 1 line · Hermes sees your edit next turn".
    private var statusLine: String {
        var parts: [String] = []
        if let language = CodeHighlighter.displayName(for: editor.language) { parts.append(language) }
        parts.append(String(localized: "line \(editor.caretLine)"))
        if editor.isTruncated { parts.append(String(localized: "first 512 KB, read only")) }
        let changed = editor.changedLines
        if changed > 0 {
            parts.append(changed == 1 ? String(localized: "you changed 1 line") : String(localized: "you changed \(changed) lines"))
        }
        if editor.savedOnce, !editor.isEdited { parts.append(String(localized: "Hermes sees your edit next turn")) }
        return parts.joined(separator: " · ")
    }
}
