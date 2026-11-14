import HermesKit
import SwiftUI

/// Sidebar sizes per platform, from the Elyx rows (`navRow`, `sessionRow`, `botRow`,
/// `sectionHeader` on iPhone and iPad; `macSidebarRow` on the Mac).
enum SidebarMetrics {
    #if os(macOS)
    static let rowHeight: CGFloat = 30
    static let botRowHeight: CGFloat = 44
    static let rowRadius: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let glyphSize: CGFloat = 15
    static let avatarSize: CGFloat = 22
    /// Roster rows (`docs/bot-faces.md` §4).
    static let faceSize: CGFloat = 28
    static let navFont = Font.system(size: 13)
    static let titleFont = Font.system(size: 13)
    static let selectedTitleFont = Font.system(size: 13, weight: .medium)
    static let nameFont = Font.system(size: 13, weight: .semibold)
    static let previewFont = Font.system(size: 11)
    static let gatewayFont = Font.system(size: 13, weight: .semibold)
    static let sectionFont = Font.system(size: 11, weight: .semibold)
    static let glyphColor = Theme.secondaryText
    #else
    static let rowHeight: CGFloat = 44
    static let botRowHeight: CGFloat = 60
    static let rowRadius: CGFloat = 12
    static let rowPadding: CGFloat = 12
    static let glyphSize: CGFloat = 20
    static let avatarSize: CGFloat = 32
    static let faceSize: CGFloat = 36
    static let navFont = Font.callout.weight(.medium)
    static let titleFont = Font.callout
    static let selectedTitleFont = Font.callout.weight(.medium)
    static let nameFont = Font.subheadline.weight(.semibold)
    static let previewFont = Font.footnote
    static let gatewayFont = Font.title3.weight(.semibold)
    static let sectionFont = Font.footnote.weight(.semibold)
    static let glyphColor = Theme.primaryText
    #endif
    /// The rows' inset from the sidebar's edges; the highlight sits inside it.
    static let listInset: CGFloat = 8
    static var rowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: listInset + rowPadding, bottom: 0, trailing: listInset + rowPadding)
    }
}

extension EnvironmentValues {
    /// Whether rows show which one is open. On iPhone the list is its own screen, so a row
    /// stays plain once its chat is pushed and the person comes back.
    @Entry var sidebarShowsSelection = true
    /// Whether the window is as narrow as an iPhone, so the list is a screen of its own. Read from
    /// the window: inside a split view's sidebar column the size class is always compact, even on
    /// an iPad in landscape.
    @Entry var sidebarIsCompact = false
}

/// A row in the sidebar: a quiet rounded wash when selected, and a lighter one under the
/// pointer. The system list selection would fill with the Mac's accent colour instead.
struct SidebarRow<Label: View>: View {
    let isSelected: Bool
    var height: CGFloat = SidebarMetrics.rowHeight
    let action: () -> Void
    @ViewBuilder let label: Label

    @Environment(\.sidebarShowsSelection) private var showsSelection
    @State private var isHovered = false

    var body: some View {
        let isLit = isSelected && showsSelection
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primaryText)
        .accessibilityAddTraits(isLit ? .isSelected : [])
        .onHover { isHovered = $0 }
        .listRowBackground(
            RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous)
                .fill(isLit ? Theme.rowSelected : isHovered ? Theme.rowHover : .clear)
                .padding(.horizontal, SidebarMetrics.listInset)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        )
        .listRowSeparator(.hidden)
        .listRowInsets(SidebarMetrics.rowInsets)
    }
}

/// Insets for a row that isn't a `SidebarRow` (a title, a toggle, a spinner).
struct SidebarRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(SidebarMetrics.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// New Chat, Tasks, Skills; All Bots, New Bot: a glyph and a label.
struct SidebarNavRow: View {
    let title: LocalizedStringKey
    let symbol: String
    var isSelected = false
    var shortcut: String?
    let action: () -> Void

    // The glyph grows with its label on iPhone and iPad, up to 1.6 times, so "New Chat" keeps
    // its one line at the largest sizes.
    #if os(macOS)
    private let glyphSize = SidebarMetrics.glyphSize
    #else
    @ScaledMetric(relativeTo: .callout) private var scaledGlyph = SidebarMetrics.glyphSize
    private var glyphSize: CGFloat { min(scaledGlyph, SidebarMetrics.glyphSize * 1.6) }
    #endif

    var body: some View {
        SidebarRow(isSelected: isSelected, action: action) {
            HStack(spacing: SidebarMetrics.rowPadding) {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize * 0.82, weight: .regular))
                    .foregroundStyle(SidebarMetrics.glyphColor)
                    .frame(width: glyphSize, height: glyphSize)
                    .accessibilityHidden(true)
                Text(title)
                    .font(SidebarMetrics.navFont)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
            }
        }
        .help(shortcut.map { Text("\(Text(title)) (\($0))") } ?? Text(title))
    }
}

/// "Pinned", "Today", "Your Bots": a quiet title row between groups.
struct SidebarSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(SidebarMetrics.sectionFont)
            .foregroundStyle(Theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .modifier(SidebarRowInsets())
            .accessibilityAddTraits(.isHeader)
    }
}

/// The bottom of the sidebar (iPad, Mac): how the gateway (or Bot Mode) is doing, and Settings.
/// On iPhone the list's subtitle and its gear say the same.
struct SidebarFooter: View {
    let workspace: BotWorkspace

    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    // Settings' gear grows with the status line beside it, up to 1.5 times.
    @ScaledMetric(relativeTo: .footnote) private var scaledGear: CGFloat = 15
    private var gearSize: CGFloat { min(scaledGear, 22) }
    private var gearSide: CGFloat { gearSize + 7 }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Hermes at background priority on its Mac: one line above the connection
            // (`docs/setup.md` §4.17).
            if let notice = workspace.setup.priorityNotice {
                MacPriorityNotice(setup: workspace.setup, notice: notice)
            } else if workspace.setup.priorityPutBack {
                MacPriorityPutBack()
                    .transition(.opacity)
            }
            #endif
            row
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var row: some View {
        #if os(macOS)
        HStack(spacing: 10) {
            ConnectionStatusLabel(workspace: workspace)
            Spacer(minLength: 8)
            settingsButton
        }
        .modifier(SidebarFooterPadding())
        #else
        if dynamicTypeSize.isAccessibilitySize {
            // Beside the gear, "Connected" no longer fits a line: the status takes the full width
            // and the gear sits under it (`docs/inbox.md` §6).
            VStack(alignment: .leading, spacing: 8) {
                ConnectionStatusLabel(workspace: workspace)
                    .frame(maxWidth: .infinity, alignment: .leading)
                settingsButton
            }
            .modifier(SidebarFooterPadding())
        } else {
            HStack(spacing: 10) {
                ConnectionStatusLabel(workspace: workspace)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(SidebarFooterPadding())
        }
        #endif
    }

    private var settingsButton: some View {
        Button {
            #if os(macOS)
            openSettings()
            #else
            router?.sheet = .settings
            #endif
        } label: {
            Image(systemName: "gearshape")
                #if os(macOS)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 20, height: 20)
                #else
                .font(.system(size: gearSize, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: gearSide, height: gearSide)
                #endif
        }
        #if os(macOS)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        #else
        .glassButton()
        .buttonBorderShape(.circle)
        #endif
        .accessibilityLabel("Settings")
        .help("Settings")
    }
}

private struct SidebarFooterPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
    }
}

/// An empty, loading or problem state, centred in the free space below the navigation rows
/// (`docs/design-to-swiftui.md` §8).
struct SidebarState: View {
    var symbol: String?
    var isLoading = false
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                Spinner(size: .regular)
                    .padding(.bottom, 4)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .cardButton()
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
