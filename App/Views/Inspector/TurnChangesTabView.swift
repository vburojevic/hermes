import HermesKit
import SwiftUI

/// The Changed Files tab (`docs/inspector.md` §2.7): what one turn did to files, from the chat
/// itself, so it works without Bot Mode. The files on top, the selected one's diff below. On the
/// Mac ↑ and ↓ move between files and Esc closes the tab.
struct TurnChangesTabView: View {
    let inspector: InspectorModel
    let conversation: ConversationModel
    let tab: InspectorTab

    @AppStorage(PreferenceKey.wrapsDiffLines) private var wraps = false
    @FocusState private var listFocused: Bool

    private var key: String? { inspector.changesTurn ?? conversation.latestChangesKey }

    var body: some View {
        let changes = key.flatMap { conversation.changes(forTurn: $0) }
        VStack(spacing: 0) {
            if let changes, !changes.isEmpty {
                let file = selectedFile(in: changes)
                header(changes)
                fileList(changes, selected: file?.path)
                Divider().overlay(Theme.hairline)
                if let file {
                    fileBar(file)
                    ChangedFileNotes(file: file)
                    ChangedFileDiff(file: file, wraps: wraps)
                        .id(file.path)
                }
            } else {
                ContentUnavailableView("No changed files", systemImage: "plus.forwardslash.minus",
                                       description: Text("Files a turn edits show here. Tap a turn's Changes row to see its files."))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .background(Theme.canvas)
        #if os(macOS)
        .onExitCommand { inspector.close(tab.id) }
        #endif
    }

    private func selectedFile(in changes: TurnChanges) -> ChangedFile? {
        if let path = inspector.changesFile, let file = changes.file(path) { return file }
        return changes.changedFiles.first ?? changes.files.first
    }

    private func header(_ changes: TurnChanges) -> some View {
        HStack(spacing: 8) {
            Text(changes.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            if !changes.changedFiles.isEmpty {
                DiffCounts(added: changes.added, removed: changes.removed)
                    .font(.footnote.monospacedDigit())
            }
            Spacer(minLength: 0)
            if key == conversation.liveChanges?.key, conversation.isWorking {
                // Still: the turn's own header is the live line (`docs/chat.md` §4a).
                Text("Hermes is still working")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func fileList(_ changes: TurnChanges, selected: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(changes.files) { file in
                        Button { select(file.path) } label: {
                            ChangedFileRow(file: file, isSelected: file.path == selected)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(file.path == selected ? Theme.surfaceRaised : .clear,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(file.path)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: listHeight(changes.files.count))
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: changes, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, in: changes, proxy: proxy) }
            .accessibilityLabel("Changed files")
        }
    }

    /// Up to about five rows, then the list scrolls: the diff keeps most of the panel.
    private func listHeight(_ count: Int) -> CGFloat {
        CGFloat(min(count, 5)) * 50 + 8
    }

    private func fileBar(_ file: ChangedFile) -> some View {
        HStack(spacing: 10) {
            Text(file.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Toggle(isOn: $wraps) {
                Label("Wrap Lines", systemImage: "text.word.spacing")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Wrap Lines")
            if file.change != .deleted {
                Button("Open") { inspector.openFile(file.path) }
                    .font(.footnote.weight(.medium))
                    .cardButton()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Open \(file.name)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func select(_ path: String) {
        inspector.changesFile = path
        listFocused = true
    }

    private func move(_ step: Int, in changes: TurnChanges, proxy: ScrollViewProxy) -> KeyPress.Result {
        let paths = changes.files.map(\.path)
        guard !paths.isEmpty else { return .ignored }
        let current = selectedFile(in: changes).flatMap { paths.firstIndex(of: $0.path) } ?? 0
        let next = min(max(current + step, 0), paths.count - 1)
        inspector.changesFile = paths[next]
        proxy.scrollTo(paths[next])
        return .handled
    }
}
