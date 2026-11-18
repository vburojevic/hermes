#if os(macOS)
import HermesKit
import SwiftUI

/// A narrow Mac window's sidebar (`docs/chat.md` §4, `macNarrow600Sidebar`): the same 240 pt
/// glass panel, over the chat with a deeper shadow, and the chat stays where it is underneath.
/// Picking a chat, clicking the chat, Esc or its sidebar button puts it away. Showing it never
/// resizes the window.
struct SidebarOverChat: View {
    let workspace: BotWorkspace
    let router: WindowRouter

    @AccessibilityFocusState private var voiceOverInPanel: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A click on the chat puts the sidebar away; the click goes no further.
            Color.black.opacity(0.001)
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
        }
        .ignoresSafeArea()
        .onAppear {
            voiceOverInPanel = true
            if router.searchesWhenSidebarShows {
                router.searchesWhenSidebarShows = false
                router.focusSidebarSearch()
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            topRow
            SidebarView(workspace: workspace)
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.shadow, radius: 20, y: 12)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Sidebar")
    }

    /// The window's own traffic lights sit at its leading end; its sidebar button takes the
    /// place of the toolbar's.
    private var topRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if workspace.sidebarMode == .chats || workspace.roster == nil {
                InboxFilterButton(workspace: workspace)
                    .labelStyle(.iconOnly)
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
            }
            Button(action: close) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityLabel("Hide Sidebar")
            .help("Hide Sidebar (⌃⌘S)")
            .accessibilityFocused($voiceOverInPanel)
            // Esc puts the sidebar away from anywhere in the window. The chat's own Esc (an
            // approval's Deny) steps aside while it shows (`panelOverChat`).
            Button("Hide Sidebar", action: close)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func close() {
        router.layout.closeSidebarOver()
    }
}
#endif
