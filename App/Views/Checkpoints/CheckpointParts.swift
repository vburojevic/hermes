import HermesKit
import SwiftUI

// Parts of undo and checkpoints (`blocks/checkpoints.elyx`). Transcript content: `surface`
// fills, never glass.

extension EnvironmentValues {
    /// The chat's checkpoints, for replies that changed files.
    @Entry var checkpoints: CheckpointsModel?
}

/// Where an undone turn was (`restoredNote`): what went back, then what stayed or failed.
struct RestoredNoteRow: View {
    let note: RestoredNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .foregroundStyle(Theme.secondaryText)
                ForEach(note.details, id: \.self) { line in
                    Text(line).foregroundStyle(Theme.tertiaryText)
                }
                ForEach(note.warnings, id: \.self) { line in
                    Text(line).foregroundStyle(Theme.warning)
                }
            }
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One file of a checkpoint (`checkpointFileRow`, `checkpointFileRowNew`): the path, +/− or "new", then
/// a chevron or an action.
struct CheckpointFileRow<Accessory: View>: View {
    let file: CheckpointFileChange
    var shortPath = false
    var isSelected = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.change == .created ? "plus" : "doc.text")
                .font(.system(size: 13, weight: file.change == .created ? .semibold : .regular))
                .foregroundStyle(file.change == .created ? Theme.Syntax.inserted : Theme.secondaryText)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(shortPath ? file.fileName : file.path)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch file.change {
                case .created:
                    Text("new").foregroundStyle(Theme.Syntax.inserted)
                case .deleted:
                    Text("deleted").foregroundStyle(Theme.Syntax.deleted)
                default:
                    if file.isBinary {
                        Text("binary").foregroundStyle(Theme.tertiaryText)
                    } else {
                        HStack(spacing: 6) {
                            Text("+\(file.added)").foregroundStyle(Theme.Syntax.inserted)
                            Text("−\(file.removed)").foregroundStyle(Theme.Syntax.deleted)
                        }
                    }
                }
            }
            .font(.footnote.monospacedDigit())
            accessory
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        switch file.change {
        case .created: String(localized: "\(file.path), new file")
        case .deleted: String(localized: "\(file.path), deleted")
        default: String(localized: "\(file.path), \(file.added) lines added, \(file.removed) removed")
        }
    }
}

/// A checkpoint in the timeline (`checkpointRow`, `checkpointRowNow`): a dot on a rail, the
/// time, what it was before, and how much changed after it.
struct CheckpointTimelineRow: View {
    let time: String
    let title: String
    let detail: String?
    var isNow = false
    var isFirst = false
    var isLast = false
    var showsChevron = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .top) {
                if !isLast {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 2)
                        .padding(.top, 20)
                }
                Circle()
                    .fill(isNow ? Theme.primaryText : Theme.sheetCell)
                    .overlay { Circle().strokeBorder(isNow ? Theme.primaryText : Theme.secondaryText, lineWidth: 2) }
                    .frame(width: 12, height: 12)
                    .padding(.top, 16)
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(time)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.top, 11)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// `checkpointsOff`: what checkpoints do, Turn On, and the limits.
struct CheckpointsOffView: View {
    let model: CheckpointsModel
    @Environment(WindowRouter.self) private var router: WindowRouter?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            Text("Undo for files is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text("With checkpoints on, Hermes saves the folder before each turn that edits files, so you can put things back.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.turnOn() }
            } label: {
                ZStack {
                    Text("Turn On Checkpoints").opacity(model.isWorking("on") ? 0 : 1)
                    if model.isWorking("on") { Spinner().tint(Theme.inkForeground) }
                }
                .font(.subheadline.weight(.semibold))
            }
            .inkFilledButton()
            .disabled(model.isWorking("on") || !model.isOnline)
            .padding(.top, 4)
            if !model.isOnline, let workspace = model.workspace {
                // Turning it on goes through Bot Mode (`docs/setup.md` §4.6).
                SetupNote(status: GatewaySetup.needsBotMode(id: GatewaySetup.ID.checkpoints, title: String(localized: "Undo for Files"), workspace.setup.facts),
                          actionTitle: workspace.botModeIsDown ? String(localized: "Edit Gateway…") : nil,
                          action: workspace.botModeIsDown ? { router?.sheet = .editGateway(workspace.bot) } : nil)
            }
            if model.turnOnFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hermes couldn't change the setting from here. On \(model.gatewayName), run:")
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                    SetupCommand(command: model.turnOnCommand)
                    SetupDocsLink(url: GatewaySetup.Docs.checkpoints)
                        .font(.footnote)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(CheckpointLimits.line(gateway: model.gatewayName))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .frame(maxWidth: 360)
    }
}

/// The gateway's limits: 20 per folder, 7 days, 500 MB, files over 10 MB skipped. `hermes serve`
/// builds its chats with these defaults whatever the config says.
enum CheckpointLimits {
    static func line(gateway: String) -> String {
        String(localized: "On \(gateway) · last 20 per folder, kept 7 days, up to 500 MB")
    }

    static let footer = String(localized: "Hermes saves the folder before each turn that edits files. The last 20 are kept for 7 days; files over 10 MB aren't saved.")
}
