import HermesKit
import SwiftUI

/// Where the Inspector shows (`docs/inspector.md` §1): beside the chat on the Mac and iPad in
/// landscape, a two-height sheet on iPhone and iPad in portrait. It also tells the model whether
/// it's on screen, so Hermes's requests are answered only while the person can see them.
struct InspectorPresentation: ViewModifier {
    let conversation: ConversationModel
    let workspace: BotWorkspace
    /// Beside the chat (Mac, iPad landscape); otherwise a sheet.
    let usesPanel: Bool
    /// The window's width, for the panel's 60% limit.
    let windowWidth: CGFloat

    @Environment(WindowRouter.self) private var router: WindowRouter?
    @State private var shownInspector: InspectorModel?

    private var inspector: InspectorModel { conversation.inspector }

    private var maxPanelWidth: CGFloat {
        max(380, windowWidth > 0 ? windowWidth * 0.6 : 720)
    }

    func body(content: Content) -> some View {
        let inspector = inspector
        content
            .inspector(isPresented: Binding(
                get: { usesPanel && inspector.isPresented },
                set: { if !$0, usesPanel { inspector.isPresented = false } }
            )) {
                InspectorPanel(inspector: inspector, conversation: conversation, workspace: workspace, style: .panel)
                    .modifier(PanelChrome())
                    .inspectorColumnWidth(min: 380, ideal: 600, max: maxPanelWidth)
            }
            #if os(iOS)
            .sheet(isPresented: Binding(
                get: { !usesPanel && inspector.isPresented },
                set: { if !usesPanel { inspector.isPresented = $0 } }
            )) {
                InspectorSheet(inspector: inspector, conversation: conversation, workspace: workspace)
            }
            #endif
            .onChange(of: usesPanel, initial: true) { _, panel in inspector.prefersPanel = panel }
            .onChange(of: inspector.isPresented, initial: true) { _, _ in syncPlacement() }
            .onChange(of: ObjectIdentifier(conversation), initial: true) { _, _ in
                // Another chat in the same screen: the last one's Inspector is off screen now.
                if let shownInspector, shownInspector !== inspector { shownInspector.placement = .hidden }
                shownInspector = inspector
                syncPlacement()
            }
            .onDisappear {
                inspector.placement = .hidden
                router?.inspectorIsOpen = false
            }
            // The Team opens as a tab (`docs/helpers.md`: the Team inspector became the Team tab).
            .onChange(of: conversation.helpers.shownTeam) { old, new in
                if let new, inspector.selected?.id != "team:\(new)" {
                    inspector.openTeam(new)
                } else if new == nil, let old, inspector.tab("team:\(old)") != nil {
                    inspector.close("team:\(old)")
                }
            }
    }

    private func syncPlacement() {
        inspector.placement = inspector.isPresented ? .visible : .hidden
        router?.inspectorIsOpen = usesPanel && inspector.isPresented
    }
}

/// The Mac's panel: inset 8 pt, radius 18, a hairline; content is solid.
private struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding([.horizontal, .bottom], 8)
            .background(Theme.canvas)
        #else
        content
            .background(Theme.canvas)
        #endif
    }
}

#if os(iOS)
/// The iPhone sheet (`inspectorSheet`, `inspectorChanges`, `inspectorOpen`): medium keeps the end
/// of the chat and the composer in view and is glass, with the content in a solid card; large is
/// full height with a title bar.
private struct InspectorSheet: View {
    let inspector: InspectorModel
    let conversation: ConversationModel
    let workspace: BotWorkspace

    @State private var detent = PresentationDetent.medium

    private var isLarge: Bool { detent == .large }

    var body: some View {
        VStack(spacing: 0) {
            if isLarge || inspector.showsOpenGrid || inspector.tabs.isEmpty {
                header
            }
            if inspector.showsOpenGrid || inspector.tabs.isEmpty {
                InspectorOpenGrid(inspector: inspector)
            } else {
                InspectorTabStrip(inspector: inspector, style: .sheet)
                    .padding(.horizontal, 12)
                    .padding(.top, isLarge ? 0 : 14)
                    .padding(.bottom, 8)
                if let tab = inspector.selected {
                    InspectorTabContent(tab: tab, inspector: inspector, conversation: conversation, workspace: workspace)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: isLarge ? 0 : 22, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: isLarge ? 0 : 22, style: .continuous))
                        .padding(.horizontal, isLarge ? 0 : 10)
                        .padding(.bottom, isLarge ? 0 : 10)
                }
            }
        }
        .environment(\.inspectorModel, nil)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        .presentationBackground(isLarge ? AnyShapeStyle(Theme.sheetBackground) : AnyShapeStyle(.clear))
        .onChange(of: detent) { _, new in inspector.sheetHeight = new == .large ? .large : .medium }
        .onAppear { detent = inspector.sheetHeight == .large ? .large : .medium }
        .alert("Open Address", isPresented: Binding(get: { inspector.showsAddressPrompt }, set: { inspector.showsAddressPrompt = $0 })) {
            SheetAddressPrompt(inspector: inspector)
        } message: {
            Text("A page, a localhost port on \(inspector.gatewayMachineName), or a file on it.")
        }
    }

    private var header: some View {
        HStack {
            Button {
                if inspector.showsOpenGrid, !inspector.tabs.isEmpty {
                    inspector.showsOpenGrid = false
                } else {
                    inspector.isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(inspector.showsOpenGrid && !inspector.tabs.isEmpty ? "Back" : "Close")
            Spacer()
            Text(inspector.showsOpenGrid || inspector.tabs.isEmpty ? "Open in Inspector" : "Inspector")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Button {
                inspector.showsOpenGrid.toggle()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Open in Inspector")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct SheetAddressPrompt: View {
    let inspector: InspectorModel
    @State private var address = ""

    var body: some View {
        TextField("localhost:5173", text: $address)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        Button("Cancel", role: .cancel) {}
        Button("Open") {
            inspector.showsOpenGrid = false
            inspector.openAddress(address)
        }
    }
}
#endif

/// `inspectorPill` (iPhone, iPad portrait): the current tab, an ink dot while Hermes uses it, and
/// "+N" for the others. Tapping it opens the sheet.
struct InspectorPill: View {
    let inspector: InspectorModel

    var body: some View {
        if let tab = inspector.selected {
            Button {
                inspector.isPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.kind.symbol)
                        .font(.system(size: 12, weight: .medium))
                    Text(tab.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if inspector.isUsedByHermes(tab) {
                        Circle().fill(Theme.ink).frame(width: 6, height: 6)
                    }
                    if inspector.tabs.count > 1 {
                        Text("+\(inspector.tabs.count - 1)")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pillLabel(tab)))
            .accessibilityHint(Text("Opens the Inspector"))
        }
    }

    private func pillLabel(_ tab: InspectorTab) -> String {
        var parts = [String(localized: "Inspector"), tab.title]
        if inspector.isUsedByHermes(tab) { parts.append(String(localized: "Hermes is using this")) }
        if inspector.tabs.count > 1 { parts.append(String(localized: "\(inspector.tabs.count - 1) more tabs")) }
        return parts.joined(separator: ", ")
    }
}

/// The toolbar's Inspector button (Mac, iPad): ink while the panel is open.
struct InspectorToolbarButton: View {
    let inspector: InspectorModel

    var body: some View {
        Button {
            inspector.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .accessibilityLabel(inspector.isPresented ? "Hide Inspector" : "Show Inspector")
        .help(inspector.isPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
    }
}
