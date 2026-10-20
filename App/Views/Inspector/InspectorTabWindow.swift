import HermesKit
import SwiftUI

#if os(macOS)
/// One Inspector tab in its own window (Mac): dragged out of the strip, or Open in New Window.
/// Closing the window puts the tab back in the chat's Inspector.
struct InspectorTabWindow: View {
    let ref: InspectorWindowRef

    @Environment(AppModel.self) private var app

    private var workspace: BotWorkspace? { app.workspaces[ref.workspaceID] }
    private var conversation: ConversationModel? { workspace?.loadedConversation(id: ref.conversationID) }

    var body: some View {
        Group {
            if let workspace, let conversation, let tab = conversation.inspector.tab(ref.tabID) {
                InspectorPanel(inspector: conversation.inspector, conversation: conversation, workspace: workspace, style: .window, onlyTab: tab.id)
                    .navigationTitle(tab.title)
                    .onDisappear { conversation.inspector.reattach(tab.id) }
            } else {
                StateMessage(symbol: "sidebar.right", title: String(localized: "This tab is closed"), message: nil)
                    .navigationTitle(String(localized: "Inspector"))
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Theme.canvas)
    }
}
#endif

extension FocusedValues {
    /// The Inspector whose panel has focus (⌘W closes its tab rather than the window).
    @Entry var inspectorPanel: InspectorModel?
}

/// ⌘W closes the selected tab while the panel has focus.
struct InspectorCloseShortcut: View {
    let inspector: InspectorModel
    @FocusedValue(\.inspectorPanel) private var focused

    var body: some View {
        if focused === inspector, inspector.selected != nil {
            Button("Close Tab") { inspector.closeSelected() }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
