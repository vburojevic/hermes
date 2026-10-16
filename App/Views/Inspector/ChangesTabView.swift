import HermesKit
import SwiftUI

/// The Changes tab (`macInspectorChanges`, `inspectorChanges`): scope (This Turn, Branch,
/// Uncommitted), the changed files with their stage boxes, the selected file's diff, and the
/// `shipBar`: the commit message, Commit and Push, Create Pull Request.
struct ChangesTabView: View {
    let inspector: InspectorModel
    let model: ChangesModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 10) {
                    if let error = model.loadError {
                        inlineError(error)
                    }
                    if model.files.isEmpty, !model.isLoading, model.loadError == nil {
                        Text(emptyText)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    VStack(spacing: 2) {
                        ForEach(model.files) { file in
                            ChangeRow(file: file, isSelected: model.selectedFile == file.path, isBusy: model.busyFiles.contains(file.path),
                                      select: { model.selectedFile = file.path },
                                      toggle: { Task { await model.toggleStaged(file) } })
                        }
                    }
                    if let file = model.selectedFile, let diff = model.diff, !diff.isEmpty {
                        DiffCard(path: file, diff: diff)
                            .id("\(file)-\(model.scope.rawValue)")
                            .contextMenu {
                                Button("Open File", systemImage: "doc") { inspector.openFile(file) }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .refreshable { await model.refresh() }
            ShipBar(inspector: inspector, model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .task { await model.loadIfNeeded() }
        .onChange(of: model.pullRequestURL) { _, url in
            if url != nil, let url = model.consumePullRequestURL() { openURL(url) }
        }
    }

    private var emptyText: String {
        switch model.scope {
        case .lastTurn: model.turnBase == nil ? String(localized: "Nothing uncommitted.") : String(localized: "The last turn didn't change any files.")
        case .branch: String(localized: "This branch has no commits beyond the default branch.")
        case .uncommitted: String(localized: "Nothing uncommitted.")
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 10) {
            Picker("Scope", selection: Binding(get: { model.scope }, set: { model.scope = $0 })) {
                Text("This Turn").tag(ReviewScope.lastTurn)
                Text("Branch").tag(ReviewScope.branch)
                Text("Uncommitted").tag(ReviewScope.uncommitted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            if let list = model.list, !list.files.isEmpty {
                Text("\(list.files.count) files · +\(list.added) −\(list.removed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .frame(minHeight: 32)
    }

    private func inlineError(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.dangerWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// `changeRow`: stage box, status letter, path, lines added and removed.
private struct ChangeRow: View {
    let file: ReviewFile
    let isSelected: Bool
    let isBusy: Bool
    let select: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(file.staged ? Theme.ink : .clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(file.staged ? Theme.ink : Theme.tertiaryText, lineWidth: 1.5)
                    if file.staged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.inkForeground)
                    }
                }
                .frame(width: 16, height: 16)
                .opacity(isBusy ? 0.4 : 1)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(file.staged ? Text("Unstage \(file.path)") : Text("Stage \(file.path)"))
            Text(file.letter)
                .font(.caption.weight(.semibold).monospaced())
                .foregroundStyle(GitLetter.color(file.letter))
                .frame(width: 12)
            Text(file.path)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if file.added > 0 {
                Text("+\(file.added)").font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Theme.Syntax.inserted)
            }
            if file.removed > 0 {
                Text("−\(file.removed)").font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Theme.Syntax.deleted)
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 8)
        .frame(minHeight: 36)
        .background(isSelected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(file.path), \(GitLetter.name(file.letter)), \(file.added) added, \(file.removed) removed, \(file.staged ? String(localized: "staged") : String(localized: "not staged"))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// `shipBar`: the commit message (Hermes drafts it when asked), where it goes, and the actions.
private struct ShipBar: View {
    let inspector: InspectorModel
    let model: ChangesModel

    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Commit message", text: Binding(get: { model.message }, set: { model.message = $0; model.edited() }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.footnote)
                .lineLimit(2...6)
                .focused($editing)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 60, alignment: .topLeading)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await model.draftMessage() }
                } label: {
                    HStack(spacing: 4) {
                        if model.isDrafting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                        }
                        Text(model.draftedByHermes ? "Drafted by Hermes" : "Draft with Hermes")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                .buttonStyle(.plain)
                .disabled(model.isDrafting || model.stagedCount == 0)
                .help(model.draftedByHermes ? "Draft another message" : "Hermes writes the message from what's staged")
            }
            if let error = model.shipError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let blocker = model.pullRequestBlocker {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.commitAndPush() }
                } label: {
                    Text("Commit and Push")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .cardButton()
                .disabled(!model.canCommit)
                Button {
                    Task { await model.createPullRequest() }
                } label: {
                    Group {
                        if model.isShipping {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(model.ship?.openPullRequest != nil ? "Open Pull Request" : "Create Pull Request")
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                }
                .inkFilledButton()
                .disabled(model.isShipping || model.pullRequestBlocker != nil || (model.ship?.openPullRequest == nil && model.files.isEmpty && model.stagedCount == 0))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// "feature/beta-page → main · 3 of 4 files staged".
    private var meta: String {
        var parts: [String] = []
        if let branch = model.branchLine { parts.append(branch) }
        if !model.files.isEmpty { parts.append(String(localized: "\(model.stagedCount) of \(model.files.count) files staged")) }
        return parts.joined(separator: " · ")
    }
}
