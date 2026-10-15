import HermesKit
import SwiftUI

// The sheets of undo and checkpoints (`screens/iphone/checkpoints.elyx`,
// `screens/mac/checkpoints.elyx`): Review, the Undo / Restore All confirmation, the timeline with a
// checkpoint's detail, and the off state.

/// Presents the chat's checkpoint sheets.
struct CheckpointSheets: ViewModifier {
    @Bindable var model: CheckpointsModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.sheet) { sheet in
                Group {
                    switch sheet {
                    case .review(let turnID):
                        #if os(macOS)
                        MacCheckpointsSheet(model: model, initial: model.checkpoint(beforeTurn: turnID).map(CheckpointsModel.stableKey))
                        #else
                        ReviewChangesSheet(model: model, turnID: turnID)
                        #endif
                    case .confirm(let target):
                        CheckpointConfirmSheet(model: model, target: target) { model.sheet = nil }
                    case .timeline(let selected):
                        #if os(macOS)
                        MacCheckpointsSheet(model: model, initial: selected)
                        #else
                        CheckpointsTimelineSheet(model: model, initial: selected)
                        #endif
                    case .off:
                        CheckpointsOffSheet(model: model)
                    }
                }
                .modifier(CheckpointAlert(model: model))
            }
    }
}

/// What a checkpoint call said went wrong.
struct CheckpointAlert: ViewModifier {
    @Bindable var model: CheckpointsModel

    func body(content: Content) -> some View {
        content.alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - Review (`reviewChanges`)

/// What a reply changed: the files, a diff, then Done / Undo This Turn.
struct ReviewChangesSheet: View {
    let model: CheckpointsModel
    let turnID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    private var checkpoint: Checkpoint? { model.checkpoint(beforeTurn: turnID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let checkpoint {
                        ChangedFiles(model: model, checkpoint: checkpoint, selected: $selected, footer: footer(checkpoint))
                    } else {
                        Text("Nothing to review: Hermes saved no checkpoint for this turn.")
                            .foregroundStyle(Theme.secondaryText)
                            .padding(20)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.sheetBackground)
            .navigationTitle("Changes in This Turn")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                PairedSheetButtons(
                    secondary: String(localized: "Done"), onSecondary: { dismiss() },
                    primary: String(localized: "Undo This Turn"), symbol: "arrow.uturn.backward",
                    primaryEnabled: checkpoint != nil && model.isOnline && !model.chatIsWorking
                ) {
                    model.undo(turnID: turnID)
                }
            }
        }
    }

    private func footer(_ checkpoint: Checkpoint) -> String {
        let count = model.diff(for: checkpoint)?.files.count ?? 0
        let all = count == 2 ? String(localized: "both") : count == 3 ? String(localized: "all three") : count > 3 ? String(localized: "all \(count)") : String(localized: "it")
        return String(localized: "Tap a file to see its diff. Undo puts \(all) back as they were at \(CheckpointsModel.time(checkpoint.date)).")
    }
}

/// The files that differ from a checkpoint, then the selected one's diff (`reviewChanges`,
/// `checkpointDetail`). With `restores`, each row restores on its own.
struct ChangedFiles: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint
    @Binding var selected: String?
    var footer: String?
    var restores = false
    var countLabel: (CheckpointDiff) -> String = { diff in
        diff.files.count == 1 ? String(localized: "1 file · +\(diff.added) −\(diff.removed)") : String(localized: "\(diff.files.count) files · +\(diff.added) −\(diff.removed)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A restored file matches the checkpoint now, so it leaves the list: say it's back.
            if restores {
                ForEach(model.restoredPaths(from: checkpoint), id: \.self) { path in
                    Label("\((path as NSString).lastPathComponent) is back as it was at \(CheckpointsModel.time(checkpoint.date)).", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 20)
                }
            }
            if let diff = model.diff(for: checkpoint) {
                if diff.files.isEmpty {
                    Text("The files are as they were at \(CheckpointsModel.time(checkpoint.date)).")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 20)
                } else {
                    Text(countLabel(diff))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 20)
                    fileList(diff)
                    if let footer {
                        Text(footer)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 20)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    diffView(diff)
                        .padding(.top, 16)
                }
            } else if let failure = model.diffFailure(for: checkpoint) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
        }
        .task(id: CheckpointsModel.stableKey(checkpoint)) { await model.loadDiff(checkpoint) }
    }

    private func fileList(_ diff: CheckpointDiff) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(diff.files.enumerated()), id: \.element.id) { index, file in
                if index > 0 {
                    Divider().overlay(Theme.separator).padding(.leading, 42)
                }
                // Next to Restore there's room for the name; the diff below has the path.
                CheckpointFileRow(file: file, shortPath: restores, isSelected: shown(diff)?.id == file.id) {
                    if restores {
                        RestoreFileButton(model: model, checkpoint: checkpoint, file: file)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .onTapGesture { selected = file.path }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows its diff")
            }
        }
        .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func shown(_ diff: CheckpointDiff) -> CheckpointFileChange? {
        diff.files.first { $0.path == selected } ?? diff.files.first { $0.diff != nil }
    }

    @ViewBuilder
    private func diffView(_ diff: CheckpointDiff) -> some View {
        if let file = shown(diff) {
            VStack(alignment: .leading, spacing: 6) {
                if let text = file.diff {
                    DiffCard(path: file.path, diff: text)
                        .id(file.path)
                } else {
                    Text(file.isBinary ? String(localized: "\(file.fileName) is a binary file.") : String(localized: "\(file.fileName) changed too, past the part of the diff Hermes sends."))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                if diff.isShortened {
                    Text("The diff is shortened: Hermes sends its first 4,000 characters.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Restore on a file row, then "Restored".
private struct RestoreFileButton: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint
    let file: CheckpointFileChange

    var body: some View {
        if model.wasRestored(file.path, from: checkpoint) {
            Label("Restored", systemImage: "checkmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.success)
                .labelStyle(.titleOnly)
        } else if file.pathIsExact, !(file.change == .created) {
            Button {
                Task { await model.restoreFile(file, from: checkpoint) }
            } label: {
                ZStack {
                    Text("Restore").opacity(model.isWorking(model.fileKey(checkpoint, file.path)) ? 0 : 1)
                    if model.isWorking(model.fileKey(checkpoint, file.path)) { ProgressView().controlSize(.mini) }
                }
            }
            .font(.footnote.weight(.medium))
            .cardButton()
            .controlSize(.small)
            .disabled(!model.isOnline || model.refusal != nil)
            .accessibilityLabel("Restore \(file.fileName)")
        }
    }
}

/// Done and the prominent action across a sheet's bottom, in glass (`reviewChanges`,
/// `checkpointDetail`).
struct PairedSheetButtons: View {
    let secondary: String
    let onSecondary: () -> Void
    let primary: String
    var symbol: String?
    var primaryEnabled = true
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSecondary) {
                Text(secondary).frame(maxWidth: .infinity)
            }
            .glassButton()
            Button(action: onPrimary) {
                Group {
                    if let symbol { Label(primary, systemImage: symbol) } else { Text(primary) }
                }
                .frame(maxWidth: .infinity)
            }
            .prominentGlassButton()
            .disabled(!primaryEnabled)
        }
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .controlSize(.extraLarge)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Undo / Restore All (`undoConfirm`)

/// The confirmation: what goes back, which turns leave the chat, the files, what's replaced.
struct CheckpointConfirmSheet: View {
    let model: CheckpointsModel
    let target: CheckpointsModel.Target
    let close: () -> Void
    @AccessibilityFocusState private var cancelFocused: Bool
    @State private var contentHeight: CGFloat = 420

    private var time: String { CheckpointsModel.time(target.checkpoint.date) }
    private var turns: [CheckpointMatcher.Span] { model.turnsRemoved(restoring: target.checkpoint) }
    private var isUndo: Bool { target.turnID != nil && turns.count <= 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityHidden(true)
                Text(isUndo ? String(localized: "Undo this turn?") : String(localized: "Go back to \(time)?"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !isUndo, turns.count > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(turns, id: \.userID) { span in
                            Label("“\(span.text)”", systemImage: "minus.circle")
                                .font(.subheadline)
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(2)
                        }
                    }
                }
                files
                warning
                if model.chatIsWorking {
                    Label("Hermes is still working. You can undo when it stops.", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                } else if !model.isOnline {
                    Label("\(model.gatewayName) is offline.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            buttons
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .task { await model.loadDiff(target.checkpoint) }
        .onAppear { cancelFocused = true }
        #if os(iOS)
        .presentationDetents([.height(min(contentHeight + 90, 720)), .large])
        .presentationDragIndicator(.hidden)
        #else
        .frame(width: 440)
        .frame(minHeight: 380)
        #endif
    }

    private var explanation: String {
        let gone: String = switch turns.count {
        case 0: ""
        case 1: isUndo ? String(localized: " and removes the turn from this chat. Your message comes back to the composer.") : String(localized: " and removes 1 turn from this chat:")
        default: String(localized: " and removes \(turns.count) turns from this chat:")
        }
        return String(localized: "Hermes puts these files back as they were at \(time)") + (gone.isEmpty ? "." : gone)
    }

    @ViewBuilder
    private var files: some View {
        if let diff = model.diff(for: target.checkpoint) {
            if !diff.files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(diff.files.prefix(6).enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 42) }
                        CheckpointFileRow(file: file, shortPath: true) { EmptyView() }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 46)
                    }
                    if diff.files.count > 6 {
                        Text("and \(diff.files.count - 6) more")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                    }
                }
                .background(Theme.sheetCell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else if let failure = model.diffFailure(for: target.checkpoint) {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    /// What's replaced, and what a full overwrite leaves (files Hermes created stay).
    private var warning: some View {
        let created = model.diff(for: target.checkpoint)?.files.filter { $0.change == .created } ?? []
        let stays: String = switch created.count {
        case 0: ""
        case 1: String(localized: " \(created[0].fileName) stays: Hermes doesn't delete files it created.")
        default: String(localized: " \(created.map(\.fileName).formatted(.list(type: .and))) stay: Hermes doesn't delete files it created.")
        }
        return Label {
            Text(String(localized: "Changes you made to these files after \(time) are replaced too.") + stays)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .cardButton()
            .keyboardShortcut(.cancelAction)
            .accessibilityFocused($cancelFocused)
            Button(role: .destructive) {
                Task { await model.restoreAll(target) }
            } label: {
                ZStack {
                    Text(isUndo ? String(localized: "Undo Turn") : String(localized: "Restore All"))
                        .foregroundStyle(Theme.danger)
                        .opacity(model.isWorking(model.allKey(target.checkpoint)) ? 0 : 1)
                    if model.isWorking(model.allKey(target.checkpoint)) { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            }
            .cardButton()
            .disabled(model.chatIsWorking || !model.isOnline || model.isWorking(model.allKey(target.checkpoint)))
        }
        .font(.body.weight(.semibold))
        .controlSize(.extraLarge)
    }
}

// MARK: - Timeline (`checkpointsTimeline`, `checkpointDetail`)

struct CheckpointsTimelineSheet: View {
    let model: CheckpointsModel
    var initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            CheckpointsTimelineList(model: model) { checkpoint in
                path.append(CheckpointsModel.stableKey(checkpoint))
            }
            .navigationTitle("Checkpoints")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                }
            }
            .navigationDestination(for: String.self) { key in
                if let checkpoint = model.checkpoints.first(where: { CheckpointsModel.stableKey($0) == key }) {
                    CheckpointDetailView(model: model, checkpoint: checkpoint)
                }
            }
        }
        .task { await model.refresh(force: true) }
        .onAppear { if let initial { path = [initial] } }
    }
}

/// The folder, Now, then each checkpoint, newest first; or the empty, off and offline states.
struct CheckpointsTimelineList: View {
    let model: CheckpointsModel
    var selected: String?
    /// The Mac's sheet: the folder is in its header, the rows sit on the sheet, no footer.
    var isSidebar = false
    let open: (Checkpoint) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let folder = model.folder, !isSidebar {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                        Text("Folder \(folder) on \(model.gatewayName)")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, 20)
                }
                content
            }
            .padding(.vertical, 12)
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
    }

    @ViewBuilder
    private var content: some View {
        if model.isEnabled == false {
            CheckpointsOffView(model: model)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if model.list == nil {
            if let failure = model.loadFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 20)
            } else if !model.isOnline {
                Label("\(model.gatewayName) is offline.", systemImage: "wifi.slash")
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 20)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        } else {
            if !model.isOnline {
                Label("\(model.gatewayName) is offline. This is the last list; restoring waits until it's back.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 20)
            }
            if let refusal = model.refusal {
                Label(refusal, systemImage: "shippingbox")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            rows
                .opacity(model.isOnline ? 1 : 0.55)
            if !isSidebar || model.timeline.isEmpty {
            Text(model.timeline.isEmpty
                 ? (model.justTurnedOn ? String(localized: "Checkpoints are on. They start with the next turn that edits files.") : String(localized: "Nothing to undo yet. Hermes saves the folder before the next turn that edits files."))
                 : CheckpointLimits.footer)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: some View {
        let timeline = model.timeline
        return VStack(spacing: 0) {
            CheckpointTimelineRow(
                time: String(localized: "Now"),
                title: String(localized: "Current files on \(model.gatewayName)"),
                detail: [model.folder, model.branch].compactMap { $0 }.joined(separator: " · "),
                isNow: true, isLast: timeline.isEmpty, showsChevron: false
            )
            .padding(.leading, 14)
            .padding(.trailing, 16)
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, checkpoint in
                Button {
                    open(checkpoint)
                } label: {
                    CheckpointTimelineRow(
                        time: CheckpointsModel.time(checkpoint.date),
                        title: model.title(for: checkpoint),
                        detail: changedLine(checkpoint),
                        isLast: index == timeline.count - 1
                    )
                    .padding(.leading, 14)
                    .padding(.trailing, 16)
                    .background(selected == CheckpointsModel.stableKey(checkpoint) ? Theme.rowSelected : .clear,
                                in: RoundedRectangle(cornerRadius: isSidebar ? 10 : 0, style: .continuous))
                }
                .buttonStyle(.plain)
                .task { await model.loadDiff(checkpoint) }
            }
        }
        .background(isSidebar ? Color.clear : Theme.sheetCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: isSidebar ? 0 : 22, style: .continuous))
        .padding(.horizontal, isSidebar ? 8 : 16)
    }

    private func changedLine(_ checkpoint: Checkpoint) -> String? {
        guard let diff = model.diff(for: checkpoint) else { return model.diffFailure(for: checkpoint) == nil ? " " : nil }
        switch diff.files.count {
        case 0: return String(localized: "Same as now")
        case 1: return String(localized: "1 file changed after this")
        default: return String(localized: "\(diff.files.count) files changed after this")
        }
    }
}

/// One checkpoint (`checkpointDetail`): compared with the files now, Restore per file, the diff,
/// then Done / Restore All.
struct CheckpointDetailView: View {
    let model: CheckpointsModel
    let checkpoint: Checkpoint
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var confirming: CheckpointsModel.Target?

    private var time: String { CheckpointsModel.time(checkpoint.date) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(time) · \(model.title(for: checkpoint))")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Compared with the files now")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 20)
                ChangedFiles(
                    model: model, checkpoint: checkpoint, selected: $selected,
                    footer: String(localized: "Restore one file to how it was at \(time) without touching the chat; it works even while Hermes is busy."),
                    restores: true,
                    countLabel: { diff in
                        diff.files.count == 1 ? String(localized: "1 file differs · +\(diff.added) −\(diff.removed)") : String(localized: "\(diff.files.count) files differ · +\(diff.added) −\(diff.removed)")
                    }
                )
            }
            .padding(.vertical, 12)
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
        .navigationTitle(time)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaBar(edge: .bottom) {
            PairedSheetButtons(
                secondary: String(localized: "Done"), onSecondary: { model.sheet = nil },
                primary: String(localized: "Restore All"), symbol: "arrow.uturn.backward",
                primaryEnabled: model.isOnline && !model.chatIsWorking && model.refusal == nil
            ) {
                confirming = CheckpointsModel.Target(checkpoint: checkpoint)
            }
        }
        .sheet(item: $confirming) { target in
            CheckpointConfirmSheet(model: model, target: target) { confirming = nil }
                .modifier(CheckpointAlert(model: model))
        }
    }
}

extension CheckpointsModel.Target: Identifiable {
    var id: String { CheckpointsModel.stableKey(checkpoint) }
}

// MARK: - Off (`checkpointsOffSheet`)

struct CheckpointsOffSheet: View {
    let model: CheckpointsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                CheckpointsOffView(model: model)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Theme.sheetBackground)
            .navigationTitle("Checkpoints")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }
}
