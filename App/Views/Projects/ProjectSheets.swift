import HermesKit
import SwiftUI

/// New and Edit Project, Add Folder, Move to Project, Run In and Delete Project, presented for
/// the whole window (like `BotSheets`).
struct ProjectSheets: ViewModifier {
    let workspace: BotWorkspace

    private var projects: ProjectsModel { workspace.projects }

    func body(content: Content) -> some View {
        @Bindable var projects = projects
        content
            .sheet(item: $projects.editing) { target in
                ProjectEditorSheet(workspace: workspace, target: target) { opened in
                    projects.editing = nil
                    if let opened {
                        projects.focusLane = nil
                        workspace.sidebarMode = .chats
                        workspace.selection = .project(opened)
                    }
                }
                #if os(macOS)
                // New Project is a compact window sheet (`macNewProject`); Edit Project a form.
                .modifier(MacEditorFrame(isNew: target.isNew))
                #endif
            }
            .sheet(item: Binding(get: { projects.addingFolder.map(FolderTarget.init) }, set: { projects.addingFolder = $0?.id })) { target in
                FolderPickerSheet(workspace: workspace, title: String(localized: "Add Folder")) { path in
                    projects.addingFolder = nil
                    guard let path, let project = projects.project(target.id) else { return }
                    Task { try? await projects.addFolder(path, to: project) }
                }
            }
            .sheet(item: $projects.movingSession) { session in
                MoveToProjectSheet(workspace: workspace, session: session) {
                    projects.movingSession = nil
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { projects.runInConversation.map(RunInTarget.init) }, set: { projects.runInConversation = $0?.conversation })) { target in
                RunInSheet(workspace: workspace, conversation: target.conversation) {
                    projects.runInConversation = nil
                }
                .presentationDetents([.medium, .large])
            }
            .alert(
                deleteTitle,
                isPresented: Binding(get: { projects.deleting != nil }, set: { if !$0 { projects.deleting = nil } }),
                presenting: projects.deleting
            ) { id in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { try? await projects.delete(id) }
                }
            } message: { _ in
                Text("The chats stay in Chats.")
            }
            .onChange(of: projects.editing != nil || projects.movingSession != nil || projects.runInConversation != nil) { _, presenting in
                if presenting { Keyboard.dismiss() }
            }
    }

    private var deleteTitle: String {
        let name = projects.deleting.flatMap { projects.project($0)?.name } ?? ""
        return String(localized: "Delete “\(name)”?")
    }
}

private struct FolderTarget: Identifiable {
    let id: String
}

private struct RunInTarget: Identifiable {
    let conversation: ConversationModel
    var id: ObjectIdentifier { ObjectIdentifier(conversation) }
}

#if os(macOS)
private struct MacEditorFrame: ViewModifier {
    let isNew: Bool

    func body(content: Content) -> some View {
        if isNew {
            content
        } else {
            content.frame(width: 480).frame(minHeight: 560, idealHeight: 680)
        }
    }
}
#endif

extension ProjectEditorTarget {
    var isNew: Bool {
        if case .new = self { true } else { false }
    }
}
