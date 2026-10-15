import HermesKit
import SwiftUI

/// New Project and Edit Project (`newProject`, `editProject`): a live tile, the name, seven colours
/// and eight glyphs, then the folders. New Project picks one of the git folders Hermes found as
/// the primary; Edit Project lists the project's folders (swipe to remove, long-press for Make
/// Primary) and pairs Archive with Delete. Folder edits apply together on ✓.
struct ProjectEditorSheet: View {
    let workspace: BotWorkspace
    let target: ProjectEditorTarget
    let onDone: (_ openedProjectID: String?) -> Void

    @State private var name = ""
    @State private var appearance = ProjectAppearance()
    /// New Project: the picked folder (the primary). Edit Project: the folders as edited.
    @State private var picked: String?
    @State private var folders: [String] = []
    @State private var primary: String?
    /// Folders chosen with Choose Another Folder…, listed with the found ones.
    @State private var extraFolders: [String] = []
    @State private var isSaving = false
    @State private var error: String?
    @State private var choosingFolder = false
    @State private var confirmingDelete = false
    @State private var populated = false
    @FocusState private var nameFocused: Bool

    private var projects: ProjectsModel { workspace.projects }

    private var editing: HermesProject? {
        if case .edit(let id) = target { return projects.project(id) }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !isSaving }

    var body: some View {
        #if os(macOS)
        if editing == nil {
            macNewProject
        } else {
            editorForm
        }
        #else
        editorForm
        #endif
    }

    #if os(macOS)
    /// New Project on the Mac (`macNewProject`): the tile and what a project is, then name,
    /// colour, symbol and the folder on the gateway (Choose… browses the gateway's files), then
    /// Cancel / Create Project.
    private var macNewProject: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProjectTile(appearance: appearance, size: 52)
                    .animation(Theme.snappy, value: appearance)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Project")
                        .font(.headline)
                    Text("Chats in the project run in its folder on \(workspace.bot.name).")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            VStack(spacing: 0) {
                macRow("Name") {
                    TextField("Name", text: $name, prompt: Text("Project name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }
                Divider()
                macRow("Colour") {
                    HStack(spacing: 10) {
                        ForEach(ProjectAccent.allCases) { accent in
                            Button {
                                appearance.accent = accent
                            } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [accent.top, accent.deep], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 20, height: 20)
                                    .padding(3)
                                    .overlay {
                                        if appearance.accent == accent { Circle().strokeBorder(Theme.primaryText, lineWidth: 2) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.name)
                            .accessibilityAddTraits(appearance.accent == accent ? .isSelected : [])
                        }
                    }
                }
                Divider()
                macRow("Symbol") {
                    HStack(spacing: 6) {
                        ForEach(ProjectGlyph.allCases) { glyph in
                            Button {
                                appearance.glyph = glyph
                            } label: {
                                Image(systemName: glyph.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(appearance.glyph == glyph ? Theme.primaryText : Theme.secondaryText)
                                    .frame(width: 28, height: 28)
                                    .background(appearance.glyph == glyph ? Theme.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(glyph.name)
                            .accessibilityAddTraits(appearance.glyph == glyph ? .isSelected : [])
                        }
                    }
                }
                Divider()
                macRow("Folder") {
                    HStack {
                        Text(picked.map { projects.displayPath($0) } ?? String(localized: "None chosen"))
                            .font(.body.monospaced())
                            .foregroundStyle(picked == nil ? Theme.tertiaryText : Theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { choosingFolder = true }
                            .buttonBorderShape(.capsule)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Git folders Hermes has worked in are suggested first. Hermes reads the folder's AGENTS.md before each chat.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonBorderShape(.capsule)
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Create Project") }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || picked == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await populate()
            if picked == nil, let first = projects.suggestedRepos.first { pick(first.root) }
        }
        .sheet(isPresented: $choosingFolder) {
            FolderPickerSheet(workspace: workspace, title: String(localized: "Choose a Folder")) { path in
                choosingFolder = false
                guard let path else { return }
                chose(path)
            }
        }
    }

    private func macRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }
    #endif

    private var editorForm: some View {
        NavigationStack {
            Form {
                Section {
                    identity
                }
                if editing == nil {
                    newFolders
                } else {
                    editFolders
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .font(.subheadline)
                    }
                }
                if let editing {
                    archiveAndDelete(editing)
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editing == nil ? "New Project" : "Edit Project")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .task { await populate() }
            .interactiveDismissDisabled(isSaving)
            .sheet(isPresented: $choosingFolder) {
                FolderPickerSheet(workspace: workspace, title: editing == nil ? String(localized: "Choose a Folder") : String(localized: "Add Folder")) { path in
                    choosingFolder = false
                    guard let path else { return }
                    chose(path)
                }
            }
            .alert(deleteTitle, isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("The chats stay in Chats.")
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: 16) {
            ProjectTile(appearance: appearance, size: 64)
                .animation(Theme.snappy, value: appearance)
            TextField("Project name", text: $name, prompt: Text("Project name"))
                .labelsHidden()
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Project name")
            HStack(spacing: 0) {
                ForEach(ProjectAccent.allCases) { accent in
                    Button {
                        appearance.accent = accent
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [accent.top, accent.deep], startPoint: .top, endPoint: .bottom))
                            .frame(width: 30, height: 30)
                            .padding(4)
                            .overlay {
                                if appearance.accent == accent {
                                    Circle().strokeBorder(Theme.primaryText, lineWidth: 2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accent.name)
                    .accessibilityAddTraits(appearance.accent == accent ? .isSelected : [])
                }
            }
            HStack(spacing: 6) {
                ForEach(ProjectGlyph.allCases) { glyph in
                    Button {
                        appearance.glyph = glyph
                    } label: {
                        Image(systemName: glyph.rawValue)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(appearance.glyph == glyph ? Theme.primaryText : Theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(appearance.glyph == glyph ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(glyph.name)
                    .accessibilityAddTraits(appearance.glyph == glyph ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: New Project's folder

    private var candidates: [String] {
        let found = projects.discovered.map(\.root)
        return extraFolders + found.filter { !extraFolders.contains($0) }
    }

    @ViewBuilder
    private var newFolders: some View {
        Section {
            ForEach(candidates, id: \.self) { path in
                Button {
                    pick(path)
                } label: {
                    HStack(spacing: 12) {
                        FolderRow(
                            folder: HermesProject.Folder(path: path),
                            displayPath: projects.displayPath(path),
                            isPrimary: picked == path,
                            annotation: projects.owner(ofFolder: projects.absolute(path)).map { String(localized: "in \($0.name)") }
                        )
                        Image(systemName: picked == path ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked == path ? Theme.ink : Theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked == path ? .isSelected : [])
            }
            Button("Choose Another Folder…") { choosingFolder = true }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.link)
        } header: {
            Text("Folder")
        } footer: {
            Text("Git folders on \(workspace.bot.name). Chats in the project run in the primary folder, and Hermes reads its AGENTS.md first.")
        }
    }

    private func pick(_ path: String) {
        picked = path
        error = nil
        if trimmedName.isEmpty { name = ProjectPath.lastComponent(path) }
    }

    // MARK: Edit Project's folders

    @ViewBuilder
    private var editFolders: some View {
        Section {
            ForEach(orderedFolders, id: \.self) { path in
                FolderRow(folder: HermesProject.Folder(path: path), displayPath: projects.displayPath(path), isPrimary: path == primary)
                    .contextMenu {
                        if path != primary {
                            Button("Make Primary", systemImage: "star") { primary = path }
                        }
                        Button("Remove Folder", systemImage: "minus.circle", role: .destructive) { remove(path) }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(path) }
                    }
            }
            Button("Add Folder…") { choosingFolder = true }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.link)
        } header: {
            Text("Folders")
        } footer: {
            #if os(macOS)
            Text("Right-click a folder to remove it or make it primary. Removing a folder keeps its chats.")
            #else
            Text("Swipe a folder to remove it, or long-press to make it primary. Removing a folder keeps its chats.")
            #endif
        }
    }

    private var orderedFolders: [String] {
        folders.filter { $0 == primary } + folders.filter { $0 != primary }
    }

    private func remove(_ path: String) {
        folders.removeAll { $0 == path }
        if primary == path { primary = folders.first }
    }

    private func archiveAndDelete(_ project: HermesProject) -> some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    Task {
                        try? await projects.archive(project.id)
                        onDone(nil)
                    }
                } label: {
                    Text("Archive").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Theme.primaryText)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text("Delete…").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(isSaving)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var deleteTitle: String {
        String(localized: "Delete “\(editing?.name ?? name)”?")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            #if os(macOS)
            Button("Cancel") { onDone(nil) }
            #else
            Button(role: .cancel) { onDone(nil) }
            #endif
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                #if os(macOS)
                Button(editing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                #else
                Button(role: .confirm, action: save)
                    .tint(Theme.ink)
                    .disabled(!canSave)
                    .accessibilityLabel(editing == nil ? "Create" : "Save")
                #endif
            }
        }
    }

    // MARK: Actions

    private func populate() async {
        guard !populated else { return }
        populated = true
        if let editing {
            name = editing.name
            appearance = ProjectAppearance(editing)
            folders = editing.folders.map(\.path)
            primary = editing.primaryPath ?? folders.first
        } else {
            nameFocused = true
            if case .new(let folder?) = target {
                extraFolders = [folder]
                pick(folder)
            }
            await projects.loadDiscovered()
        }
    }

    private func chose(_ chosen: String) {
        let path = projects.absolute(chosen)
        if editing != nil {
            if !folders.contains(path) { folders.append(path) }
            if primary == nil { primary = path }
        } else {
            if !candidates.contains(path) { extraFolders.insert(path, at: 0) }
            pick(path)
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                if let editing {
                    try await saveEdits(editing)
                    onDone(nil)
                } else {
                    let project = try await projects.create(
                        name: trimmedName, folders: picked.map { [$0] } ?? [], primary: picked, appearance: appearance
                    )
                    onDone(project.id)
                }
            } catch let rpc as GatewayRPCError where rpc.code == ProjectsClient.Code.invalid {
                // A folder that's already a project's primary, or a name the gateway refused.
                error = rpc.message.contains("already belongs")
                    ? String(localized: "That folder is already a project's primary folder. Open that project, or pick another folder.")
                    : rpc.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func saveEdits(_ project: HermesProject) async throws {
        if trimmedName != project.name || appearance != ProjectAppearance(project) {
            try await projects.update(project, name: trimmedName, appearance: appearance)
        }
        let before = Set(project.folders.map(\.path))
        for path in folders where !before.contains(path) {
            try await projects.addFolder(path, to: project)
        }
        if let primary, primary != project.primaryPath {
            try await projects.makePrimary(primary, in: projects.project(project.id) ?? project)
        }
        for path in before where !folders.contains(path) {
            try await projects.removeFolder(path, from: projects.project(project.id) ?? project)
        }
    }

    private func delete() {
        guard let editing else { return }
        Task {
            try? await projects.delete(editing.id)
            onDone(nil)
        }
    }
}
