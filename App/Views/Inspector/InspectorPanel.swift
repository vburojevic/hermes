import HermesKit
import SwiftUI

/// The Inspector's body (`docs/inspector.md` §1): the glass tab strip, then the selected tab's
/// content on a solid fill. The same view sits beside the chat (Mac, iPad landscape), in the
/// sheet (iPhone, iPad portrait), and in a tab's own window (Mac).
struct InspectorPanel: View {
    enum Style { case panel, sheet, window }

    let inspector: InspectorModel
    let conversation: ConversationModel
    let workspace: BotWorkspace
    var style = Style.panel
    /// Shows only this tab (a tab's own window).
    var onlyTab: String?

    @Environment(\.colorScheme) private var colorScheme

    private var shown: InspectorTab? {
        if let onlyTab { return inspector.tab(onlyTab) }
        return inspector.selected
    }

    var body: some View {
        VStack(spacing: 0) {
            if onlyTab == nil {
                InspectorTabStrip(inspector: inspector, style: style)
                    .padding(.horizontal, style == .sheet ? 12 : 8)
                    .padding(.top, style == .sheet ? 4 : 8)
                    .padding(.bottom, 6)
            }
            Group {
                if let tab = shown {
                    InspectorTabContent(tab: tab, inspector: inspector, conversation: conversation, workspace: workspace)
                        .id(tab.id)
                } else {
                    InspectorOpenGrid(inspector: inspector)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(style == .sheet ? Color.clear : Theme.canvas)
        // Cards inside the Inspector don't offer to open themselves in it.
        .environment(\.inspectorModel, nil)
        .focusedValue(\.inspectorPanel, inspector)
        .onChange(of: colorScheme, initial: true) { _, scheme in inspector.isDark = scheme == .dark }
        .background { InspectorCloseShortcut(inspector: inspector) }
        .alert("Open Address", isPresented: Binding(get: { inspector.showsAddressPrompt }, set: { inspector.showsAddressPrompt = $0 })) {
            AddressPrompt(inspector: inspector)
        } message: {
            Text("A page, a localhost port on \(inspector.gatewayMachineName), or a file on it.")
        }
    }
}

/// The + menu's Open Address… field.
private struct AddressPrompt: View {
    let inspector: InspectorModel
    @State private var address = ""

    var body: some View {
        TextField("localhost:5173", text: $address)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
        Button("Cancel", role: .cancel) {}
        Button("Open") { inspector.openAddress(address) }
    }
}

// MARK: - Tab strip

/// `inspectorBar`: the open tabs on glass, then + (`openMenu`) and the panel's … menu.
struct InspectorTabStrip: View {
    let inspector: InspectorModel
    var style = InspectorPanel.Style.panel

    @State private var showsMenu = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let tabs = inspector.tabs
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            chip(tab, index: index, count: tabs.count)
                        }
                    }
                }
                .onChange(of: inspector.selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation(Theme.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if style != .sheet {
                addButton
                moreMenu
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 40)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Inspector tabs"))
    }

    @ViewBuilder
    private func chip(_ tab: InspectorTab, index: Int, count: Int) -> some View {
        let chip = InspectorTabChip(inspector: inspector, tab: tab, index: index, count: count).id(tab.id)
        #if os(macOS)
        chip
            .draggable(InspectorTabTransfer(tabID: tab.id))
            .onDragSessionUpdated { session in
                // Dropped outside any window: the tab gets its own.
                if case .ended(.cancel) = session.phase {
                    openInWindow(tab)
                }
            }
        #else
        chip
        #endif
    }

    private var addButton: some View {
        Button {
            showsMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .accessibilityLabel("Open in Inspector")
        .help("Open in Inspector")
        .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
            InspectorOpenMenu(inspector: inspector) { showsMenu = false }
                .presentationCompactAdaptation(.popover)
        }
    }

    private var moreMenu: some View {
        Menu {
            if let tab = inspector.selected {
                Button(inspector.isPinned(tab.id) ? "Unpin Tab" : "Pin Tab", systemImage: inspector.isPinned(tab.id) ? "pin.slash" : "pin") {
                    inspector.togglePin(tab.id)
                }
                #if os(macOS)
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { openInWindow(tab) }
                #endif
                Button("Close Tab", systemImage: "xmark") { inspector.close(tab.id) }
                Divider()
            }
            Button("Open Address…", systemImage: "globe") { inspector.showsAddressPrompt = true }
            Button("Hide Inspector", systemImage: "sidebar.right") { inspector.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    private func openInWindow(_ tab: InspectorTab) {
        #if os(macOS)
        guard let conversation = inspector.conversation, let workspace = inspector.workspace else { return }
        inspector.detach(tab.id)
        openWindow(value: InspectorWindowRef(workspaceID: workspace.id, conversationID: conversation.id, tabID: tab.id))
        #endif
    }
}

/// `inspectorTab`: glyph, title, the ink dot while Hermes uses it, ✕ when selected, a pin when pinned.
struct InspectorTabChip: View {
    let inspector: InspectorModel
    let tab: InspectorTab
    let index: Int
    let count: Int

    @State private var hovering = false

    private var isSelected: Bool { inspector.selected?.id == tab.id }
    private var isPinned: Bool { inspector.isPinned(tab.id) }
    private var hermesUses: Bool { inspector.isUsedByHermes(tab) }
    private var unseen: Bool { inspector.isUnseen(tab) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .frame(width: 14)
            Text(title)
                .font(.footnote.weight(unseen ? .bold : .medium))
                .foregroundStyle(isSelected || unseen ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(1)
            if hermesUses {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
            if isSelected || hovering {
                Button {
                    inspector.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close \(title)"))
            } else if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            if isSelected {
                Capsule()
                    .fill(Theme.surfaceRaised)
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { inspector.select(tab.id) }
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button(isPinned ? "Unpin Tab" : "Pin Tab", systemImage: isPinned ? "pin.slash" : "pin") { inspector.togglePin(tab.id) }
            Button("Close Tab", systemImage: "xmark") { inspector.close(tab.id) }
        }
        .animation(Theme.snappy, value: hermesUses)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { inspector.select(tab.id) }
        .accessibilityAction(named: Text("Close")) { inspector.close(tab.id) }
        .accessibilityAction(named: Text(isPinned ? "Unpin" : "Pin")) { inspector.togglePin(tab.id) }
    }

    private var title: String {
        if tab.kind == .changes, let count = inspector.changesCount(tab) { return "\(tab.title) · \(count)" }
        return tab.title
    }

    /// "localhost:5173, Hermes is using this, tab 1 of 4".
    private var accessibilityText: String {
        var parts = [title]
        if hermesUses { parts.append(String(localized: "Hermes is using this")) }
        if isPinned { parts.append(String(localized: "Pinned")) }
        parts.append(String(localized: "tab \(index + 1) of \(count)"))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Open menu

/// `openMenu` (Mac, iPad): everything this chat can show, with live counts.
struct InspectorOpenMenu: View {
    let inspector: InspectorModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(inspector.offers) { offer in
                row(symbol: offer.kind.symbol, title: offer.kind.name, detail: offer.detail) {
                    dismiss()
                    inspector.open(offer.kind)
                }
            }
            if !inspector.offers.isEmpty {
                Divider().padding(.vertical, 4)
            }
            row(symbol: "globe", title: String(localized: "Open Address…"), detail: "⌘L") {
                dismiss()
                inspector.showsAddressPrompt = true
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .task { await inspector.refreshOffers() }
    }

    private func row(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? Theme.rowHover : .clear)
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
    }
}

/// `inspectorOpen` (iPhone), and the empty Inspector anywhere: tiles for what can open.
struct InspectorOpenGrid: View {
    let inspector: InspectorModel

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if inspector.offers.isEmpty {
                    Text("Pages, artifacts, files and changes from this chat open here, and Hermes can open them too.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 4)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(inspector.offers) { offer in
                        tile(symbol: offer.kind.symbol, title: offer.kind.name, detail: offer.detail) {
                            inspector.showsOpenGrid = false
                            inspector.open(offer.kind)
                        }
                    }
                    tile(symbol: "globe", title: String(localized: "Open Address…"), detail: String(localized: "A page or localhost")) {
                        inspector.showsAddressPrompt = true
                    }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await inspector.refreshOffers() }
    }

    private func tile(symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.primaryText)
                    .frame(height: 24, alignment: .leading)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Tab content

/// The selected tab's content, by kind. Every body is solid content, never glass.
struct InspectorTabContent: View {
    let tab: InspectorTab
    let inspector: InspectorModel
    let conversation: ConversationModel
    let workspace: BotWorkspace

    var body: some View {
        switch tab.kind {
        case .preview:
            PreviewTabView(inspector: inspector, controller: inspector.preview(for: tab), tab: tab)
        case .artifact:
            ArtifactTabView(inspector: inspector, tab: tab)
        case .file:
            FileTabView(inspector: inspector, editor: inspector.editor(for: tab))
        case .files:
            FilesTabView(inspector: inspector, tree: inspector.tree(root: tab.key))
        case .changes:
            ChangesTabView(inspector: inspector, model: inspector.changes(for: tab))
        case .terminal:
            TerminalTabView(inspector: inspector, conversation: conversation, processID: tab.key)
        case .screen:
            ScreenTabView(inspector: inspector, screen: inspector.screenController())
        case .team:
            TeamTabView(store: conversation.helpers, conversation: conversation, workspace: workspace, teamID: tab.key)
        case .plan:
            PlanTabView(inspector: inspector)
        case .sources:
            SourcesTabView(inspector: inspector)
        }
    }
}

#if os(macOS)
/// A tab dragged out of the strip.
struct InspectorTabTransfer: Codable, Transferable {
    var tabID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Which tab a tab window shows: the gateway, the chat (this run of the app) and the tab.
struct InspectorWindowRef: Codable, Hashable {
    var workspaceID: UUID
    var conversationID: UUID
    var tabID: String
}
#endif
