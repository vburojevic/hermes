import HermesKit
import SwiftUI

/// The Mac's checkpoints (`macCheckpoints`), and iPad's (`ipadCheckpoints`): one sheet, the
/// timeline on the left and the selected checkpoint's files and diff on the right; Restore per
/// file, then Restore All… in the footer (with Done on the Mac; iPad has it in the bar).
struct MacCheckpointsSheet: View {
    let model: CheckpointsModel
    var initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var file: String?
    @State private var confirming: CheckpointsModel.Target?

    private var checkpoint: Checkpoint? {
        model.timeline.first { CheckpointsModel.stableKey($0) == selected }
            ?? model.checkpoints.first { CheckpointsModel.stableKey($0) == selected }
    }

    var body: some View {
        #if os(macOS)
        sheet
            .frame(width: 820, height: 560)
        #else
        // iPad (`ipadCheckpoints`): a centred sheet with Close and Done in its bar.
        NavigationStack {
            sheet
                .navigationTitle("Checkpoints")
                .navigationSubtitle(model.folder.map { "\($0) on \(model.gatewayName)" } ?? "")
                .navigationBarTitleDisplayMode(.inline)
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
        .frame(width: 800, height: 600)
        #endif
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            Divider()
            #endif
            if model.isEnabled == false {
                CheckpointsOffView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    CheckpointsTimelineList(model: model, selected: selected, isSidebar: true) { checkpoint in
                        selected = CheckpointsModel.stableKey(checkpoint)
                        file = nil
                    }
                    .frame(width: 300)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            Divider()
            footer
        }
        .background(Theme.sheetBackground)
        .task {
            await model.refresh(force: true)
            if selected == nil { selected = initial ?? model.timeline.first.map(CheckpointsModel.stableKey) }
        }
        .sheet(item: $confirming) { target in
            CheckpointConfirmSheet(model: model, target: target) { confirming = nil }
                .modifier(CheckpointAlert(model: model))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Checkpoints")
                .font(.headline)
            if let folder = model.folder {
                Text("\(folder) on \(model.gatewayName)")
                    .font(.callout.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        if let checkpoint {
            ScrollView {
                ChangedFiles(
                    model: model, checkpoint: checkpoint, selected: $file,
                    footer: String(localized: "Restore one file to how it was at \(CheckpointsModel.time(checkpoint.date)) without touching the chat; it works even while Hermes is busy."),
                    restores: true,
                    countLabel: { diff in
                        diff.files.count == 1 ? String(localized: "1 file differs from now") : String(localized: "\(diff.files.count) files differ from now")
                    }
                )
                .padding(.vertical, 16)
            }
            .id(CheckpointsModel.stableKey(checkpoint))
        } else if model.isEnabled == true, model.timeline.isEmpty {
            ContentUnavailableView("Nothing to undo yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Hermes saves the folder before the next turn that edits files."))
        } else {
            ContentUnavailableView("Pick a checkpoint", systemImage: "clock.arrow.circlepath")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let checkpoint {
                let turns = model.turnsRemoved(restoring: checkpoint)
                Text(turns.count == 1
                     ? String(localized: "Restore All also removes the last turn from this chat.")
                     : String(localized: "Restore All also removes \(turns.count) turns from this chat."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            #if os(macOS)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            #endif
            Button("Restore All…") {
                if let checkpoint { confirming = CheckpointsModel.Target(checkpoint: checkpoint) }
            }
            .keyboardShortcut(.defaultAction)
            #if os(macOS)
            .inkDefaultButton()
            #else
            .prominentGlassButton()
            #endif
            .disabled(checkpoint == nil || !model.isOnline || model.chatIsWorking || model.refusal != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
